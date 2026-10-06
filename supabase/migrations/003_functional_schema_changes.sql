-- 003_functional_schema_changes.sql — IIPS Market V2 (FUNCTIONAL / SCHEMA ONLY)
-- Additive and re-runnable. Run AFTER 002_security_fixes.sql. Nothing is dropped or rewritten.
--
-- FIRST STATEMENT = PRE-FLIGHT GATE: aborts (changing nothing) unless 002's protections are in place:
--   RLS on profiles; anon and authenticated have no INSERT/UPDATE/DELETE (table OR column level) on
--   profiles; no permissive write policy exists on profiles; RLS is on for messages and conversations.
--
-- Adds: role column (student|moderator|admin), indexes for paginated queries,
--       Realtime publication for chat, and an optional public-browsing policy (OFF by default).

begin;

-- ───────────────────────── PRE-FLIGHT GATE: role protection + private-chat prerequisites ─────────────────────────
-- The role column is only safe if students can never write to profiles, and Realtime only safe to
-- enable on tables that have RLS. Nothing below this block runs unless every prerequisite holds.
do $$
declare
  problems text[] := '{}';
  r text;
  priv text;
  pol text;
begin
  if to_regclass('public.profiles') is null then
    raise exception 'MIGRATION 003 ABORTED - nothing was changed. public.profiles does not exist.';
  end if;

  if not (select relrowsecurity from pg_class where oid = 'public.profiles'::regclass) then
    problems := array_append(problems, 'RLS is NOT enabled on public.profiles');
  end if;

  foreach r in array array['authenticated', 'anon'] loop
    foreach priv in array array['INSERT', 'UPDATE'] loop        -- table-level OR any column-level grant
      if has_any_column_privilege(r, 'public.profiles', priv) then
        problems := array_append(problems, format('%s can %s public.profiles', r, priv));
      end if;
    end loop;
    if has_table_privilege(r, 'public.profiles', 'DELETE') then
      problems := array_append(problems, format('%s can DELETE from public.profiles', r));
    end if;
  end loop;

  select string_agg(format('"%s" (%s)', policyname, cmd), ', ' order by policyname) into pol
  from pg_policies
  where schemaname = 'public' and tablename = 'profiles'
    and permissive = 'PERMISSIVE' and cmd in ('INSERT', 'UPDATE', 'DELETE', 'ALL');
  if pol is not null then
    problems := array_append(problems, 'permissive write policy on public.profiles: ' || pol);
  end if;

  foreach r in array array['messages', 'conversations'] loop
    if to_regclass('public.' || r) is null then
      problems := array_append(problems, format('public.%s does not exist', r));
    elsif not (select relrowsecurity from pg_class where oid = ('public.' || r)::regclass) then
      problems := array_append(problems, format('RLS is NOT enabled on public.%s', r));
    end if;
  end loop;

  if cardinality(problems) > 0 then
    raise exception 'MIGRATION 003 ABORTED - nothing was changed. Prerequisites failed: %', array_to_string(problems, ' | ')
      using hint = 'Run 002_security_fixes.sql first, and fix anything listed above (nothing is changed automatically).';
  end if;
end $$;

-- ───────────────────────── Roles ─────────────────────────
-- Existing users all become 'student' (the column default). Users cannot write profiles at all
-- (see 002), so nobody can grant themselves a role. Change roles ONLY from the SQL Editor
-- (or a future server-only admin tool), e.g.:
--   update public.profiles set role = 'moderator' where email = 'someone@college.edu';
alter table public.profiles add column if not exists role text not null default 'student';
do $$ begin
  if not exists (select 1 from pg_constraint where conname = 'profiles_role_check') then
    alter table public.profiles add constraint profiles_role_check
      check (role in ('student','moderator','admin'));
  end if;
end $$;

create or replace function public.user_role() returns text
language sql stable security definer set search_path = public as $$
  select coalesce((select role from public.profiles where id = auth.uid()), 'student')
$$;
revoke all on function public.user_role() from public, anon;
grant execute on function public.user_role() to authenticated;
-- Future moderation policies can use:  using (public.user_role() in ('moderator','admin'))

-- ───────────────────────── Indexes for paginated / filtered queries ─────────────────────────
create index if not exists items_status_created on public.items (status, created_at desc);
create index if not exists items_category on public.items (category);
create index if not exists items_price on public.items (price);
create index if not exists items_seller on public.items (seller_id);
create index if not exists conversations_buyer on public.conversations (buyer_id);
create index if not exists conversations_seller on public.conversations (seller_id);
create index if not exists messages_conv_time on public.messages (conversation_id, created_at);
create index if not exists wishlists_user_time on public.wishlists (user_id, created_at desc);

-- ───────────────────────── Realtime (RLS still decides who receives what) ─────────────────────────
do $$ begin
  if not exists (select 1 from pg_publication_tables where pubname = 'supabase_realtime'
                 and schemaname = 'public' and tablename = 'messages') then
    alter publication supabase_realtime add table public.messages;
  end if;
  if not exists (select 1 from pg_publication_tables where pubname = 'supabase_realtime'
                 and schemaname = 'public' and tablename = 'conversations') then
    alter publication supabase_realtime add table public.conversations;
  end if;
end $$;

-- ───────────────────────── OPTIONAL: public browsing (V1 required login) ─────────────────────────
-- Only if you set REQUIRE_LOGIN_TO_BROWSE=false in the app. Contact details stay private either way.
-- create policy "anyone can browse" on public.items for select to anon using (true);

commit;
