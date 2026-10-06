-- 001_initial_review.sql — READ-ONLY AUDIT. Changes nothing.
--
-- This file is ONE SELECT statement (no INSERT/UPDATE/DELETE/DDL), so it cannot modify anything.
-- It returns ONE result table because the Supabase SQL Editor only displays the last result of a
-- script. Columns:  section | check_name | object | detail | status
-- status:  OK · INFO · PRESENT/MISSING (expected V1 object) · REVIEW (look at it before running 002/003)
--          · DANGER (do NOT run 002/003 until you understand it)
-- Tip: sort/filter the output by `status` — anything that is not OK / INFO / PRESENT deserves a look.
--
-- Sections
--  1 RLS enabled?                          8 existing rows that violate the new NOT VALID constraints
--  2 RLS policies on the six app tables    9 existing conversations vs. their listing's real owner
--  3 Expected V1 policy names present?    10 current privileges on profiles (002 revokes writes)
--  4 Storage policies (exact names)       11 Realtime publication contents
--  5 Storage bucket config + objects      12 registered email domains (to build allowed_email_domains)
--  6 get_contact() privileges             13 objects 002/003 will create — do they already exist?
--  7 Triggers + function definitions

with
app_tables(t) as (values ('profiles'),('items'),('item_private'),('wishlists'),('conversations'),('messages')),
expected_policies(tbl, pol) as (values
  ('profiles','own profile'), ('items','signed-in can browse'), ('items','sellers post'),
  ('items','sellers update own'), ('item_private','seller manages contact'),
  ('wishlists','own wishlist'), ('conversations','see my chats'), ('conversations','buyer starts chat'),
  ('messages','read my messages'), ('messages','send in my chats')),
expected_storage_policies(pol) as (values ('anyone views photos'), ('students upload photos')),
-- storage write-policies that 002 itself creates or drops; everything else that can write STAYS ACTIVE
storage_known_write(pol) as (values ('students upload photos'), ('upload to own folder'), ('delete own photos')),
get_contact_fn as (
  select p.oid, p.oid::regprocedure::text as sig, pg_get_userbyid(p.proowner) as owner, p.prosecdef, p.proconfig,
         has_function_privilege('anon', p.oid, 'EXECUTE')          as anon_can,
         has_function_privilege('authenticated', p.oid, 'EXECUTE') as authed_can,
         exists (select 1 from aclexplode(coalesce(p.proacl, acldefault('f', p.proowner))) a
                 where a.grantee = 0 and a.privilege_type = 'EXECUTE') as public_can
  from pg_proc p join pg_namespace n on n.oid = p.pronamespace
  where n.nspname = 'public' and p.proname = 'get_contact'),
rows_out as (

  -- 1 ── RLS status
  select 1 as s, 'RLS enabled' as check_name, c.relname::text as object,
         case when c.relrowsecurity then 'row level security ON' else 'row level security OFF' end as detail,
         case when c.relrowsecurity then 'OK' else 'DANGER' end as status
  from pg_class c join pg_namespace n on n.oid = c.relnamespace
  where n.nspname = 'public' and c.relkind = 'r'

  union all
  -- 2 ── every RLS policy on the six app tables
  select 2, 'RLS policy', p.tablename || ' / "' || p.policyname || '"',
         p.cmd || ' | roles=' || p.roles::text || ' | ' || p.permissive || ' | USING: ' || coalesce(p.qual, '-') ||
         ' | CHECK: ' || coalesce(p.with_check, '-'), 'INFO'
  from pg_policies p where p.schemaname = 'public' and p.tablename in (select t from app_tables)

  union all
  -- 3 ── expected V1 policy names: present or missing
  select 3, 'expected V1 policy', e.tbl || ' / "' || e.pol || '"',
         'from supabase/schema.sql',
         case when exists (select 1 from pg_policies p where p.schemaname = 'public'
                           and p.tablename = e.tbl and p.policyname = e.pol) then 'PRESENT' else 'MISSING' end
  from expected_policies e
  union all
  -- 3b ── policies on public tables that are NOT in V1's schema (added in the dashboard? by hand?)
  select 3, 'UNEXPECTED policy (not in V1 schema.sql)', p.tablename || ' / "' || p.policyname || '"',
         p.cmd || ' | roles=' || p.roles::text || ' | USING: ' || coalesce(p.qual, '-') || ' | CHECK: ' || coalesce(p.with_check, '-'),
         'REVIEW'
  from pg_policies p where p.schemaname = 'public'
    and not exists (select 1 from expected_policies e where e.tbl = p.tablename and e.pol = p.policyname)

  union all
  -- 4 ── storage policies, exact names (storage.objects and storage.buckets)
  select 4, 'storage policy', p.tablename || ' / "' || p.policyname || '"',
         p.cmd || ' | roles=' || p.roles::text || ' | ' || p.permissive || ' | USING: ' || coalesce(p.qual, '-') ||
         ' | CHECK: ' || coalesce(p.with_check, '-'),
         case
           when p.tablename = 'objects' and p.cmd in ('INSERT','UPDATE','DELETE','ALL')
                and p.policyname not in (select pol from storage_known_write)
             then 'DANGER'   -- policies are OR-ed: this one would stay active next to 002's stricter ones
           when p.tablename = 'objects' and p.cmd in ('INSERT','UPDATE','DELETE','ALL')
                and coalesce(p.qual, '') || coalesce(p.with_check, '') not like '%bucket_id%'
             then 'REVIEW'   -- not limited to a bucket: applies to ALL buckets
           when p.policyname in (select pol from expected_storage_policies) then 'INFO'
           else 'REVIEW'
         end
  from pg_policies p where p.schemaname = 'storage'
  union all
  select 4, 'expected V1 storage policy', 'objects / "' || e.pol || '"', 'from supabase/schema.sql',
         case when exists (select 1 from pg_policies p where p.schemaname = 'storage' and p.tablename = 'objects'
                           and p.policyname = e.pol) then 'PRESENT' else 'MISSING' end
  from expected_storage_policies e
  union all
  select 4, '002 will DROP this storage policy', '"students upload photos"',
         'the permissive V1 upload policy (any signed-in user, any path)',
         case when exists (select 1 from pg_policies p where p.schemaname = 'storage' and p.tablename = 'objects'
                           and p.policyname = 'students upload photos') then 'INFO' else 'REVIEW' end

  union all
  -- 5 ── bucket configuration + existing objects against the limits 002 will set
  select 5, 'storage bucket', b.id::text,
         'public=' || b.public::text || ' | file_size_limit=' || coalesce(b.file_size_limit::text, 'none') ||
         ' | allowed_mime_types=' || coalesce(b.allowed_mime_types::text, 'any'), 'INFO'
  from storage.buckets b
  union all
  select 5, 'bucket item-images exists', 'item-images', '002 updates this bucket row (size + MIME limits)',
         case when exists (select 1 from storage.buckets where id = 'item-images') then 'OK' else 'MISSING' end
  union all
  select 5, 'existing photos outside 002 limits', 'item-images',
         count(*)::text || ' object(s) larger than 5 MB or not jpeg/png/webp (they are NOT deleted; limits apply to new uploads)',
         case when count(*) = 0 then 'OK' else 'REVIEW' end
  from storage.objects o
  where o.bucket_id = 'item-images'
    and (coalesce((o.metadata->>'size')::bigint, 0) > 5242880
         or coalesce(o.metadata->>'mimetype', 'image/jpeg') not in ('image/jpeg','image/png','image/webp'))
  union all
  select 5, 'existing photos outside a <user-id>/ folder', 'item-images',
         count(*)::text || ' object(s) whose first folder is not a user id (only matters for later deletes by owners)', 'INFO'
  from storage.objects o
  where o.bucket_id = 'item-images' and (storage.foldername(o.name))[1] !~ '^[0-9a-f-]{36}$'

  union all
  -- 6 ── get_contact(): signature, owner, privileges
  select 6, 'get_contact() function', g.sig,
         'owner=' || g.owner || ' | security_definer=' || g.prosecdef::text || ' | config=' || coalesce(g.proconfig::text, 'none') ||
         ' | anon can execute=' || g.anon_can::text || ' | PUBLIC can execute=' || g.public_can::text ||
         ' | authenticated can execute=' || g.authed_can::text,
         case when g.anon_can or g.public_can then 'DANGER' else 'OK' end
  from get_contact_fn g
  union all
  select 6, 'get_contact(bigint) present (002 replaces it in place)', 'get_contact(bigint)',
         'if the signature differs, create-or-replace would ADD an overload and leave the old one callable',
         case when exists (select 1 from get_contact_fn where sig = 'get_contact(bigint)')
                   and (select count(*) from get_contact_fn) = 1 then 'OK' else 'REVIEW' end

  union all
  -- 7 ── triggers (full definitions) on public tables and auth.users
  select 7, 'trigger', c.relname::text || ' / ' || t.tgname, pg_get_triggerdef(t.oid), 'INFO'
  from pg_trigger t join pg_class c on c.oid = t.tgrelid join pg_namespace n on n.oid = c.relnamespace
  where not t.tgisinternal and (n.nspname = 'public' or (n.nspname = 'auth' and c.relname = 'users'))
  union all
  select 7, 'expected V1 trigger', e.tbl || ' / ' || e.trg, 'from supabase/schema.sql',
         case when exists (select 1 from pg_trigger t join pg_class c on c.oid = t.tgrelid
                           where not t.tgisinternal and c.relname = e.tbl and t.tgname = e.trg) then 'PRESENT' else 'MISSING' end
  from (values ('users','college_email_only'), ('users','on_auth_user_created')) e(tbl, trg)
  union all
  select 7, 'function definition', p.oid::regprocedure::text, pg_get_functiondef(p.oid), 'INFO'
  from pg_proc p join pg_namespace n on n.oid = p.pronamespace
  where n.nspname = 'public' and p.proname in ('check_college_email','handle_new_user','get_contact')

  union all
  -- 8 ── existing rows that violate the NOT VALID constraints 002 will add
  --      (NOT VALID skips old rows, but an UPDATE of a violating row — e.g. "mark sold" — WILL be rejected)
  select 8, 'items violating new constraints', 'items.id=' || i.id::text,
         'title="' || left(i.title, 40) || '" | problems: ' ||
         concat_ws(', ',
           case when char_length(btrim(i.title)) not between 3 and 120 then 'title length not 3-120' end,
           case when char_length(i.description) > 1000 then 'description > 1000 chars' end,
           case when i.condition_label not in ('new','like-new','good','fair') then 'condition_label="' || i.condition_label || '"' end),
         case when i.seller_id is null then 'INFO' else 'REVIEW' end   -- seller_id null = demo row nobody can edit
  from public.items i
  where char_length(btrim(i.title)) not between 3 and 120 or char_length(i.description) > 1000
     or i.condition_label not in ('new','like-new','good','fair')
  union all
  select 8, 'item_private violating phone format', 'item_private.item_id=' || p.item_id::text,
         'contact_phone does not match ^[0-9+()[:space:]-]{7,20}$', 'REVIEW'
  from public.item_private p where p.contact_phone <> '' and p.contact_phone !~ '^[0-9+()[:space:]-]{7,20}$'
  union all
  select 8, 'messages violating length limit', 'messages.id=' || m.id::text, 'body longer than 1000 characters', 'REVIEW'
  from public.messages m where char_length(m.body) > 1000
  union all
  select 8, 'summary', 'all tables',
         (select count(*) from public.items)::text || ' items, ' || (select count(*) from public.item_private)::text ||
         ' item_private, ' || (select count(*) from public.messages)::text || ' messages checked; violations listed above (none = clean)',
         'INFO'
  union all
  select 8, 'item photos not matching the own-folder URL rule', 'items',
         count(*)::text || ' item(s) — only enforced when image_url is CHANGED; demo rows with bare filenames are expected',
         'INFO'
  from public.items i
  where i.image_url is not null
    and i.image_url !~ ('^https://[^/]+/storage/v1/object/public/item-images/' || coalesce(i.seller_id::text, 'x') || '/[A-Za-z0-9._-]+$')

  union all
  -- 9 ── existing conversations vs. the listing's actual owner (002 enforces this on NEW chats only)
  select 9, 'conversation whose seller_id differs from the listing owner', 'conversations.id=' || c.id::text,
         'item ' || c.item_id::text || ' | conversation seller=' || c.seller_id::text || ' | listing owner=' || coalesce(i.seller_id::text, 'NULL'),
         'REVIEW'
  from public.conversations c join public.items i on i.id = c.item_id
  where i.seller_id is distinct from c.seller_id
  union all
  select 9, 'conversations consistent with listing owner', 'conversations',
         (select count(*) from public.conversations c join public.items i on i.id = c.item_id
          where i.seller_id is not distinct from c.seller_id)::text || ' of ' || (select count(*) from public.conversations)::text ||
         ' existing conversations match; 002 never rewrites them', 'INFO'

  union all
  -- 10 ── who can write profiles right now (002 revokes this; V1 relies on RLS having no write policy)
  select 10, 'profiles table privilege', r.role_name || ' / ' || p.priv,
         case when has_table_privilege(r.role_name, 'public.profiles', p.priv) then 'granted (RLS still applies)' else 'not granted' end,
         case when has_table_privilege(r.role_name, 'public.profiles', p.priv) then 'INFO' else 'OK' end
  from (values ('anon'),('authenticated')) r(role_name), (values ('INSERT'),('UPDATE'),('DELETE')) p(priv)
  union all
  select 10, 'write policy on profiles', p.policyname, p.cmd || ' | USING: ' || coalesce(p.qual, '-') || ' | CHECK: ' || coalesce(p.with_check, '-'), 'DANGER'
  from pg_policies p where p.schemaname = 'public' and p.tablename = 'profiles' and p.cmd in ('INSERT','UPDATE','DELETE','ALL')

  union all
  -- 11 ── Realtime publication: which tables, and is RLS on for them?
  select 11, 'published to Realtime', pt.schemaname || '.' || pt.tablename,
         'RLS=' || (select c.relrowsecurity::text from pg_class c join pg_namespace n on n.oid = c.relnamespace
                    where n.nspname = pt.schemaname and c.relname = pt.tablename),
         case when pt.tablename in ('item_private','profiles','wishlists') then 'DANGER'
              when (select c.relrowsecurity from pg_class c join pg_namespace n on n.oid = c.relnamespace
                    where n.nspname = pt.schemaname and c.relname = pt.tablename) is not true then 'DANGER'
              else 'INFO' end
  from pg_publication_tables pt where pt.pubname = 'supabase_realtime'
  union all
  select 11, 'Realtime publication', 'supabase_realtime',
         (select count(*) from pg_publication_tables where pubname = 'supabase_realtime')::text || ' table(s) currently published (003 adds messages + conversations)', 'INFO'

  union all
  -- 12 ── email domains of registered users (helps you build allowed_email_domains; 002 does not touch users)
  select 12, 'registered email domain', u.dom, count(*)::text || ' user(s)', 'INFO'
  from (select lower(split_part(email, '@', 2)) as dom from auth.users) u group by u.dom

  union all
  -- 13 ── things 002/003 create: already there?
  select 13, 'column profiles.role', 'profiles.role', '003 adds it with default ''student''',
         case when exists (select 1 from information_schema.columns where table_schema = 'public'
                           and table_name = 'profiles' and column_name = 'role') then 'REVIEW' else 'INFO' end
  union all
  select 13, 'table ' || x.t, x.t, '002 creates it if missing',
         case when to_regclass('public.' || x.t) is not null then 'REVIEW' else 'INFO' end
  from (values ('allowed_email_domains'), ('contact_requests')) x(t)
)
select s as section, check_name, object, detail, status
from rows_out
order by s,
         case status when 'DANGER' then 0 when 'MISSING' then 1 when 'REVIEW' then 2 else 3 end,
         check_name, object;
