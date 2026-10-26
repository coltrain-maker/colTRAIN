import test from 'node:test';
import assert from 'node:assert/strict';
import {createHmac} from 'node:crypto';
import {createStripeCheckoutHandler} from '../supabase/functions/stripe-checkout/handler.ts';
import {createStripeSignupWebhook} from '../supabase/functions/stripe-signup-webhook/handler.ts';
import {validCheckoutUrl,verifySignupSignature} from '../supabase/functions/_shared/stripe-signup.ts';
const signup='40000000-0000-0000-0000-000000000951';
const now=Date.parse('2026-10-26T12:00:00Z');
const priceId='price_1UTrnrLKSqENX3EoqGe9eX6R';
const secret='whsec_local_test_signing_secret';
function fixture(options={}){
 const calls=[],requests=[];
 const env={COLTRAIN_APP_URL:'https://signup.example',SUPABASE_URL:'https://project.example',SUPABASE_ANON_KEY:'anon-local',SUPABASE_SERVICE_ROLE_KEY:'service-local',STRIPE_SANDBOX_SECRET_KEY:'sk_test_local_not_a_real_key',STRIPE_SANDBOX_WEBHOOK_SECRET:secret,...options.env};
 const price={id:priceId,livemode:false,active:true,currency:'usd',unit_amount:15900,type:'recurring',recurring:{interval:'month',interval_count:1,usage_type:'licensed'},billing_scheme:'per_unit',transform_quantity:null,custom_unit_amount:null,product:{active:true,livemode:false}};
 const session={id:'cs_test_LocalSession',livemode:false,url:'https://checkout.stripe.com/c/pay/cs_test_LocalSession',expires_at:Math.floor(now/1000)+86400,status:'complete',mode:'subscription',payment_status:'no_payment_required',customer:'cus_LocalCustomer',client_reference_id:signup,metadata:{signup_id:signup,environment:'coltrain-sandbox'},
  subscription:{id:'sub_LocalSubscription',livemode:false,customer:'cus_LocalCustomer',status:'trialing',metadata:{signup_id:signup,environment:'coltrain-sandbox'},trial_end:now/1000+1209600,current_period_end:now/1000+1209600,items:{data:[{quantity:1,price:structuredClone(price)}]}}};
 options.mutatePrice?.(price);options.mutateSession?.(session);
 const service={rpc:async(name,args)=>{
  calls.push({name,args});
  if(options.rpcError===name)return {error:{message:'Signup is not available'}};
  if(name==='claim_store_signup_checkout')return {data:options.claim||{id:signup,actor:'verified-owner',email:'owner@example.test',plan_code:'store_25',lease:'lease-local'}};
  if(name==='get_store_signup_for_webhook')return {data:options.unknownSignup?null:{id:signup,user_id:'verified-owner',plan_code:'store_25',checkout_id:options.unsavedSession?null:session.id,state:options.provisioned?'provisioned':'checkout'}};
  return {data:{store_id:'new-store',created:true}};
 }};
 const createClient=(url,key,args)=>{
  assert.equal(url,env.SUPABASE_URL);
  if(key===env.SUPABASE_SERVICE_ROLE_KEY)return service;
  assert.equal(key,env.SUPABASE_ANON_KEY);assert.equal(args.global.headers.Authorization,'Bearer local-session');
  return {auth:{getUser:async()=>({data:{user:options.invalidUser?null:{id:'verified-owner',email_confirmed_at:options.unconfirmed?null:'2026-10-26T00:00:00Z'}}})}};
 };
 const fetcher=async(url,args)=>{
  requests.push({url:String(url),args});assert.equal(new URL(url).origin,'https://api.stripe.com');assert.equal(args.redirect,'error');
  if(options.providerError)return Response.json({error:{message:'private provider details '+env.STRIPE_SANDBOX_SECRET_KEY}},{status:500});
  if(String(url).includes('/v1/prices/'))return Response.json(price);
  return Response.json(session);
 };
 const deps={createClient,env:n=>env[n],fetcher,now:()=>now};
 function checkout(body={signup_id:signup},origin='https://signup.example'){
  return new Request('https://edge.example/stripe-checkout',{method:'POST',headers:{Origin:origin,Authorization:'Bearer local-session'},body:JSON.stringify(body)});
 }
 function webhook({event={},raw,signature,timestamp=Math.floor(now/1000)}={}){
  raw??=JSON.stringify({id:'evt_local',livemode:false,type:'checkout.session.completed',data:{object:{id:session.id,metadata:{signup_id:signup}}},...event});
  signature??='t='+timestamp+',v1='+createHmac('sha256',secret).update(timestamp+'.'+raw).digest('hex');
  return new Request('https://edge.example/stripe-signup-webhook',{method:'POST',headers:{'Stripe-Signature':signature},body:raw});
 }
 return {calls,requests,env,session,checkout,webhook,handler:createStripeCheckoutHandler(deps),receiver:createStripeSignupWebhook(deps)};
}
test('checkout uses verified identity and server plan, requires a card, and sets exactly fourteen trial days',async()=>{
 const f=fixture(),response=await f.handler(f.checkout({signup_id:signup,actor:'attacker',price_id:'price_fake',quantity:100,trial_days:999,success_url:'https://attacker.example'}));
 assert.equal(response.status,200);assert.equal((await response.json()).url,f.session.url);
 assert.equal(f.calls[0].args.actor,'verified-owner');
 const post=f.requests.find(r=>r.args.method==='POST'),params=post.args.body;
 assert.equal(params.get('line_items[0][price]'),priceId);assert.equal(params.get('line_items[0][quantity]'),'1');
 assert.equal(params.get('payment_method_collection'),'always');assert.equal(params.get('subscription_data[trial_period_days]'),'14');
 assert.equal(params.get('customer_email'),'owner@example.test');assert.equal(params.get('success_url'),'https://signup.example/accounts/?store_signup=return');
 assert.equal(post.args.headers['Idempotency-Key'],'coltrain-sandbox-signup/'+signup);
 assert.equal(f.calls.at(-1).name,'finish_store_signup_checkout');
 assert.ok(!f.calls.some(c=>c.name==='provision_sandbox_store_signup'));
});
test('invalid identity, unconfirmed email, foreign origins and live keys cannot create checkout',async()=>{
 for(const options of [{invalidUser:true},{unconfirmed:true},{env:{STRIPE_SANDBOX_SECRET_KEY:'sk_live_forbidden'}}]){
  const f=fixture(options),r=await f.handler(f.checkout());assert.ok([401,503].includes(r.status));assert.equal(f.requests.length,0);
 }
 const f=fixture();assert.equal((await f.handler(f.checkout({},'https://attacker.example'))).status,403);assert.equal(f.calls.length,0);
});
test('checkout retries reuse saved URL and reject another caller or an active lease',async()=>{
 const f=fixture({claim:{url:'https://checkout.stripe.com/c/pay/cs_test_Saved'}});assert.equal((await f.handler(f.checkout())).status,200);assert.equal(f.requests.length,0);
 const denied=fixture({rpcError:'claim_store_signup_checkout'});assert.equal((await denied.handler(denied.checkout())).status,409);
 const busy=fixture({claim:{busy:true}});assert.equal((await busy.handler(busy.checkout())).status,409);assert.equal(busy.requests.length,0);
});
test('wrong prices, unsafe checkout URLs and ambiguous provider failures cannot be accepted or create stores',async()=>{
 for(const options of [{mutatePrice:p=>p.unit_amount=21900},{mutateSession:s=>s.url='https://attacker.example/'},{mutateSession:s=>s.livemode=true},{providerError:true},{rpcError:'finish_store_signup_checkout'}]){
  const f=fixture(options),r=await f.handler(f.checkout());assert.ok(r.status>=400);assert.equal(f.calls.at(-1).name,'release_store_signup_checkout');
  assert.ok(!(await r.text()).includes('private provider details'));assert.ok(!f.calls.some(c=>c.name==='provision_sandbox_store_signup'));
 }
 for(const url of ['https://checkout.stripe.com.attacker.example/c/pay/cs_test_x','http://checkout.stripe.com/c/pay/cs_test_x','https://user@checkout.stripe.com/c/pay/cs_test_x','https://checkout.stripe.com/c/pay/cs_live_x'])assert.equal(validCheckoutUrl(url),false);
});
test('identical checkout retries keep the same Stripe idempotency key',async()=>{
 const f=fixture();await f.handler(f.checkout());await f.handler(f.checkout());
 assert.equal(new Set(f.requests.filter(r=>r.args.method==='POST').map(r=>r.args.headers['Idempotency-Key'])).size,1);
});
test('webhook verifies raw signature and canonical Stripe subscription before provisioning',async()=>{
 const f=fixture(),response=await f.receiver(f.webhook());assert.equal(response.status,200);
 const saved=f.calls.find(c=>c.name==='provision_sandbox_store_signup');
 assert.equal(saved.args.signup,signup);assert.equal(saved.args.plan,'store_25');assert.equal(saved.args.subscription,'sub_LocalSubscription');
 assert.equal(saved.args.subscription_status,'trialing');assert.ok(f.requests.every(r=>r.args.method==='GET'));
});
test('untrusted, tampered, stale and live events never get database or provider access',async()=>{
 const f=fixture();
 for(const request of [f.webhook({signature:'t=123,v1=invalid'}),f.webhook({timestamp:Math.floor(now/1000)-301}),f.webhook({event:{livemode:true}})])assert.equal((await f.receiver(request)).status,400);
 const original=f.webhook(),tampered=new Request(original.url,{method:'POST',headers:original.headers,body:(await original.text())+' '});
 assert.equal((await f.receiver(tampered)).status,400);assert.equal(f.calls.length,0);assert.equal(f.requests.length,0);
 const raw=' {"test":true}';const t=Math.floor(now/1000),sig=createHmac('sha256',secret).update(t+'.'+raw).digest('hex');
 assert.equal(await verifySignupSignature(new TextEncoder().encode(raw),'t='+t+',v1='+'0'.repeat(64)+',v1='+sig,secret,now),true);
});
for(const [label,mutate] of [
 ['wrong client reference',s=>s.client_reference_id='attacker'],['live subscription',s=>s.subscription.livemode=true],
 ['wrong customer',s=>s.subscription.customer='cus_Other'],['wrong subscription metadata',s=>s.subscription.metadata.signup_id='other'],
 ['quantity',s=>s.subscription.items.data[0].quantity=2],['wrong price',s=>s.subscription.items.data[0].price.unit_amount=21900],
 ['extra subscription item',s=>s.subscription.items.data.push(structuredClone(s.subscription.items.data[0]))]
])test('webhook rejects '+label,async()=>{
 const f=fixture({mutateSession:mutate}),r=await f.receiver(f.webhook());assert.equal(r.status,400);assert.ok(!f.calls.some(c=>c.name==='provision_sandbox_store_signup'));
});
test('unpaid, incomplete, canceled, unrelated and duplicate events never provision a second store',async()=>{
 for(const mutateSession of [s=>s.payment_status='unpaid',s=>s.status='open',s=>s.subscription.status='canceled']){
  const f=fixture({mutateSession}),r=await f.receiver(f.webhook());assert.equal(r.status,200);assert.ok(!f.calls.some(c=>c.name==='provision_sandbox_store_signup'));
 }
 const unrelated=fixture();assert.equal((await unrelated.receiver(unrelated.webhook({event:{type:'invoice.created'}}))).status,200);assert.equal(unrelated.calls.length,0);
 const duplicate=fixture({provisioned:true});assert.equal((await duplicate.receiver(duplicate.webhook())).status,200);assert.equal(duplicate.requests.length,0);assert.equal(duplicate.calls.length,1);
});
test('webhook can recover a paid checkout whose browser response was lost; SQL outages request retry',async()=>{
 const early=fixture({unsavedSession:true});assert.equal((await early.receiver(early.webhook())).status,200);assert.ok(early.calls.some(c=>c.name==='provision_sandbox_store_signup'));
 const failed=fixture({rpcError:'provision_sandbox_store_signup'});assert.equal((await failed.receiver(failed.webhook())).status,503);
 const badKey=fixture({env:{STRIPE_SANDBOX_SECRET_KEY:'sk_live_forbidden'}});assert.equal((await badKey.receiver(badKey.webhook())).status,503);assert.equal(badKey.requests.length,0);
});
