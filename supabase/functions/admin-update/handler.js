const uuid=/^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$/i;
export function createAdminUpdateHandler({createClient,env,fetcher=fetch,pause=ms=>new Promise(resolve=>setTimeout(resolve,ms))}){
 return async request=>{
  let app;
  try{app=new URL(env('COLTRAIN_APP_URL'));if(app.protocol!=='https:'||app.pathname!=='/'||app.search||app.hash||app.username||app.password||/^(localhost|127\.|\[::1\])/.test(app.hostname))throw Error();}catch{return Response.json({error:'Admin updates need the hosted website configured.'},{status:503});}
  const origin=request.headers.get('Origin'),headers={'Vary':'Origin','Cache-Control':'no-store'};
  if(origin===app.origin)headers['Access-Control-Allow-Origin']=origin;
  const reply=(status,data)=>Response.json(data,{status,headers});
  if(origin&&origin!==app.origin)return reply(403,{error:'Open colTRAIN at its hosted website.'});
  if(request.method==='OPTIONS')return new Response(null,{status:204,headers:{...headers,'Access-Control-Allow-Methods':'POST, OPTIONS','Access-Control-Allow-Headers':'authorization, apikey, content-type, x-client-info'}});
  if(request.method!=='POST')return reply(405,{error:'Use POST.'});
  const authorization=request.headers.get('Authorization');if(!authorization?.startsWith('Bearer '))return reply(401,{error:'Sign in first.'});
  try{
   const caller=createClient(env('SUPABASE_URL'),env('SUPABASE_ANON_KEY'),{global:{headers:{Authorization:authorization}},auth:{persistSession:false,autoRefreshToken:false}});
   const identity=await caller.auth.getUser();if(identity.error||!identity.data?.user)return reply(401,{error:'Sign in again.'});
   const raw=await request.text();if(raw.length>15000)return reply(400,{error:'Update details are too long.'});
   let body;try{body=JSON.parse(raw);}catch{return reply(400,{error:'Enter valid update details.'});}
   if(!['send','deliver'].includes(body?.action))return reply(400,{error:'Choose an update action.'});
   // Verify platform admin authorization with the caller JWT before constructing a service client.
   const history=await caller.rpc('get_admin_updates',{});if(history.error)return reply(403,{error:'Administrator access required.'});
   let id,created={};
   if(body.action==='send'){
    const p=body.payload||{};if(!uuid.test(p.submission_key||''))return reply(400,{error:'Submission key required.'});
    const sent=await caller.rpc('send_admin_update',{title:p.title,body:p.body,audience:p.audience,submission_key:p.submission_key,store_ids:p.store_ids||[],all_stores:p.all_stores===true,link_url:p.link_url||null});
    if(sent.error)return reply(400,{error:sent.error.message});id=sent.data.id;created=sent.data;
   }else{id=body.update_id;if(!uuid.test(id||'')||!history.data?.some(m=>m.id===id))return reply(404,{error:'Admin update not found.'});}
   const key=env('RESEND_API_KEY'),from=env('COLTRAIN_EMAIL_FROM');let deliveryStatus='processed';let processed=0;
   if(!key||!from||/[\r\n]/.test(from)){deliveryStatus='not_configured';}
   else{
    const service=createClient(env('SUPABASE_URL'),env('SUPABASE_SERVICE_ROLE_KEY'),{auth:{persistSession:false,autoRefreshToken:false}});
    for(let i=0;i<20;i++){
     const claimed=await service.rpc('claim_admin_update_email',{update_id:id,retry_failed:body.action==='deliver'});
     if(claimed.error)throw Error('Email queue could not be opened.');const job=claimed.data;if(!job)break;
     let success=false,providerId=null,failure='Email provider did not confirm this request.';
     try{
      const response=await fetcher('https://api.resend.com/emails',{method:'POST',headers:{Authorization:`Bearer ${key}`,'Content-Type':'application/json','Idempotency-Key':`coltrain-admin-update/${job.id}`},body:JSON.stringify({from,to:[job.email],subject:job.title,text:`${job.body}\n\n${job.link_url?job.link_url+'\n\n':''}Open colTRAIN: ${app.origin}/accounts/\n\nYou received this because email notifications are enabled in your colTRAIN profile. You can turn them off in Account & team settings.`}),signal:AbortSignal.timeout(12000)});
      const data=await response.json();success=response.ok&&typeof data.id==='string';providerId=success?data.id:null;
      if(!success)failure=`Email provider returned ${response.status}.`;
     }catch{/* Never include recipient addresses, credentials or provider payloads in logs/responses. */}
     const saved=await service.rpc('finish_admin_update_email',{delivery_id:job.id,lease:job.lease_id,success,provider_id:providerId,error_message:success?null:failure});
     if(saved.error)throw Error('Email delivery status could not be saved. Retry uses the original delivery key.');
     processed++;if(i<19)await pause(550);
     if(!success)break; // Avoid consuming provider limits or repeatedly failing the same delivery.
    }
   }
   const updated=await caller.rpc('get_admin_updates',{});if(updated.error)throw Error('Update saved. Refresh delivery status.');
   return reply(200,{...created,id,processed,delivery_status:deliveryStatus,update:updated.data.find(m=>m.id===id)});
  }catch{return reply(500,{error:'The request could not be completed. Refresh admin updates before retrying; saved updates use the same submission key.'});}
 };
}
