# Phase 3 — secure and verify Supabase (production runbook)

You do the dashboard steps; I cannot reach your project. Dashboard labels change between releases, so look for
the setting by name rather than by menu path. Do the steps **in order**. Nothing here needs a code deploy except
the Phase 3 ZIP (token-hash callback), and that change is backward compatible.

## 0. Baseline (2 minutes, read-only)
Run `supabase/verification/phase3_live_checks.sql` and keep the output. It shows the allow-list, how your
existing accounts line up with it, confirmation state, staff counts, rate-limit rules and bucket settings.

## 1. Allow-list
Domain stored **without a leading dot**, lower case:
```sql
insert into public.allowed_email_domains (domain, note) values ('dauniv.ac.in', 'campus email domain')
on conflict (domain) do nothing;
```
Re-run check 1 and 2. Accounts that are "NOT ON ALLOW-LIST" keep working; only new sign-ups and email changes are checked.

## 2. Email delivery (custom SMTP) — before turning confirmation on
Password reset needs email even while sign-up confirmation is off, and Supabase's built-in sender is intended for
testing only (heavily rate limited; check the current limits in the Supabase docs).
1. Pick a transactional email provider (any that offers SMTP). Create an account and verify the **sender domain or
   address you control**. You cannot send as `@dauniv.ac.in` unless the university gives you DNS access, so use your own
   domain or the provider's verified single-sender option.
2. Supabase → Authentication → SMTP settings: enable custom SMTP and enter host, port, username, password (the provider's
   SMTP credentials — paste them only into the Supabase dashboard, never into chat or code), sender email and sender name
   ("Campus Market").
3. Keep the provider's SPF/DKIM records published so mail does not land in spam.
4. Send yourself a test: request a password reset for your own `@dauniv.ac.in` account.

## 3. URL configuration
- **Site URL:** `https://campus-market-v2.vercel.app`
- **Redirect URLs:** `https://campus-market-v2.vercel.app/auth/callback`, `http://localhost:3000/auth/callback`, and, for
  preview deployments, your Vercel preview pattern (`https://*-<your-vercel-scope>.vercel.app/auth/callback`).
- Vercel env var `NEXT_PUBLIC_SITE_URL`: set it for the **Production** scope only. If it is set for Preview too, preview
  emails will link to production. When unset, the app uses the request's own host.

## 4. Email templates (token-hash links, work across devices)
The Supabase default links use a one-browser-only `code`. The Phase 3 callback also accepts `token_hash` links, so a
student can request on a laptop and click on a phone. In Authentication → Email templates, change the link in each template:

| Template | Link |
|---|---|
| Confirm signup | `{{ .RedirectTo }}&token_hash={{ .TokenHash }}&type=email` |
| Reset password | `{{ .RedirectTo }}&token_hash={{ .TokenHash }}&type=recovery` |
| Change email address | `{{ .RedirectTo }}&token_hash={{ .TokenHash }}&type=email_change` |

`{{ .RedirectTo }}` is the URL the app passes when it sends the email (`/auth/callback?next=…`), so appending with `&` is correct
and previews keep working. Confirm `RedirectTo` appears in the template editor's variable list; if your dashboard does not offer it,
use `{{ .SiteURL }}/auth/callback?token_hash={{ .TokenHash }}&type=email&next=/marketplace` (this always points at the Site URL).
Leaving the default templates is also safe: the old `code` flow still works.

## 5. Turn "Confirm email" ON
1. Test first on a Vercel preview with a throwaway `@dauniv.ac.in` address you can read: register → you must receive the
   email → click → you land signed in on `/marketplace`. Then try the same link on a second device/browser (should work with the
   token-hash templates). Then: sign out → "forgot password" → email → set a new password.
2. Then switch **Confirm email** on in production (Authentication → Sign In / Providers → Email).
3. Check result 3 from step 0: existing accounts created while confirmation was off should show as confirmed. If any are
   unconfirmed they will be unable to sign in after the switch; confirm them in Authentication → Users first.
4. Do not announce the site publicly until this step is done.
Known limitation: some mail systems pre-open links to scan them, which can use up a one-time link ("expired or already used").
If students report this, tell me and we will add a 6-digit code option instead of links.

## 6. Auth settings to review (availability depends on your Supabase plan)
- Minimum password length: the app requires 8; set the same or higher in Supabase.
- Leaked-password protection and CAPTCHA: enable if your plan offers them (CAPTCHA mainly protects sign-up and reset email sending).
- Email / sign-in rate limits: leave at defaults unless students are being blocked.
- Session timeouts: optional. Note a ban or suspension does not sign the person out, but the database blocks them anyway
  (restrictive RLS policies from migration 006): they cannot post, message, save or read listings; they can still read their own profile.

## 7. Photos of hidden listings (decision needed later, not blocking)
The `item-images` bucket is public by design, so a hidden or rejected listing's photo stays reachable by its URL.
Options: (A) accept for launch and rely on hiding the listing (recommended now); (B) delete the file when a moderator hides
it (needs a server-side function with elevated rights); (C) private bucket + signed URLs (largest change). Tell me if you want B or C.

## 8. Security tests
Run `docs/SECURITY_TESTS.md` sections A–E in the SQL Editor (every test rolls back) and the manual list in D.

## 9. First admin
Follow `docs/V3_MIGRATION_RUNBOOK.md` section 3, then re-run the V3 verification SQL (must still be 0 FAIL).

## Done when
- [ ] Check 1 shows `dauniv.ac.in` with `format_check = ok`
- [ ] Registration with an address outside the allow-list is rejected with the "approved university email" message
- [ ] Custom SMTP sends confirmation and reset emails (inbox, not spam)
- [ ] Confirm email is ON and a new sign-up must click the link before signing in
- [ ] Cross-device link works (or the known limitation is accepted)
- [ ] SECURITY_TESTS A–E all behave as expected
- [ ] First admin created; V3 verification still 0 FAIL
