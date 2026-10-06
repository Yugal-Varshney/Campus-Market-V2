-- 002_security_fixes.sql — IIPS Market V2 (SECURITY ONLY)
--
-- WHAT THIS FILE CHANGES (read before running):
--   It does NOT modify, delete or rewrite any existing ROW data in your app tables (items,
--   item_private, profiles, wishlists, conversations, messages) or in auth.users / storage.objects.
--   FIRST STATEMENT = PRE-FLIGHT GATE: if any storage.objects policy that can INSERT/UPDATE/DELETE/ALL
--   exists besides "students upload photos" (dropped below), "upload to own folder" and
--   "delete own photos", the whole migration ABORTS before changing anything and names the policy.
--   Unknown policies are never dropped silently.
--   It DOES change database and storage CONFIGURATION and PRIVILEGES:
--     * Privileges: REVOKEs INSERT/UPDATE/DELETE on public.profiles from anon + authenticated;
--       REVOKEs EXECUTE on get_contact() from PUBLIC + anon and GRANTs it to authenticated only.
--     * Storage configuration: UPDATES the existing row in storage.buckets for 'item-images'
--       (file_size_limit = 5 MB, allowed_mime_types = jpeg/png/webp); DROPS the permissive V1
--       storage policy "students upload photos" and CREATES stricter upload/delete policies.
--     * Functions replaced in place (create or replace): check_college_email, handle_new_user,
--       get_contact. Triggers created/re-created: college_email_only (insert), college_email_only_update,
--       items_guard_trg, item_private_guard_trg, conversations_guard_trg, items_block_delete_with_chats_trg.
--     * RLS + trigger: adds the policy "sellers delete own" on items AND a BEFORE DELETE trigger
--       (items_block_delete_with_chats_trg). An owner can delete a listing only if it has NO
--       conversations; otherwise the delete is rejected and nothing is removed (the seller should
--       mark it sold/rented instead). This applies to every role, including the SQL Editor, so a
--       listing's chats and messages are never destroyed as a side effect. Deleting a listing with
--       no conversations removes only its own item_private and wishlist rows (V1 cascade).
--     * New objects: tables allowed_email_domains and contact_requests (both start empty, RLS on,
--       no client policies); CHECK constraints added as NOT VALID.
--   NOT VALID means existing rows are not checked, but any later UPDATE of a row that violates a
--   constraint (for example marking an old listing sold) will be REJECTED. Run 001 section 8 first.
--   New rows written by signed-in users (not by the SQL Editor) have seller/buyer identity, names,
--   contact email and created_at set by triggers, regardless of what the client sends.
--
-- Re-runnable: every statement is idempotent (verified by running it twice on a V1-shaped database).
-- Run order: 001 (read-only audit) -> 002 (this file) -> 003 (functional/schema changes).
-- Run 001 first and resolve every DANGER row — in particular any unexpected storage WRITE policy
-- (Postgres ORs policies together, so an extra permissive one would stay active next to the new ones).
--
-- Fixes: #1 chat seller spoofing   #2 storage abuse        #3 name spoofing
--        #4 listing tampering      #5 server-side checks   #6 email-change bypass
--        #7 get_contact scraping   #11 owner delete (only when no chats)   + profiles write lock (role safety)
--
-- Service-role key: nothing here uses or needs it, and the Next.js app never reads it.
-- (SECURITY DEFINER functions run with their owner's privileges inside Postgres; that is not a key.)

begin;

-- ───────────────────────── PRE-FLIGHT GATE: unexpected storage write policies ─────────────────────────
-- Postgres ORs policies together, so one extra permissive INSERT/UPDATE/DELETE/ALL policy on
-- storage.objects would stay active next to the strict ones below and defeat them.
-- This block runs BEFORE anything else. It never drops an unknown policy: it aborts and names it.
do $$
declare found text;
begin
  select string_agg(format('"%s" (%s, roles=%s)', policyname, cmd, roles::text), '; ' order by policyname)
    into found
  from pg_policies
  where schemaname = 'storage' and tablename = 'objects'
    and cmd in ('INSERT', 'UPDATE', 'DELETE', 'ALL')
    and policyname not in ('students upload photos',   -- V1 policy: dropped by this migration
                           'upload to own folder',     -- created by this migration
                           'delete own photos');       -- created by this migration
  if found is not null then
    raise exception 'MIGRATION 002 ABORTED - nothing was changed. Unexpected storage.objects write policy found: %', found
      using hint = 'Review it in Supabase -> Storage -> Policies. If it is not needed, drop it yourself '
                   '(drop policy "<name>" on storage.objects;) and run this file again.';
  end if;
end $$;

-- ───────────────────────── Profiles are not writable by users (blocks role escalation) ─────────────────────────
-- V1 already had no INSERT/UPDATE/DELETE policy on profiles; this also removes the table
-- privileges, so even a future careless policy cannot let a student edit a profile.
-- New profiles are created by the handle_new_user() trigger (security definer), unaffected.
revoke insert, update, delete on public.profiles from anon, authenticated;

-- ───────────────────────── College email rules ─────────────────────────
-- Format check stays. Add an OPTIONAL allow-list: while the table is empty, any
-- well-formed college-style address works (V1 behaviour). Once you insert rows, only
-- those domains (and their subdomains) can register.
create table if not exists public.allowed_email_domains (
  domain text primary key check (domain = lower(domain)),
  note text,
  created_at timestamptz not null default now()
);
alter table public.allowed_email_domains enable row level security;  -- no policies: invisible to clients
-- Example (do NOT add a fake list): insert into public.allowed_email_domains (domain) values ('iips.edu.in');

create or replace function public.check_college_email() returns trigger
language plpgsql security definer set search_path = public as $$
declare dom text;
begin
  if tg_op = 'UPDATE' and new.email is not distinct from old.email then return new; end if;
  if new.email is null
     or new.email !~* '@[^@[:space:]]+\.(edu(\.[a-z]{2})?|ac\.[a-z]{2})$' then
    raise exception 'Use your college email (.edu or .ac.xx).';
  end if;
  dom := lower(split_part(new.email, '@', 2));
  if exists (select 1 from public.allowed_email_domains)
     and not exists (select 1 from public.allowed_email_domains d
                     where dom = d.domain or dom like '%.' || d.domain) then
    raise exception 'Your college is not on the approved list yet.';
  end if;
  return new;
end $$;

drop trigger if exists college_email_only on auth.users;
create trigger college_email_only before insert on auth.users
  for each row execute function public.check_college_email();
-- NEW: the same rule when an existing user changes their email (V1 only checked sign-up)
drop trigger if exists college_email_only_update on auth.users;
create trigger college_email_only_update before update of email on auth.users
  for each row execute function public.check_college_email();

-- Clean display names on sign-up (trimmed, max 60 chars)
create or replace function public.handle_new_user() returns trigger
language plpgsql security definer set search_path = public as $$
begin
  insert into public.profiles (id, display_name, email)
  values (new.id,
          coalesce(nullif(left(btrim(new.raw_user_meta_data->>'display_name'), 60), ''), 'Student'),
          new.email);
  return new;
end $$;

-- ───────────────────────── items: ownership, names, images ─────────────────────────
create or replace function public.items_guard() returns trigger
language plpgsql security definer set search_path = public as $$
declare uid uuid := auth.uid();
begin
  if uid is null then return new; end if;                 -- SQL editor / service role: untouched
  if tg_op = 'INSERT' then
    new.seller_id := uid;
    select display_name into new.seller_name from public.profiles where id = uid;
    new.seller_name := coalesce(new.seller_name, 'Student');
    new.created_at := now();
    new.status := 'active';
  else
    new.seller_id  := old.seller_id;                       -- cannot be reassigned
    new.seller_name := old.seller_name;                    -- cannot be spoofed
    new.created_at := old.created_at;                      -- cannot "bump" a listing
  end if;
  -- Photos must be a file inside the caller's own folder of the item-images bucket.
  if new.image_url is not null and (tg_op = 'INSERT' or new.image_url is distinct from old.image_url) then
    if new.image_url !~ ('^https://[^/]+/storage/v1/object/public/item-images/' || uid::text || '/[A-Za-z0-9._-]+$') then
      raise exception 'Invalid image location.';
    end if;
  end if;
  return new;
end $$;
drop trigger if exists items_guard_trg on public.items;
create trigger items_guard_trg before insert or update on public.items
  for each row execute function public.items_guard();

-- Owners can delete their own listings (V1 had no DELETE policy) - but see the trigger below
drop policy if exists "sellers delete own" on public.items;
create policy "sellers delete own" on public.items for delete to authenticated
  using (seller_id = auth.uid());

-- A listing that has conversations can NEVER be deleted: the V1 foreign keys (on delete cascade) would
-- silently destroy the chat and its messages for both people. The check runs in the database
-- (SECURITY DEFINER, so row level security cannot hide a conversation from it) and applies to every
-- role. Sellers should mark such a listing sold/rented instead. To remove one deliberately an
-- administrator must first disable this trigger on purpose:
--   alter table public.items disable trigger items_block_delete_with_chats_trg;
create or replace function public.items_block_delete_with_chats() returns trigger
language plpgsql security definer set search_path = public as $$
begin
  if exists (select 1 from public.conversations where item_id = old.id) then
    raise exception 'This listing has conversations and cannot be deleted. Mark it as sold or rented instead.'
      using errcode = 'restrict_violation',
            hint = 'Existing conversations and messages are never deleted by deleting a listing.';
  end if;
  return old;
end $$;
drop trigger if exists items_block_delete_with_chats_trg on public.items;
create trigger items_block_delete_with_chats_trg before delete on public.items
  for each row execute function public.items_block_delete_with_chats();

-- Contact email always comes from the owner's profile, not from the request body
create or replace function public.item_private_guard() returns trigger
language plpgsql security definer set search_path = public as $$
begin
  if auth.uid() is null then return new; end if;
  select email into new.contact_email from public.profiles where id = auth.uid();
  new.contact_email := coalesce(new.contact_email, '');
  return new;
end $$;
drop trigger if exists item_private_guard_trg on public.item_private;
create trigger item_private_guard_trg before insert or update on public.item_private
  for each row execute function public.item_private_guard();

-- ───────────────────────── Server-side validation (NOT VALID = existing rows untouched) ─────────────────────────
do $$ begin
  if not exists (select 1 from pg_constraint where conname = 'items_title_len') then
    alter table public.items add constraint items_title_len
      check (char_length(btrim(title)) between 3 and 120) not valid;
  end if;
  if not exists (select 1 from pg_constraint where conname = 'items_description_len') then
    alter table public.items add constraint items_description_len
      check (char_length(description) <= 1000) not valid;
  end if;
  if not exists (select 1 from pg_constraint where conname = 'items_condition_valid') then
    alter table public.items add constraint items_condition_valid
      check (condition_label in ('new','like-new','good','fair')) not valid;
  end if;
  if not exists (select 1 from pg_constraint where conname = 'item_private_phone_format') then
    alter table public.item_private add constraint item_private_phone_format
      check (contact_phone = '' or contact_phone ~ '^[0-9+()[:space:]-]{7,20}$') not valid;
  end if;
  if not exists (select 1 from pg_constraint where conname = 'messages_body_len') then
    alter table public.messages add constraint messages_body_len
      check (char_length(body) <= 1000) not valid;
  end if;
end $$;
-- After 001 section 8 shows no violating rows you may run, e.g.:
--   alter table public.items validate constraint items_title_len;

-- ───────────────────────── Conversations: seller comes from the listing, never the client ─────────────────────────
create or replace function public.conversations_guard() returns trigger
language plpgsql security definer set search_path = public as $$
declare it record;
begin
  if auth.uid() is null then return new; end if;
  select seller_id, status into it from public.items where id = new.item_id;
  if not found then raise exception 'Listing not found.'; end if;
  if it.seller_id is null then raise exception 'This is a showcase listing and cannot be messaged.'; end if;
  if it.status <> 'active' then raise exception 'This item is no longer available.'; end if;
  if it.seller_id = auth.uid() then raise exception 'You cannot start a chat on your own listing.'; end if;
  new.buyer_id  := auth.uid();
  new.seller_id := it.seller_id;
  select display_name into new.buyer_name from public.profiles where id = auth.uid();
  new.buyer_name := coalesce(new.buyer_name, 'Student');
  return new;
end $$;
drop trigger if exists conversations_guard_trg on public.conversations;
create trigger conversations_guard_trg before insert on public.conversations
  for each row execute function public.conversations_guard();

-- ───────────────────────── get_contact(): signed-in only, rate-limited ─────────────────────────
create table if not exists public.contact_requests (
  id bigint generated always as identity primary key,
  user_id uuid not null,
  item_id bigint not null,
  created_at timestamptz not null default now()
);
alter table public.contact_requests enable row level security;   -- no policies: only the function writes
create index if not exists contact_requests_user_time on public.contact_requests (user_id, created_at desc);

create or replace function public.get_contact(p_item_id bigint)
returns table (name text, email text, phone text)
language plpgsql security definer set search_path = public as $$
begin
  if auth.uid() is null then raise exception 'Sign in first.'; end if;
  if not exists (select 1 from items where id = p_item_id) then raise exception 'Listing not found.'; end if;
  if not exists (select 1 from items where id = p_item_id and status = 'active') then
    raise exception 'This item is no longer available.';
  end if;
  if (select count(*) from contact_requests
      where user_id = auth.uid() and created_at > now() - interval '1 hour') >= 40 then
    raise exception 'Too many contact lookups. Try again later.';
  end if;
  insert into contact_requests (user_id, item_id) values (auth.uid(), p_item_id);
  return query select i.seller_name, coalesce(p.contact_email, ''), coalesce(p.contact_phone, '')
    from items i left join item_private p on p.item_id = i.id where i.id = p_item_id;
end $$;
revoke all on function public.get_contact(bigint) from public, anon;
grant execute on function public.get_contact(bigint) to authenticated;

-- ───────────────────────── Storage: own folder only, size + type limits ─────────────────────────
update storage.buckets
   set file_size_limit = 5242880,
       allowed_mime_types = array['image/jpeg','image/png','image/webp']
 where id = 'item-images';

drop policy if exists "students upload photos" on storage.objects;
drop policy if exists "upload to own folder" on storage.objects;
create policy "upload to own folder" on storage.objects for insert to authenticated
  with check (bucket_id = 'item-images' and (storage.foldername(name))[1] = auth.uid()::text);
drop policy if exists "delete own photos" on storage.objects;
create policy "delete own photos" on storage.objects for delete to authenticated
  using (bucket_id = 'item-images' and (storage.foldername(name))[1] = auth.uid()::text);
-- (no UPDATE policy on purpose: files can't be overwritten; replace = upload new + delete old)

commit;
