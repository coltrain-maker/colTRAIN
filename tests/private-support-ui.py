"""Private support browser checks backed by real local SQL/RLS. All email HTTP is stubbed."""
from pathlib import Path
import base64,json,os,re,subprocess,time,uuid
from urllib.parse import urlparse,parse_qs
from playwright.sync_api import sync_playwright,expect
root=Path(__file__).resolve().parent.parent;name='coltrain-support-ui-'+uuid.uuid4().hex[:8]
image='postgres:17-alpine@sha256:b0f9560a2de083e2cc7382e75f808c7381a32852a7ec49117deedb300e552b24'
subprocess.run(['node','scripts/build-accounts.mjs'],cwd=root,check=True,env={**os.environ,'SUPABASE_PUBLISHABLE_KEY':'sb_publishable_local_test_only'})
html=(root/'accounts/index.html').read_text();store='10000000-0000-0000-0000-000000000200'
def uid(n):return f'00000000-0000-0000-0000-{n:012}'
def mid(n):return f'20000000-0000-0000-0000-{n:012}'
def sql(q):
 r=subprocess.run(['docker','exec','-i',name,'psql','-X','-qAt','-v','ON_ERROR_STOP=1','-U','postgres'],input=q,text=True,capture_output=True)
 if r.returncode:raise RuntimeError(r.stderr)
 return r.stdout.strip()
def quote(v):return "'"+str(v).replace("'","''")+"'"
def arg(v):
 if v is None:return 'null'
 if isinstance(v,bool):return str(v).lower()
 if isinstance(v,list):return 'array['+','.join(quote(x) for x in v)+']::uuid[]'
 return quote(v)
def actor(person,q):return sql(f"begin;set local role authenticated;set local request.jwt.claim.sub='{person}';{q};commit;")
people={f'support{n}@example.test':uid(n) for n in range(200,205)}
encode=lambda x:base64.urlsafe_b64encode(json.dumps(x).encode()).decode().rstrip('=')
def person(u):return {'id':u,'email':next(e for e,i in people.items() if i==u),'aud':'authenticated','role':'authenticated','user_metadata':{},'app_metadata':{'provider':'email'}}
def token(u):return encode({'alg':'HS256','typ':'JWT'})+'.'+encode({'sub':u,'role':'authenticated','exp':int(time.time())+3600})+'.fixture'
lost=[False]
def handle(route):
 url=route.request.url;p=urlparse(url);path=p.path;params=parse_qs(p.query)
 if url.startswith('https://training.example/accounts/'):
  if path=='/accounts/':return route.fulfill(content_type='text/html',body=html)
  if path.startswith('/accounts/icons/') or path.endswith('manifest.webmanifest'):
   return route.fulfill(content_type='application/manifest+json' if path.endswith('webmanifest') else 'image/png',body=(root/path.lstrip('/')).read_bytes())
  return route.abort()
 assert url.startswith('https://flhdeftduysnjvqnhhee.supabase.co/'),url
 auth=route.request.headers.get('authorization','').removeprefix('Bearer ')
 user=json.loads(base64.urlsafe_b64decode(auth.split('.')[1]+'==='))['sub'] if auth.count('.')==2 else None
 try:
  if path=='/auth/v1/token':
   user=people[route.request.post_data_json['email']];result={'access_token':token(user),'refresh_token':'fixture-refresh','expires_in':3600,'token_type':'bearer','user':person(user)}
  elif path=='/auth/v1/user':result=person(user)
  elif path=='/auth/v1/logout':result={}
  elif path=='/functions/v1/employee-login':result={'delivery_status':'processed'}
  elif path=='/functions/v1/team-support-email':
   for _ in range(20):
    job=json.loads(sql(f"set role service_role;select public.claim_support_email('{user}')") or 'null')
    if not job:break
    if job.get('skip'):continue
    sql(f"set role service_role;select public.finish_support_email('{job['id']}','{job['lease_id']}',true,'fixture-provider')")
   result={'delivery_status':'processed'}
  elif path.startswith('/rest/v1/rpc/'):
   function=path.rsplit('/',1)[1];assert re.fullmatch('[a-z_]+',function)
   args=','.join('"'+k+'"=>'+arg(v) for k,v in route.request.post_data_json.items())
   result=json.loads(actor(user,'select to_jsonb(public."'+function+'"('+args+'))') or 'null')
   if function=='send_team_support_message' and lost[0]:lost[0]=False;return route.fulfill(status=500,content_type='application/json',body=json.dumps({'message':'Fixture lost response after commit'}))
  elif path.startswith('/rest/v1/'):
   table=path.rsplit('/',1)[1];assert re.fullmatch('[a-z_]+',table)
   columns=params.get('select',['*'])[0];assert columns=='*' or all(re.fullmatch('[a-z_]+',x) for x in columns.split(','))
   conditions=[]
   for k,vs in params.items():
    if k in ('select','order'):continue
    assert re.fullmatch('[a-z_]+',k)
    for v in vs:assert v.startswith('eq.');conditions.append('"'+k+'"='+quote(v[3:]))
   order=''
   if 'order' in params:
    col,direction=params['order'][0].split('.')[:2];assert re.fullmatch('[a-z_]+',col) and direction in ('asc','desc');order=' order by "'+col+'" '+direction
   result=json.loads(actor(user,"select coalesce(jsonb_agg(to_jsonb(x)),'[]') from (select "+columns+' from public."'+table+'"'+(' where '+' and '.join(conditions) if conditions else '')+order+')x'))
   if 'application/vnd.pgrst.object+json' in route.request.headers.get('accept',''):result=result[0] if result else None
  else:raise AssertionError(path)
  route.fulfill(content_type='application/json',body=json.dumps(result))
 except RuntimeError as e:route.fulfill(status=400,content_type='application/json',body=json.dumps({'message':str(e),'code':'P0001'}))
subprocess.run(['docker','run','--rm','-d','--name',name,'--network','none','-e','POSTGRES_HOST_AUTH_METHOD=trust',image],check=True,capture_output=True)
try:
 for _ in range(80):
  if subprocess.run(['docker','exec',name,'pg_isready','-h','127.0.0.1','-U','postgres'],capture_output=True).returncode==0:break
  time.sleep(.25)
 sql((root/'tests/supabase-auth-fixture.sql').read_text())
 for p in sorted((root/'supabase/migrations').glob('*.sql')):sql(p.read_text())
 sql(f"""insert into auth.users(id,email,email_confirmed_at) select ('00000000-0000-0000-0000-'||lpad(n::text,12,'0'))::uuid,'support'||n||'@example.test',now() from generate_series(200,204)n;
 insert into public.profiles(user_id,full_name,optional_email_notifications) select id,case email when 'support201@example.test' then 'Selected Manager' when 'support203@example.test' then 'Other Manager' when 'support202@example.test' then 'Pilot Employee' else 'Another Person' end,false from auth.users;
 insert into public.platform_admins values('{uid(200)}');insert into public.organizations(id,name) values('{store}','Coltrain Hardware');
 insert into public.organization_memberships(id,organization_id,user_id,email,role) select ('20000000-0000-0000-0000-'||lpad(n::text,12,'0'))::uuid,'{store}',('00000000-0000-0000-0000-'||lpad(n::text,12,'0'))::uuid,'support'||n||'@example.test',case when n in(201,203) then 'manager' else 'employee' end from generate_series(201,204)n;""")
 with sync_playwright() as p:
  browser=p.chromium.launch(executable_path='/usr/bin/chromium',args=['--no-sandbox']);page=browser.new_page(service_workers='block',viewport={'width':1280,'height':1000});errors=[]
  page.route('**/*',handle);page.on('pageerror',lambda e:errors.append(str(e)));page.on('dialog',lambda d:d.accept());page.goto('https://training.example/accounts/')
  def login(n):
   page.locator('#auth-form input[name=email]').fill(f'support{n}@example.test');page.locator('#auth-form input[name=password]').fill('Fixture password');page.locator('#auth-form button[type=submit]').click();expect(page.locator('.page-heading h1')).to_be_visible()
  def nav(label):page.get_by_role('button',name='Open menu').click();page.locator('.training-drawer').get_by_role('button',name=label,exact=True).click()
  def logout():page.get_by_role('button',name='Open menu').click();page.get_by_role('button',name='Sign out and switch accounts',exact=True).click();expect(page.locator('#auth-form')).to_be_visible()
  login(202);nav('Team support');expect(page.locator('.page-heading h1')).to_have_text('Team support');page.get_by_role('button',name='New message',exact=True).click()
  page.locator('#training-support-new input[name=recipients][value="'+mid(201)+'"]').check();page.locator('#training-support-new select[name=category]').select_option('customer');page.locator('#training-support-new input[name=subject]').fill('Customer return question');page.locator('#training-support-new textarea').fill('Please help with this return. <img src=x onerror=alert(1)>')
  page.get_by_role('button',name='Open menu').click();page.get_by_role('button',name='Close',exact=True).click();expect(page.locator('#training-support-new textarea')).to_contain_text('<img')
  lost[0]=True;page.get_by_role('button',name='Send private message',exact=True).click();expect(page.locator('#account-message')).to_contain_text('lost response');page.get_by_role('button',name='Send private message',exact=True).click()
  expect(page.locator('.support-conversation h2')).to_have_text('Customer return question');assert page.locator('.support-message img').count()==0
  assert sql('select count(*) from private.support_threads')=='1';assert sql('select count(*) from private.support_messages')=='1'
  thread=sql('select id from private.support_threads');logout();login(203);nav('Team support');expect(page.locator('.support-thread-row')).to_have_count(0);logout()
  login(201);nav('Notifications');page.get_by_role('button',name='Open conversation',exact=True).click();expect(page.locator('.support-conversation h2')).to_have_text('Customer return question')
  page.locator('#training-support-reply textarea').fill('Bring the warranty receipt to the counter.');page.get_by_role('button',name='Send reply',exact=True).click();expect(page.locator('.support-message')).to_have_count(2)
  page.locator('.support-conversation').get_by_role('button',name='Archive',exact=True).click();page.get_by_role('button',name='Archive',exact=True).first.click();page.locator('.support-search input').fill('warranty receipt');page.get_by_role('button',name='Search',exact=True).click();expect(page.locator('.support-thread-row')).to_have_count(1)
  page.get_by_role('button',name='Customer return question',exact=True).click();expect(page.locator('.support-conversation h2')).to_have_text('Customer return question');expect(page.get_by_role('button',name='New message',exact=True)).to_be_enabled();page.screenshot(path=str(root/'design/team-support-manager.png'),full_page=True)
  logout();login(202);nav('Notifications');page.get_by_role('button',name='Open conversation',exact=True).click();expect(page.locator('.support-message')).to_have_count(2)
  page.locator('#training-support-reply textarea').fill('I need urgent help with the customer.');page.locator('#training-support-reply input[name=emergency]').check();page.get_by_role('button',name='Send reply',exact=True).click();expect(page.locator('.support-email-status')).to_contain_text('1 request accepted');expect(page.locator('.support-message')).to_have_count(3)
  assert sql("select count(*) from private.support_email_queue where status='sent'")=='1'
  page.set_viewport_size({'width':390,'height':844});assert page.locator('body').evaluate('n=>n.scrollWidth<=innerWidth');page.screenshot(path=str(root/'design/team-support-employee-mobile.png'),full_page=True)
  logout();login(201);page.goto('https://training.example/accounts/?support_thread='+thread);expect(page.locator('.support-conversation h2')).to_have_text('Customer return question');assert 'support_thread' not in page.url
  page.locator('.support-conversation').get_by_role('button',name='Delete',exact=True).click();page.get_by_role('button',name='Trash',exact=True).click();expect(page.locator('.support-thread-row')).to_have_count(1)
  page.get_by_role('button',name='Restore conversation',exact=True).click();page.get_by_role('button',name='Inbox',exact=True).click();expect(page.locator('.support-thread-row')).to_have_count(1)
  logout();login(204);nav('Team support');expect(page.locator('.support-thread-row')).to_have_count(0)
  logout();login(203);page.goto('https://training.example/accounts/?support_thread='+thread);expect(page.locator('#account-message')).to_contain_text('not available');assert 'warranty receipt' not in page.locator('main').inner_text()
  logout();login(202);nav('Team support');page.get_by_role('button',name='New message',exact=True).click()
  page.locator('input[name=contact_search]').fill('Another')
  page.locator('#training-support-new input[name=recipients][value="'+mid(204)+'"]').check()
  page.locator('input[name=contact_search]').fill('')
  page.locator('#training-support-new select[name=category]').select_option('emergency')
  page.locator('#training-support-new input[name=subject]').fill('Selected staff conversation')
  page.locator('#training-support-new textarea').fill('Private group message')
  page.get_by_role('button',name='Send private message',exact=True).click()
  expect(page.locator('#account-message')).to_contain_text('Include an active manager')
  page.locator('#training-support-new input[name=recipients][value="'+mid(201)+'"]').check()
  page.locator('#training-support-new input[name=recipients][value="'+mid(203)+'"]').check()
  page.get_by_role('button',name='Send private message',exact=True).click()
  expect(page.locator('.support-conversation h2')).to_have_text('Selected staff conversation')
  expect(page.locator('.support-conversation')).to_contain_text('Other Manager')
  expect(page.locator('.support-email-status')).to_contain_text('2 requests accepted')
  group_thread=sql("select id from private.support_threads where subject='Selected staff conversation'")
  logout();login(204);nav('Team support')
  page.get_by_role('button',name='Selected staff conversation',exact=True).click()
  page.locator('#training-support-reply textarea').fill('Everyone in this group can see this reply')
  page.get_by_role('button',name='Send reply',exact=True).click()
  expect(page.locator('.support-message')).to_have_count(2)
  # Every person has personal Archive/Trash, without removing anyone else's messages.
  page.locator('.support-conversation').get_by_role('button',name='Delete',exact=True).click()
  page.get_by_role('button',name='Trash',exact=True).click();expect(page.locator('.support-thread-row')).to_have_count(1)
  logout();login(202);nav('Team support')
  page.get_by_role('button',name='Selected staff conversation',exact=True).click()
  expect(page.locator('.support-message')).to_have_count(2)
  page.set_viewport_size({'width':390,'height':844});assert page.locator('body').evaluate('n=>n.scrollWidth<=innerWidth')
  page.screenshot(path=str(root/'design/team-support-group-mobile.png'),full_page=True)
  logout();login(204);nav('Team support');page.get_by_role('button',name='Trash',exact=True).click()
  page.get_by_role('button',name='Restore conversation',exact=True).click();page.get_by_role('button',name='Inbox',exact=True).click()
  page.get_by_role('button',name='New message',exact=True).click()
  page.locator('#training-support-new input[name=recipients][value="'+mid(202)+'"]').check()
  page.locator('#training-support-new input[name=subject]').fill('Employee direct message')
  page.locator('#training-support-new textarea').fill('One to one between employees')
  page.get_by_role('button',name='Send private message',exact=True).click()
  expect(page.locator('.support-conversation h2')).to_have_text('Employee direct message')
  assert not errors,errors;browser.close()
 print('Passed private Team support browser + SQL/RLS: participant/group privacy, peer messages, lost-response retry, safe text, reply notifications, archived-message search, Emergency email override, mobile, private deep links and Trash recovery. Email provider HTTP was stubbed.')
finally:
 subprocess.run(['docker','rm','-f',name],capture_output=True);subprocess.run(['node','scripts/build-accounts.mjs'],cwd=root,check=True)
