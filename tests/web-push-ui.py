"""Browser consent/device controls. Browser push transport and Supabase are simulated."""
from pathlib import Path
from http.server import ThreadingHTTPServer,SimpleHTTPRequestHandler
from functools import partial
from threading import Thread
from playwright.sync_api import sync_playwright,expect
root=Path(__file__).resolve().parent.parent
class Handler(SimpleHTTPRequestHandler):
 def log_message(self,*args):pass
server=ThreadingHTTPServer(('127.0.0.1',0),partial(Handler,directory=str(root)));Thread(target=server.serve_forever,daemon=True).start()
origin=f'http://127.0.0.1:{server.server_port}'
harness='''<!doctype html><div id="root"></div><div id="error"></div><script type="module">
import {createPushNotifications} from '/accounts/push.js';
window.shared=true;window.calls=[];window.saved=false;window.fail=false;
const client={rpc:async(name,args)=>{calls.push({name,args});if(name==='get_web_push_status')return {data:saved};if(name==='save_web_push'){if(fail)return {error:{message:'Server unavailable'}};saved=true;}if(name==='remove_web_push')saved=false;return {};},functions:{invoke:async()=>({data:{public_key:'B'+'A'.repeat(86)}})}};
window.push=createPushNotifications({client,isShared:()=>shared,notify:()=>{}});
window.render=()=>document.querySelector('#root').innerHTML=push.html();
document.addEventListener('click',async e=>{const action=e.target.dataset.trainingAction;if(!action)return;try{await push.action(action);render();}catch(error){document.querySelector('#error').textContent=error.message;}});
render();window.ready=true;
</script>'''
script='''window.pushPermission='granted';window.permissionCalls=0;window.unsubscribed=0;window.badges=[];window.fetches=[];window.subscription=null;
window.PushManager=function(){};
Object.defineProperty(window,'Notification',{configurable:true,value:{requestPermission:async()=>{permissionCalls++;return pushPermission;}}});
const sub=()=>({endpoint:'https://web.push.apple.com/test',toJSON:()=>({keys:{p256dh:'B'+'A'.repeat(86),auth:'A'.repeat(22)}}),unsubscribe:async()=>{unsubscribed++;subscription=null;return true;}});
const reg={pushManager:{getSubscription:async()=>subscription,subscribe:async options=>{window.subscribeOptions=options;subscription=sub();return subscription;}},getNotifications:async()=>[]};
Object.defineProperty(navigator,'serviceWorker',{value:{getRegistration:async()=>reg,ready:Promise.resolve(reg)}});
navigator.setAppBadge=async n=>badges.push(n);navigator.clearAppBadge=async()=>badges.push(0);
window.fetch=async(url,options)=>{fetches.push({url,options});return new Response('{}');};'''
try:
 with sync_playwright() as p:
  browser=p.chromium.launch(executable_path='/usr/bin/chromium',args=['--no-sandbox'])
  page=browser.new_page();page.add_init_script(script)
  page.route(origin+'/push-test',lambda route:route.fulfill(content_type='text/html',body=harness))
  page.goto(origin+'/push-test');page.wait_for_function('window.ready')
  expect(page.get_by_role('button',name='Enable device notifications')).to_be_disabled()
  assert page.evaluate('permissionCalls')==0
  page.evaluate('shared=false;render()')
  page.evaluate("pushPermission='denied'");page.get_by_role('button',name='Enable device notifications').click()
  expect(page.get_by_text('Notifications were not enabled.',exact=False)).to_be_visible();assert not page.evaluate('saved')
  page.evaluate("pushPermission='granted'");page.get_by_role('button',name='Enable device notifications').click()
  expect(page.get_by_role('button',name='Turn off device notifications')).to_be_visible()
  assert page.evaluate('saved') and page.evaluate('subscribeOptions.userVisibleOnly')
  assert page.evaluate("calls.find(c=>c.name==='save_web_push').args.public_key.length")==87
  page.evaluate('push.badge(8)');page.wait_for_function('badges.includes(8)')
  page.get_by_role('button',name='Turn off device notifications').click()
  expect(page.get_by_role('button',name='Enable device notifications')).to_be_visible();assert page.evaluate('unsubscribed')==1 and not page.evaluate('saved')
  # A save failure unsubscribes rather than leaving an unbound subscription.
  page.evaluate('fail=true');page.get_by_role('button',name='Enable device notifications').click()
  expect(page.locator('#error')).to_have_text('Server unavailable');assert page.evaluate('unsubscribed')==2
  page.evaluate('fail=false');page.get_by_role('button',name='Enable device notifications').click()
  expect(page.get_by_role('button',name='Turn off device notifications')).to_be_visible()
  page.evaluate("push.signout({url:'https://project.supabase.co',key:'public',token:'test-session'})")
  page.wait_for_function('unsubscribed===3 && fetches.length===1')
  assert page.evaluate('badges.at(-1)')==0
  assert page.evaluate('fetches[0].options.keepalive')
  assert '/rest/v1/rpc/remove_web_push' in page.evaluate('fetches[0].url')
  assert page.evaluate('localStorage.length')==0
  # iPhone without home-screen support gets installation instructions, no permission prompt.
  page.evaluate("delete window.PushManager;Object.defineProperty(navigator,'userAgent',{value:'iPhone'});render()")
  expect(page.get_by_text('On iPhone or iPad, add colTRAIN',exact=False)).to_be_visible()
  # Local generator produces a valid-length pair without network or persistence.
  page.goto(origin+'/supabase/generate-web-push-keys.html')
  page.get_by_role('button',name='Generate keys').click()
  expect(page.locator('#status')).to_contain_text('Keys generated locally')
  assert page.locator('#public').input_value().__len__()==87
  assert page.locator('#private').input_value().__len__()==43
  assert page.evaluate('localStorage.length')==0
  browser.close()
 print('Passed browser opt-in, denied permission, shared-device block, registration, failed-save cleanup, badge, sign-out revocation and iPhone guidance. No real push sent.')
finally:server.shutdown()
