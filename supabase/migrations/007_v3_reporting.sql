-- 007_v3_reporting.sql — Campus Market V3: reporting listings and users.
--
-- WHAT THIS CHANGES: new table `reports` (+ constraints, indexes, RLS, triggers), new report RPCs,
-- a foreign key moderation_actions.report_id -> reports.id, and one more BEFORE DELETE trigger on items
-- (a listing with an open report cannot be deleted). Nothing existing is modified or deleted.
-- Idempotent; one transaction. Requires 006.
--
-- Anti-abuse (all enforced by the database, not the UI):
--   * reporter_id, status, reviewed_by/at and the reported user are DERIVED by a trigger; anything the
--     client sends for them is overwritten. The reported user of a listing report is the listing owner.
--   * no self-reports and no reports on your own listing; one OPEN report per (reporter, target)
--     (partial unique indexes); 3 reports/hour and 10/day per user (rate_limit_check 'report_create');
--     suspended/banned accounts cannot report; 'other' needs a >=10 character explanation.
--   * reports can never be edited (evidence columns are frozen) or deleted; status only moves
--     pending -> reviewing -> resolved|dismissed, and closed reports are final.
--   * students read only their own reports; staff read all; nobody updates/deletes through the API.
--   * FKs are ON DELETE SET NULL plus a snapshot (target_snapshot) so evidence survives deleted users/listings.
-- SECURITY DEFINER protections: same rules as 006 (search_path = '', actor = auth.uid(), role re-checked
-- inside, moderators cannot handle reports about moderators/admins, EXECUTE only for authenticated).

begin;

-- ───────────────────────── PRE-FLIGHT GATE ─────────────────────────
do $$
begin
  if to_regclass('public.moderation_actions') is null or to_regprocedure('public.staff_hide_listing(bigint,text,bigint)') is null
     or to_regprocedure('public.acting_role()') is null
     or not exists (select 1 from information_schema.columns where table_schema = 'public' and table_name = 'items' and column_name = 'moderation_status') then
    raise exception 'MIGRATION 007 ABORTED - nothing was changed. Run 005 and 006 first.';
  end if;
end $$;

-- ───────────────────────── reports ─────────────────────────
create table if not exists public.reports (
  id               bigint generated always as identity primary key,
  reporter_id      uuid references auth.users(id) on delete set null,
  reported_user_id uuid references auth.users(id) on delete set null,
  listing_id       bigint references public.items(id) on delete set null,
  reason           text not null,
  description      text not null default '',
  status           text not null default 'pending',
  reviewed_by      uuid,
  reviewed_at      timestamptz,
  target_snapshot  jsonb not null default '{}'::jsonb,
  created_at       timestamptz not null default now(),
  constraint reports_reason_valid check (reason in ('scam','prohibited_item','misleading_information','duplicate_listing','harassment','inappropriate_content','other')),
  constraint reports_description_len check (char_length(description) <= 500),
  constraint reports_other_needs_text check (reason <> 'other' or char_length(btrim(description)) >= 10),
  constraint reports_status_valid check (status in ('pending','reviewing','resolved','dismissed')),
  constraint reports_has_target check (listing_id is not null or reported_user_id is not null or target_snapshot <> '{}'::jsonb),
  constraint reports_not_self check (reporter_id is null or reported_user_id is null or reporter_id <> reported_user_id),
  constraint reports_review_consistent check (
    (status = 'pending' and reviewed_by is null and reviewed_at is null)
    or (status <> 'pending' and reviewed_by is not null and reviewed_at is not null))
);
create index if not exists reports_status_created on public.reports (status, created_at desc);
create index if not exists reports_listing on public.reports (listing_id) where listing_id is not null;
create index if not exists reports_reported_user on public.reports (reported_user_id) where reported_user_id is not null;
create index if not exists reports_reporter on public.reports (reporter_id, created_at desc);
-- one OPEN report per reporter and target (stops repeat/identical spam)
create unique index if not exists reports_one_open_per_listing on public.reports (reporter_id, listing_id)
  where listing_id is not null and status in ('pending','reviewing');
create unique index if not exists reports_one_open_per_user on public.reports (reporter_id, reported_user_id)
  where listing_id is null and reported_user_id is not null and status in ('pending','reviewing');

-- moderation_actions.report_id can now be a real foreign key
do $$ begin
  if not exists (select 1 from pg_constraint where conname = 'moderation_actions_report_fkey') then
    alter table public.moderation_actions add constraint moderation_actions_report_fkey
      foreign key (report_id) references public.reports(id);
  end if;
end $$;

-- ───────────────────────── triggers ─────────────────────────
create or replace function public.reports_before_insert() returns trigger
language plpgsql security definer set search_path = '' as $$
declare v_uid uuid := auth.uid(); it record; u record;
begin
  if v_uid is null then return new; end if;                 -- SQL Editor / service role: trusted
  perform public.assert_account_active();
  perform public.rate_limit_check('report_create');
  new.reporter_id := v_uid;                                 -- never trust the client for any of these
  new.status := 'pending'; new.reviewed_by := null; new.reviewed_at := null; new.created_at := now();
  new.description := btrim(coalesce(new.description, ''));
  if new.listing_id is not null then
    select i.seller_id, i.title, i.seller_name, i.moderation_status into it from public.items i where i.id = new.listing_id;
    if not found or it.moderation_status <> 'approved' then raise exception 'Listing not found.' using errcode = 'P0002'; end if;
    new.reported_user_id := it.seller_id;                   -- derived from the listing, not from the request
    new.target_snapshot := jsonb_build_object('type', 'listing', 'listing_title', it.title, 'reported_user_name', it.seller_name);
  else
    if new.reported_user_id is null then raise exception 'A report needs a listing or a user.' using errcode = '23514'; end if;
    select p.display_name into u from public.profiles p where p.id = new.reported_user_id;
    if not found then raise exception 'User not found.' using errcode = 'P0002'; end if;
    new.target_snapshot := jsonb_build_object('type', 'user', 'reported_user_name', u.display_name);
  end if;
  if new.reported_user_id is not null and new.reported_user_id = v_uid then
    raise exception 'You cannot report yourself or your own listing.' using errcode = '23514';
  end if;
  return new;
end $$;
drop trigger if exists reports_before_insert_trg on public.reports;
create trigger reports_before_insert_trg before insert on public.reports
  for each row execute function public.reports_before_insert();

-- signal for V4: three open reports on one target within 24 hours (accepted request, so it persists)
create or replace function public.reports_after_insert() returns trigger
language plpgsql security definer set search_path = '' as $$
declare n integer;
begin
  select count(*) into n from public.reports r
   where r.status in ('pending','reviewing') and r.created_at > now() - interval '24 hours'
     and case when new.reported_user_id is not null then r.reported_user_id = new.reported_user_id else r.listing_id = new.listing_id end;
  if n = 3 then
    perform public.record_security_event(new.reported_user_id, 'REPORT_THRESHOLD', 'notice',
            jsonb_build_object('listing_id', new.listing_id, 'open_reports_24h', n));
  end if;
  return null;
end $$;
drop trigger if exists reports_after_insert_trg on public.reports;
create trigger reports_after_insert_trg after insert on public.reports
  for each row execute function public.reports_after_insert();

-- Evidence is immutable; only the review workflow may change a report (INVOKER function: no privileges needed).
create or replace function public.reports_guard_update() returns trigger
language plpgsql set search_path = '' as $$
begin
  if new.id is distinct from old.id or new.reason is distinct from old.reason or new.description is distinct from old.description
     or new.created_at is distinct from old.created_at or new.target_snapshot is distinct from old.target_snapshot then
    raise exception 'Report evidence cannot be changed.' using errcode = '42501';
  end if;
  -- foreign-key actions (ON DELETE SET NULL) may only clear these columns, never re-point them
  if (new.reporter_id is distinct from old.reporter_id and new.reporter_id is not null)
     or (new.reported_user_id is distinct from old.reported_user_id and new.reported_user_id is not null)
     or (new.listing_id is distinct from old.listing_id and new.listing_id is not null) then
    raise exception 'Report targets cannot be changed.' using errcode = '42501';
  end if;
  if old.status in ('resolved', 'dismissed')
     and (new.status is distinct from old.status or new.reviewed_by is distinct from old.reviewed_by or new.reviewed_at is distinct from old.reviewed_at) then
    raise exception 'A closed report is final.' using errcode = '42501';
  end if;
  if new.status is distinct from old.status and not (
       (old.status = 'pending'   and new.status in ('reviewing', 'resolved', 'dismissed'))
    or (old.status = 'reviewing' and new.status in ('resolved', 'dismissed'))) then
    raise exception 'Invalid report status change (% -> %).', old.status, new.status using errcode = '23514';
  end if;
  return new;
end $$;
drop trigger if exists reports_guard_update_trg on public.reports;
create trigger reports_guard_update_trg before update on public.reports
  for each row execute function public.reports_guard_update();

drop trigger if exists reports_no_delete on public.reports;
create trigger reports_no_delete before delete on public.reports
  for each row execute function public.v3_block_mutation();
drop trigger if exists reports_no_truncate on public.reports;
create trigger reports_no_truncate before truncate on public.reports
  for each statement execute function public.v3_block_mutation();

-- A listing with an open (pending/reviewing) report cannot be deleted by anyone: sellers mark it sold/rented/inactive.
create or replace function public.items_v3_report_delete_guard() returns trigger
language plpgsql security definer set search_path = '' as $$
begin
  if exists (select 1 from public.reports r where r.listing_id = old.id and r.status in ('pending', 'reviewing')) then
    raise exception 'LISTING_REPORTED: this listing has an open report and cannot be deleted. Mark it sold, rented or inactive instead.'
      using errcode = '23001';
  end if;
  return old;
end $$;
drop trigger if exists items_v3_report_delete_guard_trg on public.items;
create trigger items_v3_report_delete_guard_trg before delete on public.items
  for each row execute function public.items_v3_report_delete_guard();

-- ───────────────────────── RLS ─────────────────────────
alter table public.reports enable row level security;
revoke all on public.reports from public, anon, authenticated, service_role;
grant select, insert on public.reports to authenticated;       -- no UPDATE / DELETE / TRUNCATE for any API role
drop policy if exists "reports insert own" on public.reports;
create policy "reports insert own" on public.reports for insert to authenticated
  with check (reporter_id = auth.uid() and (select public.account_is_active()));
drop policy if exists "reports read own" on public.reports;
create policy "reports read own" on public.reports for select to authenticated
  using (reporter_id = auth.uid());
drop policy if exists "reports staff read all" on public.reports;
create policy "reports staff read all" on public.reports for select to authenticated
  using ((select public.acting_role()) in ('moderator','admin'));
drop policy if exists "v3 banned no read" on public.reports;
create policy "v3 banned no read" on public.reports as restrictive for select to authenticated
  using ((select public.account_not_banned()));
drop policy if exists "v3 banned no insert" on public.reports;
create policy "v3 banned no insert" on public.reports as restrictive for insert to authenticated
  with check ((select public.account_not_banned()));

-- ───────────────────────── staff RPCs ─────────────────────────
create or replace function public.v3_close_report(p_report_id bigint, p_new_status text, p_reason text)
returns bigint language plpgsql security definer set search_path = '' as $$
declare v_role text; v_reason text; r record; v_trole text;
begin
  v_role := public.v3_staff_guard();
  v_reason := public.v3_clean_reason(p_reason);
  select x.status, x.reported_user_id, x.listing_id into r from public.reports x where x.id = p_report_id for update;
  if not found then raise exception 'Report not found.' using errcode = 'P0002'; end if;
  if v_role = 'moderator' and r.reported_user_id is not null then
    select role into v_trole from public.profiles where id = r.reported_user_id;
    if coalesce(v_trole, 'student') <> 'student' then
      raise exception 'Reports about moderators or admins must be handled by an admin.' using errcode = '42501';
    end if;
  end if;
  if r.status not in ('pending', 'reviewing') then raise exception 'This report is already closed.' using errcode = '22023'; end if;
  update public.reports set status = p_new_status, reviewed_by = auth.uid(), reviewed_at = now() where id = p_report_id;
  return public.v3_log_action(case p_new_status when 'resolved' then 'report_resolved' else 'report_dismissed' end,
                              case p_new_status when 'resolved' then 'REPORT_RESOLVED' else 'REPORT_DISMISSED' end,
                              r.reported_user_id, r.listing_id, p_report_id, v_reason, jsonb_build_object('previous_status', r.status));
end $$;

create or replace function public.staff_dismiss_report(p_report_id bigint, p_reason text) returns bigint
language sql security definer set search_path = '' as $$ select public.v3_close_report(p_report_id, 'dismissed', p_reason) $$;
create or replace function public.staff_resolve_report(p_report_id bigint, p_reason text) returns bigint
language sql security definer set search_path = '' as $$ select public.v3_close_report(p_report_id, 'resolved', p_reason) $$;

create or replace function public.staff_claim_report(p_report_id bigint) returns bigint
language plpgsql security definer set search_path = '' as $$
declare v_role text; r record; v_trole text;
begin
  v_role := public.v3_staff_guard();
  select x.status, x.reported_user_id, x.listing_id into r from public.reports x where x.id = p_report_id for update;
  if not found then raise exception 'Report not found.' using errcode = 'P0002'; end if;
  if v_role = 'moderator' and r.reported_user_id is not null then
    select role into v_trole from public.profiles where id = r.reported_user_id;
    if coalesce(v_trole, 'student') <> 'student' then
      raise exception 'Reports about moderators or admins must be handled by an admin.' using errcode = '42501';
    end if;
  end if;
  if r.status <> 'pending' then raise exception 'Only a pending report can be claimed.' using errcode = '22023'; end if;
  update public.reports set status = 'reviewing', reviewed_by = auth.uid(), reviewed_at = now() where id = p_report_id;
  return public.v3_log_action('report_reviewing', 'REPORT_REVIEWING', r.reported_user_id, r.listing_id, p_report_id,
                              'Report claimed for review', '{}'::jsonb);
end $$;

-- ───────────────────────── EXECUTE privileges ─────────────────────────
revoke all on function public.reports_before_insert(), public.reports_after_insert(), public.reports_guard_update(),
  public.items_v3_report_delete_guard() from public, anon, authenticated, service_role;
revoke all on function public.v3_close_report(bigint, text, text) from public, anon, authenticated, service_role;
revoke all on function public.staff_dismiss_report(bigint, text), public.staff_resolve_report(bigint, text), public.staff_claim_report(bigint) from public, anon;
grant execute on function public.staff_dismiss_report(bigint, text), public.staff_resolve_report(bigint, text), public.staff_claim_report(bigint) to authenticated;

commit;
