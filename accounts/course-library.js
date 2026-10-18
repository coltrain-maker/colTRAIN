export const skillLevels=[['foundations','Level 1 — Foundations'],['application','Level 2 — Application'],['expertise','Level 3 — Expertise']];
export const skillLabel=course=>skillLevels.find(([value])=>value===(course.skill_level||'foundations'))?.[1]||'Skill level not set';
const normalized=value=>String(value??'').normalize('NFKD').replace(/[\u0300-\u036f]/g,'').toLocaleLowerCase('en-US').trim();
export function courseTopics(course){return [...new Set([course.category,...(course.topics||[])].filter(value=>typeof value==='string'&&value.trim()).map(value=>value.trim()))];}
export function libraryTopics(courses){const names=new Map();for(const topic of courses.flatMap(courseTopics)){if(!names.has(normalized(topic)))names.set(normalized(topic),topic);}return [...names.values()].sort((a,b)=>a.localeCompare(b));}
export function libraryPaths(courses){return [...new Set(courses.flatMap(course=>course.learning_paths||[]))].sort((a,b)=>a.localeCompare(b));}
export function filterLibrary(courses,{search='',level='',topic='',path=''}={}){
 const terms=normalized(search).split(/\s+/).filter(Boolean);
 return courses.filter(course=>{
  if(level&&(course.skill_level||'foundations')!==level)return false;
  if(topic&&!courseTopics(course).some(value=>normalized(value)===normalized(topic)))return false;
  if(path&&!(course.learning_paths||[]).includes(path))return false;
  const haystack=normalized([course.title,course.description,course.slug,course.course_code,course.category,skillLabel(course),...courseTopics(course),...(course.keywords||[]),...(course.learning_paths||[])].join(' '));
  return terms.every(term=>haystack.includes(term));
 });
}
