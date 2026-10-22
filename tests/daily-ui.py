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
name='coltrain-daily-ui-'+uuid.uuid4().hex[:8]
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
people={'admin@example.test':'00000000-0000-0000-0000-000000000001','manager.a@example.test':'00000000-0000-0000-0000-000000000002','employee.a@example.test':'00000000-0000-0000-0000-000000000004'}
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
 sql((root/'supabase/daily-imports/PILOT_10_IMPORT_DRAFTS.sql').read_text())
 sql("""insert into auth.users(id,email,email_confirmed_at) values
 ('00000000-0000-0000-0000-000000000001','admin@example.test',now()),
 ('00000000-0000-0000-0000-000000000002','manager.a@example.test',now()),
 ('00000000-0000-0000-0000-000000000004','employee.a@example.test',now());
 insert into public.platform_admins(user_id) values('00000000-0000-0000-0000-000000000001');
 insert into public.profiles(user_id,full_name) values('00000000-0000-0000-0000-000000000001','Pilot Admin'),('00000000-0000-0000-0000-000000000002','Pilot Manager'),('00000000-0000-0000-0000-000000000004','Pilot Employee');
 insert into public.organizations(id,name) values('10000000-0000-0000-0000-000000000099','Coltrain Hardware');
 insert into public.organization_memberships(id,organization_id,user_id,email,role) values
 ('20000000-0000-0000-0000-000000000002','10000000-0000-0000-0000-000000000099','00000000-0000-0000-0000-000000000002','manager.a@example.test','manager'),
 ('20000000-0000-0000-0000-000000000004','10000000-0000-0000-0000-000000000099','00000000-0000-0000-0000-000000000004','employee.a@example.test','employee');
 insert into public.seats(organization_id,membership_id) select organization_id,id from public.organization_memberships;""")
 store='10000000-0000-0000-0000-000000000099';employee=people['employee.a@example.test'];admin=people['admin@example.test']
 rows=json.loads(sql('select jsonb_agg(to_jsonb(d) order by code) from public.daily_modules d'))
 for m in rows:
  query_as(admin,f"select public.publish_daily_module('{m['id']}')")
  query_as(admin,f"select public.release_daily_module('{store}','{m['id']}')")
 def key(module):return json.loads(sql(f"select jsonb_build_object('id',question_id,'option',correct_option) from private.daily_answer_keys where module_id='{module}'"))
 with sync_playwright() as p:
  browser=p.chromium.launch(executable_path='/usr/bin/chromium',args=['--no-sandbox'])
  page=browser.new_page(service_workers='block',viewport={'width':1280,'height':1000});errors=[]
  page.on('pageerror',lambda e:errors.append(str(e)));page.route('**/*',handle)
  page.goto('https://training.example/accounts/')
  def login(email):
   page.locator('#auth-form input[name=email]').fill(email);page.locator('#auth-form input[name=password]').fill('Local test password');page.locator('#auth-form button[type=submit]').click()
   expect(page.locator('.daily-dashboard h2')).to_have_text('The Daily Drill')
  def dashboard():page.get_by_role('button',name='Back to dashboard',exact=True).click();expect(page.locator('.daily-dashboard')).to_be_visible()
  def signout():
   page.get_by_role('button',name='Open menu').click();page.get_by_role('button',name='Sign out and switch accounts',exact=True).click();expect(page.locator('#auth-form')).to_be_visible()
  login('employee.a@example.test')
  expect(page.locator('.daily-dashboard h3')).to_have_text('Paint Sheen: Recognize the Finish')
  assert page.locator('.daily-dashboard').evaluate('n=>n.compareDocumentPosition(document.querySelector(".learning-section")) & Node.DOCUMENT_POSITION_FOLLOWING')
  expect(page.locator('.daily-levels')).to_contain_text('0 completed · 10 available')
  page.screenshot(path=str(root/'design/daily-drill-dashboard.png'),full_page=True)
  page.get_by_role('button',name='Start your drill',exact=True).click()
  expect(page.locator('.page-heading h1')).to_have_text('The Daily Drill')
  expect(page.locator('.daily-reader h2')).to_have_text(rows[0]['title'])
  expect(page.locator('.daily-table-scroll table')).to_be_visible()
  assert page.locator('.daily-reader img').count()==0
  assert page.locator('.daily-reader').get_by_text('Correct answer',exact=False).count()==0
  page.get_by_text('Sources',exact=True).click();expect(page.locator('.daily-sources a').first).to_be_visible()
  page.screenshot(path=str(root/'design/daily-drill-lesson.png'),full_page=True)
  page.get_by_role('button',name='Take the quick check',exact=True).click()
  expect(page.locator('#training-daily-form input[type=radio]')).to_have_count(4)
  page.get_by_role('button',name='Check my answer',exact=True).click()
  expect(page.locator('#training-daily-form')).to_be_visible()
  k=key(rows[0]['id']);wrong=(k['option']+1)%4
  page.locator(f'#training-daily-form input[value="{wrong}"]').check();page.get_by_role('button',name='Check my answer',exact=True).click()
  expect(page.locator('.daily-feedback')).to_contain_text('Let’s build on that.')
  expect(page.locator('.daily-explanation')).to_contain_text('Eggshell')
  page.reload();page.get_by_role('button',name='Continue your drill',exact=True).click();expect(page.locator('.daily-feedback')).to_contain_text('Let’s build on that.')
  page.get_by_role('button',name='Review lesson',exact=True).click();expect(page.locator('.daily-section')).to_have_count(5)
  page.get_by_role('button',name='Take the quick check',exact=True).click()
  # Simulate a committed submission with a lost HTTP response: retry must reuse the key.
  lost=[True]
  def lost_result(route):
   if lost[0] and route.request.url.endswith('/rpc/submit_daily_check'):
    lost[0]=False
    request=route.request.post_data_json
    arguments=','.join('"'+key_name+'"=>'+arg(value) for key_name,value in request.items())
    query_as(employee,'select public.submit_daily_check('+arguments+')')
    route.fulfill(status=500,content_type='application/json',body=json.dumps({'message':'Test response lost after saving'}))
   else:handle(route)
  page.route('**/rpc/submit_daily_check',lost_result)
  page.locator(f'#training-daily-form input[value="{k["option"]}"]').check();page.get_by_role('button',name='Check my answer',exact=True).click()
  expect(page.locator('#training-daily-form')).to_be_visible();expect(page.locator('#account-message.error')).to_be_visible()
  page.get_by_role('button',name='Check my answer',exact=True).click();expect(page.locator('.daily-feedback')).to_contain_text('Drill complete.')
  assert sql(f"select attempt_count from public.daily_assignments where module_id='{rows[0]['id']}' and membership_id='20000000-0000-0000-0000-000000000004'")=='2'
  expect(page.locator('.daily-feedback')).to_contain_text('+5 Daily Drill points earned.')
  page.screenshot(path=str(root/'design/daily-drill-result.png'),full_page=True)
  page.get_by_role('button',name='Continue to next drill',exact=True).click();expect(page.locator('.daily-reader h2')).to_have_text(rows[1]['title'])
  dashboard();expect(page.locator('.daily-dashboard')).to_contain_text('1 completed · 10 available')
  expect(page.locator('.daily-dashboard')).to_contain_text('5 Daily Drill points')
  expect(page.locator('.stats')).to_contain_text('Daily Drill points')
  page.get_by_role('button',name='Review completed drills',exact=True).click();expect(page.locator('.daily-history-item')).to_have_count(1)
  page.get_by_role('button',name='Review lesson',exact=True).click();expect(page.locator('.daily-reader')).to_contain_text('Completed — review anytime')
  assert page.get_by_role('button',name='Take the quick check',exact=True).count()==0
  dashboard();page.set_viewport_size({'width':390,'height':844});assert page.locator('body').evaluate('n=>n.scrollWidth<=innerWidth')
  page.screenshot(path=str(root/'design/daily-drill-dashboard-mobile.png'),full_page=True)
  page.get_by_role('button',name='Continue your drill',exact=True).click();expect(page.locator('.daily-reader h2')).to_have_text(rows[1]['title'])
  assert page.locator('body').evaluate('n=>n.scrollWidth<=innerWidth')
  page.screenshot(path=str(root/'design/daily-drill-lesson-mobile.png'),full_page=True)
  dashboard()
  # Complete remaining pilot via real SQL/RPCs, then refresh the actual dashboard.
  for m in rows[1:]:
   a=sql(f"select id from public.daily_assignments where module_id='{m['id']}' and membership_id='20000000-0000-0000-0000-000000000004'")
   query_as(employee,f"select public.get_daily_module('{a}')");answer=key(m['id']);body=json.dumps([{'question_id':answer['id'],'option':answer['option']}])
   query_as(employee,f"select public.submit_daily_check('{a}','{body}',gen_random_uuid())")
  page.reload();expect(page.locator('.daily-dashboard')).to_contain_text('You’re caught up.')
  expect(page.locator('.daily-dashboard')).to_contain_text('10 completed · 10 available')
  assert page.get_by_role('button',name='Start your drill',exact=True).count()==0
  assert sql('select count(*) from public.training_trophies')=='0'
  signout();login('manager.a@example.test');expect(page.locator('table').first).to_contain_text('Daily Drill points');expect(page.locator('.daily-dashboard')).to_contain_text('0 completed · 10 available')
  page.get_by_role('button',name='Start your drill',exact=True).click();expect(page.locator('.daily-reader h2')).to_have_text(rows[0]['title'])
  signout();assert page.locator('.daily-reader,.daily-dashboard').count()==0
  assert not errors,errors
  browser.close()
 print('Passed The Daily Drill browser + SQL/RLS: dashboard placement, safe text/tables/sources, required answers, wrong feedback/review/reload, saved-success lost-response replay, next module, completed review, mobile, caught-up state, manager personal progress, account switching and no full-course awards.')
finally:
 subprocess.run(['docker','rm','-f',name],capture_output=True)
 subprocess.run(['node','scripts/build-accounts.mjs'],cwd=root,check=True)
