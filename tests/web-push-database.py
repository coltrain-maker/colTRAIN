"""Isolated PostgreSQL checks; no hosted account access or email provider traffic."""
from pathlib import Path
import json,subprocess,time,uuid,concurrent.futures
root=Path(__file__).resolve().parent.parent
name='coltrain-push-'+uuid.uuid4().hex[:8]
image='postgres:17-alpine@sha256:b0f9560a2de083e2cc7382e75f808c7381a32852a7ec49117deedb300e552b24'
checks=0
store='10000000-0000-0000-0000-000000000200';other='10000000-0000-0000-0000-000000000205'
def uid(n):return f'00000000-0000-0000-0000-{n:012}'
def mid(n):return f'20000000-0000-0000-0000-{n:012}'
def sql(q,check=True):
 r=subprocess.run(['docker','exec','-i',name,'psql','-X','-qAt','-v','ON_ERROR_STOP=1','-U','postgres'],input=q,text=True,capture_output=True)
 if check and r.returncode:raise AssertionError(r.stderr)
 return r

def actor(n,q,check=True):return sql(f"begin;set local role authenticated;set local request.jwt.claim.sub='{uid(n)}';{q};commit;",check)
def data(n,q):
 value=actor(n,q).stdout.strip() or 'null'
 return {'t':True,'f':False}.get(value) if value in ('t','f') else json.loads(value)
def ok(v,msg):
 global checks
 assert v,msg
 checks+=1

def reject(n,q,needle):
 r=actor(n,q,False);ok(r.returncode!=0 and needle in r.stderr,(needle,r.stderr))
def quote(v):return "'"+str(v).replace("'","''")+"'"
def send(n,thread=None,recipient=201,body='Please review the customer return procedure',category='work',emergency=False,key=None):
 q=f"select public.send_team_support_message('{store}','{key or uuid.uuid4()}',{quote(body)},thread=>{quote(thread)+'::uuid' if thread else 'null'},recipient=>'{mid(recipient)}',category=>'{category}',subject=>'Private return question',emergency=>{str(emergency).lower()})"
 return data(n,q)
def board(n,folder='inbox',words='',s=store):return data(n,f"select public.get_team_support_workspace('{s}','{folder}',{quote(words)})")
def inbox(n,s=store):return data(n,f"select public.get_my_training_notifications('{s}')")
def detail(n,thread):return data(n,f"select public.get_team_support_thread('{thread}')")
def claim(n):return json.loads(sql(f"set role service_role;select public.claim_support_email('{uid(n)}')").stdout.strip() or 'null')
try:
 subprocess.run(['docker','run','--rm','-d','--network','none','--name',name,'-e','POSTGRES_PASSWORD=isolated-test',image],check=True)
 for _ in range(100):
  if subprocess.run(['docker','exec',name,'pg_isready','-h','127.0.0.1','-U','postgres'],capture_output=True).returncode==0:break
  time.sleep(.2)
 sql((root/'tests/supabase-auth-fixture.sql').read_text())
 for p in sorted((root/'supabase/migrations').glob('*.sql')):sql(p.read_text())
 sql(f"""insert into auth.users(id,email,email_confirmed_at) select ('00000000-0000-0000-0000-'||lpad(n::text,12,'0'))::uuid,'push'||n||'@example.test',now() from generate_series(200,207)n;
 insert into public.profiles(user_id,full_name,optional_email_notifications) select id,'Push user',false from auth.users;
 insert into public.platform_admins values('{uid(200)}');
 insert into public.organizations(id,name) values('{store}','Push A'),('{other}','Push B');
 insert into public.organization_memberships(id,organization_id,user_id,email,role)
 select ('20000000-0000-0000-0000-'||lpad(n::text,12,'0'))::uuid,case when n in (205,206) then '{other}' else '{store}' end::uuid,('00000000-0000-0000-0000-'||lpad(n::text,12,'0'))::uuid,'push'||n||'@example.test',case when n in (201,203,205) then 'manager' else 'employee' end from generate_series(201,207)n;""")
 endpoint='https://web.push.apple.com/test-secret-endpoint'
 def save(n=201,e=endpoint):return actor(n,f"select public.save_web_push('{e}','{'A'*87}','{'B'*22}')")
 def claim():return json.loads(sql("begin;set local role service_role;select public.claim_web_push();commit;").stdout.strip() or 'null')
 def finish(j,outcome='sent'):sql(f"begin;set local role service_role;select public.finish_web_push('{j['id']}','{j['lease']}',{quote(json.dumps(j['ids']))}::jsonb,'{outcome}');commit;")
 def due():sql('update private.web_push_subscriptions set next_scan_at=now()-interval \'1 minute\';')
 reject(200,f"select public.save_web_push('{endpoint}','{'A'*87}','{'B'*22}')",'Active store membership')
 for ep in ['http://web.push.apple.com/a','https://127.0.0.1/a','https://web.push.apple.com.evil.test/a','https://web.push.apple.com:443/a','https://user@web.push.apple.com/a']:
  reject(201,f"select public.save_web_push('{ep}','{'A'*87}','{'B'*22}')",'Invalid push subscription')
 save();ok(data(201,f"select public.get_web_push_status('{endpoint}')"),'owner sees subscription')
 ok(data(202,f"select public.get_web_push_status('{endpoint}')") is False,'other user cannot see subscription')
 reject(202,f"select public.save_web_push('{endpoint}','{'A'*87}','{'B'*22}')",'Turn off notifications')
 reject(201,'select * from private.web_push_subscriptions','permission denied')
 reject(201,'select public.claim_web_push()','permission denied')
 ok(claim()=={'skip':True},'empty snapshot does not push')
 first=send(202,body='Private customer details not in payload');due();job=claim()
 ok(job['count']==1 and 'Private customer' not in json.dumps(job),'new recipient notification creates count-only job')
 ok(data(201,'select public.get_my_web_push_count()')==1,'personal aggregate badge count follows active inbox')
 ok(data(203,'select public.get_my_web_push_count()')==0,'other manager badge does not count private conversation')
 ok(job['subscription']['endpoint']==endpoint,'correct device endpoint')
 ok(claim() is None,'lease prevents duplicate claim')
 finish(job);due();ok(claim()=={'skip':True},'successful alert not repeated')
 send(204,recipient=203,body='Another managers thread');due();ok(claim()=={'skip':True},'other manager private conversation excluded')
 send(202,thread=first['thread_id'],body='New reply');due();job=claim();ok(job['count']==2,'reply changes unread count')
 finish(job,'failed');due();retry=claim();ok(retry['ids']==job['ids'],'failed delivery stays retryable');finish(retry)
 actor(201,f"select public.mark_training_notifications_read('{store}',mark_all=>true)")
 due();ok(claim()=={'skip':True},'reading clears snapshot without invisible push')
 send(202,thread=first['thread_id']);due();job=claim();ok(job['count']==1,'read messages excluded from badge total');finish(job,'expired')
 ok(data(201,f"select public.get_web_push_status('{endpoint}')") is False,'expired endpoint removed')
 # Subscribe with an existing unread inbox: no burst of historical notifications.
 save();ok(claim()=={'skip':True},'existing unread notifications baselined at opt-in')
 actor(202,f"select public.remove_web_push('{endpoint}')");ok(data(201,f"select public.get_web_push_status('{endpoint}')"),'cannot remove another users endpoint')
 actor(201,f"select public.remove_web_push('{endpoint}')");ok(not data(201,f"select public.get_web_push_status('{endpoint}')"),'owner turns off subscription')
 save();sql(f"update public.organization_memberships set status='inactive' where user_id='{uid(201)}'");due();ok(claim()=={'skip':True},'inactive member gets no alerts')
 # Snapshot impersonation never leaks into subsequent operations in the transaction.
 sql(f"begin;select set_config('request.jwt.claim.sub','{uid(204)}',true);select private.push_snapshot('{uid(202)}');select test.ok(auth.uid()='{uid(204)}','snapshot restores caller');commit;")
 ok(True,'snapshot restores caller identity')
 print(f'Passed {checks} Web Push database privacy, recipient, opt-in baseline, lease/retry, read state and expiry checks. No hosted services accessed.')
finally:
 subprocess.run(['docker','rm','-f',name],capture_output=True)
