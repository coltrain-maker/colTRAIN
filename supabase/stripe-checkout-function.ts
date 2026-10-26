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

export function createStripeCheckoutHandler({createClient,env,fetcher=fetch}:Dependencies){
 return async(request:Request):Promise<Response>=>{
  let headers:Record<string,string>={'Cache-Control':'no-store','Vary':'Origin'};
  const reply=(status:number,body:unknown)=>Response.json(body,{status,headers});
  try{
   const app=signupApp(env),origin=request.headers.get('Origin');
   if(origin&&origin!==app.origin)return reply(403,{error:'Open the hosted colTRAIN website.'});
   if(origin)headers['Access-Control-Allow-Origin']=origin;
   if(request.method==='OPTIONS')return new Response(null,{status:204,headers:{...headers,'Access-Control-Allow-Methods':'POST, OPTIONS','Access-Control-Allow-Headers':'authorization, apikey, content-type, x-client-info'}});
   if(request.method!=='POST')return reply(405,{error:'Use POST.'});
   const auth=request.headers.get('Authorization');if(!auth?.startsWith('Bearer '))return reply(401,{error:'Sign in first.'});
   const caller=createClient(env('SUPABASE_URL')||'',env('SUPABASE_ANON_KEY')||'',{global:{headers:{Authorization:auth}},auth:{persistSession:false,autoRefreshToken:false}});
   const identity=await caller.auth.getUser();if(identity.error||!identity.data.user?.email_confirmed_at)return reply(401,{error:'Sign in with a confirmed email first.'});
   let body;try{body=JSON.parse(new TextDecoder().decode(await readSignupBody(request,2048)));}catch(error){if(error instanceof SignupError)throw error;return reply(400,{error:'Choose your saved signup.'});}
   if(typeof body?.signup_id!=='string'||!/^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$/i.test(body.signup_id))return reply(400,{error:'Choose your saved signup.'});
   const key=sandboxKey(env);
   const service=createClient(env('SUPABASE_URL')||'',env('SUPABASE_SERVICE_ROLE_KEY')||'',{auth:{persistSession:false,autoRefreshToken:false}});
   const claim=await service.rpc('claim_store_signup_checkout',{signup:body.signup_id,actor:identity.data.user.id});
   if(claim.error)return reply(409,{error:claim.error.message});
   const job=claim.data;if(!job)return reply(409,{error:'Signup is not available.'});
   if(job.ready)return reply(200,{ready:true});
   if(job.busy)return reply(409,{error:'Checkout is already being prepared. Wait a moment, then retry.'});
   if(job.url){if(!validCheckoutUrl(job.url))throw new SignupError('Saved checkout is unavailable; contact support.',503);return reply(200,{url:job.url});}
   try{
    const plan=signupPlans.find(p=>p.code===job.plan_code);if(!plan)throw new SignupError('Unknown store package.',409);
    const price=await stripeSignupRequest(fetcher,key,'GET','/prices/'+plan.price_id,new URLSearchParams({'expand[]':'product'}));
    if(!validSignupPrice(price,plan)||price.product?.livemode!==false||price.product?.active!==true)throw new SignupError('The selected Stripe package needs administrator attention.',409);
    const params=new URLSearchParams({mode:'subscription','payment_method_types[0]':'card',payment_method_collection:'always',
     'line_items[0][price]':plan.price_id,'line_items[0][quantity]':'1','subscription_data[trial_period_days]':'14',
     'subscription_data[trial_settings][end_behavior][missing_payment_method]':'cancel',
     'subscription_data[metadata][signup_id]':job.id,'subscription_data[metadata][environment]':'coltrain-sandbox',
     'metadata[signup_id]':job.id,'metadata[environment]':'coltrain-sandbox',client_reference_id:job.id,
     customer_email:job.email,billing_address_collection:'required',
     success_url:app.origin+'/accounts/?store_signup=return',cancel_url:app.origin+'/accounts/?store_signup=cancelled'});
    const session=await stripeSignupRequest(fetcher,key,'POST','/checkout/sessions',params,'coltrain-sandbox-signup/'+job.id);
    if(session.livemode!==false||typeof session.id!=='string'||!/^cs_test_[A-Za-z0-9]+$/.test(session.id)||!validCheckoutUrl(session.url)||!Number.isSafeInteger(session.expires_at))throw new SignupError('Stripe returned an invalid sandbox checkout.',502);
    const saved=await service.rpc('finish_store_signup_checkout',{signup:job.id,actor:identity.data.user.id,lease:job.lease,
     session_id:session.id,session_url:session.url,expires_at:new Date(session.expires_at*1000).toISOString()});
    if(saved.error)throw new SignupError('Checkout could not be saved. Retry using this same signup.',503);
    return reply(200,{url:session.url});
   }catch(error){await service.rpc('release_store_signup_checkout',{signup:job.id,actor:identity.data.user.id,lease:job.lease});throw error;}
  }catch(error){return reply(error instanceof SignupError?error.status:503,{error:error instanceof SignupError?error.message:'Checkout could not be prepared. Please try again.'});}
 };
}

Deno.serve(createStripeCheckoutHandler({createClient,env:(name:string)=>Deno.env.get(name)}));
