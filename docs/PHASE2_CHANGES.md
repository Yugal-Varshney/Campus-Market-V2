# Phase 2 — bug fixes (no new features, no database changes)

No SQL migration was added or changed in this phase. The database already passed the V3 verification
(0 FAIL / 229 PASS); these changes make the **app** match it.

## What changed

| Area | File(s) | Change |
|---|---|---|
| Friendly V3 errors | `lib/errors.ts` (new), `lib/listings/actions.ts`, `lib/listings/queries.ts`, `lib/listings/storage.ts`, `lib/messages/actions.ts` | Rate-limit, suspension, ban, hidden-listing and open-report errors raised by migrations 006/009 are now shown as readable messages instead of generic ones. Unknown database errors still fall back to the old generic text (internal details never reach the UI). |
| Contact lookup bug | `lib/listings/queries.ts` | The code looked for the V2 text `Too many…`; V3 raises `RATE_LIMIT: …`, so the limit message was never shown. |
| Silent phone-edit failure | `lib/listings/actions.ts` (`updateListing`) | The `item_private` update result is now checked and reported. |
| `inactive` status | `types/database.ts`, `lib/format.ts`, `lib/listings/actions.ts` | `inactive` is a known status (label UNAVAILABLE). `setListingStatus` only accepts active / sold / rented from the client. |
| Types | `types/database.ts` | Added the V3 columns (`items.moderation_*`, `profiles.account_status` and related) and the `is_display_name_reserved` RPC. Corrected the stale header comment. |
| Open-redirect hardening | `lib/validation/auth.ts` (`safeNext`) | Rejects control characters, whitespace and anything that does not resolve to the same origin (`/\t/evil.com` used to pass). |
| Registration | `lib/auth/actions.ts` | Reserved display names are pre-checked with a friendly message. The generic "Database error saving new user" (college / allow-list trigger) now gets an actionable message. With email confirmation OFF, a successful sign-up goes straight to the marketplace instead of saying "check your inbox". |
| Password reset | `lib/auth/actions.ts` | Rate-limit responses are reported instead of being swallowed. |
| Mobile search | `app/(site)/marketplace/page.tsx`, `app/globals.css` | A search box appears on screens under 768 px (the navbar search is hidden there). Active filters are carried over. |
| Tests | `tests/validation.test.ts` | 26 → 46 assertions (redirect bypasses, error mapping, status labels). |
| Docs | `README.md`, `docs/SECURITY_TESTS.md` | Migration list 001–009, allow-list instructions, corrected rate-limit message. |

## Not done in this phase (and why)

- **`npm run lint`**: ESLint is not installed, and adding it needs `npm install` to update `package-lock.json` (not possible here). To enable it later: `npm install -D eslint eslint-config-next`, then add an ESLint config.
- **Build / typecheck / lint were not run** by the author of these changes (no `node_modules`, no network). Only `npm test`'s logic was run. Please run the commands below before deploying.
- Items deferred to later phases: consent-based contact sharing, rental unit and duration, report buttons, "show sold/rented" toggle, admin and moderation screens.

## Allow-list (Supabase SQL Editor — your database, run it yourself)

```sql
-- Store the domain WITHOUT a leading dot, lower case.
insert into public.allowed_email_domains (domain, note)
values ('dauniv.ac.in', 'campus email domain')
on conflict (domain) do nothing;

select * from public.allowed_email_domains;
```

Existing accounts are not affected (the trigger runs only on sign-up and email change).

## Run before deploying

```bash
npm ci
npm run typecheck
npm test
npm run build
```

## Check by hand after deploying to a Vercel preview

1. Register with a `@dauniv.ac.in` address → works. Register with another `.ac.in` address → clear error (needs the allow-list row above).
2. Register with a reserved name such as `admin` → "That display name is reserved."
3. Post 6 listings within an hour → the 6th shows the "limit for this action (5 per 60 minutes)" message.
4. Edit a listing's phone number → saved; check it on the listing page after revealing contact.
5. Open `/marketplace` on a phone-width window → search box visible above the listings.
6. Log in with `?next=/%09/evil.com` style values → lands on `/marketplace`.
