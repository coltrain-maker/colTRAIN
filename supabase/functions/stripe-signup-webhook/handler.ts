import {type Dependencies,SignupError,sandboxKey,signupPlans,readSignupBody,stripeSignupRequest,validSignupPrice,verifySignupSignature} from '../_shared/stripe-signup.ts';
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
