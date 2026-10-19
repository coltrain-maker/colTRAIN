import test from 'node:test';
import assert from 'node:assert/strict';
import {academyPlan,academyLabel,filterLibrary,libraryTopics,libraryPaths,skillLabel} from '../accounts/course-library.js';
import {readFileSync} from 'node:fs';
const courses=[
 {title:'Paint Basics',slug:'pt-101',category:'Paint & Decorating',skill_level:'foundations',topics:['Paint'],keywords:['roller']},
 {title:'Project Consultation',course_code:'PT-201',category:'Paint & Decorating',skill_level:'application',topics:['Paint','Surface preparation'],keywords:['rollers','adhesion'],description:'Choose a suitable coating.'},
 {title:'Failure Analysis',category:'Paint & Decorating',skill_level:'expertise',topics:['Paint'],keywords:['adhesion']},
 {title:'Retail Terms',category:'Retail Foundations',keywords:['UPC'],topics:['Inventory'],learning_paths:['New Retail Employee']}
];
test('level, topic and all keyword terms combine',()=>{
 assert.deepEqual(filterLibrary(courses,{level:'application',topic:'Paint',search:'rollers coating'}),[courses[1]]);
 assert.deepEqual(filterLibrary(courses,{level:'expertise',topic:'Paint',search:'adhesion'}),[courses[2]]);
 assert.deepEqual(filterLibrary(courses,{level:'foundations',topic:'Paint',search:'adhesion'}),[]);
});
test('paths are browse filters and do not duplicate courses',()=>{
 assert.deepEqual(filterLibrary(courses,{path:'New Retail Employee',level:'foundations',search:'UPC'}),[courses[3]]);
 assert.deepEqual(libraryPaths(courses),['New Retail Employee']);
 assert.deepEqual(filterLibrary(courses,{path:'Unlisted path'}),[]);
});
test('historical launch registry preserves 25 stable courses and six paths',()=>{
 const catalog=JSON.parse(readFileSync(new URL('../courses/approved-launch-catalog.json',import.meta.url)));
 const codes=catalog.academies.flatMap(a=>a.courses.map(c=>c.code));
 assert.equal(catalog.academies.length,8);assert.equal(codes.length,25);assert.equal(new Set(codes).size,25);
 assert.equal(catalog.learning_paths.length,6);assert.equal(catalog.skill_level,'foundations');
 assert.deepEqual(catalog.learning_paths[0].core_courses,['RF-101','RF-102','RF-103','RF-104','CS-101','CS-103']);
 assert.equal(catalog.learning_paths[2].core_courses.length,0);
 for(const path of catalog.learning_paths)for(const code of [...path.core_courses,...(path.select_from||[])])assert.ok(codes.includes(code));
});
test('keywords and codes are searchable, with case and whitespace normalization',()=>{
 assert.deepEqual(filterLibrary(courses,{search:'  upc  '}),[courses[3]]);
 assert.deepEqual(filterLibrary(courses,{search:'pt-201'}),[courses[1]]);
 assert.deepEqual(filterLibrary(courses,{search:'pt-101'}),[courses[0]]);
 assert.equal(filterLibrary(courses).length,4);
});
test('topic options come only from supplied visible courses and include academy',()=>{
 assert.deepEqual(libraryTopics([courses[3]]),['Inventory','Retail Foundations']);
 assert.equal(libraryTopics(courses).filter(t=>t==='Paint').length,1);
 assert.deepEqual(libraryTopics([{category:'Customer Service',topics:['Customer service']}]),['Customer Service']);
});
test('launch course compatibility and course labels use training levels',()=>{
 assert.equal(skillLabel(courses[3]),'Level 1 — Foundations');
 assert.deepEqual(filterLibrary(courses,{level:'foundations'}),[courses[0],courses[3]]);
 assert.deepEqual(filterLibrary(courses,{topic:'paint & decorating',search:'préparation'}),[courses[1]]);
});

test('active academy allocations total 260 without creating course content',()=>{
 assert.equal(academyPlan.academies.length,10);
 const totals={foundations:0,application:0,expertise:0,total:0};
 for(const academy of academyPlan.academies){
  const p=academy.planned_modules;
  assert.equal(p.total,p.foundations+p.application+p.expertise);
  for(const key of Object.keys(totals))totals[key]+=p[key];
 }
 assert.deepEqual(totals,{foundations:88,application:112,expertise:60,total:260});
 assert.deepEqual(totals,academyPlan.planned_module_totals);
 const codes=academyPlan.academies.flatMap(a=>a.existing_course_codes);
 assert.equal(codes.length,25);assert.equal(new Set(codes).size,25);
 const old=JSON.parse(readFileSync(new URL('../courses/approved-launch-catalog.json',import.meta.url)));
 const originalCodes=old.academies.flatMap(a=>a.courses.map(c=>c.code));
 assert.deepEqual([...codes,...academyPlan.unresolved_mappings.map(m=>m.code)].sort(),originalCodes.sort());
});
test('split academies resolve from stable codes and preserve search, identity and paths',()=>{
 const courses=[
  {id:'electrical',course_code:'HB-101',category:'Home Systems & Building Materials',topics:['Home Systems & Building Materials','Wiring'],learning_paths:['Department Specialist']},
  {id:'hvac',slug:'hb-103-heating-and-cooling-fundamentals',category:'Home Systems & Building Materials'},
  {id:'power',course_code:'HT-103',category:'Hardware & Tools'},
  {id:'hand',course_code:'HT-102',category:'Hardware & Tools'}
 ];
 const snapshot=JSON.stringify(courses);
 assert.equal(academyLabel(courses[0]),'Electrical');
 assert.equal(academyLabel(courses[1]),'HVAC');
 assert.equal(academyLabel(courses[2]),'Power Tools & Accessories');
 assert.equal(academyLabel(courses[3]),'Hand Tools & Fasteners');
 assert.deepEqual(filterLibrary(courses,{topic:'Electrical',path:'Department Specialist'}),[courses[0]]);
 assert.deepEqual(filterLibrary(courses,{topic:'HVAC'}),[courses[1]]);
 assert.deepEqual(filterLibrary(courses,{search:'home systems'}),courses.slice(0,2));
 assert.deepEqual(libraryTopics(courses),['Electrical','Hand Tools & Fasteners','HVAC','Power Tools & Accessories','Wiring']);
 assert.equal(JSON.stringify(courses),snapshot);
 assert.deepEqual(libraryTopics([courses[1]]),['HVAC']);
});
test('approved safety mapping and store-specific categories preserve separate identities',()=>{
 assert.equal(academyLabel({course_code:'RF-103',category:'Retail Foundations'}),'Customer Service & Retail Readiness');
 assert.equal(academyLabel({slug:'my-store-orientation',category:'My store'}),'My store');
 assert.equal(academyLabel({slug:'customer-trust',category:'Customer Service'}),'Customer Service & Retail Readiness');
 assert.deepEqual(academyPlan.unresolved_mappings,[]);
});
