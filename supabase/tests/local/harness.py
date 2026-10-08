"""Local Postgres stand-in for Supabase (dev tooling only - NOT an npm dependency).

    pip install pgserver psycopg2-binary
    python supabase/tests/local/test_v3.py

Starts an embedded PostgreSQL, loads a minimal Supabase imitation (roles anon/authenticated/service_role,
auth.users + auth.uid(), storage.buckets/objects, supabase_realtime publication, Supabase's default
privileges), then the V1 schema + V2 migrations 002/003 + representative V2 data.
It is NOT real Supabase: Storage API, Auth, Realtime delivery and platform-level ownership of the
storage schema cannot be tested here.
"""
import json, os, pathlib
import psycopg2, pgserver

HERE = pathlib.Path(__file__).resolve().parent
MIG = HERE.parent.parent / 'migrations'
PGDATA = os.environ.get('CM_PGDATA', '/tmp/cm_pgdata')
_server = None

def server():
    global _server
    if _server is None:
        _server = pgserver.get_server(PGDATA, cleanup_mode=None)
    return _server

def uri(db):
    return server().get_uri().replace('/postgres?', f'/{db}?')

def create_db(name):
    c = psycopg2.connect(uri('postgres')); c.autocommit = True
    cur = c.cursor(); cur.execute(f'drop database if exists {name} with (force)'); cur.execute(f'create database {name}'); c.close()

class DB:
    def __init__(self, name):
        self.name = name; self.uri = uri(name)
        self.su_conn = psycopg2.connect(self.uri); self.su_conn.autocommit = True

    def su(self, sql, params=None):
        """Run as the database owner (like the Supabase SQL Editor / service role)."""
        cur = self.su_conn.cursor(); cur.execute(sql, params)
        return cur.fetchall() if cur.description else cur.rowcount

    def migrate(self, filename):
        """Run a migration file exactly as the SQL Editor would; returns ('OK','') or ('ERR', message)."""
        try:
            self.su((MIG / filename).read_text()); return ('OK', '')
        except Exception as e:
            try: self.su('rollback')
            except Exception: pass
            return ('ERR', str(e).strip())

    def as_(self, uid, sql, params=None, role='authenticated'):
        """Run as an API role with a JWT for `uid`, in ONE transaction. Rolled back unless sql starts with '!'.
        Returns ('OK', rows|rowcount) or ('ERR', first error line)."""
        keep = sql.startswith('!'); sql = sql.lstrip('!')
        cn = psycopg2.connect(self.uri); cn.autocommit = False; cur = cn.cursor()
        try:
            cur.execute(f'set local role {role}')
            if uid: cur.execute("select set_config('request.jwt.claims', %s, true)", (json.dumps({'sub': uid, 'role': role}),))
            cur.execute(sql, params)
            res = cur.fetchall() if cur.description else cur.rowcount
            (cn.commit() if keep else cn.rollback()); return ('OK', res)
        except Exception as e:
            cn.rollback(); return ('ERR', str(e).strip().splitlines()[0])
        finally:
            cn.close()

    def as_many(self, uid, statements, role='authenticated'):
        """Several statements in ONE transaction (needed for rate-limit tests, which count within a txn). Rolled back."""
        cn = psycopg2.connect(self.uri); cn.autocommit = False; cur = cn.cursor(); out = []
        try:
            cur.execute(f'set local role {role}')
            cur.execute("select set_config('request.jwt.claims', %s, true)", (json.dumps({'sub': uid, 'role': role}),))
            for sql, params in statements:
                try:
                    cur.execute('savepoint s'); cur.execute(sql, params); cur.execute('release savepoint s'); out.append(('OK', None))
                except Exception as e:
                    cur.execute('rollback to savepoint s'); out.append(('ERR', str(e).strip().splitlines()[0]))
            return out
        finally:
            cn.rollback(); cn.close()

def build_v2_database(name, seed=True):
    """Fresh DB shaped like production after V2: stub + V1 schema + V2 migrations 002 and 003 (+ data)."""
    create_db(name)
    db = DB(name)
    db.su((HERE / 'stub.sql').read_text())
    db.su((HERE / 'schema.v1.sql').read_text())
    for f in ('002_security_fixes.sql', '003_functional_schema_changes.sql'):
        r = db.migrate(f); assert r[0] == 'OK', (f, r)
    if seed: seed_v2(db)
    return db

U = {k: f'aaaaaaaa-0000-0000-0000-00000000000{i}' for i, k in enumerate('ABCDEFGH', start=1)}

def seed_v2(db):
    """Representative V2 production data: students, listings (sell/rent, several statuses/categories,
    demo rows with NULL seller), private contacts, a chat with messages, wishlists and photos."""
    people = {'A': 'Asha A', 'B': 'Bala B', 'C': 'Chitra C', 'D': 'Dev D', 'E': 'Esha E', 'F': 'Farid F', 'G': 'Gita G', 'H': 'Hari H'}
    for k, name in people.items():
        db.su('insert into auth.users(id,email,raw_user_meta_data) values (%s,%s,%s)',
              (U[k], f'{name.split()[0].lower()}@iips.edu.in', json.dumps({'display_name': name})))
    img = lambda k, f: f'https://x.supabase.co/storage/v1/object/public/item-images/{U[k]}/{f}'
    rows = [('A','Chemistry book','books','sell',250,'active'), ('A','Lab coat','books','rent',50,'active'),
            ('B','Calculator','electronics','sell',300,'active'), ('B','Notes bundle','notes','sell',90,'sold'),
            ('C','Drafting kit','stationary','sell',400,'active'), ('D','Headphones','electronics','rent',120,'rented')]
    for k, title, cat, typ, price, st in rows:
        db.su("insert into public.items(seller_id,seller_name,title,description,category,listing_type,price,condition_label,image_url,status) "
              "values (%s,%s,%s,'desc',%s,%s,%s,'good',%s,%s)", (U[k], people[k], title, cat, typ, price, img(k, 'p.jpg'), st))
    for iid, in db.su('select id from public.items where seller_id is not null'):
        db.su("insert into public.item_private(item_id,contact_phone) values (%s,'+91 98765 43210')", (iid,))
    i1 = db.su("select id from public.items where title='Chemistry book'")[0][0]
    db.su("insert into public.conversations(item_id,buyer_id,seller_id,buyer_name) values (%s,%s,%s,'Bala B')", (i1, U['B'], U['A']))
    c = db.su('select id from public.conversations')[0][0]
    db.su("insert into public.messages(conversation_id,sender_id,body) values (%s,%s,'is it available?'),(%s,%s,'yes')", (c, U['B'], c, U['A']))
    db.su('insert into public.wishlists(user_id,item_id) values (%s,%s)', (U['B'], i1))
    db.su("insert into storage.objects(bucket_id,name) values ('item-images',%s)", (f"{U['A']}/p.jpg",))

FP_QUERIES = {
    'items(V2 columns)': "select md5(coalesce(string_agg(t::text,'|' order by id),'')) from (select id,seller_id,seller_name,title,description,category,listing_type,price,condition_label,image_url,campus_location,status,created_at from public.items) t",
    'item_private': "select md5(coalesce(string_agg(t::text,'|' order by item_id),'')) from public.item_private t",
    'conversations': "select md5(coalesce(string_agg(t::text,'|' order by id),'')) from public.conversations t",
    'messages': "select md5(coalesce(string_agg(t::text,'|' order by id),'')) from public.messages t",
    'wishlists': "select md5(coalesce(string_agg(t::text,'|' order by user_id,item_id),'')) from public.wishlists t",
    'profiles(id,name,email,role)': "select md5(coalesce(string_agg(t::text,'|' order by id),'')) from (select id,display_name,email,role from public.profiles) t",
    'auth.users': "select md5(coalesce(string_agg(t::text,'|' order by id),'')) from (select id,email,raw_user_meta_data from auth.users) t",
    'storage.objects': "select md5(coalesce(string_agg(t::text,'|' order by name),'')) from (select bucket_id,name from storage.objects) t",
}
def fingerprint(db):
    return {k: db.su(q)[0][0] for k, q in FP_QUERIES.items()}

SNAPSHOT_SQL = """select md5(string_agg(x,'|' order by x)) from (
 select 'pol:'||schemaname||'.'||tablename||'.'||policyname||'.'||cmd||'.'||permissive as x from pg_policies
 union all select 'trg:'||tgrelid::regclass||'.'||tgname from pg_trigger where not tgisinternal
 union all select 'tbl:'||table_schema||'.'||table_name from information_schema.tables where table_schema in ('public','auth','storage')
 union all select 'col:'||table_name||'.'||column_name from information_schema.columns where table_schema='public'
 union all select 'bucket:'||id||coalesce(file_size_limit::text,'-')||coalesce(allowed_mime_types::text,'-') from storage.buckets
 union all select 'fn:'||p.oid::regprocedure||coalesce(p.proacl::text,'')||md5(p.prosrc) from pg_proc p join pg_namespace n on n.oid=p.pronamespace where n.nspname='public'
 union all select 'acl:'||c.relname||'.'||a.grantee||'.'||a.privilege_type from pg_class c, aclexplode(c.relacl) a where c.relnamespace='public'::regnamespace
 union all select 'cacl:'||attrelid::regclass||'.'||attname||attacl::text from pg_attribute where attacl is not null
 union all select 'rls:'||relname||relrowsecurity::text from pg_class where relnamespace='public'::regnamespace and relkind='r'
 union all select 'con:'||conrelid::regclass||'.'||conname||pg_get_constraintdef(oid) from pg_constraint where connamespace='public'::regnamespace
 union all select 'pub:'||tablename from pg_publication_tables) t"""
def snapshot(db): return db.su(SNAPSHOT_SQL)[0][0]
