-- 005_v3_audit_events_and_rate_core.sql — Campus Market V3
-- Adds: audit_logs, security_events (both APPEND-ONLY), rate_limit_rules/events + rate_limit_check().
--
-- WHAT THIS CHANGES: creates 5 new tables, 5 new functions, 6 triggers and seeds the rate-limit rules
-- table. It does NOT modify, delete or rewrite any existing V2 table, row, policy, function or trigger.
-- Idempotent: safe to run twice. Runs inside one transaction (all-or-nothing).
-- Run order: 004 (read-only audit) -> 005 (this) -> 006 -> 007 -> 008 -> 009.
--
-- SECURITY DEFINER RULES (apply to every definer function in V3, including this file):
--   * `SET search_path = ''` and every object reference is schema-qualified, so a caller's search_path
--     (or an object planted in another schema) can never change what the function does.
--   * The actor is ALWAYS auth.uid() (derived from the signed JWT). No function accepts an actor id,
--     role or "created_by" argument, and none trusts such a value from the browser.
--   * EXECUTE is revoked from PUBLIC, anon, authenticated and service_role for internal functions
--     (they are reachable only from other definer functions/triggers, which run as the owner).
--   * Nothing here needs, reads or exposes the Supabase service-role key.
-- Append-only: API roles get no INSERT/UPDATE/DELETE/TRUNCATE on the audit tables; triggers raise for
-- EVERYONE (including the SQL Editor). The database OWNER can still disable a trigger on purpose.
-- Read policies for these tables are created in 006 (they need helper functions defined there);
-- until then the tables are unreadable by API roles (RLS on, no policy).

begin;

-- ───────────────────────── PRE-FLIGHT GATE ─────────────────────────
do $$
begin
  if to_regclass('public.profiles') is null or to_regclass('public.items') is null
     or to_regprocedure('public.user_role()') is null
     or not exists (select 1 from information_schema.columns
                    where table_schema = 'public' and table_name = 'profiles' and column_name = 'role') then
    raise exception 'MIGRATION 005 ABORTED - nothing was changed. V2 prerequisites are missing (profiles.role / user_role()).'
      using hint = 'Run V2 migrations 002_security_fixes.sql and 003_functional_schema_changes.sql first.';
  end if;
  if has_any_column_privilege('authenticated', 'public.profiles', 'UPDATE')
     or has_any_column_privilege('anon', 'public.profiles', 'UPDATE')
     or has_any_column_privilege('authenticated', 'public.profiles', 'INSERT') then
    raise exception 'MIGRATION 005 ABORTED - nothing was changed. API roles can still write public.profiles (role escalation risk).'
      using hint = 'V2 migration 002 revokes this; run it first.';
  end if;
end $$;

-- ───────────────────────── append-only helper ─────────────────────────
create or replace function public.v3_block_mutation() returns trigger
language plpgsql set search_path = '' as $$
begin
  raise exception 'Table % is append-only: % is not allowed.', tg_table_name, tg_op using errcode = '42501';
end $$;
revoke all on function public.v3_block_mutation() from public, anon, authenticated, service_role;

-- ───────────────────────── audit_logs ─────────────────────────
create table if not exists public.audit_logs (
  id          bigint generated always as identity primary key,
  created_at  timestamptz not null default now(),
  actor_id    uuid,                              -- NO foreign key on purpose: evidence must survive account deletion
  actor_role  text not null default 'system',    -- snapshot of the actor's role at the time
  actor_name  text,                              -- snapshot of the actor's display name
  action      text not null,
  category    text not null,
  target_type text,
  target_id   text,
  reason      text,
  metadata    jsonb not null default '{}'::jsonb,
  source      text not null default 'rpc',
  constraint audit_logs_action_valid check (action in (
    'ROLE_CHANGED','LISTING_HIDDEN','LISTING_RESTORED','USER_WARNED','USER_SUSPENDED','USER_UNSUSPENDED',
    'USER_BANNED','USER_UNBANNED','REPORT_REVIEWING','REPORT_RESOLVED','REPORT_DISMISSED',
    'CATEGORY_CREATED','CATEGORY_UPDATED','CATEGORY_DISABLED','CATEGORY_ENABLED',
    'ACCOUNT_STATUS_CHANGED','LISTING_MODERATION_CHANGED')),
  constraint audit_logs_category_valid check (category in ('moderation','admin','security','system')),
  constraint audit_logs_target_type_valid check (target_type is null or target_type in ('user','listing','report','category','system')),
  constraint audit_logs_source_valid check (source in ('rpc','trigger','direct_sql'))
);
create index if not exists audit_logs_created on public.audit_logs (created_at desc);
create index if not exists audit_logs_category_created on public.audit_logs (category, created_at desc);
create index if not exists audit_logs_target on public.audit_logs (target_type, target_id);
create index if not exists audit_logs_actor on public.audit_logs (actor_id);

-- ───────────────────────── security_events (V4 risk-scoring foundation) ─────────────────────────
create table if not exists public.security_events (
  id         bigint generated always as identity primary key,
  created_at timestamptz not null default now(),
  user_id    uuid,
  event_type text not null,
  severity   text not null default 'info',
  metadata   jsonb not null default '{}'::jsonb,
  source     text not null default 'system',
  constraint security_events_severity_valid check (severity in ('info','notice','warning'))
);
create index if not exists security_events_created on public.security_events (created_at desc);
create index if not exists security_events_user on public.security_events (user_id, created_at desc);
create index if not exists security_events_type on public.security_events (event_type, created_at desc);

-- append-only triggers (row-level UPDATE/DELETE and statement-level TRUNCATE) for both tables
do $$
declare t text;
begin
  foreach t in array array['audit_logs', 'security_events'] loop
    execute format('drop trigger if exists %I on public.%I', t || '_no_mutate', t);
    execute format('create trigger %I before update or delete on public.%I for each row execute function public.v3_block_mutation()', t || '_no_mutate', t);
    execute format('drop trigger if exists %I on public.%I', t || '_no_truncate', t);
    execute format('create trigger %I before truncate on public.%I for each statement execute function public.v3_block_mutation()', t || '_no_truncate', t);
    execute format('alter table public.%I enable row level security', t);
    execute format('revoke all on public.%I from public, anon, authenticated, service_role', t);
  end loop;
end $$;

-- ───────────────────────── rate limiting core ─────────────────────────
create table if not exists public.rate_limit_rules (
  action         text    not null,
  window_seconds integer not null check (window_seconds > 0),
  max_count      integer not null check (max_count > 0),
  primary key (action, window_seconds)
);
create table if not exists public.rate_limit_events (
  id         bigint generated always as identity primary key,
  user_id    uuid not null,
  action     text not null,
  created_at timestamptz not null default now()
);
create index if not exists rate_limit_events_lookup on public.rate_limit_events (user_id, action, created_at desc);
alter table public.rate_limit_rules  enable row level security;
alter table public.rate_limit_events enable row level security;
revoke all on public.rate_limit_rules, public.rate_limit_events from public, anon, authenticated, service_role;

-- Seed values = the agreed starting limits (configuration data; existing rows are never overwritten).
insert into public.rate_limit_rules (action, window_seconds, max_count) values
  ('listing_create',   3600,   5), ('listing_create', 86400, 20),
  ('report_create',    3600,   3), ('report_create',  86400, 10),
  ('chat_start',      86400,  20),
  ('message_send',      600,  60),
  ('photo_upload',     3600,  30),
  ('contact_lookup',   3600,  40),
  ('moderator_action', 3600, 200)
on conflict (action, window_seconds) do nothing;

-- ───────────────────────── internal functions (definer, no API access) ─────────────────────────
create or replace function public.audit_write(
  p_action text, p_category text, p_target_type text, p_target_id text,
  p_reason text default null, p_metadata jsonb default '{}'::jsonb, p_source text default 'rpc')
returns bigint language plpgsql security definer set search_path = '' as $$
declare v_uid uuid := auth.uid(); v_role text; v_name text; v_id bigint;
begin
  if v_uid is not null then
    select p.role, p.display_name into v_role, v_name from public.profiles p where p.id = v_uid;
  end if;
  insert into public.audit_logs (actor_id, actor_role, actor_name, action, category, target_type, target_id, reason, metadata, source)
  values (v_uid,
          coalesce(v_role, case when v_uid is null then 'system' else 'student' end),
          coalesce(v_name, case when v_uid is null then 'SQL Editor / system' end),
          p_action, p_category, p_target_type, p_target_id, nullif(left(btrim(p_reason), 1000), ''),
          coalesce(p_metadata, '{}'::jsonb), p_source)
  returning id into v_id;
  return v_id;
end $$;

create or replace function public.record_security_event(
  p_user_id uuid, p_event_type text, p_severity text default 'info', p_metadata jsonb default '{}'::jsonb)
returns void language plpgsql security definer set search_path = '' as $$
begin
  insert into public.security_events (user_id, event_type, severity, metadata, source)
  values (p_user_id, p_event_type, p_severity, coalesce(p_metadata, '{}'::jsonb), 'db');
end $$;

-- Sliding-window limiter. user = auth.uid() (JWT), time = now() (server). Counts ACCEPTED events only,
-- and an event is recorded only when the action is allowed. Raises SQLSTATE 54000 'RATE_LIMIT: ...'.
-- If no user is authenticated (SQL Editor / service role) it does nothing.
create or replace function public.rate_limit_check(p_action text)
returns void language plpgsql security definer set search_path = '' as $$
declare
  v_uid uuid := auth.uid();
  r record;
  v_count integer;
begin
  if v_uid is null then return; end if;
  -- serialise concurrent requests of the same user+action so the limit is exact
  perform pg_advisory_xact_lock(hashtextextended(v_uid::text || ':' || p_action, 0));
  delete from public.rate_limit_events where user_id = v_uid and created_at < now() - interval '2 days';
  for r in select window_seconds, max_count from public.rate_limit_rules where action = p_action order by window_seconds loop
    select count(*) into v_count from public.rate_limit_events
     where user_id = v_uid and action = p_action and created_at > now() - make_interval(secs => r.window_seconds);
    if v_count >= r.max_count then
      raise exception 'RATE_LIMIT: too many "%" actions (limit % per % minutes). Please try again later.',
        p_action, r.max_count, (r.window_seconds / 60) using errcode = '54000';
    end if;
  end loop;
  insert into public.rate_limit_events (user_id, action) values (v_uid, p_action);
  -- signal only: crossing 80% of any limit is recorded once per window (accepted request, so it persists)
  for r in select window_seconds, max_count from public.rate_limit_rules where action = p_action loop
    select count(*) into v_count from public.rate_limit_events
     where user_id = v_uid and action = p_action and created_at > now() - make_interval(secs => r.window_seconds);
    if v_count = ceil(r.max_count * 0.8)::integer then
      perform public.record_security_event(v_uid, 'RATE_LIMIT_NEAR', 'notice',
        jsonb_build_object('action', p_action, 'window_seconds', r.window_seconds, 'count', v_count, 'max', r.max_count));
    end if;
  end loop;
end $$;

-- No API role may call any of these directly.
revoke all on function public.audit_write(text, text, text, text, text, jsonb, text) from public, anon, authenticated, service_role;
revoke all on function public.record_security_event(uuid, text, text, jsonb)          from public, anon, authenticated, service_role;
revoke all on function public.rate_limit_check(text)                                  from public, anon, authenticated, service_role;

commit;
