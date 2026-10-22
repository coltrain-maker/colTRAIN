import test from 'node:test';
import assert from 'node:assert/strict';
import webpush from 'web-push';
import {createECDH} from 'node:crypto';
import {createWebPushHandler} from '../supabase/functions/web-push/handler.js';
const keys=webpush.generateVAPIDKeys();
function fixture({jobs=[],identity=true,providerError=null,variables={}}={}){
 const calls=[],sends=[];
 const config={COLTRAIN_APP_URL:'https://coltrain.example/',SUPABASE_URL:'https://project.supabase.co',SUPABASE_ANON_KEY:'anon',SUPABASE_SERVICE_ROLE_KEY:'service',SUPPORT_WORKER_SECRET:'x'.repeat(40),WEB_PUSH_PUBLIC_KEY:keys.publicKey,WEB_PUSH_PRIVATE_KEY:keys.privateKey,WEB_PUSH_SUBJECT:'mailto:updates@example.test',...variables};
 const createClient=(url,key)=>key==='anon'?{auth:{getUser:async()=>({data:{user:identity?{id:'user-a'}:null}})}}:{rpc:async(name,args)=>{calls.push([name,args]);return {data:name==='claim_web_push'?jobs.shift()||null:null};}};
 const handler=createWebPushHandler({createClient,env:n=>config[n],sendNotification:async(...args)=>{sends.push(args);if(providerError)throw providerError;}});
 const request=(body={},headers={})=>handler(new Request('https://project.supabase.co/functions/v1/web-push',{method:'POST',headers:{'Content-Type':'application/json',...headers},body:JSON.stringify(body)}));
 return {request,calls,sends};
}
const worker={'x-coltrain-support-worker':'x'.repeat(40)};
const job={id:'device-a',lease:'lease-a',subscription:{endpoint:'https://web.push.apple.com/secret-endpoint',keys:{p256dh:'a',auth:'b'}},ids:['notification-a'],count:3};
test('only verified users get public configuration, never private material',async()=>{
 let f=fixture();assert.equal((await f.request({action:'config'})).status,401);
 let response=await f.request({action:'config'},{Authorization:'Bearer token',Origin:'https://coltrain.example'});assert.deepEqual(await response.json(),{public_key:keys.publicKey});assert.equal(f.calls.length,0);
 assert.equal((await f.request({action:'config'},{Authorization:'Bearer token',Origin:'https://evil.test'})).status,403);
 f=fixture({identity:false});assert.equal((await f.request({action:'config'},{Authorization:'Bearer invalid'})).status,401);
});
test('worker credential required; payload is count-only, encrypted transport uses VAPID',async()=>{
 const f=fixture({jobs:[job]});assert.equal((await f.request({}, {Authorization:'Bearer user-token'})).status,401);assert.equal(f.calls.length,0);
 assert.equal((await f.request({},worker)).status,200);assert.equal(f.sends.length,1);
 assert.deepEqual(JSON.parse(f.sends[0][1]),{count:3});assert.equal(f.sends[0][2].TTL,300);
 assert.deepEqual(f.calls.at(-2),['finish_web_push',{subscription_id:'device-a',claim_lease:'lease-a',unread_ids:job.ids,outcome:'sent'}]);
 // Exercise real library encryption/signature generation without any HTTP request.
 const recipient=createECDH('prime256v1');recipient.generateKeys();
 const encrypted=webpush.generateRequestDetails({endpoint:job.subscription.endpoint,keys:{p256dh:recipient.getPublicKey().toString('base64url'),auth:Buffer.alloc(16,7).toString('base64url')}},f.sends[0][1],f.sends[0][2]);
 assert.equal(encrypted.headers['Content-Encoding'],'aes128gcm');assert.match(encrypted.headers.Authorization,/^vapid /);assert(!encrypted.body.includes(Buffer.from('"count"')));
});
test('expiry prunes endpoint; provider failure retries; no arbitrary destinations',async()=>{
 for(const [code,outcome] of [[410,'expired'],[404,'expired'],[429,'failed'],[500,'failed']]){
  const f=fixture({jobs:[job],providerError:{statusCode:code}});await f.request({},worker);assert.equal(f.calls.find(c=>c[0]==='finish_web_push')[1].outcome,outcome);
 }
 for(const endpoint of ['https://127.0.0.1/secret','https://web.push.apple.com.evil.test/a','https://user@web.push.apple.com/a','http://web.push.apple.com/a']){
  const f=fixture({jobs:[{...job,subscription:{...job.subscription,endpoint}}]});assert.equal((await f.request({},worker)).status,500);assert.equal(f.sends.length,0);
 }
 const f=fixture({variables:{WEB_PUSH_PRIVATE_KEY:''}});assert.equal((await f.request({},worker)).status,503);assert.equal(f.calls.length,0);
});
