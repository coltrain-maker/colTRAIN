"""Isolated PostgreSQL checks; no hosted account access or email provider traffic."""
from pathlib import Path
import json,subprocess,time,uuid,concurrent.futures
root=Path(__file__).resolve().parent.parent
name='coltrain-groups-'+uuid.uuid4().hex[:8]
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
 for p in sorted((root/'supabase/migrations').glob('*.sql')):
  if '022_' not in p.name:sql(p.read_text())
 sql(f"""insert into auth.users(id,email,email_confirmed_at) select ('00000000-0000-0000-0000-'||lpad(n::text,12,'0'))::uuid,'push'||n||'@example.test',now() from generate_series(200,207)n;
 insert into public.profiles(user_id,full_name,optional_email_notifications) select id,'Push user',false from auth.users;
 insert into public.platform_admins values('{uid(200)}');
 insert into public.organizations(id,name) values('{store}','Push A'),('{other}','Push B');
 insert into public.organization_memberships(id,organization_id,user_id,email,role)
 select ('20000000-0000-0000-0000-'||lpad(n::text,12,'0'))::uuid,case when n in (205,206) then '{other}' else '{store}' end::uuid,('00000000-0000-0000-0000-'||lpad(n::text,12,'0'))::uuid,'push'||n||'@example.test',case when n in (201,203,205) then 'manager' else 'employee' end from generate_series(201,207)n;""")

 legacy=send(202,body='Existing private history')['thread_id']
 actor(201,f"select public.set_team_support_state('{legacy}','archive')")
 sql((root/'supabase/migrations/202610220022_group_private_messages.sql').read_text())
 ok(len(board(202,'archive')['threads'])==1,'legacy archive migrated for both original participants')
 ok(detail(201,legacy)['messages'][0]['body']=='Existing private history','existing messages preserved')
 ok(len(detail(202,legacy)['thread']['participants'])==2,'old selected pair migrated without new readers')
 actor(202,f"select public.set_team_support_state('{legacy}','unarchive')")
 ok(len(board(201,'archive')['threads'])==1 and len(board(202)['threads'])==1,'archive state is now personal')
 def group(n,people,body='Group conversation',category='general',thread=None,key=None,urgent=False):
  ids='array['+','.join(quote(mid(i))+'::uuid' for i in people)+']::uuid[]'
  return data(n,f"select public.send_team_support_message('{store}','{key or uuid.uuid4()}',{quote(body)},thread=>{quote(thread)+'::uuid' if thread else 'null'},category=>'{category}',subject=>'Selected team group',emergency=>{str(urgent).lower()},recipients=>{ids})")
 ok(len(board(202)['recipients'])==4,'all other active employees and managers are selectable')
 peer=group(202,[204]);ok(len(detail(204,peer['thread_id'])['thread']['participants'])==2,'employee to employee direct message')
 managers=group(201,[203]);ok(len(detail(203,managers['thread_id'])['thread']['participants'])==2,'manager to manager direct message')
 g=group(202,[201,203,204]);t=g['thread_id']
 ok(len(detail(204,t)['thread']['participants'])==4,'shared group roster includes author and selected recipients')
 for n in [201,203,204]:ok(any(x.get('support_thread_id')==t for x in inbox(n)['items']),'each selected recipient gets an in-app event')
 ok(not any(x.get('support_thread_id')==t for x in inbox(202)['items']),'sender not notified')
 for n in [200,205,207]:reject(n,f"select public.get_team_support_thread('{t}')",'Private conversation not available')
 reject(207,'select * from private.support_participants','permission denied')
 for members in [[205],[202],[201,206]]:
  try:group(202,members);raise AssertionError('forged recipient accepted')
  except AssertionError as error:ok('Choose active recipients' in str(error),'reject self/cross-store recipient')
 key=str(uuid.uuid4());first=group(202,[204,203],key=key);again=group(202,[203,204],key=key)
 ok(first==again,'group submission replay reuses one thread/message')
 ok(sql(f"select count(*) from private.support_receipts where message_id='{first['message_id']}'").stdout.strip()=='2','one receipt per other recipient')
 group(204,[],thread=t,body='Reply includes warranty keyword')
 for n in [201,202,203]:ok(any(x['body']=='Reply includes warranty keyword' for x in detail(n,t)['messages']),'reply visible to every selected participant')
 d=detail(203,t);actor(203,f"select public.mark_team_support_read('{t}',{d['read_through']})")
 ok(detail(203,t)['thread']['unread_count']==0 and detail(201,t)['thread']['unread_count']>0,'read receipts independent per participant')
 actor(204,f"select public.set_team_support_state('{t}','archive')")
 ok(any(x['id']==t for x in board(204,'archive','warranty')['threads']),'personal archive searches replies')
 ok(any(x['id']==t for x in board(202)['threads']),'archive does not move others inboxes')
 group(202,[],thread=t,body='New reply reopens archive')
 ok(any(x['id']==t for x in board(204)['threads']),'new reply reopens each non-deleted archived inbox')
 actor(201,f"select public.set_team_support_state('{t}','delete')")
 ok(any(x['id']==t for x in board(201,'trash')['threads']),'any participant has personal Trash')
 ok(not any(x.get('support_thread_id')==t for x in inbox(201)['items']),'personal deletion hides only own notifications')
 ok(detail(204,t)['thread']['can_reply'],'other participants can still reply after one deletes')
 group(204,[],thread=t,body='Reply while another member has Trash')
 ok(not any(x.get('support_thread_id')==t for x in inbox(201)['items']),'new messages do not resurrect personal Trash')
 actor(201,f"select public.set_team_support_state('{t}','restore')")
 ok(any(x['body']=='Reply while another member has Trash' for x in detail(201,t)['messages']),'personal restore retains shared history')
 # An Emergency always needs an active included manager; unrelated store managers do not count.
 for op in [lambda:group(202,[204],category='emergency'),lambda:group(202,[],thread=peer['thread_id'],urgent=True)]:
  try:op();raise AssertionError('Emergency without manager accepted')
  except AssertionError as error:ok('Include an active manager' in str(error),'Emergency manager requirement enforced')
 urgent=group(202,[],thread=t,urgent=True,body='Emergency for both included managers')
 ok(sql(f"select count(*) from private.support_email_queue where message_id='{urgent['message_id']}'").stdout.strip()=='2','each included manager gets a separate email job despite email opt-out')
 ok(sql(f"select count(*) from private.support_email_queue where message_id='{urgent['message_id']}' and manager_id not in ('{mid(201)}','{mid(203)}')").stdout.strip()=='0','no other manager receives Emergency email')
 # Existing service-role worker still claims separate scoped, stable jobs.
 job=json.loads(sql("set role service_role;select public.claim_support_email(null)").stdout.strip())
 ok(job['thread_id']==t and job['email'] in ['push201@example.test','push203@example.test'],'email worker selects included manager')
 second=json.loads(sql("set role service_role;select public.claim_support_email(null)").stdout.strip())
 ok(second['id']!=job['id'] and second['email']!=job['email'],'queue lease and distinct manager deliveries')
 actor(201,f"select public.set_team_support_state('{t}','delete')")
 sql(f"update private.support_participants set deleted_at=now()-interval '31 days' where thread_id='{t}' and membership_id='{mid(201)}';")
 reject(201,f"select public.get_team_support_thread('{t}')",'Private conversation not available')
 reject(201,f"select public.set_team_support_state('{t}','restore')",'Recovery period has expired')
 sql('select private.purge_expired_support_trash()')
 ok(len(detail(204,t)['messages'])>=4,'expired personal copy does not erase others history')
 sql(f"update public.organization_memberships set status='inactive' where id='{mid(203)}';")
 try:group(202,[],thread=t,urgent=True);raise AssertionError('Emergency without available manager accepted')
 except AssertionError as error:ok('Include an active manager' in str(error),'inactive/deleted manager no longer qualifies for Emergency')
 group(202,[],thread=t,body='Employees can keep a normal conversation going')
 reject(203,f"select public.get_team_support_thread('{t}')",'Private conversation not available')
 # Stable recipient set: promoting an unrelated employee grants no group access.
 sql(f"update public.organization_memberships set role='manager' where id='{mid(207)}';")
 reject(207,f"select public.get_team_support_thread('{t}')",'Private conversation not available')
 # Physical erasure only after every personal copy expires.
 sql(f"update private.support_participants set deleted_at=now()-interval '31 days' where thread_id='{t}';select private.purge_expired_support_trash();")
 ok(sql(f"select count(*) from private.support_threads where id='{t}'").stdout.strip()=='0','last expired copy purges thread')
 ok(sql(f"select count(*) from private.support_messages where thread_id='{t}'").stdout.strip()=='0','group purge cascades messages and jobs')
 # Concurrent lost-response retries still create just one shared group and receipt per recipient.
 retry_key=str(uuid.uuid4())
 with concurrent.futures.ThreadPoolExecutor(max_workers=3) as pool:
  attempts=list(pool.map(lambda _:group(202,[204,207],key=retry_key),range(3)))
 ok(all(x==attempts[0] for x in attempts),'concurrent group submission key is idempotent')
 current=attempts[0]['thread_id']
 ok(sql(f"select count(*) from private.support_messages where thread_id='{current}'").stdout.strip()=='1','concurrent retry stores one message')
 actor(202,f"do $loop$begin for i in 1..55 loop perform public.send_team_support_message('{store}',gen_random_uuid(),'Group history '||i,thread=>'{current}');end loop;end$loop$")
 d=detail(207,current);ok(len(d['messages'])==50 and d['has_older'],'group history pages at fifty messages')
 remaining=data(207,f"select public.mark_team_support_read('{current}',{d['read_through']},{d['messages'][0]['seq']})")
 ok(remaining==6,'group reading leaves unseen older messages unread')
 group(202,[],thread=current,body='Concurrent newer group reply')
 remaining=data(207,f"select public.mark_team_support_read('{current}',{d['read_through']})")
 ok(remaining==1,'group cutoff leaves a later reply unread')
 ok(detail(204,current)['thread']['unread_count']==57,'one participants reads never clear another participants receipts')
 print(f'Passed {checks} group/direct messaging, legacy migration, recipient/privacy, personal inbox, Emergency manager/email, read/search, concurrency/paging and retention checks.')
finally:
 subprocess.run(['docker','rm','-f',name],capture_output=True)
