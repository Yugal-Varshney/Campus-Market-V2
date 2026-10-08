-- 006_v3_accounts_and_moderation.sql — Campus Market V3
-- Account status (active/suspended/banned), listing moderation state, staff actions, enforcement.
--
-- WHAT THIS CHANGES (read before running):
--  ADDITIVE: new columns on profiles (account status, warnings) and items (moderation_*); new table
--    moderation_actions (append-only); new helper/staff functions; new triggers; new policies.
--    Existing rows are NOT modified: every existing profile becomes 'active', every existing listing
--    'approved' (column defaults only).
--  REPLACED / DESTRUCTIVE-LOOKING (no data is deleted or rewritten):
--    1. DROPS the V2 policy "signed-in can browse" on items and replaces it with moderation-aware
--       policies (approved listings for everyone, own listings for the owner, all for staff).
--    2. DROPS the old CHECK constraint on items.status (active/sold/rented) and adds a SUPERSET
--       (+ 'inactive'). Every existing value stays valid.
--    3. Re-creates get_contact(bigint) (same signature) so hidden listings / suspended users are refused.
--    4. Adds RESTRICTIVE policies on items, item_private, wishlists, conversations, messages: banned
--       users read nothing, only 'active' accounts write (suspended = read-only). V2 permissive
--       policies are untouched.
--  Idempotent; one transaction. Run order: 004 -> 005 -> 006 -> 007 -> 008 -> 009.
--
-- SECURITY DEFINER PROTECTIONS (every definer function below):
--   * SET search_path = '' and fully schema-qualified references (no reliance on caller search_path)
--   * actor = auth.uid() ONLY; no function takes an actor/role/created_by argument
--   * the caller's role is re-read from public.profiles inside the function; suspended/banned staff are
--     treated as students (they lose all staff power immediately)
--   * target restrictions inside the function: nobody acts on themselves; moderators act on students only
--   * EXECUTE: revoked from PUBLIC/anon; granted to `authenticated` only for the RPCs and the four
--     tiny caller-state helpers; revoked from everyone for internal helpers and trigger functions
--   * state change + moderation_actions row + audit_logs row happen in ONE transaction
--   * the profiles/items backstop triggers log any role/status/moderation change made OUTSIDE these
--     functions (SQL Editor, service role) as source='direct_sql'
-- Marketplace state (items.status) and moderation state (items.moderation_status) are independent:
-- hiding never changes status, marking sold never changes moderation_status.

begin;

-- ───────────────────────── PRE-FLIGHT GATE ─────────────────────────
do $$
declare bad text; n integer;
begin
  if to_regclass('public.audit_logs') is null or to_regprocedure('public.audit_write(text,text,text,text,text,jsonb,text)') is null
     or to_regprocedure('public.rate_limit_check(text)') is null then
    raise exception 'MIGRATION 006 ABORTED - nothing was changed. Run 005_v3_audit_events_and_rate_core.sql first.';
  end if;
  if to_regprocedure('public.items_guard()') is null or to_regprocedure('public.conversations_guard()') is null
     or to_regprocedure('public.get_contact(bigint)') is null or to_regprocedure('public.user_role()') is null then
    raise exception 'MIGRATION 006 ABORTED - nothing was changed. V2 functions are missing (run V2 002 and 003 first).';
  end if;
  if has_any_column_privilege('authenticated','public.profiles','UPDATE') or has_any_column_privilege('anon','public.profiles','UPDATE')
     or has_any_column_privilege('authenticated','public.profiles','INSERT') or has_table_privilege('authenticated','public.profiles','DELETE') then
    raise exception 'MIGRATION 006 ABORTED - nothing was changed. API roles can write public.profiles.' using hint = 'Run V2 migration 002 first.';
  end if;
  select string_agg(policyname || ' (' || cmd || ')', ', ') into bad from pg_policies
   where schemaname = 'public' and tablename = 'profiles' and permissive = 'PERMISSIVE' and cmd in ('INSERT','UPDATE','DELETE','ALL');
  if bad is not null then
    raise exception 'MIGRATION 006 ABORTED - nothing was changed. Permissive write policy on profiles: %', bad;
  end if;
  select string_agg(c.relname, ', ') into bad from pg_class c
   where c.oid in ('public.items'::regclass,'public.item_private'::regclass,'public.wishlists'::regclass,
                   'public.conversations'::regclass,'public.messages'::regclass,'public.profiles'::regclass)
     and not c.relrowsecurity;
  if bad is not null then raise exception 'MIGRATION 006 ABORTED - nothing was changed. RLS is OFF on: %', bad; end if;
  -- an extra permissive SELECT policy on items would keep hidden listings visible
  select string_agg('"' || policyname || '"', ', ') into bad from pg_policies
   where schemaname = 'public' and tablename = 'items' and permissive = 'PERMISSIVE' and cmd in ('SELECT','ALL')
     and policyname not in ('signed-in can browse','v3 browse approved','v3 owner reads own listings','v3 staff read all listings');
  if bad is not null then
    raise exception 'MIGRATION 006 ABORTED - nothing was changed. Unexpected permissive SELECT policy on items would defeat hiding: %', bad
      using hint = 'Review it in the dashboard; drop it yourself if unneeded, then run this file again.';
  end if;
  select count(*) into n from pg_constraint
   where conrelid = 'public.items'::regclass and contype = 'c'
     and pg_get_constraintdef(oid) ~ 'status = ANY \(ARRAY\[''active''::text, ''sold''::text, ''rented''::text\]\)';
  if n > 1 or (n = 0 and not exists (select 1 from pg_constraint where conname = 'items_status_valid_v3')) then
    raise exception 'MIGRATION 006 ABORTED - nothing was changed. Could not identify the items.status CHECK (found % matching constraints).', n
      using hint = 'Run 004_v3_preflight_audit.sql and send me the constraint list.';
  end if;
end $$;

-- ───────────────────────── profiles: account status ─────────────────────────
alter table public.profiles
  add column if not exists account_status     text not null default 'active',
  add column if not exists suspended_until    timestamptz,
  add column if not exists suspension_reason  text,
  add column if not exists status_changed_at  timestamptz,
  add column if not exists status_changed_by  uuid,
  add column if not exists warning_count      integer not null default 0,
  add column if not exists last_warning_at    timestamptz,
  add column if not exists last_warning_reason text;
do $$ begin
  if not exists (select 1 from pg_constraint where conname = 'profiles_account_status_valid') then
    alter table public.profiles add constraint profiles_account_status_valid check (account_status in ('active','suspended','banned'));
  end if;
  if not exists (select 1 from pg_constraint where conname = 'profiles_suspension_consistent') then
    alter table public.profiles add constraint profiles_suspension_consistent
      check ((account_status = 'suspended' or suspended_until is null) and warning_count >= 0);
  end if;
end $$;

-- ───────────────────────── helpers (state of the CALLER only) ─────────────────────────
create or replace function public.v3_effective_status(p_status text, p_until timestamptz) returns text
language sql stable set search_path = '' as $$
  select case when p_status = 'banned' then 'banned'
              when p_status = 'suspended' and (p_until is null or p_until > now()) then 'suspended'
              else 'active' end
$$;

create or replace function public.account_is_active() returns boolean
language sql stable security definer set search_path = '' as $$
  select coalesce((select public.v3_effective_status(p.account_status, p.suspended_until) = 'active'
                   from public.profiles p where p.id = auth.uid()), true)
$$;
create or replace function public.account_not_banned() returns boolean
language sql stable security definer set search_path = '' as $$
  select coalesce((select public.v3_effective_status(p.account_status, p.suspended_until) <> 'banned'
                   from public.profiles p where p.id = auth.uid()), true)
$$;
-- Role the caller may ACT with: suspended/banned accounts (and unknown users) count as 'student'.
create or replace function public.acting_role() returns text
language sql stable security definer set search_path = '' as $$
  select coalesce((select case when public.v3_effective_status(p.account_status, p.suspended_until) = 'active'
                               then p.role else 'student' end
                   from public.profiles p where p.id = auth.uid()), 'student')
$$;
create or replace function public.assert_account_active() returns void
language plpgsql stable security definer set search_path = '' as $$
declare p record; v_eff text;
begin
  if auth.uid() is null then return; end if;
  select account_status, suspended_until into p from public.profiles where id = auth.uid();
  if not found then return; end if;
  v_eff := public.v3_effective_status(p.account_status, p.suspended_until);
  if v_eff = 'banned' then
    raise exception 'ACCOUNT_BANNED: your account has been banned.' using errcode = '42501';
  elsif v_eff = 'suspended' then
    raise exception 'ACCOUNT_SUSPENDED: your account is suspended until %. You can browse but not post, message or report.',
      coalesce(to_char(p.suspended_until at time zone 'UTC', 'YYYY-MM-DD HH24:MI "UTC"'), 'further notice') using errcode = '42501';
  end if;
end $$;

-- ───────────────────────── items: moderation columns + status superset ─────────────────────────
alter table public.items
  add column if not exists moderation_status text not null default 'approved',
  add column if not exists moderated_by      uuid,
  add column if not exists moderated_at      timestamptz,
  add column if not exists moderation_reason text;
do $$
declare c record;
begin
  if not exists (select 1 from pg_constraint where conname = 'items_moderation_status_valid') then
    alter table public.items add constraint items_moderation_status_valid
      check (moderation_status in ('approved','pending','hidden','rejected'));
  end if;
  -- REPLACES the old status CHECK by a superset that adds 'inactive' (no data change; gate verified it is found exactly once)
  for c in select conname from pg_constraint
            where conrelid = 'public.items'::regclass and contype = 'c'
              and pg_get_constraintdef(oid) ~ 'status = ANY \(ARRAY\[''active''::text, ''sold''::text, ''rented''::text\]\)' loop
    execute format('alter table public.items drop constraint %I', c.conname);
  end loop;
  if not exists (select 1 from pg_constraint where conname = 'items_status_valid_v3') then
    alter table public.items add constraint items_status_valid_v3 check (status in ('active','sold','rented','inactive'));
  end if;
end $$;
create index if not exists items_moderation_status on public.items (moderation_status);

-- ───────────────────────── items: visibility policies (REPLACES "signed-in can browse") ─────────────────────────
drop policy if exists "signed-in can browse" on public.items;
drop policy if exists "v3 browse approved" on public.items;
create policy "v3 browse approved" on public.items for select to authenticated
  using (moderation_status = 'approved');
drop policy if exists "v3 owner reads own listings" on public.items;
create policy "v3 owner reads own listings" on public.items for select to authenticated
  using (seller_id = auth.uid());
drop policy if exists "v3 staff read all listings" on public.items;
create policy "v3 staff read all listings" on public.items for select to authenticated
  using ((select public.acting_role()) in ('moderator','admin'));

-- ───────────────────────── RESTRICTIVE policies: banned = no reads, suspended = read-only ─────────────────────────
do $$
declare t text; c text;
begin
  foreach t in array array['items','item_private','wishlists','conversations','messages'] loop
    execute format('drop policy if exists "v3 banned no read" on public.%I', t);
    execute format('create policy "v3 banned no read" on public.%I as restrictive for select to authenticated using ((select public.account_not_banned()))', t);
    execute format('drop policy if exists "v3 active insert" on public.%I', t);
    execute format('create policy "v3 active insert" on public.%I as restrictive for insert to authenticated with check ((select public.account_is_active()))', t);
  end loop;
  foreach t in array array['items','item_private','wishlists'] loop
    execute format('drop policy if exists "v3 active update" on public.%I', t);
    execute format('create policy "v3 active update" on public.%I as restrictive for update to authenticated using ((select public.account_is_active())) with check ((select public.account_is_active()))', t);
    execute format('drop policy if exists "v3 active delete" on public.%I', t);
    execute format('create policy "v3 active delete" on public.%I as restrictive for delete to authenticated using ((select public.account_is_active()))', t);
  end loop;
end $$;

-- ───────────────────────── items triggers ─────────────────────────
-- INSERT (definer): signed-in callers cannot choose moderation fields; suspended/banned cannot create.
create or replace function public.items_v3_insert_guard() returns trigger
language plpgsql security definer set search_path = '' as $$
begin
  if auth.uid() is null then return new; end if;
  perform public.assert_account_active();
  new.moderation_status := 'approved';
  new.moderated_by := null; new.moderated_at := null; new.moderation_reason := null;
  return new;
end $$;
drop trigger if exists items_v3_insert_guard_trg on public.items;
create trigger items_v3_insert_guard_trg before insert on public.items
  for each row execute function public.items_v3_insert_guard();

-- UPDATE (INVOKER on purpose): current_user is the role that issued the statement. Statements sent
-- through the API run as anon/authenticated; statements issued inside the staff definer functions run
-- as their owner. So an owner can NEVER change moderation columns or edit a hidden listing directly,
-- while staff functions can — and a client cannot fake current_user.
create or replace function public.items_v3_guard() returns trigger
language plpgsql set search_path = '' as $$
begin
  if current_user in ('anon', 'authenticated') then
    perform public.assert_account_active();
    if old.moderation_status in ('hidden', 'rejected') then
      raise exception 'LISTING_HIDDEN: this listing was hidden by a moderator and cannot be changed.' using errcode = '42501';
    end if;
    new.moderation_status := old.moderation_status;
    new.moderated_by := old.moderated_by;
    new.moderated_at := old.moderated_at;
    new.moderation_reason := old.moderation_reason;
  end if;
  return new;
end $$;
drop trigger if exists items_v3_guard_trg on public.items;
create trigger items_v3_guard_trg before update on public.items
  for each row execute function public.items_v3_guard();

-- DELETE (definer, ALL roles): a hidden/rejected listing is evidence and can never be deleted.
create or replace function public.items_v3_delete_guard() returns trigger
language plpgsql security definer set search_path = '' as $$
begin
  if auth.uid() is not null then perform public.assert_account_active(); end if;
  if old.moderation_status in ('hidden', 'rejected') then
    raise exception 'LISTING_HIDDEN: a hidden listing cannot be deleted.' using errcode = '23001';
  end if;
  return old;
end $$;
drop trigger if exists items_v3_delete_guard_trg on public.items;
create trigger items_v3_delete_guard_trg before delete on public.items
  for each row execute function public.items_v3_delete_guard();

-- ───────────────────────── chats / messages / contact: hidden listings and suspended users ─────────────────────────
create or replace function public.conversations_v3_guard() returns trigger
language plpgsql security definer set search_path = '' as $$
begin
  if auth.uid() is null then return new; end if;
  perform public.assert_account_active();
  if exists (select 1 from public.items i where i.id = new.item_id and i.moderation_status <> 'approved') then
    raise exception 'This listing is no longer available.' using errcode = '42501';
  end if;
  return new;
end $$;
drop trigger if exists conversations_v3_guard_trg on public.conversations;
create trigger conversations_v3_guard_trg before insert on public.conversations
  for each row execute function public.conversations_v3_guard();

create or replace function public.messages_v3_guard() returns trigger
language plpgsql security definer set search_path = '' as $$
begin
  if auth.uid() is null then return new; end if;
  perform public.assert_account_active();
  if exists (select 1 from public.conversations c join public.items i on i.id = c.item_id
              where c.id = new.conversation_id and i.moderation_status <> 'approved') then
    raise exception 'LISTING_HIDDEN: this conversation belongs to a listing that is no longer available.' using errcode = '42501';
  end if;
  return new;
end $$;
drop trigger if exists messages_v3_guard_trg on public.messages;
create trigger messages_v3_guard_trg before insert on public.messages
  for each row execute function public.messages_v3_guard();

-- get_contact(): same signature/result as V2 + hidden listing = "not found", suspended/banned refused,
-- limit via the shared limiter (40/hour, same value as V2).
create or replace function public.get_contact(p_item_id bigint)
returns table (name text, email text, phone text)
language plpgsql security definer set search_path = '' as $$
declare it record;
begin
  if auth.uid() is null then raise exception 'Sign in first.'; end if;
  perform public.assert_account_active();
  select i.status, i.moderation_status into it from public.items i where i.id = p_item_id;
  if not found or it.moderation_status <> 'approved' then raise exception 'Listing not found.'; end if;
  if it.status <> 'active' then raise exception 'This item is no longer available.'; end if;
  perform public.rate_limit_check('contact_lookup');
  return query
    select i.seller_name, coalesce(p.contact_email, ''), coalesce(p.contact_phone, '')
      from public.items i left join public.item_private p on p.item_id = i.id where i.id = p_item_id;
end $$;

-- ───────────────────────── moderation_actions (append-only) ─────────────────────────
create table if not exists public.moderation_actions (
  id             bigint generated always as identity primary key,
  created_at     timestamptz not null default now(),
  actor_id       uuid not null,
  actor_role     text not null,
  action         text not null,
  target_user_id uuid,
  listing_id     bigint,
  report_id      bigint,          -- FK to reports is added in 007
  reason         text not null,
  metadata       jsonb not null default '{}'::jsonb,
  constraint moderation_actions_action_valid check (action in (
    'listing_hidden','listing_restored','user_warned','user_suspended','user_unsuspended',
    'user_banned','user_unbanned','report_reviewing','report_resolved','report_dismissed')),
  constraint moderation_actions_reason_len check (char_length(btrim(reason)) between 3 and 1000),
  constraint moderation_actions_has_target check (target_user_id is not null or listing_id is not null or report_id is not null)
);
create index if not exists moderation_actions_created on public.moderation_actions (created_at desc);
create index if not exists moderation_actions_user on public.moderation_actions (target_user_id, created_at desc);
create index if not exists moderation_actions_listing on public.moderation_actions (listing_id);
drop trigger if exists moderation_actions_no_mutate on public.moderation_actions;
create trigger moderation_actions_no_mutate before update or delete on public.moderation_actions
  for each row execute function public.v3_block_mutation();
drop trigger if exists moderation_actions_no_truncate on public.moderation_actions;
create trigger moderation_actions_no_truncate before truncate on public.moderation_actions
  for each statement execute function public.v3_block_mutation();
alter table public.moderation_actions enable row level security;
revoke all on public.moderation_actions from public, anon, authenticated, service_role;
grant select on public.moderation_actions to authenticated;
drop policy if exists "staff read moderation actions" on public.moderation_actions;
create policy "staff read moderation actions" on public.moderation_actions for select to authenticated
  using ((select public.acting_role()) in ('moderator','admin'));

-- read policies for the audit tables created in 005
grant select on public.audit_logs, public.security_events to authenticated;
drop policy if exists "admin reads all audit" on public.audit_logs;
create policy "admin reads all audit" on public.audit_logs for select to authenticated
  using ((select public.acting_role()) = 'admin');
drop policy if exists "moderator reads moderation audit" on public.audit_logs;
create policy "moderator reads moderation audit" on public.audit_logs for select to authenticated
  using ((select public.acting_role()) = 'moderator' and category = 'moderation');
drop policy if exists "admin reads security events" on public.security_events;
create policy "admin reads security events" on public.security_events for select to authenticated
  using ((select public.acting_role()) = 'admin');

-- ───────────────────────── internal helpers for the staff functions ─────────────────────────
create or replace function public.v3_clean_reason(p_reason text, p_min integer default 3) returns text
language plpgsql immutable set search_path = '' as $$
declare v text := btrim(coalesce(p_reason, ''));
begin
  if char_length(v) < p_min or char_length(v) > 1000 then
    raise exception 'A reason of % to 1000 characters is required.', p_min using errcode = '22023';
  end if;
  return v;
end $$;

-- p_admin_only: admin required. p_write: marks the transaction as an audited RPC and applies the
-- moderator action limit. The caller's role comes from the database, never from the client.
create or replace function public.v3_staff_guard(p_admin_only boolean default false, p_write boolean default true) returns text
language plpgsql security definer set search_path = '' as $$
declare v_role text;
begin
  if auth.uid() is null then raise exception 'Not authenticated.' using errcode = '42501'; end if;
  v_role := public.acting_role();
  if v_role = 'admin' or (not p_admin_only and v_role = 'moderator') then
    if p_write then
      perform set_config('app.v3_rpc', 'on', true);          -- tells the backstop triggers this change is already audited
      if v_role = 'moderator' then perform public.rate_limit_check('moderator_action'); end if;
    end if;
    return v_role;
  end if;
  raise exception 'Insufficient privileges.' using errcode = '42501';
end $$;

create or replace function public.v3_assert_target(p_actor_role text, p_target uuid, p_target_role text) returns void
language plpgsql security definer set search_path = '' as $$
begin
  if p_target = auth.uid() then
    raise exception 'You cannot perform this action on your own account.' using errcode = '42501';
  end if;
  if p_actor_role = 'moderator' and p_target_role <> 'student' then
    raise exception 'Moderators can only act on student accounts.' using errcode = '42501';
  end if;
end $$;

create or replace function public.v3_listing_owner_check(p_actor_role text, p_seller uuid) returns void
language plpgsql security definer set search_path = '' as $$
declare v_owner_role text;
begin
  if p_seller is null then return; end if;
  select role into v_owner_role from public.profiles where id = p_seller;
  if p_actor_role = 'moderator' and coalesce(v_owner_role, 'student') <> 'student' then
    raise exception 'Moderators can only act on listings owned by students.' using errcode = '42501';
  end if;
end $$;

create or replace function public.v3_check_report_open(p_report_id bigint) returns void
language plpgsql security definer set search_path = '' as $$
begin
  if p_report_id is null then return; end if;
  if not exists (select 1 from public.reports r where r.id = p_report_id and r.status in ('pending','reviewing')) then
    raise exception 'Report not found or already closed.' using errcode = '22023';
  end if;
end $$;

create or replace function public.v3_log_action(
  p_action text, p_audit_action text, p_target_user uuid, p_listing bigint, p_report bigint,
  p_reason text, p_metadata jsonb default '{}'::jsonb)
returns bigint language plpgsql security definer set search_path = '' as $$
declare v_id bigint; v_role text;
begin
  select role into v_role from public.profiles where id = auth.uid();
  insert into public.moderation_actions (actor_id, actor_role, action, target_user_id, listing_id, report_id, reason, metadata)
  values (auth.uid(), coalesce(v_role, 'student'), p_action, p_target_user, p_listing, p_report, p_reason, coalesce(p_metadata, '{}'::jsonb))
  returning id into v_id;
  perform public.audit_write(p_audit_action, 'moderation',
          case when p_listing is not null then 'listing' else 'user' end,
          coalesce(p_listing::text, p_target_user::text), p_reason,
          coalesce(p_metadata, '{}'::jsonb) || jsonb_build_object('moderation_action_id', v_id, 'report_id', p_report), 'rpc');
  return v_id;
end $$;

-- ───────────────────────── staff RPCs: listings ─────────────────────────
create or replace function public.staff_hide_listing(p_listing_id bigint, p_reason text, p_report_id bigint default null)
returns bigint language plpgsql security definer set search_path = '' as $$
declare v_role text; v_reason text; it record;
begin
  v_role := public.v3_staff_guard();
  v_reason := public.v3_clean_reason(p_reason);
  perform public.v3_check_report_open(p_report_id);
  select i.seller_id, i.moderation_status into it from public.items i where i.id = p_listing_id for update;
  if not found then raise exception 'Listing not found.' using errcode = 'P0002'; end if;
  perform public.v3_listing_owner_check(v_role, it.seller_id);
  if it.moderation_status = 'hidden' then raise exception 'This listing is already hidden.' using errcode = '22023'; end if;
  update public.items set moderation_status = 'hidden', moderated_by = auth.uid(), moderated_at = now(), moderation_reason = v_reason
   where id = p_listing_id;
  return public.v3_log_action('listing_hidden', 'LISTING_HIDDEN', it.seller_id, p_listing_id, p_report_id, v_reason,
                              jsonb_build_object('previous_moderation_status', it.moderation_status));
end $$;

create or replace function public.staff_restore_listing(p_listing_id bigint, p_reason text, p_report_id bigint default null)
returns bigint language plpgsql security definer set search_path = '' as $$
declare v_role text; v_reason text; it record;
begin
  v_role := public.v3_staff_guard();
  v_reason := public.v3_clean_reason(p_reason);
  perform public.v3_check_report_open(p_report_id);
  select i.seller_id, i.moderation_status into it from public.items i where i.id = p_listing_id for update;
  if not found then raise exception 'Listing not found.' using errcode = 'P0002'; end if;
  perform public.v3_listing_owner_check(v_role, it.seller_id);
  if it.moderation_status not in ('hidden', 'rejected') then raise exception 'This listing is not hidden.' using errcode = '22023'; end if;
  update public.items set moderation_status = 'approved', moderated_by = auth.uid(), moderated_at = now(), moderation_reason = v_reason
   where id = p_listing_id;
  return public.v3_log_action('listing_restored', 'LISTING_RESTORED', it.seller_id, p_listing_id, p_report_id, v_reason,
                              jsonb_build_object('previous_moderation_status', it.moderation_status));
end $$;

-- ───────────────────────── staff RPCs: users ─────────────────────────
create or replace function public.staff_warn_user(p_user_id uuid, p_reason text, p_report_id bigint default null)
returns bigint language plpgsql security definer set search_path = '' as $$
declare v_role text; v_reason text; t record;
begin
  v_role := public.v3_staff_guard();
  v_reason := public.v3_clean_reason(p_reason);
  perform public.v3_check_report_open(p_report_id);
  select p.role into t from public.profiles p where p.id = p_user_id for update;
  if not found then raise exception 'User not found.' using errcode = 'P0002'; end if;
  perform public.v3_assert_target(v_role, p_user_id, t.role);
  update public.profiles set warning_count = warning_count + 1, last_warning_at = now(), last_warning_reason = v_reason where id = p_user_id;
  return public.v3_log_action('user_warned', 'USER_WARNED', p_user_id, null, p_report_id, v_reason, '{}'::jsonb);
end $$;

create or replace function public.staff_suspend_user(p_user_id uuid, p_until timestamptz, p_reason text, p_report_id bigint default null)
returns bigint language plpgsql security definer set search_path = '' as $$
declare v_role text; v_reason text; t record;
begin
  v_role := public.v3_staff_guard();
  v_reason := public.v3_clean_reason(p_reason);
  perform public.v3_check_report_open(p_report_id);
  select p.role, p.account_status, p.suspended_until into t from public.profiles p where p.id = p_user_id for update;
  if not found then raise exception 'User not found.' using errcode = 'P0002'; end if;
  perform public.v3_assert_target(v_role, p_user_id, t.role);
  if p_until is not null and p_until <= now() then raise exception 'The suspension end must be in the future.' using errcode = '22023'; end if;
  if t.account_status = 'banned' then raise exception 'This user is banned; unban first.' using errcode = '22023'; end if;
  if v_role = 'moderator' then
    if p_until is null or p_until > now() + interval '7 days' then
      raise exception 'Moderators can suspend for at most 7 days.' using errcode = '42501';
    end if;
    if t.account_status = 'suspended' and t.suspended_until is null then
      raise exception 'This user has an indefinite suspension that only an admin can change.' using errcode = '42501';
    end if;
  end if;
  update public.profiles set account_status = 'suspended', suspended_until = p_until, suspension_reason = v_reason,
         status_changed_at = now(), status_changed_by = auth.uid() where id = p_user_id;
  return public.v3_log_action('user_suspended', 'USER_SUSPENDED', p_user_id, null, p_report_id, v_reason,
                              jsonb_build_object('until', p_until, 'previous_status', t.account_status));
end $$;

create or replace function public.staff_unsuspend_user(p_user_id uuid, p_reason text)
returns bigint language plpgsql security definer set search_path = '' as $$
declare v_role text; v_reason text; t record;
begin
  v_role := public.v3_staff_guard();
  v_reason := public.v3_clean_reason(p_reason);
  select p.role, p.account_status, p.suspended_until into t from public.profiles p where p.id = p_user_id for update;
  if not found then raise exception 'User not found.' using errcode = 'P0002'; end if;
  perform public.v3_assert_target(v_role, p_user_id, t.role);
  if t.account_status <> 'suspended' then raise exception 'This user is not suspended.' using errcode = '22023'; end if;
  if v_role = 'moderator' and t.suspended_until is null then
    raise exception 'This user has an indefinite suspension that only an admin can change.' using errcode = '42501';
  end if;
  update public.profiles set account_status = 'active', suspended_until = null, suspension_reason = null,
         status_changed_at = now(), status_changed_by = auth.uid() where id = p_user_id;
  return public.v3_log_action('user_unsuspended', 'USER_UNSUSPENDED', p_user_id, null, null, v_reason, '{}'::jsonb);
end $$;

create or replace function public.admin_ban_user(p_user_id uuid, p_reason text, p_report_id bigint default null)
returns bigint language plpgsql security definer set search_path = '' as $$
declare v_role text; v_reason text; t record; v_id bigint;
begin
  v_role := public.v3_staff_guard(true);
  v_reason := public.v3_clean_reason(p_reason);
  perform public.v3_check_report_open(p_report_id);
  select p.role, p.account_status into t from public.profiles p where p.id = p_user_id for update;
  if not found then raise exception 'User not found.' using errcode = 'P0002'; end if;
  perform public.v3_assert_target(v_role, p_user_id, t.role);
  if t.account_status = 'banned' then raise exception 'This user is already banned.' using errcode = '22023'; end if;
  update public.profiles set account_status = 'banned', suspended_until = null, suspension_reason = v_reason,
         status_changed_at = now(), status_changed_by = auth.uid() where id = p_user_id;
  v_id := public.v3_log_action('user_banned', 'USER_BANNED', p_user_id, null, p_report_id, v_reason,
                               jsonb_build_object('previous_status', t.account_status));
  perform public.record_security_event(p_user_id, 'USER_BANNED', 'notice', jsonb_build_object('by', auth.uid()));
  return v_id;
end $$;

create or replace function public.admin_unban_user(p_user_id uuid, p_reason text)
returns bigint language plpgsql security definer set search_path = '' as $$
declare v_role text; v_reason text; t record;
begin
  v_role := public.v3_staff_guard(true);
  v_reason := public.v3_clean_reason(p_reason);
  select p.role, p.account_status into t from public.profiles p where p.id = p_user_id for update;
  if not found then raise exception 'User not found.' using errcode = 'P0002'; end if;
  perform public.v3_assert_target(v_role, p_user_id, t.role);
  if t.account_status <> 'banned' then raise exception 'This user is not banned.' using errcode = '22023'; end if;
  update public.profiles set account_status = 'active', suspended_until = null, suspension_reason = null,
         status_changed_at = now(), status_changed_by = auth.uid() where id = p_user_id;
  return public.v3_log_action('user_unbanned', 'USER_UNBANNED', p_user_id, null, null, v_reason, '{}'::jsonb);
end $$;

-- Role changes: admin only, never on yourself (so nobody can promote or demote themselves), and the
-- last active admin is additionally protected by a trigger below.
create or replace function public.admin_set_role(p_user_id uuid, p_new_role text, p_reason text)
returns bigint language plpgsql security definer set search_path = '' as $$
declare v_role text; v_reason text; t record; v_id bigint;
begin
  v_role := public.v3_staff_guard(true);
  v_reason := public.v3_clean_reason(p_reason);
  if p_new_role is null or p_new_role not in ('student','moderator','admin') then
    raise exception 'Invalid role.' using errcode = '22023';
  end if;
  select p.role into t from public.profiles p where p.id = p_user_id for update;
  if not found then raise exception 'User not found.' using errcode = 'P0002'; end if;
  perform public.v3_assert_target(v_role, p_user_id, t.role);       -- rejects self-targeting
  if t.role = p_new_role then raise exception 'The user already has this role.' using errcode = '22023'; end if;
  update public.profiles set role = p_new_role where id = p_user_id;  -- last-admin trigger can veto
  v_id := public.audit_write('ROLE_CHANGED', 'admin', 'user', p_user_id::text, v_reason,
                             jsonb_build_object('old_role', t.role, 'new_role', p_new_role), 'rpc');
  perform public.record_security_event(p_user_id, 'ROLE_CHANGED', case when p_new_role = 'admin' then 'warning' else 'notice' end,
                                       jsonb_build_object('old_role', t.role, 'new_role', p_new_role, 'by', auth.uid()));
  return v_id;
end $$;

-- ───────────────────────── staff read helpers (columns controlled in the function) ─────────────────────────
create or replace function public.staff_get_user(p_user_id uuid)
returns table (id uuid, display_name text, role text, account_status text, effective_status text,
               suspended_until timestamptz, suspension_reason text, warning_count integer, email text)
language plpgsql stable security definer set search_path = '' as $$
declare v_role text;
begin
  v_role := public.v3_staff_guard(false, false);
  return query
    select p.id, p.display_name, p.role, p.account_status, public.v3_effective_status(p.account_status, p.suspended_until),
           p.suspended_until, p.suspension_reason, p.warning_count,
           case when v_role = 'admin' then p.email else null end
      from public.profiles p where p.id = p_user_id;
end $$;

create or replace function public.admin_search_users(p_query text, p_limit integer default 20, p_offset integer default 0)
returns table (id uuid, display_name text, role text, account_status text, effective_status text,
               suspended_until timestamptz, warning_count integer, email text)
language plpgsql stable security definer set search_path = '' as $$
declare v_pat text;
begin
  perform public.v3_staff_guard(true, false);
  v_pat := '%' || replace(replace(replace(btrim(coalesce(p_query, '')), '\', '\\'), '%', '\%'), '_', '\_') || '%';
  return query
    select p.id, p.display_name, p.role, p.account_status, public.v3_effective_status(p.account_status, p.suspended_until),
           p.suspended_until, p.warning_count, p.email
      from public.profiles p
     where p.display_name ilike v_pat escape '\' or p.email ilike v_pat escape '\'
     order by p.display_name
     limit least(greatest(coalesce(p_limit, 20), 1), 50) offset greatest(coalesce(p_offset, 0), 0);
end $$;

-- ───────────────────────── backstop triggers: last admin + out-of-band audit ─────────────────────────
create or replace function public.profiles_last_admin_guard() returns trigger
language plpgsql security definer set search_path = '' as $$
declare v_was_active_admin boolean; v_stays boolean;
begin
  v_was_active_admin := old.role = 'admin' and public.v3_effective_status(old.account_status, old.suspended_until) = 'active';
  if not v_was_active_admin then return case when tg_op = 'DELETE' then old else new end; end if;
  v_stays := tg_op = 'UPDATE' and new.role = 'admin' and public.v3_effective_status(new.account_status, new.suspended_until) = 'active';
  if v_stays then return new; end if;
  if not exists (select 1 from public.profiles p
                  where p.id <> old.id and p.role = 'admin'
                    and public.v3_effective_status(p.account_status, p.suspended_until) = 'active') then
    raise exception 'LAST_ADMIN: this would leave the marketplace without an active admin.' using errcode = '23514',
      hint = 'Promote another admin first.';
  end if;
  return case when tg_op = 'DELETE' then old else new end;
end $$;
drop trigger if exists profiles_last_admin_guard_trg on public.profiles;
create trigger profiles_last_admin_guard_trg before update of role, account_status, suspended_until or delete on public.profiles
  for each row execute function public.profiles_last_admin_guard();

create or replace function public.profiles_audit_backstop() returns trigger
language plpgsql security definer set search_path = '' as $$
begin
  if coalesce(current_setting('app.v3_rpc', true), '') = 'on' then return null; end if;   -- already audited by an RPC
  if new.role is distinct from old.role then
    perform public.audit_write('ROLE_CHANGED', 'security', 'user', new.id::text, null,
            jsonb_build_object('old_role', old.role, 'new_role', new.role), 'direct_sql');
    perform public.record_security_event(new.id, 'ROLE_CHANGED_DIRECT', 'warning',
            jsonb_build_object('old_role', old.role, 'new_role', new.role));
  end if;
  if new.account_status is distinct from old.account_status or new.suspended_until is distinct from old.suspended_until then
    perform public.audit_write('ACCOUNT_STATUS_CHANGED', 'security', 'user', new.id::text, null,
            jsonb_build_object('old_status', old.account_status, 'new_status', new.account_status,
                               'old_until', old.suspended_until, 'new_until', new.suspended_until), 'direct_sql');
  end if;
  return null;
end $$;
drop trigger if exists profiles_audit_backstop_trg on public.profiles;
create trigger profiles_audit_backstop_trg after update of role, account_status, suspended_until on public.profiles
  for each row execute function public.profiles_audit_backstop();

create or replace function public.items_moderation_backstop() returns trigger
language plpgsql security definer set search_path = '' as $$
begin
  if coalesce(current_setting('app.v3_rpc', true), '') = 'on' then return null; end if;
  perform public.audit_write('LISTING_MODERATION_CHANGED', 'security', 'listing', new.id::text, new.moderation_reason,
          jsonb_build_object('old', old.moderation_status, 'new', new.moderation_status), 'direct_sql');
  return null;
end $$;
drop trigger if exists items_moderation_backstop_trg on public.items;
create trigger items_moderation_backstop_trg after update of moderation_status on public.items
  for each row when (old.moderation_status is distinct from new.moderation_status)
  execute function public.items_moderation_backstop();

-- ───────────────────────── EXECUTE privileges ─────────────────────────
-- internal helpers + trigger functions: nobody via the API
revoke all on function public.v3_effective_status(text, timestamptz)       from public, anon, authenticated, service_role;
revoke all on function public.v3_clean_reason(text, integer)               from public, anon, authenticated, service_role;
revoke all on function public.v3_staff_guard(boolean, boolean)             from public, anon, authenticated, service_role;
revoke all on function public.v3_assert_target(text, uuid, text)           from public, anon, authenticated, service_role;
revoke all on function public.v3_listing_owner_check(text, uuid)           from public, anon, authenticated, service_role;
revoke all on function public.v3_check_report_open(bigint)                 from public, anon, authenticated, service_role;
revoke all on function public.v3_log_action(text, text, uuid, bigint, bigint, text, jsonb) from public, anon, authenticated, service_role;
revoke all on function public.items_v3_insert_guard()        from public, anon, authenticated, service_role;
revoke all on function public.items_v3_guard()               from public, anon, authenticated, service_role;
revoke all on function public.items_v3_delete_guard()        from public, anon, authenticated, service_role;
revoke all on function public.conversations_v3_guard()       from public, anon, authenticated, service_role;
revoke all on function public.messages_v3_guard()            from public, anon, authenticated, service_role;
revoke all on function public.profiles_last_admin_guard()    from public, anon, authenticated, service_role;
revoke all on function public.profiles_audit_backstop()      from public, anon, authenticated, service_role;
revoke all on function public.items_moderation_backstop()    from public, anon, authenticated, service_role;
-- caller-state helpers (return only the CALLER's own state; needed by RLS policies and invoker triggers)
revoke all on function public.account_is_active(), public.account_not_banned(), public.acting_role(), public.assert_account_active() from public, anon;
grant execute on function public.account_is_active(), public.account_not_banned(), public.acting_role(), public.assert_account_active() to authenticated;
-- staff/admin RPCs: signed-in callers only (the role check is INSIDE each function)
revoke all on function public.staff_hide_listing(bigint, text, bigint)                    from public, anon;
revoke all on function public.staff_restore_listing(bigint, text, bigint)                 from public, anon;
revoke all on function public.staff_warn_user(uuid, text, bigint)                         from public, anon;
revoke all on function public.staff_suspend_user(uuid, timestamptz, text, bigint)         from public, anon;
revoke all on function public.staff_unsuspend_user(uuid, text)                            from public, anon;
revoke all on function public.admin_ban_user(uuid, text, bigint)                          from public, anon;
revoke all on function public.admin_unban_user(uuid, text)                                from public, anon;
revoke all on function public.admin_set_role(uuid, text, text)                            from public, anon;
revoke all on function public.staff_get_user(uuid)                                        from public, anon;
revoke all on function public.admin_search_users(text, integer, integer)                  from public, anon;
grant execute on function public.staff_hide_listing(bigint, text, bigint), public.staff_restore_listing(bigint, text, bigint),
  public.staff_warn_user(uuid, text, bigint), public.staff_suspend_user(uuid, timestamptz, text, bigint),
  public.staff_unsuspend_user(uuid, text), public.admin_ban_user(uuid, text, bigint), public.admin_unban_user(uuid, text),
  public.admin_set_role(uuid, text, text), public.staff_get_user(uuid), public.admin_search_users(text, integer, integer) to authenticated;
revoke all on function public.get_contact(bigint) from public, anon;
grant execute on function public.get_contact(bigint) to authenticated;

commit;
