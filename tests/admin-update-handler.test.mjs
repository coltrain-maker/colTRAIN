import test from 'node:test';
import assert from 'node:assert/strict';
import {createAdminUpdateHandler} from '../supabase/functions/admin-update/handler.js';
const id='80000000-0000-4000-8000-000000000001',delivery='81000000-0000-4000-8000-000000000001';
function fixture({admin=true,validUser=true,providerOk=true,configured=true}={}){
 const calls=[],emails=[],jobs=[{id:delivery,lease_id:id,email:'opted-in@example.test',title:'Update',body:'Approved message',link_url:null}];
 const envs={COLTRAIN_APP_URL:'https://training.example',SUPABASE_URL:'https://example.supabase.co',SUPABASE_ANON_KEY:'anon-test',SUPABASE_SERVICE_ROLE_KEY:'secret-test',RESEND_API_KEY:configured?'provider-test':null,COLTRAIN_EMAIL_FROM:'colTRAIN <updates@example.test>'};
 const createClient=(url,key)=>key==='secret-test'?{rpc:async(name,args)=>{calls.push({name,args,service:true});return {data:name==='claim_admin_update_email'?jobs.shift()||null:null};}}:{auth:{getUser:async()=>({data:{user:validUser?{id}:null}})},rpc:async(name,args)=>{calls.push({name,args});if(name==='get_admin_updates')return admin?{data:[{id,email_counts:{sent:1}}]}:{error:{message:'Administrator access required'}};return {data:{id,recipient_count:1}};}};
 const handler=createAdminUpdateHandler({createClient,env:n=>envs[n],pause:async()=>{},fetcher:async(url,args)=>{emails.push({url,args});return Response.json(providerOk?{id:'provider-id'}:{error:'Provider failure'},{status:providerOk?200:429});}});
 const request=(body={action:'send',payload:{submission_key:id,title:'Title',body:'Body',audience:'both',store_ids:[id]}},origin='https://training.example')=>new Request('https://edge.example/admin-update',{method:'POST',headers:{Authorization:'Bearer session-test',Origin:origin},body:JSON.stringify(body)});
 return {handler,calls,emails,request};
}
test('non-admin, invalid sessions and untrusted origins cannot create a service delivery',async()=>{
 for(const options of [{admin:false},{validUser:false}]){const f=fixture(options);const r=await f.handler(f.request());assert.ok([401,403].includes(r.status));assert.equal(f.emails.length,0);assert.ok(!f.calls.some(c=>c.service));}
 const f=fixture();assert.equal((await f.handler(f.request(undefined,'https://untrusted.example'))).status,403);assert.equal(f.calls.length,0);
});
test('email uses only the claimed recipient and a stable provider idempotency key',async()=>{
 const f=fixture();const r=await f.handler(f.request());assert.equal(r.status,200);assert.equal(f.emails.length,1);
 const email=f.emails[0];assert.equal(email.url,'https://api.resend.com/emails');assert.deepEqual(JSON.parse(email.args.body).to,['opted-in@example.test']);assert.equal(email.args.headers['Idempotency-Key'],`coltrain-admin-update/${delivery}`);
 assert.match(JSON.parse(email.args.body).text,/turn them off/);assert.match(JSON.parse(email.args.body).text,/https:\/\/training.example\/accounts\//);
 const finish=f.calls.find(c=>c.name==='finish_admin_update_email');assert.equal(finish.args.success,true);assert.equal(finish.args.provider_id,'provider-id');assert.ok(!JSON.stringify(await r.json()).includes('opted-in@example.test'));
});
test('provider errors are recorded without exposing recipient or credentials',async()=>{
 const f=fixture({providerOk:false});const r=await f.handler(f.request());assert.equal(r.status,200);assert.equal(f.calls.find(c=>c.name==='finish_admin_update_email').args.success,false);
 assert.ok(!JSON.stringify(await r.json()).includes('provider-test'));
});
test('missing sender configuration preserves the in-app update and queued email',async()=>{
 const f=fixture({configured:false});const data=await (await f.handler(f.request())).json();assert.equal(data.delivery_status,'not_configured');assert.ok(f.calls.some(c=>c.name==='send_admin_update'));assert.ok(!f.calls.some(c=>c.service));assert.equal(f.emails.length,0);
});
