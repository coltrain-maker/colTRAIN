// Generated standalone dashboard function. No credentials are included.
import {createClient} from 'npm:@supabase/supabase-js@2.118.0';
import type {createClient as SupabaseFactory} from 'npm:@supabase/supabase-js@2.118.0';
const signupConfiguration={
  "environment": "sandbox",
  "currency": "usd",
  "interval": "month",
  "interval_count": 1,
  "trial_days": 14,
  "payment_method_required": true,
  "confirmed_by_owner_on": "2026-10-24",
  "verification_status": "owner_confirmed_not_yet_verified_against_stripe_api",
  "plans": [
    {
      "code": "store_15",
      "minimum_seats": 1,
      "seat_limit": 15,
      "unit_amount_cents": 9900,
      "price_id": "price_1UTrhULKSqENX3EoVuI54JbR"
    },
    {
      "code": "store_25",
      "minimum_seats": 16,
      "seat_limit": 25,
      "unit_amount_cents": 15900,
      "price_id": "price_1UTrnrLKSqENX3EoqGe9eX6R"
    },
    {
      "code": "store_35",
      "minimum_seats": 26,
      "seat_limit": 35,
      "unit_amount_cents": 21900,
      "price_id": "price_1UTroBLKSqENX3Eo7JUSvRve"
    }
  ],
  "assisted_setup": {
    "minimum_seats": 36,
    "additional_locations": true,
    "price_id": null
  }
};
export type Dependencies={createClient:typeof SupabaseFactory;env:(name:string)=>string|undefined;fetcher?:typeof fetch;now?:()=>number};
export type StripeData=Record<string,any>;
export const signupPlans=signupConfiguration.plans;
export class SignupError extends Error{status:number;constructor(message:string,status=400){super(message);this.status=status;}}
export function sandboxKey(env:Dependencies['env']):string{
 const key=env('STRIPE_SANDBOX_SECRET_KEY')||'';
 if(!key.startsWith('sk_test_')||key.length<20||/\s/.test(key))throw new SignupError('A Stripe sandbox secret key is required.',503);
 return key;
}
export function signupApp(env:Dependencies['env']):URL{
 try{const app=new URL(env('COLTRAIN_APP_URL')||'');if(app.protocol!=='https:'||app.pathname!=='/'||app.search||app.hash||app.username||app.password||/^(localhost|127\.|\[::1\])/.test(app.hostname))throw Error();return app;}
 catch{throw new SignupError('Hosted website configuration is required.',503);}
}
export async function readSignupBody(request:Request,limit=65536):Promise<Uint8Array>{
 const reader=request.body?.getReader();if(!reader)return new Uint8Array();const chunks:Uint8Array[]=[];let size=0;
 while(true){const next=await reader.read();if(next.done)break;size+=next.value.byteLength;if(size>limit){await reader.cancel();throw new SignupError('Request is too large.',413);}chunks.push(next.value);}
 const body=new Uint8Array(size);let offset=0;for(const c of chunks){body.set(c,offset);offset+=c.length;}return body;
}
export async function stripeSignupRequest(fetcher:typeof fetch,key:string,method:'GET'|'POST',path:string,params?:URLSearchParams,idempotency?:string):Promise<StripeData>{
 if(!/^\/(prices\/price_[A-Za-z0-9]+|checkout\/sessions(\/cs_test_[A-Za-z0-9]+)?)$/.test(path))throw new SignupError('Invalid Stripe request.',500);
 const url=new URL('https://api.stripe.com/v1'+path);if(method==='GET'&&params)url.search=params.toString();
 const headers:Record<string,string>={Authorization:'Bearer '+key,'Stripe-Version':'2024-06-20'};
 if(method==='POST'){headers['Content-Type']='application/x-www-form-urlencoded';if(!idempotency)throw new SignupError('Checkout retry key is required.',500);headers['Idempotency-Key']=idempotency;}
 try{
  const response=await fetcher(url,{method,headers,body:method==='POST'?params:undefined,redirect:'error',signal:AbortSignal.timeout(12000)});
  if(!response.ok)throw new SignupError('Stripe could not confirm the sandbox request. Try again or contact colTRAIN support.',502);
  const data=await response.json();if(!data||typeof data!=='object'||Array.isArray(data))throw Error();return data;
 }catch(error){if(error instanceof SignupError)throw error;throw new SignupError('Stripe could not be reached. Retry using the same signup.',502);}
}
export function validSignupPrice(price:StripeData,plan:typeof signupPlans[number],requireActive=true):boolean{
 return !!price&&price.id===plan.price_id&&price.livemode===false&&(!requireActive||price.active===true)&&price.currency==='usd'
 &&price.unit_amount===plan.unit_amount_cents&&price.type==='recurring'&&price.recurring?.interval==='month'&&price.recurring?.interval_count===1
 &&price.recurring?.usage_type==='licensed'&&price.billing_scheme==='per_unit'&&price.transform_quantity==null&&price.custom_unit_amount==null&&price.tiers_mode==null;
}
export function validCheckoutUrl(value:unknown):value is string{
 if(typeof value!=='string')return false;try{const u=new URL(value);return u.protocol==='https:'&&u.hostname==='checkout.stripe.com'&&!u.port&&!u.username&&!u.password&&u.pathname.startsWith('/c/pay/cs_test_');}catch{return false;}
}
export async function verifySignupSignature(raw:Uint8Array,header:string|null,secret:string,now:number):Promise<boolean>{
 if(!header||header.length>2048||!secret.startsWith('whsec_')||secret.length<16)return false;
 const parts=header.split(',').map(p=>p.split('='));const times=parts.filter(p=>p[0]==='t');
 if(times.length!==1||!/^\d{10,12}$/.test(times[0][1]||''))return false;
 const timestamp=times[0][1];if(Math.abs(now/1000-Number(timestamp))>300)return false;
 const prefix=new TextEncoder().encode(timestamp+'.'),message=new Uint8Array(prefix.length+raw.length);message.set(prefix);message.set(raw,prefix.length);
 const key=await crypto.subtle.importKey('raw',new TextEncoder().encode(secret),{name:'HMAC',hash:'SHA-256'},false,['verify']);
 for(const [name,value] of parts){if(name!=='v1'||!value||!/^[0-9a-f]{64}$/i.test(value))continue;
  const bytes=Uint8Array.from(value.match(/../g)!.map(s=>parseInt(s,16)));if(await crypto.subtle.verify('HMAC',key,bytes,message))return true;
 }return false;
}

export function createStripeSignupWebhook({createClient,env,fetcher=fetch,now=()=>Date.now()}:Dependencies){
 return async(request:Request):Promise<Response>=>{
  const reply=(status:number,body:unknown)=>Response.json(body,{status,headers:{'Cache-Control':'no-store'}});
  if(request.method!=='POST')return reply(405,{error:'Use POST.'});
  try{
   const secret=env('STRIPE_SANDBOX_WEBHOOK_SECRET')||'';
   if(!secret.startsWith('whsec_')||secret.length<16)throw new SignupError('Sandbox webhook is not configured.',503);
   const raw=await readSignupBody(request,524288);
   if(!await verifySignupSignature(raw,request.headers.get('Stripe-Signature'),secret,now()))return reply(400,{error:'Invalid webhook signature.'});
   let event;try{event=JSON.parse(new TextDecoder('utf-8',{fatal:true}).decode(raw));}catch{return reply(400,{error:'Invalid event.'});}
   if(event.livemode!==false||typeof event.id!=='string'||!/^evt_[A-Za-z0-9_]+$/.test(event.id))return reply(400,{error:'A sandbox event is required.'});
   if(!['checkout.session.completed','checkout.session.async_payment_succeeded'].includes(event.type))return reply(200,{ignored:true});
   const object=event.data?.object;
   if(typeof object?.id!=='string'||!/^cs_test_[A-Za-z0-9]+$/.test(object.id)||typeof object.metadata?.signup_id!=='string'||!/^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$/i.test(object.metadata.signup_id))return reply(200,{ignored:true});
   const service=createClient(env('SUPABASE_URL')||'',env('SUPABASE_SERVICE_ROLE_KEY')||'',{auth:{persistSession:false,autoRefreshToken:false}});
   const found=await service.rpc('get_store_signup_for_webhook',{signup:object.metadata.signup_id});
   if(found.error)throw new SignupError('Signup lookup failed; retry delivery.',503);
   const signup=found.data;if(!signup)return reply(200,{ignored:true});
   if(signup.checkout_id&&signup.checkout_id!==object.id)return reply(400,{error:'Checkout does not match signup.'});
   if(signup.state==='provisioned')return reply(200,{processed:true});
   const plan=signupPlans.find(p=>p.code===signup.plan_code);if(!plan)return reply(400,{error:'Invalid signup package.'});
   const session=await stripeSignupRequest(fetcher,sandboxKey(env),'GET','/checkout/sessions/'+object.id,new URLSearchParams({'expand[]':'subscription'}));
   const sub=session.subscription;
   if(session.id!==object.id||session.livemode!==false||session.mode!=='subscription'||session.metadata?.signup_id!==signup.id
    ||session.client_reference_id!==signup.id||session.metadata?.environment!=='coltrain-sandbox')return reply(400,{error:'Verified checkout does not match signup.'});
   if(session.status!=='complete'||!['paid','no_payment_required'].includes(session.payment_status))return reply(200,{pending:true});
   if(!sub||typeof sub!=='object'||sub.livemode!==false||!/^sub_[A-Za-z0-9]+$/.test(sub.id||'')
    ||sub.metadata?.signup_id!==signup.id||sub.metadata?.environment!=='coltrain-sandbox'
    ||typeof session.customer!=='string'||!/^cus_[A-Za-z0-9]+$/.test(session.customer)||sub.customer!==session.customer)return reply(400,{error:'Verified subscription does not match signup.'});
   if(!['trialing','active'].includes(sub.status))return reply(200,{pending:true});
   const items=sub.items?.data;
   if(!Array.isArray(items)||items.length!==1||items[0].quantity!==1||!validSignupPrice(items[0].price,plan,false)
    ||!Number.isSafeInteger(sub.current_period_end)||(sub.status==='trialing'&&!Number.isSafeInteger(sub.trial_end)))return reply(400,{error:'Subscription package does not match signup.'});
   const saved=await service.rpc('provision_sandbox_store_signup',{signup:signup.id,event_id:event.id,session_id:session.id,customer:session.customer,
    subscription:sub.id,plan:plan.code,subscription_status:sub.status,
    trial_end:Number.isSafeInteger(sub.trial_end)?new Date(sub.trial_end*1000).toISOString():null,period_end:new Date(sub.current_period_end*1000).toISOString()});
   if(saved.error)throw new SignupError('Store setup needs a retry or administrator review.',503);
   return reply(200,{processed:true});
  }catch(error){return reply(error instanceof SignupError?error.status:503,{error:error instanceof SignupError?error.message:'Webhook processing failed; retry delivery.'});}
 };
}

Deno.serve(createStripeSignupWebhook({createClient,env:(name:string)=>Deno.env.get(name)}));
