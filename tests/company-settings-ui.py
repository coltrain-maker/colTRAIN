"""Exercise the bundled account UI with mocked APIs; no real users/emails/payments."""
from pathlib import Path
import base64,copy,json,os,subprocess,time
from urllib.parse import urlparse
from playwright.sync_api import sync_playwright,expect

root=Path(__file__).resolve().parent.parent
subprocess.run(['node','scripts/build-accounts.mjs'],cwd=root,env={**os.environ,'SUPABASE_PUBLISHABLE_KEY':'sb_publishable_local_test_only'},check=True)
html=(root/'accounts/index.html').read_text()
user_id='00000000-0000-0000-0000-000000000901'
company='30000000-0000-0000-0000-000000000901'
store='10000000-0000-0000-0000-000000000901'
member='20000000-0000-0000-0000-000000000901'
person={'id':user_id,'email':'owner@example.test','aud':'authenticated','role':'authenticated','email_confirmed_at':'2026-10-23T00:00:00Z','app_metadata':{'provider':'email'},'user_metadata':{}}
enc=lambda v:base64.urlsafe_b64encode(json.dumps(v).encode()).decode().rstrip('=')
token=enc({'alg':'HS256','typ':'JWT'})+'.'+enc({'sub':user_id,'role':'authenticated','exp':int(time.time())+3600})+'.local-test-signature'
role='owner';calls=[];fail_save=False;held=[];hold_company=False;stripe_ok=True;stripe_failed=False;stripe_amount_conflict=False
settings={'company':{'id':company,'name':'Pilot Hardware','phone':'555-0100','buying_group':'Example group','owner_user_id':user_id},'people':[{'user_id':user_id,'name':'Owner','email':'owner@example.test'}],'permissions':[],'audit':[]}

def reply(route,value,status=200):route.fulfill(status=status,content_type='application/json',body=json.dumps(value))
def handler(route):
 global hold_company
 path=urlparse(route.request.url).path
 if route.request.url.startswith('https://company.example/'):
  if path in ['/accounts/','/accounts/index.html']:return route.fulfill(content_type='text/html',body=html)
  if path.startswith('/accounts/icons/') or path=='/accounts/manifest.webmanifest':return route.fulfill(body=(root/path.lstrip('/')).read_bytes())
  raise AssertionError(path)
 assert route.request.url.startswith('https://flhdeftduysnjvqnhhee.supabase.co/'),route.request.url
 args=route.request.post_data_json if route.request.method=='POST' else {}
 calls.append((path,args))
 training_member=role in ['owner','admin']
 if path=='/auth/v1/token':value={'access_token':token,'refresh_token':'test-refresh','expires_in':3600,'token_type':'bearer','user':person}
 elif path=='/auth/v1/user':value=person
 elif path=='/auth/v1/logout':value={}
 elif path=='/rest/v1/profiles':value=[{'user_id':user_id,'full_name':'Owner','avatar_path':None,'optional_email_notifications':False}]
 elif path=='/rest/v1/organization_memberships':value=[{'id':member,'organization_id':store,'user_id':user_id,'email':person['email'],'role':'manager','status':'active'}] if training_member else []
 elif path=='/rest/v1/platform_admins':value=[{'user_id':user_id}] if role=='admin' else []
 elif path=='/rest/v1/organizations':value=[{'id':store,'name':'Pilot Hardware','time_zone':'America/New_York'}] if training_member else []
 elif path in ['/rest/v1/seats','/rest/v1/invitations']:value=[]
 elif path=='/rest/v1/rpc/record_employee_first_login':value={'first_login':False}
 elif path in ['/functions/v1/employee-login','/functions/v1/team-support-email']:value={}
 elif path=='/rest/v1/rpc/get_daily_workspace':value=None
 elif path=='/rest/v1/rpc/get_my_web_push_count':value=0
 elif path=='/rest/v1/rpc/get_my_training_notifications':value={'items':[],'unread_count':0}
 elif path=='/rest/v1/rpc/get_training_workspace':value={'store':{'id':store,'name':'Pilot Hardware','time_zone':'America/New_York'},'my_membership':member,'can_manage':True,'is_admin':role=='admin','members':[{'id':member,'name':'Owner','role':'manager','status':'active','departments':[]}],'courses':[],'assignments':[],'departments':[],'competitions':[],'lifetime_standings':[],'totals':{'lifetime_points':0,'trophies':0,'completed_courses':0},'team_learning_seconds':0}
 elif path=='/rest/v1/rpc/get_my_store_signup':value=None
 elif path=='/rest/v1/rpc/get_my_company_accounts':
  value=[] if role=='ordinary' else [{'company_id':company,'name':settings['company']['name'],'is_owner':role=='owner','can_administer':role in ['owner','admin'],'stores':[{'store_id':store,'name':'Pilot Hardware','can_bill':role in ['owner','admin','billing'],'can_oversee_training':role in ['owner','admin','training'],'access_mode':'pilot' if role in ['owner','admin','billing'] else None}]}]
  if hold_company:hold_company=False;held.append((route,value));return
 elif path=='/functions/v1/stripe-sandbox':
  assert role=='admin' and args=={'action':'verify_configuration'}
  if stripe_failed:return reply(route,{'error':'Save a sandbox secret key beginning with sk_test_ as STRIPE_SANDBOX_SECRET_KEY.'},503)
  if stripe_amount_conflict:return reply(route,{'environment':'sandbox','all_verified':False,'error':'Stripe price check — 16–25 seats: expected $159.00/month; Stripe returned $179.00/month. Price ID: price_local_test.\nNo charges or subscriptions were created.'},409)
  config=json.loads((root/'supabase/billing/stripe-sandbox-prices.json').read_text())
  value={'environment':'sandbox','all_verified':stripe_ok,'plans':[{**plan,'verified':stripe_ok or plan['seat_limit']!=35,'issue':'' if stripe_ok or plan['seat_limit']!=35 else 'amount_mismatch'} for plan in config['plans']]}
 elif path=='/rest/v1/rpc/get_company_access_settings':
  assert role in ['owner','admin'];value=copy.deepcopy(settings)
 elif path=='/rest/v1/rpc/save_company_details':
  assert role=='owner'
  if fail_save:return reply(route,{'message':'Company owner access required','code':'P0001'},400)
  settings['company'].update(name=args['company_name'],phone=args['company_phone'],buying_group=args['affiliation']);value=None
 elif path=='/rest/v1/rpc/set_company_permission_by_email':
  assert role=='owner' and args['account_email']=='billing@example.test' and args['capability']=='billing' and args['store']==store
  settings['permissions']=[{'id':'permission-one','user_id':'billing-id','permission':'billing','organization_id':store}]
  settings['people'].append({'user_id':'billing-id','name':'Billing Person','email':'billing@example.test'});value=None
 elif path=='/rest/v1/rpc/set_company_permission':
  assert role=='owner' and args['person']=='billing-id' and args['enabled']==False and args['store']==store
  settings['permissions']=[];value=None
 elif path=='/rest/v1/rpc/get_company_training_overview':
  assert role in ['owner','admin','training'] and args=={'company':company,'store':store}
  value={'company_id':company,'stores':[{'store_id':store,'name':'Pilot Hardware','members':[{'name':'Employee One','role':'employee','completed_courses':2,'assigned_courses':4,'completed_drills':3,'points':{'course_points':20,'daily_points':15,'lifetime_points':35}}]}]}
 else:raise AssertionError('Unexpected endpoint '+path)
 reply(route,value)

def login(browser):
 context=browser.new_context(service_workers='block',viewport={'width':1200,'height':900})
 page=context.new_page();page.route('**/*',handler)
 page.goto('https://company.example/accounts/');page.locator('#auth-form input[name=email]').fill(person['email']);page.locator('#auth-form input[name=password]').fill('Test password only')
 page.locator('#auth-form button[type=submit]').click()
 if role in ['owner','admin']:
  expect(page.get_by_role('heading',name='Your team, learning together.')).to_be_visible()
  page.get_by_role('button',name='Open menu').click();page.get_by_role('button',name='Account & team settings',exact=True).click()
 if role in ['owner','admin']:expect(page.get_by_role('button',name='Open company settings',exact=True)).to_be_visible()
 else:expect(page.locator('#company-settings')).to_be_visible()
 return context,page

try:
 with sync_playwright() as p:
  browser=p.chromium.launch(executable_path='/usr/bin/chromium',args=['--no-sandbox'])
  context,page=login(browser)
  page.get_by_role('button',name='Open company settings',exact=True).click()
  expect(page.locator('#company-details-form')).to_be_visible()
  expect(page.get_by_role('button',name='Check Stripe sandbox connection',exact=True)).to_have_count(0)
  expect(page.locator('#company-settings')).to_contain_text('No-charge pilot')
  page.locator('#company-details-form input[name=company_name]').fill('Hardware <script>window.companyInjected=true</script>')
  page.locator('#company-details-form button[type=submit]').click()
  expect(page.locator('#account-message')).to_have_text('Company details saved.')
  assert page.evaluate('window.companyInjected') is None
  expect(page.locator('#company-details-form input[name=company_name]')).to_have_value(settings['company']['name'])
  # Opening and closing the menu must retain the refreshed company-settings view.
  page.get_by_role('button',name='Open menu').click();page.locator('.training-drawer').get_by_role('button',name='Close',exact=True).click()
  expect(page.locator('#company-details-form')).to_be_visible()
  fail_save=True;page.locator('#company-details-form button[type=submit]').click()
  expect(page.locator('#account-message')).to_have_text('Company owner access required');fail_save=False
  page.locator('#company-permission-form input[name=account_email]').fill('billing@example.test')
  page.locator('#company-permission-form select[name=store]').select_option(store)
  page.locator('#company-permission-form button[type=submit]').click()
  expect(page.locator('#account-message')).to_contain_text('Company permission granted')
  expect(page.locator('#company-settings')).to_contain_text('Billing Person')
  page.on('dialog',lambda d:d.accept());page.get_by_role('button',name='Remove access',exact=True).click()
  expect(page.locator('#account-message')).to_have_text('Company permission removed.')
  page.get_by_role('button',name='View training progress',exact=True).click()
  expect(page.locator('.company-progress')).to_contain_text('Employee One')
  expect(page.locator('.company-progress th')).to_contain_text(['Employee','Courses completed','Daily Drills completed','Course points','Daily Drill points','Lifetime points','Employee Oneemployee'])
  page.set_viewport_size({'width':390,'height':844})
  assert page.evaluate('document.documentElement.scrollWidth<=window.innerWidth')
  context.close()
  for role in ['billing','training','ordinary']:
   context,page=login(browser);before=len(calls)
   page.get_by_role('button',name='Refresh',exact=True).click()
   expect(page.locator('#company-settings')).to_contain_text('Your access is limited' if role!='ordinary' else 'does not have company ownership')
   expect(page.locator('#company-details-form')).to_have_count(0)
   expect(page.locator('#company-permission-form')).to_have_count(0)
   expect(page.get_by_role('button',name='Check Stripe sandbox connection',exact=True)).to_have_count(0)
   assert not any(path.endswith('get_company_access_settings') for path,args in calls[before:])
   if role=='training':
    page.get_by_role('button',name='View training progress',exact=True).click();expect(page.locator('.company-progress')).to_contain_text('Employee One')
   else:expect(page.get_by_role('button',name='View training progress',exact=True)).to_have_count(0)
   context.close()
  role='admin';context,page=login(browser)
  page.get_by_role('button',name='Open company settings',exact=True).click()
  check=page.get_by_role('button',name='Check Stripe sandbox connection',exact=True)
  expect(check).to_be_visible();check.click()
  expect(page.locator('#account-message')).to_have_text('Stripe sandbox packages verified. No charges were created.')
  expect(page.locator('#company-settings')).to_contain_text('26–35 seats · $219.00/month: Verified')
  stripe_ok=False;check.click()
  expect(page.locator('#account-message')).to_have_text('Some Stripe sandbox packages need attention.')
  expect(page.locator('#company-settings')).to_contain_text('Monthly amount does not match')
  stripe_failed=True;check.click()
  expect(page.locator('#account-message')).to_contain_text('Save a sandbox secret key')
  stripe_failed=False;stripe_amount_conflict=True;check.click()
  expect(page.locator('#account-message')).to_contain_text('expected $159.00/month; Stripe returned $179.00/month')
  expect(page.locator('#account-message')).to_contain_text('Price ID: price_local_test')
  stripe_amount_conflict=False;stripe_ok=True;context.close()
  # A delayed company response must never paint account details after sign-out.
  role='billing';context,page=login(browser);hold_company=True
  page.get_by_role('button',name='Refresh',exact=True).click()
  page.get_by_role('button',name='Sign out and switch accounts',exact=True).click()
  expect(page.get_by_role('heading',name='Welcome to colTRAIN')).to_be_visible()
  if held:
   route,value=held.pop()
   try:reply(route,value)
   except Exception:pass  # The document request may have been canceled by navigation.
  expect(page.locator('#company-settings')).to_have_count(0)
  context.close();browser.close()
 print('Passed owner save/error/grant/revoke, menu persistence, escaped content, mobile layout, billing/training-only permissions, ordinary-account empty state, and sign-out response isolation browser checks.')
finally:
 subprocess.run(['node','scripts/build-accounts.mjs'],cwd=root,check=True)
