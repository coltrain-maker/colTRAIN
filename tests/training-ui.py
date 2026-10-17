"""Exercise the browser against real local SQL/RLS; Auth HTTP responses are mocked.
No hosted database access, real credentials, or outbound emails are used.
"""
from pathlib import Path
import base64, json, os, re, subprocess, time, uuid
from urllib.parse import urlparse, parse_qs
from playwright.sync_api import sync_playwright, expect
root=Path(__file__).resolve().parent.parent
name='coltrain-training-ui-'+uuid.uuid4().hex[:8]
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
def handle(route):
 url=route.request.url
 if url=='https://training.example/accounts/':return route.fulfill(content_type='text/html',body=html)
 assert url.startswith('https://flhdeftduysnjvqnhhee.supabase.co/'),url
 parsed=urlparse(url);path=parsed.path;params=parse_qs(parsed.query)
 header=route.request.headers.get('authorization','').removeprefix('Bearer ')
 uid=json.loads(base64.urlsafe_b64decode(header.split('.')[1]+'==='))['sub'] if header.count('.')==2 else None
 try:
  if path=='/auth/v1/token':
   uid=people[route.request.post_data_json['email']];result={'access_token':token(uid),'refresh_token':'local-refresh','expires_in':3600,'token_type':'bearer','user':person(uid)}
  elif path=='/auth/v1/user':result=person(uid)
  elif path=='/auth/v1/logout':result={}
  elif path.startswith('/rest/v1/rpc/'):
   function=path.rsplit('/',1)[1];assert re.fullmatch('[a-z_]+',function)
   arguments=','.join('"'+key+'"=>'+arg(value) for key,value in route.request.post_data_json.items())
   result=json.loads(query_as(uid,'select to_jsonb(public."'+function+'"('+arguments+'))'))
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
 for _ in range(60):
  if subprocess.run(['docker','exec',name,'pg_isready','-h','127.0.0.1','-U','postgres'],capture_output=True).returncode==0:break
  time.sleep(.25)
 sql((root/'tests/supabase-auth-fixture.sql').read_text())
 for migration in sorted((root/'supabase/migrations').glob('*.sql')):sql(migration.read_text())
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
 with sync_playwright() as p:
  browser=p.chromium.launch(executable_path='/usr/bin/chromium',args=['--no-sandbox'])
  page=browser.new_page(viewport={'width':1280,'height':1000});errors=[]
  page.on('pageerror',lambda error:errors.append(str(error)))
  page.route('**/*',handle)
  page.goto('https://training.example/accounts/')
  def login(email):
   page.locator('#auth-form input[name=email]').fill(email)
   page.locator('#auth-form input[name=password]').fill('Local test password')
   page.locator('#auth-form button[type=submit]').click()
   page.get_by_role('button',name='Open training',exact=True).click()
  def navigate(label):
   page.get_by_role('button',name='Open menu').click()
   page.locator('.training-drawer').get_by_role('button',name=label,exact=True).click()
  def signout():
   page.get_by_role('button',name='Open menu').click()
   page.locator('.training-drawer').get_by_role('button',name='Sign out',exact=True).click()
   expect(page.get_by_role('heading',name='Welcome to colTRAIN')).to_be_visible()
  login('admin@example.test')
  navigate('Course library')
  page.get_by_role('button',name='Make available to store',exact=True).click()
  expect(page.locator('#account-message')).to_contain_text('Course is available')
  navigate('Departments')
  page.locator('#training-department-form input[name=name]').fill('Paint')
  page.locator('#training-department-form button').click()
  expect(page.locator('#account-message')).to_have_text('Department created.')
  page.locator('#training-department-member').select_option('20000000-0000-0000-0000-000000000004')
  page.locator('#training-department-options input').check()
  page.get_by_role('button',name='Save departments',exact=True).click()
  expect(page.locator('#account-message')).to_have_text('Departments saved.')
  navigate('Assign training')
  page.locator('#training-assign-form input[name=all]').check()
  page.locator('#training-assign-form input[name=department]').check()
  page.get_by_role('button',name='Assign course',exact=True).click()
  expect(page.locator('#account-message')).to_have_text('Training assigned to 1 person.')
  signout()
  login('employee.a@example.test')
  expect(page.get_by_role('heading',name='Your next chapter',exact=True)).to_be_visible()
  page.get_by_role('button',name='Start learning',exact=True).click()
  expect(page.locator('.lesson-item').nth(1)).to_be_disabled()
  page.get_by_role('button',name='Mark complete & continue',exact=True).click()
  expect(page.locator('.lesson-content h1')).to_have_text('Teach, don’t just sell')
  page.get_by_role('button',name='Mark complete & continue',exact=True).click()
  expect(page.locator('.lesson-content h1')).to_have_text('Build your product knowledge')
  page.get_by_role('button',name='Complete & take quiz',exact=True).click()
  def quiz(correct):
   answers={'A customer asks a product question you cannot answer. What is the best response?':2,'Good customer service requires knowing every answer immediately.':1,'Which action best demonstrates “teach, don’t just sell”?':0,'Which is the best way to build product knowledge?':2,'Asking a knowledgeable teammate for help can build customer trust.':0}
   for i in range(5):
    prompt=page.locator('.quiz-panel h2').inner_text()
    choice=answers[prompt] if correct and prompt!='Asking a knowledgeable teammate for help can build customer trust.' else (answers[prompt]+1)%page.locator('.option').count()
    page.locator('.option input').nth(choice).check()
    page.locator('#training-quiz-form button[type=submit], #training-quiz-form button:not([type])').click()
  quiz(False)
  expect(page.get_by_role('heading',name='A few things to revisit')).to_be_visible()
  expect(page.locator('.result-stats strong').first).to_have_text('0%')
  page.get_by_role('button',name='Review lessons',exact=True).click()
  page.get_by_role('button',name='Knowledge check',exact=True).click()
  quiz(True)
  expect(page.locator('.result-stats strong').first).to_have_text('80%')
  expect(page.locator('.result-stats strong').nth(1)).to_have_text('+40')
  page.screenshot(path=str(root/'design/training-results.png'),full_page=True)
  expect(page.locator('#account-message')).to_have_text('Course passed. Your points and trophy are saved.')
  page.set_viewport_size({'width':390,'height':844})
  page.get_by_role('button',name='Back to home',exact=True).click()
  expect(page.get_by_text('Lifetime points',exact=True)).to_be_visible()
  assert page.locator('body').evaluate('element=>element.scrollWidth<=innerWidth')
  page.screenshot(path=str(root/'design/training-employee-mobile.png'),full_page=True)
  page.reload()
  page.get_by_role('button',name='Open training',exact=True).click()
  expect(page.get_by_text('You’re all caught up.',exact=True)).to_be_visible()
  signout()
  login('manager.a@example.test')
  row=page.locator('.table tbody tr').filter(has_text='Pilot Employee')
  expect(row).to_contain_text('Completed')
  expect(row).to_contain_text('Latest score 80%')
  expect(row.locator('td').last).to_have_text('40')
  assert page.get_by_text('A few things to revisit',exact=True).count()==0
  assert page.locator('body').evaluate('element=>element.scrollWidth<=innerWidth')
  page.set_viewport_size({'width':1280,'height':1000})
  page.screenshot(path=str(root/'design/training-manager.png'),full_page=True)
  navigate('Account & team settings')
  expect(page.get_by_role('heading',name='Your store account')).to_be_visible()
  assert page.get_by_role('button',name='Open menu').count()==0
  assert not errors,errors
  assert sql('select count(*) from public.training_trophies')=='1'
  assert sql('select sum(points) from private.training_point_awards')=='40'
  assert sql('select count(*) from public.training_attempts')=='2'
  print('Passed browser + actual SQL/RLS: admin release, departments, assignment, sequential lessons, failed quiz explanations, passing retry, points/trophy, reload persistence, manager reporting, mobile, account navigation.')
  browser.close()
finally:
 subprocess.run(['docker','stop',name],capture_output=True)
 subprocess.run(['node','scripts/build-accounts.mjs'],cwd=root,check=True)
