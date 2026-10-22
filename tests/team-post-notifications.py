"""Isolated PostgreSQL checks; no hosted account access or email provider traffic."""
from pathlib import Path
import json,subprocess,time,uuid,concurrent.futures
root=Path(__file__).resolve().parent.parent
name='coltrain-team-notify-'+uuid.uuid4().hex[:8]
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

 def post(n=202,message='New safety reminder',key=None,announcement=False):
  value=actor(n,f"select public.create_team_corner_post('{store}','{key or uuid.uuid4()}',{quote(message)},is_announcement=>{str(announcement).lower()})").stdout.strip()
  return value
 def posts(n):return [i for i in inbox(n,other if n in (205,206) else store)['items'] if i['kind']=='team_post']
 # Old posts do not fan out. Simulate migration applied to an existing live feed.
 sql('alter table public.team_corner_posts disable trigger coltrain_new_team_post;')
 old=post(message='Existing post before update')
 sql('alter table public.team_corner_posts enable trigger coltrain_new_team_post;')
 ok(posts(201)==[],'no historical backfill')
 p=post(message='<script>private store content</script>')
 ok(posts(202)==[],'author not notified')
 for n in [201,203,204,207]:
  result=posts(n);ok(len(result)==1 and result[0]['team_post_id']==p,'each active teammate gets one alert')
  ok(result[0]['target_view']=='team' and '<script>' not in result[0]['body'],'generic in-app text links to feed')
 ok(posts(205)==[] and posts(206)==[],'other store gets no alerts')
 ok(posts(200)==[],'platform administrator without membership gets no feed alerts')
 reject(204,'select * from private.team_post_audience','permission denied')
 note=posts(201)[0]['id'];actor(201,f"select public.mark_training_notifications_read('{store}',array['{note}'::uuid])")
 ok(posts(201)[0]['read_at'] is not None,'read receipt persists')
 post(key=p,message='New safety reminder')
 ok(len(posts(201))==1 and posts(201)[0]['id']==note and posts(201)[0]['read_at'] is not None,'idempotent post retry creates no duplicate/reset')
 actor(204,f"select public.create_team_corner_comment('{p}',gen_random_uuid(),'Comment without a new post alert')")
 actor(204,f"select public.set_team_corner_like('{p}',true)")
 actor(201,f"select public.set_team_corner_post_options('{p}',true,false)")
 ok(len(posts(204))==1,'comment, like and pin do not add alerts')
 ok(data(204,f"select public.get_team_corner_post('{p}')")['id']==p,'recipient opens exact post')
 reject(205,f"select public.get_team_corner_post('{p}')",'Store feed access required')
 reject(200,f"select public.get_team_corner_post('{p}')",'Store feed access required')
 actor(201,f"select public.request_team_corner_support('{store}','Review feed issue')")
 ok(data(200,f"select public.get_team_corner_post('{p}')")['id']==p and posts(200)==[],'temporary admin feed access receives no notification')
 # An employee enrolled later should not inherit post notifications from before joining.
 sql(f"insert into auth.users(id,email,email_confirmed_at) values('{uid(208)}','new@example.test',now());insert into public.organization_memberships(id,organization_id,user_id,email,role) values('{mid(208)}','{store}','{uid(208)}','new@example.test','employee');")
 ok(posts(208)==[],'late enrollment does not notify historical posts')
 sql(f"update public.organization_memberships set status='inactive' where id='{mid(207)}';")
 q=post(201,'Manager announcement',announcement=True)
 ok(not sql(f"select 1 from private.team_post_audience where post_id='{q}' and membership_id='{mid(207)}'").stdout.strip(),'inactive member excluded at creation')
 ok(any(i['team_post_id']==q and i['title']=='New Team Corner announcement' for i in posts(208)),'manager announcement notifies newly active employee')
 # Existing Web Push snapshots automatically include the new notification kind.
 actor(203,f"select public.save_web_push('https://web.push.apple.com/team-notification','{'A'*87}','{'B'*22}')")
 fresh=post(202,'Newest post triggers existing push worker')
 job=json.loads(sql("set role service_role;select public.claim_web_push();").stdout.strip())
 ok(job['count']==3 and len(job['ids'])==3,'push worker includes unread team post notifications')
 ok('Newest post' not in json.dumps(job),'push payload preparation contains no post body')
 sql(f"update public.organization_memberships set status='inactive' where id='{mid(204)}';")
 reject(204,f"select public.get_my_training_notifications('{store}')",'Active store membership')
 reject(204,f"select public.get_team_corner_post('{p}')",'Store feed access required')
 actor(201,f"select public.remove_team_corner_item('{p}',false)")
 ok(all(i['team_post_id']!=p for i in posts(203)),'removed post disappears from notifications')
 reject(203,f"select public.get_team_corner_post('{p}')",'Store feed access required')
 print(f'Passed {checks} Team Corner notification audience, no-backfill, read/idempotency, deletion, private deep-link and Web Push integration checks.')
finally:
 subprocess.run(['docker','rm','-f',name],capture_output=True)
