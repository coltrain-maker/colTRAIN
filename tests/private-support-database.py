"""Historical selected-pair behavior through migration 021; see group-support-database.py for 022+ migration/current policy checks. No hosted traffic."""
from pathlib import Path
import json,subprocess,time,uuid,concurrent.futures
root=Path(__file__).resolve().parent.parent
name='coltrain-support-'+uuid.uuid4().hex[:8]
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
def data(n,q):return json.loads(actor(n,q).stdout.strip() or 'null')
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
subprocess.run(['docker','run','--rm','-d','--name',name,'--network','none','-e','POSTGRES_HOST_AUTH_METHOD=trust',image],check=True,capture_output=True)
try:
 for _ in range(80):
  if subprocess.run(['docker','exec',name,'pg_isready','-h','127.0.0.1','-U','postgres'],capture_output=True).returncode==0:break
  time.sleep(.25)
 sql((root/'tests/supabase-auth-fixture.sql').read_text())
 for p in sorted((root/'supabase/migrations').glob('*.sql')):
  if p.name<'202610220022':sql(p.read_text())
 sql(f"""insert into auth.users(id,email,email_confirmed_at) select ('00000000-0000-0000-0000-'||lpad(n::text,12,'0'))::uuid,'support'||n||'@example.test',now() from generate_series(200,207) n;
 insert into public.profiles(user_id,full_name,optional_email_notifications) select id,'Support '||email,false from auth.users;
 insert into public.platform_admins values('{uid(200)}');
 insert into public.organizations(id,name) values('{store}','Support A'),('{other}','Support B');
 insert into public.organization_memberships(id,organization_id,user_id,email,role)
 select ('20000000-0000-0000-0000-'||lpad(n::text,12,'0'))::uuid,case when n in (205,206) then '{other}' else '{store}' end::uuid,('00000000-0000-0000-0000-'||lpad(n::text,12,'0'))::uuid,'support'||n||'@example.test',case when n in (201,203,205) then 'manager' else 'employee' end from generate_series(201,207) n;""")
 ok(len(board(202)['recipients'])==2,'employee selects among active store managers')
 ok(all(r['role']=='employee' for r in board(201)['recipients']),'manager selects an active employee')
 reject(200,f"select public.get_team_support_workspace('{store}')",'Active store membership')
 first=send(202);t=first['thread_id']
 ok(len(board(201)['threads'])==1 and len(board(202)['threads'])==1,'only the selected pair receives thread')
 ok(board(203)['threads']==[] and board(204)['threads']==[],'other manager and coworker cannot list conversation')
 for n in [200,203,204,205]:reject(n,f"select public.get_team_support_thread('{t}')",'Private conversation not available')
 reject(204,f"select public.send_team_support_message('{store}',gen_random_uuid(),'forged',recipient=>'{mid(202)}',subject=>'x')",'Choose an active recipient')
 reject(202,f"select public.send_team_support_message('{store}',gen_random_uuid(),'forged',recipient=>'{mid(205)}',subject=>'x')",'Choose an active recipient')
 reject(202,'select * from private.support_messages','permission denied')
 ok(inbox(201)['unread_count']==1 and inbox(202)['unread_count']==0,'new message notifies recipient, not sender')
 d=detail(201,t);actor(201,f"select public.mark_team_support_read('{t}',{d['read_through']})")
 ok(board(201)['threads'][0]['unread_count']==0 and inbox(201)['unread_count']==0,'reading thread synchronizes inbox receipts')
 reply=send(201,t,body='Let us review the receipt together')
 ok(inbox(202)['unread_count']==1 and inbox(202)['items'][0]['support_thread_id']==t,'reply notification opens correct private thread')
 note=inbox(202)['items'][0]['id'];actor(202,f"select public.mark_training_notifications_read('{store}',array['{note}'::uuid])")
 ok(board(202)['threads'][0]['unread_count']==0,'marking notification read synchronizes thread unread count')
 reject(203,f"select public.set_team_support_state('{t}','archive')",'Only the selected manager')
 reject(202,f"select public.set_team_support_state('{t}','delete')",'Only the selected manager')
 actor(201,f"select public.set_team_support_state('{t}','archive')")
 ok(board(201)['threads']==[] and len(board(201,'archive','customer return')['threads'])==1,'archive keyword search includes original message text')
 ok(len(board(202,'archive','receipt')['threads'])==1,'employee searches own archived replies')
 ok(board(203,'archive','receipt')['threads']==[],'archive search never leaks to another manager')
 ok(board(201,'archive',"' OR 1=1 --")['threads']==[],'search text cannot inject SQL')
 send(202,t,body='Follow up about the return')
 ok(len(board(201)['threads'])==1 and board(201,'archive')['threads']==[],'new reply reopens archived thread')
 urgent=send(202,t,body='Urgent assistance needed',emergency=True)
 ok(inbox(201)['items'][0]['kind']=='support_message','emergency still triggers private in-app notification')
 reject(202,f"select public.claim_support_email('{uid(202)}')",'permission denied')
 ok(claim(203) is None,'unselected manager cannot claim emergency email')
 job=claim(202);ok(job['email']=='support201@example.test','emergency emails only selected manager despite email opt-out')
 ok('Urgent assistance' not in job['body'],'email excludes private message body')
 ok(claim(201) is None,'email lease prevents concurrent duplicate request')
 sql(f"set role service_role;select public.finish_support_email('{job['id']}','{job['lease_id']}',true,'provider-fixture')")
 ok(detail(202,t)['email_counts']['sent']==1,'provider acceptance is visible without exposing manager email')
 key=str(uuid.uuid4())
 with concurrent.futures.ThreadPoolExecutor(2) as pool:results=list(pool.map(lambda _:send(202,t,body='Concurrent message',key=key),range(2)))
 ok(results[0]==results[1],'concurrent submission retries return same message')
 ok(sql(f"select count(*) from private.support_messages where submission_key='{key}'").stdout.strip()=='1','idempotent reply stored once')
 actor(201,f"select public.set_team_support_state('{t}','delete')")
 ok(board(201)['threads']==[] and len(board(201,'trash')['threads'])==1,'deleted thread moves to manager Trash')
 reject(202,f"select public.get_team_support_thread('{t}')",'Private conversation not available')
 ok(not any(x['kind']=='support_message' for x in inbox(202)['items']),'deleted messages no longer appear in notifications')
 actor(201,f"select public.set_team_support_state('{t}','restore')")
 ok(len(detail(202,t)['messages'])>=5,'restore preserves message history')
 send(202,t,body='Another emergency',emergency=True)
 actor(201,f"select public.set_team_support_state('{t}','delete')")
 ok(claim(202)=={'skip':True},'deletion cancels emergency email not yet accepted')
 sql(f"update private.support_threads set deleted_at=now()-interval '31 days' where id='{t}'")
 reject(201,f"select public.get_team_support_thread('{t}')",'Private conversation not available')
 reject(201,f"select public.set_team_support_state('{t}','restore')",'Recovery period has expired')
 sql('select private.purge_expired_support_trash()')
 ok(sql(f"select count(*) from private.support_messages where thread_id='{t}'").stdout.strip()=='0','expired Trash physically purges messages and dependent receipts/queue')
 new=send(201,recipient=202,body='Manager-initiated work note')
 ok(inbox(202)['unread_count']==1,'manager can initiate private conversation with employee')
 # A newly promoted manager does not gain access to other managers conversations.
 data(200,f"select public.promote_store_manager('{mid(204)}')")
 reject(204,f"select public.get_team_support_thread('{new['thread_id']}')",'Private conversation not available')
 sql(f"insert into public.platform_admins values('{uid(203)}')")
 reject(203,f"select public.get_team_support_thread('{new['thread_id']}')",'Private conversation not available')
 # Paginated reads must not mark hidden older messages or a concurrently arriving reply as read.
 t2=new['thread_id']
 actor(201,f"do $loop$begin for i in 1..55 loop perform public.send_team_support_message('{store}',gen_random_uuid(),'History entry '||i,thread=>'{t2}');end loop;end$loop$")
 d=detail(202,t2);ok(len(d['messages'])==50 and d['has_older'],'long conversations are paginated')
 remaining=data(202,f"select public.mark_team_support_read('{t2}',{d['read_through']},{d['messages'][0]['seq']})")
 ok(remaining==6,'opening newest page leaves six unseen older messages unread')
 send(201,t2,body='Reply arriving while reader is open')
 remaining=data(202,f"select public.mark_team_support_read('{t2}',{d['read_through']})")
 ok(remaining==1,'read cutoff never marks a concurrent new message as read')
 inbox(202);actor(202,f"select public.mark_training_notifications_read('{store}',mark_all=>true)")
 ok(next(t for t in board(202)['threads'] if t['id']==t2)['unread_count']==0,'mark-all inbox synchronizes paginated message receipts')
 emergency=send(202,t2,body='Worker-only retry',emergency=True)
 job=json.loads(sql('set role service_role;select public.claim_support_email(null)').stdout)
 ok(job['email']=='support201@example.test','scheduled worker delivers only the selected manager even with no signed-in user')
 sql(f"set role service_role;select public.finish_support_email('{job['id']}','{job['lease_id']}',false)")
 sql(f"update private.support_email_queue set first_attempt_at=now()-interval '24 hours' where id='{job['id']}'")
 ok(json.loads(sql('set role service_role;select public.claim_support_email(null)').stdout)=={'skip':True},'ambiguous deliveries past provider idempotency window are held for review')
 sql(f"update public.organization_memberships set status='inactive' where id='{mid(201)}'")
 reject(201,f"select public.get_team_support_thread('{new['thread_id']}')",'Private conversation not available')
 ok(not detail(202,new['thread_id'])['thread']['can_reply'],'inactive selected manager closes replies without exposing conversation to replacements')
 # Verify schedule SQL in isolation: the guards fail cleanly without extensions, then execute
 # only the prepared job commands against stub scheduler/network interfaces (never real HTTP).
 schedule=(root/'supabase/PRIVATE_SUPPORT_SCHEDULE.sql').read_text()
 failed=sql(schedule,False);ok(failed.returncode!=0 and 'Enable Supabase Cron' in failed.stderr,'schedule refuses missing required extensions clearly')
 sql("""create schema cron;create schema net;create schema vault;
 create table vault.decrypted_secrets(name text,decrypted_secret text);
 insert into vault.decrypted_secrets values('coltrain_support_worker_key','fixture-32-character-private-worker-key-only');
 create table test.support_jobs(name text primary key,schedule text,command text);
 create table test.support_http(url text,headers jsonb,body jsonb,timeout integer);
 create function net.http_post(url text,headers jsonb,body jsonb,timeout_milliseconds integer) returns bigint language plpgsql as $fn$begin insert into test.support_http values(url,headers,body,timeout_milliseconds);return 1;end;$fn$;
 create function cron.schedule(job_name text,schedule text,command text) returns bigint language plpgsql as $fn$begin insert into test.support_jobs values(job_name,schedule,command) on conflict(name) do update set schedule=excluded.schedule,command=excluded.command;execute command;return 1;end;$fn$;""")
 commands=schedule[schedule.index("select cron.schedule("):];sql(commands);sql(commands)
 ok(sql('select count(*) from test.support_jobs').stdout.strip()=='2','prepared schedules update two named jobs without duplicates')
 ok(sql("select bool_and(url='https://flhdeftduysnjvqnhhee.supabase.co/functions/v1/team-support-email' and headers->>'x-coltrain-support-worker'='fixture-32-character-private-worker-key-only') from test.support_http").stdout.strip()=='t','scheduled request targets correct worker and reads credential from Vault')
 ok(sql("select count(*) from test.support_jobs where command like '%fixture-32-character%' ").stdout.strip()=='0','scheduler stores secret references rather than embedded credential values')
 print(f'Passed {checks} private-support SQL checks: selected-pair privacy, manager initiation, notifications/read sync, emergency opt-out override, search, idempotency, Trash/expiry, and role changes.')
finally:subprocess.run(['docker','rm','-f',name],capture_output=True)
