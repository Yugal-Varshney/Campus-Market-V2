-- 004_v3_preflight_audit.sql — READ-ONLY. Run this in the Supabase SQL Editor BEFORE any V3 migration.
--
-- One SELECT statement (no INSERT/UPDATE/DELETE/DDL), so it cannot change anything. It returns ONE result
-- table (the SQL Editor only shows the last result of a script):  section | check_name | object | detail | status
-- status:  OK / INFO / PRESENT  = fine        MISSING = an expected V2 object is absent (do NOT run V3)
--          REVIEW = look at it first         DANGER  = do NOT run V3 until this is fixed or understood
-- Tip: filter the output for status in ('DANGER','MISSING','REVIEW').
--
--  1 V2 prerequisites present?              8 existing profiles with reserved display names (not renamed)
--  2 V3 objects that already exist          9 existing rows that violate V2's NOT VALID constraints
--  3 policies on tables V3 touches         10 storage: bucket, owner, can this role alter its policies?
--  4 API-role write access to profiles     11 RLS status + Realtime publication
--  5 constraints 006/008 will replace      12 auth.users triggers
--  6 items.category values (008 aborts on any unmatched value)
--  7 data summary (roles, admins, statuses, conversations)

with
v2_funcs(sig) as (values ('public.check_college_email()'),('public.handle_new_user()'),('public.get_contact(bigint)'),
  ('public.items_guard()'),('public.item_private_guard()'),('public.conversations_guard()'),
  ('public.items_block_delete_with_chats()'),('public.user_role()')),
v2_triggers(tbl, trg) as (values ('users','college_email_only'),('users','college_email_only_update'),('users','on_auth_user_created'),
  ('items','items_guard_trg'),('items','items_block_delete_with_chats_trg'),('item_private','item_private_guard_trg'),
  ('conversations','conversations_guard_trg')),
v2_policies(sch, tbl, pol) as (values
  ('public','items','signed-in can browse'),('public','items','sellers post'),('public','items','sellers update own'),('public','items','sellers delete own'),
  ('public','item_private','seller manages contact'),('public','wishlists','own wishlist'),
  ('public','conversations','see my chats'),('public','conversations','buyer starts chat'),
  ('public','messages','read my messages'),('public','messages','send in my chats'),('public','profiles','own profile'),
  ('storage','objects','anyone views photos'),('storage','objects','upload to own folder'),('storage','objects','delete own photos')),
v2_constraints(con) as (values ('items_title_len'),('items_description_len'),('items_condition_valid'),('item_private_phone_format'),('messages_body_len')),
v3_tables(t) as (values ('audit_logs'),('security_events'),('rate_limit_rules'),('rate_limit_events'),('moderation_actions'),('reports'),('categories')),
v3_funcs(f) as (values ('audit_write'),('record_security_event'),('rate_limit_check'),('acting_role'),('account_is_active'),('assert_account_active'),
  ('staff_hide_listing'),('staff_restore_listing'),('staff_warn_user'),('staff_suspend_user'),('staff_unsuspend_user'),('admin_ban_user'),
  ('admin_unban_user'),('admin_set_role'),('staff_claim_report'),('staff_dismiss_report'),('staff_resolve_report'),
  ('admin_create_category'),('admin_update_category'),('admin_set_category_active'),('is_display_name_reserved'),('v3_purge_old_events')),
v3_cols(tbl, col) as (values ('profiles','account_status'),('profiles','suspended_until'),('profiles','warning_count'),
  ('items','moderation_status'),('items','moderated_by')),
v3_policy_names(tbl, pol) as (values ('items','v3 browse approved'),('items','v3 owner reads own listings'),('items','v3 staff read all listings')),
seed_categories(c) as (values ('books'),('notes'),('electronics'),('stationary')),
reserved_tokens(tok) as (values ('administrator'),('campusmarket'),('moderator'),('support'),('system'),('admin')),
rows_out as (

  -- 1 ── V2 prerequisites
  select 1 as s, 'V2 function' as check_name, f.sig as object, 'from V2 migrations 002/003' as detail,
         case when to_regprocedure(f.sig) is not null then 'PRESENT' else 'MISSING' end as status from v2_funcs f
  union all
  select 1, 'V2 trigger', t.tbl || ' / ' || t.trg, 'from V2 migrations 002/003',
         case when exists (select 1 from pg_trigger g join pg_class c on c.oid = g.tgrelid where not g.tgisinternal and c.relname = t.tbl and g.tgname = t.trg)
              then 'PRESENT' else 'MISSING' end from v2_triggers t
  union all
  select 1, 'V2 policy', p.sch || '.' || p.tbl || ' / "' || p.pol || '"', 'from V1/V2',
         case when exists (select 1 from pg_policies x where x.schemaname = p.sch and x.tablename = p.tbl and x.policyname = p.pol)
              then 'PRESENT' else 'MISSING' end from v2_policies p
  union all
  select 1, 'V2 constraint', c.con, 'from V2 migration 002',
         case when exists (select 1 from pg_constraint x where x.conname = c.con) then 'PRESENT' else 'MISSING' end from v2_constraints c
  union all
  select 1, 'V2 table/column', x.obj, 'from V2 migrations 002/003',
         case when x.ok then 'PRESENT' else 'MISSING' end
    from (values ('public.allowed_email_domains', to_regclass('public.allowed_email_domains') is not null),
                 ('public.contact_requests', to_regclass('public.contact_requests') is not null),
                 ('profiles.role column', exists (select 1 from information_schema.columns where table_schema = 'public' and table_name = 'profiles' and column_name = 'role'))) x(obj, ok)

  union all
  -- 2 ── V3 objects that already exist (a clean V2 production has none)
  select 2, 'V3 table already exists', t.t, 'migration will skip creating it (re-run) - REVIEW if you did not run V3 before',
         case when to_regclass('public.' || t.t) is not null then 'REVIEW' else 'OK' end from v3_tables t
  union all
  select 2, 'V3 column already exists', c.tbl || '.' || c.col, 'column will be left as is',
         case when exists (select 1 from information_schema.columns where table_schema = 'public' and table_name = c.tbl and column_name = c.col)
              then 'REVIEW' else 'OK' end from v3_cols c
  union all
  select 2, 'V3 function name already used', f.f, 'a function with this name exists in schema public',
         case when exists (select 1 from pg_proc p join pg_namespace n on n.oid = p.pronamespace where n.nspname = 'public' and p.proname = f.f)
              then 'REVIEW' else 'OK' end from v3_funcs f
  union all
  select 2, 'V3 policy name already used', p.tbl || ' / "' || p.pol || '"', '',
         case when exists (select 1 from pg_policies x where x.schemaname = 'public' and x.tablename = p.tbl and x.policyname = p.pol)
              then 'REVIEW' else 'OK' end from v3_policy_names p

  union all
  -- 3 ── every policy on the tables V3 touches (+ the dangerous ones)
  select 3, 'policy', p.schemaname || '.' || p.tablename || ' / "' || p.policyname || '"',
         p.cmd || ' | ' || p.permissive || ' | roles=' || p.roles::text || ' | USING: ' || coalesce(p.qual, '-') || ' | CHECK: ' || coalesce(p.with_check, '-'),
         case
           when p.schemaname = 'storage' and p.tablename = 'objects' and p.cmd in ('INSERT','UPDATE','DELETE','ALL')
                and p.policyname not in ('upload to own folder','delete own photos','students upload photos') then 'DANGER'
           when p.schemaname = 'public' and p.tablename = 'items' and p.permissive = 'PERMISSIVE' and p.cmd in ('SELECT','ALL')
                and p.policyname not in ('signed-in can browse') then 'DANGER'
           when p.schemaname = 'public' and p.tablename = 'profiles' and p.cmd in ('INSERT','UPDATE','DELETE','ALL') and p.permissive = 'PERMISSIVE' then 'DANGER'
           when not exists (select 1 from v2_policies e where e.sch = p.schemaname and e.tbl = p.tablename and e.pol = p.policyname)
                and not exists (select 1 from v3_policy_names e where e.tbl = p.tablename and e.pol = p.policyname) then 'REVIEW'
           else 'INFO' end
  from pg_policies p
  where (p.schemaname = 'public' and p.tablename in ('items','item_private','wishlists','conversations','messages','profiles'))
     or (p.schemaname = 'storage' and p.tablename = 'objects')

  union all
  -- 4 ── can API roles write profiles? (role-escalation prerequisite)
  select 4, 'profiles privilege', r.role_name || ' / ' || p.priv,
         case when has_any_column_privilege(r.role_name, 'public.profiles', p.priv) then 'granted' else 'not granted' end,
         case when has_any_column_privilege(r.role_name, 'public.profiles', p.priv) then 'DANGER' else 'OK' end
  from (values ('anon'),('authenticated')) r(role_name), (values ('INSERT'),('UPDATE')) p(priv)

  union all
  -- 5 ── constraints that 006 and 008 replace
  select 5, 'items CHECK constraint', c.conname, pg_get_constraintdef(c.oid),
         case when pg_get_constraintdef(c.oid) ~ 'status = ANY \(ARRAY\[''active''::text, ''sold''::text, ''rented''::text\]\)' then 'INFO (006 replaces this)'
              when pg_get_constraintdef(c.oid) ~ '^CHECK \(\(category = ANY' then 'INFO (008 replaces this)'
              else 'INFO' end
  from pg_constraint c where c.conrelid = 'public.items'::regclass and c.contype = 'c'
  union all
  select 5, 'items.status CHECK found exactly once (006 needs this)', 'status', '',
         case when (select count(*) from pg_constraint c where c.conrelid = 'public.items'::regclass and c.contype = 'c'
                      and pg_get_constraintdef(c.oid) ~ 'status = ANY \(ARRAY\[''active''::text, ''sold''::text, ''rented''::text\]\)') = 1
                or exists (select 1 from pg_constraint where conname = 'items_status_valid_v3') then 'OK' else 'DANGER' end
  union all
  select 5, 'items.category CHECK found exactly once (008 needs this)', 'category', '',
         case when (select count(*) from pg_constraint c where c.conrelid = 'public.items'::regclass and c.contype = 'c'
                      and pg_get_constraintdef(c.oid) ~ '^CHECK \(\(category = ANY') = 1
                or exists (select 1 from pg_constraint where conname = 'items_category_fkey') then 'OK' else 'DANGER' end

  union all
  -- 6 ── category values: 008 stops if any value has no seed/category row (it never rewrites them)
  select 6, 'items.category value', coalesce(i.category, 'NULL'), i.n::text || ' listing(s)',
         case when i.category in (select c from seed_categories)
                or (to_regclass('public.categories') is not null and exists (select 1 from information_schema.columns where table_schema = 'public' and table_name = 'categories' and column_name = 'slug'))
              then 'OK' else 'DANGER' end
  from (select category, count(*) as n from public.items group by category) i

  union all
  -- 7 ── data summary
  select 7, 'profiles by role', coalesce(to_jsonb(p) ->> 'role', 'NULL'), count(*)::text || ' profile(s)', 'INFO'
  from public.profiles p group by to_jsonb(p) ->> 'role'
  union all
  select 7, 'admin accounts', 'role = admin', (select count(*) from public.profiles p where to_jsonb(p) ->> 'role' = 'admin')::text ||
         ' admin(s). V3 admin features are unusable until one exists: create the first admin AFTER migration 006 (see README).',
         case when (select count(*) from public.profiles p where to_jsonb(p) ->> 'role' = 'admin') = 0 then 'REVIEW' else 'OK' end
  union all
  select 7, 'items by marketplace status', i.status, i.n::text || ' listing(s)', 'INFO' from (select status, count(*) n from public.items group by status) i
  union all
  select 7, 'row counts', 'items / conversations / messages / wishlists',
         (select count(*) from public.items)::text || ' / ' || (select count(*) from public.conversations)::text || ' / ' ||
         (select count(*) from public.messages)::text || ' / ' || (select count(*) from public.wishlists)::text, 'INFO'
  union all
  select 7, 'showcase listings (seller_id NULL)', 'items', count(*)::text || ' listing(s) - cannot be messaged or reported by an owner', 'INFO'
  from public.items where seller_id is null

  union all
  -- 8 ── existing profiles whose display name is reserved (009 blocks NEW sign-ups only; nothing is renamed)
  select 8, 'reserved display name in use', p.display_name || ' (' || p.id::text || ')', 'role=' || coalesce(p.r, '?') || ' - NOT renamed by V3', 'REVIEW'
  from (select x.id, x.display_name, to_jsonb(x) ->> 'role' as r, n.norm,
               regexp_replace(regexp_replace(n.norm, '(administrator|campusmarket|moderator|support|system|admin)', '', 'g'),
                              '(administrator|campusmarket|moderator|support|system|admin)', '', 'g') as stripped
          from public.profiles x,
               lateral (select regexp_replace(translate(lower(x.display_name), '013457@$', 'oieastas'), '[^a-z0-9]', '', 'g') as norm) n) p
  where p.norm <> p.stripped and (p.stripped = '' or p.stripped ~ '^[0-9]+$')
     or (regexp_replace(lower(p.display_name), '[^a-z0-9]', '', 'g') ~ '(administrator|campusmarket|moderator|support|system|admin)'
         and regexp_replace(regexp_replace(regexp_replace(lower(p.display_name), '[^a-z0-9]', '', 'g'), '(administrator|campusmarket|moderator|support|system|admin)', '', 'g'),
                            '(administrator|campusmarket|moderator|support|system|admin)', '', 'g') ~ '^[0-9]*$')

  union all
  -- 9 ── rows that would reject UPDATEs (e.g. a moderator hiding them) because of V2's NOT VALID constraints
  select 9, 'item violating V2 constraints', 'items.id=' || i.id::text,
         concat_ws(', ', case when char_length(btrim(i.title)) not between 3 and 120 then 'title length' end,
                         case when char_length(i.description) > 1000 then 'description > 1000' end,
                         case when i.condition_label not in ('new','like-new','good','fair') then 'condition_label' end),
         'REVIEW'
  from public.items i
  where char_length(btrim(i.title)) not between 3 and 120 or char_length(i.description) > 1000
     or i.condition_label not in ('new','like-new','good','fair')
  union all
  select 9, 'item_private violating phone rule', 'item_private.item_id=' || p.item_id::text, 'contact_phone format', 'REVIEW'
  from public.item_private p where p.contact_phone <> '' and p.contact_phone !~ '^[0-9+()[:space:]-]{7,20}$'
  union all
  select 9, 'summary', 'violations', 'none listed above = clean', 'INFO'

  union all
  -- 10 ── storage
  select 10, 'storage bucket', b.id::text, 'public=' || b.public::text || ' | file_size_limit=' || coalesce(b.file_size_limit::text, 'none')
         || ' | mime=' || coalesce(b.allowed_mime_types::text, 'any'), 'INFO' from storage.buckets b
  union all
  select 10, 'can this role alter storage.objects policies? (009 needs it)', 'storage.objects',
         'owner=' || pg_get_userbyid(c.relowner) || ' | current_user=' || current_user,
         case when pg_has_role(current_user, c.relowner, 'USAGE') then 'OK' else 'DANGER' end
  from pg_class c where c.oid = 'storage.objects'::regclass

  union all
  -- 11 ── RLS + Realtime
  select 11, 'RLS enabled', c.relname::text, case when c.relrowsecurity then 'on' else 'OFF' end,
         case when c.relrowsecurity then 'OK' else 'DANGER' end
  from pg_class c join pg_namespace n on n.oid = c.relnamespace where n.nspname = 'public' and c.relkind = 'r'
  union all
  select 11, 'published to Realtime', pt.schemaname || '.' || pt.tablename, '',
         case when pt.tablename in ('item_private','profiles','wishlists','reports','audit_logs','moderation_actions','security_events') then 'DANGER' else 'INFO' end
  from pg_publication_tables pt where pt.pubname = 'supabase_realtime'

  union all
  -- 12 ── triggers on auth.users
  select 12, 'auth.users trigger', t.tgname::text, pg_get_triggerdef(t.oid), 'INFO'
  from pg_trigger t join pg_class c on c.oid = t.tgrelid join pg_namespace n on n.oid = c.relnamespace
  where not t.tgisinternal and n.nspname = 'auth' and c.relname = 'users'
)
select s as section, check_name, object, detail, status
from rows_out
order by s, case when status like 'DANGER%' then 0 when status = 'MISSING' then 1 when status like 'REVIEW%' then 2 else 3 end, check_name, object;
