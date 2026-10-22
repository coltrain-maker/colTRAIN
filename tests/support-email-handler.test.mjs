import test from 'node:test';
import assert from 'node:assert/strict';
import {createSupportEmailHandler} from '../supabase/functions/team-support-email/handler.js';
function fixture({valid=true,configured=true,providerOk=true}={}){
 const calls=[],emails=[],jobs=[{id:'queue-test',lease_id:'lease-test',email:'selected-manager@example.test',thread_id:'thread-test',body:'An Emergency message is waiting in colTRAIN.'}];
 const values={COLTRAIN_APP_URL:'https://training.example',SUPABASE_URL:'https://project.example',SUPABASE_ANON_KEY:'anon-test',SUPABASE_SERVICE_ROLE_KEY:'service-test',RESEND_API_KEY:configured?'resend-test':null,COLTRAIN_EMAIL_FROM:'colTRAIN <updates@example.test>',SUPPORT_WORKER_SECRET:'fixture-private-worker-token-of-at-least-32-characters'};
 const createClient=(url,key)=>key==='service-test'?{rpc:async(name,args)=>{calls.push({name,args});return {data:name==='claim_support_email'?jobs.shift()||null:null};}}:{auth:{getUser:async()=>({data:{user:valid?{id:'verified-user'}:null}})}};
 const handler=createSupportEmailHandler({createClient,env:n=>values[n],pause:async()=>{},fetcher:async(url,args)=>{emails.push({url,args});return Response.json(providerOk?{id:'accepted-test'}:{error:'Rate limited'},{status:providerOk?200:429});}});
 const request=(extra={})=>new Request('https://edge.example/team-support-email',{method:'POST',headers:{Origin:'https://training.example',Authorization:'Bearer session-test',...extra},body:JSON.stringify({actor:'forged-user',email:'attacker@example.test'})});
 return {handler,request,calls,emails,values};
}
test('authenticated delivery scopes jobs to verified identity and selected recipient with stable idempotency',async()=>{
 const f=fixture();const r=await f.handler(f.request());assert.equal(r.status,200);assert.equal(f.calls[0].args.actor,'verified-user');
 assert.deepEqual(JSON.parse(f.emails[0].args.body).to,['selected-manager@example.test']);assert.equal(f.emails[0].args.headers['Idempotency-Key'],'coltrain-support-emergency/queue-test');
 assert.match(JSON.parse(f.emails[0].args.body).text,/support_thread=thread-test/);assert.ok(!JSON.stringify(await r.json()).includes('selected-manager@example.test'));
});
test('invalid sessions, origins and scheduler credentials never acquire privileged jobs',async()=>{
 const f=fixture({valid:false});assert.equal((await f.handler(f.request())).status,401);assert.equal(f.calls.length,0);
 const g=fixture();assert.equal((await g.handler(g.request({Origin:'https://untrusted.example'}))).status,403);assert.equal(g.calls.length,0);
 assert.equal((await g.handler(g.request({'x-coltrain-support-worker':'wrong-secret'}))).status,401);assert.equal(g.calls.length,0);
});
test('scheduler requests need the separate private worker credential and can drain global queued mail',async()=>{
 const f=fixture({valid:false});const req=new Request('https://edge.example/team-support-email',{method:'POST',headers:{'x-coltrain-support-worker':f.values.SUPPORT_WORKER_SECRET}});
 assert.equal((await f.handler(req)).status,200);assert.equal(f.calls[0].args.actor,null);assert.equal(f.emails.length,1);
});
test('missing configuration and provider rejection keep failed messages queued without reporting accepted delivery',async()=>{
 const f=fixture({configured:false});assert.equal((await (await f.handler(f.request())).json()).delivery_status,'not_configured');assert.equal(f.calls.length,0);
 const g=fixture({providerOk:false});assert.equal((await (await g.handler(g.request())).json()).delivery_status,'retry_needed');assert.equal(g.calls.find(c=>c.name==='finish_support_email').args.success,false);
});
