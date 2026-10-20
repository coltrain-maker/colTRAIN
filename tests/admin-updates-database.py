"""Real isolated PostgreSQL tests. No hosted messages or email provider calls."""
from pathlib import Path
import concurrent.futures,json,subprocess,time,uuid
root=Path(__file__).resolve().parent.parent
name='coltrain-admin-updates-'+uuid.uuid4().hex[:8]
image='postgres:17-alpine@sha256:b0f9560a2de083e2cc7382e75f808c7381a32852a7ec49117deedb300e552b24'
checks=0
store='10000000-0000-0000-0000-000000000160';other='10000000-0000-0000-0000-000000000164'
def uid(n):return '00000000-0000-0000-0000-'+str(n).zfill(12)
def mid(n):return '20000000-0000-0000-0000-'+str(n).zfill(12)
def sql(text,check=True):
 r=subprocess.run(['docker','exec','-i',name,'psql','-X','-qAt','-v','ON_ERROR_STOP=1','-U','postgres'],input=text,text=True,capture_output=True)
 if check and r.returncode:raise AssertionError(r.stderr)
 return r

def actor(n,q,check=True):return sql(f"begin;set local role authenticated;set local request.jwt.claim.sub='{uid(n)}';{q};commit;",check)
def data(n,q):return json.loads(actor(n,q).stdout)
def ok(v,msg):
 global checks
 assert v,msg
 checks+=1

def reject(n,q,needle):
 r=actor(n,q,False);ok(r.returncode!=0 and needle in r.stderr,(r.stderr,needle))
def inbox(n,s=store):return data(n,f"select public.get_my_training_notifications('{s}')")
def send(audience='both',s=store,key=None):
 key=key or str(uuid.uuid4())
 return data(160,f"select public.send_admin_update('Update title','Approved message','{audience}','{key}',array['{s}'::uuid],link_url=>'https://example.test/news')")
def claim(message,retry=False):return json.loads(sql(f"set role service_role;select public.claim_admin_update_email('{message}',{str(retry).lower()});").stdout.strip() or 'null')
subprocess.run(['docker','run','--rm','-d','--name',name,'--network','none','-e','POSTGRES_HOST_AUTH_METHOD=trust',image],check=True,capture_output=True)
try:
 for _ in range(80):
  if subprocess.run(['docker','exec',name,'pg_isready','-h','127.0.0.1','-U','postgres'],capture_output=True).returncode==0:break
  time.sleep(.25)
 sql((root/'tests/supabase-auth-fixture.sql').read_text())
 for p in sorted((root/'supabase/migrations').glob('*.sql')):sql(p.read_text())
 sql(f"""insert into auth.users(id,email,email_confirmed_at) select ('00000000-0000-0000-0000-'||lpad(n::text,12,'0'))::uuid,'updates'||n||'@example.test',now() from generate_series(160,167) n;
 insert into public.profiles(user_id,full_name,optional_email_notifications) select id,'Updates user',email<>'updates163@example.test' from auth.users where email like 'updates%@example.test';
 insert into public.platform_admins(user_id) values('{uid(160)}');
 insert into public.organizations(id,name) values('{store}','Updates A'),('{other}','Updates B');
 insert into public.organization_memberships(id,organization_id,user_id,email,role,status)
 select ('20000000-0000-0000-0000-'||lpad(n::text,12,'0'))::uuid,case when n=164 then '{other}' else '{store}' end::uuid,
 ('00000000-0000-0000-0000-'||lpad(n::text,12,'0'))::uuid,'updates'||n||'@example.test',case when n in (161,164) then 'manager' else 'employee' end,case when n=165 then 'inactive' else 'active' end from generate_series(161,165) n;""")
 preview=data(160,f"select public.preview_admin_update('Title','Message','both',array['{store}'::uuid])")
 ok(preview['recipient_count']==3 and preview['email_count']==2,'preview matches selected store active roles/opt-in')
 ok(sql('select count(*) from private.admin_updates').stdout.strip()=='0','preview sends nothing')
 reject(161,'select public.get_admin_updates()','Administrator access required')
 reject(162,f"select public.preview_admin_update('x','y','both',array['{store}'::uuid])",'Administrator access required')
 reject(161,f"select public.send_admin_update('x','y','both',gen_random_uuid(),array['{store}'::uuid])",'Administrator access required')
 reject(160,"select public.preview_admin_update('x','y','both')",'Choose at least one store')
 reject(160,f"select public.preview_admin_update('x','y','both',array['{store}'::uuid],true)",'all stores or specific stores')
 reject(160,f"select public.preview_admin_update('x','y','unknown',array['{store}'::uuid])",'Choose managers')
 reject(160,f"select public.preview_admin_update('x','y','both',array['{store}'::uuid],link_url=>'javascript:alert(1)')",'https://')
 reject(160,"select public.preview_admin_update('x','y','both',array['00000000-0000-0000-0000-000000000999'::uuid])",'does not exist')
 managers=send('manager');employees=send('employee');both=send()
 ok(managers['recipient_count']==1 and employees['recipient_count']==2 and both['recipient_count']==3,'audiences count actual roles')
 ok(len(inbox(161)['items'])==2,'manager receives managers and both')
 ok(len(inbox(162)['items'])==2 and len(inbox(163)['items'])==2,'employees receive employees and both even when email off')
 ok(inbox(164,other)['items']==[],'selected stores isolate updates')
 ok(inbox(160)['items']==[],'platform admin cannot bypass membership into recipient inbox')
 ok(all(n['link_url']=='https://example.test/news' for n in inbox(162)['items']),'recipient links present after authorization')
 first=inbox(162)['items'][0]['id'];actor(162,f"select public.mark_training_notifications_read('{store}',array['{first}'::uuid])")
 ok(inbox(162)['unread_count']==1 and inbox(163)['unread_count']==2,'read receipts private and independent')
 actor(163,f"select public.mark_training_notifications_read('{store}',array['{first}'::uuid])")
 ok(inbox(163)['unread_count']==2,'teammate cannot mark another receipt')
 actor(162,f"select public.mark_training_notifications_read('{store}',mark_all=>true)")
 ok(inbox(162)['unread_count']==0,'mark-all includes admin announcements')
 reject(162,f"select public.get_my_training_notifications('{other}')",'Active store membership required')
 for table in ['admin_updates','admin_update_recipients','admin_update_email_queue']:
  reject(161,f'select * from private.{table}','permission denied')
 reject(160,f"select public.claim_admin_update_email('{both['id']}')",'permission denied')
 ok(sql(f"select count(*) from private.admin_update_email_queue where update_id='{both['id']}'").stdout.strip()=='2','opt-out excluded from email queue')
 # Same key across concurrent network retries produces exactly one message and one audience snapshot.
 token=str(uuid.uuid4())
 with concurrent.futures.ThreadPoolExecutor(max_workers=2) as pool:results=list(pool.map(lambda _:send(key=token),range(2)))
 ok(results[0]['id']==results[1]['id'],'concurrent send deduplicates')
 ok(sql(f"select count(*) from private.admin_update_recipients where update_id='{results[0]['id']}'").stdout.strip()=='3','no duplicate recipient rows')
 # Live preference changes are rechecked immediately before email claims.
 sql(f"update public.profiles set optional_email_notifications=false where user_id='{uid(162)}'")
 job=claim(employees['id']);ok(job is None,'opt-out before delivery cancels queued email')
 sql(f"update public.organization_memberships set role='employee' where id='{mid(161)}'")
 ok(not any(i['admin_update_id']==managers['id'] for i in inbox(161)['items']),'manager-only update hidden after role change')
 ok(claim(managers['id']) is None,'role change cancels manager-only queued email')
 # Restore a current opted-in manager for delivery lease checks.
 sql(f"update public.organization_memberships set role='manager' where id='{mid(161)}'")
 job=claim(both['id']);ok(job and job['email']=='updates161@example.test','service claims only remaining eligible email')
 ok(claim(both['id']) is None,'active lease prevents concurrent claim')
 sql(f"set role service_role;select public.finish_admin_update_email('{job['id']}','{job['lease_id']}',true,'provider-test');")
 ok(claim(both['id'],True) is None,'accepted email never reclaims')
 actor(160,f"select public.archive_admin_update('{both['id']}')")
 ok(not any(i['admin_update_id']==both['id'] for i in inbox(162)['items']),'archive hides in-app update')
 # New members do not receive old audience snapshots.
 sql(f"insert into public.organization_memberships(id,organization_id,user_id,email,role) values('{mid(166)}','{store}','{uid(166)}','updates166@example.test','employee')")
 ok(inbox(166)['items']==[],'new hires do not inherit earlier messages')
 sql(f"update public.organization_memberships set status='inactive',deactivated_at=now() where id='{mid(162)}'")
 reject(162,f"select public.get_my_training_notifications('{store}')",'Active store membership required')
 allmsg=data(160,"select public.send_admin_update('All stores','Hello','both',gen_random_uuid(),all_stores=>true)")
 ok(allmsg['recipient_count']==4,'all current stores counts active members only')
 ok(len(inbox(164,other)['items'])==1,'all-store update reaches other store')
 older=send('manager');job=claim(older['id'])
 sql(f"update private.admin_update_email_queue set leased_at=now()-interval '10 minutes',first_attempt_at=now()-interval '25 hours' where id='{job['id']}'")
 ok(claim(older['id'],True) is None,'ambiguous old provider request not replayed beyond idempotency window')
 ok(sql(f"select status from private.admin_update_email_queue where id='{job['id']}'").stdout.strip()=='review','old request marked for review')
 history=data(160,'select public.get_admin_updates()')
 ok(any(m['id']==both['id'] and m['email_counts'].get('sent')==1 for m in history),'admin history records provider acceptance')
 ok('updates161@example.test' not in json.dumps(history),'admin summaries do not expose email queue addresses')
 ok(sql("select has_function_privilege('anon','public.send_admin_update(text,text,text,uuid,uuid[],boolean,text)','execute')").stdout.strip()=='f','anonymous send denied')
 print(f'Passed {checks} admin update database checks: audience/store isolation, preview-only state, read receipts, consent, private queues, role/deactivation safety, leases, archive, concurrent idempotency and historical delivery review.')
finally:subprocess.run(['docker','rm','-f',name],capture_output=True)
