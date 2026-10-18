"""Real local-origin PWA checks. No Supabase access, account data, or external email.
Installation prompts are simulated; phone home-screen acceptance remains a device test.
"""
from functools import partial
from http.server import ThreadingHTTPServer, SimpleHTTPRequestHandler
from pathlib import Path
from threading import Thread
from tempfile import TemporaryDirectory
from urllib.parse import urlparse
from zipfile import ZipFile
import json, struct, subprocess
from playwright.sync_api import sync_playwright, expect

root=Path(__file__).resolve().parent.parent
subprocess.run(['npm','run','build:accounts'],cwd=root,check=True)
subprocess.run(['python','scripts/build-hosting.py'],cwd=root,check=True)
class Handler(SimpleHTTPRequestHandler):
 extensions_map={**SimpleHTTPRequestHandler.extensions_map,'.webmanifest':'application/manifest+json','.js':'application/javascript'}
 def log_message(self,*args):pass
server=ThreadingHTTPServer(('127.0.0.1',0),partial(Handler,directory=str(root/'hosting')))
thread=Thread(target=server.serve_forever,daemon=True);thread.start()
origin=f'http://127.0.0.1:{server.server_port}'
try:
 manifest=json.loads((root/'accounts/manifest.webmanifest').read_text())
 assert manifest['id']==manifest['start_url']==manifest['scope']=='/accounts/'
 assert manifest['display']=='standalone' and manifest['name']=='colTRAIN'
 for icon in manifest['icons']+[{'src':'/accounts/icons/apple-touch-icon.png','sizes':'180x180'}]:
  payload=(root/icon['src'].lstrip('/')).read_bytes()
  assert payload[:8]==b'\x89PNG\r\n\x1a\n'
  width,height=struct.unpack('>II',payload[16:24])
  assert icon['sizes']==f'{width}x{height}'
 with ZipFile(root/'design/coltrain-website.zip') as archive:
  expected={'index.html','accounts/index.html','preview/index.html','_headers','accounts/sw.js','accounts/manifest.webmanifest',*[icon['src'].lstrip('/') for icon in manifest['icons']],'accounts/icons/apple-touch-icon.png','accounts/icons/coltrain.svg'}
  assert set(archive.namelist())==expected
  assert 'Service-Worker-Allowed: /accounts/' in archive.read('_headers').decode()
 with TemporaryDirectory(prefix='coltrain-pwa-') as profile, sync_playwright() as p:
  context=p.chromium.launch_persistent_context(profile,executable_path='/usr/bin/chromium',headless=True,args=['--no-sandbox'])
  browser=context.browser
  # The real app has no stored session. Reject any unintended external call.
  context.route('**/*',lambda route: route.continue_() if route.request.url.startswith(origin+'/') else route.abort())
  page=context.new_page();errors=[]
  page.on('pageerror',lambda error:errors.append(str(error)))
  response=page.goto(origin+'/accounts/')
  assert response.status==200
  expect(page.get_by_role('heading',name='Welcome to colTRAIN')).to_be_visible()
  page.evaluate('navigator.serviceWorker.ready')
  page.wait_for_function('navigator.serviceWorker.controller !== null')
  assert page.evaluate('navigator.serviceWorker.controller.scriptURL')==origin+'/accounts/sw.js'
  assert page.locator('link[rel=apple-touch-icon]').get_attribute('href')=='/accounts/icons/apple-touch-icon.png'
  session=context.new_cdp_session(page)
  app_manifest=session.send('Page.getAppManifest')
  assert not app_manifest.get('errors'),app_manifest
  install_errors=session.send('Page.getInstallabilityErrors')
  assert not install_errors.get('installabilityErrors'),install_errors
  page.get_by_role('button',name='Add to home screen',exact=True).click()
  expect(page.get_by_role('dialog')).to_be_visible()
  expect(page.get_by_role('heading',name='Add colTRAIN to your home screen')).to_be_visible()
  page.get_by_text('iPhone and iPad',exact=True).click()
  expect(page.get_by_text('Add to Home Screen',exact=True)).to_be_visible()
  page.get_by_role('button',name='Close installation instructions').click()
  expect(page.get_by_role('dialog')).not_to_be_visible()
  page.evaluate('''() => {
   const event=new Event('beforeinstallprompt',{cancelable:true});
   event.prompt=async()=>{window.promptCalls=(window.promptCalls||0)+1};
   event.userChoice=Promise.resolve({outcome:'dismissed'});
   window.dispatchEvent(event);
  }''')
  page.get_by_role('button',name='Add to home screen',exact=True).click()
  page.get_by_role('button',name='Install colTRAIN',exact=True).click()
  expect(page.locator('.install-status')).to_have_text('You can add colTRAIN later using the steps below.')
  assert page.evaluate('window.promptCalls')==1
  expect(page.get_by_role('button',name='Install colTRAIN',exact=True)).to_have_count(0)
  page.keyboard.press('Escape')
  expect(page.get_by_role('dialog')).not_to_be_visible()
  # Browser installation is only claimed after appinstalled, not after a click.
  page.evaluate('''() => {
   const event=new Event('beforeinstallprompt',{cancelable:true});
   event.prompt=async()=>{};event.userChoice=Promise.resolve({outcome:'accepted'});window.dispatchEvent(event);
  }''')
  page.get_by_role('button',name='Add to home screen',exact=True).click()
  page.get_by_role('button',name='Install colTRAIN',exact=True).click()
  expect(page.locator('.install-status')).to_have_text('Follow your browser’s installation steps.')
  page.evaluate("window.dispatchEvent(new Event('appinstalled'))")
  expect(page.get_by_role('heading',name='colTRAIN is installed',exact=True)).to_be_visible()
  expect(page.locator('.install-status')).to_have_text('')
  page.get_by_role('button',name='Close installation instructions').click()
  assert page.evaluate('caches.keys()')==[]
  assert not errors,errors
  context.set_offline(True)
  offline=page.goto(origin+'/accounts/?invitation_id=private-test-value')
  assert offline.status==503
  expect(page.get_by_role('heading',name="You're offline.")).to_be_visible()
  assert 'private-test-value' not in page.content()
  assert 'supabase' not in page.content().lower()
  assert page.evaluate('caches.keys()')==[]
  context.set_offline(False)
  page.get_by_role('link',name='Try again').click()
  expect(page.get_by_role('heading',name='Welcome to colTRAIN')).to_be_visible()
  assert urlparse(page.url).query==''
  # Browser-rendered mobile instructions and standalone detection.
  for agent,platform,is_mobile in [
   ('Mozilla/5.0 (iPhone; CPU iPhone OS 18_0 like Mac OS X) AppleWebKit/605.1.15 Version/18.0 Mobile/15E148 Safari/604.1','iPhone',True),
   ('Mozilla/5.0 (Linux; Android 14) AppleWebKit/537.36 Chrome/130.0.0.0 Mobile Safari/537.36','Android',True),
   ('Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15) AppleWebKit/605.1.15 Version/18.0 Safari/605.1.15','iPad',True),
  ]:
   mobile=browser.new_context(viewport={'width':390,'height':844},user_agent=agent,is_mobile=is_mobile,has_touch=True)
   mobile.route('**/*',lambda route: route.continue_() if route.request.url.startswith(origin+'/') else route.abort())
   if platform=='iPad':mobile.add_init_script("Object.defineProperty(navigator,'platform',{get:()=> 'MacIntel'});Object.defineProperty(navigator,'maxTouchPoints',{get:()=>5});")
   phone=mobile.new_page();phone.goto(origin+'/accounts/')
   phone.get_by_role('button',name='Add to home screen',exact=True).click()
   detail=phone.locator('details[open] summary')
   expect(detail).to_have_text('Android phones' if platform=='Android' else 'iPhone and iPad')
   assert phone.locator('.install-dialog').evaluate('el=>el.scrollWidth<=el.clientWidth')
   phone.keyboard.press('Escape');mobile.close()
  standalone=browser.new_context()
  standalone.route('**/*',lambda route: route.continue_() if route.request.url.startswith(origin+'/') else route.abort())
  standalone.add_init_script("Object.defineProperty(navigator,'standalone',{get:()=>true});")
  installed=standalone.new_page();installed.goto(origin+'/accounts/')
  installed.get_by_role('button',name='Add to home screen',exact=True).click()
  expect(installed.get_by_role('heading',name='colTRAIN is installed',exact=True)).to_be_visible()
  standalone.close();browser.close()
 print('Passed PWA manifest/icons/package, Chromium installability, real service worker scope, zero CacheStorage, safe offline/reconnect, install prompt lifecycle, mobile guidance, and standalone detection. Physical phone installation remains a hosted device check.')
finally:
 server.shutdown();server.server_close();thread.join()
