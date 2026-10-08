# Campus Market V3 — design review (written BEFORE implementation)

Scope of this document: the database foundation (migrations 004–009). UI phases (reporting UI, `/moderator`, `/admin`) come later and only call what is defined here.

## 0. Principles
1. **The database is the authority.** RLS, triggers and `SECURITY DEFINER` functions enforce everything; routes/buttons are UX only.
2. **No service-role key in the app.** Privileged work = definer functions called with the user's own JWT.
3. **Identity is never client-supplied.** Actor = `auth.uid()` inside the function/trigger. Roles are read from `profiles` on every call (never from JWT claims, so they cannot be stale or forged).
4. **Additive + explicit.** No data is rewritten. The only structural replacements: the `items.status` CHECK (superset, adds `inactive`), the `items.category` CHECK (→ FK), the `items` browse policy (→ moderation-aware). Each is flagged in its migration and guarded by a preflight.

## 1. Final V3 schema

| Object | Change | Key columns / rules |
|---|---|---|
| `profiles` | + columns | `account_status` (active/suspended/banned, default active), `suspended_until`, `suspension_reason`, `status_changed_at/by`, `warning_count`, `last_warning_at/reason`. Existing rows → `active`. |
| `items` | + columns | `moderation_status` (approved/pending/hidden/rejected, **default approved**), `moderated_by/at`, `moderation_reason`. `status` gains `inactive` (superset; old CHECK replaced). `category` → FK `categories(slug)`. |
| `categories` | new | `id, name, slug (unique, ^[a-z0-9-]{2,40}$), description, is_active, sort_order, created_at, updated_at`. Seeded with the exact V2 values: `books, notes, electronics, stationary`. Never deleted; disabled instead. |
| `reports` | new | `reporter_id, reported_user_id, listing_id, reason, description (≤500), status, reviewed_by, reviewed_at, target_snapshot, created_at`. FKs `ON DELETE SET NULL` + snapshot so evidence survives. |
| `moderation_actions` | new, append-only | `actor_id, actor_role, action, target_user_id, listing_id, report_id, reason (3–1000), metadata, created_at`. No FKs to users (evidence is never cascaded away). |
| `audit_logs` | new, append-only | `actor_id, actor_role, actor_name, action, category (moderation/admin/security/system), target_type, target_id, reason, metadata, source (rpc/trigger/direct_sql), created_at`. |
| `security_events` | new, append-only | `user_id, event_type, severity (info/notice/warning), metadata, source, created_at` — foundation for V4 risk scoring. |
| `rate_limit_rules` | new | `(action, window_seconds) → max_count`; seeded with the agreed limits. |
| `rate_limit_events` | new | `user_id, action, created_at` — one row per **accepted** action. |

Marketplace state (`items.status`: active/sold/rented/inactive) and moderation state (`items.moderation_status`) are separate columns and never touch each other: hiding does not change `status`; marking sold does not change `moderation_status`.

## 2. Table-by-table RLS (all tables: RLS on; `anon` has nothing)

| Table | SELECT | INSERT | UPDATE | DELETE |
|---|---|---|---|---|
| `items` (V2 table) | approved listings (all signed-in) · own listings · staff all. **Replaces V2 "signed-in can browse".** | own (V2 policy); triggers force identity + `approved` | own (V2 policy); triggers freeze moderation columns, block edits to hidden listings | own, only if no chats (V2), no open report, not hidden |
| `item_private`, `wishlists`, `conversations`, `messages`, `profiles` | unchanged V2 permissive policies | unchanged | unchanged | unchanged |
| *all of the above except `profiles`* | + **restrictive** policy: banned users read nothing | + restrictive: only `active` accounts write (suspended = read-only) | same | same |
| `categories` | all signed-in | none (definer RPC, admin) | none | none |
| `reports` | own reports · staff all | own, `account active`; trigger forces `reporter_id`, `status`, derived target | **nobody** (RPCs only) | **nobody** (trigger blocks) |
| `moderation_actions` | staff | none (RPCs) | none (trigger) | none (trigger) |
| `audit_logs` | admin all · moderator `category='moderation'` only · students none | none (definer only) | none (trigger) | none (trigger) |
| `security_events` | admin only | none | none | none |
| `rate_limit_*` | none | none | none | none |

Restrictive policies are used so V2's permissive policies stay byte-for-byte as reviewed.

## 3. SECURITY DEFINER functions

**Every** V3 definer function: `SET search_path = ''` (all references schema-qualified), actor from `auth.uid()`, role re-checked inside, `EXECUTE` revoked from `PUBLIC`/`anon` (and from `authenticated` for internal ones).

| Function | Callable by | Purpose / checks |
|---|---|---|
| `acting_role()`, `account_is_active()`, `account_not_banned()`, `assert_account_active()` | authenticated (return only the caller's own state) | role/status of caller; suspended/banned staff are treated as `student` |
| `staff_hide_listing`, `staff_restore_listing` | moderator, admin | target owner must be a student for moderators; reason required |
| `staff_warn_user`, `staff_suspend_user`, `staff_unsuspend_user` | moderator, admin | moderators: students only, 1 min–7 days, cannot touch banned or indefinite suspensions |
| `admin_ban_user`, `admin_unban_user`, `admin_set_role` | admin | never self; last active admin protected (also by trigger) |
| `staff_claim_report`, `staff_dismiss_report`, `staff_resolve_report` | moderator, admin | moderators cannot handle reports about staff |
| `admin_create_category`, `admin_update_category`, `admin_set_category_active` | admin | slug immutable; cannot disable the last active category |
| `staff_get_user`, `admin_search_users` | staff / admin | email visible to admins only |
| internal: `audit_write`, `record_security_event`, `rate_limit_check`, `v3_log_action`, `v3_staff_guard`, `v3_target_check`, triggers | nobody via API | called by other definer code only |

## 4. Permission matrix (enforced in DB)

| Capability | Student | Moderator | Admin |
|---|---|---|---|
| Browse approved listings; own hidden listing visible to owner | ✔ | ✔ | ✔ |
| Create/edit/delete own listing, chat, wishlist, upload | ✔ (active account) | ✔ | ✔ |
| Suspended (read-only) | browse + read own chats only | same | same |
| Banned | own profile only | same | same |
| Report listing/user | ✔ | ✔ | ✔ |
| See reports | own | all | all |
| Claim/dismiss/resolve report | ✘ | ✔ (not about staff) | ✔ |
| Hide/restore listing | ✘ | ✔ (student-owned) | ✔ |
| Warn user | ✘ | ✔ students | ✔ |
| Suspend ≤7 days | ✘ | ✔ students | ✔ any length / indefinite |
| Ban/unban, set role | ✘ | ✘ | ✔ (not self) |
| Categories | read | read | manage |
| Audit logs | ✘ | moderation entries | all |
| Security events | ✘ | ✘ | ✔ |

## 5. Migration order and dependencies

| File | Depends on | Contents |
|---|---|---|
| `004_v3_preflight_audit.sql` | — | **read-only** single `SELECT`: V2 prerequisites, collisions, category values, constraint names, staff counts, reserved names |
| `005_v3_audit_events_and_rate_core.sql` | V2 (002, 003) | audit_logs, security_events, rate_limit rules/events + `rate_limit_check`; append-only enforcement |
| `006_v3_accounts_and_moderation.sql` | 005 | account status, moderation state, items policies/guards, moderation_actions, staff RPCs, last-admin + audit backstop triggers, hidden-listing enforcement in `get_contact`/chats/messages |
| `007_v3_reporting.sql` | 006 | reports, RLS, anti-spam, report RPCs, delete guard for open reports |
| `008_v3_categories.sql` | 006 | categories (seed + FK swap with data verification), admin RPCs, category guard |
| `009_v3_rate_limits_hardening.sql` | 005–007 | limit triggers (listings, chats, messages), photo-upload limit in storage policy, reserved display names, cleanup function |

005 was widened from the proposal (it also holds the rate-limit core) because 006/007 call `rate_limit_check`; the limits themselves are applied in 009.

## 6. Rate-limit design
Rule table `(action, window_seconds, max_count)`; one `rate_limit_events` row per **accepted** action, `created_at = now()` (server clock; no client time, user = `auth.uid()`).
Check = `count(events for this user+action with created_at > now() - window)`; if `>= max` → error `RATE_LIMIT` (SQLSTATE 54000). A per-(user,action) `pg_advisory_xact_lock` serialises concurrent requests so the limit is exact. Old events (>2 days) of that user are purged on each call (bounded growth).

| Action | Limit | Applied by |
|---|---|---|
| listing_create | 5/h, 20/day | BEFORE INSERT trigger on `items` |
| report_create | 3/h, 10/day | BEFORE INSERT trigger on `reports` |
| chat_start | 20/day | BEFORE INSERT trigger on `conversations` |
| message_send | 60 / 10 min | BEFORE INSERT trigger on `messages` |
| photo_upload | 30/h | storage INSERT policy |
| contact_lookup | 40/h (V2 value) | `get_contact()` |
| moderator_action | 200/h (moderators only) | every staff RPC |

**Known limit:** a rejected request raises and rolls back, so it cannot itself be logged. `security_events` therefore records *accepted* signals (80 % of a limit reached, 3 open reports on one target, role changes, direct-SQL role/status changes); rejections appear in Postgres logs.

## 7. Audit-log design
Append-only: no `INSERT/UPDATE/DELETE/TRUNCATE` privileges for any API role (incl. `service_role`); BEFORE UPDATE/DELETE row triggers and a BEFORE TRUNCATE trigger raise for **everyone**, including the SQL Editor. Rows are written only by `audit_write()` (definer, not executable via API) inside the same transaction as the action. A backstop trigger on `profiles.role/account_status` and `items.moderation_status` logs changes made outside the RPCs as `source='direct_sql'` (admin-only visibility). No FKs from audit/moderation tables to users, so deleting an account cannot cascade evidence away. **Honest limit:** the database owner can still disable a trigger; this protects against every API role (including a rogue moderator), not against someone with owner-level SQL access.

## 8. Reporting workflow
Student inserts into `reports` (`listing_id`+reason, or `reported_user_id`+reason). Trigger: forces `reporter_id=auth.uid()`, `status=pending`, no reviewer; derives `reported_user_id` from the listing owner; rejects self/own-listing reports; one open report per (reporter, target); rate limit; account must be active; snapshots titles/names. Reasons: scam, prohibited_item, misleading_information, duplicate_listing, harassment, inappropriate_content, other (other needs ≥10 chars). Reporter sees only own reports (no staff notes).

## 9. Moderator workflow
Queue → `staff_claim_report` (pending→reviewing) → inspect listing/user (RLS lets staff read) → action (`staff_hide_listing` / `staff_warn_user` / `staff_suspend_user` ≤7 d) with `p_report_id` → `staff_resolve_report` or `staff_dismiss_report`. Every step writes `moderation_actions` + `audit_logs` atomically. Listings with open reports cannot be deleted by the seller (they can mark sold/rented/inactive).

## 10. Admin workflow
Everything moderators can do, plus ban/unban, `admin_set_role`, category management, full audit log, security events, user search (with email). Self-targeting is rejected; the last active admin cannot be demoted, suspended, banned or deleted (function + trigger).

## 11. Security test plan
Runs on a local Postgres Supabase stand-in (`supabase/tests/local/`), against V2-shaped production data: gate aborts; V2 data fingerprints unchanged; idempotent re-runs; role escalation (student→mod/admin, mod→admin/self/other mod/admin, last admin); IDOR across listings, item_private, chats, messages, reports, moderation actions, audit logs, account info; tampering with actor/user/seller/buyer ids, role, account_status, moderation_status, report status, reviewed_by; suspended/banned behaviour per operation; hidden-listing behaviour; reports rules; categories; rate limits (each rule + window expiry); EXECUTE-privilege and `search_path` catalog assertions; reserved names; V2 regression suite.
Not testable locally (needs real Supabase): Storage API enforcement, `ALTER POLICY` on `storage.objects` ownership, Realtime delivery, Auth. These are listed separately in the Phase 2 report.

---
## Implementation notes (as built in Phase 2 — differences from the plan above)
- **`items.status` gains `inactive`** (superset of the old CHECK) so a seller can pull a listing that has chats or an open report instead of deleting it. Migration 006 replaces the old CHECK; every existing value stays valid. The V2 UI does not offer it yet (Phase 3+).
- **005** also contains the rate-limit core (tables, `rate_limit_check`); the limits themselves are applied in 009.
- **Invoker vs definer:** `items_v3_guard` (blocks owners from touching moderation columns / editing hidden listings) is deliberately SECURITY **INVOKER**: it uses `current_user` (the role that issued the statement: `authenticated` for API calls, the function owner inside staff RPCs), which a client cannot fake. Every other V3 function that needs elevated access is SECURITY DEFINER with `search_path = ''`.
- **Restrictive policies** implement suspension/ban without touching any V2 permissive policy. A suspended user's UPDATE/DELETE on their own rows therefore affects **0 rows** (no error) — the UI must read `profiles.account_status` to explain it; INSERTs raise `ACCOUNT_SUSPENDED`.
- **Reserved names**: `is_display_name_reserved(text)` is callable by `anon` (pure, no table access) so the sign-up page can pre-check; the `auth.users` trigger is the enforcement. Supabase Auth shows a generic "Database error saving new user" for trigger exceptions, so the app must pre-check to give a friendly message (V2 had the same limitation for the college-email trigger).
- `pending`/`rejected` moderation states exist in the schema but nothing sets them yet (reserved for V4).
- Staff cannot read conversations/messages/`item_private` (privacy by design); moderators never see user emails.
- Not auto-audited: direct SQL edits to `categories`, `rate_limit_rules`. Rejected (rolled-back) requests cannot be logged.
