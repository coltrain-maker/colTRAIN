import test from 'node:test';
import assert from 'node:assert/strict';
import {pickerLists,coursePicker} from '../accounts/course-picker.js';
import {filterLibrary} from '../accounts/course-library.js';
const courses=[
 {id:'a',title:'Drill basics',course_code:'HT-103',category:'Hardware & Tools',topics:['Drills & Drivers']},
 {id:'b',title:'Blade selection',course_code:'HT-103',category:'Hardware & Tools',topics:['Blades']},
 {id:'c',title:'Paint basics',category:'Paint & Surface Care',topics:['Sheen']}
];
test('academy and subtopic narrow courses; stale child selections clear',()=>{
 const p=pickerLists(courses,{academy:'Power Tools & Accessories',subtopic:'Drills & Drivers'});
 assert.deepEqual(p.courses,[courses[0]]);assert.deepEqual(p.subtopics,['Blades','Drills & Drivers']);
 const changed=pickerLists(courses,{academy:'Paint & Surface Care',subtopic:'Drills & Drivers'});
 assert.equal(changed.subtopic,'');assert.deepEqual(changed.courses,[courses[2]]);
 assert.deepEqual(filterLibrary(courses,{academy:p.academy,subtopic:p.subtopic,course:'a'}),[courses[0]]);
 assert.deepEqual(pickerLists([courses[2]]).academies,['Paint & Surface Care']);
});
test('course selectors escape labels and provide a general fallback for untagged courses',()=>{
 const course={id:'safe-id',title:'<img onerror=bad>',category:'Custom academy',topics:[]};
 assert.deepEqual(pickerLists([course],{academy:'Custom academy'}).subtopics,['General']);
 const html=coursePicker([course],{academy:'Custom academy',allowAll:true});
 assert.ok(html.includes('&lt;img onerror=bad&gt;'));assert.ok(!html.includes('<img'));assert.ok(html.includes('All courses'));
 assert.ok(!coursePicker([course]).includes('All courses'));
});
