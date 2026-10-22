const esc=value=>String(value??'').replace(/[&<>"']/g,c=>({'&':'&amp;','<':'&lt;','>':'&gt;','"':'&quot;',"'":'&#39;'}[c]));
const labels={emergency:'Emergency',work:'Work related',app:'App related',customer:'Customer',general:'General',other:'Other'};
const when=value=>new Intl.DateTimeFormat('en-US',{month:'short',day:'numeric',hour:'numeric',minute:'2-digit'}).format(new Date(value));
const button=(text,action,extra='',kind='secondary')=>`<button type="button" class="button ${kind}" data-support-action="${action}" ${extra}>${text}</button>`;
const empty=()=>({key:crypto.randomUUID(),recipient:'',subject:'',category:'general',body:'',emergency:false});
export function createTeamSupport({client,notify}){
 let store=null,workspace=null,folder='inbox',keywords='',page=0,detail=null,compose=false,newDraft=empty(),replies=new Map(),closed=false,generation=0;
 const rpc=async(name,args)=>{const r=await client.rpc(name,args);if(r.error)throw new Error(r.error.message||'The private message could not be loaded.');return r.data;};
 const currentReply=()=>{if(!detail)return empty();let d=replies.get(detail.thread.id);if(!d){d=empty();replies.set(detail.thread.id,d);}return d;};
 async function deliver(){try{const r=await client.functions.invoke('team-support-email',{body:{}});return !r.error&&r.data?.delivery_status==='processed';}catch{return false;}}
 async function load(nextStore){
  if(store!==nextStore){generation++;store=nextStore;workspace=null;detail=null;compose=false;newDraft=empty();replies.clear();folder='inbox';keywords='';page=0;}
  const own=generation;const data=await rpc('get_team_support_workspace',{store,folder,keywords,page});if(closed||own!==generation)return;workspace=data;
 }
 async function open(id,markRead=true){
  const own=generation;const d=await rpc('get_team_support_thread',{thread:id});if(closed||own!==generation)return;
  detail=d;compose=false;
  if(markRead&&d.messages.length){const remaining=await rpc('mark_team_support_read',{thread:id,through_seq:d.read_through,from_seq:d.messages[0].seq});if(closed||own!==generation)return;await load(store);detail.thread.unread_count=remaining;}
 }
 function controls(t){return `${t.unread_count?button('Mark as read','read',`data-thread="${t.id}"`):''}${t.can_manage?t.deleted_at?button('Restore conversation','restore',`data-thread="${t.id}"`):`${button(t.archived_at?'Move to inbox':'Archive',t.archived_at?'unarchive':'archive',`data-thread="${t.id}"`)}${button('Delete','delete',`data-thread="${t.id}"`,'secondary account-danger')}`:''}`;}
 function editor(){const d=newDraft;return `<section class="panel support-editor"><h2>New private message</h2><p class="muted">Only you and the selected person can read this conversation.</p><form id="training-support-new" data-support-form="new"><label class="field">${workspace.is_manager?'Employee':'Manager'}<select name="recipient" required><option value="">Choose ${workspace.is_manager?'an employee':'a manager'}</option>${workspace.recipients.map(p=>`<option value="${p.id}" ${d.recipient===p.id?'selected':''}>${esc(p.name)}</option>`).join('')}</select></label><label class="field">Category<select name="category">${Object.entries(labels).map(([v,l])=>`<option value="${v}" ${d.category===v?'selected':''}>${l}</option>`).join('')}</select></label><label class="field">Subject<input name="subject" value="${esc(d.subject)}" maxlength="150" required></label><label class="field">Message<textarea name="body" rows="5" maxlength="5000" required>${esc(d.body)}</textarea></label><p class="account-small">Emergency messages also email the selected manager, even if optional email is off. For immediate help, contact your manager directly.</p><div class="support-actions"><button class="button" type="submit">Send private message</button>${button('Cancel','cancel')}</div></form>${!workspace.recipients.length?'<p class="account-danger">There are no active recipients available. Contact your store manager.</p>':''}</section>`;}
 function conversation(){
  if(!detail)return '<section class="panel"><h2>Choose a conversation</h2><p class="muted">Open a message or start a new private conversation.</p></section>';
  const t=detail.thread,d=currentReply(),counts=detail.email_counts||{};
  return `<section class="panel support-conversation"><div class="panel-top"><div><h2>${esc(t.subject)}</h2><p class="muted">${esc(t.employee_name)} ↔ ${esc(t.manager_name)}</p></div><span class="chip ${t.has_emergency?'amber':'gray'}">${esc(labels[t.category])}${t.has_emergency&&t.category!=='emergency'?' · Emergency reply':''}</span></div><p class="account-small">Private to these two participants.${t.deleted_at?' In Trash—recoverable for 30 days.':t.archived_at?' Archived. A reply moves this conversation back to the inbox.':''}</p><div class="support-actions">${button('Refresh conversation','refresh-thread',`data-thread="${t.id}"`)}${controls(t)}</div>${Object.keys(counts).length?`<p class="support-email-status" role="status">Emergency email: ${counts.sent||0} request${counts.sent===1?'':'s'} accepted · ${(counts.queued||0)+(counts.failed||0)+(counts.working||0)} pending${counts.review?` · ${counts.review} need delivery review`:''}${counts.canceled?` · ${counts.canceled} canceled`:''}. Email acceptance does not confirm inbox delivery.</p>${!t.deleted_at&&((counts.queued||0)+(counts.failed||0)+(counts.working||0)>0)?button('Retry emergency email','retry-email'):''}`:''}<div class="support-message-history">${detail.has_older?button('Load earlier messages','older'):''}${detail.messages.map(m=>`<article class="support-message ${m.author_member===workspace.my_membership?'support-message-own':''}"><div class="panel-top"><strong>${esc(m.author_name)}</strong><small>${when(m.created_at)}</small></div>${m.emergency?'<span class="chip amber">Emergency</span>':''}<p>${esc(m.body)}</p></article>`).join('')}</div>${t.can_reply?`<form id="training-support-reply" data-support-form="reply"><label class="field">Reply<textarea name="body" rows="4" maxlength="5000" required>${esc(d.body)}</textarea></label>${t.category==='emergency'?'<p class="account-small">Replies in this Emergency conversation also email the selected manager.</p>':`<label class="training-check"><input type="checkbox" name="emergency" ${d.emergency?'checked':''}>Mark this reply as Emergency and email the selected manager</label>`}<button class="button" type="submit">Send reply</button></form>`:!t.deleted_at?'<p class="muted">A participant is no longer active. This conversation remains available for review; start a new conversation with an active person for help.</p>':''}</section>`;
 }
 function html(){
  if(!workspace)return '<section class="panel"><h1>Team support</h1><p>Loading private conversations…</p></section>';
  return `<div class="page-heading"><div><h1>Team support</h1><p>Private conversations between an employee and their selected manager.</p></div>${button('New message','new','','')}</div><div class="support-folders tabs">${['inbox','archive',...(workspace.is_manager?['trash']:[])].map(f=>`<button type="button" class="tab ${folder===f?'active':''}" data-support-action="folder" data-folder="${f}">${f[0].toUpperCase()+f.slice(1)}</button>`).join('')}${button('Refresh messages','refresh')}</div><form class="panel support-search" id="training-support-search" data-support-form="search"><label class="field">${folder==='archive'?'Search archived messages':'Search messages'}<input type="search" name="keywords" value="${esc(keywords)}" maxlength="200" placeholder="Subject, message, or reply keywords"></label><button class="button" type="submit">Search</button></form>${folder==='trash'?'<p class="muted">Deleted conversations can be restored for 30 days. After that they are permanently removed.</p>':''}<div class="support-layout"><aside class="support-list stack" aria-label="Private conversations">${workspace.threads.map(t=>`<article class="panel support-thread-row ${t.unread_count?'support-unread':''}">${button(esc(t.subject),'open',`data-thread="${t.id}"`)}<p>${esc(workspace.my_membership===t.manager_id?t.employee_name:t.manager_name)}</p><small>${esc(labels[t.category])} · ${when(t.updated_at)}</small>${t.unread_count?`<span class="chip">${t.unread_count} unread</span>`:''}<p class="support-excerpt">${esc(t.last_body)}</p><div class="support-actions">${controls(t)}</div></article>`).join('')||'<section class="panel"><p>No conversations in this view.</p></section>'}<div class="support-actions">${page?button('Previous page','previous'):''}${workspace.has_more?button('Next page','next'):''}</div></aside>${compose?editor():conversation()}</div>`;
 }
 function input(target){const form=target.closest('[data-support-form]');if(!form)return;const d=form.dataset.supportForm==='new'?newDraft:form.dataset.supportForm==='reply'?currentReply():null;if(d&&target.name in d)d[target.name]=target.type==='checkbox'?target.checked:target.value;}
 async function submit(form){
  const fields=new FormData(form);
  if(form.dataset.supportForm==='search'){keywords=fields.get('keywords').trim();page=0;detail=null;compose=false;await load(store);return;}
  const fresh=form.dataset.supportForm==='new',draft=fresh?newDraft:currentReply();
  const saved=await rpc('send_team_support_message',{store,submission_key:draft.key,message_body:fields.get('body').trim(),thread:fresh?null:detail.thread.id,recipient:fresh?fields.get('recipient'):null,category:fresh?fields.get('category'):'general',subject:fresh?fields.get('subject').trim():null,emergency:fields.get('emergency')==='on'});
  if(closed)return;
  if(fresh)newDraft=empty();else replies.delete(saved.thread_id);
  const accepted=saved.emergency?await deliver():true;
  folder='inbox';page=0;keywords='';await load(store);await open(saved.thread_id);
  notify(saved.emergency?accepted?'Private message saved. Emergency email requests processed; check delivery status below.':'Private message saved. Emergency email is pending—use Retry emergency email.':'Private message saved. The recipient has an in-app notification.');
 }
 async function action(name,id,selectedFolder){
  if(name==='new'){compose=true;return;}
  if(name==='cancel'){compose=false;return;}
  if(name==='folder'){folder=selectedFolder;page=0;keywords='';detail=null;compose=false;await load(store);return;}
  if(name==='next'||name==='previous'){page+=name==='next'?1:-1;await load(store);return;}
  if(name==='open'||name==='refresh-thread'){await open(id);return;}
  if(name==='refresh'){await load(store);if(detail)await open(detail.thread.id);return;}
  if(name==='read'){const d=await rpc('get_team_support_thread',{thread:id});const remaining=await rpc('mark_team_support_read',{thread:id,through_seq:d.read_through});await load(store);if(detail?.thread.id===id)detail.thread.unread_count=remaining;return;}
  if(name==='retry-email'){await deliver();if(detail)await open(detail.thread.id,false);return;}
  if(name==='older'){
   const d=await rpc('get_team_support_thread',{thread:detail.thread.id,before_seq:detail.messages[0].seq});detail.messages=[...d.messages,...detail.messages];detail.has_older=d.has_older;
   if(d.messages.length){detail.thread.unread_count=await rpc('mark_team_support_read',{thread:detail.thread.id,through_seq:d.read_through,from_seq:d.messages[0].seq});await load(store);}return;
  }
  if(['archive','unarchive','delete','restore'].includes(name)){
   if(name==='delete'&&!confirm('Move this private conversation to Trash? It will be hidden from both participants and can be restored by the selected manager for 30 days.'))return;
   await rpc('set_team_support_state',{thread:id,action:name});if(detail?.thread.id===id)detail=null;await load(store);notify(name==='delete'?'Conversation moved to Trash for 30 days.':name==='restore'?'Conversation restored.':name==='archive'?'Conversation archived.':'Conversation moved to inbox.');
  }
 }
 function close(){closed=true;generation++;workspace=null;detail=null;newDraft=empty();replies.clear();}
 return {load,open,html,input,submit,action,close,deliver};
}
