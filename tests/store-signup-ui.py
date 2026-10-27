"""Bundled signup UI tests; fake Auth, checkout navigation and webhook result."""
from pathlib import Path
import base64,json,os,subprocess,time
from urllib.parse import urlparse,parse_qs
from playwright.sync_api import sync_playwright,expect
root=Path(__file__).resolve().parent.parent
subprocess.run(['node','scripts/build-accounts.mjs'],cwd=root,env={**os.environ,'SUPABASE_PUBLISHABLE_KEY':'sb_publishable_local_test_only'},check=True)
html=(root/'accounts/index.html').read_text()
uid='00000000-0000-0000-0000-000000000972';store='10000000-0000-0000-0000-000000000972';member='20000000-0000-0000-0000-000000000972';signup='40000000-0000-0000-0000-000000000972'
person={'id':uid,'email':'new-owner@example.test','aud':'authenticated','role':'authenticated','email_confirmed_at':'2026-10-26T00:00:00Z','app_metadata':{'provider':'email'},'user_metadata':{}}
enc=lambda v:base64.urlsafe_b64encode(json.dumps(v).encode()).decode().rstrip('=')
token=enc({'alg':'HS256','typ':'JWT'})+'.'+enc({'sub':uid,'role':'authenticated','exp':int(time.time())+3600})+'.local-test-signature'
manager_pending=None
delegated=False;accepted=False
enabled=True;state=None;manager=True;details={};calls=[];checkout_url='https://checkout.stripe.com/c/pay/cs_test_LocalSignup'
def handler(route):
 global state,details,manager,accepted,manager_pending
 url=route.request.url;path=urlparse(url).path
 if url.startswith('https://signup.example'):
  if path in ['/accounts/','/accounts/index.html']:return route.fulfill(content_type='text/html',body=html)
  if path.startswith('/accounts/icons/') or path=='/accounts/manifest.webmanifest':return route.fulfill(body=(root/path.lstrip('/')).read_bytes())
 if url.startswith('https://checkout.stripe.com/c/pay/cs_test_'):return route.fulfill(content_type='text/html',body='<h1>Stripe sandbox checkout</h1>')
 assert url.startswith('https://flhdeftduysnjvqnhhee.supabase.co/'),url
 args=route.request.post_data_json if route.request.method=='POST' else {}
 calls.append((path,args))
 if path=='/auth/v1/signup':
  assert parse_qs(urlparse(url).query)['redirect_to'][0]=='https://signup.example/accounts/?store_signup=start'
  result={'user':person,'session':None}
 elif path=='/auth/v1/token':result={'access_token':token,'refresh_token':'local-refresh','expires_in':3600,'token_type':'bearer','user':person}
 elif path=='/auth/v1/user':result=person
 elif path=='/rest/v1/rpc/accept_company_invitation':
  assert args=={'invitation':signup};accepted=True;result=None
 elif path=='/auth/v1/logout':result={}
 elif path=='/rest/v1/profiles':result=[{'user_id':uid,'full_name':'New Owner','avatar_path':None,'optional_email_notifications':False}]
 elif path=='/rest/v1/platform_admins':result=[]
 elif path=='/rest/v1/organization_memberships':result=[{'id':member,'organization_id':store,'user_id':uid,'email':person['email'],'role':'manager','status':'active'}] if state=='provisioned' and manager else []
 elif path=='/rest/v1/organizations':result=[{'id':store,'name':details['store_name'],'time_zone':'America/New_York'}] if state=='provisioned' and manager else []
 elif path in ['/rest/v1/seats','/rest/v1/invitations']:result=[]
 elif path=='/rest/v1/rpc/get_store_signup_availability':result={'enabled':enabled,'environment':'sandbox'}
 elif path=='/rest/v1/rpc/get_my_store_signup':result=None if state is None else {'id':signup,'state':state,'details':details,'store_id':store if state=='provisioned' else None}
 elif path=='/rest/v1/rpc/prepare_store_signup':
  details=args['details'];assert details['terms_accepted'] is True and details['purchase_authority'] is True
  assert details['buying_group']=='House Hasson\nOrgil\nOther: Local wholesaler';assert 'buying_groups' not in details;assert 'buying_group_other' not in details
  assert details['plan_code']=='store_25';assert 'price_id' not in details
  manager=details['become_manager'];state='prepared';result=signup
 elif path=='/functions/v1/stripe-checkout':assert args=={'signup_id':signup};state='checkout';result={'url':checkout_url}
 elif path=='/rest/v1/rpc/record_employee_first_login':result={'first_login':False}
 elif path in ['/functions/v1/employee-login','/functions/v1/team-support-email']:result={}
 elif path=='/rest/v1/rpc/get_daily_workspace':result=None
 elif path=='/rest/v1/rpc/get_my_web_push_count':result=0
 elif path=='/rest/v1/rpc/get_my_training_notifications':result={'items':[],'unread_count':0}
 elif path=='/rest/v1/rpc/get_training_workspace':result={'store':{'id':store,'name':details['store_name'],'time_zone':'America/New_York'},'my_membership':member,'can_manage':True,'is_admin':False,'members':[{'id':member,'name':'New Owner','role':'manager','status':'active','departments':[]}],'courses':[],'assignments':[],'departments':[],'competitions':[],'lifetime_standings':[],'totals':{'lifetime_points':0,'trophies':0,'completed_courses':0},'team_learning_seconds':0}
 elif path=='/rest/v1/rpc/get_my_company_accounts':result=[] if state!='provisioned' else [{'company_id':store,'name':details['company_name'],'is_owner':not delegated,'can_administer':not delegated,'stores':[{'store_id':store,'name':details['store_name'],'can_bill':True,'can_oversee_training':True,'access_mode':'sandbox'}]}]
 elif path=='/rest/v1/rpc/get_company_access_settings':result={'company':{'id':store,'name':details['company_name'],'phone':details['phone'],'buying_group':details['buying_group'],'owner_user_id':uid},'manager_invitations':[manager_pending] if manager_pending else [],'permissions':[],'people':[{'user_id':uid,'name':'New Owner','email':person['email']}],'audit':[]}
 elif path=='/functions/v1/invite-company-admin':
  assert args=={'action':'create','company':store,'name':'Additional Admin','email':'admin@example.test','capability':'both','store':store}
  result={'message':'Administrator invitation requested.'}
 elif path=='/functions/v1/invite-employee':
  assert not manager and args['store']==store
  if args['action']=='create':
   assert args['role']=='manager' and args['email']=='manager@example.test'
   manager_pending={'id':signup,'invitee_name':args['name'],'email':args['email'],'organization_id':store,'store_name':details['store_name'],'email_status':'sent','expires_at':'2026-11-01T00:00:00Z'}
  else:assert args=={'action':'resend','store':store,'invitation':signup}
  result={'message':'Manager invitation requested.'}
 elif path=='/rest/v1/rpc/revoke_invitation':assert args=={'invitation':signup};manager_pending=None;result=None
 else:raise AssertionError('Unexpected endpoint '+path)
 route.fulfill(content_type='application/json',body=json.dumps(result))
def signin(page):
 page.get_by_role('button',name='Sign in to continue',exact=True).click()
 page.locator('#auth-form input[name=email]').fill(person['email']);page.locator('#auth-form input[name=password]').fill('Local test password')
 page.locator('#auth-form button[type=submit]').click();expect(page.locator('#store-signup-form')).to_be_visible()
def fill(page,as_manager=True):
 for name,value in {'company_name':'Test Company','store_name':'Test Hardware <safe>','contact_name':'New Owner','phone':'555-0100','street':'100 Test St','city':'Test City','region':'NC','postal_code':'28501'}.items():page.locator(f'#store-signup-form input[name={name}]').fill(value)
 page.locator('#store-signup-form select[name=plan_code]').select_option('store_25')
 expect(page.locator('#store-signup-form [data-buying-group-other]')).to_be_hidden()
 page.locator('#store-signup-form input[name=buying_groups][value="House Hasson"]').check()
 page.locator('#store-signup-form input[name=buying_groups][value=Orgil]').check()
 page.locator('#store-signup-form input[name=buying_groups][value=Other]').check()
 expect(page.locator('#store-signup-form input[name=buying_group_other]')).to_have_attribute('required','')
 page.locator('#store-signup-form input[name=buying_group_other]').fill('Local wholesaler')
 page.locator('#store-signup-form input[name=become_manager]').set_checked(as_manager)
 page.locator('#store-signup-form input[name=purchase_authority]').check();page.locator('#store-signup-form input[name=terms_accepted]').check()
try:
 with sync_playwright() as p:
  browser=p.chromium.launch(executable_path='/usr/bin/chromium',args=['--no-sandbox'])
  context=browser.new_context(service_workers='block');page=context.new_page();page.route('**/*',handler)
  page.goto('https://signup.example/accounts/?store_signup=start')
  expect(page.get_by_text('$159.00/month',exact=True)).to_be_visible();expect(page.get_by_text('$219.00/month',exact=True)).to_be_visible()
  page.get_by_role('button',name='Create owner account',exact=True).click()
  page.locator('#auth-form input[name=name]').fill('New Owner');page.locator('#auth-form input[name=email]').fill(person['email']);page.locator('#auth-form input[name=password]').fill('Local test password')
  page.locator('#auth-form button[type=submit]').click();expect(page.locator('#account-message')).to_contain_text('Check your email')
  page.locator('#auth-form input[name=email]').fill(person['email']);page.locator('#auth-form input[name=password]').fill('Local test password');page.locator('#auth-form button[type=submit]').click()
  expect(page.locator('#store-signup-form')).to_be_visible();fill(page)
  page.locator('#store-signup-form button[type=submit]').click();expect(page.get_by_role('heading',name='Stripe sandbox checkout')).to_be_visible()
  assert page.url.startswith('https://checkout.stripe.com/');assert state=='checkout'
  page.goto('https://signup.example/accounts/')
  expect(page.get_by_role('button',name='Continue to secure checkout',exact=True)).to_be_visible()
  page.goto('https://signup.example/accounts/?store_signup=return')
  expect(page.get_by_role('heading',name='Your store is ready')).to_have_count(0)
  expect(page.get_by_role('button',name='Refresh store status',exact=True)).to_be_visible()
  state='provisioned';page.get_by_role('button',name='Refresh store status',exact=True).click();expect(page.get_by_role('heading',name='Your store is ready')).to_be_visible()
  assert page.locator('#store-signup img').count()==0
  page.get_by_role('button',name='Open your account',exact=True).click();expect(page.get_by_role('heading',name='Set up your store')).to_be_visible()
  expect(page.locator('#company-admin-invite-form')).to_be_visible()
  page.get_by_role('button',name='Continue to dashboard',exact=True).click();expect(page.get_by_role('heading',name='Your team, learning together.')).to_be_visible()
  context.close()
  # Billing-only owner: no training membership; a separate manager can be invited.
  state=None;context=browser.new_context(service_workers='block',viewport={'width':390,'height':844});page=context.new_page();page.route('**/*',handler)
  page.goto('https://signup.example/accounts/?store_signup=start');signin(page);fill(page,False)
  checkout_url='https://attacker.example/'
  page.locator('#store-signup-form button[type=submit]').click();expect(page.locator('#account-message')).to_have_text('Checkout returned an invalid sandbox link.')
  assert page.url.startswith('https://signup.example/')
  state='provisioned';page.get_by_role('button',name='Refresh store status',exact=True).click();page.get_by_role('button',name='Open your account',exact=True).click()
  expect(page.locator('.training-menu-toggle')).to_have_count(0)
  expect(page.locator('#company-settings')).to_contain_text('Sandbox test subscription')
  page.locator('#company-manager-form input[name=name]').fill('Separate Manager');page.locator('#company-manager-form input[name=email]').fill('manager@example.test');page.locator('#company-manager-form button[type=submit]').click()
  expect(page.locator('#account-message')).to_have_text('Manager invitation requested.')
  page.get_by_role('button',name='Resend manager invitation',exact=True).click()
  expect(page.locator('#company-settings')).to_contain_text('Separate Manager')
  page.get_by_role('button',name='Cancel manager invitation',exact=True).click()
  expect(page.locator('#account-message')).to_have_text('Manager invitation canceled.')
  expect(page.get_by_role('button',name='Resend manager invitation',exact=True)).to_have_count(0)
  expect(page.get_by_role('heading',name='Join your store',exact=True)).to_have_count(0)
  page.locator('#company-admin-invite-form input[name=name]').fill('Additional Admin');page.locator('#company-admin-invite-form input[name=email]').fill('admin@example.test');page.locator('#company-admin-invite-form select[name=capability]').select_option('both')
  page.locator('#company-admin-invite-form button[type=submit]').click();expect(page.locator('#account-message')).to_have_text('Administrator invitation requested.')
  # Ordinary sign-in for an owner with no training seat opens company setup, never Join your store.
  page.goto('https://signup.example/accounts/')
  expect(page.get_by_role('heading',name='Set up your store')).to_be_visible()
  expect(page.get_by_role('heading',name='Join your store',exact=True)).to_have_count(0)
  assert page.evaluate('document.documentElement.scrollWidth<=innerWidth')
  context.close()
  # Administrator callback accepts an email-bound company invitation after saving a password.
  delegated=True;accepted=False;manager=False
  context=browser.new_context(service_workers='block');page=context.new_page();page.route('**/*',handler)
  page.goto('https://signup.example/accounts/?company_invitation_id='+signup+'#access_token='+token+'&refresh_token=local-refresh&type=invite&expires_in=3600&token_type=bearer')
  expect(page.get_by_role('heading',name='Create your password')).to_be_visible()
  page.locator('#password-form input[name=password]').fill('New administrator password')
  page.get_by_role('button',name='Save password and accept access',exact=True).click()
  expect(page.locator('#account-message')).to_have_text('Your password is saved and your company access is active.')
  assert accepted
  expect(page.get_by_role('heading',name='Join your store',exact=True)).to_have_count(0)
  expect(page.locator('#company-manager-form')).to_have_count(0)
  expect(page.locator('#company-admin-invite-form')).to_have_count(0)
  assert '?' not in page.url and '#' not in page.url
  context.close();browser.close()
 print('Passed sandbox packages, owner registration/confirmation redirect, authorized signup, safe checkout navigation, webhook-pending/ready states, manager dashboard, billing-only ownership, separate manager invitation, escaping and mobile checks.')
finally:subprocess.run(['node','scripts/build-accounts.mjs'],cwd=root,check=True)
