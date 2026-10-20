import test from 'node:test';
import assert from 'node:assert/strict';
import {dailyMarkdown,dailyInline} from '../accounts/daily-drill.js';
test('approved lesson Markdown supports readable tables, lists and emphasis',()=>{
 const html=dailyMarkdown('**Sheen** is shine.\n\n| Finish | Appearance |\n|---|---|\n| Flat | Low shine |\n\n- Ask first\n- Check the label');
 assert.match(html,/<strong>Sheen<\/strong>/);assert.match(html,/<th scope="col">Finish/);assert.match(html,/<td>Low shine<\/td>/);assert.match(html,/<li>Check the label<\/li>/);
});
test('Markdown escapes HTML and refuses executable and image links',()=>{
 const html=dailyMarkdown('<img src=x onerror=alert(1)>\n\n[click](javascript:alert(1))\n\n![missing](file:///secret)');
 assert.ok(!html.includes('<img'));assert.ok(!html.includes('<script'));assert.ok(!html.includes('href='));assert.match(html,/&lt;img/);
 assert.equal(dailyInline('[Source](https://example.test/?a=1&b=2)'),'<a href="https://example.test/?a=1&amp;b=2" target="_blank" rel="noopener noreferrer">Source</a>');
});

import {createDailyDrill} from '../accounts/daily-drill.js';
const progress={next_assignment_id:null,completed:{foundations:0,application:0,expertise:0},planned:{foundations:88,application:112,expertise:60},pathway_complete:false};
test('Daily state handles unavailable content, stale store responses and sign-out cleanup',async()=>{
 const original=globalThis.document;globalThis.document=new EventTarget();
 let resolveOld;
 const client={rpc:async(name,args)=>args.store==='old'?new Promise(resolve=>resolveOld=resolve):{data:{modules:[],assignments:[],progression:progress}}};
 const drill=createDailyDrill({client,notify(){},isVisible:()=>false});
 try{
  const pending=drill.load('old');await drill.load('new');
  resolveOld({data:{modules:[{title:'Old store secret'}],assignments:[],progression:progress}});await pending;
  assert.ok(!drill.card().includes('Old store secret'));assert.match(drill.card(),/Your drills are on the way/);
  drill.close();assert.ok(!drill.page().includes('Old store secret'));
 }finally{drill.close();globalThis.document=original;}
});
test('Daily activity pauses when hidden, idle or outside the reader, resets baseline before resuming',async()=>{
 const originalDocument=globalThis.document,originalInterval=globalThis.setInterval,originalClear=globalThis.clearInterval,originalNow=Date.now;
 const doc=new EventTarget();doc.hidden=false;globalThis.document=doc;
 let tick,clock=1000,visible=true;Date.now=()=>clock;
 globalThis.setInterval=fn=>{tick=fn;return 123;};globalThis.clearInterval=()=>{};
 const calls=[];const assignment={id:'a',module_id:'m',sequence_position:1,sequence_level:'foundations'};
 const client={rpc:async(name)=>{calls.push(name);return {data:name==='get_daily_workspace'?{modules:[],assignments:[assignment],progression:{...progress,next_assignment_id:'a'}}:name==='get_daily_module'?{questions:[],sections:[]}:null};}};
 const drill=createDailyDrill({client,notify(){},isVisible:()=>visible});
 try{
  await drill.load('store');await drill.action('open','a');drill.setVisible(true);calls.length=0;
  await tick();await tick();assert.deepEqual(calls,['get_daily_module','record_daily_activity']);
  doc.hidden=true;await tick();assert.equal(calls.length,2);
  doc.hidden=false;await tick();assert.equal(calls.at(-1),'get_daily_module');
  clock+=100000;await tick();assert.equal(calls.length,3);
  doc.dispatchEvent(new Event('pointerdown'));await tick();assert.equal(calls.at(-1),'get_daily_module');
  visible=false;await tick();assert.equal(calls.length,4);
  drill.close();visible=true;await tick();assert.equal(calls.length,4);
 }finally{drill.close();globalThis.document=originalDocument;globalThis.setInterval=originalInterval;globalThis.clearInterval=originalClear;Date.now=originalNow;}
});
