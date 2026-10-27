const groups=['Ace','Do It Best','House Hasson','Orgil'];
const esc=value=>String(value??'').replace(/[&<>"']/g,c=>({'&':'&amp;','<':'&lt;','>':'&gt;','"':'&quot;',"'":'&#39;'}[c]));
function parse(value){
 const selected=new Set(),other=[];
 for(const line of String(value||'').split('\n').map(s=>s.trim()).filter(Boolean)){
  const match=groups.find(g=>g.toLowerCase()===line.toLowerCase());
  if(match)selected.add(match);else other.push(line.startsWith('Other: ')?line.slice(7):line);
 }
 return {selected,other:other.join('; ')};
}
export function buyingGroupsField(value=''){
 const {selected,other}=parse(value);
 return `<fieldset class="buying-groups"><legend>Buying Group Affiliation (optional)</legend><p class="account-small">Select all that apply.</p>${[...groups,'Other'].map(group=>`<label class="account-checkbox"><input type="checkbox" name="buying_groups" value="${group}" ${group==='Other'?(other?'checked':''):(selected.has(group)?'checked':'')}><span>${group}</span></label>`).join('')}<label class="field" data-buying-group-other ${other?'':'hidden'}>Who else do you buy from?<input type="text" name="buying_group_other" value="${esc(other)}" maxlength="160" ${other?'required':'disabled'}></label></fieldset>`;
}
export function updateBuyingGroups(target){
 if(target.name!=='buying_groups'||target.value!=='Other')return;
 const field=target.closest('.buying-groups')?.querySelector('[data-buying-group-other]');if(!field)return;
 field.hidden=!target.checked;
 const input=field.querySelector('input');input.disabled=!target.checked;input.required=target.checked;
 if(target.checked)input.focus();
}
export function buyingGroupsValue(data){
 const selected=new Set(data.getAll('buying_groups'));
 const values=groups.filter(g=>selected.has(g));
 if(selected.has('Other')){
  const text=String(data.get('buying_group_other')||'').trim();
  if(!text)throw new Error('Enter who you buy from under Other.');
  // A single legacy free-text affiliation round-trips without expanding it.
  values.push(values.length||groups.some(g=>g.toLowerCase()===text.toLowerCase())||text.startsWith('Other: ')?'Other: '+text:text);
 }
 const value=values.join('\n');
 if(value.length>160)throw new Error('Please shorten the Other details so all buying-group information fits within 160 characters.');
 return value;
}
