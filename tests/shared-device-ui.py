"""Shared-device browser safeguards with mocked Auth; no hosted writes or emails."""
from pathlib import Path
from urllib.parse import urlparse
import base64,json,os,subprocess,time
from playwright.sync_api import sync_playwright,expect,Error
root=Path(__file__).resolve().parent.parent
subprocess.run(['node','scripts/build-accounts.mjs'],cwd=root,check=True,env={**os.environ,'SUPABASE_PUBLISHABLE_KEY':'sb_publishable_local_test_only'})
html=(root/'accounts/index.html').read_text()
origin='https://shared.example'
store='10000000-0000-0000-0000-000000000001'
key='sb-flhdeftduysnjvqnhhee-auth-token'
people={email:{'id':f'00000000-0000-0000-0000-{i:012}','email':email,'aud':'authenticated','role':'authenticated','app_metadata':{},'user_metadata':{}} for i,email in [(1,'one@example.test'),(2,'two@example.test')]}
encode=lambda value:base64.urlsafe_b64encode(json.dumps(value).encode()).decode().rstrip('=')
def token(person):return encode({'alg':'HS256','typ':'JWT'})+'.'+encode({'sub':person['id'],'role':'authenticated','exp':int(time.time())+86400})+'.local-test'
held=[];hold_next=False;fail_logout=False;deny_refresh=False;removed_member=False

def handle(route):
 global hold_next
 url=route.request.url;path=urlparse(url).path
 if url.startswith(origin+'/'):
  if path in ('/accounts/','/accounts/index.html'):return route.fulfill(content_type='text/html',body=html)
  if path.startswith('/accounts/icons/') or path=='/accounts/manifest.webmanifest':
   mime='application/manifest+json' if path.endswith('webmanifest') else 'image/svg+xml' if path.endswith('.svg') else 'image/png'
   return route.fulfill(content_type=mime,body=(root/path.lstrip('/')).read_bytes())
  raise AssertionError('Unexpected local path')
 assert url.startswith('https://flhdeftduysnjvqnhhee.supabase.co/'),url
 uid=None
 bearer=route.request.headers.get('authorization','').removeprefix('Bearer ')
 if bearer.count('.')==2:uid=json.loads(base64.urlsafe_b64decode(bearer.split('.')[1]+'==='))['sub']
 person=next((p for p in people.values() if p['id']==uid),None)
 number=1 if uid==people['one@example.test']['id'] else 2
 name='Device User One' if number==1 else 'Device User Two'
 member=f'20000000-0000-0000-0000-{number:012}'
 if path=='/auth/v1/token':
  body=route.request.post_data_json
  if 'refresh_token' in body:
   if deny_refresh:return route.fulfill(status=400,content_type='application/json',body=json.dumps({'code':'refresh_token_not_found','msg':'Invalid refresh token'}))
   person=next(p for p in people.values() if body['refresh_token']=='test-refresh-'+p['id'])
  else:person=people[body['email']]
  result={'access_token':token(person),'refresh_token':'test-refresh-'+person['id'],'expires_in':86400,'token_type':'bearer','user':person}
 elif path=='/auth/v1/user':result=person
 elif path=='/auth/v1/logout':
  if fail_logout:return route.abort()
  result={}
 elif path=='/rest/v1/profiles':result=[{'user_id':uid,'full_name':name,'team_corner_nickname':None,'avatar_path':None}]
 elif path=='/rest/v1/organization_memberships':result=[{'id':member,'organization_id':store,'user_id':uid,'email':person['email'],'role':'employee','status':'inactive' if removed_member else 'active'}]
 elif path=='/rest/v1/platform_admins':result=[]
 elif path=='/rest/v1/organizations':result=[{'id':store,'name':'Shared Hardware'}]
 elif path=='/rest/v1/rpc/record_employee_first_login':result={'first_login':False}
 elif path in ('/functions/v1/employee-login','/functions/v1/team-support-email'):result={'delivery_status':'processed'}
 elif path=='/rest/v1/rpc/get_my_company_accounts':result=[]
 elif path=='/rest/v1/rpc/get_my_store_signup':result=None
 elif path=='/rest/v1/rpc/get_daily_workspace':result=None
 elif path=='/rest/v1/rpc/get_my_web_push_count':result=0
 elif path=='/rest/v1/rpc/get_web_push_status':result=False
 elif path=='/rest/v1/rpc/remove_web_push':result=None
 elif path=='/rest/v1/rpc/get_my_training_notifications':result={'items':[],'unread_count':0}
 elif path=='/rest/v1/rpc/get_team_corner':result={'can_read':True,'can_post':True,'is_manager':False,'pinned':[],'posts':[],'has_more':False}
 elif path=='/rest/v1/rpc/get_training_workspace':
  result={'store':{'id':store,'name':'Shared Hardware','time_zone':'America/New_York'},'my_membership':member,'can_manage':False,'is_admin':False,'members':[{'id':member,'name':name,'role':'employee','status':'active','departments':[],'lifetime_points':0}],'courses':[],'assignments':[],'departments':[],'competitions':[],'lifetime_standings':[],'totals':{'lifetime_points':0,'trophies':0,'completed_courses':0}}
  if hold_next:hold_next=False;held.append((route,result));return
 else:raise AssertionError('Unexpected API path '+path)
 route.fulfill(content_type='application/json',body=json.dumps(result))

def login(page,email='one@example.test'):
 page.locator('#auth-form input[name=email]').fill(email)
 page.locator('#auth-form input[name=password]').fill('Local test password')
 page.locator('#auth-form button[type=submit]').click()
 expect(page.locator('.page-heading h1')).to_be_visible()
 expect(page.locator('header .account-identity')).to_contain_text('Device User One' if email.startswith('one') else 'Device User Two')
def navigate(page,name):
 page.get_by_role('button',name='Open menu').click()
 page.locator('.training-drawer').get_by_role('button',name=name,exact=True).click()
def signed_out(page):
 expect(page.get_by_role('heading',name='Welcome to colTRAIN')).to_be_visible()
 expect(page.locator('#auth-form input[name=email]')).to_have_value('')
 expect(page.locator('#auth-form input[name=password]')).to_have_value('')
 assert page.evaluate('(key)=>sessionStorage.getItem(key)',key) is None
 expect(page.locator('header')).not_to_contain_text('Device User')
 expect(page.locator('.training-menu-toggle')).to_have_count(0)
 expect(page.locator('.training-drawer')).to_have_count(0)

def fresh(browser,clock=True):
 context=browser.new_context(service_workers='block');context.route('**/*',handle)
 page=context.new_page()
 if clock:page.clock.install()
 page.goto(origin+'/accounts/')
 expect(page.get_by_role('heading',name='Welcome to colTRAIN')).to_be_visible()
 return context,page
try:
 with sync_playwright() as p:
  browser=p.chromium.launch(executable_path='/usr/bin/chromium',args=['--no-sandbox'])
  context,page=fresh(browser)
  expect(page.locator('input[name=shared-device]')).to_be_checked()
  login(page)
  navigate(page,'Team Corner')
  page.locator('#training-team-post-form textarea').fill('Unsent private draft')
  page.clock.fast_forward(14*60*1000)
  expect(page.get_by_role('heading',name='Still learning?')).to_be_visible()
  page.keyboard.press('Escape')
  expect(page.locator('.shared-device-dialog')).to_be_visible()
  page.get_by_role('button',name='Stay signed in',exact=True).click()
  expect(page.locator('.shared-device-dialog')).not_to_be_visible()
  expect(page.locator('#training-team-post-form textarea')).to_have_value('Unsent private draft')
  page.clock.fast_forward(15*60*1000)
  signed_out(page)
  expect(page.locator('#account-message')).to_contain_text('15 minutes')
  login(page,'two@example.test')
  navigate(page,'Team Corner')
  expect(page.locator('#training-team-post-form textarea')).to_have_value('')
  assert 'Unsent private draft' not in page.content()
  context.close()

  context,page=fresh(browser)
  login(page)
  page.clock.fast_forward(13*60*1000)
  page.reload()
  expect(page.locator('.page-heading h1')).to_be_visible()
  page.clock.fast_forward(60*1000)
  expect(page.get_by_role('heading',name='Still learning?')).to_be_visible()
  page.get_by_role('button',name='Sign out now',exact=True).click()
  signed_out(page);context.close()

  context,page=fresh(browser)
  login(page)
  # OS sleep can advance wall time without running any JavaScript timers.
  page.clock.set_system_time(int(time.time()*1000)+16*60*1000)
  page.evaluate("document.dispatchEvent(new Event('visibilitychange'))")
  signed_out(page);context.close()

  context,page=fresh(browser)
  page.locator('input[name=shared-device]').uncheck()
  login(page)
  page.clock.fast_forward(31*60*1000)
  expect(page.locator('.page-heading h1')).to_be_visible()
  expect(page.locator('.shared-device-dialog')).not_to_be_visible()
  navigate(page,'Account & team settings')
  page.locator('#device-form input[name=shared-device]').check()
  page.get_by_role('button',name='Save device setting',exact=True).click()
  expect(page.locator('#account-message')).to_contain_text('protection is on')
  page.clock.fast_forward(15*60*1000)
  signed_out(page);context.close()

  context,page=fresh(browser,False)
  login(page)
  other=context.new_page();other.goto(origin+'/accounts/');login(other,'two@example.test')
  # Foreign Auth broadcasts must not change this tab's displayed/account identity.
  expect(page.locator('header .account-identity')).to_contain_text('Device User One')
  fail_logout=True
  navigate(page,'Sign out and switch accounts')
  signed_out(page);signed_out(other)
  fail_logout=False;context.close()

  context,page=fresh(browser)
  login(page)
  hold_next=True
  navigate(page,'My training')
  page.wait_for_timeout(100)
  assert held
  page.clock.fast_forward(15*60*1000)
  signed_out(page)
  for route,result in held:
   try:route.fulfill(content_type='application/json',body=json.dumps(result))
   except Error:pass
  held.clear()
  login(page,'two@example.test')
  expect(page.locator('header .account-identity')).not_to_contain_text('Device User One')
  context.close()

  # Personal-device consent survives a complete context restart, without sessionStorage.
  context,page=fresh(browser,False)
  page.locator('input[name=remember-device]').check()
  expect(page.locator('input[name=shared-device]')).not_to_be_checked()
  login(page)
  assert page.evaluate('(key)=>localStorage.getItem(key)!==null',key)
  remembered=context.storage_state();context.close()
  def reopen(state):
   c=browser.new_context(service_workers='block',storage_state=state);c.route('**/*',handle);p=c.new_page();p.goto(origin+'/accounts/');return c,p
  context,page=reopen(remembered)
  expect(page.locator('header .account-identity')).to_contain_text('Device User One')
  expect(page.locator('#auth-form')).to_have_count(0)
  navigate(page,'Account & team settings')
  expect(page.locator('#device-form input[name=remember-device]')).to_be_checked()
  page.locator('#device-form input[name=remember-device]').uncheck()
  page.get_by_role('button',name='Save device setting',exact=True).click()
  expect(page.locator('#account-message')).to_contain_text('Saved login is off')
  assert page.evaluate('(key)=>localStorage.getItem(key)',key) is None
  assert page.evaluate('(key)=>sessionStorage.getItem(key)!==null',key)
  session_only=context.storage_state();context.close()
  context,page=reopen(session_only);signed_out(page);context.close()

  # Existing personal sessions can opt in from settings, then return to shared mode.
  context,page=fresh(browser,False);page.locator('input[name=shared-device]').uncheck();login(page)
  navigate(page,'Account & team settings');page.locator('#device-form input[name=remember-device]').check()
  page.get_by_role('button',name='Save device setting',exact=True).click()
  expect(page.locator('#account-message')).to_contain_text('will keep you signed in')
  assert page.evaluate('(key)=>localStorage.getItem(key)!==null',key)
  page.locator('#device-form input[name=shared-device]').check()
  expect(page.locator('#device-form input[name=remember-device]')).not_to_be_checked()
  page.get_by_role('button',name='Save device setting',exact=True).click()
  expect(page.locator('#account-message')).to_contain_text('protection is on')
  assert page.evaluate('(key)=>localStorage.getItem(key)',key) is None
  context.close()

  # Explicit sign-out erases remembered credentials and doesn't restore them on restart.
  context,page=reopen(remembered);expect(page.locator('.page-heading h1')).to_be_visible()
  navigate(page,'Sign out and switch accounts');signed_out(page)
  assert page.evaluate('(key)=>localStorage.getItem(key)',key) is None
  assert page.evaluate("localStorage.getItem('coltrain-remember-device')") is None
  signedout_state=context.storage_state();context.close()
  context,page=reopen(signedout_state);signed_out(page);login(page,'two@example.test')
  assert page.evaluate('(key)=>localStorage.getItem(key)',key) is None
  context.close()

  # Server-rejected refresh clears persistence instead of restoring an expired login.
  import copy
  expired=copy.deepcopy(remembered)
  for record in expired['origins'][0]['localStorage']:
   if record['name']==key:
    record_value=json.loads(record['value']);record_value['expires_at']=int(time.time())-100;record['value']=json.dumps(record_value)
  context,page=reopen(expired);expect(page.locator('header .account-identity')).to_contain_text('Device User One')
  assert page.evaluate('(key)=>JSON.parse(localStorage.getItem(key)).expires_at',key)>int(time.time())
  context.close()
  deny_refresh=True;context,page=reopen(expired);signed_out(page)
  assert page.evaluate('(key)=>localStorage.getItem(key)',key) is None
  context.close();deny_refresh=False

  # Remembering Auth never restores removed store membership or a training dashboard.
  removed_member=True;context,page=reopen(remembered)
  expect(page.get_by_text('No active store membership.',exact=False)).to_be_visible()
  expect(page.locator('.training-menu-toggle')).to_have_count(0)
  context.close();removed_member=False
  browser.close()
 print('Passed personal restart/opt-in/settings/sign-out/revoked-refresh/removed-access checks and shared-device warning/stay/expiry, clearing drafts and credentials, reload and sleep checks, personal-device choice/settings, offline revocation failure, cross-tab sign-out/identity isolation, and pending-response account switching.')
finally:
 subprocess.run(['node','scripts/build-accounts.mjs'],cwd=root,check=True)
