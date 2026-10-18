import test from 'node:test';
import assert from 'node:assert/strict';
import {filterLibrary,libraryTopics,libraryPaths,skillLabel} from '../accounts/course-library.js';
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
test('approved catalog preserves 25 distinct courses, eight academies and six paths',()=>{
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
