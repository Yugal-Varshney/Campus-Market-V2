# V3 database migration runbook (production)

Nothing here has been run against your Supabase project. Run it yourself, in the **SQL Editor**, in this order. Each file is one transaction: if it aborts it changes nothing and tells you why.

## 0. Before you start
1. **Back up**: Supabase → Database → Backups (confirm a recent backup exists; on plans without daily backups export first). There is no staging project, so pick a quiet moment.
2. Confirm V2 migrations 002 and 003 were applied (004 verifies this for you).

## 1. Audit (read-only)
Run `004_v3_preflight_audit.sql`. It is a single SELECT. Read the result table:
- `MISSING` / `DANGER` → **stop**; send me the rows. (Typical DANGER: an extra permissive policy created in the dashboard, an items category value outside books/notes/electronics/stationary, API roles able to write `profiles`.)
- `REVIEW` → read it. "admin accounts: 0" is expected (you create the first admin after 006). "reserved display name in use" lists existing users; V3 never renames anyone. Rows under section 9 are listings that V2's NOT VALID constraints would stop a moderator from updating (hiding); fix those rows first if any appear.
- Section 10 must say `OK` for "can this role alter storage.objects policies" or 009 will abort.

## 2. Migrations, one file per run
`005_v3_audit_events_and_rate_core.sql` → `006_v3_accounts_and_moderation.sql` → `007_v3_reporting.sql` → `008_v3_categories.sql` → `009_v3_rate_limits_hardening.sql`

Each starts with a pre-flight gate and names exactly what is wrong if it refuses. They are idempotent (safe to re-run).
**What changes behaviour for existing users once 006 runs:** listings now appear only if `moderation_status='approved'` (all existing ones are); the V2 app keeps working unchanged. 008 replaces the category CHECK by a foreign key (it aborts, listing the values, if any listing has an unknown category). 006 replaces the status CHECK by a superset that adds `inactive`.

## 3. Create the first admin (no in-app way exists, on purpose)
After 006, in the SQL Editor, replace the e-mail with the account that should administer the site (it must already have signed up):
```sql
update public.profiles set role = 'admin' where email = 'you@your-college.edu';
select id, email, role from public.profiles where role <> 'student';
```
This is recorded automatically in `audit_logs` as `ROLE_CHANGED`, `source = direct_sql`. Afterwards all role changes go through `admin_set_role` (admins only; never your own role; the last active admin cannot be demoted, suspended, banned or deleted). Never share the SQL Editor or database password; anyone with them can bypass the application rules.

## 4. Verify (read-only queries)
```sql
select count(*) from public.items;                               -- same number as before
select slug, name, is_active from public.categories order by sort_order;   -- books, notes, electronics, stationary
select count(*) from public.items where moderation_status <> 'approved';   -- 0
select policyname, cmd, permissive from pg_policies where tablename = 'items' order by 1;
select action, category, source, created_at from public.audit_logs order by id desc limit 10;
select * from public.rate_limit_rules order by action, window_seconds;
```

## 5. Manual checks on the live site (not testable locally)
Sign in as a normal student and: browse, search/filter, create + edit + mark sold a listing, upload a photo, wishlist, contact seller, start a chat and send a message in two browsers (Realtime), delete a listing that has no chat. Then, with a second test account promoted to moderator, call the RPCs from the SQL Editor impersonating nothing — the dashboards arrive in later phases; until then staff features are exercised through tests only.
**Specifically verify on Supabase** (my local stand-in cannot): `ALTER POLICY` on `storage.objects` succeeded in 009 and a photo upload still works; uploading > 5 MB or a non-image is still rejected; Realtime chat still delivers.

## 6. If something goes wrong
There are no automatic down-migrations. Options: restore the backup; or, for a single migration, undo by hand: re-create the V2 policy `"signed-in can browse"` (`create policy "signed-in can browse" on public.items for select to authenticated using (true);`) and drop the three `v3 ...` policies; the old CHECKs can be re-added with `alter table ... add constraint ... check (...)`. Tell me before improvising.

## Known limitations
Hidden listings' photos remain reachable by their public URL (public bucket, by decision). Hiding/suspension/ban only affect what the database serves; they do not sign the user out. Email confirmation is currently disabled in your project, so ban evasion with a new address is possible until it is re-enabled.
