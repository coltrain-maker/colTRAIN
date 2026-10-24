const esc=value=>String(value??'').replace(/[&<>"']/g,c=>({'&':'&amp;','<':'&lt;','>':'&gt;','"':'&quot;',"'":'&#39;'}[c]));
const mode=value=>({pilot:'No-charge pilot',legacy_no_charge:'Existing no-charge arrangement',awaiting_paid_approval:'Awaiting approval for a paid subscription'}[value]||'Billing details unavailable');
const accessLabel=value=>value==='billing'?'Billing administrator':'Training administrator';
const date=value=>new Date(value).toLocaleString();
const events={company_initialized:'Owner assigned',permission_changed:'Permission changed',ownership_transferred:'Ownership transferred',store_linked:'Store linked',pilot_changed:'Pilot status changed',company_details_updated:'Company details updated'};

export function createCompanySettings({client,notify,isPlatformAdmin=()=>false}){
 let generation=0,opened=false,companies=[],selected=null,settings=null,overview=null,stripeCheck=null;
 const cancelled=Symbol('company request cancelled');
 async function rpc(name,args={}){
  const current=generation;
  const result=await client.rpc(name,args);
  if(current!==generation)throw cancelled;
  if(result.error)throw result.error;
  return result.data;
 }
 const chosen=()=>companies.find(c=>c.company_id===selected);
 const person=id=>settings?.people?.find(p=>p.user_id===id);
 function render(){const element=document.getElementById('company-settings');if(element)element.outerHTML=html();}
 async function select(company){
  selected=company;settings=null;overview=null;
  if(chosen()?.can_administer)settings=await rpc('get_company_access_settings',{company});
 }
 async function reload(){
  companies=await rpc('get_my_company_accounts');
  const next=companies.find(c=>c.company_id===selected)||companies[0];
  if(next)await select(next.company_id);else{selected=null;settings=null;overview=null;}
 }
 function html(){
  if(!opened)return '<section class="panel" id="company-settings"><h2>Company settings</h2><p class="muted">Company details, store access, and training oversight.</p><button type="button" class="button" data-company-action="open">Open company settings</button></section>';
  const company=chosen();
  return `<section class="panel company-settings" id="company-settings"><div class="panel-top"><h2>Company settings</h2><button type="button" class="button secondary" data-company-action="refresh">Refresh</button></div>${!company?'<p class="muted">Your account does not have company ownership, billing, or company training access. Your store manager and employee permissions are unchanged.</p>':`
   ${companies.length>1?`<label>Company<select data-company-select>${companies.map(c=>`<option value="${esc(c.company_id)}" ${c.company_id===selected?'selected':''}>${esc(c.name)}</option>`).join('')}</select></label>`:`<h3>${esc(company.name)}</h3>`}
   <p class="account-note">${company.is_owner?'You are the company owner.':company.can_administer?'You are viewing this company as a colTRAIN administrator.':'Your access is limited to the stores and responsibilities listed below.'} Payment setup is coming next. No payment or subscription change can be made here yet.</p>
   <div class="company-store-list">${company.stores.map(store=>`<article class="company-store"><h3>${esc(store.name)}</h3><p>${store.can_bill?`<span>${esc(mode(store.access_mode))}</span> · Billing access`:''}${store.can_bill&&store.can_oversee_training?' · ':''}${store.can_oversee_training?'Training oversight':''}</p>${store.can_oversee_training?`<button type="button" class="button secondary" data-company-action="progress" data-store="${esc(store.store_id)}">View training progress</button>`:''}</article>`).join('')}</div>
   ${settings?management(company):''}${overview?progress():''}`}${isPlatformAdmin()?stripePanel():''}</section>`;
 }
 function stripePanel(){
  const issues={price_id_mismatch:'Price ID does not match',live_price_rejected:'Live pricing is not allowed in sandbox',price_not_active:'Price is archived',currency_mismatch:'Currency must be USD',amount_mismatch:'Monthly amount does not match',billing_interval_mismatch:'Must bill once each month',flat_package_pricing_required:'Must use flat-rate package pricing',product_not_active_in_sandbox:'Product must be active in this sandbox',key_not_accepted:'Sandbox key was not accepted',key_permission_denied:'Key cannot read these prices',price_not_found_in_sandbox:'Price was not found in this sandbox',stripe_unavailable:'Stripe could not confirm this price; try again'};
  return `<div class="company-management"><h3>Stripe sandbox connection</h3><p class="muted">Administrator setup check for the three monthly packages. This only reads Stripe configuration and does not create payments or subscriptions.</p><button class="button secondary" type="button" data-company-action="stripe-check">Check Stripe sandbox connection</button>${stripeCheck?`<p class="account-note">${stripeCheck.all_verified?'All three sandbox packages are verified.':'Some sandbox packages need attention.'} No charges were created.</p><ul>${stripeCheck.plans.map(p=>`<li><strong>${esc(p.minimum_seats)}–${esc(p.seat_limit)} seats · ${esc(new Intl.NumberFormat('en-US',{style:'currency',currency:'USD'}).format(p.unit_amount_cents/100))}/month</strong>: ${p.verified?'Verified':esc(issues[p.issue]||'Not verified')}</li>`).join('')}</ul>`:''}</div>`;
 }
 function management(company){
  const c=settings.company,owner=person(c.owner_user_id);
  return `<div class="company-management"><h3>Company details</h3><p class="muted">Owner: ${owner?esc(owner.name)+' ('+esc(owner.email)+')':'Not assigned yet'}</p>
   <form id="company-details-form"><label>Company name<input type="text" name="company_name" value="${esc(c.name)}" maxlength="120" required></label><label>Company phone<input name="company_phone" type="tel" value="${esc(c.phone)}" maxlength="50"></label><label>Buying-group affiliation (optional)<input type="text" name="affiliation" value="${esc(c.buying_group)}" maxlength="160"></label><button class="button" type="submit">Save company details</button></form>
   <h3>Authorize company access</h3><p class="muted">Use an existing, confirmed colTRAIN account. Billing and training access are separate. Granting either does not make someone a store manager or use a training seat.</p>
   <form id="company-permission-form"><label>Account email<input name="account_email" type="email" autocomplete="off" maxlength="254" required></label><label>Responsibility<select name="capability"><option value="billing">Billing administrator</option><option value="training">Training administrator</option></select></label><label>Store access<select name="store"><option value="">All company stores, including future locations</option>${company.stores.map(s=>`<option value="${esc(s.store_id)}">${esc(s.name)}</option>`).join('')}</select></label><button class="button" type="submit">Grant access</button></form>
   <h3>Authorized people</h3>${settings.permissions.length?settings.permissions.map(p=>`<div class="account-row"><div><strong>${esc(person(p.user_id)?.name||'Authorized account')}</strong><small>${esc(person(p.user_id)?.email||'')} · ${accessLabel(p.permission)} · ${esc(p.organization_id?company.stores.find(s=>s.store_id===p.organization_id)?.name||'Selected store':'All company stores')}</small></div><button class="button secondary account-danger" type="button" data-company-action="revoke" data-permission="${esc(p.id)}">Remove access</button></div>`).join(''):'<p class="muted">No additional company permissions granted.</p>'}
   <details><summary>Recent account activity</summary>${settings.audit.length?`<ul>${settings.audit.map(a=>`<li>${esc(events[a.event]||'Account updated')} · ${esc(date(a.created_at))}${a.event==='permission_changed'?` · ${esc(accessLabel(a.details.permission))} ${a.details.enabled?'granted':'removed'}`:''}</li>`).join('')}</ul>`:'<p class="muted">No activity yet.</p>'}</details></div>`;
 }
 function progress(){return `<div class="company-progress"><h3>Training progress</h3>${overview.stores.map(s=>`<h4>${esc(s.name)}</h4>${s.members.length?`<div class="company-table-scroll"><table><thead><tr><th>Employee</th><th>Courses completed</th><th>Daily Drills completed</th><th>Course points</th><th>Daily Drill points</th><th>Lifetime points</th></tr></thead><tbody>${s.members.map(m=>`<tr><th scope="row">${esc(m.name)}<small>${esc(m.role)}</small></th><td>${esc(m.completed_courses)} of ${esc(m.assigned_courses)}</td><td>${esc(m.completed_drills)}</td><td>${esc(m.points.course_points)}</td><td>${esc(m.points.daily_points)}</td><td>${esc(m.points.lifetime_points)}</td></tr>`).join('')}</tbody></table></div>`:'<p class="muted">No active team members yet.</p>'}`).join('')}<p class="account-small">Read-only overview. Store managers manage assignments and deadlines in their store dashboard.</p></div>`;}
 async function action(target){
  try{
   const action=target.dataset.companyAction;
   if(action==='open'||action==='refresh'){await reload();opened=true;}
   if(action==='stripe-check'){
    if(!isPlatformAdmin())throw new Error('colTRAIN administrator access is required.');
    const current=generation;
    const {data,error}=await client.functions.invoke('stripe-sandbox',{body:{action:'verify_configuration'}});
    if(current!==generation)throw cancelled;
    if(error){let details;try{details=await error.context?.json();}catch{}if(current!==generation)throw cancelled;throw new Error(details?.error||'The Stripe sandbox check is unavailable. Confirm the stripe-sandbox function is deployed, then try again.');}
    if(data?.environment!=='sandbox'||!Array.isArray(data.plans)||data.plans.length!==3)throw new Error('The Stripe sandbox check returned an unexpected result. Please try again.');
    stripeCheck=data;notify(data.all_verified?'Stripe sandbox packages verified. No charges were created.':'Some Stripe sandbox packages need attention.',!data.all_verified);
   }
   if(action==='progress'){
    if(!chosen()?.stores.some(s=>s.store_id===target.dataset.store&&s.can_oversee_training))throw new Error('Training access is required for this store.');
    overview=await rpc('get_company_training_overview',{company:selected,store:target.dataset.store});
   }
   if(action==='revoke'){
    const permission=settings?.permissions.find(p=>p.id===target.dataset.permission);
    if(!permission||!chosen()?.can_administer)throw new Error('Company owner access required.');
    if(!confirm('Remove this company permission? Separate store roles and any other company permissions will remain.'))return;
    await rpc('set_company_permission',{company:selected,person:permission.user_id,capability:permission.permission,enabled:false,store:permission.organization_id});
    await reload();notify('Company permission removed.');
   }
   render();
  }catch(error){if(error!==cancelled)throw error;}
 }
 async function submit(form,capturedData){
  try{
   if(!chosen()?.can_administer)throw new Error('Company owner access required.');
   const data=capturedData||new FormData(form);
   if(form.id==='company-details-form'){
    await rpc('save_company_details',{company:selected,company_name:data.get('company_name').trim(),company_phone:data.get('company_phone').trim(),affiliation:data.get('affiliation').trim()});
    await reload();notify('Company details saved.');
   }
   if(form.id==='company-permission-form'){
    await rpc('set_company_permission_by_email',{company:selected,account_email:data.get('account_email').trim(),capability:data.get('capability'),enabled:true,store:data.get('store')||null});
    await reload();notify('Company permission granted. No invitation email was sent.');
   }
   render();
  }catch(error){if(error!==cancelled)throw error;}
 }
 async function change(selectElement){
  try{if(!companies.some(c=>c.company_id===selectElement.value))return;await select(selectElement.value);render();}
  catch(error){if(error!==cancelled)throw error;}
 }
 function close(){generation++;opened=false;companies=[];selected=null;settings=null;overview=null;stripeCheck=null;}
 return {html,action,submit,change,close};
}
