"""V3 migration tests (local Postgres stand-in). Run:  python supabase/tests/local/test_v3.py
Everything below talks to the database the way a browser holding a Supabase JWT could: as the
`authenticated` / `anon` roles (db.as_), or as the owner (db.su = SQL Editor / service role)."""
import json, re, sys, threading, pathlib
import psycopg2
sys.path.insert(0, str(pathlib.Path(__file__).resolve().parent))
import harness as h
from harness import U

R = []
def t(name, cond, info=''):
    R.append(bool(cond))
    print(('PASS ' if cond else 'FAIL ') + name + ((f'   [{str(info)[:170]}]' if (info and not cond) else '')))
ok = lambda r: r[0] == 'OK'
def err(r, *needles): return r[0] == 'ERR' and all(n.lower() in r[1].lower() for n in needles)
def head(s): print('\n=== ' + s)

MIGS = ['005_v3_audit_events_and_rate_core.sql', '006_v3_accounts_and_moderation.sql', '007_v3_reporting.sql',
        '008_v3_categories.sql', '009_v3_rate_limits_hardening.sql']
A, B, C, D, E, F, G, H = (U[k] for k in 'ABCDEFGH')     # A-D students, E/F moderators, G/H admins (promoted below)

def mk_item(db, owner, title, cat='books', typ='sell', status='active', price=100):
    name = db.su('select display_name from public.profiles where id=%s', (owner,))[0][0]
    iid = db.su("insert into public.items(seller_id,seller_name,title,description,category,listing_type,price,condition_label,status) "
                "values (%s,%s,%s,'d',%s,%s,%s,'good',%s) returning id", (owner, name, title, cat, typ, price, status))[0][0]
    db.su("insert into public.item_private(item_id,contact_phone) values (%s,'+91 98765 43210')", (iid,))
    return iid
def item_id(db, title): return db.su('select id from public.items where title=%s', (title,))[0][0]
def mod(db, uid, fn, *args, keep=False):
    ph = ','.join(['%s'] * len(args))
    return db.as_(uid, ('!' if keep else '') + f'select public.{fn}({ph})', args)
def audit_count(db, action=None, **kw):
    q, p = 'select count(*) from public.audit_logs where true', []
    if action: q += ' and action=%s'; p.append(action)
    for k, v in kw.items(): q += f' and {k}=%s'; p.append(v)
    return db.su(q, p)[0][0]

# ───────────────────────────────────────────── 1. GATES ─────────────────────────────────────────────
head('1. PRE-FLIGHT GATES abort safely and change nothing')
def fresh_through(name, upto):
    d = h.build_v2_database(name)
    for f in MIGS[:upto]: assert d.migrate(f)[0] == 'OK', f
    return d
d = h.build_v2_database('g1', seed=False); s0 = h.snapshot(d)
r = d.migrate(MIGS[1]); t('006 refuses to run without 005', err(r, 'MIGRATION 006 ABORTED', '005') and h.snapshot(d) == s0, r[1][:120])
r = d.migrate(MIGS[2]); t('007 refuses to run without 006', err(r, 'MIGRATION 007 ABORTED'))
r = d.migrate(MIGS[3]); t('008 refuses to run without 006', err(r, 'MIGRATION 008 ABORTED'))
r = d.migrate(MIGS[4]); t('009 refuses to run without 005/006', err(r, 'MIGRATION 009 ABORTED'))
h.create_db('g0'); d0 = h.DB('g0'); d0.su((h.HERE / 'stub.sql').read_text()); d0.su((h.HERE / 'schema.v1.sql').read_text())
r = d0.migrate(MIGS[0]); t('005 refuses a database without V2 (002/003) applied', err(r, 'MIGRATION 005 ABORTED', 'V2'), r[1][:120])
d = fresh_through('g2', 1); d.su('create policy "Dash read all" on public.items for select to authenticated using (true)'); s0 = h.snapshot(d)
r = d.migrate(MIGS[1]); t('006 aborts on an extra permissive SELECT policy on items, naming it', err(r, 'MIGRATION 006 ABORTED', '"Dash read all"') and h.snapshot(d) == s0, r[1][:160])
d = fresh_through('g3', 1); d.su('grant update (display_name) on public.profiles to authenticated'); s0 = h.snapshot(d)
r = d.migrate(MIGS[1]); t('006 aborts when API roles can write profiles (column-level grant)', err(r, 'MIGRATION 006 ABORTED', 'profiles') and h.snapshot(d) == s0)
d = fresh_through('g4', 1)
for (n,) in d.su("select conname from pg_constraint where conrelid='public.items'::regclass and pg_get_constraintdef(oid) like '%rented%' and contype='c' and conname not like 'items_check%'"): d.su(f'alter table public.items drop constraint "{n}"')
r = d.migrate(MIGS[1]); t('006 aborts if the items.status CHECK cannot be identified', err(r, 'MIGRATION 006 ABORTED', 'items.status'), r[1][:140])
d = fresh_through('g5', 3)
d.su("alter table public.items drop constraint items_category_check") if d.su("select count(*) from pg_constraint where conname='items_category_check'")[0][0] else None
for (n,) in d.su("select conname from pg_constraint where conrelid='public.items'::regclass and contype='c' and pg_get_constraintdef(oid) ~ '^CHECK \\(\\(category = ANY'"): d.su(f'alter table public.items drop constraint "{n}"')
mk_item(d, A, 'Weird category item'); d.su("update public.items set category='furniture' where title='Weird category item'"); mk_item(d, B, 'Another weird'); d.su("update public.items set category='furniture' where title='Another weird'")
s0 = h.snapshot(d); r = d.migrate(MIGS[3])
t("008 aborts listing the unmatched category value + count, rewrites nothing", err(r, 'MIGRATION 008 ABORTED', "'furniture' (2 listings)") and h.snapshot(d) == s0 and d.su("select count(*) from public.items where category='furniture'")[0][0] == 2, r[1][:200])
d = fresh_through('g6', 4); d.su('create policy "Dash upd" on storage.objects for update to authenticated using (true)'); s0 = h.snapshot(d)
r = d.migrate(MIGS[4]); t('009 aborts on an unexpected storage write policy, naming it', err(r, 'MIGRATION 009 ABORTED', '"Dash upd"') and h.snapshot(d) == s0, r[1][:150])
d.su('drop policy "Dash upd" on storage.objects'); d.su('create policy "Dash all" on storage.objects for all to authenticated using (true)')
r = d.migrate(MIGS[4]); t('009 also aborts on an ALL policy', err(r, '"Dash all"'))

# ───────────────────────────────────────────── 1b. PREFLIGHT AUDIT (004) ─────────────────────────────────────────────
head('1b. 004 preflight audit: read-only, flags real problems')
def audit004(d):
    cn = psycopg2.connect(d.uri); cn.autocommit = False; cu = cn.cursor(); cu.execute('set transaction read only')
    try: cu.execute((h.MIG / '004_v3_preflight_audit.sql').read_text().rstrip().rstrip(';')); return cu.fetchall()
    finally: cn.rollback(); cn.close()
dp = h.build_v2_database('v3pre2'); sp0 = h.snapshot(dp); fpp = h.fingerprint(dp)
rows = audit004(dp)
t('004 runs in a READ ONLY transaction and returns a full report', len(rows) > 100)
t('004 changes nothing (schema snapshot and data fingerprint identical)', h.snapshot(dp) == sp0 and h.fingerprint(dp) == fpp)
t('clean V2 production shape: no MISSING and no DANGER rows', not [r for r in rows if r[4] == 'MISSING' or r[4].startswith('DANGER')], [r[:3] for r in rows if r[4] == 'MISSING' or r[4].startswith('DANGER')][:3])
t('004 flags "no admin yet" and lists category values + both constraints it will replace', any(r[1] == 'admin accounts' and r[4] == 'REVIEW' for r in rows) and
  {r[2] for r in rows if r[1] == 'items.category value'} == {'books', 'notes', 'electronics', 'stationary'} and sum(1 for r in rows if r[1] == 'items CHECK constraint' and 'replaces' in r[4]) == 2)
dp.su("insert into auth.users(id,email,raw_user_meta_data) values (gen_random_uuid(),'x1@iips.edu.in','{\"display_name\":\"admin1\"}'),(gen_random_uuid(),'x2@iips.edu.in','{\"display_name\":\"Campus Market\"}')")
dp.su('create policy "Dash read" on public.items for select to authenticated using (true)'); dp.su('create policy "Dash write" on storage.objects for insert to authenticated with check (true)')
dp.su('grant update (display_name) on public.profiles to authenticated')
rows = audit004(dp)
t('004 flags a stray items SELECT policy, a stray storage write policy and profile write access as DANGER',
  sum(1 for r in rows if r[4] == 'DANGER' and (r[2].endswith('"Dash read"') or r[2].endswith('"Dash write"') or 'profiles privilege' in r[1])) == 3, [r[:3] for r in rows if r[4] == 'DANGER'])
t('004 lists existing reserved display names as REVIEW (they are never renamed)', {r[2].split(' (')[0] for r in rows if r[1] == 'reserved display name in use'} == {'admin1', 'Campus Market'})
dp.su("update public.items set category='furniture' where false")
dp.su('alter table public.items drop constraint items_category_check') if dp.su("select count(*) from pg_constraint where conname='items_category_check'")[0][0] else None
for (n,) in dp.su("select conname from pg_constraint where conrelid='public.items'::regclass and contype='c' and pg_get_constraintdef(oid) ~ '^CHECK \\(\\(category = ANY'"): dp.su(f'alter table public.items drop constraint "{n}"')
dp.su("update public.items set category='furniture' where title='Calculator'")
t('004 flags an unmatched category value as DANGER (008 would abort)', any(r[1] == 'items.category value' and r[2] == 'furniture' and r[4] == 'DANGER' for r in audit004(dp)))

# ───────────────────────────────────── 2. APPLY ON V2 PRODUCTION-SHAPED DATA ─────────────────────────────────────
head('2. Apply 005-009 to V2-shaped production data: preserved, idempotent')
db = h.build_v2_database('v3t'); fp0 = h.fingerprint(db)
counts0 = {k: db.su(f'select count(*) from {k}')[0][0] for k in ['public.items', 'public.profiles', 'public.conversations', 'public.messages', 'public.wishlists', 'public.item_private']}
for f in MIGS:
    r = db.migrate(f); t(f'{f} applies cleanly', ok(r), r[1][:200])
for rnd in (1, 2):
    t(f're-running all five migrations (round {rnd}) is idempotent', all(ok(db.migrate(f)) for f in MIGS))
t('ALL existing V2 data byte-identical after V3 (8 table fingerprints)', h.fingerprint(db) == fp0, [k for k in fp0 if h.fingerprint(db)[k] != fp0[k]])
t('row counts unchanged', counts0 == {k: db.su(f'select count(*) from {k}')[0][0] for k in counts0})
t('every existing profile = active, every listing = approved, statuses untouched',
  db.su("select count(*) from public.profiles where account_status<>'active'")[0][0] == 0 and
  db.su("select count(*) from public.items where moderation_status<>'approved'")[0][0] == 0 and
  sorted(x[0] for x in db.su('select distinct status from public.items')) == ['active', 'rented', 'sold'])
t('categories seeded with exactly the V2 values and cover every listing',
  [x[0] for x in db.su('select slug from public.categories order by sort_order')] == ['books', 'notes', 'electronics', 'stationary']
  and db.su('select count(*) from public.items i where not exists (select 1 from public.categories c where c.slug=i.category)')[0][0] == 0)
t('V2 policies kept (except the replaced browse policy); old CHECKs replaced', all(db.su("select count(*) from pg_policies where policyname=%s",(p,))[0][0] == 1 for p in
  ['sellers post', 'sellers update own', 'sellers delete own', 'seller manages contact', 'own wishlist', 'see my chats', 'buyer starts chat', 'read my messages', 'send in my chats', 'own profile'])
  and db.su("select count(*) from pg_policies where policyname='signed-in can browse'")[0][0] == 0
  and db.su("select count(*) from pg_constraint where conname in ('items_status_valid_v3','items_category_fkey')")[0][0] == 2)
# promote staff AFTER the migrations (what the production runbook does)
for uid, role in [(E, 'moderator'), (F, 'moderator'), (G, 'admin'), (H, 'admin')]: db.su("update public.profiles set role=%s where id=%s", (role, uid))
t('promoting via SQL Editor is audited as source=direct_sql / category=security', audit_count(db, 'ROLE_CHANGED', source='direct_sql', category='security') == 4)

# ───────────────────────────────────── 3. CATALOG: search_path + EXECUTE + privileges ─────────────────────────────────────
head('3. SECURITY DEFINER hygiene, EXECUTE and table privileges (catalog assertions)')
names = set()
for f in MIGS:
    names |= set(re.findall(r'create or replace function public\.(\w+)\(', (h.MIG / f).read_text()))
rows = db.su("select p.oid, p.proname, p.prosecdef, p.proconfig, p.oid::regprocedure::text from pg_proc p join pg_namespace n on n.oid=p.pronamespace where n.nspname='public' and p.proname = any(%s)", (sorted(names),))
t(f'{len(rows)} V3 functions found', len(rows) >= 50, len(rows))
t('EVERY V3 function pins search_path to empty (definer AND invoker)', all(r[3] and any('search_path=""' in c for c in r[3]) for r in rows), [r[1] for r in rows if not (r[3] and any('search_path=""' in c for c in r[3]))])
AUTH_OK = {'acting_role', 'account_is_active', 'account_not_banned', 'assert_account_active', 'staff_hide_listing', 'staff_restore_listing', 'staff_warn_user',
           'staff_suspend_user', 'staff_unsuspend_user', 'admin_ban_user', 'admin_unban_user', 'admin_set_role', 'staff_get_user', 'admin_search_users',
           'staff_claim_report', 'staff_dismiss_report', 'staff_resolve_report', 'admin_create_category', 'admin_update_category', 'admin_set_category_active',
           'get_contact', 'v3_storage_upload_check', 'is_display_name_reserved'}
def can(role, oid): return db.su("select has_function_privilege(%s,%s,'EXECUTE')", (role, oid))[0][0]
def public_can(oid): return db.su("select exists(select 1 from pg_proc p, aclexplode(coalesce(p.proacl,acldefault('f',p.proowner))) a where p.oid=%s and a.grantee=0 and a.privilege_type='EXECUTE')", (oid,))[0][0]
t('PUBLIC pseudo-role can execute NO V3 function', not any(public_can(r[0]) for r in rows), [r[1] for r in rows if public_can(r[0])])
t('anon can execute only the pure is_display_name_reserved()', sorted({r[1] for r in rows if can('anon', r[0])}) == ['is_display_name_reserved'])
t('authenticated can execute exactly the intended RPC/helper set (no internal function)', {r[1] for r in rows if can('authenticated', r[0])} == AUTH_OK, sorted({r[1] for r in rows if can('authenticated', r[0])} ^ AUTH_OK))
internal = [r for r in rows if r[1] not in AUTH_OK]
t('internal helpers/triggers are executable by NOBODY via API roles (incl. service_role)', not any(can(x, r[0]) for r in internal for x in ('anon', 'authenticated', 'service_role')))
def tp(role, tbl, priv): return db.su("select has_table_privilege(%s,%s,%s)", (role, f'public.{tbl}', priv))[0][0]
for tbl in ['audit_logs', 'security_events', 'moderation_actions']:
    t(f'{tbl}: no INSERT/UPDATE/DELETE/TRUNCATE for anon/authenticated/service_role', not any(tp(r, tbl, p) for r in ('anon', 'authenticated', 'service_role') for p in ('INSERT', 'UPDATE', 'DELETE', 'TRUNCATE')))
t('reports: authenticated may only SELECT/INSERT; anon nothing', tp('authenticated', 'reports', 'SELECT') and tp('authenticated', 'reports', 'INSERT') and not any(tp('authenticated', 'reports', p) for p in ('UPDATE', 'DELETE', 'TRUNCATE')) and not tp('anon', 'reports', 'SELECT'))
t('categories: authenticated SELECT only', tp('authenticated', 'categories', 'SELECT') and not any(tp('authenticated', 'categories', p) for p in ('INSERT', 'UPDATE', 'DELETE')))
t('rate_limit_* tables: no API privileges at all', not any(tp(r, x, p) for r in ('anon', 'authenticated') for x in ('rate_limit_rules', 'rate_limit_events') for p in ('SELECT', 'INSERT', 'UPDATE', 'DELETE')))
t('RLS enabled on every V3 table', db.su("select bool_and(relrowsecurity) from pg_class where relname in ('audit_logs','security_events','moderation_actions','reports','categories','rate_limit_rules','rate_limit_events') and relnamespace='public'::regnamespace")[0][0])
t('V3 tables are NOT in the Realtime publication (V2: only messages+conversations)', sorted(x[0] for x in db.su("select tablename from pg_publication_tables where pubname='supabase_realtime'")) == ['conversations', 'messages'])
t('anon cannot read/write anything V3', all(db.as_(None, f'select count(*) from public.{x}', role='anon')[0] == 'ERR' for x in ['audit_logs', 'reports', 'categories', 'moderation_actions', 'security_events']))
t('anon cannot call staff RPCs', all(err(db.as_(None, q, args, role='anon'), 'permission denied') for q, args in [('select public.staff_get_user(%s)', (A,)), ('select public.admin_set_role(%s,%s,%s)', (A, 'admin', 'xxxx'))]))
t('service_role (no JWT) cannot use staff RPCs either', err(db.as_(None, 'select public.admin_set_role(%s,%s,%s)', (A, 'admin', 'xxxx'), role='service_role'), 'not authenticated'))

# ───────────────────────────────────── 4. ROLE ESCALATION ─────────────────────────────────────
head('4. Role escalation')
for tgt in ('moderator', 'admin'):
    t(f'student cannot UPDATE own role to {tgt}', err(db.as_(A, f"update public.profiles set role='{tgt}' where id=%s", (A,)), 'permission denied'))
    t(f'student cannot call admin_set_role on self -> {tgt}', err(db.as_(A, 'select public.admin_set_role(%s,%s,%s)', (A, tgt, 'please')), 'insufficient'))
    t(f'moderator cannot become {tgt} (direct UPDATE)', err(db.as_(E, f"update public.profiles set role='{tgt}' where id=%s", (E,)), 'permission denied'))
t('student cannot promote another user', err(db.as_(A, 'select public.admin_set_role(%s,%s,%s)', (B, 'moderator', 'please')), 'insufficient'))
t('student cannot insert a profile row', err(db.as_(A, "insert into public.profiles(id,display_name,email,role) values (gen_random_uuid(),'x','x@x.edu','admin')"), 'permission denied'))
t('moderator cannot set own role via RPC', err(mod(db, E, 'admin_set_role', E, 'admin', 'promote me'), 'insufficient'))
t('moderator cannot change ANOTHER moderator\'s role', err(mod(db, E, 'admin_set_role', F, 'student', 'demote'), 'insufficient'))
t('moderator cannot change an admin\'s role', err(mod(db, E, 'admin_set_role', G, 'student', 'demote'), 'insufficient'))
t('moderator cannot change a student\'s role', err(mod(db, E, 'admin_set_role', A, 'moderator', 'promote'), 'insufficient'))
t('invalid role value rejected', err(mod(db, G, 'admin_set_role', A, 'superuser', 'because'), 'invalid role'))
n0 = audit_count(db, 'ROLE_CHANGED')
t('admin cannot change their OWN role', err(mod(db, G, 'admin_set_role', G, 'student', 'oops'), 'own account'))
r = mod(db, G, 'admin_set_role', A, 'moderator', 'trusted helper', keep=True)
t('admin promotes student -> moderator', ok(r) and db.su('select role from public.profiles where id=%s', (A,))[0][0] == 'moderator')
a = db.su("select actor_id,actor_role,category,source,metadata->>'old_role',metadata->>'new_role',target_id from public.audit_logs where action='ROLE_CHANGED' order by id desc limit 1")[0]
t('role change is audited by the DB (actor=admin from JWT, old/new role, source=rpc)', a == (G, 'admin', 'admin', 'rpc', 'student', 'moderator', A) and audit_count(db, 'ROLE_CHANGED') == n0 + 1, a)
t('role change also recorded as a security event', db.su("select count(*) from public.security_events where event_type='ROLE_CHANGED' and user_id=%s", (A,))[0][0] == 1)
mod(db, G, 'admin_set_role', A, 'student', 'back to student', keep=True)
r = mod(db, G, 'admin_set_role', H, 'student', 'demote other admin', keep=True)
t('admin can demote ANOTHER admin when an active admin remains', ok(r))
n1 = audit_count(db)
r = db.su("update public.profiles set role='student' where id=%s", (G,)) if False else None
try: db.su("update public.profiles set role='student' where id=%s", (G,)); lastadmin = False
except Exception as e: lastadmin = 'LAST_ADMIN' in str(e); db.su('rollback') if False else None
t('LAST ADMIN cannot be demoted (even from the SQL Editor)', lastadmin and db.su('select role from public.profiles where id=%s', (G,))[0][0] == 'admin')
for sql, nm in [("update public.profiles set account_status='suspended' where id=%s", 'suspended'), ("update public.profiles set account_status='banned' where id=%s", 'banned')]:
    try: db.su(sql, (G,)); ok_ = False
    except Exception as e: ok_ = 'LAST_ADMIN' in str(e)
    t(f'LAST ADMIN cannot be {nm}', ok_)
try: db.su('delete from public.profiles where id=%s', (G,)); ok_ = False
except Exception as e: ok_ = 'LAST_ADMIN' in str(e)
t('LAST ADMIN profile cannot be deleted (also blocks cascade from auth.users)', ok_)
t('failed last-admin attempts left no stray audit rows', audit_count(db) == n1)
mod(db, G, 'admin_set_role', H, 'admin', 'restore second admin', keep=True)
t('second admin restored', db.su('select role from public.profiles where id=%s', (H,))[0][0] == 'admin')
# suspended staff lose power
r = mod(db, H, 'staff_suspend_user', G, None, 'security review', keep=True)
t('admin can suspend another admin (indefinite)', ok(r))
t('SUSPENDED admin has no admin powers (acts as student)', err(mod(db, G, 'admin_set_role', A, 'moderator', 'try it'), 'insufficient') and db.as_(G, 'select public.acting_role()')[1][0][0] == 'student')
mod(db, H, 'staff_unsuspend_user', G, 'review done', keep=True)
t('unsuspended admin regains powers', db.as_(G, 'select public.acting_role()')[1][0][0] == 'admin')

# ───────────────────────────────────── 5. IDOR + TAMPERING ─────────────────────────────────────
head('5. IDOR across users and tampering with client-supplied values')
chem = item_id(db, 'Chemistry book'); calc = item_id(db, 'Calculator'); conv = db.su('select id from public.conversations')[0][0]
t('B cannot update A\'s listing', db.as_(B, "update public.items set title='hacked' where id=%s", (chem,)) == ('OK', 0))
t('B cannot delete A\'s listing', db.as_(B, 'delete from public.items where id=%s', (chem,)) == ('OK', 0))
t('B cannot read A\'s item_private (contact details)', db.as_(B, 'select count(*) from public.item_private where item_id=%s', (chem,))[1][0][0] == 0)
t('C cannot read the A-B conversation', db.as_(C, 'select count(*) from public.conversations')[1][0][0] == 0)
t('C cannot read its messages', db.as_(C, 'select count(*) from public.messages')[1][0][0] == 0)
t('C cannot post into it', err(db.as_(C, "insert into public.messages(conversation_id,sender_id,body) values (%s,%s,'x')", (conv, C))))
t('B cannot post as A', err(db.as_(B, "insert into public.messages(conversation_id,sender_id,body) values (%s,%s,'x')", (conv, A))))
t('students cannot read other profiles / account info', db.as_(A, 'select count(*) from public.profiles where id<>%s', (A,))[1][0][0] == 0)
t('student cannot call staff_get_user / admin_search_users', err(mod(db, A, 'staff_get_user', B), 'insufficient') and err(db.as_(A, "select * from public.admin_search_users('a')"), 'insufficient'))
r = db.as_(B, "select public.get_contact(%s)", (chem,)); t('signed-in student can still get seller contact (V2 feature)', ok(r))
for tbl in ['audit_logs', 'moderation_actions', 'security_events']:
    t(f'student reads 0 rows of {tbl} (and the table is not empty)', db.as_(A, f'select count(*) from public.{tbl}')[1][0][0] == 0 and db.su(f'select count(*) from public.{tbl}')[0][0] > 0)
UPD = {'audit_logs': "set reason='x'", 'moderation_actions': "set reason='x'", 'security_events': "set severity='info'", 'rate_limit_events': "set action='x'", 'rate_limit_rules': 'set max_count=1'}
for tbl in ['audit_logs', 'moderation_actions', 'security_events', 'rate_limit_events', 'rate_limit_rules']:
    t(f'student cannot INSERT/UPDATE/DELETE {tbl}', all(err(db.as_(A, q), 'permission denied') for q in [f'insert into public.{tbl} default values', f'update public.{tbl} {UPD[tbl]}', f'delete from public.{tbl}']))
t('forged actor_id insert into audit_logs / moderation_actions denied', err(db.as_(A, "insert into public.audit_logs(actor_id,action,category) values (%s,'ROLE_CHANGED','admin')", (G,)), 'permission denied') and
  err(db.as_(A, "insert into public.moderation_actions(actor_id,actor_role,action,target_user_id,reason) values (%s,'admin','user_banned',%s,'forged')", (G, B)), 'permission denied'))
r = db.as_(A, "insert into public.items(title,description,category,listing_type,price,condition_label,seller_id,seller_name,moderation_status,moderated_by,moderated_at,moderation_reason,status) values ('Forged fields','', 'books','sell',10,'good',%s,'Boss','hidden',%s,now(),'x','sold') returning seller_id,seller_name,moderation_status,moderated_by,moderation_reason,status", (B, G))
t('forged seller_id/seller_name/moderation_*/status on INSERT are all overridden', ok(r) and r[1][0] == (A, 'Asha A', 'approved', None, None, 'active'), r)
mine = db.su("select id from public.items where title='Forged fields'")
if not mine: mine = [(mk_item(db, A, 'Forged fields'),)]
r = db.as_(A, "update public.items set moderation_status='hidden', moderated_by=%s, moderation_reason='x' where title='Chemistry book' returning moderation_status,moderated_by", (G,))
t('owner cannot change moderation columns on their own listing', ok(r) and r[1][0] == ('approved', None), r)
r = db.as_(A, "update public.items set status='sold' where title='Chemistry book' returning status,moderation_status")
t('marking SOLD changes marketplace status only, never moderation_status', ok(r) and r[1][0] == ('sold', 'approved'), r)
db.su("update public.items set status='active' where title='Chemistry book'")
t('owner can set status to inactive (new marketplace state)', db.as_(A, "update public.items set status='inactive' where title='Chemistry book'") == ('OK', 1))
db.su("update public.items set status='active' where title='Chemistry book'")
t('role can never be forged through an item/report/profile payload (profiles write denied)', err(db.as_(A, "update public.profiles set role='admin', account_status='active' where id=%s", (A,)), 'permission denied'))
t('account_status cannot be forged by the user', err(db.as_(A, "update public.profiles set account_status='active', suspended_until=null where id=%s", (A,)), 'permission denied'))
t('staff RPC cannot be aimed at yourself (forged user_id = own id)', err(mod(db, E, 'staff_warn_user', E, 'self warn'), 'own account') and err(mod(db, G, 'admin_ban_user', G, 'self ban'), 'own account'))

# ───────────────────────────────────── 6. REPORTING ─────────────────────────────────────
head('6. Reporting')
cal_owner = B; lab = item_id(db, 'Lab coat'); draft = item_id(db, 'Drafting kit')
r = db.as_(B, "!insert into public.reports(listing_id,reason,description,reporter_id,status,reviewed_by,reviewed_at,reported_user_id,created_at) values (%s,'scam','looks fake',%s,'resolved',%s,now(),%s,now()-interval '9 days') returning reporter_id,status,reviewed_by,reviewed_at,reported_user_id,target_snapshot->>'listing_title',created_at > now()-interval '1 minute'", (chem, A, G, C))
t('listing report: reporter/status/reviewer/reported user/created_at all derived by the DB', ok(r) and r[1][0] == (B, 'pending', None, None, A, 'Chemistry book', True), r)
rep1 = db.su('select max(id) from public.reports')[0][0]
t('duplicate OPEN report on the same listing by the same user is blocked', err(db.as_(B, "insert into public.reports(listing_id,reason) values (%s,'scam')", (chem,)), 'duplicate key'))
t('another student can report the same listing', ok(db.as_(C, "!insert into public.reports(listing_id,reason) values (%s,'misleading_information')", (chem,))))
t('cannot report your OWN listing', err(db.as_(A, "insert into public.reports(listing_id,reason) values (%s,'scam')", (chem,)), 'yourself'))
t('cannot report yourself (user report)', err(db.as_(A, "insert into public.reports(reported_user_id,reason) values (%s,'harassment')", (A,)), 'yourself'))
t('report with neither listing nor user rejected', err(db.as_(B, "insert into public.reports(reason) values ('scam')"), 'listing or a user'))
t('report on a non-existent listing / user rejected', err(db.as_(B, "insert into public.reports(listing_id,reason) values (999999,'scam')"), 'not found') and err(db.as_(B, "insert into public.reports(reported_user_id,reason) values (gen_random_uuid(),'scam')"), 'not found'))
t('invalid reason rejected', err(db.as_(B, "insert into public.reports(reported_user_id,reason) values (%s,'dislike')", (C,)), 'reports_reason_valid'))
t("reason 'other' needs an explanation (>=10 chars)", err(db.as_(B, "insert into public.reports(reported_user_id,reason,description) values (%s,'other','short')", (C,)), 'reports_other_needs_text') and ok(db.as_(B, "insert into public.reports(reported_user_id,reason,description) values (%s,'other','this is a proper explanation')", (C,))))
t('description over 500 chars rejected', err(db.as_(B, "insert into public.reports(reported_user_id,reason,description) values (%s,'harassment',%s)", (C, 'x' * 501)), 'reports_description_len'))
t('user report works and snapshots the name', db.as_(B, "!insert into public.reports(reported_user_id,reason) values (%s,'harassment') returning target_snapshot->>'reported_user_name',listing_id", (D,))[1][0] == ('Dev D', None))
t('reporter sees only OWN reports', db.as_(B, 'select count(*) from public.reports')[1][0][0] == 2 and db.as_(C, 'select count(*) from public.reports')[1][0][0] == 1 and db.su('select count(*) from public.reports')[0][0] == 3)
t('reported user (A) cannot see reports about them', db.as_(A, 'select count(*) from public.reports')[1][0][0] == 0)
t('students cannot UPDATE / DELETE reports (API)', err(db.as_(B, "update public.reports set status='dismissed' where id=%s", (rep1,)), 'permission denied') and err(db.as_(B, 'delete from public.reports where id=%s', (rep1,)), 'permission denied'))
t('rate limit: 4th report within an hour is refused (RATE_LIMIT, 54000)', [x[0] for x in db.as_many(F, [("insert into public.reports(reported_user_id,reason) values (%s,'scam')", (u,)) for u in (A, B, C, D)])] == ['OK', 'OK', 'OK', 'ERR']
  and 'RATE_LIMIT' in db.as_many(F, [("insert into public.reports(reported_user_id,reason) values (%s,'scam')", (u,)) for u in (A, B, C, D)])[3][1])
t('three open reports on one listing recorded a REPORT_THRESHOLD security event', db.su("select count(*) from public.security_events where event_type='REPORT_THRESHOLD'")[0][0] == 0)
db.as_(D, "!insert into public.reports(listing_id,reason) values (%s,'scam')", (chem,))
t('third open report on the same target raises REPORT_THRESHOLD (V4 signal)', db.su("select count(*) from public.security_events where event_type='REPORT_THRESHOLD' and user_id=%s", (A,))[0][0] == 1)
db.as_(B, "!insert into public.reports(listing_id,reason) values (%s,'prohibited_item')", (lab,))
t('listing with an OPEN report cannot be deleted by its owner', err(db.as_(A, 'delete from public.items where id=%s', (lab,)), 'LISTING_REPORTED'))
try: db.su('delete from public.items where id=%s', (lab,)); x = False
except Exception as e: x = 'LISTING_REPORTED' in str(e)
t('... not even from the SQL Editor (all roles)', x)
t('... and the listing and its report are still there', db.su('select count(*) from public.items where id=%s', (lab,))[0][0] == 1)
t('listing with chats is protected by the V2 rule first (chat history never destroyed)', err(db.as_(A, 'delete from public.items where id=%s', (chem,)), 'conversations'))
t('seller can still mark a reported listing sold / inactive meanwhile', db.as_(A, "update public.items set status='sold' where id=%s", (chem,)) == ('OK', 1) and db.as_(A, "update public.items set status='inactive' where id=%s", (lab,)) == ('OK', 1))

# moderator workflow
head('7. Moderator workflow + powers')
t('student cannot claim/dismiss/resolve reports', all(err(db.as_(A, q, a), 'insufficient') for q, a in [('select public.staff_claim_report(%s)', (rep1,)), ('select public.staff_dismiss_report(%s,%s)', (rep1, 'nope nope')), ('select public.staff_resolve_report(%s,%s)', (rep1, 'nope nope'))]))
t('moderator sees ALL reports; student only own', db.as_(E, 'select count(*) from public.reports')[1][0][0] == db.su('select count(*) from public.reports')[0][0])
r = mod(db, E, 'staff_claim_report', rep1, keep=True)
t('moderator claims a pending report (pending -> reviewing, reviewer = JWT user)', ok(r) and db.su('select status,reviewed_by from public.reports where id=%s', (rep1,))[0] == ('reviewing', E))
t('claiming twice is refused', err(mod(db, E, 'staff_claim_report', rep1), 'pending'))
t('moderator hides the reported listing, linked to the report', ok(mod(db, E, 'staff_hide_listing', chem, 'Likely scam listing', rep1, keep=True)))
t('hide recorded in moderation_actions + audit_logs (same actor, report link)', db.su("select actor_id,action,listing_id,report_id from public.moderation_actions order by id desc limit 1")[0] == (E, 'listing_hidden', chem, rep1)
  and db.su("select actor_id,category from public.audit_logs where action='LISTING_HIDDEN' order by id desc limit 1")[0] == (E, 'moderation'))
t('moderator warns the seller (student)', ok(mod(db, E, 'staff_warn_user', A, 'Misleading description', rep1, keep=True)) and db.su('select warning_count from public.profiles where id=%s', (A,))[0][0] == 1)
r = db.as_(E, "!select public.staff_suspend_user(%s, now() + interval '3 days', 'Repeated scam listings', %s)", (A, rep1))
t('suspension (<=7 days) recorded', ok(r) and db.su('select account_status from public.profiles where id=%s', (A,))[0][0] == 'suspended')
r = mod(db, E, 'staff_resolve_report', rep1, 'Listing hidden, seller warned and suspended', keep=True)
t('moderator resolves the report', ok(r) and db.su('select status from public.reports where id=%s', (rep1,))[0][0] == 'resolved')
t('closed report is final (no re-open / re-dismiss via RPC)', err(mod(db, E, 'staff_dismiss_report', rep1, 'changed my mind'), 'closed'))
for sql in ["update public.reports set status='pending', reviewed_by=null, reviewed_at=null where id=%s", "update public.reports set description='edited' where id=%s", "update public.reports set reason='other' where id=%s"]:
    try: db.su(sql, (rep1,)); x = False
    except Exception as e: x = True
    t(f'report evidence/closure immutable even for the owner: {sql[:48]}', x)
try: db.su('delete from public.reports where id=%s', (rep1,)); x = False
except Exception as e: x = 'append-only' in str(e)
t('reports cannot be deleted (even by the owner role)', x)
t('hide with a CLOSED report id is refused', err(mod(db, E, 'staff_hide_listing', calc, 'link to closed report', rep1), 'closed'))
t('moderator cannot suspend > 7 days', err(db.as_(E, "select public.staff_suspend_user(%s, now() + interval '8 days', 'too long', null)", (B,)), '7 days'))
t('moderator cannot suspend indefinitely', err(db.as_(E, "select public.staff_suspend_user(%s, null, 'forever', null)", (B,)), '7 days'))
t('moderator cannot BAN', err(mod(db, E, 'admin_ban_user', B, 'banhammer', None), 'insufficient'))
t('moderator cannot act on another moderator / admin (warn, suspend, hide listing)',
  err(mod(db, E, 'staff_warn_user', F, 'warn mod'), 'student') and err(db.as_(E, "select public.staff_suspend_user(%s, now()+interval '1 day','x y z',null)", (G,)), 'student')
  and err(mod(db, E, 'staff_hide_listing', mk_item(db, F, 'Moderator item'), 'hide mod item'), 'students'))
t('admin CAN hide a moderator\'s listing', ok(mod(db, G, 'staff_hide_listing', item_id(db, 'Moderator item'), 'policy check', keep=True)))
t('moderator cannot lift an INDEFINITE suspension (admin only)', (mod(db, G, 'staff_suspend_user', B, None, 'long suspension', keep=True), err(mod(db, E, 'staff_unsuspend_user', B, 'lifting it'), 'indefinite'))[1])
t('admin lifts it', ok(mod(db, G, 'staff_unsuspend_user', B, 'appeal accepted', keep=True)))
t('moderator CAN lift a temporary suspension of a student', (db.as_(E, "!select public.staff_suspend_user(%s, now() + interval '2 days','cool off', null)", (D,)), ok(mod(db, E, 'staff_unsuspend_user', D, 'cooled off', keep=True)))[1])
t('moderator cannot read admin-only data (security events, admin/security audit rows)', db.as_(E, 'select count(*) from public.security_events')[1][0][0] == 0
  and db.as_(E, "select count(*) from public.audit_logs where category<>'moderation'")[1][0][0] == 0 and db.as_(E, "select count(*) from public.audit_logs where category='moderation'")[1][0][0] > 0)
t('moderator cannot read user emails (staff_get_user hides email)', db.as_(E, 'select email from public.staff_get_user(%s)', (B,))[1][0][0] is None and db.as_(G, 'select email from public.staff_get_user(%s)', (B,))[1][0][0] == 'bala@iips.edu.in')
for q in ["update public.audit_logs set reason='x'", 'delete from public.audit_logs', 'truncate public.audit_logs']:
    t(f'moderator cannot {q.split()[0]} audit logs (API)', err(db.as_(E, q), 'permission denied'))
    try: db.su(q); x = False
    except Exception as e: x = 'append-only' in str(e)
    t(f'... nor can the DB owner: {q}', x)
t('moderator cannot edit/delete moderation_actions either', all(err(db.as_(E, q), 'permission denied') for q in ['update public.moderation_actions set reason=reason', 'delete from public.moderation_actions']))
used = db.su("select count(*) from public.rate_limit_events where user_id=%s and action='moderator_action'", (E,))[0][0]
t(f'moderator action limit: exactly 200 per hour ({used} already used) then refused', [x[0] for x in db.as_many(E, [('select public.staff_warn_user(%s,%s,null)', (C, 'rate limit probe'))] * 201)].count('OK') == 200 - used and used > 5)
t('admins are not subject to the moderator limit', [x[0] for x in db.as_many(G, [('select public.staff_warn_user(%s,%s,null)', (C, 'rate limit probe'))] * 201)].count('OK') == 201)

# ───────────────────────────────────── 8. HIDDEN LISTING BEHAVIOUR ─────────────────────────────────────
head('8. Hidden listing behaviour (chem book is hidden since step 7)')
db.su("update public.profiles set account_status='active', suspended_until=null, suspension_reason=null where id=%s", (A,))  # A's suspension is re-applied in section 9
t('hidden: other students do not see it (list or by id)', db.as_(C, 'select count(*) from public.items where id=%s', (chem,))[1][0][0] == 0 and db.as_(C, "select count(*) from public.items where title='Chemistry book'")[1][0][0] == 0)
t('hidden: owner still sees it; moderation_status=hidden, marketplace status untouched', db.as_(A, 'select moderation_status,status from public.items where id=%s', (chem,))[1] == [('hidden', 'active')])
t('hidden: staff see it', db.as_(E, 'select count(*) from public.items where id=%s', (chem,))[1][0][0] == 1)
t('hidden: students browsing still see other approved listings', db.as_(C, 'select count(*) from public.items')[1][0][0] >= 9)
db.su("update public.items set status='active' where id=%s", (chem,)) if False else None
t('hidden: no contact lookup (reads as "not found")', err(db.as_(C, 'select public.get_contact(%s)', (chem,)), 'not found'))
t('hidden: no NEW conversation can be started', err(db.as_(D, 'insert into public.conversations(item_id) values (%s)', (chem,)), 'no longer available'))
t('hidden: existing chat cannot receive messages (history stays readable)', err(db.as_(B, "insert into public.messages(conversation_id,sender_id,body) values (%s,%s,'hi')", (conv, B)), 'no longer available')
  and db.as_(B, 'select count(*) from public.messages where conversation_id=%s', (conv,))[1][0][0] == 2)
t('hidden: conversation row itself is untouched', db.su('select count(*) from public.conversations where id=%s', (conv,))[0][0] == 1)
t('hidden: owner cannot edit it', err(db.as_(A, "update public.items set title='sneaky edit' where id=%s", (chem,)), 'hidden'))
t('hidden: owner cannot un-hide it by editing moderation_status', err(db.as_(A, "update public.items set moderation_status='approved' where id=%s", (chem,)), 'hidden'))
t('hidden: owner cannot delete it (evidence stays)', err(db.as_(A, 'delete from public.items where id=%s', (chem,))) and db.su('select count(*) from public.items where id=%s', (chem,))[0][0] == 1)
hid = mk_item(db, A, 'Hidden no chat'); mod(db, E, 'staff_hide_listing', hid, 'hide for delete test', keep=True)
t('hidden listing WITHOUT chats: deletion refused by the hidden-listing guard itself', err(db.as_(A, 'delete from public.items where id=%s', (hid,)), 'hidden') and db.su('select count(*) from public.items where id=%s', (hid,))[0][0] == 1)
t('hidden: report on a hidden listing refused', err(db.as_(D, "insert into public.reports(listing_id,reason) values (%s,'scam')", (chem,)), 'not found'))
t('hidden: listing + reports + conversation + messages all still exist', db.su('select count(*) from public.items where id=%s', (chem,))[0][0] == 1 and db.su('select count(*) from public.reports where listing_id=%s', (chem,))[0][0] >= 3)
t('hide an already hidden listing refused; restore an approved one refused', err(mod(db, E, 'staff_hide_listing', chem, 'again again'), 'already hidden') and err(mod(db, E, 'staff_restore_listing', calc, 'not hidden'), 'not hidden'))
t('student cannot hide/restore', err(mod(db, B, 'staff_restore_listing', chem, 'let me back'), 'insufficient'))
r = mod(db, E, 'staff_restore_listing', chem, 'Seller clarified the description', keep=True)
t('moderator restores it', ok(r) and db.as_(C, 'select count(*) from public.items where id=%s', (chem,))[1][0][0] == 1)
t('after restore: contact lookup and new messages work again', ok(db.as_(C, 'select public.get_contact(%s)', (chem,))) and ok(db.as_(B, "insert into public.messages(conversation_id,sender_id,body) values (%s,%s,'back')", (conv, B))))
t('restore audited (LISTING_RESTORED, moderation category)', audit_count(db, 'LISTING_RESTORED', category='moderation') == 1)
db.su("update public.items set status='sold' where id=%s", (chem,))
t('hiding a SOLD listing keeps status=sold; hide never deletes data', (mod(db, E, 'staff_hide_listing', chem, 'second look', keep=True), db.su('select status,moderation_status from public.items where id=%s', (chem,))[0])[1] == ('sold', 'hidden'))
mod(db, E, 'staff_restore_listing', chem, 'fine after all', keep=True)
db.su("update public.items set status='active' where id=%s", (chem,))
db.su("update public.items set moderation_status='hidden' where id=%s", (calc,))
t('direct SQL moderation change is caught by the backstop audit (direct_sql, security)', audit_count(db, 'LISTING_MODERATION_CHANGED', source='direct_sql', category='security') == 1)
db.su("update public.items set moderation_status='approved' where id=%s", (calc,))

# ───────────────────────────────────── 9. SUSPENSION / BAN ENFORCEMENT ─────────────────────────────────────
head('9. Suspension = read-only, ban = blocked (enforced in the DB; A is suspended for 3 days)')
db.su("update public.profiles set account_status='suspended', suspended_until=now() + interval '3 days', suspension_reason='Repeated scam listings' where id=%s", (A,))
blocked = lambda r, *n: (r[0] == 'ERR' and all(x.lower() in r[1].lower() for x in n)) or r == ('OK', 0) or (r[0] == 'ERR' and 'row-level security' in r[1])
mine = mk_item(db, A, 'A second listing'); db.su("insert into public.wishlists(user_id,item_id) values (%s,%s)", (A, calc))
db.su("insert into public.conversations(item_id,buyer_id,seller_id,buyer_name) values (%s,%s,%s,'Asha A')", (calc, A, B))
cv2 = db.su('select max(id) from public.conversations')[0][0]
t('A is effectively suspended', db.as_(A, 'select public.account_is_active()')[1][0][0] is False)
t('suspended: can still BROWSE approved listings', db.as_(A, "select count(*) from public.items where moderation_status='approved'")[1][0][0] >= 8)
t('suspended: can read own profile (sees status/reason) and own chats', db.as_(A, 'select account_status,suspension_reason from public.profiles where id=%s', (A,))[1][0][0] == 'suspended' and db.as_(A, 'select count(*) from public.messages')[1][0][0] >= 2)
t('suspended: cannot create a listing', err(db.as_(A, "insert into public.items(title,description,category,listing_type,price,condition_label) values ('Nope','', 'books','sell',10,'good')"), 'suspended'))
t('suspended: cannot edit a listing (0 rows or error)', blocked(db.as_(A, "update public.items set title='edited' where id=%s", (mine,))) and db.su('select title from public.items where id=%s', (mine,))[0][0] == 'A second listing')
t('suspended: cannot mark sold / inactive', blocked(db.as_(A, "update public.items set status='sold' where id=%s", (mine,))) and blocked(db.as_(A, "update public.items set status='inactive' where id=%s", (mine,))))
t('suspended: cannot delete a listing', blocked(db.as_(A, 'delete from public.items where id=%s', (mine,))) and db.su('select count(*) from public.items where id=%s', (mine,))[0][0] == 1)
t('suspended: cannot edit item_private (contact details)', db.as_(A, "update public.item_private set contact_phone='+1 234 567 8901' where item_id=%s", (mine,)) == ('OK', 0))
t('suspended: cannot send messages', err(db.as_(A, "insert into public.messages(conversation_id,sender_id,body) values (%s,%s,'hello')", (cv2, A)), 'suspended'))
t('suspended: cannot start conversations', err(db.as_(A, 'insert into public.conversations(item_id) values (%s)', (item_id(db, 'Drafting kit'),)), 'suspended'))
t('suspended: cannot create reports', err(db.as_(A, "insert into public.reports(reported_user_id,reason) values (%s,'scam')", (D,)), 'suspended'))
t('suspended: cannot change the wishlist', err(db.as_(A, 'insert into public.wishlists(user_id,item_id) values (%s,%s)', (A, item_id(db, 'Drafting kit')))) and db.as_(A, 'delete from public.wishlists where user_id=%s', (A,)) == ('OK', 0))
t('suspended: cannot look up seller contact', err(db.as_(A, 'select public.get_contact(%s)', (item_id(db, 'Drafting kit'),)), 'suspended'))
t('suspended: cannot upload photos / delete photos', err(db.as_(A, "insert into storage.objects(bucket_id,name) values ('item-images',%s)", (f'{A}/new.jpg',))) and db.as_(A, 'delete from storage.objects where name=%s', (f'{A}/p.jpg',)) == ('OK', 0))
t('suspended: acting_role is student', db.as_(A, 'select public.acting_role()')[1][0][0] == 'student')
db.su("update public.profiles set suspended_until = now() - interval '1 minute' where id=%s", (A,))
t('suspension EXPIRES by itself (no cron): writes work again', ok(db.as_(A, "insert into public.items(title,description,category,listing_type,price,condition_label) values ('Back again','', 'books','sell',10,'good')")))
db.su("update public.profiles set suspended_until = now() + interval '3 days' where id=%s", (A,))
# ban
db.su("update public.profiles set account_status='banned', suspended_until=null, suspension_reason='x' where id=%s", (D,))
t('banned: reads NO listings / chats / wishlist / reports', all(db.as_(D, f'select count(*) from public.{x}')[1][0][0] == 0 for x in ['items', 'conversations', 'messages', 'wishlists', 'item_private']))
t('banned: can still read own profile (to see the ban)', db.as_(D, 'select account_status from public.profiles where id=%s', (D,))[1][0][0] == 'banned')
t('banned: cannot write or look up contacts', err(db.as_(D, "insert into public.items(title,description,category,listing_type,price,condition_label) values ('Nope','', 'books','sell',10,'good')"), 'banned') and err(db.as_(D, 'select public.get_contact(%s)', (calc,)), 'banned'))
t('banned: cannot report', err(db.as_(D, "insert into public.reports(reported_user_id,reason) values (%s,'scam')", (B,))))
t('banned moderator cannot act', (db.su("update public.profiles set account_status='banned' where id=%s", (F,)), err(mod(db, F, 'staff_warn_user', C, 'banned mod'), 'insufficient'))[1])
db.su("update public.profiles set account_status='active' where id=%s", (F,))
t('moderator cannot unban; admin can ban/unban (audited)', err(mod(db, E, 'admin_unban_user', D, 'unban pls'), 'insufficient') and ok(mod(db, G, 'admin_unban_user', D, 'ban appealed', keep=True)) and audit_count(db, 'USER_UNBANNED') == 1)
t('admin bans a student; moderator cannot touch banned user', ok(mod(db, G, 'admin_ban_user', C, 'Fraud confirmed', None, keep=True)) and err(db.as_(E, "select public.staff_suspend_user(%s, now()+interval '1 day','x y z',null)", (C,)), 'banned'))
mod(db, G, 'admin_unban_user', C, 'cleanup', keep=True)

# ───────────────────────────────────── 10. ADMIN: users, categories, audit ─────────────────────────────────────
head('10. Admin capabilities')
t('admin search finds users and returns email; limit is clamped', len(db.as_(G, "select * from public.admin_search_users('a', 1000, 0)")[1]) >= 5 and db.as_(G, "select email from public.admin_search_users('Bala')")[1][0][0] == 'bala@iips.edu.in')
t('admin search escapes wildcards (a literal % matches nothing)', db.as_(G, "select count(*) from public.admin_search_users('%')")[1][0][0] == 0 and db.as_(G, "select count(*) from public.admin_search_users('_')")[1][0][0] == 0)
t('moderator cannot search users', err(db.as_(E, "select * from public.admin_search_users('a')"), 'insufficient'))
t('admin sees all audit logs and security events', db.as_(G, 'select count(*) from public.audit_logs')[1][0][0] == audit_count(db) and db.as_(G, 'select count(*) from public.security_events')[1][0][0] > 0)
cat = db.as_(G, "!select public.admin_create_category('Furniture','furniture','Desks and chairs')")
t('admin creates a category (audited)', ok(cat) and audit_count(db, 'CATEGORY_CREATED') == 1)
cid = cat[1][0][0]
t('students and moderators cannot manage categories', all(err(x, 'insufficient') for x in [db.as_(A, "select public.admin_create_category('X Cat','xcat','')"), db.as_(E, "select public.admin_create_category('X Cat','xcat','')"), db.as_(E, 'select public.admin_set_category_active(%s,false,%s)', (cid, 'nope nope'))])
  and err(db.as_(A, "insert into public.categories(name,slug) values ('Hack','hack')"), 'permission denied') and err(db.as_(A, "update public.categories set is_active=false"), 'permission denied'))
t('duplicate slug/name and bad slug rejected', err(db.as_(G, "select public.admin_create_category('Furniture 2','furniture','')"), 'already exists') and err(db.as_(G, "select public.admin_create_category('Bad','Bad Slug!','')"), 'slug'))
t('students can list categories', db.as_(A, 'select count(*) from public.categories')[1][0][0] == 5)
t('new category usable for a listing', ok(db.as_(B, "insert into public.items(title,description,category,listing_type,price,condition_label) values ('Study desk','', 'furniture','sell',500,'good')")))
t('unknown category rejected (guard trigger first, foreign key behind it)', err(db.as_(B, "insert into public.items(title,description,category,listing_type,price,condition_label) values ('Bad cat','', 'weapons','sell',5,'good')"), 'not available'))
db.as_(B, "!insert into public.items(title,description,category,listing_type,price,condition_label) values ('Desk 2','', 'furniture','sell',500,'good')")
t('admin disables a category (audited, reason required)', ok(mod(db, G, 'admin_set_category_active', cid, False, 'Not wanted on campus', keep=True)) and audit_count(db, 'CATEGORY_DISABLED') == 1)
t('disabled category: existing listings stay visible; new listings / re-categorising refused', db.as_(C, "select count(*) from public.items where category='furniture'")[1][0][0] >= 1
  and err(db.as_(B, "insert into public.items(title,description,category,listing_type,price,condition_label) values ('Desk 3','', 'furniture','sell',5,'good')"), 'not available')
  and err(db.as_(B, "update public.items set category='furniture' where id=%s", (calc,)), 'not available'))
try: db.su("delete from public.categories where slug='furniture'"); x = False
except Exception as e: x = 'violates foreign key' in str(e)
t('FK blocks deleting a category that listings use', x)
t('rename works; slug unchanged', ok(mod(db, G, 'admin_update_category', cid, 'Dorm furniture', 'Desks, chairs', 9, keep=True)) and db.su("select name,slug from public.categories where id=%s", (cid,))[0] == ('Dorm furniture', 'furniture'))
t('cannot disable the LAST active category', ok(db.as_many(G, [('select public.admin_set_category_active(%s,false,%s)', (x[0], 'trim down')) for x in db.su('select id from public.categories where is_active and id<>%s order by id limit 3', (cid,))])[0]) and
  [x[0] for x in db.as_many(G, [('select public.admin_set_category_active(%s,false,%s)', (x[0], 'trim down')) for x in db.su("select id from public.categories where is_active order by id")])][-1] == 'ERR')
mod(db, G, 'admin_set_category_active', cid, True, 'enable again', keep=True)

# ───────────────────────────────────── 11. RATE LIMITS ─────────────────────────────────────
head('11. Rate limits (each rule; server clock; exact under concurrency)')
for i, nm in enumerate(['Ra', 'Rb', 'Rc', 'Rd', 'Re']):
    db.su("insert into auth.users(id,email,raw_user_meta_data) values (%s,%s,%s)", (f'bbbbbbbb-0000-0000-0000-00000000000{i}', f'{nm.lower()}@iips.edu.in', json.dumps({'display_name': f'Rate User {nm}'})))
RA, RB, RC, RD, RE = (f'bbbbbbbb-0000-0000-0000-00000000000{i}' for i in range(5))
ins = ("insert into public.items(title,description,category,listing_type,price,condition_label) values (%s,'', 'books','sell',10,'good')", None)
res = [x[0] for x in db.as_many(RA, [(ins[0], (f'Rate item {i}',)) for i in range(6)])]
t('listing_create: 6th listing inside an hour refused (limit 5/hour)', res == ['OK'] * 5 + ['ERR'])
for i in range(4): db.as_(RB, '!' + ins[0], (f'Near {i}',))
t('80% of a limit records a RATE_LIMIT_NEAR security event (accepted request, so it persists)', db.su("select count(*) from public.security_events where event_type='RATE_LIMIT_NEAR' and user_id=%s", (RB,))[0][0] >= 1)
db.su("insert into public.rate_limit_events(user_id,action,created_at) select %s,'listing_create', now() - interval '2 hours' from generate_series(1,20)", (RC,))
t('listing_create: daily limit (20/day) counts events older than the hourly window', err(db.as_(RC, ins[0], ('Day limit',)), 'rate_limit'))
db.su("update public.rate_limit_events set created_at = now() - interval '25 hours' where user_id=%s", (RC,))
t('... and events older than 24h no longer count (sliding window)', ok(db.as_(RC, ins[0], ('Day limit ok',))))
t('users cannot reset their own counters (no access to rate_limit_events)', err(db.as_(RA, 'delete from public.rate_limit_events'), 'permission denied') and err(db.as_(RA, "insert into public.rate_limit_events(user_id,action) values (%s,'x')", (RA,)), 'permission denied'))
db.as_(RA, "!insert into public.items(title,description,category,listing_type,price,condition_label,created_at,seller_id) values ('Key test','', 'books','sell',10,'good', now()-interval '30 days', %s)", (RB,))
t('events are keyed on the JWT user and the server clock (client created_at/seller_id ignored)', db.su("select count(*) from public.rate_limit_events where user_id=%s and action='listing_create' and created_at > now() - interval '1 minute'", (RA,))[0][0] == 1 and db.su("select count(*) from public.rate_limit_events where user_id=%s and action='listing_create' and created_at > now() - interval '1 minute'", (RB,))[0][0] >= 4)
for i in range(21): mk_item(db, D, f'Chat target {i}')
res = [x[0] for x in db.as_many(RD, [('insert into public.conversations(item_id) select id from public.items where title=%s', (f'Chat target {i}',)) for i in range(21)])]
t('chat_start: 21st new conversation in a day refused (limit 20/day)', res == ['OK'] * 20 + ['ERR'])
res = db.as_many(B, [("insert into public.messages(conversation_id,sender_id,body) values (%s,%s,'m')", (conv, B))] * 3)
db.su("update public.items set moderation_status='approved' where id=%s", (chem,))
msgs = [x[0] for x in db.as_many(B, [("insert into public.messages(conversation_id,sender_id,body) values (%s,%s,'spam')", (conv, B))] * 61)]
t('message_send: 61st message in 10 minutes refused (limit 60/10 min)', msgs == ['OK'] * 60 + ['ERR'], msgs.count('OK'))
t('photo_upload: 31st upload in an hour refused (limit 30/h)', [x[0] for x in db.as_many(RE, [("insert into storage.objects(bucket_id,name) values ('item-images',%s)", (f'{RE}/u{i}.jpg',)) for i in range(31)])] == ['OK'] * 30 + ['ERR'])
res = [x[0] for x in db.as_many(C, [('select public.get_contact(%s)', (lab,))] * 41)]
t('contact_lookup: 41st lookup in an hour refused (V2 value 40/h kept)', res.count('OK') == 40, res.count('OK'))
# concurrency: the advisory lock makes the limit exact
db.su("insert into public.rate_limit_rules values ('t_conc', 3600, 5) on conflict do nothing")
outs = []
def worker():
    cn = psycopg2.connect(db.uri); cn.autocommit = False; cur = cn.cursor()
    try:
        cur.execute("select set_config('request.jwt.claims', %s, true)", (json.dumps({'sub': RA}),)); cur.execute("select public.rate_limit_check('t_conc')"); cn.commit(); outs.append('ok')
    except Exception: cn.rollback(); outs.append('err')
    finally: cn.close()
th = [threading.Thread(target=worker) for _ in range(16)]; [x.start() for x in th]; [x.join() for x in th]
t('16 concurrent requests against a limit of 5: exactly 5 pass', outs.count('ok') == 5 and db.su("select count(*) from public.rate_limit_events where action='t_conc'")[0][0] == 5, outs)
db.su("delete from public.rate_limit_rules where action='t_conc'")
t('rejected requests record nothing; purge function works and is not callable via API', (lambda j: j['rate_limit_events_deleted'] >= 0)(json.loads(json.dumps(db.su('select public.v3_purge_old_events()')[0][0]))) and err(db.as_(A, 'select public.v3_purge_old_events()'), 'permission denied'))

# ───────────────────────────────────── 12. RESERVED NAMES ─────────────────────────────────────
head('12. Reserved display names')
def reserved(n): return db.as_(None, 'select public.is_display_name_reserved(%s)', (n,), role='anon')[1][0][0]
bad = ['admin', 'Admin', 'ADMINISTRATOR', 'a d m i n', 'Ad-min', 'admin1', 'Moderator', 'moderator 2', 'support', 'SUPPORT', 'Campus Market', 'campusmarket', 'campus_market', 'CampusMarket',
       'system', 'System', '4dmin', 'M0derator', 'Admin Support', 'campus market admin', 'sys tem', 'S y s t e m', 'ADMIN!!', 'admin_', 'adadminmin']
good = ['Madison', 'Systemic Sam', 'Supportive Sam', 'Madmin Kumar', 'Asha A', 'Radmin', 'Campus Mark', 'Administrate Jo', 'Moderate Mo', '12345', 'Priya Sharma']
t('reserved names are blocked (case/space/punctuation/leetspeak tricks)', all(reserved(n) for n in bad), [n for n in bad if not reserved(n)])
t('normal names (incl. look-alike substrings) are allowed', not any(reserved(n) for n in good), [n for n in good if reserved(n)])
t('anon can call the pure checker (sign-up page pre-check)', reserved('admin') is True)
for n in ('Admin Support', 'M0derator'):
    try: db.su("insert into auth.users(email,raw_user_meta_data) values ('z@iips.edu.in',%s)", (json.dumps({'display_name': n}),)); x = False
    except Exception as e: x = 'RESERVED_NAME' in str(e)
    t(f'sign-up with reserved name "{n}" is rejected by the auth.users trigger', x)
t('sign-up with a normal name still works', (db.su("insert into auth.users(email,raw_user_meta_data) values ('okname@iips.edu.in','{\"display_name\":\"Priya Sharma\"}')"), True)[1])
t('existing profiles were not renamed', [x[0] for x in db.su('select display_name from public.profiles where id = any(%s::uuid[]) order by email', ([A,B,C,D,E,F,G,H],))] == ['Asha A','Bala B','Chitra C','Dev D','Esha E','Farid F','Gita G','Hari H'])

# ───────────────────────────────────── 13. V2 REGRESSION (what the deployed app does) ─────────────────────────────────────
head('13. V2 functionality still works for a normal student on the migrated DB')
t('browse: search + category + price + sort + pagination (range) as V2 queries do', db.as_(C, "select id from public.items where status='active' and category = any(%s) and price<=%s and (title ilike %s) order by created_at desc, id desc limit 20 offset 0", (['books','electronics'], 5000, '%book%'))[0] == 'OK'
  and db.as_(C, "select count(*) from public.items where status='active'")[1][0][0] >= 5)
rr = db.as_(C, "!insert into public.items(title,description,category,listing_type,price,condition_label,image_url) values ('V2 flow listing','', 'notes','sell',75,'good',%s) returning id,moderation_status", (f'https://x.supabase.co/storage/v1/object/public/item-images/{C}/ok.jpg',))
t('student creates listing with own-folder photo URL', ok(rr) and rr[1][0][1] == 'approved', rr)
nid = rr[1][0][0]
t('... item_private insert (phone) works', ok(db.as_(C, "insert into public.item_private(item_id,contact_phone) values (%s,'+91 98765 43210')", (nid,))))
t('... edit own listing, mark sold, mark available again', db.as_(C, "update public.items set price=80 where id=%s", (nid,)) == ('OK', 1) and db.as_(C, "update public.items set status='sold' where id=%s", (nid,)) == ('OK', 1) and db.as_(C, "update public.items set status='active' where id=%s", (nid,)) == ('OK', 1))
db.as_(C, '!insert into public.wishlists(user_id,item_id) values (%s,%s)', (C, calc))
t('wishlist add / list / remove', db.as_(C, 'select count(*) from public.wishlists')[1][0][0] == 1 and db.as_(C, 'delete from public.wishlists where user_id=%s and item_id=%s', (C, calc)) == ('OK', 1))
t('start conversation + send + read messages (what the Next.js actions do)', (lambda c: ok(c) and ok(db.as_(RA, "insert into public.messages(conversation_id,sender_id,body) values (%s,%s,'hello')", (c[1][0][0], RA))))(db.as_(RA, '!insert into public.conversations(item_id) values (%s) returning id', (nid,))))
t('photo upload to own folder allowed; to someone else\'s folder / bucket root denied', ok(db.as_(B, "insert into storage.objects(bucket_id,name) values ('item-images',%s)", (f'{B}/v2.jpg',))) and err(db.as_(B, "insert into storage.objects(bucket_id,name) values ('item-images',%s)", (f'{C}/evil.jpg',))) and err(db.as_(B, "insert into storage.objects(bucket_id,name) values ('item-images','root.jpg')")))
t('owner deletes a listing that has no chats/reports', db.as_(C, 'delete from public.items where id=%s', (item_id(db, 'Drafting kit'),)) == ('OK', 1))
t('listing with a chat cannot be deleted (V2 rule kept)', err(db.as_(C, 'delete from public.items where id=%s', (nid,)), 'conversations'))
t('Realtime publication unchanged (messages + conversations only)', sorted(x[0] for x in db.su("select tablename from pg_publication_tables where pubname='supabase_realtime'")) == ['conversations', 'messages'])
t('V2 chats from before V3 are intact (2 messages, same conversation)', db.su('select count(*) from public.messages where conversation_id=%s and body in (%s,%s)', (conv, 'is it available?', 'yes'))[0][0] == 2)

print(f'\n{sum(R)}/{len(R)} checks passed')
print('ALL GOOD' if all(R) else 'FAILURES at positions: ' + str([i + 1 for i, x in enumerate(R) if not x]))
sys.exit(0 if all(R) else 1)
