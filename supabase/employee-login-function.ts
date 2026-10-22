import {createClient} from "https://esm.sh/@supabase/supabase-js@2.118.0";
function createEmployeeLoginHandler({createClient,env,fetcher=fetch,pause=ms=>new Promise(resolve=>setTimeout(resolve,ms))}){
 return async request=>{
  let app;try{app=new URL(env('COLTRAIN_APP_URL'));if(app.protocol!=='https:'||app.pathname!=='/'||app.search||app.hash||app.username||app.password||/^(localhost|127\.|\[::1\])/.test(app.hostname))throw Error();}catch{return Response.json({error:'Hosted website configuration required.'},{status:503});}
  const origin=request.headers.get('Origin'),headers={'Vary':'Origin','Cache-Control':'no-store'};
  if(origin===app.origin)headers['Access-Control-Allow-Origin']=origin;
  const reply=(status,data)=>Response.json(data,{status,headers});
  if(origin&&origin!==app.origin)return reply(403,{error:'Open the hosted colTRAIN website.'});
  if(request.method==='OPTIONS')return new Response(null,{status:204,headers:{...headers,'Access-Control-Allow-Methods':'POST, OPTIONS','Access-Control-Allow-Headers':'authorization, apikey, content-type, x-client-info'}});
  if(request.method!=='POST')return reply(405,{error:'Use POST.'});
  const authorization=request.headers.get('Authorization');if(!authorization?.startsWith('Bearer '))return reply(401,{error:'Sign in first.'});
  try{
   const caller=createClient(env('SUPABASE_URL'),env('SUPABASE_ANON_KEY'),{global:{headers:{Authorization:authorization}},auth:{persistSession:false,autoRefreshToken:false}});
   const identity=await caller.auth.getUser();if(identity.error||!identity.data?.user)return reply(401,{error:'Sign in again.'});
   // Identity comes only from Auth, never from request JSON or an invitation's metadata.
   const recorded=await caller.rpc('record_employee_first_login',{});if(recorded.error)return reply(403,{error:'Login confirmation could not be recorded.'});
   const key=env('RESEND_API_KEY'),from=env('COLTRAIN_EMAIL_FROM');
   if(!key||!from||/[\r\n]/.test(from))return reply(200,{delivery_status:'not_configured'});
   const service=createClient(env('SUPABASE_URL'),env('SUPABASE_SERVICE_ROLE_KEY'),{auth:{persistSession:false,autoRefreshToken:false}});
   let processed=0,failed=false;
   for(let i=0;i<20;i++){
    const claimed=await service.rpc('claim_employee_login_email',{actor:identity.data.user.id});
    if(claimed.error)throw Error();const job=claimed.data;if(!job)break;if(job.skip)continue;
    let success=false,providerId=null;
    try{
     const response=await fetcher('https://api.resend.com/emails',{method:'POST',headers:{Authorization:`Bearer ${key}`,'Content-Type':'application/json','Idempotency-Key':`coltrain-first-login/${job.id}`},body:JSON.stringify({from,to:[job.email],subject:job.title,text:`${job.body}\n\nOpen colTRAIN: ${app.origin}/accounts/\n\nYou can change optional email notifications in your colTRAIN account settings.`}),signal:AbortSignal.timeout(12000)});
     const result=await response.json();success=response.ok&&typeof result.id==='string';if(success)providerId=result.id;
    }catch{/* No credentials, addresses or provider payloads in logs or responses. */}
    const saved=await service.rpc('finish_employee_login_email',{delivery_id:job.id,lease:job.lease_id,success,provider_id:providerId,error_message:success?null:'Email provider did not confirm delivery.'});
    if(saved.error)throw Error();processed++;
    if(!success){failed=true;break;}await pause(550);
   }
   return reply(200,{delivery_status:failed?'retry_needed':'processed',processed});
  }catch{return reply(500,{error:'Login email remains queued for a later retry.'});}
 };
}

Deno.serve(createEmployeeLoginHandler({createClient,env:(name:string)=>Deno.env.get(name)}));
