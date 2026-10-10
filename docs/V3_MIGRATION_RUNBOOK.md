# V3 database migration runbook (production)

Nothing here has been run against your Supabase project. Run it yourself, in the **SQL Editor**, in this order. Each file is one transaction: if it aborts it changes nothing and tells you why.

## 0. Before you start
1. **Back up**: Supabase → Database → Backups (confirm a recent backup exists; on plans without daily backups export first). There is no staging project, so pick a quiet moment.
2. Confirm V2 migrations 002 and 003 were applied (004 verifies this for you).

## 1. Audit (read-only)
Run `004_v3_preflight_audit.sql`. It is a single SELECT. Read the result table:
- `MISSING` / `DANGER` → **stop**; send me the rows. (Typical DANGER: an extra permissive policy created in the dashboard, an items category value outside books/notes/electronics/stationary, API roles able to write `profiles`.)
- `REVIEW` → read it. "admin accounts: 0" is expected (you create the first admin after 006). "reserved display name in use" lists existing users; V3 never renames anyone. Rows under section 9 are listings that V2's NOT VALID constraints would stop a moderator from updating (hiding); fix those rows first if any appear.
- Section 10 "storage.objects ownership": on Supabase it is **normal** to see `owner=supabase_storage_admin | current_user=postgres`. `postgres` does not own that table, but the platform extension `supautils` delegates `CREATE/ALTER/DROP POLICY` on `storage.objects` to it (Supabase's own troubleshooting docs describe this). Do **not** try to change ownership or grant yourself `supabase_storage_admin`. Migration 009 re-checks the real capability itself with a rolled-back probe before changing anything and aborts safely if it ever fails. (The first version of 004 flagged this row as DANGER; that was a false alarm in my check and is fixed.)

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

## 4. Verify (read-only) — two SQL files, then a short app checklist
Both files are a single `SELECT` (they cannot change anything) and return one table: `mig | area | check_name | expected | actual | status` with status PASS / FAIL / REVIEW / INFO. The first rows are a summary.

**Step 1 — `supabase/verification/v3_post_migration_verification.sql` (structure, security, privileges).**
Uses only catalog tables and V2 tables, so it never errors even if a migration is missing; it reports FAIL instead. Covers: tables + RLS on; new columns and defaults; constraints and the category FK (old CHECKs gone); every expected policy present **and no unexpected policy** (stray permissive policies, anything applying to anon/PUBLIC); storage policies hardened, bucket unchanged, no leftover probe policy; Realtime still only conversations + messages; table privileges for anon/authenticated/service_role; all 55 V3 functions (SECURITY DEFINER flag, empty search_path, EXECUTE only where intended); all triggers present and enabled; V2 row counts not lower than the 004 audit and no orphans; ownership. The summary has one row per migration (005-009), so a partially applied migration shows up immediately.
Before running, edit the `expected_min_counts` line at the top if your row counts changed since 004 (defaults: items 7, conversations 2, messages 11, wishlists 1, profiles 3; the check is "not lower than").
**Expected result:** `OVERALL ... 0 FAIL`. `INFO` rows are normal (status counts, "0 admins" until you create one). A `REVIEW` row means something unexpected exists (e.g. an extra trigger) — read it.

**Step 2 — only if Step 1 shows 0 FAIL: `supabase/verification/v3_post_migration_data_checks.sql`.**
Reads V3 data: the rate-limit rules are exactly the agreed set (listing 5/h + 20/day, report 3/h + 10/day, chat 20/day, message 60/10 min, photo 30/h, contact 40/h, moderator 200/h); the four seeded categories; no listing with an unknown category; all listings approved and all profiles active; and the pure helper functions behave (reserved names, suspension-expiry logic). Expected: `0 FAIL`.

Paste both outputs back before moving on. Neither file writes anything; the only functions Step 2 calls are pure.

**Optional read-only follow-up queries** (after you have clicked through the app in §5):
```sql
-- proves the limit triggers fired on real traffic (one row per action you performed)
select action, count(*) as events, max(created_at) as last_seen from public.rate_limit_events group by action order by action;
-- after you create the first admin: proves the audit trail captured it
select created_at, action, category, source, actor_role, target_id, metadata from public.audit_logs order by id desc limit 5;
```

## 5. Manual checks on the live site (not testable from SQL or from my local stand-in)
These are ordinary uses of the V2 app (they create a few normal test rows you can delete afterwards). Do them with a normal student account:
1. **Browse**: marketplace shows your listings (showcase + real); search, category filter, price slider, sort, pagination all work.
2. **Listing page**: open one; "Contact seller" reveals contact details (this runs the replaced `get_contact`).
3. **Wishlist**: add/remove a heart; the wishlist page lists it.
4. **Create a listing with a photo**; then edit it, mark it sold, mark it available again, and delete it (allowed: it has no chat). Exercises the new insert/limit triggers, the category FK and the **hardened storage upload policy** (a photo upload that fails here is the first thing to report).
5. **Chat + Realtime**: with a second account in another browser, start a conversation on a listing and send messages both ways; they must appear without refreshing. Open your 2 existing conversations: all 11 earlier messages are still there.
6. **Storage limits** (enforced by the Storage API, which I cannot test): uploading a >5 MB file or a non-image must still be rejected.
7. Optional: signing up with the display name `Admin` is rejected (the app will show a generic error until Phase 3 adds a friendly pre-check).
Staff features (hide/restore, reports, suspension, role changes, categories admin) have no screens until Phase 3/4; they are verified here only structurally (Step 1/2) and by my local tests, **not** by live behaviour. If you want live behavioural proof before the dashboards exist, ask me for a single-statement probe that always rolls back (note: even rolled-back inserts advance identity counters, so it is not strictly read-only).
**Specifically verify on Supabase** (my local stand-in cannot): 009 completed (its probe passed and the two storage policies were altered) and a photo upload still works; uploading > 5 MB or a non-image is still rejected; Realtime chat still delivers.

## 6. If something goes wrong
There are no automatic down-migrations. Options: restore the backup; or, for a single migration, undo by hand: re-create the V2 policy `"signed-in can browse"` (`create policy "signed-in can browse" on public.items for select to authenticated using (true);`) and drop the three `v3 ...` policies; the old CHECKs can be re-added with `alter table ... add constraint ... check (...)`. Tell me before improvising.

## Known limitations
Hidden listings' photos remain reachable by their public URL (public bucket, by decision). Hiding/suspension/ban only affect what the database serves; they do not sign the user out. Email confirmation is currently disabled in your project, so ban evasion with a new address is possible until it is re-enabled.
