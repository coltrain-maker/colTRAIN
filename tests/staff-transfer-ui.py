"""Returning accounts accept an email-bound invitation using their existing login."""
from pathlib import Path
import base64,json,os,subprocess,time
from urllib.parse import urlparse
from playwright.sync_api import sync_playwright,expect
expect.set_options(timeout=10000)
root=Path(__file__).resolve().parent.parent
subprocess.run(['node','scripts/build-accounts.mjs'],cwd=root,env={**os.environ,'SUPABASE_PUBLISHABLE_KEY':'sb_publishable_local_test_only'},check=True)
html=(root/'accounts/index.html').read_text()
uid='00000000-0000-0000-0000-000000000002';store='10000000-0000-0000-0000-000000000002';invitation='40000000-0000-0000-0000-000000000002';member='20000000-0000-0000-0000-000000000002'
person={'id':uid,'email':'returning@example.test','aud':'authenticated','role':'authenticated','email_confirmed_at':'2026-01-01T00:00:00Z','app_metadata':{'provider':'email'},'user_metadata':{}}
enc=lambda v:base64.urlsafe_b64encode(json.dumps(v).encode()).decode().rstrip('=')
token=enc({'alg':'HS256','typ':'JWT'})+'.'+enc({'sub':uid,'role':'authenticated','exp':int(time.time())+3600})+'.local-test'
joined=False;blocked=False;wrong=False;calls=[]
def handler(route):
 global joined
 url=route.request.url;path=urlparse(url).path;method=route.request.method
 if url.startswith('https://transfer.example/'):
  if path in ['/accounts/','/accounts/index.html']:return route.fulfill(content_type='text/html',body=html)
  return route.fulfill(body=(root/path.lstrip('/')).read_bytes())
 assert url.startswith('https://flhdeftduysnjvqnhhee.supabase.co/'),url
 args=route.request.post_data_json if method=='POST' else {};calls.append((method,path,args))
 if path=='/auth/v1/token':
  assert args['password']=='Existing account password';value={'access_token':token,'refresh_token':'local-refresh','expires_in':3600,'token_type':'bearer','user':person}
 elif path=='/auth/v1/user':assert method=='GET';value=person
 elif path=='/auth/v1/logout':value={}
 elif path=='/rest/v1/profiles':value=[{'user_id':uid,'full_name':'Returning Person','avatar_path':None,'optional_email_notifications':False}]
 elif path=='/rest/v1/platform_admins':value=[]
 elif path=='/rest/v1/organizations':value=[{'id':store,'name':'New Hardware','time_zone':'America/New_York'}] if joined else []
 elif path=='/rest/v1/organization_memberships':value=[{'id':member,'organization_id':store,'user_id':uid,'email':person['email'],'role':'manager','status':'active'}] if joined else []
 elif path=='/rest/v1/rpc/get_my_company_accounts':value=[]
 elif path=='/rest/v1/rpc/get_my_store_signup':value=None
 elif path=='/rest/v1/rpc/get_my_store_invitation':
  assert args=={'invitation':invitation}
  if wrong:return route.fulfill(status=400,content_type='application/json',body=json.dumps({'message':'does not match','code':'P0001'}))
  value={'store_name':'New Hardware','role':'manager','accepted':False,'can_join':not blocked}
 elif path=='/rest/v1/rpc/accept_email_invitation':assert not blocked and not wrong;joined=True;value=member
 elif path=='/rest/v1/rpc/record_employee_first_login':value={'first_login':False}
 elif path in ['/functions/v1/employee-login','/functions/v1/team-support-email']:value={}
 elif path=='/rest/v1/rpc/get_daily_workspace':value=None
 elif path=='/rest/v1/rpc/get_my_web_push_count':value=0
 elif path=='/rest/v1/rpc/get_my_training_notifications':value={'items':[],'unread_count':0}
 elif path=='/rest/v1/rpc/get_training_workspace':value={'store':{'id':store,'name':'New Hardware','time_zone':'America/New_York'},'my_membership':member,'can_manage':True,'is_admin':False,'members':[{'id':member,'name':'Returning Person','role':'manager','status':'active','departments':[]}],'courses':[],'assignments':[],'departments':[],'competitions':[],'lifetime_standings':[],'totals':{'lifetime_points':15,'course_points':10,'daily_points':5,'trophies':1,'completed_courses':1},'team_learning_seconds':0}
 elif path in ['/rest/v1/seats','/rest/v1/invitations']:value=[]
 elif path=='/rest/v1/rpc/get_my_training_history':value={'points':{'course_points':10,'daily_points':5,'lifetime_points':15},'trophies':1,'courses':[{'title':'Earlier standard course <safe>','version':1,'standard':True,'completed_at':'2026-01-01T00:00:00Z','started_at':'2026-01-01T00:00:00Z','lessons_completed':1,'attempts_used':1}],'daily':[{'title':'Earlier Drill','code':'CD-0001','completed_at':'2026-01-01T00:00:00Z'}]}
 else:raise AssertionError(path)
 route.fulfill(content_type='application/json',body=json.dumps(value))
def login(browser,invited=True):
 context=browser.new_context(service_workers='block',viewport={'width':390,'height':844});page=context.new_page();page.route('**/*',handler)
 page.goto('https://transfer.example/accounts/'+('?invitation_id='+invitation if invited else ''))
 if invited:expect(page.locator('#accounts-app')).to_contain_text('existing colTRAIN email and password')
 page.locator('#auth-form input[name=email]').fill(person['email']);page.locator('#auth-form input[name=password]').fill('Existing account password');page.locator('#auth-form button[type=submit]').click()
 return context,page
try:
 with sync_playwright() as p:
  browser=p.chromium.launch(executable_path='/usr/bin/chromium',args=['--no-sandbox'])
  context,page=login(browser)
  expect(page.get_by_role('heading',name='Join New Hardware')).to_be_visible()
  expect(page.locator('#accounts-app')).to_contain_text('store manager')
  page.get_by_role('button',name='Accept invitation and join store',exact=True).click()
  expect(page.get_by_role('heading',name='Your team, learning together.')).to_be_visible()
  assert '?' not in page.url
  assert not any(method=='PUT' and path=='/auth/v1/user' for method,path,args in calls)
  page.get_by_role('button',name='Open menu').click();page.get_by_role('button',name='Account & team settings',exact=True).click()
  page.get_by_role('button',name='View my training history',exact=True).click()
  expect(page.locator('#personal-training-history')).to_contain_text('Earlier standard course <safe>')
  expect(page.locator('#personal-training-history')).to_contain_text('Lifetime points: 15')
  assert page.locator('#personal-training-history script').count()==0
  assert page.evaluate('document.documentElement.scrollWidth<=innerWidth')
  context.close();joined=False
  context,page=login(browser,False)
  expect(page.locator('#accounts-app')).to_contain_text('No active store membership')
  page.get_by_role('button',name='View my training history',exact=True).click()
  expect(page.locator('#personal-training-history')).to_contain_text('Earlier standard course <safe>')
  context.close();blocked=True
  context,page=login(browser);expect(page.locator('#accounts-app')).to_contain_text('current store must remove your staff access')
  expect(page.get_by_role('button',name='Accept invitation and join store',exact=True)).to_have_count(0)
  context.close();blocked=False;wrong=True
  context,page=login(browser);expect(page.locator('#accounts-app')).to_contain_text('does not match your confirmed email')
  expect(page.locator('#accounts-app')).not_to_contain_text('New Hardware')
  expect(page.get_by_role('button',name='Accept invitation and join store',exact=True)).to_have_count(0)
  page.get_by_role('button',name='Sign out and switch accounts',exact=True).click()
  expect(page.get_by_role('heading',name='Welcome to colTRAIN')).to_be_visible()
  assert 'invitation_id='+invitation in page.url
  wrong=False
  page.locator('#auth-form input[name=email]').fill(person['email']);page.locator('#auth-form input[name=password]').fill('Existing account password');page.locator('#auth-form button[type=submit]').click()
  expect(page.get_by_role('heading',name='Join New Hardware')).to_be_visible()
  context.close();browser.close()
 print('Passed returning-account invitation, existing password, explicit acceptance, correct manager store, private transcript, active-store conflict, wrong account and mobile checks.')
finally:
 subprocess.run(['node','scripts/build-accounts.mjs'],cwd=root,check=True)
