import {updateBuyingGroups} from './buying-groups.js';
import {createStoreSignup} from './store-signup.js';
import {createCompanySettings} from './company-settings.js';
import {createPersonalSessionStorage} from './personal-session.js';
import {createPushNotifications} from './push.js';
import {confirmEmployeeLogin} from './employee-login.js';
import {createSharedDeviceGuard} from './shared-device.js';
import {avatarMarkup,createAvatarLoader,prepareAvatar} from './avatars.js';
import {setupHomeScreenInstall} from './install.js';
import {setAccountHeader} from './header.js';
import {mountTraining} from './training.js';
import {createClient} from '@supabase/supabase-js';
const root=document.querySelector('#accounts-app'),message=document.querySelector('#account-message');
const esc=value=>String(value??'').replace(/[&<>"']/g,c=>({'&':'&amp;','<':'&lt;','>':'&gt;','"':'&quot;',"'":'&#39;'}[c]));
const button=(text,action,kind='secondary')=>`<button class="button ${kind}" data-action="${action}">${text}</button>`;
function sessionStorageForAuth(){try{return window.sessionStorage;}catch{const values=new Map();return {getItem:key=>values.get(key)||null,setItem:(key,value)=>values.set(key,value),removeItem:key=>values.delete(key)};}}
const baseStorage=sessionStorageForAuth();
const authKey='sb-'+new URL(__SUPABASE_URL__).hostname.split('.')[0]+'-auth-token';
let persistentStorage=null;try{persistentStorage=window.localStorage;}catch{}
const personalSession=createPersonalSessionStorage({session:baseStorage,local:persistentStorage,authKey});
let sessionEnding=false;
const authStorage={getItem:key=>sessionEnding?null:personalSession.getItem(key),setItem:(key,value)=>{if(!sessionEnding)personalSession.setItem(key,value);},removeItem:key=>personalSession.removeItem(key)};
const deviceGuard=createSharedDeviceGuard({storage:baseStorage,onExpire:endSession});
const callbackEntry=location.hash.includes('access_token=')||new URLSearchParams(location.search).has('code');
let startupReason=null;
try{startupReason=deviceGuard.preflight(JSON.parse(personalSession.getItem(authKey)||'null'),callbackEntry);}catch{}
function eraseStoredAuth(){personalSession.clear();}
if(startupReason){eraseStoredAuth();deviceGuard.end(false);}
const client=__SUPABASE_KEY__?createClient(__SUPABASE_URL__,__SUPABASE_KEY__,{auth:{storage:authStorage,storageKey:authKey,persistSession:true,autoRefreshToken:true,detectSessionInUrl:true}}):null;
const avatars=createAvatarLoader(client);
const push=createPushNotifications({client,isShared:()=>deviceGuard.isShared(),notify:notice});
let photoDraft=null,memberProfiles=[];
function clearPhotoDraft(){if(photoDraft)URL.revokeObjectURL(photoDraft.preview);photoDraft=null;}
const emailRedirect=/^https?:$/.test(location.protocol)?location.origin+location.pathname:undefined;
setupHomeScreenInstall();
const companyInvitationId=new URLSearchParams(location.search).get('company_invitation_id');
let companySetupRequested=new URLSearchParams(location.search).has('company_setup');
const invitationId=new URLSearchParams(location.search).get('invitation_id');
let trainingController=null,trainingView="home",activeStoreId=null;
let storeSignupRequested=new URLSearchParams(location.search).has('store_signup');
const storeSignup=createStoreSignup({client,root,notify:notice});
const companySettings=createCompanySettings({client,notify:notice,isPlatformAdmin:()=>admin});
const accountForms=new Set(['company-admin-invite-form','company-manager-form','store-signup-form','company-details-form','company-permission-form','auth-form','password-form','profile-form','profile-photo-form','device-form','join-form','store-form','invite-form']);
let view='signin',user=null,profile=null,members=[],admin=false,stores=[],seats=[],invitations=[],busy=false,recovering=location.hash.includes('type=recovery')||location.hash.includes('type=invite');
function endSession(reason='switch',broadcast=true){
 if(sessionEnding)return;
 let token;try{token=JSON.parse(personalSession.getItem(authKey)||'null')?.access_token;}catch{}
 push.signout({url:__SUPABASE_URL__,key:__SUPABASE_KEY__,token});
 sessionEnding=true;deviceGuard.end(broadcast);eraseStoredAuth();
 avatars.clear();clearPhotoDraft();memberProfiles=[];companySettings.close();storeSignup.close();
 trainingController?.close();trainingController=null;
 document.querySelectorAll('.training-menu-toggle').forEach(button=>button.remove());
 document.querySelectorAll('dialog[open]').forEach(dialog=>dialog.close());
 user=null;profile=null;members=[];stores=[];seats=[];invitations=[];admin=false;recovering=false;trainingView='home';activeStoreId=null;
 root.replaceChildren();message.textContent='';setAccountHeader();
 // Best-effort server revocation must not delay or prevent local sign-out when offline.
 if(token)fetch(__SUPABASE_URL__+'/auth/v1/logout?scope=local',{method:'POST',headers:{apikey:__SUPABASE_KEY__,Authorization:'Bearer '+token},keepalive:true}).catch(()=>{});
 location.replace(location.pathname+'?signed_out='+encodeURIComponent(reason));
}
function syncCompanySettings(){const section=root.querySelector('.training-account-settings');if(section)trainingController?.updateAccountMarkup(section.innerHTML);}
function deviceChoice(){return `<label class="account-checkbox"><input type="checkbox" name="shared-device" ${deviceGuard.isShared()?'checked':''}><span>This is a shared store device. Sign out after 15 minutes without activity.</span></label><label class="account-checkbox"><input type="checkbox" name="remember-device" ${personalSession.isRemembered()?'checked':''}><span>Keep me signed in on this personal device.</span></label>`;}
function deviceSettings(){return `<section class="panel"><h2>This device</h2><form id="device-form">${deviceChoice()}<p class="account-small">Choose Keep me signed in only on a phone or computer you own. Shared-device mode removes the saved login and signs you out after 15 minutes without activity. This choice is separate from notification permissions.</p><button class="button" type="submit">Save device setting</button></form></section>`;}
function notice(text,error=false){message.className=error?'error':'success';message.textContent=text;if(text)message.scrollIntoView({block:'nearest'});}
async function sendEmailInvitation(body){const {data,error}=await client.functions.invoke('invite-employee',{body});if(error){let details;try{details=await error.context?.json();}catch{}throw new Error(details?.error||'Email invitations are temporarily unavailable. Please contact colTRAIN support.');}if(data?.error)throw new Error(data.error);return data;}
function field(label,name,type='text',value='',extra=''){return `<label class="field">${label}<input type="${type}" name="${name}" value="${esc(value)}" ${extra}></label>`;}
function passwordField(label='Password'){return `<label class="field">${label}<input class="account-password" type="password" name="password" ${view==='signup'||recovering?'minlength="12"':''} autocomplete="${view==='signup'||recovering?'new-password':'current-password'}" required></label>`;}
function authScreen(){
 trainingController?.close();trainingController=null;setAccountHeader();
 const signup=view==='signup',reset=view==='reset';
 root.innerHTML=`<section class="panel auth-card"><h1>${reset?'Reset your password':signup?'Create your account':'Welcome to colTRAIN'}</h1><p class="muted">${reset?'We’ll send a password reset link if an account is available.':signup?(storeSignupRequested?'Create your personal owner account. Confirm your email, then sign in to finish store signup.':'Use the email address your manager invited. Confirm your email, then sign in and enter your invitation code.'):'Sign in to your store’s training space.'}</p><form id="auth-form">${signup?field('Your name','name','text','','maxlength="120" autocomplete="name" required'):''}${field('Email','email','email','','autocomplete="email" required')}${reset?'':passwordField()+deviceChoice()}<button class="button" type="submit">${reset?'Send reset link':signup?'Create account':'Sign in'}</button></form><div class="auth-links">${button(signup||reset?'Back to sign in':'Create account',signup||reset?'signin':'signup')}${!signup&&!reset?button('Forgot password?','reset'):''}</div><p class="account-small">For store owners and authorized purchasers: <button type="button" class="button secondary" data-action="store-signup-start">Register a store (sandbox)</button></p><button type="button" class="button secondary install-entry" data-install-action="open">Add to home screen</button><p class="account-small">On a shared device, sign out when you finish. Use your own email and password, and avoid saving your password in the browser on shared hardware.</p></section>`;
}
function recoveryScreen(){trainingController?.close();trainingController=null;setAccountHeader({user});root.innerHTML=`<section class="panel auth-card"><h1>${invitationId||companyInvitationId?'Create your password':'Choose a new password'}</h1><p class="muted">Use at least 12 characters.</p><form id="password-form">${passwordField('New password')}<button class="button">${companyInvitationId?'Save password and accept access':invitationId?'Save password and join store':'Save password'}</button></form></section>`;}
function photoControls(){return `<div class="profile-photo-preview">${photoDraft?`<img class="profile-avatar profile-avatar-large" src="${photoDraft.preview}" alt="Selected profile picture">`:avatarMarkup(profile?.full_name||user.email,profile?.avatar_path,true)}<p>Choose a photo with your face near the center.</p></div><label class="profile-photo-picker">Choose photo<input type="file" accept="image/jpeg,image/png,image/webp" data-profile-photo></label><div class="profile-photo-actions"><button class="button" type="submit" ${photoDraft?'':'disabled'}>Save photo</button>${photoDraft?'<button type="button" class="button secondary" data-action="cancel-photo">Cancel</button>':''}${profile?.avatar_path?'<button type="button" class="button secondary" data-action="remove-photo">Remove photo</button>':''}</div>`;}
async function savePhoto(){
 if(!photoDraft)throw new Error('Choose a photo first.');
 if(!photoDraft.path){const reserved=await client.rpc('reserve_profile_photo',{photo:photoDraft.id});if(reserved.error)throw reserved.error;photoDraft.path=reserved.data;}
 if(!photoDraft.uploaded){
  const upload=await client.storage.from('profile-photos').upload(photoDraft.path,photoDraft.blob,{contentType:'image/jpeg',upsert:false,cacheControl:'0'});
  if(upload.error){const check=await client.storage.from('profile-photos').download(photoDraft.path);if(check.error)throw new Error('The photo could not be uploaded. Please try again.');}
  photoDraft.uploaded=true;
 }
 await updatePhoto(photoDraft.id);
}
async function updatePhoto(photo){
 const {data,error}=await client.rpc('set_my_profile_photo',{photo});if(error)throw error;
 if(data.previous_object&&data.previous_object!==data.object_name){try{await client.storage.from('profile-photos').remove([data.previous_object]);}catch{}}
 clearPhotoDraft();avatars.clear();await loadWorkspace();notice(photo?'Profile picture saved.':'Profile picture removed.');
}
function profileForm(){return `<section class="panel"><h2>Your profile</h2><h3 class="profile-photo-label">Profile picture</h3><form id="profile-photo-form">${photoControls()}</form><form id="profile-form">${field('Name','name','text',profile?.full_name||user.user_metadata?.full_name||'','maxlength="120" required')}${field('Team Corner nickname (optional)','team_nickname','text',profile?.team_corner_nickname||'','maxlength="60"')}<p class="account-small">Posts and comments show your name unless you choose a nickname. Leave this blank to use your name. Your training records keep your name.</p><label class="account-checkbox"><input type="checkbox" name="notifications" ${profile?.optional_email_notifications?'checked':''}><span>Allow training, team, and admin updates to my email. Essential security and password-reset messages are separate.</span></label><button class="button" type="submit">Save preferences</button></form><p class="account-small">This saves your preference. Admin update and manager first-login emails are sent only when this preference is enabled. Emergency Team support alerts are always emailed to the selected manager.</p></section>`;}
function joinForm(){return `<section class="panel"><h2>Join your store</h2><p class="muted" style="margin-top:10px">Enter the single-use code your manager gave you. Your confirmed email must match the invitation.</p><form id="join-form">${field('Invitation code','code','text','','maxlength="64" autocomplete="off" required')}<button class="button">Join store</button></form></section>`;}
function adminPanel(){return `<section class="panel"><h2>Create a pilot store</h2><p class="muted" style="margin-top:10px">Seats are account capacity here. This does not create a paid subscription.</p><form id="store-form">${field('Store name','name','text','','maxlength="120" required')}<label class="field">Total seats, including the manager<input type="number" name="seats" min="1" max="1000" value="10" required></label><button class="button">Create store</button></form></section>`;}
function canManageStore(store){return admin||members.some(m=>m.user_id===user.id&&m.organization_id===store&&m.status==='active'&&m.role==='manager');}
function managerPanel(store){const team=members.filter(m=>m.organization_id===store.id);return `<section class="panel"><div class="panel-top"><div><h2>${esc(store.name)}</h2><p class="muted">${seats.filter(s=>s.organization_id===store.id).length} total seats · ${team.filter(m=>m.status==='active').length} active members</p></div></div><form id="invite-form" data-store="${store.id}">${field('Employee name','name','text','','maxlength="120" autocomplete="off" required')}${field('Employee email','email','email','','autocomplete="off" required')}${admin?'<label class="field">Role<select name="role"><option value="employee">Employee</option><option value="manager">Store manager</option></select></label>':''}<button class="button">Send invitation</button></form><p class="account-small">We’ll email a secure link so the employee can choose their own password and join this store. A seat is reserved until the invitation expires or is revoked.</p>${team.map(m=>`<div class="account-row"><div class="person-with-avatar">${avatarMarkup(memberProfiles.find(p=>p.user_id===m.user_id)?.full_name||m.email,memberProfiles.find(p=>p.user_id===m.user_id)?.avatar_path)}<div><strong>${esc(m.email)}</strong><small>${esc(m.role)} · ${esc(m.status)}</small></div></div>${m.status==='active'?`<div class="account-row-actions">${canManageStore(store.id)&&m.role==='employee'?`<button class="button secondary" data-action="promote-manager" data-member="${m.id}">Make store manager</button>`:''}<button class="button secondary" data-action="send-reset" data-email="${esc(m.email)}">Send reset link</button>${m.user_id!==user.id&&(admin||m.role==='employee')?`<button class="button secondary account-danger" data-action="remove" data-member="${m.id}">Remove access</button>`:''}</div>`:''}</div>`).join('')}<h3 style="margin:25px 0 12px">Pending invitations</h3>${invitations.filter(i=>i.organization_id===store.id&&!i.accepted_at&&!i.revoked_at).map(i=>`<div class="account-row"><div><strong>${esc(i.invitee_name||i.email)}</strong><small>${esc(i.email)} · ${esc(i.email_status==='sent'?'Email requested':i.email_status==='failed'?'Email could not be sent':i.email_status==='pending'?'Email request pending':'Manual invitation')} · Expires ${new Date(i.expires_at).toLocaleDateString()}</small></div><div class="account-row-actions"><button class="button secondary" data-action="reissue" data-invitation="${i.id}" data-store="${store.id}" data-email="${esc(i.email)}">${i.invitee_name?'Resend invitation':'Replace code'}</button><button class="button secondary" data-action="revoke" data-invitation="${i.id}">${i.invitee_name?'Cancel invitation':'Revoke code'}</button></div></div>`).join('')||'<p class="muted">No pending invitations.</p>'}</section>`;}
function showInvitationCode(record,email){const box=document.createElement('section');box.className='panel';box.innerHTML=`<h2>Invitation code</h2><p class="muted">Give this code to ${esc(email)}. It is shown once and expires after 7 days.</p><p class="account-code">${esc(record.invitation_code)}</p><p class="muted">The employee creates an account with the same email address, confirms it, signs in, and enters this code.</p>`;root.prepend(box);box.scrollIntoView({behavior:'smooth'});}
function accountMarkup(own,canManage,standalone=false){
 return `<div class="account-toolbar"><div><h1>${own?'Your store account':'Welcome, '+esc(profile?.full_name||'teammate')}</h1><p class="muted">${esc(user.email)}${admin?' · colTRAIN administrator':''}</p></div>${standalone?button('Sign out and switch accounts','signout'):''}</div>${!own&&!admin&&!companySettings.hasAccounts()?'<div class="account-note">No active store membership. Owners and billing administrators can open Company settings below without using a training seat. To join a training team, accept your invitation below or contact your manager.</div>':''}<div class="stack">${!own&&companySettings.hasAccounts()?companySettings.html():''}<div class="account-form-grid">${profileForm()}${!own?(companySettings.hasAccounts()?'':joinForm()):`<section class="panel"><h2>${esc(stores.find(s=>s.id===own.organization_id)?.name||'Your store')}</h2><p class="muted" style="margin-top:15px">Role: ${esc(own.role)}</p><p class="account-note">Your account is connected. Use the hamburger menu to return to your ${canManage?'dashboard':'home page'}, find courses, and view competitions.</p></section>`}</div>${deviceSettings()}${standalone&&!own&&!companySettings.hasAccounts()?'<section class="panel"><h2>Store signup</h2><p class="muted">For store owners or authorized purchasers starting or resuming a sandbox signup.</p><button class="button secondary" data-action="store-signup-start">Start or resume store signup (sandbox)</button></section>':''}${!own&&companySettings.hasAccounts()?'':companySettings.html()}${admin?adminPanel():''}${canManage?stores.map(managerPanel).join(''):''}</div>`;
}
async function loadAccountSettings(own,canManage){
 if(canManage){const [s,i,p]=await Promise.all([client.from('seats').select('*'),client.from('invitations').select('id,organization_id,email,role,created_at,expires_at,accepted_at,revoked_at,invitee_name,email_status,last_email_attempt_at').order('created_at',{ascending:false}),client.from('profiles').select('user_id,full_name,avatar_path')]);if(p.error)throw p.error;memberProfiles=p.data;if(s.error)throw s.error;if(i.error)throw new Error('Invitation details could not be loaded. Please contact colTRAIN support.');seats=s.data;invitations=i.data;}
}
async function showStoreSignup(){trainingController?.close();trainingController=null;setAccountHeader({user,profile});await storeSignup.load(user);root.innerHTML=storeSignup.page();}
async function loadWorkspace(){
 companySettings.close();storeSignup.close();
 if(!user){if(storeSignupRequested)await showStoreSignup();else authScreen();return;}
 if(recovering){recoveryScreen();return;}
 const [p,m,a,o]=await Promise.all([client.from('profiles').select('*').eq('user_id',user.id).maybeSingle(),client.from('organization_memberships').select('*').order('joined_at'),client.from('platform_admins').select('user_id').eq('user_id',user.id),client.from('organizations').select('*').order('created_at')]);
 const error=[p,m,a,o].find(result=>result.error)?.error;if(error)throw error;
 profile=p.data;members=m.data;admin=a.data.length>0;stores=o.data;
 if(storeSignupRequested){await showStoreSignup();return;}
 const own=members.find(m=>m.user_id===user.id&&m.status==='active');
 const canManage=admin||own?.role==='manager';
 if(own)void confirmEmployeeLogin(client);
 trainingController?.close();trainingController=null;
 if(!own||companySetupRequested){
  const hasCompany=await companySettings.load(true);
  if(companySetupRequested&&hasCompany){
   setAccountHeader({user,profile,role:'Company account'});
   root.innerHTML=`<div class="stack">${companySettings.html()}${own?button('Continue to dashboard','company-setup-finish',''):''}${button('Sign out and switch accounts','signout')}</div>`;return;
  }
  if(!own&&!hasCompany&&!admin){const pending=await client.rpc('get_my_store_signup');if(pending.error)throw pending.error;if(pending.data){storeSignupRequested=true;history.replaceState(null,'',location.pathname+'?store_signup=start');await showStoreSignup();return;}}
 }
 if((own||admin)&&stores.length){
  const initialStore=stores.find(s=>s.id===activeStoreId)?.id||own?.organization_id||stores[0].id;
  await push.load();
  trainingController=await mountTraining({client,root,user,profile,stores,initialStore,initialView:trainingView,avatars,push,onNavigate:(page,store)=>{trainingView=page;activeStoreId=store;},onAccounts:async()=>{await loadAccountSettings(own,canManage);return accountMarkup(own,canManage);},notify:notice});
  return;
 }
 setAccountHeader({user,profile,role:admin?'Administrator':undefined});
 await loadAccountSettings(own,canManage);
 root.innerHTML=accountMarkup(own,canManage,true);avatars.hydrate(document);
}
async function perform(action){if(busy)return;busy=true;const buttons=[...root.querySelectorAll('button:not([data-action=signout]), #company-settings input, #company-settings select')].map(button=>({button,disabled:button.disabled}));buttons.forEach(({button})=>button.disabled=true);try{await action();}catch(error){notice(error.message||'The request could not be completed.',true);}finally{busy=false;buttons.forEach(({button,disabled})=>{if(button.isConnected)button.disabled=disabled;});}}
document.addEventListener('click',event=>{
 // Embedded previews may allow scripts while blocking native form submissions.
 const submit=event.target.closest('button');
 if(submit?.form&&root.contains(submit)&&accountForms.has(submit.form.id)&&submit.type==='submit'){event.preventDefault();if(submit.form.reportValidity())submitForm(submit.form);return;}
 const signupTarget=event.target.closest('[data-store-signup-action]');if(signupTarget&&root.contains(signupTarget)){event.preventDefault();perform(()=>storeSignup.action(signupTarget));return;}
 const companyTarget=event.target.closest('[data-company-action]');if(companyTarget&&root.contains(companyTarget)){event.preventDefault();perform(async()=>{await companySettings.action(companyTarget);syncCompanySettings();});return;}
 const target=event.target.closest('[data-action]');if(!target)return;const action=target.dataset.action;
 if(action==='signout'){endSession('switch');return;}
 if(['signin','signup','reset'].includes(action)){view=action;notice('');authScreen();return;}
 perform(async()=>{
  if(action==='store-signup-start'){storeSignupRequested=true;history.replaceState(null,'',location.pathname+'?store_signup=start');await showStoreSignup();return;}
  if(action==='signup-owner-account'||action==='signup-owner-signin'){view=action==='signup-owner-account'?'signup':'signin';authScreen();return;}
  if(action==='company-setup-finish'){companySetupRequested=false;history.replaceState(null,'',location.pathname);await loadWorkspace();return;}
  if(action==='signup-exit'||action==='signup-finish'){if(action==='signup-finish')companySetupRequested=true;storeSignupRequested=false;history.replaceState(null,'',location.pathname+(companySetupRequested?'?company_setup=1':''));await loadWorkspace();return;}
  if(action==='cancel-photo'){clearPhotoDraft();const form=root.querySelector('#profile-photo-form');if(form){form.innerHTML=photoControls();avatars.hydrate(form);}return;}
  if(action==='remove-photo'){await updatePhoto(null);return;}
  if(action==='promote-manager'){
   const member=members.find(m=>m.id===target.dataset.member);
   if(!member||!canManageStore(member.organization_id)||member.status!=='active'||member.role!=='employee')throw new Error('Choose an active employee.');
   const name=memberProfiles.find(p=>p.user_id===member.user_id)?.full_name||member.email;
   const store=stores.find(s=>s.id===member.organization_id)?.name||'this store';
   if(!confirm(`Make ${name} a store manager for ${store}? They will be able to manage employees, assignments, competitions, and Team Corner. Their existing account, paid seat, and training progress will be kept.`))return;
   const {error}=await client.rpc('promote_store_manager',{member:member.id});if(error)throw error;
   await loadWorkspace();notice('Store manager role saved. Ask them to refresh colTRAIN or sign out and sign back in to see their manager dashboard.');
  }
  if(action==='send-reset'){const {error}=await client.auth.resetPasswordForEmail(target.dataset.email,{redirectTo:emailRedirect});if(error)throw error;notice('Password reset requested. The employee should check their inbox.');}
  if(action==='remove'){if(!confirm('Remove this employee’s store access and free their seat? Their membership record will be retained.'))return;const {error}=await client.rpc('deactivate_member',{member:target.dataset.member});if(error)throw error;await loadWorkspace();notice('Store access removed and the seat is available.');}
  if(action==='reissue'){const invite=invitations.find(i=>i.id===target.dataset.invitation);if(invite?.invitee_name){try{const result=await sendEmailInvitation({action:'resend',store:target.dataset.store,invitation:target.dataset.invitation});await loadWorkspace();notice(result.message);}catch(error){await loadWorkspace();throw error;}}else{const {data,error}=await client.rpc('reissue_invitation',{invitation:target.dataset.invitation});if(error)throw error;await loadWorkspace();showInvitationCode(data[0],target.dataset.email);notice('New invitation code created. The previous code no longer works.');}}
  if(action==='revoke'){const {error}=await client.rpc('revoke_invitation',{invitation:target.dataset.invitation});if(error)throw error;await loadWorkspace();notice('Invitation revoked. You can issue a new code if needed.');}
 });
});
document.addEventListener('change',event=>{
 if(root.contains(event.target))updateBuyingGroups(event.target);
 if(root.contains(event.target)&&event.target.matches('[data-company-select]')){perform(async()=>{await companySettings.change(event.target);syncCompanySettings();});return;}
 const choice=event.target;if(choice.checked&&choice.name==='remember-device'){const shared=choice.form?.querySelector('[name=shared-device]');if(shared)shared.checked=false;}
 if(choice.checked&&choice.name==='shared-device'){const remember=choice.form?.querySelector('[name=remember-device]');if(remember)remember.checked=false;}
 if(!root.contains(event.target)||!event.target.matches('[data-profile-photo]'))return;
 const file=event.target.files?.[0],owner=user?.id;if(!file)return;
 perform(async()=>{const next=await prepareAvatar(file);if(user?.id!==owner){URL.revokeObjectURL(next.preview);return;}clearPhotoDraft();photoDraft=next;const form=root.querySelector('#profile-photo-form');if(form){form.innerHTML=photoControls();avatars.hydrate(form);}});
});
document.addEventListener('submit',event=>{if(!root.contains(event.target)||!accountForms.has(event.target.id))return;event.preventDefault();submitForm(event.target);});
function submitForm(form){const data=new FormData(form);perform(async()=>{
 if(form.id==='store-signup-form'){await storeSignup.submit(form);return;}
 if(form.id==='company-admin-invite-form'||form.id==='company-details-form'||form.id==='company-permission-form'||form.id==='company-manager-form'){await companySettings.submit(form,data);syncCompanySettings();return;}
 if(form.id==='auth-form'){
  if(view!=='reset'){deviceGuard.setShared(data.get('shared-device')==='on');personalSession.setRemember(!deviceGuard.isShared()&&data.get('remember-device')==='on');}
  if(view==='signup'){const {error}=await client.auth.signUp({email:data.get('email').trim(),password:data.get('password'),options:{data:{full_name:data.get('name').trim()},emailRedirectTo:storeSignupRequested&&emailRedirect?emailRedirect+'?store_signup=start':emailRedirect}});if(error)throw error;view='signin';authScreen();notice('Check your email to confirm your account, then sign in.');}
  else if(view==='reset'){const {error}=await client.auth.resetPasswordForEmail(data.get('email').trim(),{redirectTo:emailRedirect});if(error)throw error;notice('If an account is available, a reset link will be sent.');}
  else{const submit=form.querySelector('button[type=submit]');submit.textContent='Signing in…';try{const {data:result,error}=await client.auth.signInWithPassword({email:data.get('email').trim(),password:data.get('password')});if(error)throw error;user=result.user;if(!deviceGuard.start(user.id,{fresh:true}))return;await loadWorkspace();notice(personalSession.failed()?'Signed in for this session. Your browser could not save the login for reopening.':'Signed in.');}finally{if(submit.isConnected)submit.textContent='Sign in';}}
 }
 if(form.id==='password-form'){const {error}=await client.auth.updateUser({password:data.get('password')});if(error)throw error;if(companyInvitationId){const accepted=await client.rpc('accept_company_invitation',{invitation:companyInvitationId});if(accepted.error)throw accepted.error;companySetupRequested=true;}if(invitationId){const accepted=await client.rpc('accept_email_invitation',{invitation:invitationId});if(accepted.error)throw accepted.error;}recovering=false;history.replaceState(null,'',location.pathname);await loadWorkspace();notice(companyInvitationId?'Your password is saved and your company access is active.':invitationId?'Your password is saved and you have joined your store.':'Password updated.');}
 if(form.id==='device-form'){deviceGuard.setShared(data.get('shared-device')==='on');const saved=personalSession.setRemember(!deviceGuard.isShared()&&data.get('remember-device')==='on');if(deviceGuard.isShared())await push.disable();notice(!saved?'Your browser could not save the login. You remain signed in for this session.':deviceGuard.isShared()?'Shared-device protection is on. You will get a warning before inactivity sign-out.':personalSession.isRemembered()?'This personal device will keep you signed in until you sign out or your session expires.':'Saved login is off. You remain signed in for this session.');}
 if(form.id==='profile-photo-form'){notice('Saving your profile picture…');await savePhoto();}
 if(form.id==='profile-form'){notice('Saving your preferences…');const {error}=await client.rpc('save_my_account_preferences',{display_name:data.get('name').trim(),email_notifications:data.get('notifications')==='on',team_nickname:data.get('team_nickname').trim()||null});if(error)throw error;await loadWorkspace();notice('Profile and email preference saved.');}
 if(form.id==='join-form'){const {error}=await client.rpc('accept_invitation',{invitation_code:data.get('code').trim()});if(error)throw error;await loadWorkspace();notice('You joined your store.');}
 if(form.id==='store-form'){const {error}=await client.rpc('create_store',{store_name:data.get('name').trim(),seat_count:Number(data.get('seats'))});if(error)throw error;await loadWorkspace();notice('Store created. Invite its manager using the form below.');}
 if(form.id==='invite-form'){const submit=form.querySelector('button');submit.textContent='Sending invitation…';try{const result=await sendEmailInvitation({action:'create',store:form.dataset.store,email:data.get('email').trim(),name:data.get('name').trim(),role:data.get('role')||'employee'});await loadWorkspace();notice(result.message);}catch(error){await loadWorkspace();throw error;}finally{if(submit.isConnected)submit.textContent='Send invitation';}}
 });}
if(!client){root.innerHTML='<section class="panel account-not-configured"><h1>Account connection is not configured yet</h1><p class="muted" style="margin-top:15px">The Supabase publishable key and database setup are still needed. Follow SUPABASE_SETUP.md before using real accounts.</p><a class="text-link" href="/preview/">View the sample design preview →</a></section>';}
else{
 client.auth.onAuthStateChange((event,session)=>{
  if(sessionEnding)return;
  // Auth broadcasts cross tabs; never replace this tab’s displayed account with another identity.
  if(session?.user){let stored;try{stored=JSON.parse(personalSession.getItem(authKey)||'null')?.user?.id;}catch{}if(stored&&stored!==session.user.id||user&&user.id!==session.user.id)return;}
  user=session?.user||null;
  if(event==='PASSWORD_RECOVERY'){recovering=true;recoveryScreen();}
  if(event==='SIGNED_OUT'){endSession('expired');}
 });
 client.auth.getSession().then(async({data,error})=>{if(error)throw error;user=data.session?.user||null;if(user&&!deviceGuard.start(user.id,{fresh:callbackEntry}))return;await loadWorkspace();const reason=new URLSearchParams(location.search).get('signed_out')||startupReason;if(reason&&!user){history.replaceState(null,'',location.pathname);notice(reason==='idle'?'You were signed out after 15 minutes without activity. Saved progress is kept. Unsent drafts and unsubmitted answers were cleared.':reason==='other-tab'?'This device was signed out in another tab. Sign in with your own account.':'You are signed out. Sign in with your own account to continue.');}}).catch(error=>{recovering=false;authScreen();notice(error.message||'This sign-in link could not be opened. Ask your manager to resend the invitation.',true);});
}
