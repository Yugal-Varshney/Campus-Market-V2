-- v3_post_migration_data_checks.sql (PART 2 of 2: rate-limit rules, categories, pure-function behaviour) — READ-ONLY.
-- Run ONLY after PART 1 (v3_post_migration_verification.sql) shows 0 FAIL: this part reads the V3 tables and calls two
-- pure helper functions, so it would raise "relation/function does not exist" if a migration were missing.
-- One SELECT; reads data only (is_display_name_reserved / v3_effective_status / acting_role are pure and write nothing).
-- Result: mig | area | check_name | expected | actual | status   (first row = overall summary; must read 0 FAIL)

with
exp_rules(action, win, mx) as (values ('listing_create',3600,5),('listing_create',86400,20),('report_create',3600,3),('report_create',86400,10),('chat_start',86400,20),
  ('message_send',600,60),('photo_upload',3600,30),('contact_lookup',3600,40),('moderator_action',3600,200)),
checks(mig, area, area_name, check_name, expected, actual, status) as (
  -- 9 ── rate-limit rules: exactly the agreed set, nothing extra
  select '005', 9, 'rate limits', coalesce(e.action, r.action) || ' / ' || coalesce(e.win, r.window_seconds)::text || 's',
         coalesce(e.mx::text, '(no such rule)'), coalesce(r.max_count::text, 'MISSING'),
         case when e.mx is not null and r.max_count = e.mx then 'PASS' else 'FAIL' end
  from exp_rules e full join public.rate_limit_rules r on r.action = e.action and r.window_seconds = e.win
  union all
  select '005', 9, 'rate limits', 'rate_limit_events currently stored', '(any, small)', (select count(*) from public.rate_limit_events)::text, 'INFO'

  union all
  -- 10 ── data integrity that involves V3 objects
  select 'V3', 10, 'data preserved', 'listings whose category has no category row', '0', (select count(*) from public.items i where not exists (select 1 from public.categories c where c.slug = i.category))::text,
         case when (select count(*) from public.items i where not exists (select 1 from public.categories c where c.slug = i.category)) = 0 then 'PASS' else 'FAIL' end
  union all
  select 'V3', 10, 'data preserved', 'every listing is moderation_status = approved (nothing hidden by the migration)', 'all',
         (select count(*) filter (where moderation_status = 'approved') || ' of ' || count(*) from public.items),
         case when (select count(*) from public.items where moderation_status <> 'approved') = 0 then 'PASS' else 'INFO' end
  union all
  select 'V3', 10, 'data preserved', 'every profile is account_status = active', 'all',
         (select count(*) filter (where account_status = 'active') || ' of ' || count(*) from public.profiles),
         case when (select count(*) from public.profiles where account_status <> 'active') = 0 then 'PASS' else 'INFO' end
  union all
  select 'V3', 10, 'data preserved', 'reports / moderation_actions / audit_logs / security_events rows', '(info; audit rows appear once you create the first admin)',
         (select count(*) from public.reports)::text || ' / ' || (select count(*) from public.moderation_actions)::text || ' / ' || (select count(*) from public.audit_logs)::text || ' / ' || (select count(*) from public.security_events)::text, 'INFO'

  union all
  -- 11 ── categories
  select '008', 11, 'categories', 'seeded categories are exactly the V2 values, in order', 'books, notes, electronics, stationary',
         (select string_agg(slug, ', ' order by sort_order, slug) from public.categories),
         case when (select string_agg(slug, ', ' order by sort_order, slug) from public.categories) = 'books, notes, electronics, stationary' then 'PASS' else 'INFO' end
  union all
  select '008', 11, 'categories', 'category ' || c.slug, 'name / active / sort / listings', c.name || ' | active=' || c.is_active || ' | sort=' || c.sort_order || ' | listings=' || (select count(*) from public.items i where i.category = c.slug), 'INFO'
  from public.categories c

  union all
  -- 12 ── behaviour of the pure helper functions
  select '009', 12, 'pure functions', 'is_display_name_reserved(' || quote_literal(t.n) || ')', t.exp::text, public.is_display_name_reserved(t.n)::text,
         case when public.is_display_name_reserved(t.n) = t.exp then 'PASS' else 'FAIL' end
  from (values ('Admin', true), ('admin1', true), ('Campus Market', true), ('4dmin', true), ('M0derator', true), ('Admin Support', true), ('System', true),
               ('Priya Sharma', false), ('Madison', false), ('Systemic Sam', false), ('12345', false)) t(n, exp)
  union all
  select '006', 12, 'pure functions', 'v3_effective_status(' || t.s || ', ' || t.d || ')', t.exp, public.v3_effective_status(t.s, t.u), case when public.v3_effective_status(t.s, t.u) = t.exp then 'PASS' else 'FAIL' end
  from (values ('active','none',null::timestamptz,'active'), ('suspended','1 day ahead',now() + interval '1 day','suspended'), ('suspended','1 day ago',now() - interval '1 day','active'),
               ('suspended','none',null,'suspended'), ('banned','none',null,'banned'), ('banned','1 day ahead',now() + interval '1 day','banned')) t(s, d, u, exp)
  union all
  select '006', 12, 'pure functions', 'acting_role() with no signed-in user (SQL Editor)', 'student', public.acting_role(), case when public.acting_role() = 'student' then 'PASS' else 'FAIL' end
)
select mig, area, area_name || ' | ' || check_name as check_name, expected, actual, status
from (
  select '--' as mig, 0 as area, 'SUMMARY' as area_name, 'OVERALL (must be 0 FAIL)' as check_name, 'FAIL = 0' as expected,
         count(*) filter (where status = 'FAIL')::text || ' FAIL / ' || count(*) filter (where status = 'PASS')::text || ' PASS / ' || count(*) filter (where status = 'INFO')::text || ' INFO' as actual,
         case when count(*) filter (where status = 'FAIL') = 0 then 'PASS' else 'FAIL' end as status
  from checks
  union all
  select mig, area, area_name, check_name, expected, actual, status from checks
) z
order by area, case status when 'FAIL' then 0 when 'REVIEW' then 1 when 'PASS' then 2 else 3 end, mig, check_name;
