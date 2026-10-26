import {type Dependencies,SignupError,sandboxKey,signupApp,signupPlans,readSignupBody,stripeSignupRequest,validSignupPrice,validCheckoutUrl} from '../_shared/stripe-signup.ts';
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
