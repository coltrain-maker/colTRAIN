import {pointSummary} from './points.js';
const esc=value=>String(value??'').replace(/[&<>"']/g,c=>({'&':'&amp;','<':'&lt;','>':'&gt;','"':'&quot;',"'":'&#39;'}[c]));
const labels={foundations:'Foundations',application:'Application',expertise:'Expertise'};
const button=(label,action,extra='',secondary=false)=>`<button type="button" class="button ${secondary?'secondary':''}" data-daily-action="${action}" ${extra}>${label}</button>`;
// Small safe Markdown subset used by the approved text pilot. Raw HTML/images never execute.
export function dailyInline(text){
 const pattern=/\[([^\]\n]+)\]\((https?:\/\/[^\s)]+)\)|\*\*([^*\n]+)\*\*|`([^`\n]+)`/g;
 let result='',last=0;
 for(const match of String(text).matchAll(pattern)){
  result+=esc(String(text).slice(last,match.index));
  if(match[1])result+=`<a href="${esc(match[2])}" target="_blank" rel="noopener noreferrer">${esc(match[1])}</a>`;
  else if(match[3])result+=`<strong>${esc(match[3])}</strong>`;
  else result+=`<code>${esc(match[4])}</code>`;
  last=match.index+match[0].length;
 }
 return result+esc(String(text).slice(last));
}
export function dailyMarkdown(text){
 const lines=String(text||'').split(/\r?\n/);let html='';
 const cells=line=>line.trim().replace(/^\||\|$/g,'').split('|').map(s=>s.trim());
 for(let i=0;i<lines.length;){
  if(!lines[i].trim()){i++;continue;}
  if(lines[i].includes('|')&&/^\s*\|?\s*:?-{3,}/.test(lines[i+1]||'')){
   const headings=cells(lines[i]);i+=2;const rows=[];
   while(i<lines.length&&lines[i].trim()&&lines[i].includes('|'))rows.push(cells(lines[i++]));
   html+=`<div class="daily-table-scroll" tabindex="0" role="region" aria-label="Lesson comparison table"><table><thead><tr>${headings.map(h=>`<th scope="col">${dailyInline(h)}</th>`).join('')}</tr></thead><tbody>${rows.map(row=>`<tr>${headings.map((_,c)=>`<td>${dailyInline(row[c]||'')}</td>`).join('')}</tr>`).join('')}</tbody></table></div>`;continue;
  }
  if(/^\s*[-*] /.test(lines[i])){const items=[];while(i<lines.length&&/^\s*[-*] /.test(lines[i]))items.push(lines[i++].replace(/^\s*[-*] /,''));html+=`<ul>${items.map(t=>`<li>${dailyInline(t)}</li>`).join('')}</ul>`;continue;}
  if(/^#{1,6} /.test(lines[i])){html+=`<h3>${dailyInline(lines[i++].replace(/^#{1,6} /,''))}</h3>`;continue;}
  const paragraph=[];
  while(i<lines.length&&lines[i].trim()){if(paragraph.length&&(/^(?:\s*[-*] |#{1,6} )/.test(lines[i])||(lines[i].includes('|')&&/^\s*\|?\s*:?-{3,}/.test(lines[i+1]||''))))break;paragraph.push(lines[i++]);}
  html+=`<p>${dailyInline(paragraph.join('\n')).replace(/\n/g,'<br>')}</p>`;
 }
 return html;
}
export function createDailyDrill({client,notify,isVisible,getPoints=()=>({}),onPointsChanged=async()=>{}}){
 let store=null,workspace=null,error='',module=null,assignment=null,feedback=null,stage='read',choices={},key=null,closed=false,generation=0,visible=false,lastInteraction=Date.now(),heartbeatBusy=false,needsBaseline=true,lastPulse=Date.now();
 const events=new AbortController();
 async function rpc(name,args){const {data,error}=await client.rpc(name,args);if(error)throw new Error(error.message||'Please try again.');return data;}
 async function load(nextStore){
  if(store!==nextStore){generation++;store=nextStore;workspace=null;module=null;assignment=null;feedback=null;choices={};key=null;stage='read';}
  const own=generation;
  try{const data=await rpc('get_daily_workspace',{store});if(closed||own!==generation)return;workspace=data?.progression&&Array.isArray(data.assignments)?data:null;error=workspace?'':'The Daily Drill is not available yet.';}
  catch{if(!closed&&own===generation)error='We couldn’t load The Daily Drill. Please try again.';}
 }
 // Daily workspace summaries can include a whole team for managers; progression is always caller-specific.
 const next=()=>workspace?.assignments.find(a=>a.id===workspace.progression.next_assignment_id);
 const nextModule=()=>workspace?.modules.find(m=>m.id===next()?.module_id);
 function card(){
  if(error||!workspace)return `<section class="panel daily-dashboard" aria-labelledby="daily-heading"><h2 id="daily-heading">The Daily Drill</h2><p>${esc(error||'Your drills are on the way.')}</p>${button('Try again','reload','',true)}</section>`;
  const p=workspace.progression,m=nextModule(),a=next();const completed=Object.values(p.completed).reduce((n,c)=>n+c,0);
  const available=Object.fromEntries(Object.keys(labels).map(level=>[level,workspace.modules.filter(m=>m.skill_level===level&&m.published&&m.released&&m.sequence_position!=null).length]));
  return `<section class="panel daily-dashboard" aria-labelledby="daily-heading"><div class="section-title"><h2 id="daily-heading">The Daily Drill</h2><span class="chip gray">${workspace.daily_points??0} Daily Drill points</span></div>${m?`<div class="chips"><span class="chip">${esc(labels[m.skill_level])}</span><span class="chip gray">${esc(m.academy)}</span></div><h3>${esc(m.title)}</h3><p class="muted">About ${m.estimated_minutes} minutes · Drill ${a.sequence_position} in ${esc(labels[a.sequence_level])}</p>${button(a.started_at?'Continue your drill':'Start your drill','open',`data-assignment="${esc(a.id)}"`)}`:`<h3>${p.pathway_complete?'Your learning path is complete.':completed?'You’re caught up.':'Your drills are on the way.'}</h3><p class="muted">${p.pathway_complete?'You’ve completed Foundations, Application, and Expertise.':completed?'More training is on the way. Your progress is saved.':'New drills will appear here when they’re ready for your store.'}</p>`}<div class="daily-levels" aria-label="Your Daily Drill progress">${Object.keys(labels).map(level=>`<div><strong>${esc(labels[level])}</strong><span>${p.completed[level]} completed · ${available[level]} available</span></div>`).join('')}</div><p class="muted">Available drills unlock in order. Earn ${workspace.points_per_drill??5} points once for each completed drill; they count toward your lifetime total.</p>${completed?button('Review completed drills','history','',true):''}</section>`;
 }
 function page(){
  const top=`<div class="page-heading"><div><h1>The Daily Drill</h1><p>One skill at a time. Learn together. Grow together.</p></div>${button('Back to dashboard','home','',true)}</div>`;
  if(stage==='history'){
   // can_open is caller-specific, including for manager workspaces.
   const completed=(workspace?.assignments||[]).filter(a=>a.completed_at&&a.can_open);
   return top+`<section class="panel daily-reader"><h2>Your completed drills</h2>${completed.map(a=>{const m=workspace.modules.find(m=>m.id===a.module_id);return `<div class="daily-history-item"><div><h3>${esc(m?.title)}</h3><p>${esc(labels[a.sequence_level])} · Drill ${a.sequence_position}</p></div>${button('Review lesson','review',`data-assignment="${esc(a.id)}"`,true)}</div>`;}).join('')||'<p>No completed drills yet.</p>'}</section>`;
  }
  if(!module)return top+card();
  const heading=`<div class="chips"><span class="chip">${esc(labels[module.skill_level])}</span><span class="chip gray">${esc(module.academy)}</span></div><h2>${esc(module.title)}</h2>`;
  if(stage==='feedback'&&feedback){
   const completed=feedback.completed;
   return top+`<section class="panel daily-reader daily-feedback" aria-live="polite">${heading}<h3>${completed?'Drill complete. Well done!':'Let’s build on that.'}</h3><p>${completed?`Your completion is saved. ${feedback.new_points?`+${feedback.new_points} Daily Drill points earned.`:'Previously earned points are kept.'}`:'Review the explanation, then try again. You can revisit the lesson whenever you need.'}</p>${pointSummary(getPoints())}${feedback.feedback.map(f=>{const q=module.questions.find(q=>q.id===f.question_id);return `<div class="daily-explanation ${f.is_correct?'correct':''}"><h4>${esc(q?.prompt)}</h4><p><strong>${f.is_correct?'Correct':'Correct answer'}: ${esc(q?.options[f.correct_option])}</strong></p><p>${esc(f.explanation)}</p><p class="muted">${esc(f.teaching_reference)}</p></div>`;}).join('')}<div class="daily-actions">${completed?(workspace?.progression.next_assignment_id&&workspace.progression.next_assignment_id!==assignment.id&&!error?button('Continue to next drill','open',`data-assignment="${esc(workspace.progression.next_assignment_id)}"`):button('Back to dashboard','home')):button('Try the quick check again','quiz')}${button('Review lesson','read','',true)}</div></section>`;
  }
  if(stage==='quiz')return top+`<section class="panel daily-reader">${heading}<h3>Quick check</h3><form id="training-daily-form">${module.questions.map((q,index)=>`<fieldset><legend>${module.questions.length>1?`${index+1}. `:''}${esc(q.prompt)}</legend>${q.options.map((option,i)=>`<label class="daily-option"><input type="radio" name="${esc(q.id)}" value="${i}" ${choices[q.id]===i?'checked':''} required><span>${esc(option)}</span></label>`).join('')}</fieldset>`).join('')}<div class="daily-actions"><button class="button" type="submit">Check my answer${module.questions.length>1?'s':''}</button>${button('Review lesson','read','',true)}</div></form></section>`;
  return top+`<article class="panel daily-reader">${heading}<p class="muted">About ${module.estimated_minutes} minutes · ${assignment?.completed_at?'Completed — review anytime':'Read the lesson, then take the quick check.'}</p>${module.sections.map(s=>`<section class="daily-section"><h3>${esc(s.heading.replace(/^\d+\.\s*/,''))}</h3>${dailyMarkdown(s.content_markdown)}</section>`).join('')}${module.sources?.length?`<details class="daily-sources"><summary>Sources</summary><ul>${module.sources.map(s=>`<li>${/^https?:\/\//.test(s.url||'')?`<a href="${esc(s.url)}" target="_blank" rel="noopener noreferrer">${esc(s.publisher)} — ${esc(s.title)}</a>`:esc(s.title)}</li>`).join('')}</ul></details>`:''}<div class="daily-actions">${assignment?.completed_at?button('Review completed drills','history','',true):button('Take the quick check','quiz')}</div></article>`;
 }
 async function open(id,review=false){
  const own=generation;const loaded=await rpc('get_daily_module',{assignment:id});
  if(closed||own!==generation)return;
  module=loaded;assignment=workspace.assignments.find(a=>a.id===id);choices={};key=null;feedback=null;stage='read';
  if(!review){try{const result=await rpc('get_daily_result',{assignment:id});if(!closed&&own===generation&&result){feedback=result;stage='feedback';}}catch{/* Lesson remains usable if result recovery is temporarily unavailable. */}}
  lastInteraction=Date.now();
 }
 async function action(name,id){
  if(name==='reload'){await load(store);return;}
  if(name==='open'||name==='review'){await load(store);if(error)throw new Error(error);await open(id||workspace.progression.next_assignment_id,name==='review');return;}
  if(name==='history'){stage='history';return;}
  if(name==='quiz'){stage='quiz';choices={};key=crypto.randomUUID();return;}
  if(name==='read'){stage='read';return;}
 }
 function input(target){if(target.closest('#training-daily-form')&&target.type==='radio')choices[target.name]=Number(target.value);}
 async function submit(form){
  const data=new FormData(form);const answers=module.questions.map(q=>({question_id:q.id,option:Number(data.get(q.id))}));
  key ||= crypto.randomUUID();const own=generation;
  const result=await rpc('submit_daily_check',{assignment:assignment.id,answers,submission_key:key});
  if(closed||own!==generation)return;
  feedback=result;stage='feedback';if(result.completed)assignment.completed_at=new Date().toISOString();
  await load(store);try{await onPointsChanged();}catch{/* Saved completion remains usable; totals refresh on the dashboard. */}notify(result.completed?'Your Daily Drill completion is saved.':'Answer saved. Review the explanation and try again.');
 }
 for(const type of ['pointerdown','keydown','scroll','touchstart'])document.addEventListener(type,()=>{lastInteraction=Date.now();},{passive:true,capture:true,signal:events.signal});
 document.addEventListener('visibilitychange',()=>{needsBaseline=true;},{signal:events.signal});
 const interval=setInterval(async()=>{
  if(Date.now()-lastPulse>30000)needsBaseline=true;lastPulse=Date.now();
  if(closed||heartbeatBusy)return;
  if(!visible||!isVisible()||document.hidden||Date.now()-lastInteraction>90000||!assignment||assignment.completed_at||stage==='history'||stage==='feedback'){needsBaseline=true;return;}
  heartbeatBusy=true;try{if(needsBaseline){await rpc('get_daily_module',{assignment:assignment.id});needsBaseline=false;}else await rpc('record_daily_activity',{assignment:assignment.id});}catch{needsBaseline=true;}finally{heartbeatBusy=false;}
 },15000);
 return {load,card,page,action,input,submit,async resume(){await load(store);if(!module&&workspace?.progression.next_assignment_id)await open(workspace.progression.next_assignment_id);},setVisible(value){if(!value)needsBaseline=true;visible=value;},close(){closed=true;generation++;clearInterval(interval);events.abort();workspace=null;module=null;assignment=null;feedback=null;choices={};key=null;}};
}
