"""Browser wiring tests with mocked Supabase responses; never sends real email."""
from pathlib import Path
import base64
import json
import os
import subprocess
import time
from urllib.parse import urlparse, parse_qs
from playwright.sync_api import sync_playwright, expect

root = Path(__file__).resolve().parent.parent
environment = {**os.environ, 'SUPABASE_PUBLISHABLE_KEY': 'sb_publishable_local_test_only'}
subprocess.run(['node', 'scripts/build-accounts.mjs'], cwd=root, env=environment, check=True)
html = (root / 'accounts/index.html').read_text()
uid = '00000000-0000-0000-0000-000000000002'
store = '10000000-0000-0000-0000-000000000001'
person = {'id': uid, 'email': 'manager@example.test', 'aud': 'authenticated', 'role': 'authenticated',
          'email_confirmed_at': '2026-01-01T00:00:00Z', 'app_metadata': {'provider': 'email'}, 'user_metadata': {}}
encode = lambda value: base64.urlsafe_b64encode(json.dumps(value).encode()).decode().rstrip('=')
token = encode({'alg': 'HS256', 'typ': 'JWT'}) + '.' + encode({'sub': uid, 'role': 'authenticated', 'exp': int(time.time()) + 3600}) + '.local-test-signature'
team = [
    {'id': '20000000-0000-0000-0000-000000000001', 'organization_id': store, 'user_id': uid, 'email': 'manager@example.test', 'role': 'manager', 'status': 'active'},
    {'id': '20000000-0000-0000-0000-000000000002', 'organization_id': store, 'user_id': '00000000-0000-0000-0000-000000000004', 'email': 'employee@example.test', 'role': 'employee', 'status': 'active'},
]
invites = []
calls = []
invitation_read_error = False
display_name = 'Store Manager'
team_nickname = None
def handle(route):
    global display_name, team_nickname
    url = route.request.url
    asset_path=urlparse(url).path
    if url.startswith('https://accounts.example/accounts/') and asset_path in ['/accounts/manifest.webmanifest','/accounts/icons/coltrain.svg','/accounts/icons/apple-touch-icon.png','/accounts/icons/icon-192.png','/accounts/icons/icon-512.png','/accounts/icons/icon-maskable-512.png']:
        mime='application/manifest+json' if asset_path.endswith('.webmanifest') else 'image/svg+xml' if asset_path.endswith('.svg') else 'image/png'
        return route.fulfill(content_type=mime,body=(root/asset_path.lstrip('/')).read_bytes())
    if url.startswith('https://accounts.example/accounts/index.html'):
        return route.fulfill(status=200, content_type='text/html', body=html)
    if not url.startswith('https://flhdeftduysnjvqnhhee.supabase.co/'):
        raise AssertionError('Unexpected network destination')
    path = url.split('.supabase.co', 1)[1].split('?')[0]
    calls.append((route.request.method, path))
    if path == '/auth/v1/token':
        result = {'access_token': token, 'refresh_token': 'local-test-refresh', 'token_type': 'bearer', 'expires_in': 3600, 'user': person}
    elif path == '/auth/v1/user': result = person
    elif path in ['/auth/v1/logout', '/auth/v1/recover']: result = {}
    elif path == '/rest/v1/profiles': result = [{'user_id': uid, 'full_name': display_name, 'team_corner_nickname': team_nickname, 'optional_email_notifications': False}]
    elif path == '/rest/v1/organization_memberships': result = team
    elif path == '/rest/v1/platform_admins': result = []
    elif path == '/rest/v1/organizations': result = [{'id': store, 'name': 'Pilot Hardware'}]
    elif path == '/rest/v1/seats': result = [{'id': 'seat1', 'organization_id': store}, {'id': 'seat2', 'organization_id': store}]
    elif path == '/rest/v1/invitations':
        columns = parse_qs(urlparse(url).query).get('select', ['*'])[0]
        if invitation_read_error and 'invitee_name' in columns:
            return route.fulfill(status=403, content_type='application/json', headers={'access-control-allow-origin': '*'}, body=json.dumps({'code': '42501', 'message': 'permission denied'}))
        result = invites if columns == '*' else [{key: row.get(key) for key in columns.split(',')} for row in invites]
    elif path == '/rest/v1/rpc/get_my_training_notifications': result = {'items': [], 'unread_count': 0}
    elif path == '/rest/v1/rpc/get_training_workspace':
        result = {'store': {'id':store,'name':'Pilot Hardware','time_zone':'America/New_York'},'my_membership':team[0]['id'],'can_manage':True,'is_admin':False,
                  'members':[{'id':m['id'],'name':'Store Manager' if m['user_id']==uid else 'Employee','email':m['email'],'role':m['role'],'status':m['status'],'departments':[],'lifetime_points':0} for m in team],
                  'courses':[],'assignments':[],'departments':[],'totals':{'lifetime_points':0,'trophies':0,'completed_courses':0},'question_alerts':[],'global_question_alerts':[],
                  'competitions':[],'lifetime_standings':[],'team_learning_seconds':0}
    elif path == '/rest/v1/rpc/save_my_account_preferences':
        display_name=route.request.post_data_json['display_name']
        team_nickname=route.request.post_data_json['team_nickname']
        result = None
    elif path == '/functions/v1/invite-employee':
        data = route.request.post_data_json
        assert data['store'] == store
        if data['action'] == 'create':
            assert data['name'] == 'New Employee'
            invites.append({'id': '40000000-0000-0000-0000-000000000001', 'organization_id': store, 'email': data['email'], 'invitee_name': data['name'], 'email_status': 'sent', 'role': 'employee', 'expires_at': '2099-01-01T00:00:00Z', 'accepted_at': None, 'revoked_at': None})
        else: assert data['action'] == 'resend'
        result = {'message': 'Invitation email requested.'}
    elif path == '/rest/v1/rpc/accept_email_invitation':
        assert route.request.post_data_json['invitation'] == '40000000-0000-0000-0000-000000000001'
        result = team[0]['id']
    elif path == '/rest/v1/rpc/create_invitation':
        data = route.request.post_data_json
        assert data['store'] == store and data['member_role'] == 'employee'
        invites.append({'id': '40000000-0000-0000-0000-000000000001', 'organization_id': store, 'email': data['employee_email'], 'role': 'employee', 'expires_at': '2099-01-01T00:00:00Z', 'accepted_at': None, 'revoked_at': None})
        result = [{'invitation_id': invites[-1]['id'], 'invitation_code': 'LOCAL_TEST_INVITATION_ONE', 'expires_at': invites[-1]['expires_at']}]
    elif path == '/rest/v1/rpc/reissue_invitation':
        result = [{'invitation_id': invites[-1]['id'], 'invitation_code': 'LOCAL_TEST_REPLACEMENT_CODE', 'expires_at': invites[-1]['expires_at']}]
    elif path == '/rest/v1/rpc/deactivate_member':
        assert route.request.post_data_json['member'] == team[1]['id']
        team[1]['status'] = 'inactive'
        result = None
    else: raise AssertionError('Unexpected Supabase endpoint: ' + path)
    route.fulfill(status=200, content_type='application/json', headers={'access-control-allow-origin': '*'}, body=json.dumps(result))

try:
    with sync_playwright() as p:
        browser = p.chromium.launch(executable_path='/usr/bin/chromium', args=['--no-sandbox'])
        page = browser.new_page(service_workers='block',viewport={'width': 1200, 'height': 1000})
        errors = []
        page.on('pageerror', lambda error: errors.append(str(error)))
        page.on('dialog', lambda dialog: dialog.accept())
        page.route('**/*', handle)
        page.goto('https://accounts.example/accounts/index.html', wait_until='networkidle')
        expect(page.get_by_role('heading', name='Welcome to colTRAIN')).to_be_visible()
        page.locator('#auth-form input[name=email]').fill('manager@example.test')
        page.locator('#auth-form input[name=password]').fill('short-pass')
        page.locator('#auth-form button[type=submit]').click()
        expect(page.get_by_role('heading', name='Your team, learning together.')).to_be_visible()
        expect(page.locator('header .account-identity')).to_contain_text('Pilot Hardware')
        expect(page.locator('header .account-identity')).to_contain_text('Signed in as Store Manager')
        assert page.get_by_role('button',name='Open training',exact=True).count()==0
        def navigate(label):
            page.get_by_role('button',name='Open menu').click()
            page.locator('.training-drawer').get_by_role('button',name=label,exact=True).click()
        navigate('Account & team settings')
        expect(page.get_by_role('heading',name='Your store account')).to_be_visible()
        expect(page.get_by_role('heading', name='Pilot Hardware', exact=True).first).to_be_visible()
        page.locator('#profile-form input[name=name]').fill('Renamed Manager')
        page.get_by_label('Team Corner nickname (optional)').fill('Paint Pro')
        page.locator('#profile-form button[type=submit]').click()
        expect(page.locator('#account-message')).to_have_text('Profile and email preference saved.')
        expect(page.locator('header .account-identity')).to_contain_text('Renamed Manager')
        expect(page.get_by_label('Team Corner nickname (optional)')).to_have_value('Paint Pro')
        assert team_nickname == 'Paint Pro'
        page.locator('#invite-form input[name=name]').fill('New Employee')
        page.locator('#invite-form input[name=email]').fill('new.employee@example.test')
        page.locator('#invite-form').get_by_role('button', name='Send invitation', exact=True).click()
        expect(page.locator('#account-message')).to_have_text('Invitation email requested.')
        expect(page.get_by_text('New Employee', exact=True)).to_be_visible()
        page.get_by_role('button', name='Resend invitation', exact=True).click()
        expect(page.locator('#account-message')).to_have_text('Invitation email requested.')
        page.get_by_role('button', name='Send reset link', exact=True).last.click()
        expect(page.locator('#account-message')).to_contain_text('Password reset requested')
        page.get_by_role('button', name='Remove access', exact=True).click()
        expect(page.get_by_text('employee · inactive', exact=True)).to_be_visible()
        page.set_viewport_size({'width': 390, 'height': 844})
        assert page.locator('body').evaluate('(el)=>el.scrollWidth<=innerWidth')
        expect(page.locator('header .account-identity')).to_be_visible()
        page.get_by_role('button',name='Open menu').click()
        page.locator('.training-drawer').get_by_role('button', name='Sign out', exact=True).click()
        expect(page.get_by_role('heading', name='Welcome to colTRAIN')).to_be_visible()
        page.get_by_role('button', name='Create account', exact=True).click()
        expect(page.get_by_role('heading', name='Create your account')).to_be_visible()
        assert page.locator('input[name=password]').get_attribute('minlength') == '12'
        assert not errors, errors
        assert ('POST', '/functions/v1/invite-employee') in calls
        print('Passed mocked account UI: direct dashboard login, shared settings navigation, visible mobile identity, profile name refresh, sign-in/out, invite/reissue, password reset, deactivate, registration screen, mobile layout.')
        # Chat previews allow JavaScript but may omit the allow-forms sandbox permission.
        sandbox_page = browser.new_page(service_workers='block')
        sandbox_page.route('**/*', handle)
        sandbox_page.on('pageerror', lambda error: errors.append(str(error)))
        sandbox_page.set_content('<iframe sandbox="allow-scripts" style="width:900px;height:900px"></iframe>')
        sandbox_page.locator('iframe').evaluate('(el, html) => el.srcdoc = html', html)
        frame = sandbox_page.frame_locator('iframe')
        frame.locator('input[name=email]').fill('manager@example.test')
        frame.locator('input[name=password]').fill('short-pass')
        frame.get_by_role('button', name='Sign in', exact=True).click()
        expect(frame.get_by_role('heading', name='Your team, learning together.')).to_be_visible()
        expect(frame.locator('#account-message')).to_have_text('Signed in.')
        assert not errors, errors
        print('Passed sign-in inside an opaque preview iframe without allow-forms.')
        callback_page = browser.new_page(service_workers='block')
        callback_page.route('**/*', handle)
        callback_page.on('pageerror', lambda error: errors.append(str(error)))
        callback_page.goto('https://accounts.example/accounts/index.html?invitation_id=40000000-0000-0000-0000-000000000001#access_token='+token+'&refresh_token=local-test-refresh&type=invite&expires_in=3600&token_type=bearer')
        expect(callback_page.get_by_role('heading', name='Create your password')).to_be_visible()
        callback_page.locator('input[name=password]').fill('New password for local testing')
        callback_page.get_by_role('button', name='Save password and join store').click()
        expect(callback_page.locator('#account-message')).to_have_text('Your password is saved and you have joined your store.')
        assert calls.index(('PUT','/auth/v1/user')) < calls.index(('POST','/rest/v1/rpc/accept_email_invitation'))
        assert '?' not in callback_page.url and '#' not in callback_page.url
        assert not errors, errors
        print('Passed invitation callback: choose password, join store, remove URL tokens.')
        invitation_read_error = True
        unavailable_page = browser.new_page(service_workers='block')
        unavailable_page.route('**/*', handle)
        unavailable_page.goto('https://accounts.example/accounts/index.html')
        unavailable_page.locator('input[name=email]').fill('manager@example.test')
        unavailable_page.locator('input[name=password]').fill('short-pass')
        unavailable_page.get_by_role('button', name='Sign in', exact=True).click()
        expect(unavailable_page.get_by_role('heading',name='Your team, learning together.')).to_be_visible()
        unavailable_page.get_by_role('button',name='Open menu').click()
        unavailable_page.locator('.training-drawer').get_by_role('button',name='Account & team settings',exact=True).click()
        expect(unavailable_page.locator('#account-message')).to_have_text('Invitation details could not be loaded. Please contact colTRAIN support.')
        assert unavailable_page.get_by_role('button', name='Replace code', exact=True).count() == 0
        assert unavailable_page.get_by_text('Manual invitation', exact=True).count() == 0
        print('Passed invitation-detail failure: never silently labels email invitations as manual codes.')
        browser.close()
    # A privileged key must never be embedded in the browser artifact.
    rejected = subprocess.run(['node', 'scripts/build-accounts.mjs'], cwd=root,
                              env={**os.environ, 'SUPABASE_PUBLISHABLE_KEY': 'sb_secret_local_test_rejected'},
                              capture_output=True, text=True)
    assert rejected.returncode != 0 and 'Only a Supabase publishable key' in rejected.stderr
    print('Passed privileged-key build rejection.')
finally:
    subprocess.run(['node', 'scripts/build-accounts.mjs'], cwd=root, check=True)
