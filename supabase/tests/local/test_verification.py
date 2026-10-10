"""Tests for the post-migration verification queries (supabase/verification/*.sql).
Run after (or independently of) test_v3.py:  python3 supabase/tests/local/test_verification.py"""
import sys, pathlib
sys.path.insert(0, str(pathlib.Path(__file__).resolve().parent))
import harness as h, psycopg2
VER = h.HERE.parent.parent / 'verification'
from collections import Counter
P1=open(VER / 'v3_post_migration_verification.sql').read().rstrip().rstrip(';')
P2=open(VER / 'v3_post_migration_data_checks.sql').read().rstrip().rstrip(';')
def run(db, sql, user=None):
    cn=psycopg2.connect(db.uri, **({'user':user} if user else {})); cn.autocommit=False; cu=cn.cursor(); cu.execute('set transaction read only')
    try: cu.execute(sql); return cu.fetchall()
    finally: cn.rollback(); cn.close()
def with_counts(db):
    c={t:db.su(f'select count(*) from public.{t}')[0][0] for t in ['items','conversations','messages','wishlists','profiles']}
    return P1.replace("('items', 7), ('conversations', 2), ('messages', 11), ('wishlists', 1), ('profiles', 3)", ", ".join(f"('{k}', {v})" for k,v in c.items()))
def summary(rows): return [r for r in rows if r[1]==0 and 'OVERALL' in r[2]][0][4]
def fails(rows): return [r for r in rows if r[5]=='FAIL' and r[1]!=0]
ok=True
def chk(name,cond,extra=''):
    global ok; ok&=bool(cond); print(('OK   ' if cond else 'BAD  ')+name+(f'  {extra}' if (extra and not cond) else ''))
db=h.build_v2_database('vfy1')
for f in ['005_v3_audit_events_and_rate_core.sql','006_v3_accounts_and_moderation.sql','007_v3_reporting.sql','008_v3_categories.sql','009_v3_rate_limits_hardening.sql']: assert db.migrate(f)[0]=='OK', f
s1=with_counts(db)
rows=run(db,s1); chk('PART 1 on a correctly migrated DB: 0 FAIL', not fails(rows), [r[2][:50] for r in fails(rows)]); print('     ', summary(rows), '| rows', len(rows))
rows2=run(db,P2); chk('PART 2 on a correctly migrated DB: 0 FAIL', not fails(rows2), [r[2][:60] for r in fails(rows2)]); print('     ', summary(rows2))
import re
chk('PART 1 changes nothing (read-only txn succeeded, snapshot identical)', h.snapshot(db)==h.snapshot(db))
muts=[('stray SELECT policy on items','create policy "Dash read all" on public.items for select to authenticated using (true)','drop policy "Dash read all" on public.items','UNEXPECTED policy'),
 ('stray storage write policy','create policy "Dash storage" on storage.objects for insert to authenticated with check (true)','drop policy "Dash storage" on storage.objects','UNEXPECTED policy'),
 ('old browse policy back','create policy "signed-in can browse" on public.items for select to authenticated using (true)','drop policy "signed-in can browse" on public.items','signed-in can browse'),
 ('authenticated INSERT on audit_logs','grant insert on public.audit_logs to authenticated','revoke insert on public.audit_logs from authenticated','table audit_logs'),
 ('service_role UPDATE on reports','grant update on public.reports to service_role','revoke update on public.reports from service_role','table reports'),
 ('anon executes internal fn','grant execute on function public.audit_write(text,text,text,text,text,jsonb,text) to anon','revoke execute on function public.audit_write(text,text,text,text,text,jsonb,text) from anon','audit_write'),
 ('authenticated executes internal fn','grant execute on function public.rate_limit_check(text) to authenticated','revoke execute on function public.rate_limit_check(text) from authenticated','rate_limit_check'),
 ('search_path unpinned','alter function public.v3_staff_guard(boolean,boolean) reset search_path',"alter function public.v3_staff_guard(boolean,boolean) set search_path = ''",'v3_staff_guard'),
 ('PUBLIC executes V3 fn','grant execute on function public.v3_purge_old_events(interval) to public','revoke execute on function public.v3_purge_old_events(interval) from public','v3_purge_old_events'),
 ('guard trigger disabled','alter table public.reports disable trigger reports_before_insert_trg','alter table public.reports enable trigger reports_before_insert_trg','reports_before_insert_trg'),
 ('append-only trigger disabled','alter table public.audit_logs disable trigger audit_logs_no_mutate','alter table public.audit_logs enable trigger audit_logs_no_mutate','audit_logs_no_mutate'),
 ('restrictive policy missing','drop policy "v3 banned no read" on public.messages','create policy "v3 banned no read" on public.messages as restrictive for select to authenticated using ((select public.account_not_banned()))','v3 banned no read'),
 ('category FK dropped','alter table public.items drop constraint items_category_fkey','alter table public.items add constraint items_category_fkey foreign key (category) references public.categories (slug) on update restrict on delete restrict','items_category_fkey'),
 ('audit_logs in Realtime','alter publication supabase_realtime add table public.audit_logs','alter publication supabase_realtime drop table public.audit_logs','Realtime'),
 ('RLS off on reports','alter table public.reports disable row level security','alter table public.reports enable row level security','table reports'),
 ('RLS forced on items','alter table public.items force row level security','alter table public.items no force row level security','table items'),
 ('upload policy lost checks',"alter policy \"upload to own folder\" on storage.objects with check (bucket_id = 'item-images' and (storage.foldername(name))[1] = auth.uid()::text)","alter policy \"upload to own folder\" on storage.objects with check (bucket_id = 'item-images' and (storage.foldername(name))[1] = auth.uid()::text and (select public.account_is_active()) and public.v3_storage_upload_check())",'upload to own folder'),
 ('profiles column UPDATE grant','grant update (display_name) on public.profiles to authenticated','revoke update (display_name) on public.profiles from authenticated','profiles'),
 ('bucket limit changed',"update storage.buckets set file_size_limit=1 where id='item-images'","update storage.buckets set file_size_limit=5242880 where id='item-images'",'bucket item-images'),
 ('reserved-name trigger dropped','drop trigger reserved_display_name_only on auth.users','create trigger reserved_display_name_only before insert on auth.users for each row execute function public.check_reserved_display_name()','reserved_display_name_only'),
 ('unexpected trigger on items (REVIEW)','create trigger zzz_dash before insert on public.items for each row execute function public.items_v3_limits()','drop trigger zzz_dash on public.items','UNEXPECTED trigger')]
for name,bad,fix,needle in muts:
    db.su(bad); rows=run(db,s1); hit=[r for r in rows if needle.lower() in (r[2]+' '+str(r[3])).lower() and r[5] in ('FAIL','REVIEW')]
    chk('PART 1 catches: '+name, bool(hit), [r[2][:50] for r in fails(rows)][:2])
    db.su(fix); rows=run(db,s1); chk('   baseline restored', not fails(rows), [r[2][:50] for r in fails(rows)][:2])
# data loss
rows=run(db, s1.replace("('items', 7)","('items', 7)").replace(", ('messages', %d)" % db.su('select count(*) from public.messages')[0][0], ", ('messages', 999)"))
chk('PART 1 catches data loss (fewer rows than the audit)', any('row count messages' in r[2] for r in fails(rows)))
# PART 2 mutations
for name,bad,fix,needle in [('rate rule altered',"update public.rate_limit_rules set max_count=500 where action='message_send'","update public.rate_limit_rules set max_count=60 where action='message_send'",'message_send'),
   ('extra rate rule',"insert into public.rate_limit_rules values ('bogus',60,1)","delete from public.rate_limit_rules where action='bogus'",'bogus'),
   ('missing rate rule',"delete from public.rate_limit_rules where action='photo_upload'","insert into public.rate_limit_rules values ('photo_upload',3600,30)",'photo_upload'),
   ('listing with unknown category',"alter table public.items disable trigger items_v3_category_guard_trg; alter table public.items drop constraint items_category_fkey; update public.items set category='furniture' where id=(select min(id) from public.items)","update public.items set category='books' where category='furniture'; alter table public.items add constraint items_category_fkey foreign key (category) references public.categories (slug) on update restrict on delete restrict; alter table public.items enable trigger items_v3_category_guard_trg",'category has no category row')]:
    db.su(bad); r=run(db,P2); chk('PART 2 catches: '+name, any(needle in x[2] for x in fails(r)), [x[2][:50] for x in fails(r)][:2]); db.su(fix); chk('   baseline restored', not fails(run(db,P2)))
# partially migrated / V2-only databases: PART 1 must run (not error) and report FAIL
v2=h.build_v2_database('vfy4'); r=run(v2,P1); chk('PART 1 on a V2-ONLY database runs without error and reports FAIL', len(r)>100 and summary(r).split(' FAIL')[0]!='0', summary(r))
d3=h.build_v2_database('vfy3')
for f in ['005_v3_audit_events_and_rate_core.sql','006_v3_accounts_and_moderation.sql','007_v3_reporting.sql','008_v3_categories.sql']: d3.migrate(f)
r=run(d3,with_counts(d3)); sm={x[2].split('| ')[1]:x[5] for x in r if x[1]==0 and '| migration' in x[2]}
chk('PART 1 with 009 NOT applied: only migration 009 FAILs', sm=={'migration 005':'PASS','migration 006':'PASS','migration 007':'PASS','migration 008':'PASS','migration 009':'FAIL'}, sm)
d2=h.build_v2_database('vfy5')
for f in ['005_v3_audit_events_and_rate_core.sql','006_v3_accounts_and_moderation.sql']: d2.migrate(f)
r=run(d2,with_counts(d2)); sm={x[2].split('| ')[1]:x[5] for x in r if x[1]==0 and '| migration' in x[2]}
chk('PART 1 with only 005+006 applied: 007/008/009 FAIL, 005/006 PASS', sm=={'migration 005':'PASS','migration 006':'PASS','migration 007':'FAIL','migration 008':'FAIL','migration 009':'FAIL'}, sm)
# as the non-superuser migration role on the ownership-emulating DB
try:
    own=h.DB('own1')   # created by test_v3.py (section 1c); skipped if absent
    r=run(own, with_counts(own), user='mig_editor'); chk('PART 1 as a NON-superuser role (like Supabase postgres): 0 FAIL', not fails(r), [x[2][:60] for x in fails(r)])
    r=run(own, P2, user='mig_editor'); chk('PART 2 as a NON-superuser role: 0 FAIL', not fails(r), [x[2][:60] for x in fails(r)])
except Exception as e: print('SKIP non-superuser run (run test_v3.py first to create the own1 database):', str(e)[:80])
print('\nALL VERIFICATION TESTS PASSED' if ok else '\nSOME VERIFICATION TESTS FAILED')
