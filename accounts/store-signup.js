import configuration from '../supabase/billing/stripe-sandbox-prices.json' with {type:'json'};
const esc=v=>String(v??'').replace(/[&<>"']/g,c=>({'&':'&amp;','<':'&lt;','>':'&gt;','"':'&quot;',"'":'&#39;'}[c]));
const money=c=>new Intl.NumberFormat('en-US',{style:'currency',currency:'USD'}).format(c/100);
export function createStoreSignup({client,root,notify,navigate=url=>location.assign(url)}){
 let generation=0,user=null,available=false,record=null,key=null,timer=null,polls=0;
 const cancelled=Symbol('signup cancelled');
 async function rpc(name,args={}){const current=generation;const result=await client.rpc(name,args);if(current!==generation)throw cancelled;if(result.error)throw result.error;return result.data;}
 function render(){if(root.querySelector('#store-signup'))root.innerHTML=page();}
 function close(){generation++;clearTimeout(timer);timer=null;polls=0;user=null;record=null;key=null;available=false;}
 async function load(person){
  close();user=person;
  available=(await rpc('get_store_signup_availability'))?.enabled===true;
  if(user)record=await rpc('get_my_store_signup');
  key=crypto.randomUUID();
  if(record?.state==='checkout'&&new URLSearchParams(location.search).get('store_signup')==='return')poll();
 }
 function poll(){
  if(polls>=20||record?.state==='provisioned')return;
  const current=generation;
  timer=setTimeout(async()=>{if(current!==generation||!root.querySelector('#store-signup'))return;polls++;
   try{record=await rpc('get_my_store_signup');render();}catch{/* Manual refresh remains available if temporarily offline. */}
   if(current===generation)poll();
  },3000);
 }
 const input=(label,name,extra='')=>`<label class="field">${label}<input type="text" name="${name}" ${extra} required></label>`;
 function page(){
  const plans=`<div class="signup-plans">${configuration.plans.map(p=>`<article class="panel"><h2>${p.minimum_seats}–${p.seat_limit} seats</h2><p><strong>${money(p.unit_amount_cents)}/month</strong></p><p>14-day trial · Credit card required</p></article>`).join('')}</div><p class="muted">For 36+ seats or additional locations, contact colTRAIN for setup.</p>`;
  if(record?.state==='provisioned')return `<section id="store-signup" class="stack"><section class="panel"><h1>Your store is ready</h1><p>${esc(record.details.store_name)} has been created with its standard course library, The Daily Drill, and starter departments.</p><p>Next: choose who manages training and billing. You can keep these responsibilities or invite a separate store manager and optional additional administrators, then review departments and invite your team.</p><button class="button" data-action="signup-finish">Open your account</button></section></section>`;
  return `<section id="store-signup" class="stack"><div class="account-toolbar"><h1>Start a store trial</h1><button class="button secondary" data-action="signup-exit">Back</button>${user?'<button class="button secondary" data-action="signout">Sign out</button>':''}</div><p class="account-note">Sandbox testing only. Use Stripe’s test card 4242 4242 4242 4242, a future expiry date, and any three-digit CVC. No real payment will be taken. Commercial signup is not enabled.</p>${plans}
   ${record?`<section class="panel"><h2>${esc(record.details.store_name)}</h2><p>Your signup details are saved. Returning from checkout does not unlock training until Stripe confirmation is received.</p><div class="account-row-actions"><button class="button" data-store-signup-action="checkout">Continue to secure checkout</button><button class="button secondary" data-store-signup-action="refresh">Refresh store status</button></div><p class="account-small">If you already completed checkout, wait briefly or refresh the status. To change saved details or restart an expired checkout, contact colTRAIN support.</p></section>`:
   !available?'<section class="panel"><h2>Signup is being prepared</h2><p>Sandbox signup is not open yet. Existing store accounts remain available.</p></section>':!user?`<section class="panel"><h2>Create your owner account first</h2><p>For owners or managers authorized to purchase for a US hardware store. Employee invitations use the regular account sign-in.</p><div class="account-row-actions"><button class="button" data-action="signup-owner-account">Create owner account</button><button class="button secondary" data-action="signup-owner-signin">Sign in to continue</button></div></section>`:
   `<section class="panel"><h2>Store details</h2><p>Signed in as ${esc(user.email)}. Your account becomes the company owner.</p><form id="store-signup-form">
    ${input('Company name','company_name','maxlength="120" autocomplete="organization"')}${input('Store name','store_name','maxlength="120"')}${input('Your name','contact_name','maxlength="120" autocomplete="name"')}
    <label class="field">Company phone<input type="tel" name="phone" maxlength="50" autocomplete="tel" required></label>
    <label class="field">Buying-group affiliation (optional)<input type="text" name="buying_group" maxlength="160"></label>
    ${input('Street address','street','maxlength="200" autocomplete="street-address"')}${input('City','city','maxlength="100" autocomplete="address-level2"')}${input('State (two-letter code)','region','minlength="2" maxlength="2" autocomplete="address-level1"')}${input('ZIP code','postal_code','pattern="[0-9]{5}(-[0-9]{4})?" autocomplete="postal-code"')}<p>Country: United States</p>
    <label class="field">Store time zone<select name="time_zone">${[['America/New_York','Eastern'],['America/Chicago','Central'],['America/Denver','Mountain'],['America/Phoenix','Arizona'],['America/Los_Angeles','Pacific'],['America/Anchorage','Alaska'],['Pacific/Honolulu','Hawaii']].map(([v,l])=>`<option value="${v}">${l}</option>`).join('')}</select></label>
    <label class="field">Package<select name="plan_code">${configuration.plans.map(p=>`<option value="${p.code}">${p.minimum_seats}–${p.seat_limit} seats · ${money(p.unit_amount_cents)}/month</option>`).join('')}</select></label>
    <label class="account-checkbox"><input type="checkbox" name="become_manager" checked><span>I will also manage staff and training. This uses one training seat. Leave unchecked for ownership and billing access only.</span></label>
    <label class="account-checkbox"><input type="checkbox" name="purchase_authority" required><span>I own this business or am authorized to purchase for it.</span></label>
    <details><summary>Sandbox signup terms</summary><p>This is a test signup, not a live purchase. Stripe’s sandbox simulates a 14-day trial with a card required and monthly billing afterward at the selected package price. Use test card details only. For this test, cancellation and subscription changes are handled in Stripe’s sandbox dashboard with colTRAIN support. No live charge is authorized. The first account becomes the owner; staff access is private to the store, with company-level permissions granted separately. Canceled-store training records are intended to be retained for 12 months under the planned service policy. Final commercial terms and billing lifecycle controls will be completed before live signup.</p></details>
    <label class="account-checkbox"><input type="checkbox" name="terms_accepted" required><span>I accept these sandbox signup terms.</span></label><button class="button" type="submit">Continue to Stripe test checkout</button></form></section>`}</section>`;
 }
 async function checkout(){
  const current=generation;
  const response=await client.functions.invoke('stripe-checkout',{body:{signup_id:record.id}});
  if(current!==generation)throw cancelled;
  if(response.error){let details;try{details=await response.error.context?.json();}catch{}if(current!==generation)throw cancelled;throw new Error(details?.error||'Checkout could not be opened. Please retry.');}
  if(response.data?.ready){record=await rpc('get_my_store_signup');render();return;}
  let url;try{url=new URL(response.data?.url);}catch{throw new Error('Checkout returned an invalid link.');}
  if(url.protocol!=='https:'||url.hostname!=='checkout.stripe.com'||url.port||url.username||url.password||!url.pathname.startsWith('/c/pay/cs_test_'))throw new Error('Checkout returned an invalid sandbox link.');
  navigate(url.href);
 }
 async function submit(form){
  try{
   const data=new FormData(form),details=Object.fromEntries(data);
   for(const name of ['become_manager','purchase_authority','terms_accepted'])details[name]=data.get(name)==='on';
   const id=await rpc('prepare_store_signup',{details,submission_key:key});
   record=await rpc('get_my_store_signup');if(!record||record.id!==id)throw new Error('Signup status could not be loaded.');
   render();await checkout();
  }catch(error){if(error!==cancelled)throw error;}
 }
 async function action(target){
  try{if(target.dataset.storeSignupAction==='refresh'){record=await rpc('get_my_store_signup');render();if(record?.state!=='provisioned')notify('Store setup is still awaiting Stripe confirmation.');}
   if(target.dataset.storeSignupAction==='checkout')await checkout();
  }catch(error){if(error!==cancelled)throw error;}
 }
 return {load,page,submit,action,close};
}
