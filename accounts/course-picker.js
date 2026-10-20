import {academyLabel,courseSubtopics,filterLibrary} from './course-library.js';
const esc=value=>String(value??'').replace(/[&<>"']/g,c=>({'&':'&amp;','<':'&lt;','>':'&gt;','"':'&quot;',"'":'&#39;'}[c]));
const unique=values=>{const names=new Map();for(const value of values.filter(Boolean)){const key=value.normalize('NFKD').replace(/[\u0300-\u036f]/g,'').toLocaleLowerCase('en-US');if(!names.has(key))names.set(key,value);}return [...names.values()].sort((a,b)=>a.localeCompare(b));};
const options=(values,selected)=>values.map(value=>`<option value="${esc(value)}" ${value===selected?'selected':''}>${esc(value)}</option>`).join('');
export function pickerLists(courses,{academy='',subtopic=''}={}){
 const academies=unique(courses.map(academyLabel));
 if(!academies.includes(academy)){academy='';subtopic='';}
 const inAcademy=filterLibrary(courses,{academy});
 const subtopics=academy?unique(inAcademy.flatMap(courseSubtopics)):[];
 if(!subtopics.includes(subtopic))subtopic='';
 return {academies,subtopics,academy,subtopic,courses:filterLibrary(inAcademy,{subtopic})};
}
export function coursePicker(courses,{academy='',subtopic='',course='',allowAll=false,courseId='',courseLabel='Course'}={}){
 const lists=pickerLists(courses,{academy,subtopic});
 return `<div class="course-picker" data-course-picker data-allow-all="${allowAll}"><label class="field">Academy<select name="academy" aria-label="Academy"><option value="">All academies</option>${options(lists.academies,lists.academy)}</select></label><label class="field">Subtopic<select name="subtopic" aria-label="Subtopic" ${lists.academy?'':'disabled'}><option value="">${lists.academy?'All subtopics':'Choose an academy first'}</option>${options(lists.subtopics,lists.subtopic)}</select></label><label class="field">${esc(courseLabel)}<select name="course" aria-label="${esc(courseLabel)}" ${courseId?`id="${esc(courseId)}"`:''} ${allowAll?'':'required'}>${allowAll?'<option value="">All courses</option>':''}${lists.courses.map(c=>`<option value="${esc(c.id)}" ${c.id===course?'selected':''}>${esc(c.title)}</option>`).join('')}</select></label></div>`;
}
export function updateCoursePicker(picker,courses){
 const academy=picker.querySelector('[name=academy]'),subtopic=picker.querySelector('[name=subtopic]'),course=picker.querySelector('[name=course]');
 const lists=pickerLists(courses,{academy:academy.value,subtopic:subtopic.value});const previous=course.value;
 subtopic.innerHTML=`<option value="">${lists.academy?'All subtopics':'Choose an academy first'}</option>${options(lists.subtopics,lists.subtopic)}`;
 subtopic.disabled=!lists.academy;
 course.innerHTML=(picker.dataset.allowAll==='true'?'<option value="">All courses</option>':'')+lists.courses.map(c=>`<option value="${esc(c.id)}">${esc(c.title)}</option>`).join('');
 if(lists.courses.some(c=>c.id===previous))course.value=previous;
 return course.value;
}
