import test from 'node:test';
import assert from 'node:assert/strict';
import {readFile} from 'node:fs/promises';
import {createStripeSandboxHandler} from '../supabase/functions/stripe-sandbox/handler.ts';
import configuration from '../supabase/billing/stripe-sandbox-prices.json' with {type:'json'};

function fixture({admin=true,validUser=true,key='sk_test_local_example_never_real',mutate=()=>{},status=200,throwFetch=false,adminError=false}={}){
 const calls=[],queries=[],envReads=[];
 const values={COLTRAIN_APP_URL:'https://training.example',SUPABASE_URL:'https://project.example',SUPABASE_ANON_KEY:'anon-local-test',STRIPE_SANDBOX_SECRET_KEY:key};
 const createClient=(url,publicKey,options)=>{
  assert.equal(url,values.SUPABASE_URL);assert.equal(publicKey,values.SUPABASE_ANON_KEY);
  assert.equal(options.global.headers.Authorization,'Bearer user-session');
  assert.equal(options.auth.persistSession,false);
  return {
   auth:{getUser:async()=>({data:{user:validUser?{id:'verified-admin',user_metadata:{role:'administrator'}}:null}})},
   from(table){
    assert.equal(table,'platform_admins');
    return {select(columns){
     assert.equal(columns,'user_id');
     return {eq(field,user){
      queries.push({table,field,user});assert.equal(field,'user_id');assert.equal(user,'verified-admin');
      return {maybeSingle:async()=>({data:admin?{user_id:user}:null,error:adminError?{message:'Internal details'}:null})};
     }};
    }};
   }
  };
 };
 const handler=createStripeSandboxHandler({createClient,env:name=>{envReads.push(name);return values[name];},clock:()=>new Date('2026-10-24T12:00:00Z'),fetcher:async(url,args)=>{
  calls.push({url:String(url),args});
  assert.equal(args.method,'GET');assert.equal(args.redirect,'error');assert.equal(args.headers['Stripe-Version'],'2024-06-20');
  const u=new URL(url);assert.equal(u.origin,'https://api.stripe.com');assert.equal(u.searchParams.get('expand[]'),'product');
  const plan=configuration.plans.find(p=>u.pathname==='/v1/prices/'+p.price_id);assert.ok(plan);
  if(throwFetch)throw Error('Credential and provider diagnostics must never appear in a response');
  if(status!==200)return Response.json({error:{message:'private Stripe account details '+key}},{status});
  const price={id:plan.price_id,livemode:false,active:true,currency:'usd',unit_amount:plan.unit_amount_cents,type:'recurring',
   recurring:{interval:'month',interval_count:1,usage_type:'licensed'},billing_scheme:'per_unit',tiers_mode:null,transform_quantity:null,custom_unit_amount:null,
   product:{id:'prod_local_test',active:true,livemode:false}};
  mutate(price,plan);return Response.json(price);
 }});
 function request({origin='https://training.example',authorization='Bearer user-session',method='POST',body={action:'verify_configuration'}}={}){
  const headers={};if(origin!==null)headers.Origin=origin;if(authorization)headers.Authorization=authorization;
  return new Request('https://edge.example/stripe-sandbox',{method,headers,...(method==='GET'||method==='OPTIONS'?{}:{body:typeof body==='string'?body:JSON.stringify(body)})});
 }
 return {handler,request,calls,queries,envReads,values};
}

test('verified admin checks exactly the three sandbox prices with GET only',async()=>{
 const f=fixture();const response=await f.handler(f.request());const result=await response.json();
 assert.equal(response.status,200);assert.equal(response.headers.get('Cache-Control'),'no-store');
 assert.equal(result.environment,'sandbox');assert.equal(result.all_verified,true);
 assert.equal(result.checked_at,'2026-10-24T12:00:00.000Z');
 assert.deepEqual(result.plans.map(p=>[p.seat_limit,p.unit_amount_cents,p.verified]),[[15,9900,true],[25,21900,true],[35,15900,true]]);
 assert.equal(f.calls.length,3);assert.equal(f.queries.length,1);
 assert.ok(!f.envReads.includes('SUPABASE_SERVICE_ROLE_KEY'));
 assert.ok(!JSON.stringify(result).includes(f.values.STRIPE_SANDBOX_SECRET_KEY));
});

test('invalid identities, non-admins and failed permission reads never reach Stripe or read its key',async()=>{
 for(const options of [{validUser:false},{admin:false},{adminError:true}]){
  const f=fixture(options);const response=await f.handler(f.request({body:{action:'verify_configuration',admin:true,user_id:'verified-admin'}}));
  assert.ok([401,403].includes(response.status));assert.equal(f.calls.length,0);
  assert.ok(!f.envReads.includes('STRIPE_SANDBOX_SECRET_KEY'));
 }
 const f=fixture();assert.equal((await f.handler(f.request({authorization:null}))).status,401);assert.equal(f.queries.length,0);
});

test('foreign origins and other methods are rejected; same-origin preflight needs no authentication',async()=>{
 const f=fixture();assert.equal((await f.handler(f.request({origin:'https://attacker.example'}))).status,403);
 assert.equal((await f.handler(f.request({method:'GET'}))).status,405);
 const preflight=await f.handler(f.request({method:'OPTIONS',authorization:null}));
 assert.equal(preflight.status,204);assert.equal(preflight.headers.get('Access-Control-Allow-Origin'),'https://training.example');
 assert.equal(f.calls.length,0);assert.equal(f.queries.length,0);
});

test('live, publishable, missing and whitespace-damaged keys are rejected before provider requests',async()=>{
 for(const key of ['sk_live_should_never_be_used','pk_test_public_key_not_secret','', 'sk_test_credential_with_newline\n']){
  const f=fixture({key});const response=await f.handler(f.request());assert.equal(response.status,503);assert.equal(f.calls.length,0);
  assert.ok(!(await response.text()).includes('sk_live_should_never_be_used'));
 }
});

test('request fields cannot replace server-approved plans, prices, origin or provider URLs',async()=>{
 const f=fixture();const response=await f.handler(f.request({body:{action:'verify_configuration',price_id:'price_attacker',url:'http://attacker.example',unit_amount:1,environment:'live'}}));
 assert.equal((await response.json()).all_verified,true);
 assert.ok(f.calls.every(c=>!c.url.includes('attacker')));
 for(const body of [{action:'create_checkout'},{action:'charge'},[],null,'not json','x'.repeat(1025)]){
  const denied=fixture();assert.ok([400,413].includes((await denied.handler(denied.request({body}))).status));assert.equal(denied.calls.length,0);
 }
});

const mismatches=[
 ['price_id_mismatch',p=>{p.id='price_other';}],
 ['live_price_rejected',p=>{p.livemode=true;}],
 ['price_not_active',p=>{p.active=false;}],
 ['currency_mismatch',p=>{p.currency='cad';}],
 ['amount_mismatch',p=>{p.unit_amount=219.99;}],
 ['amount_mismatch',p=>{p.unit_amount='9900';}],
 ['billing_interval_mismatch',p=>{p.recurring.interval='year';}],
 ['billing_interval_mismatch',p=>{p.recurring.interval_count=2;}],
 ['billing_interval_mismatch',p=>{p.type='one_time';p.recurring=null;}],
 ['flat_package_pricing_required',p=>{p.recurring.usage_type='metered';}],
 ['flat_package_pricing_required',p=>{p.billing_scheme='tiered';}],
 ['flat_package_pricing_required',p=>{p.transform_quantity={divide_by:15,round:'up'};}],
 ['flat_package_pricing_required',p=>{p.custom_unit_amount={enabled:true};}],
 ['product_not_active_in_sandbox',p=>{p.product.active=false;}],
 ['product_not_active_in_sandbox',p=>{p.product.livemode=true;}],
 ['product_not_active_in_sandbox',p=>{p.product='prod_unexpanded';}]
];
for(const [issue,mutate] of mismatches)test('rejects incorrect Stripe configuration: '+issue,async()=>{
 const f=fixture({mutate:(price,plan)=>{if(plan.seat_limit===35)mutate(price);}});
 const response=await f.handler(f.request());const result=await response.json();
 assert.equal(result.all_verified,false);assert.equal(result.plans[2].issue,issue);
 assert.deepEqual(result.plans.map(p=>p.verified),[true,true,false]);
});

test('amount conflicts expose exact expected and returned dollars with Price IDs for the existing client',async()=>{
 const f=fixture({mutate:(p,plan)=>{if(plan.seat_limit===25)p.unit_amount=17900;if(plan.seat_limit===35)p.unit_amount=23900;}});
 const response=await f.handler(f.request()),result=await response.json();
 assert.equal(response.status,409);assert.equal(result.all_verified,false);
 assert.match(result.error,/16–25 seats: expected \$219\.00\/month; Stripe returned \$179\.00\/month/);
 assert.match(result.error,/26–35 seats: expected \$159\.00\/month; Stripe returned \$239\.00\/month/);
 for(const plan of configuration.plans.slice(1))assert.ok(result.error.includes(plan.price_id));
 assert.deepEqual(result.plans.map(p=>p.stripe_unit_amount_cents),[9900,17900,23900]);
 assert.ok(!result.error.includes(f.values.STRIPE_SANDBOX_SECRET_KEY));
});

test('correct integer-cent prices still pass; malformed amounts are rejected without echoing raw strings',async()=>{
 const good=fixture(),success=await good.handler(good.request());
 assert.equal(success.status,200);const verified=await success.json();assert.equal(verified.all_verified,true);
 assert.deepEqual(verified.plans.map(p=>p.stripe_unit_amount_cents),[9900,21900,15900]);
 const bad=fixture({mutate:p=>{p.unit_amount='untrusted-provider-string-with-private-details';}});
 const response=await bad.handler(bad.request()),text=await response.text();
 assert.equal(response.status,409);assert.ok(!text.includes('untrusted-provider-string'));
 assert.ok(JSON.parse(text).plans.every(p=>p.stripe_unit_amount_cents===null));
});

test('superseded 25- and 35-seat amounts cannot pass the corrected package mapping',async()=>{
 const f=fixture({mutate:(p,plan)=>{if(plan.seat_limit===25)p.unit_amount=15900;if(plan.seat_limit===35)p.unit_amount=21999;}});
 const response=await f.handler(f.request()),result=await response.json();
 assert.equal(response.status,409);assert.equal(result.all_verified,false);
 assert.deepEqual(result.plans.map(p=>[p.seat_limit,p.unit_amount_cents,p.verified]),[[15,9900,true],[25,21900,false],[35,15900,false]]);
 assert.match(result.error,/16–25 seats: expected \$219\.00\/month; Stripe returned \$159\.00\/month/);
 assert.match(result.error,/26–35 seats: expected \$159\.00\/month; Stripe returned \$219\.99\/month/);
});

test('provider errors and network failures are reported without provider bodies, keys or account details',async()=>{
 for(const [options,issue] of [[{status:401},'key_not_accepted'],[{status:403},'key_permission_denied'],[{status:404},'price_not_found_in_sandbox'],[{status:429},'stripe_unavailable'],[{status:500},'stripe_unavailable'],[{throwFetch:true},'stripe_unavailable']]){
  const f=fixture(options),response=await f.handler(f.request());const text=await response.text(),result=JSON.parse(text);
  assert.equal(result.all_verified,false);assert.ok(result.plans.every(p=>p.issue===issue));
  assert.ok(!text.includes('private Stripe')&&!text.includes(f.values.STRIPE_SANDBOX_SECRET_KEY)&&!text.includes('Credential and provider'));
 }
});

test('dashboard function embeds the exact approved mapping and remains sandbox-only',async()=>{
 const code=await readFile(new URL('../supabase/stripe-sandbox-function.ts',import.meta.url),'utf8');
 assert.ok(code.includes('const configuration='+JSON.stringify(configuration,null,2)));
 assert.ok(code.includes("STRIPE_SANDBOX_SECRET_KEY"));
 assert.ok(!code.includes('sk_test_local_example_never_real'));
});
