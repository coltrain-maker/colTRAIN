import test from 'node:test';
import assert from 'node:assert/strict';
import {createEmployeeLoginHandler} from '../supabase/functions/employee-login/handler.js';
function fixture({valid=true,configured=true,providerOk=true,recordError=false}={}){
 const calls=[],emails=[],jobs=[{id:'delivery-test',lease_id:'lease-test',email:'manager@example.test',title:'First login',body:'Employee signed in.'}];
 const values={COLTRAIN_APP_URL:'https://training.example',SUPABASE_URL:'https://project.example',SUPABASE_ANON_KEY:'anon-test',SUPABASE_SERVICE_ROLE_KEY:'service-test',RESEND_API_KEY:configured?'resend-test':null,COLTRAIN_EMAIL_FROM:'colTRAIN <updates@example.test>'};
 const createClient=(url,key)=>key==='service-test'?{rpc:async(name,args)=>{calls.push({name,args,service:true});return {data:name==='claim_employee_login_email'?jobs.shift()||null:null};}}:{auth:{getUser:async()=>({data:{user:valid?{id:'verified-user'}:null}})},rpc:async(name,args)=>{calls.push({name,args});return recordError?{error:{message:'Denied'}}:{data:{recorded:true}};}};
 const handler=createEmployeeLoginHandler({createClient,env:n=>values[n],pause:async()=>{},fetcher:async(url,args)=>{emails.push({url,args});return Response.json(providerOk?{id:'accepted-test'}:{error:'Rate limited'},{status:providerOk?200:429});}});
 const request=(origin='https://training.example')=>new Request('https://edge.example/employee-login',{method:'POST',headers:{Origin:origin,Authorization:'Bearer user-session'},body:JSON.stringify({actor:'attacker-selected-user',email:'attacker@example.test'})});
 return {handler,request,calls,emails};
}
test('first-login worker rejects invalid identities and foreign origins before privileged access',async()=>{
 for(const options of [{valid:false},{recordError:true}]){const f=fixture(options);assert.ok([401,403].includes((await f.handler(f.request())).status));assert.equal(f.emails.length,0);assert.ok(!f.calls.some(c=>c.service));}
 const f=fixture();assert.equal((await f.handler(f.request('https://other.example'))).status,403);assert.equal(f.calls.length,0);
});
test('worker uses verified Auth identity, queue recipient and stable provider key',async()=>{
 const f=fixture();const r=await f.handler(f.request());assert.equal(r.status,200);
 assert.equal(f.calls.find(c=>c.name==='claim_employee_login_email').args.actor,'verified-user');
 assert.deepEqual(JSON.parse(f.emails[0].args.body).to,['manager@example.test']);
 assert.equal(f.emails[0].args.headers['Idempotency-Key'],'coltrain-first-login/delivery-test');
 assert.equal(f.calls.find(c=>c.name==='finish_employee_login_email').args.success,true);
 assert.ok(!JSON.stringify(await r.json()).includes('manager@example.test'));
});
test('configuration and provider failures preserve recorded login without exposing secrets',async()=>{
 const f=fixture({configured:false});assert.equal((await (await f.handler(f.request())).json()).delivery_status,'not_configured');assert.equal(f.calls[0].name,'record_employee_first_login');assert.equal(f.emails.length,0);
 const failed=fixture({providerOk:false});const r=await failed.handler(failed.request());assert.equal((await r.json()).delivery_status,'retry_needed');assert.equal(failed.calls.find(c=>c.name==='finish_employee_login_email').args.success,false);assert.equal(failed.emails.length,1);
});
