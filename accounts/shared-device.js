const MODE='coltrain-device-mode', CLOCK='coltrain-session-activity', SIGNAL='coltrain-device-signout';
const LIMIT=15*60*1000, WARNING=60*1000;
const read=(storage,key)=>{try{return storage.getItem(key);}catch{return null;}};
const write=(storage,key,value)=>{try{storage.setItem(key,value);}catch{}};
const parse=value=>{try{return JSON.parse(value);}catch{return null;}};
const local=()=>{try{return window.localStorage;}catch{return null;}};
export function createSharedDeviceGuard({storage,onExpire}){
 let active=false,person=null,lastActivity=0,startedAt=0,signalId=null,timer=null,countdown=null,lastSaved=0;
 let shared=(read(local(),MODE)||read(storage,MODE))!=='personal';
 const warning=document.createElement('dialog');warning.className='shared-device-dialog';
 warning.setAttribute('aria-labelledby','shared-device-title');
 warning.innerHTML='<h1 id="shared-device-title">Still learning?</h1><p>This shared device will sign you out after 15 minutes without activity.</p><p>Signing out in <strong data-idle-seconds>60</strong> seconds.</p><p class="account-small">Saved progress is kept. Unsubmitted quiz answers and unsent drafts will be cleared.</p><div class="shared-device-actions"><button type="button" class="button" data-idle-stay>Stay signed in</button><button type="button" class="button secondary" data-idle-signout>Sign out now</button></div>';
 document.body.append(warning);
 const signal=()=>parse(read(local(),SIGNAL));
 function save(){if(active){write(storage,CLOCK,JSON.stringify({person,lastActivity,startedAt,signalId}));lastSaved=Date.now();}}
 function hideWarning(){clearInterval(countdown);countdown=null;if(warning.open)warning.close();}
 function stop(){active=false;clearTimeout(timer);hideWarning();document.documentElement.classList.remove('shared-device-away');}
 function expire(reason,broadcast=true){if(!active)return;stop();onExpire(reason,broadcast);}
 function check(){
  if(!active)return false;
  const latest=signal();
  if(latest&&latest.id!==signalId){expire('other-tab',false);return false;}
  if(shared&&Date.now()-lastActivity>=LIMIT){expire('idle');return false;}
  return true;
 }
 function schedule(){
  clearTimeout(timer);if(!active||!shared)return;
  const remaining=LIMIT-(Date.now()-lastActivity);
  if(remaining<=0){expire('idle');return;}
  if(remaining<=WARNING){
   const count=()=>{if(check()){warning.querySelector('[data-idle-seconds]').textContent=String(Math.max(1,Math.ceil((LIMIT-(Date.now()-lastActivity))/1000)));}};
   if(!warning.open&&!document.hidden){warning.showModal();warning.querySelector('[data-idle-stay]').focus();}
   if(!countdown){count();countdown=setInterval(count,1000);}
   timer=setTimeout(()=>{if(check())schedule();},remaining);
  }else{hideWarning();timer=setTimeout(()=>{if(check())schedule();},remaining-WARNING);}
 }
 function touch(){
  if(!check()||document.hidden||warning.open)return;
  lastActivity=Date.now();
  if(Date.now()-lastSaved>=1000){save();schedule();}
 }
 for(const event of ['pointerdown','keydown','scroll','touchstart'])document.addEventListener(event,touch,{passive:true,capture:true});
 warning.addEventListener('cancel',event=>event.preventDefault());
 warning.querySelector('[data-idle-stay]').addEventListener('click',()=>{if(check()){lastActivity=Date.now();save();hideWarning();schedule();}});
 warning.querySelector('[data-idle-signout]').addEventListener('click',()=>expire('switch'));
 function resume(){if(check()){document.documentElement.classList.remove('shared-device-away');schedule();}}
 document.addEventListener('visibilitychange',()=>{
  if(!active)return;
  if(document.hidden){save();if(shared)document.documentElement.classList.add('shared-device-away');}
  else resume();
 });
 window.addEventListener('pagehide',()=>{if(active){save();if(shared)document.documentElement.classList.add('shared-device-away');}});
 window.addEventListener('pageshow',resume);
 window.addEventListener('storage',event=>{
  if(event.key===SIGNAL)check();
  if(event.key===MODE){shared=read(local(),MODE)!=='personal';if(active){if(check()){if(!shared){hideWarning();document.documentElement.classList.remove('shared-device-away');}schedule();}}}
 });
 return {
  isShared:()=>shared,
  preflight(session,callback=false){
   if(callback||!session?.user?.id)return null;
   const previous=parse(read(storage,CLOCK)),latest=signal();
   if(previous?.person!==session.user.id)return null;
   if(latest&&latest.id!==previous.signalId)return 'other-tab';
   if(shared&&(!Number.isFinite(previous.lastActivity)||Date.now()-previous.lastActivity>=LIMIT))return 'idle';
   return null;
  },
  start(id,{fresh=false}={}){
   if(active&&person===id&&!fresh)return check();
   stop();person=id;active=true;
   const previous=fresh?null:parse(read(storage,CLOCK));
   lastActivity=previous?.person===id&&Number.isFinite(previous.lastActivity)?previous.lastActivity:Date.now();
   startedAt=previous?.person===id?previous.startedAt:Date.now();
   signalId=previous?.person===id?previous.signalId:signal()?.id||null;
   if(!check())return false;save();schedule();return true;
  },
  setShared(enabled){shared=Boolean(enabled);const mode=shared?'shared':'personal';write(local(),MODE,mode);write(storage,MODE,mode);if(active){lastActivity=Date.now();save();hideWarning();document.documentElement.classList.remove('shared-device-away');schedule();}},
  end(broadcast=true){stop();try{storage.removeItem(CLOCK);}catch{}if(broadcast)write(local(),SIGNAL,JSON.stringify({id:crypto.randomUUID(),at:Date.now()}));},
  stop
 };
}
