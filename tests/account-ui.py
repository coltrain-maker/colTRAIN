"""Browser wiring tests with mocked Supabase responses; never sends real email."""
from pathlib import Path
import base64
import json
import os
import subprocess
import time
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
def handle(route):
    url = route.request.url
    if url == 'https://accounts.example/accounts/index.html':
        return route.fulfill(status=200, content_type='text/html', body=html)
    if not url.startswith('https://flhdeftduysnjvqnhhee.supabase.co/'):
        raise AssertionError('Unexpected network destination')
    path = url.split('.supabase.co', 1)[1].split('?')[0]
    calls.append((route.request.method, path))
    if path == '/auth/v1/token':
        result = {'access_token': token, 'refresh_token': 'local-test-refresh', 'token_type': 'bearer', 'expires_in': 3600, 'user': person}
    elif path == '/auth/v1/user': result = person
    elif path in ['/auth/v1/logout', '/auth/v1/recover']: result = {}
    elif path == '/rest/v1/profiles': result = [{'user_id': uid, 'full_name': 'Store Manager', 'optional_email_notifications': False}]
    elif path == '/rest/v1/organization_memberships': result = team
    elif path == '/rest/v1/platform_admins': result = []
    elif path == '/rest/v1/organizations': result = [{'id': store, 'name': 'Pilot Hardware'}]
    elif path == '/rest/v1/seats': result = [{'id': 'seat1', 'organization_id': store}, {'id': 'seat2', 'organization_id': store}]
    elif path == '/rest/v1/invitations': result = invites
    elif path == '/rest/v1/rpc/save_my_profile':
        assert route.request.post_data_json['display_name'] == 'Store Manager'
        result = None
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
        page = browser.new_page(viewport={'width': 1200, 'height': 1000})
        errors = []
        page.on('pageerror', lambda error: errors.append(str(error)))
        page.on('dialog', lambda dialog: dialog.accept())
        page.route('**/*', handle)
        page.goto('https://accounts.example/accounts/index.html', wait_until='networkidle')
        expect(page.get_by_role('heading', name='Welcome to colTRAIN')).to_be_visible()
        page.locator('#auth-form input[name=email]').fill('manager@example.test')
        page.locator('#auth-form input[name=password]').fill('short-pass')
        page.locator('#auth-form button[type=submit]').click()
        expect(page.get_by_role('heading', name='Your store account')).to_be_visible()
        expect(page.get_by_role('heading', name='Pilot Hardware', exact=True).first).to_be_visible()
        page.locator('#profile-form button[type=submit]').click()
        expect(page.locator('#account-message')).to_have_text('Profile and email preference saved.')
        page.locator('#invite-form input[name=email]').fill('new.employee@example.test')
        page.locator('#invite-form').get_by_role('button', name='Create invitation code', exact=True).click()
        expect(page.locator('.account-code')).to_have_text('LOCAL_TEST_INVITATION_ONE')
        page.get_by_role('button', name='Replace code', exact=True).click()
        expect(page.locator('.account-code')).to_have_text('LOCAL_TEST_REPLACEMENT_CODE')
        page.get_by_role('button', name='Send reset link', exact=True).last.click()
        expect(page.locator('#account-message')).to_contain_text('Password reset requested')
        page.get_by_role('button', name='Remove access', exact=True).click()
        expect(page.get_by_text('employee · inactive', exact=True)).to_be_visible()
        page.set_viewport_size({'width': 390, 'height': 844})
        assert page.locator('body').evaluate('(el)=>el.scrollWidth<=innerWidth')
        page.get_by_role('button', name='Sign out', exact=True).click()
        expect(page.get_by_role('heading', name='Welcome to colTRAIN')).to_be_visible()
        page.get_by_role('button', name='Create account', exact=True).click()
        expect(page.get_by_role('heading', name='Create your account')).to_be_visible()
        assert page.locator('input[name=password]').get_attribute('minlength') == '12'
        assert not errors, errors
        assert ('POST', '/rest/v1/rpc/create_invitation') in calls
        print('Passed mocked account UI: sign-in/out, profile preferences, invite/reissue, password reset, deactivate, registration screen, mobile layout.')
        browser.close()
    # A privileged key must never be embedded in the browser artifact.
    rejected = subprocess.run(['node', 'scripts/build-accounts.mjs'], cwd=root,
                              env={**os.environ, 'SUPABASE_PUBLISHABLE_KEY': 'sb_secret_local_test_rejected'},
                              capture_output=True, text=True)
    assert rejected.returncode != 0 and 'Only a Supabase publishable key' in rejected.stderr
    print('Passed privileged-key build rejection.')
finally:
    subprocess.run(['node', 'scripts/build-accounts.mjs'], cwd=root, check=True)
