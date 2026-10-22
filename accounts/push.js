// Browser consent belongs to this personal device, separately from email preferences.
export function createPushNotifications({client,isShared,notify}){
 let enabled=false,status='',closed=false,knownSubscription=null;
 const supported=()=> 'serviceWorker' in navigator && 'PushManager' in window && 'Notification' in window;
 const registration=()=>Promise.race([navigator.serviceWorker.ready,new Promise((_,reject)=>setTimeout(()=>reject(Error('Please refresh colTRAIN and try again.')),10000))]);
 async function current(){const reg=supported()?await navigator.serviceWorker.getRegistration('/accounts/'):null;knownSubscription=reg?await reg.pushManager.getSubscription():null;return knownSubscription;}
 let badgeRunning=false,badgeAgain=false,lastCount=0;
 async function badge(count){
  lastCount=count;if(closed||!navigator.setAppBadge)return;
  if(badgeRunning){badgeAgain=true;return;}badgeRunning=true;
  try{
   const result=await client.rpc('get_my_web_push_count',{});
   if(closed)return;
   const total=!result.error&&Number.isSafeInteger(result.data)?result.data:lastCount;
   if(total>0)await navigator.setAppBadge(total);else await navigator.clearAppBadge?.();
  }catch{}finally{badgeRunning=false;if(badgeAgain&&!closed){badgeAgain=false;void badge(lastCount);}}
 }
 async function load(){
  if(!supported())return;
  try{
  const sub=await current();enabled=false;
  if(sub){const result=await client.rpc('get_web_push_status',{push_endpoint:sub.endpoint});enabled=!result.error&&result.data===true;
   if(!result.error&&result.data===false)await sub.unsubscribe();
   if(enabled&&isShared())await disable();
  }
  }catch{enabled=false;}
 }
 function html(){
  const ios=/iPad|iPhone|iPod/.test(navigator.userAgent)||(navigator.platform==='MacIntel'&&navigator.maxTouchPoints>1);
  const installed=matchMedia('(display-mode: standalone)').matches||navigator.standalone===true;
  return `<section class="panel"><h2>Notifications on this device</h2><p>Optional alerts for messages, training reminders, and admin updates. Lock-screen alerts keep details private. Your email preference is separate.</p><p>${!supported()?(ios&&!installed?'On iPhone or iPad, add colTRAIN to your home screen, open it from that icon, then return here to enable notifications. iOS 16.4 or later is required.':'This browser does not support push notifications. In-app notifications still work.'):isShared()?'Push notifications are off for shared store devices. On your personal device, turn off the shared-device setting in Account & team settings first.':enabled?'Notifications are enabled on this personal device.':'Notifications are off on this device.'}</p>${supported()?`<button class="button secondary" type="button" data-training-action="push-${enabled?'disable':'enable'}" ${!enabled&&isShared()?'disabled':''}>${enabled?'Turn off device notifications':'Enable device notifications'}</button>`:''}<p class="account-small">${status||'Icon badges depend on your phone and browser. The badge updates while colTRAIN is open and when a new push alert arrives. Signing out turns off this device’s subscription.'}</p></section>`;
 }
 async function disable(){
  const sub=await current();
  if(sub){const result=await client.rpc('remove_web_push',{push_endpoint:sub.endpoint});await sub.unsubscribe();if(result.error)throw Error('The device could not be removed from the server. Please reconnect and try again.');}
  knownSubscription=null;enabled=false;await badge(0);
 }
 async function action(name){
  if(name==='push-disable'){await disable();status='Device notifications are off.';return;}
  if(isShared())throw Error('Enable notifications only on your personal device.');
  if(!supported())throw Error('Push notifications are unavailable on this browser.');
  // Permission prompt starts directly from the user's click (required on iOS).
  const permission=await Notification.requestPermission();
  if(permission!=='granted'){status='Notifications were not enabled. You can change permission in your browser or phone settings.';return;}
  const config=await client.functions.invoke('web-push',{body:{action:'config'}});
  if(config.error||!config.data?.public_key)throw Error('Device notifications are not configured yet. Please try again after setup.');
  const key=config.data.public_key,bytes=Uint8Array.from(atob(key.replace(/-/g,'+').replace(/_/g,'/')+'='.repeat((4-key.length%4)%4)),c=>c.charCodeAt(0));
  let sub=await current();if(!sub)sub=await (await registration()).pushManager.subscribe({userVisibleOnly:true,applicationServerKey:bytes});
  knownSubscription=sub;
  const json=sub.toJSON();
  const result=await client.rpc('save_web_push',{push_endpoint:sub.endpoint,public_key:json.keys.p256dh,auth_secret:json.keys.auth});
  if(result.error){await sub.unsubscribe();knownSubscription=null;throw Error(result.error.message);}
  enabled=true;status='Device notifications are enabled. New unread updates will trigger alerts; existing notifications remain in your inbox.';
 }
 // Sign-out must finish locally even offline; remove the browser subscription immediately.
 function signout({url,key,token}){
  closed=true;void navigator.clearAppBadge?.()?.catch?.(()=>{});
  if(!supported())return;
  const remove=sub=>{if(!sub)return;if(token)void fetch(url+'/rest/v1/rpc/remove_web_push',{method:'POST',headers:{apikey:key,Authorization:'Bearer '+token,'Content-Type':'application/json'},body:JSON.stringify({push_endpoint:sub.endpoint}),keepalive:true}).catch(()=>{});void sub.unsubscribe().catch(()=>{});};
  // Cached endpoint lets keepalive revocation begin before the sign-out navigation.
  if(knownSubscription)remove(knownSubscription);else void current().then(remove).catch(()=>{});
  navigator.serviceWorker.controller?.postMessage({type:'coltrain-signout'});
  if(supported())void navigator.serviceWorker.getRegistration('/accounts/').then(r=>r?.getNotifications()||[]).then(list=>list.forEach(n=>n.close())).catch(()=>{});
 }
 return {html,load,badge,action,disable,signout};
}
