# Local migration tests (dev tooling, not part of the Next.js build)

```bash
pip install pgserver psycopg2-binary     # Python tooling only; no npm dependency
npm run test:db                          # = python3 supabase/tests/local/test_v3.py
```
Starts an embedded PostgreSQL, imitates the parts of Supabase the migrations rely on (`stub.sql`: roles, `auth.users`/`auth.uid()`, `storage.*`, Realtime publication, Supabase's default grants), loads V1 schema + V2 migrations 002/003 + representative V2 data, then runs the preflight audit and migrations 005-009 and attacks them as the `authenticated`/`anon` roles. Takes a few minutes; prints PASS/FAIL per check.

**What it is not:** real Supabase. It cannot test Auth (GoTrue), the Storage API (size/MIME limits), Realtime delivery, platform-level object ownership (`ALTER POLICY` on `storage.objects`), or Vercel. See `docs/V3_MIGRATION_RUNBOOK.md` §5.

Verification-query tests: `python3 supabase/tests/local/test_verification.py` checks `supabase/verification/*.sql` (0 FAIL on a correct database; catches 21 injected defects; works on partially migrated databases; also as a non-superuser role).
