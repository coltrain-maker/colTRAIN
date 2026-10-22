"""Exercise the browser against real local SQL/RLS; Auth HTTP responses are mocked.
No hosted database access, real credentials, or outbound emails are used.
"""
from pathlib import Path
from email.parser import BytesParser
from email.policy import default as mail_policy
import base64, json, os, re, subprocess, time, uuid
from urllib.parse import urlparse, parse_qs
from playwright.sync_api import sync_playwright, expect
root=Path(__file__).resolve().parent.parent
name='coltrain-admin-ui-'+uuid.uuid4().hex[:8]
image='postgres:17-alpine@sha256:b0f9560a2de083e2cc7382e75f808c7381a32852a7ec49117deedb300e552b24'
subprocess.run(['node','scripts/build-accounts.mjs'],cwd=root,check=True,env={**os.environ,'SUPABASE_PUBLISHABLE_KEY':'sb_publishable_local_test_only'})
html=(root/'accounts/index.html').read_text()
def sql(statement):
 r=subprocess.run(['docker','exec','-i',name,'psql','-X','-qAt','-v','ON_ERROR_STOP=1','-U','postgres'],input=statement,text=True,capture_output=True)
 if r.returncode:raise RuntimeError(r.stderr)
 return r.stdout.strip()
def quote(value):return "'"+str(value).replace("'","''")+"'"
def arg(value):
 if value is None:return 'null'
 if isinstance(value,bool):return 'true' if value else 'false'
 if isinstance(value,list):
  if value and isinstance(value[0],dict):return quote(json.dumps(value))+'::jsonb'
  return 'array['+','.join(quote(v) for v in value)+']::uuid[]'
 if isinstance(value,dict):return quote(json.dumps(value))+'::jsonb'
 return quote(value)
def query_as(uid,statement):return sql('begin;set local role authenticated;set local request.jwt.claim.sub='+quote(uid)+';'+statement+';commit;')
encode=lambda value:base64.urlsafe_b64encode(json.dumps(value).encode()).decode().rstrip('=')
people={'manager.b@example.test':'00000000-0000-0000-0000-000000000003','employee.b@example.test':'00000000-0000-0000-0000-000000000005','admin@example.test':'00000000-0000-0000-0000-000000000001','manager.a@example.test':'00000000-0000-0000-0000-000000000002','employee.a@example.test':'00000000-0000-0000-0000-000000000004'}
def person(uid):return {'id':uid,'email':next(email for email,value in people.items() if value==uid),'aud':'authenticated','role':'authenticated','user_metadata':{},'app_metadata':{'provider':'email'}}
def token(uid):return encode({'alg':'HS256','typ':'JWT'})+'.'+encode({'sub':uid,'role':'authenticated','exp':int(time.time())+3600})+'.local-test'
storage_bytes={}
lost_upload_response=False
def handle(route):
 global lost_upload_response
 url=route.request.url
 asset_path=urlparse(url).path
 if url.startswith('https://training.example/accounts/') and asset_path in ['/accounts/manifest.webmanifest','/accounts/icons/coltrain.svg','/accounts/icons/apple-touch-icon.png','/accounts/icons/icon-192.png','/accounts/icons/icon-512.png','/accounts/icons/icon-maskable-512.png']:
     mime='application/manifest+json' if asset_path.endswith('.webmanifest') else 'image/svg+xml' if asset_path.endswith('.svg') else 'image/png'
     return route.fulfill(content_type=mime,body=(root/asset_path.lstrip('/')).read_bytes())
 if url.startswith('https://training.example/accounts/') and urlparse(url).path=='/accounts/':return route.fulfill(content_type='text/html',body=html)
 assert url.startswith('https://flhdeftduysnjvqnhhee.supabase.co/'),url
 parsed=urlparse(url);path=parsed.path;params=parse_qs(parsed.query)
 header=route.request.headers.get('authorization','').removeprefix('Bearer ')
 uid=json.loads(base64.urlsafe_b64decode(header.split('.')[1]+'==='))['sub'] if header.count('.')==2 else None
 try:
  if path=='/auth/v1/token':
   uid=people[route.request.post_data_json['email']];result={'access_token':token(uid),'refresh_token':'local-refresh','expires_in':3600,'token_type':'bearer','user':person(uid)}
  elif path=='/auth/v1/user':result=person(uid)
  elif path=='/auth/v1/logout':result={}
  elif path=='/functions/v1/team-support-email':result={'delivery_status':'processed','processed':0} # Mock email transport; private messages use real SQL.
  elif path=='/functions/v1/employee-login':result={'delivery_status':'processed','processed':0} # Email transport stub; first-login RPC remains real SQL.
  elif path.startswith('/storage/v1/object/'):
   storage_path=path.removeprefix('/storage/v1/object/').removeprefix('authenticated/')
   bucket,_,object_name=storage_path.partition('/')
   assert bucket in ('team-media','profile-photos')
   storage_key=bucket+'/'+object_name
   if route.request.method=='POST':
    if storage_key in storage_bytes:
     return route.fulfill(status=409,content_type='application/json',body=json.dumps({'statusCode':409,'error':'Duplicate','message':'The resource already exists'}))
    payload=route.request.post_data_buffer
    content_type=route.request.headers.get('content-type','')
    if content_type.startswith('multipart/form-data'):
     message=BytesParser(policy=mail_policy).parsebytes(('Content-Type: '+content_type+'\r\nMIME-Version: 1.0\r\n\r\n').encode()+payload)
     image_part=next(part for part in message.iter_parts() if part.get_content_maintype()=='image')
     payload=image_part.get_payload(decode=True);content_type=image_part.get_content_type()
    assert len(payload)<=1048576 and content_type=='image/jpeg'
    object_id=query_as(uid,"insert into storage.objects(bucket_id,name) values("+quote(bucket)+","+quote(object_name)+") returning id")
    storage_bytes[storage_key]=payload
    if lost_upload_response:
     lost_upload_response=False
     return route.fulfill(status=500,content_type='application/json',body=json.dumps({'statusCode':500,'error':'Test failure','message':'Test response lost after storage commit'}))
    result={'Key':storage_key,'Id':object_id}
   elif route.request.method=='GET':
    allowed=query_as(uid,"select count(*) from storage.objects where bucket_id="+quote(bucket)+" and name="+quote(object_name))
    if allowed!='1':return route.fulfill(status=403,content_type='application/json',body=json.dumps({'statusCode':403,'error':'Forbidden','message':'Photo not available'}))
    return route.fulfill(status=200,content_type='image/jpeg',body=storage_bytes[storage_key])
   elif route.request.method=='DELETE':
    removed=[]
    for name_to_remove in route.request.post_data_json['prefixes']:
     deleted=query_as(uid,'delete from storage.objects where bucket_id='+quote(bucket)+' and name='+quote(name_to_remove)+' returning name')
     if deleted:
      storage_bytes.pop(bucket+'/'+name_to_remove,None);removed.append({'name':name_to_remove})
    result=removed
   else:raise AssertionError('Unexpected storage method')
  elif path=='/functions/v1/admin-update':
   body=route.request.post_data_json
   query_as(uid,'select public.get_admin_updates()')
   if body['action']=='send':
    args=','.join('"'+key+'"=>'+arg(value) for key,value in body['payload'].items())
    created=json.loads(query_as(uid,'select public.send_admin_update('+args+')'));identifier=created['id']
   else:identifier=body['update_id'];created={}
   history=json.loads(query_as(uid,'select public.get_admin_updates()'))
   result={**created,'id':identifier,'processed':0,'delivery_status':'not_configured','update':next(a for a in history if a['id']==identifier)}
  elif path.startswith('/rest/v1/rpc/'):
   function=path.rsplit('/',1)[1];assert re.fullmatch('[a-z_]+',function)
   arguments=','.join('"'+key+'"=>'+arg(value) for key,value in route.request.post_data_json.items())
   result=json.loads(query_as(uid,'select to_jsonb(public."'+function+'"('+arguments+'))') or 'null')
  elif path.startswith('/rest/v1/'):
   table=path.rsplit('/',1)[1];assert re.fullmatch('[a-z_]+',table)
   columns=params.get('select',['*'])[0];assert columns=='*' or all(re.fullmatch('[a-z_]+',col) for col in columns.split(','))
   conditions=[]
   for key,values in params.items():
    if key in ('select','order'):continue
    assert re.fullmatch('[a-z_]+',key)
    for value in values:
     assert value.startswith('eq.')
     conditions.append('"'+key+'"='+quote(value[3:]))
   where=' where '+' and '.join(conditions) if conditions else ''
   order=''
   if 'order' in params:
    column,sort=params['order'][0].split('.')[:2];assert re.fullmatch('[a-z_]+',column) and sort in ('asc','desc')
    order=' order by "'+column+'" '+sort
   result=json.loads(query_as(uid,"select coalesce(jsonb_agg(to_jsonb(rows)),'[]') from (select "+columns+' from public."'+table+'"'+where+order+') rows'))
  else:raise AssertionError('Unexpected endpoint '+path)
  route.fulfill(status=200,content_type='application/json',headers={'access-control-allow-origin':'*'},body=json.dumps(result))
 except RuntimeError as error:
  route.fulfill(status=400,content_type='application/json',headers={'access-control-allow-origin':'*'},body=json.dumps({'code':'P0001','message':str(error)}))

subprocess.run(['docker','run','--rm','-d','--name',name,'--network','none','-e','POSTGRES_HOST_AUTH_METHOD=trust',image],check=True,capture_output=True)
try:
 for _ in range(80):
  if subprocess.run(['docker','exec',name,'pg_isready','-h','127.0.0.1','-U','postgres'],capture_output=True).returncode==0:break
  time.sleep(.25)
 sql((root/'tests/supabase-auth-fixture.sql').read_text())
 for p in sorted((root/'supabase/migrations').glob('*.sql')):sql(p.read_text())
 sql("""insert into auth.users(id,email,email_confirmed_at) values
 ('00000000-0000-0000-0000-000000000001','admin@example.test',now()),
 ('00000000-0000-0000-0000-000000000002','manager.a@example.test',now()),
 ('00000000-0000-0000-0000-000000000003','manager.b@example.test',now()),
 ('00000000-0000-0000-0000-000000000004','employee.a@example.test',now()),
 ('00000000-0000-0000-0000-000000000005','employee.b@example.test',now());
 insert into public.profiles(user_id,full_name,optional_email_notifications) select id,'Test person',true from auth.users;
 insert into public.platform_admins values('00000000-0000-0000-0000-000000000001');
 insert into public.organizations(id,name) values('10000000-0000-0000-0000-000000000099','Coltrain Hardware'),('10000000-0000-0000-0000-000000000098','Second Store');
 insert into public.organization_memberships(id,organization_id,user_id,email,role)
 select ('20000000-0000-0000-0000-'||lpad(n::text,12,'0'))::uuid,
 case when n in (3,5) then '10000000-0000-0000-0000-000000000098' else '10000000-0000-0000-0000-000000000099' end::uuid,
 ('00000000-0000-0000-0000-'||lpad(n::text,12,'0'))::uuid,case n when 2 then 'manager.a@example.test' when 3 then 'manager.b@example.test' when 4 then 'employee.a@example.test' else 'employee.b@example.test' end,case when n in (2,3) then 'manager' else 'employee' end
 from generate_series(2,5) n;
 insert into public.seats(organization_id,membership_id) select organization_id,id from public.organization_memberships;""")
 with sync_playwright() as p:
  browser=p.chromium.launch(executable_path='/usr/bin/chromium',args=['--no-sandbox']);page=browser.new_page(service_workers='block',viewport={'width':1280,'height':1000});errors=[]
  page.on('pageerror',lambda e:errors.append(str(e)));page.route('**/*',handle)
  def navigate(label):page.get_by_role('button',name='Open menu').click();page.locator('.training-drawer').get_by_role('button',name=label,exact=True).click()
  def login(email):
   page.goto('https://training.example/accounts/');page.locator('#auth-form input[name=email]').fill(email);page.locator('#auth-form input[name=password]').fill('Local test password');page.locator('#auth-form button[type=submit]').click();expect(page.locator('.page-heading h1')).to_be_visible()
  def logout():navigate('Sign out and switch accounts');expect(page.locator('#auth-form')).to_be_visible()
  def compose(title,audience,all_stores=False):
   page.locator('#training-admin-update-form input[name=title]').fill(title)
   page.locator('#training-admin-update-form textarea[name=body]').fill('Hello team.\nThis is an admin update, with <script>text only</script>.')
   page.locator('#training-admin-update-form select[name=audience]').select_option(audience)
   if all_stores:page.get_by_label('To all stores',exact=True).check()
   else:
    page.get_by_label('Select individual stores',exact=True).check()
    for box in page.locator('[data-update-stores] input').all():box.uncheck()
    page.get_by_label('Coltrain Hardware',exact=True).check()
   page.locator('#training-admin-update-form input[name=link_url]').fill('https://example.test/update')
   page.get_by_role('button',name='Preview recipients',exact=True).click();expect(page.get_by_role('heading',name='Review your update',exact=True)).to_be_visible()
  login('admin@example.test');navigate('Admin updates')
  compose('Manager-only news','manager')
  expect(page.locator('main')).to_contain_text('1 in-app recipients · 1 opted-in email recipients')
  assert sql('select count(*) from private.admin_updates')=='0'
  page.screenshot(path=str(root/'design/admin-update-preview.png'),full_page=True)
  page.get_by_role('button',name='Edit update',exact=True).click();expect(page.locator('#training-admin-update-form input[name=title]')).to_have_value('Manager-only news')
  page.get_by_role('button',name='Preview recipients',exact=True).click();page.get_by_role('button',name='Send update',exact=True).click();expect(page.locator('.admin-update-history')).to_have_count(1)
  expect(page.locator('#account-message')).to_contain_text('messages remain queued')
  compose('Employee news','employee',True);expect(page.locator('main')).to_contain_text('2 in-app recipients · 2 opted-in email recipients')
  page.get_by_role('button',name='Send update',exact=True).click();expect(page.locator('.admin-update-history')).to_have_count(2)
  compose('Everyone news','both');expect(page.locator('main')).to_contain_text('2 in-app recipients · 2 opted-in email recipients')
  page.get_by_role('button',name='Send update',exact=True).click();expect(page.locator('.admin-update-history')).to_have_count(3)
  logout();login('employee.a@example.test');page.get_by_role('button',name='Open menu').click();assert page.get_by_role('button',name='Admin updates',exact=True).count()==0;page.keyboard.press('Escape');navigate('Notifications')
  expect(page.locator('.training-notification')).to_have_count(2);assert 'Manager-only news' not in page.locator('main').inner_text()
  expect(page.locator('.training-notification a')).to_have_count(2);assert page.locator('.training-notification script').count()==0
  page.get_by_role('button',name='Mark all as read',exact=True).click();page.get_by_role('button',name='Refresh notifications',exact=True).click();expect(page.locator('.notification-unread')).to_have_count(0)
  page.set_viewport_size({'width':390,'height':844});assert page.locator('body').evaluate('n=>n.scrollWidth<=innerWidth');page.screenshot(path=str(root/'design/admin-update-inbox-mobile.png'),full_page=True)
  logout();login('manager.a@example.test');navigate('Notifications');expect(page.locator('.training-notification')).to_have_count(3);expect(page.get_by_role('heading',name='An employee has signed in',exact=True)).to_be_visible();expect(page.locator('main')).to_contain_text('Manager-only news');assert 'Employee news' not in page.locator('main').inner_text()
  logout();login('employee.b@example.test');navigate('Notifications');expect(page.locator('.training-notification')).to_have_count(1);expect(page.locator('main')).to_contain_text('Employee news')
  logout();login('admin@example.test');navigate('Admin updates');page.locator('.admin-update-history').filter(has=page.get_by_role('heading',name='Everyone news',exact=True)).get_by_role('button',name='Archive update',exact=True).click();expect(page.locator('.admin-update-history').filter(has=page.get_by_role('heading',name='Everyone news',exact=True))).to_contain_text('Archived')
  assert not errors,errors;browser.close()
 print('Passed admin updates UI + real SQL/RLS: explicit store scope, role targeting, recipient/email preview, draft edit, queued-email status, inbox privacy/read receipts, links/plain text, mobile and archive. Email HTTP is stubbed; no live messages sent.')
finally:
 subprocess.run(['docker','rm','-f',name],capture_output=True)
 subprocess.run(['node','scripts/build-accounts.mjs'],cwd=root,check=True)
