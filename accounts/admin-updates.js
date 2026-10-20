const esc=v=>String(v??'').replace(/[&<>"']/g,c=>({'&':'&amp;','<':'&lt;','>':'&gt;','"':'&quot;',"'":'&#39;'}[c]));
const labels={manager:'Managers only',employee:'Employees only',both:'Managers and employees'};
const button=(label,action,id='')=>`<button type="button" class="button secondary" data-admin-update-action="${action}" data-update="${esc(id)}">${label}</button>`;
export function createAdminUpdates({client,stores,currentStore,notify}){
 let history=[],preview=null,closed=false,draft={title:'',body:'',audience:'both',store_ids:[currentStore],all_stores:false,link_url:null},submission=crypto.randomUUID();
 async function rpc(name,args={}){const r=await client.rpc(name,args);if(r.error)throw new Error(r.error.message);return r.data;}
 async function load(){const rows=await rpc('get_admin_updates');if(!closed)history=rows;}
 function capture(form){
  if(!form||form.id!=='training-admin-update-form')return;
  const data=new FormData(form),all=data.get('scope')==='all';
  const next={title:data.get('title').trim(),body:data.get('body').trim(),audience:data.get('audience'),store_ids:all?[]:data.getAll('store').sort(),all_stores:all,link_url:data.get('link_url').trim()||null};
  if(JSON.stringify(next)!==JSON.stringify(draft)){draft=next;submission=crypto.randomUUID();preview=null;}
  const fieldset=form.querySelector('[data-update-stores]');if(fieldset)fieldset.disabled=all;
 }
 function page(){
  const compose=preview?`<section class="panel"><h2>Review your update</h2><h3>${esc(draft.title)}</h3><p class="admin-update-body">${esc(draft.body)}</p>${draft.link_url?`<p>${esc(draft.link_url)}</p>`:''}<p><strong>${esc(labels[draft.audience])}</strong> · ${draft.all_stores?'To all stores':'Select individual stores'}</p><p>${preview.recipient_count} in-app recipients · ${preview.email_count} opted-in email recipients. Counts may change before sending.</p><ul>${preview.stores.map(s=>`<li>${esc(s.name)}: ${s.managers} managers, ${s.employees} employees</li>`).join('')}</ul><div class="notification-actions">${button('Edit update','edit')}<button type="button" class="button" data-admin-update-action="send">Send update</button></div></section>`:`<section class="panel"><h2>Create an update</h2><form id="training-admin-update-form"><label class="field">Title<input name="title" maxlength="150" required value="${esc(draft.title)}"></label><label class="field">Message<textarea name="body" maxlength="6000" required>${esc(draft.body)}</textarea></label><label class="field">Who should receive this?<select name="audience">${Object.entries(labels).map(([value,label])=>`<option value="${value}" ${draft.audience===value?'selected':''}>${label}</option>`).join('')}</select></label><fieldset><legend>Stores</legend><label class="training-check"><input type="radio" name="scope" value="all" ${draft.all_stores?'checked':''}>To all stores</label><label class="training-check"><input type="radio" name="scope" value="selected" ${draft.all_stores?'':'checked'}>Select individual stores</label><fieldset data-update-stores ${draft.all_stores?'disabled':''}><legend>Choose stores</legend>${stores.map(s=>`<label class="training-check"><input type="checkbox" name="store" value="${esc(s.id)}" ${draft.store_ids.includes(s.id)?'checked':''}>${esc(s.name)}</label>`).join('')}</fieldset></fieldset><label class="field">Optional link<input type="url" name="link_url" maxlength="2048" placeholder="https://" value="${esc(draft.link_url||'')}"></label><p class="muted">Everyone selected receives an in-app update. Email goes only to recipients who have allowed email notifications. This does not post to a store’s Team Corner.</p><button class="button" type="submit">Preview recipients</button></form></section>`;
  return `<div class="page-heading"><div><h1>Admin updates</h1><p>Share news with the right people and stores.</p></div></div>${compose}<section class="panel"><div class="panel-top"><h2>Previous updates</h2>${button('Refresh delivery status','refresh')}</div>${history.length?history.map(a=>`<article class="admin-update-history"><h3>${esc(a.title)}</h3><p class="admin-update-body">${esc(a.body)}</p><p>${esc(labels[a.audience])} · ${a.all_stores?'To all stores':a.stores.map(esc).join(', ')}</p><p>${a.recipient_count} in-app recipients · ${a.read_count} read · ${a.email_counts?.sent||0} email requests accepted</p><p class="muted">${a.email_counts?.queued||0} queued · ${a.email_counts?.failed||0} failed · ${a.email_counts?.working||0} processing · ${a.email_counts?.canceled||0} canceled · ${a.email_counts?.review||0} need review</p>${a.archived_at?'<span class="chip gray">Archived</span>':`<div class="notification-actions">${button('Archive update','archive',a.id)}${['queued','failed','working'].some(k=>a.email_counts?.[k])?button('Retry email delivery','deliver',a.id):''}</div>`}</article>`).join(''):'<p>No admin updates sent yet.</p>'}</section>`;
 }
 async function prepare(form){capture(form);preview=await rpc('preview_admin_update',draft);}
 async function deliver(body){
  let result;
  for(let round=0;round<50;round++){
   const r=await client.functions.invoke('admin-update',{body});
   if(r.error)throw new Error('Delivery could not be confirmed. Refresh delivery status before retrying; your update will not be duplicated.');
   result=r.data;if(result.error)throw new Error(result.error);
   if(closed)return;
   const counts=result.update?.email_counts||{};
   if(result.delivery_status==='not_configured'||counts.failed||!counts.queued||!result.processed)break;
   notify(`Update saved. ${counts.sent||0} email requests accepted; ${counts.queued} queued.`);
   body={action:'deliver',update_id:result.id};
  }
  if(closed)return;
  await load();if(closed)return;
  const counts=result.update?.email_counts||{};
  notify(result.delivery_status==='not_configured'&&counts.queued?'In-app update saved. Email delivery needs configuration; messages remain queued.':counts.failed?'In-app update saved. Some emails failed; check delivery status and retry.':'Update saved. Check delivery status for email progress.',Boolean(counts.failed||result.delivery_status==='not_configured'&&counts.queued));
  return result;
 }
 async function action(name,id){
  if(name==='edit'){preview=null;return;}
  if(name==='refresh'){await load();return;}
  if(name==='archive'){await rpc('archive_admin_update',{update_id:id});await load();return;}
  if(name==='deliver'){await deliver({action:'deliver',update_id:id});return;}
  if(name==='send'){const result=await deliver({action:'send',payload:{...draft,submission_key:submission}});if(result&&!closed){preview=null;draft={title:'',body:'',audience:'both',store_ids:[currentStore],all_stores:false,link_url:null};submission=crypto.randomUUID();}}
 }
 return {page,load,capture,prepare,action,close(){closed=true;history=[];draft={};preview=null;}};
}
