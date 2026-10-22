import test from 'node:test';
import assert from 'node:assert/strict';
import {readFile} from 'node:fs/promises';
import vm from 'node:vm';
test('service worker keeps push content generic, badges count and opens only authenticated inbox',async()=>{
 const listeners={},shown=[],badges=[],opened=[],navigated=[];let unsubscribed=0,closed=0;
 const self={location:{origin:'https://coltrain.example'},addEventListener:(name,fn)=>listeners[name]=fn,navigator:{setAppBadge:async n=>badges.push(n),clearAppBadge:async()=>badges.push(0)},registration:{showNotification:async(...args)=>shown.push(args),getNotifications:async()=>[{close:()=>closed++}],pushManager:{getSubscription:async()=>({unsubscribe:async()=>unsubscribed++})}},clients:{matchAll:async()=>[],openWindow:async url=>opened.push(url)}};
 vm.runInNewContext(await readFile('accounts/sw.js','utf8'),{self,URL,Response,Request,fetch});
 const event=async(name,props)=>{let promise;listeners[name]({...props,waitUntil:p=>promise=p});await promise;};
 await event('push',{data:{json:()=>({count:4,body:'sensitive body',url:'https://evil.test'})}});
 assert.deepEqual(badges,[4]);assert.equal(shown[0][0],'colTRAIN');assert(!JSON.stringify(shown).includes('sensitive'));assert.equal(shown[0][1].tag,'coltrain-unread');
 await event('notificationclick',{notification:{close(){},data:{url:'https://evil.test'}}});assert.deepEqual(opened,['https://coltrain.example/accounts/?notifications=1']);
 self.clients.matchAll=async()=>[{url:'https://coltrain.example/accounts/',navigate:async u=>navigated.push(u),focus:async()=>{}}];
 await event('notificationclick',{notification:{close(){}}});assert.equal(navigated[0],opened[0]);assert.equal(opened.length,1);
 await event('push',{data:{json:()=>{throw Error();}}});assert.equal(badges.at(-1),1);
 await event('message',{data:{type:'coltrain-signout'}});assert.equal(unsubscribed,1);assert.equal(closed,1);assert.equal(badges.at(-1),0);
});
