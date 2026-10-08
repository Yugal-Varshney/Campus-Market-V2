-- 009_v3_rate_limits_hardening.sql — Campus Market V3: abuse limits + reserved display names.
--
-- WHAT THIS CHANGES:
--   ADDITIVE: BEFORE INSERT limit triggers on items / conversations / messages; reserved-name functions
--     and a BEFORE INSERT trigger on auth.users; a manual cleanup function.
--   ALTERS (policy text only, same policy names): the two V2 storage policies "upload to own folder" and
--     "delete own photos" on storage.objects now ALSO require an active (non-suspended) account, and
--     uploads additionally pass the photo_upload limit. No other storage policy is touched.
--   Existing data is not modified. Idempotent; one transaction. Requires 005 and 006.
--
-- HOW EACH LIMIT IS CALCULATED (see rate_limit_check in 005): user = auth.uid() from the signed JWT;
-- time = now() on the database server; the window slides: count of ACCEPTED events by that user for that
-- action with created_at > now() - window. A request that would exceed any window is rejected with
-- SQLSTATE 54000 'RATE_LIMIT: ...' and records nothing. A per-(user,action) advisory lock makes
-- concurrent requests exact. Rules live in public.rate_limit_rules (edit there; no redeploy needed):
--   listing_create 5/hour + 20/day · chat_start 20/day · message_send 60/10 min · photo_upload 30/hour
--   report_create 3/hour + 10/day (007) · contact_lookup 40/hour (006) · moderator_action 200/hour (staff RPCs)
-- Client timestamps and client-supplied user ids are never consulted.
-- SECURITY DEFINER protections: search_path = '', actor = auth.uid(), EXECUTE revoked from PUBLIC/anon/
-- authenticated for internal functions. The only API-callable additions are two harmless pure/caller-only
-- helpers (is_display_name_reserved, v3_storage_upload_check — see their comments).
-- Reserved names: comparison ignores case, spaces, punctuation and simple look-alike digits/symbols
-- (0->o 1->i 3->e 4->a 5->s 7->t @->a $->s). It does NOT handle non-Latin look-alike letters.

begin;

-- ───────────────────────── PRE-FLIGHT GATE ─────────────────────────
do $$
declare bad text; v_owner oid;
begin
  if to_regprocedure('public.rate_limit_check(text)') is null or to_regprocedure('public.items_v3_insert_guard()') is null
     or to_regprocedure('public.account_is_active()') is null then
    raise exception 'MIGRATION 009 ABORTED - nothing was changed. Run 005 and 006 first.';
  end if;
  if not exists (select 1 from pg_policies where schemaname = 'storage' and tablename = 'objects' and policyname = 'upload to own folder')
     or not exists (select 1 from pg_policies where schemaname = 'storage' and tablename = 'objects' and policyname = 'delete own photos') then
    raise exception 'MIGRATION 009 ABORTED - nothing was changed. The V2 storage policies "upload to own folder"/"delete own photos" are missing (run V2 002).';
  end if;
  select string_agg(format('"%s" (%s, roles=%s)', policyname, cmd, roles::text), '; ' order by policyname) into bad
    from pg_policies
   where schemaname = 'storage' and tablename = 'objects' and cmd in ('INSERT','UPDATE','DELETE','ALL')
     and policyname not in ('upload to own folder', 'delete own photos');
  if bad is not null then
    raise exception 'MIGRATION 009 ABORTED - nothing was changed. Unexpected storage.objects write policy: %', bad
      using hint = 'An extra permissive policy would defeat the suspension/upload limits. Drop it yourself, then run this file again.';
  end if;
  select relowner into v_owner from pg_class where oid = 'storage.objects'::regclass;
  if not pg_has_role(current_user, v_owner, 'USAGE') then
    raise exception 'MIGRATION 009 ABORTED - nothing was changed. The current role (%) cannot alter policies on storage.objects.', current_user;
  end if;
end $$;

-- ───────────────────────── limit triggers (all definer, signed-in callers only) ─────────────────────────
create or replace function public.items_v3_limits() returns trigger
language plpgsql security definer set search_path = '' as $$
begin
  if auth.uid() is not null then perform public.rate_limit_check('listing_create'); end if;
  return new;
end $$;
drop trigger if exists items_v3_limits_trg on public.items;
create trigger items_v3_limits_trg before insert on public.items for each row execute function public.items_v3_limits();

create or replace function public.conversations_v3_limits() returns trigger
language plpgsql security definer set search_path = '' as $$
begin
  if auth.uid() is not null then perform public.rate_limit_check('chat_start'); end if;
  return new;
end $$;
drop trigger if exists conversations_v3_limits_trg on public.conversations;
create trigger conversations_v3_limits_trg before insert on public.conversations for each row execute function public.conversations_v3_limits();

create or replace function public.messages_v3_limits() returns trigger
language plpgsql security definer set search_path = '' as $$
begin
  if auth.uid() is not null then perform public.rate_limit_check('message_send'); end if;
  return new;
end $$;
drop trigger if exists messages_v3_limits_trg on public.messages;
create trigger messages_v3_limits_trg before insert on public.messages for each row execute function public.messages_v3_limits();

-- ───────────────────────── photo uploads: suspended users + 30/hour ─────────────────────────
-- Callable by signed-in users (policies run as the caller). It only counts/limits the CALLER's own
-- uploads and returns true; calling it by hand can at most use up your own quota.
create or replace function public.v3_storage_upload_check() returns boolean
language plpgsql volatile security definer set search_path = '' as $$
begin
  perform public.assert_account_active();
  perform public.rate_limit_check('photo_upload');
  return true;
end $$;
revoke all on function public.v3_storage_upload_check() from public, anon;
grant execute on function public.v3_storage_upload_check() to authenticated;

alter policy "upload to own folder" on storage.objects
  with check (bucket_id = 'item-images'
              and (storage.foldername(name))[1] = auth.uid()::text
              and (select public.account_is_active())
              and public.v3_storage_upload_check());
alter policy "delete own photos" on storage.objects
  using (bucket_id = 'item-images'
         and (storage.foldername(name))[1] = auth.uid()::text
         and (select public.account_is_active()));

-- ───────────────────────── reserved display names ─────────────────────────
create or replace function public.v3_normalize_name(p_name text) returns text
language sql immutable set search_path = '' as $$
  select regexp_replace(translate(lower(coalesce(p_name, '')), '013457@$', 'oieastas'), '[^a-z0-9]', '', 'g')
$$;

-- Pure function (no table access; SECURITY DEFINER only so anon may call it without being able to run the
-- internal normaliser): lets the sign-up page give a friendly message before calling Auth.
create or replace function public.is_display_name_reserved(p_name text) returns boolean
language plpgsql immutable security definer set search_path = '' as $$
declare
  -- two views of the name: plain (keeps real digits, e.g. "admin1") and look-alike-normalised ("4dm1n" -> "admin")
  variants text[] := array[regexp_replace(lower(coalesce(p_name, '')), '[^a-z0-9]', '', 'g'), public.v3_normalize_name(p_name)];
  n text; v text; prev text; tok text;
  tokens text[] := array['administrator', 'campusmarket', 'moderator', 'support', 'system', 'admin'];
begin
  foreach n in array variants loop
    if n = '' then continue; end if;
    v := n;
    loop
      prev := v;
      foreach tok in array tokens loop v := replace(v, tok, ''); end loop;
      exit when v = prev;
    end loop;
    -- reserved when the name is made ONLY of reserved words (optionally followed by digits)
    if v <> n and (v = '' or v ~ '^[0-9]+$') then return true; end if;
  end loop;
  return false;
end $$;
revoke all on function public.v3_normalize_name(text) from public, anon, authenticated, service_role;
revoke all on function public.is_display_name_reserved(text) from public;
grant execute on function public.is_display_name_reserved(text) to anon, authenticated;

create or replace function public.check_reserved_display_name() returns trigger
language plpgsql security definer set search_path = '' as $$
begin
  if public.is_display_name_reserved(new.raw_user_meta_data ->> 'display_name') then
    raise exception 'RESERVED_NAME: that display name is reserved. Please choose another.' using errcode = '22023';
  end if;
  return new;
end $$;
revoke all on function public.check_reserved_display_name() from public, anon, authenticated, service_role;
drop trigger if exists reserved_display_name_only on auth.users;
create trigger reserved_display_name_only before insert on auth.users
  for each row execute function public.check_reserved_display_name();

-- ───────────────────────── manual cleanup (not executable via the API) ─────────────────────────
-- Run from the SQL Editor now and then (or schedule with pg_cron if you enable it):
--   select public.v3_purge_old_events();
-- Rate-limit events are also trimmed per user on every check; this removes idle users' leftovers and the
-- V2 contact_requests rows (the V2 counter table, no longer written since 006).
create or replace function public.v3_purge_old_events(p_older_than interval default interval '2 days') returns jsonb
language plpgsql security definer set search_path = '' as $$
declare a bigint; b bigint := 0;
begin
  delete from public.rate_limit_events where created_at < now() - p_older_than;
  get diagnostics a = row_count;
  if to_regclass('public.contact_requests') is not null then
    delete from public.contact_requests where created_at < now() - p_older_than;
    get diagnostics b = row_count;
  end if;
  return jsonb_build_object('rate_limit_events_deleted', a, 'contact_requests_deleted', b);
end $$;
revoke all on function public.v3_purge_old_events(interval) from public, anon, authenticated, service_role;
revoke all on function public.items_v3_limits(), public.conversations_v3_limits(), public.messages_v3_limits() from public, anon, authenticated, service_role;

commit;
