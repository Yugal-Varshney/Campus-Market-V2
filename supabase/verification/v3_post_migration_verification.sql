-- v3_post_migration_verification.sql (PART 1 of 2: structure, security, privileges) — READ-ONLY.
-- Run in the Supabase SQL Editor AFTER migrations 005-009. Uses only catalog tables and V2 tables, so it never errors
-- even if a migration is missing (it reports FAIL instead). Run PART 2 (v3_post_migration_data_checks.sql) only when this shows 0 FAIL.
--
-- ONE SELECT statement (no INSERT/UPDATE/DELETE/DDL, calls no V3 function): it cannot change anything. One result table:
--   mig | area | check_name | expected | actual | status        status: PASS / FAIL / REVIEW / INFO
-- The first rows are a SUMMARY (overall + per migration). Overall must read "0 FAIL". Then read any FAIL/REVIEW
-- rows (they sort to the top of each area). Paste the whole output back to me.
--
-- Areas: 1 tables+RLS  2 columns  3 constraints+FKs  4 policies (expected AND unexpected)  5 storage+Realtime
--        6 table privileges  7 functions (SECURITY DEFINER, search_path, EXECUTE)  8 triggers
--       10 V2 data preserved + integrity  13 ownership        (rate-limit rules, categories, behaviour = PART 2)
-- Edit the `expected_min_counts` values below if your row counts changed since the 004 audit.

with
expected_min_counts(tbl, n) as (values ('items', 7), ('conversations', 2), ('messages', 11), ('wishlists', 1), ('profiles', 3)),
exp_tables(mig, tbl) as (values ('005','audit_logs'),('005','security_events'),('005','rate_limit_rules'),('005','rate_limit_events'),
  ('006','moderation_actions'),('007','reports'),('008','categories'),('V2','profiles'),('V2','items'),('V2','item_private'),
  ('V2','wishlists'),('V2','conversations'),('V2','messages'),('V2','allowed_email_domains'),('V2','contact_requests')),
exp_cols(mig, tbl, col, nullable, dflt) as (values
  ('006','profiles','account_status','NO',$$'active'::text$$), ('006','profiles','suspended_until','YES',null), ('006','profiles','suspension_reason','YES',null),
  ('006','profiles','status_changed_at','YES',null), ('006','profiles','status_changed_by','YES',null), ('006','profiles','warning_count','NO','0'),
  ('006','profiles','last_warning_at','YES',null), ('006','profiles','last_warning_reason','YES',null),
  ('006','items','moderation_status','NO',$$'approved'::text$$), ('006','items','moderated_by','YES',null), ('006','items','moderated_at','YES',null), ('006','items','moderation_reason','YES',null),
  ('V2','profiles','role','NO',$$'student'::text$$)),
-- (schema, table, policy, command, kind)
exp_pol(mig, sch, tbl, pol, cmd, kind) as (values
  ('V2','public','items','sellers post','INSERT','PERMISSIVE'), ('V2','public','items','sellers update own','UPDATE','PERMISSIVE'), ('V2','public','items','sellers delete own','DELETE','PERMISSIVE'),
  ('006','public','items','v3 browse approved','SELECT','PERMISSIVE'), ('006','public','items','v3 owner reads own listings','SELECT','PERMISSIVE'), ('006','public','items','v3 staff read all listings','SELECT','PERMISSIVE'),
  ('006','public','items','v3 banned no read','SELECT','RESTRICTIVE'), ('006','public','items','v3 active insert','INSERT','RESTRICTIVE'), ('006','public','items','v3 active update','UPDATE','RESTRICTIVE'), ('006','public','items','v3 active delete','DELETE','RESTRICTIVE'),
  ('V2','public','item_private','seller manages contact','ALL','PERMISSIVE'),
  ('006','public','item_private','v3 banned no read','SELECT','RESTRICTIVE'), ('006','public','item_private','v3 active insert','INSERT','RESTRICTIVE'), ('006','public','item_private','v3 active update','UPDATE','RESTRICTIVE'), ('006','public','item_private','v3 active delete','DELETE','RESTRICTIVE'),
  ('V2','public','wishlists','own wishlist','ALL','PERMISSIVE'),
  ('006','public','wishlists','v3 banned no read','SELECT','RESTRICTIVE'), ('006','public','wishlists','v3 active insert','INSERT','RESTRICTIVE'), ('006','public','wishlists','v3 active update','UPDATE','RESTRICTIVE'), ('006','public','wishlists','v3 active delete','DELETE','RESTRICTIVE'),
  ('V2','public','conversations','see my chats','SELECT','PERMISSIVE'), ('V2','public','conversations','buyer starts chat','INSERT','PERMISSIVE'),
  ('006','public','conversations','v3 banned no read','SELECT','RESTRICTIVE'), ('006','public','conversations','v3 active insert','INSERT','RESTRICTIVE'),
  ('V2','public','messages','read my messages','SELECT','PERMISSIVE'), ('V2','public','messages','send in my chats','INSERT','PERMISSIVE'),
  ('006','public','messages','v3 banned no read','SELECT','RESTRICTIVE'), ('006','public','messages','v3 active insert','INSERT','RESTRICTIVE'),
  ('V2','public','profiles','own profile','SELECT','PERMISSIVE'),
  ('006','public','audit_logs','admin reads all audit','SELECT','PERMISSIVE'), ('006','public','audit_logs','moderator reads moderation audit','SELECT','PERMISSIVE'),
  ('006','public','security_events','admin reads security events','SELECT','PERMISSIVE'), ('006','public','moderation_actions','staff read moderation actions','SELECT','PERMISSIVE'),
  ('007','public','reports','reports insert own','INSERT','PERMISSIVE'), ('007','public','reports','reports read own','SELECT','PERMISSIVE'), ('007','public','reports','reports staff read all','SELECT','PERMISSIVE'),
  ('007','public','reports','v3 banned no read','SELECT','RESTRICTIVE'), ('007','public','reports','v3 banned no insert','INSERT','RESTRICTIVE'),
  ('008','public','categories','categories readable','SELECT','PERMISSIVE'),
  ('V2','storage','objects','anyone views photos','SELECT','PERMISSIVE'), ('V2','storage','objects','upload to own folder','INSERT','PERMISSIVE'), ('V2','storage','objects','delete own photos','DELETE','PERMISSIVE')),
exp_trg(mig, sch, tbl, trg) as (values
  ('V2','public','items','items_guard_trg'), ('V2','public','items','items_block_delete_with_chats_trg'), ('V2','public','item_private','item_private_guard_trg'), ('V2','public','conversations','conversations_guard_trg'),
  ('006','public','items','items_v3_insert_guard_trg'), ('006','public','items','items_v3_guard_trg'), ('006','public','items','items_v3_delete_guard_trg'), ('006','public','items','items_moderation_backstop_trg'),
  ('006','public','conversations','conversations_v3_guard_trg'), ('006','public','messages','messages_v3_guard_trg'),
  ('006','public','profiles','profiles_last_admin_guard_trg'), ('006','public','profiles','profiles_audit_backstop_trg'),
  ('005','public','audit_logs','audit_logs_no_mutate'), ('005','public','audit_logs','audit_logs_no_truncate'), ('005','public','security_events','security_events_no_mutate'), ('005','public','security_events','security_events_no_truncate'),
  ('006','public','moderation_actions','moderation_actions_no_mutate'), ('006','public','moderation_actions','moderation_actions_no_truncate'),
  ('007','public','reports','reports_before_insert_trg'), ('007','public','reports','reports_after_insert_trg'), ('007','public','reports','reports_guard_update_trg'), ('007','public','reports','reports_no_delete'), ('007','public','reports','reports_no_truncate'),
  ('007','public','items','items_v3_report_delete_guard_trg'),
  ('008','public','categories','categories_touch_trg'), ('008','public','items','items_v3_category_guard_trg'),
  ('009','public','items','items_v3_limits_trg'), ('009','public','conversations','conversations_v3_limits_trg'), ('009','public','messages','messages_v3_limits_trg'),
  ('V2','auth','users','college_email_only'), ('V2','auth','users','college_email_only_update'), ('V2','auth','users','on_auth_user_created'), ('009','auth','users','reserved_display_name_only')),
-- kind I = internal (no API role may execute), R = signed-in callers only, P = pure (anon + signed-in); definer = SECURITY DEFINER expected
exp_fn(mig, fname, kind, definer) as (values
  ('005','v3_block_mutation','I',false), ('005','audit_write','I',true), ('005','record_security_event','I',true), ('005','rate_limit_check','I',true),
  ('006','v3_effective_status','I',false), ('006','account_is_active','R',true), ('006','account_not_banned','R',true), ('006','acting_role','R',true), ('006','assert_account_active','R',true),
  ('006','items_v3_insert_guard','I',true), ('006','items_v3_guard','I',false), ('006','items_v3_delete_guard','I',true), ('006','conversations_v3_guard','I',true), ('006','messages_v3_guard','I',true),
  ('006','get_contact','R',true), ('006','v3_clean_reason','I',false), ('006','v3_staff_guard','I',true), ('006','v3_assert_target','I',true), ('006','v3_listing_owner_check','I',true),
  ('006','v3_check_report_open','I',true), ('006','v3_log_action','I',true),
  ('006','staff_hide_listing','R',true), ('006','staff_restore_listing','R',true), ('006','staff_warn_user','R',true), ('006','staff_suspend_user','R',true), ('006','staff_unsuspend_user','R',true),
  ('006','admin_ban_user','R',true), ('006','admin_unban_user','R',true), ('006','admin_set_role','R',true), ('006','staff_get_user','R',true), ('006','admin_search_users','R',true),
  ('006','profiles_last_admin_guard','I',true), ('006','profiles_audit_backstop','I',true), ('006','items_moderation_backstop','I',true),
  ('007','reports_before_insert','I',true), ('007','reports_after_insert','I',true), ('007','reports_guard_update','I',false), ('007','items_v3_report_delete_guard','I',true),
  ('007','v3_close_report','I',true), ('007','staff_dismiss_report','R',true), ('007','staff_resolve_report','R',true), ('007','staff_claim_report','R',true),
  ('008','categories_touch','I',false), ('008','items_v3_category_guard','I',true), ('008','admin_create_category','R',true), ('008','admin_update_category','R',true), ('008','admin_set_category_active','R',true),
  ('009','items_v3_limits','I',true), ('009','conversations_v3_limits','I',true), ('009','messages_v3_limits','I',true), ('009','v3_storage_upload_check','R',true),
  ('009','v3_normalize_name','I',false), ('009','is_display_name_reserved','P',true), ('009','check_reserved_display_name','I',true), ('009','v3_purge_old_events','I',true)),
-- table, authenticated privileges, anon privileges, service_role privileges (comma lists; '' = none)
exp_priv(mig, tbl, auth_p, anon_p, svc_p) as (values
  ('005','audit_logs','SELECT','',''), ('005','security_events','SELECT','',''), ('005','rate_limit_rules','','',''), ('005','rate_limit_events','','',''),
  ('006','moderation_actions','SELECT','',''), ('007','reports','SELECT,INSERT','',''), ('008','categories','SELECT','','')),
priv_names(p) as (values ('SELECT'),('INSERT'),('UPDATE'),('DELETE'),('TRUNCATE')),
fn_oid as (select p.oid, p.proname, p.prosecdef, p.proconfig, pg_get_userbyid(p.proowner) as owner,
                  has_function_privilege('anon', p.oid, 'EXECUTE') as anon_x, has_function_privilege('authenticated', p.oid, 'EXECUTE') as auth_x,
                  has_function_privilege('service_role', p.oid, 'EXECUTE') as svc_x,
                  exists (select 1 from aclexplode(coalesce(p.proacl, acldefault('f', p.proowner))) a where a.grantee = 0 and a.privilege_type = 'EXECUTE') as pub_x
           from pg_proc p where p.pronamespace = 'public'::regnamespace),
checks(mig, area, area_name, check_name, expected, actual, status) as (

  -- 1 ── tables + RLS (RLS on, NOT forced: SECURITY DEFINER functions rely on owner bypass)
  select t.mig, 1, 'tables + RLS', 'table ' || t.tbl, 'exists, RLS on, not forced',
         case when c.oid is null then 'MISSING' else 'exists, RLS ' || case when c.relrowsecurity then 'on' else 'OFF' end || case when c.relforcerowsecurity then ', FORCED' else '' end end,
         case when c.oid is not null and c.relrowsecurity and not c.relforcerowsecurity then 'PASS' else 'FAIL' end
  from exp_tables t left join pg_class c on c.relnamespace = 'public'::regnamespace and c.relname = t.tbl and c.relkind = 'r'

  union all
  -- 2 ── columns (existing rows got the defaults: account_status active, moderation_status approved)
  select e.mig, 2, 'columns', e.tbl || '.' || e.col, 'nullable=' || e.nullable || ', default=' || coalesce(e.dflt, '(none)'),
         coalesce('nullable=' || c.is_nullable || ', default=' || coalesce(c.column_default, '(none)'), 'MISSING'),
         case when c.column_name is not null and c.is_nullable = e.nullable and coalesce(c.column_default, '(none)') = coalesce(e.dflt, '(none)') then 'PASS' else 'FAIL' end
  from exp_cols e left join information_schema.columns c on c.table_schema = 'public' and c.table_name = e.tbl and c.column_name = e.col

  union all
  -- 3 ── constraints and foreign keys
  select x.mig, 3, 'constraints', x.con, x.expected, coalesce(a.actual, 'MISSING'),
         case when a.actual is not null and (x.fragment is null or a.def like '%' || x.fragment || '%') and (x.validated is null or a.validated = x.validated) then 'PASS' else 'FAIL' end
  from (values
    ('006','profiles_account_status_valid',null::text,true,'validated check'), ('006','profiles_suspension_consistent',null,true,'validated check'),
    ('006','items_moderation_status_valid',null,true,'validated check'), ('006','items_status_valid_v3',$$'inactive'$$,true,'validated; includes inactive'),
    ('008','items_category_fkey','categories(slug) ON UPDATE RESTRICT ON DELETE RESTRICT',true,'validated FK items.category -> categories(slug)'),
    ('007','moderation_actions_report_fkey','reports(id)',true,'validated FK'),
    ('006','moderation_actions_action_valid',null,true,'validated check'), ('006','moderation_actions_reason_len',null,true,'validated check'), ('006','moderation_actions_has_target',null,true,'validated check'),
    ('007','reports_reason_valid',null,true,'validated check'), ('007','reports_description_len',null,true,'validated check'), ('007','reports_other_needs_text',null,true,'validated check'),
    ('007','reports_status_valid',null,true,'validated check'), ('007','reports_has_target',null,true,'validated check'), ('007','reports_not_self',null,true,'validated check'), ('007','reports_review_consistent',null,true,'validated check'),
    ('008','categories_slug_format',null,true,'validated check'), ('008','categories_name_len',null,true,'validated check'), ('008','categories_description_len',null,true,'validated check'),
    ('005','audit_logs_action_valid',null,true,'validated check'), ('005','audit_logs_category_valid',null,true,'validated check'), ('005','audit_logs_target_type_valid',null,true,'validated check'), ('005','audit_logs_source_valid',null,true,'validated check'),
    ('005','security_events_severity_valid',null,true,'validated check'),
    ('V2','items_check',null,true,'sold only for sell (V2, unchanged)'), ('V2','items_check1',null,true,'rented only for rent (V2, unchanged)'),
    ('V2','items_title_len',null,false,'V2 NOT VALID, unchanged'), ('V2','items_description_len',null,false,'V2 NOT VALID, unchanged'), ('V2','items_condition_valid',null,false,'V2 NOT VALID, unchanged'),
    ('V2','item_private_phone_format',null,false,'V2 NOT VALID, unchanged'), ('V2','messages_body_len',null,false,'V2 NOT VALID, unchanged')) x(mig, con, fragment, validated, expected)
  left join lateral (select pg_get_constraintdef(c.oid) as def, c.convalidated as validated,
                            case when c.convalidated then 'validated' else 'NOT VALID' end as actual
                       from pg_constraint c where c.conname = x.con and c.connamespace = 'public'::regnamespace limit 1) a on true
  union all
  select m.mig, 3, 'constraints', 'old constraint ' || m.con || ' is gone', 'absent', case when exists (select 1 from pg_constraint where conname = m.con and conrelid = 'public.items'::regclass) then 'STILL PRESENT' else 'absent' end,
         case when exists (select 1 from pg_constraint where conname = m.con and conrelid = 'public.items'::regclass) then 'FAIL' else 'PASS' end
  from (values ('006','items_status_check'), ('008','items_category_check')) m(mig, con)
  union all
  select '007', 3, 'constraints', 'reports foreign keys are ON DELETE SET NULL (evidence survives)', '3',
         (select count(*) from pg_constraint c where c.conrelid = to_regclass('public.reports') and c.contype = 'f' and pg_get_constraintdef(c.oid) like '%ON DELETE SET NULL%')::text,
         case when (select count(*) from pg_constraint c where c.conrelid = to_regclass('public.reports') and c.contype = 'f' and pg_get_constraintdef(c.oid) like '%ON DELETE SET NULL%') = 3 then 'PASS' else 'FAIL' end
  union all
  select '007', 3, 'constraints', 'reports: one OPEN report per reporter+target (partial unique indexes)', '2',
         (select count(*) from pg_indexes where schemaname = 'public' and tablename = 'reports' and indexname in ('reports_one_open_per_listing', 'reports_one_open_per_user') and indexdef like 'CREATE UNIQUE%')::text,
         case when (select count(*) from pg_indexes where schemaname = 'public' and tablename = 'reports' and indexname in ('reports_one_open_per_listing', 'reports_one_open_per_user') and indexdef like 'CREATE UNIQUE%') = 2 then 'PASS' else 'FAIL' end

  union all
  -- 4 ── policies: every expected one present with the right command/kind ...
  select e.mig, 4, 'policies', e.sch || '.' || e.tbl || ' / "' || e.pol || '"', e.cmd || ' ' || e.kind,
         coalesce(p.cmd || ' ' || p.permissive, 'MISSING'),
         case when p.policyname is not null and p.cmd = e.cmd and p.permissive = e.kind then 'PASS' else 'FAIL' end
  from exp_pol e left join pg_policies p on p.schemaname = e.sch and p.tablename = e.tbl and p.policyname = e.pol
  union all
  -- ... and NOTHING else on the tables we care about (an extra permissive policy could silently defeat the design)
  select '--', 4, 'policies', 'UNEXPECTED policy ' || p.schemaname || '.' || p.tablename || ' / "' || p.policyname || '"', 'none',
         p.cmd || ' ' || p.permissive || ' roles=' || p.roles::text || ' USING ' || coalesce(p.qual, '-') || ' CHECK ' || coalesce(p.with_check, '-'),
         case when p.permissive = 'PERMISSIVE' and p.cmd in ('SELECT','ALL','INSERT','UPDATE','DELETE') then 'FAIL' else 'REVIEW' end
  from pg_policies p
  where ((p.schemaname = 'public') or (p.schemaname = 'storage' and p.tablename = 'objects'))
    and not exists (select 1 from exp_pol e where e.sch = p.schemaname and e.tbl = p.tablename and e.pol = p.policyname)
  union all
  select '006', 4, 'policies', 'old V2 policy "signed-in can browse" was replaced', 'absent',
         case when exists (select 1 from pg_policies where tablename = 'items' and policyname = 'signed-in can browse') then 'STILL PRESENT (hidden listings would stay visible!)' else 'absent' end,
         case when exists (select 1 from pg_policies where tablename = 'items' and policyname = 'signed-in can browse') then 'FAIL' else 'PASS' end
  union all
  select '--', 4, 'policies', 'no policy in schema public applies to anon / PUBLIC', '0',
         (select count(*) from pg_policies p where p.schemaname = 'public' and (p.roles::text like '%anon%' or p.roles::text like '%public%'))::text,
         case when (select count(*) from pg_policies p where p.schemaname = 'public' and (p.roles::text like '%anon%' or p.roles::text like '%public%')) = 0 then 'PASS' else 'FAIL' end
  union all
  select '--', 4, 'policies', 'tables with RLS on but no policy are default-deny for API roles: ' || x.tbl, 'no policies',
         (select count(*) from pg_policies p where p.schemaname = 'public' and p.tablename = x.tbl)::text, 
         case when (select count(*) from pg_policies p where p.schemaname = 'public' and p.tablename = x.tbl) = 0 then 'PASS' else 'FAIL' end
  from (values ('rate_limit_rules'),('rate_limit_events'),('allowed_email_domains'),('contact_requests')) x(tbl)

  union all
  -- 5 ── storage hardening + Realtime
  select '009', 5, 'storage + realtime', 'storage policy "upload to own folder": own folder AND active account AND photo-upload limit', 'all three conditions',
         coalesce(p.with_check, 'MISSING'),
         case when p.with_check like '%foldername%' and p.with_check like '%account_is_active%' and p.with_check like '%v3_storage_upload_check%' and p.with_check like '%item-images%' then 'PASS' else 'FAIL' end
  from (select 1) o left join pg_policies p on p.schemaname = 'storage' and p.tablename = 'objects' and p.policyname = 'upload to own folder'
  union all
  select '009', 5, 'storage + realtime', 'storage policy "delete own photos": own folder AND active account', 'both conditions',
         coalesce(p.qual, 'MISSING'), case when p.qual like '%foldername%' and p.qual like '%account_is_active%' and p.qual like '%item-images%' then 'PASS' else 'FAIL' end
  from (select 1) o left join pg_policies p on p.schemaname = 'storage' and p.tablename = 'objects' and p.policyname = 'delete own photos'
  union all
  select 'V2', 5, 'storage + realtime', 'storage.objects write policies are exactly upload + delete (no UPDATE policy: no overwriting)', '2 (INSERT, DELETE)',
         (select count(*) from pg_policies where schemaname = 'storage' and tablename = 'objects' and cmd in ('INSERT','UPDATE','DELETE','ALL'))::text || ' ' ||
         coalesce((select string_agg(cmd, ',' order by cmd) from pg_policies where schemaname = 'storage' and tablename = 'objects' and cmd in ('INSERT','UPDATE','DELETE','ALL')), ''),
         case when (select count(*) from pg_policies where schemaname = 'storage' and tablename = 'objects' and cmd in ('INSERT','UPDATE','DELETE','ALL')) = 2
                   and not exists (select 1 from pg_policies where schemaname = 'storage' and tablename = 'objects' and cmd in ('UPDATE','ALL')) then 'PASS' else 'FAIL' end
  union all
  select '009', 5, 'storage + realtime', 'no leftover probe policy on storage.objects', '0', (select count(*) from pg_policies where policyname = 'v3 privilege probe')::text,
         case when exists (select 1 from pg_policies where policyname = 'v3 privilege probe') then 'FAIL' else 'PASS' end
  union all
  select 'V2', 5, 'storage + realtime', 'bucket item-images: public, 5 MB, jpeg/png/webp only', 'true | 5242880 | {image/jpeg,image/png,image/webp}',
         coalesce(b.public::text || ' | ' || coalesce(b.file_size_limit::text, 'none') || ' | ' || coalesce(b.allowed_mime_types::text, 'any'), 'MISSING'),
         case when b.public and b.file_size_limit = 5242880 and b.allowed_mime_types = array['image/jpeg','image/png','image/webp'] then 'PASS' else 'FAIL' end
  from (select 1) o left join storage.buckets b on b.id = 'item-images'
  union all
  select 'V2', 5, 'storage + realtime', 'Realtime publishes exactly conversations + messages (V3 tables are NOT published)', 'conversations, messages',
         coalesce((select string_agg(tablename, ', ' order by tablename) from pg_publication_tables where pubname = 'supabase_realtime'), '(none)'),
         case when coalesce((select string_agg(tablename, ', ' order by tablename) from pg_publication_tables where pubname = 'supabase_realtime'), '') = 'conversations, messages' then 'PASS' else 'FAIL' end

  union all
  -- 6 ── table privileges for API roles
  select e.mig, 6, 'privileges', 'table ' || e.tbl || ' (authenticated / anon / service_role)', coalesce(nullif(e.auth_p, ''), 'none') || ' / ' || coalesce(nullif(e.anon_p, ''), 'none') || ' / ' || coalesce(nullif(e.svc_p, ''), 'none'),
         case when to_regclass('public.' || e.tbl) is null then 'MISSING' else coalesce(nullif(a.ap, ''), 'none') || ' / ' || coalesce(nullif(a.np, ''), 'none') || ' / ' || coalesce(nullif(a.sp, ''), 'none') end,
         case when to_regclass('public.' || e.tbl) is not null and a.ap = e.auth_p and a.np = e.anon_p and a.sp = e.svc_p then 'PASS' else 'FAIL' end
  from exp_priv e
  cross join lateral (select
      coalesce((select string_agg(p, ',' order by case p when 'SELECT' then 1 when 'INSERT' then 2 when 'UPDATE' then 3 when 'DELETE' then 4 else 5 end) from priv_names where has_table_privilege('authenticated', to_regclass('public.' || e.tbl), p)), '') as ap,
      coalesce((select string_agg(p, ',' order by case p when 'SELECT' then 1 when 'INSERT' then 2 when 'UPDATE' then 3 when 'DELETE' then 4 else 5 end) from priv_names where has_table_privilege('anon', to_regclass('public.' || e.tbl), p)), '') as np,
      coalesce((select string_agg(p, ',' order by case p when 'SELECT' then 1 when 'INSERT' then 2 when 'UPDATE' then 3 when 'DELETE' then 4 else 5 end) from priv_names where has_table_privilege('service_role', to_regclass('public.' || e.tbl), p)), '') as sp) a
  union all
  select 'V2', 6, 'privileges', 'profiles: API roles cannot INSERT/UPDATE/DELETE (table or column level) - role-escalation guard', 'none',
         coalesce(nullif((select string_agg(r || ':' || p, ', ') from (values ('authenticated'),('anon')) r(r), (values ('INSERT'),('UPDATE')) pp(p) where has_any_column_privilege(r, 'public.profiles', p)) ||
                         case when has_table_privilege('authenticated', 'public.profiles', 'DELETE') or has_table_privilege('anon', 'public.profiles', 'DELETE') then ', DELETE' else '' end, ''), 'none'),
         case when not exists (select 1 from (values ('authenticated'),('anon')) r(r), (values ('INSERT'),('UPDATE')) pp(p) where has_any_column_privilege(r, 'public.profiles', p))
                   and not has_table_privilege('authenticated', 'public.profiles', 'DELETE') and not has_table_privilege('anon', 'public.profiles', 'DELETE') then 'PASS' else 'FAIL' end

  union all
  -- 7 ── functions: exist, definer flag, pinned empty search_path, EXECUTE matrix
  select f.mig, 7, 'functions', f.fname || '()  [' || case f.kind when 'I' then 'internal' when 'R' then 'signed-in' else 'pure/anon' end || ']',
         case f.kind when 'I' then 'definer=' || f.definer || ', search_path pinned, NO api EXECUTE' when 'R' then 'definer=' || f.definer || ', search_path pinned, authenticated only' else 'definer=' || f.definer || ', search_path pinned, anon+authenticated' end,
         coalesce('definer=' || o.prosecdef || ', search_path ' || case when o.proconfig is not null and exists (select 1 from unnest(o.proconfig) c where c = 'search_path=""') then 'pinned' else 'NOT PINNED' end ||
                  ', EXECUTE anon=' || o.anon_x || ' auth=' || o.auth_x || ' svc=' || o.svc_x || ' public=' || o.pub_x, 'MISSING'),
         case when o.oid is not null and o.prosecdef = f.definer and o.proconfig is not null and exists (select 1 from unnest(o.proconfig) c where c = 'search_path=""')
                   and not o.pub_x
                   and case f.kind when 'I' then not o.anon_x and not o.auth_x and not o.svc_x
                                   when 'R' then not o.anon_x and o.auth_x
                                   else o.anon_x and o.auth_x end then 'PASS' else 'FAIL' end
  from exp_fn f left join fn_oid o on o.proname = f.fname
  union all
  select '--', 7, 'functions', 'all ' || (select count(*) from exp_fn)::text || ' V3 functions found, no duplicates/overloads', (select count(*) from exp_fn)::text,
         (select count(*) from fn_oid o join exp_fn f on f.fname = o.proname)::text,
         case when (select count(*) from fn_oid o join exp_fn f on f.fname = o.proname) = (select count(*) from exp_fn) then 'PASS' else 'FAIL' end

  union all
  -- 8 ── triggers present and ENABLED ('O'), plus anything unexpected on the tables V3 guards
  select e.mig, 8, 'triggers', e.sch || '.' || e.tbl || ' / ' || e.trg, 'present, enabled', coalesce(case t.tgenabled when 'O' then 'enabled' when 'D' then 'DISABLED' else 'enabled-other(' || t.tgenabled::text || ')' end, 'MISSING'),
         case when t.tgenabled = 'O' then 'PASS' else 'FAIL' end
  from exp_trg e left join lateral (select g.tgenabled from pg_trigger g join pg_class c on c.oid = g.tgrelid join pg_namespace n on n.oid = c.relnamespace
                                     where not g.tgisinternal and n.nspname = e.sch and c.relname = e.tbl and g.tgname = e.trg limit 1) t on true
  union all
  select '--', 8, 'triggers', 'UNEXPECTED trigger ' || n.nspname || '.' || c.relname || ' / ' || g.tgname, 'none', pg_get_triggerdef(g.oid), 'REVIEW'
  from pg_trigger g join pg_class c on c.oid = g.tgrelid join pg_namespace n on n.oid = c.relnamespace
  where not g.tgisinternal and ((n.nspname = 'public') or (n.nspname = 'auth' and c.relname = 'users'))
    and not exists (select 1 from exp_trg e where e.sch = n.nspname and e.tbl = c.relname and e.trg = g.tgname)

  union all
  -- 10 ── V2 data preserved and consistent
  select 'V2', 10, 'data preserved', 'row count ' || e.tbl || ' (not lower than the 004 audit)', '>= ' || e.n::text,
         (case e.tbl when 'items' then (select count(*) from public.items) when 'conversations' then (select count(*) from public.conversations) when 'messages' then (select count(*) from public.messages)
                     when 'wishlists' then (select count(*) from public.wishlists) else (select count(*) from public.profiles) end)::text,
         case when (case e.tbl when 'items' then (select count(*) from public.items) when 'conversations' then (select count(*) from public.conversations) when 'messages' then (select count(*) from public.messages)
                               when 'wishlists' then (select count(*) from public.wishlists) else (select count(*) from public.profiles) end) >= e.n then 'PASS' else 'FAIL' end
  from expected_min_counts e
  union all
  select 'V2', 10, 'data preserved', c.name, '0', c.n::text, case when c.n = 0 then 'PASS' else 'FAIL' end
  from (select 'orphans: conversations without a listing' as name, count(*) as n from public.conversations c where not exists (select 1 from public.items i where i.id = c.item_id)
        union all select 'orphans: messages without a conversation', count(*) from public.messages m where not exists (select 1 from public.conversations c where c.id = m.conversation_id)
        union all select 'orphans: wishlist rows without a listing', count(*) from public.wishlists w where not exists (select 1 from public.items i where i.id = w.item_id)
        union all select 'orphans: item_private without a listing', count(*) from public.item_private p where not exists (select 1 from public.items i where i.id = p.item_id)
        union all select 'listings whose status is outside active/sold/rented/inactive', count(*) from public.items where status not in ('active','sold','rented','inactive')
        union all select 'profiles with an invalid role', count(*) from public.profiles where role not in ('student','moderator','admin')) c
  union all
  select 'V3', 10, 'data preserved', 'every listing is moderation_status = approved (nothing hidden by the migration)', 'all', (select count(*) filter (where to_jsonb(i) ->> 'moderation_status' = 'approved') || ' of ' || count(*) from public.items i),
         case when (select count(*) from public.items i where to_jsonb(i) ->> 'moderation_status' is distinct from 'approved') = 0 then 'PASS' else 'INFO' end
  union all
  select 'V3', 10, 'data preserved', 'every profile is account_status = active', 'all', (select count(*) filter (where to_jsonb(p) ->> 'account_status' = 'active') || ' of ' || count(*) from public.profiles p),
         case when (select count(*) from public.profiles p where to_jsonb(p) ->> 'account_status' is distinct from 'active') = 0 then 'PASS' else 'INFO' end
  union all select 'V2', 10, 'data preserved', 'listings by marketplace status', '(info)', (select string_agg(status || '=' || n, ', ' order by status) from (select status, count(*) n from public.items group by status) s), 'INFO'
  union all select 'V2', 10, 'data preserved', 'profiles by role', '(info; 0 admins until you create the first one)', (select string_agg(role || '=' || n, ', ' order by role) from (select role, count(*) n from public.profiles group by role) s), 'INFO'
  union all select 'V2', 10, 'data preserved', 'showcase listings (seller_id NULL)', '(info; was 6 at audit time)', (select count(*)::text from public.items where seller_id is null), 'INFO'
  union all
  -- 13 ── ownership (SECURITY DEFINER functions rely on the owner bypassing RLS) 
  select '--', 13, 'ownership', 'V3 functions and tables are owned by the migration role', current_user,
         coalesce((select string_agg(distinct o, ', ') from (select owner as o from fn_oid o join exp_fn f on f.fname = o.proname union select pg_get_userbyid(c.relowner) from pg_class c join exp_tables t on c.relname = t.tbl and c.relnamespace = 'public'::regnamespace where t.mig <> 'V2') x), '(none)'),
         case when (select count(distinct o) from (select owner as o from fn_oid o join exp_fn f on f.fname = o.proname union select pg_get_userbyid(c.relowner) from pg_class c join exp_tables t on c.relname = t.tbl and c.relnamespace = 'public'::regnamespace where t.mig <> 'V2') x) = 1
                   and (select min(o) from (select owner as o from fn_oid o join exp_fn f on f.fname = o.proname) y) = current_user then 'PASS' else 'REVIEW' end
  union all
  select '--', 13, 'ownership', 'no V3 object left half-created (no invalid/NOT VALID constraint among V3 constraints)', '0',
         (select count(*) from pg_constraint c where c.connamespace = 'public'::regnamespace and not c.convalidated and c.conname not in ('items_title_len','items_description_len','items_condition_valid','item_private_phone_format','messages_body_len'))::text,
         case when (select count(*) from pg_constraint c where c.connamespace = 'public'::regnamespace and not c.convalidated and c.conname not in ('items_title_len','items_description_len','items_condition_valid','item_private_phone_format','messages_body_len')) = 0 then 'PASS' else 'FAIL' end
)
select mig, area, area_name || ' | ' || check_name as check_name, expected, actual, status
from (
  select '--' as mig, 0 as area, 'SUMMARY' as area_name, 'OVERALL (must be 0 FAIL)' as check_name, 'FAIL = 0' as expected,
         count(*) filter (where status = 'FAIL')::text || ' FAIL / ' || count(*) filter (where status = 'PASS')::text || ' PASS / ' || count(*) filter (where status = 'REVIEW')::text || ' REVIEW / ' || count(*) filter (where status = 'INFO')::text || ' INFO' as actual,
         case when count(*) filter (where status = 'FAIL') = 0 then 'PASS' else 'FAIL' end as status
  from checks
  union all
  select m.mig, 0, 'SUMMARY', 'migration ' || m.mig, 'FAIL = 0',
         count(*) filter (where c.status = 'FAIL')::text || ' FAIL / ' || count(*) filter (where c.status = 'PASS')::text || ' PASS',
         case when count(*) filter (where c.status = 'FAIL') = 0 then 'PASS' else 'FAIL' end
  from (values ('005'),('006'),('007'),('008'),('009')) m(mig) join checks c on c.mig = m.mig group by m.mig
  union all
  select mig, area, area_name, check_name, expected, actual, status from checks
) z
order by area, case status when 'FAIL' then 0 when 'REVIEW' then 1 when 'PASS' then 2 else 3 end, mig, check_name;
