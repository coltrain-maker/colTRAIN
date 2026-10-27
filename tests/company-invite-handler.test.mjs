import test from 'node:test';
import assert from 'node:assert/strict';
import {createCompanyInviteHandler} from '../supabase/functions/invite-company-admin/handler.js';
const company='10000000-0000-0000-0000-000000000001', invitation='40000000-0000-0000-0000-000000000001';
function fixture(options={}) {
 const calls=[];
 const env=name=>({COLTRAIN_APP_URL:options.appUrl??'https://training.example',SUPABASE_URL:'https://project.supabase.co',SUPABASE_ANON_KEY:'public-test-key',SUPABASE_SERVICE_ROLE_KEY:'server-test-key'})[name];
 const caller={auth:{getUser:async()=>options.invalidSession?{error:{message:'Invalid'}}:{data:{user:{id:'manager-id'}}}},rpc:async(name,args)=>{calls.push(['rpc',name,args]);return options.rpcError?{error:{message:options.rpcError}}:{data:{id:invitation,email:'employee@example.test',name:'Employee Name'}};}};
 const server={auth:{admin:{inviteUserByEmail:async(email,opts)=>{calls.push(['invite',email,opts]);return {error:options.emailError||null};}},resetPasswordForEmail:async(email,opts)=>{calls.push(['recover',email,opts]);return {error:options.recoveryError||null};}},rpc:async(name,args)=>{calls.push(['status',args,name]);return {error:options.statusError||null};}};
 const createClient=(url,key,config)=>{calls.push(['client',key,config]);return key==='server-test-key'?server:caller;};
 const handle=createCompanyInviteHandler({createClient,env,log:details=>calls.push(['log',details])});
 const send=(body={action:'create',company,capability:'training',email:'employee@example.test',name:'Employee Name'},headers={Origin:'https://training.example',Authorization:'Bearer caller-session'})=>handle(new Request('https://project.supabase.co/functions/v1/invite-company-admin',{method:'POST',headers:{'Content-Type':'application/json',...headers},body:JSON.stringify(body)}));
 return {calls,send,handle};
}
test('company invitation authorizes caller before privileged email; redirect and recipient are server owned',async()=>{
 const f=fixture();const response=await f.send({action:'create',company,capability:'training',email:'untrusted@example.test',name:'Untrusted name',redirectTo:'https://attacker.example'});
 assert.equal(response.status,200);
 assert.equal(response.headers.get('access-control-allow-origin'),'https://training.example');
 assert.equal(f.calls[0][2].global.headers.Authorization,'Bearer caller-session');
 assert.ok(f.calls.findIndex(c=>c[0]==='rpc')<f.calls.findIndex(c=>c[0]==='invite'));
 const email=f.calls.find(c=>c[0]==='invite');
 assert.equal(email[1],'employee@example.test');
 assert.deepEqual(email[2],{redirectTo:'https://training.example/accounts/?company_invitation_id='+invitation,data:{full_name:'Employee Name'}});
 assert.deepEqual(f.calls.find(c=>c[0]==='status')[1],{invitation,delivery_status:'sent'});
 assert.ok(!(await response.text()).includes('server-test-key'));
});
test('invalid session never creates privileged client or emails',async()=>{
 const f=fixture({invalidSession:true});assert.equal((await f.send()).status,401);assert.equal(f.calls.length,1);
});
test('company permission, scope, role and throttle failures never email',async()=>{
 for(const rpcError of ['Company owner access required','Choose administrator access','Store is not in this company','Wait one minute before resending']) {
  const f=fixture({rpcError});assert.equal((await f.send()).status,400);assert.ok(!f.calls.some(c=>c[0]==='invite'||(c[0]==='client'&&c[1]==='server-test-key')));
 }
});
test('existing account receives recovery email at same fixed callback',async()=>{
 const f=fixture({emailError:{code:'email_exists'}});assert.equal((await f.send()).status,200);
 assert.equal(f.calls.find(c=>c[0]==='recover')[2].redirectTo,'https://training.example/accounts/?company_invitation_id='+invitation);
});
test('email failures preserve pending invitation and report failure instead of success',async()=>{
 const f=fixture({emailError:{code:'unexpected_failure',message:'Internal provider details'}});const response=await f.send();assert.equal(response.status,502);
 assert.deepEqual(f.calls.find(c=>c[0]==='status')[1],{invitation,delivery_status:'failed'});
 assert.ok(!f.calls.some(c=>c[0]==='recover'));assert.ok(!(await response.text()).includes('Internal provider details'));
});
test('resend invokes database with original invitation ID',async()=>{
 const f=fixture();assert.equal((await f.send({action:'resend',company,invitation})).status,200);
 assert.equal(f.calls.find(c=>c[0]==='rpc')[2].replace_invitation,invitation);
});
test('origin restrictions, missing session and invalid input prevent any email work',async()=>{
 for(const headers of [{Origin:'null',Authorization:'Bearer session'},{Origin:'https://attacker.example',Authorization:'Bearer session'},{Origin:'https://training.example'}]) {
  const f=fixture();assert.ok((await f.send(undefined,headers)).status>=400);assert.equal(f.calls.length,0);
 }
 const f=fixture();assert.equal((await f.send({action:'create',company,capability:'training',name:'',email:'x@example.test'})).status,400);
 assert.ok(!f.calls.some(c=>c[0]==='invite'));
});
test('localhost and missing deployment configuration cannot produce localhost emails',async()=>{
 for(const appUrl of ['', 'http://localhost:3000','https://localhost','https://training.example/accounts/']) {
  const f=fixture({appUrl});assert.equal((await f.send()).status,503);assert.equal(f.calls.length,0);
 }
});

test('429 email limit is distinguished and its failed status is recorded',async()=>{
 const f=fixture({emailError:{code:'over_email_send_rate_limit',status:429}});
 const response=await f.send();assert.equal(response.status,429);
 assert.match((await response.json()).error,/sending limit/);
 const saved=f.calls.find(c=>c[0]==='status');
 assert.equal(saved[2],'record_company_invitation_email');
 assert.equal(saved[1].delivery_status,'failed');
 assert.ok(!f.calls.some(c=>c[0]==='recover'));
});
test('restricted sender is explained without exposing provider details',async()=>{
 const f=fixture({emailError:{code:'email_address_not_authorized'}});
 const response=await f.send();assert.equal(response.status,502);
 assert.match((await response.json()).error,/not configured to send to this address/);
});
test('accepted email plus failed status write does not encourage sending a duplicate',async()=>{
 const f=fixture({statusError:{code:'42501'}});
 const response=await f.send();assert.equal(response.status,200);
 assert.match((await response.json()).message,/email requested, but its status could not be saved/);
 assert.deepEqual(f.calls.find(c=>c[0]==='log')[1],{event:'delivery_status_failed',invitation_id:invitation,code:'42501'});
 assert.equal(f.calls.filter(c=>c[0]==='invite').length,1);
});
