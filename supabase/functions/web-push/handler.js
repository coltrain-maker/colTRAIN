export function createWebPushHandler({createClient,env,sendNotification}){
 return async request=>{
  let app;try{app=new URL(env('COLTRAIN_APP_URL'));if(app.protocol!=='https:'||app.pathname!=='/'||app.search||app.hash||app.username||app.password)throw Error();}catch{return Response.json({error:'Website configuration required'},{status:503});}
  const origin=request.headers.get('Origin'),headers={'Vary':'Origin','Cache-Control':'no-store'};
  if(origin===app.origin)headers['Access-Control-Allow-Origin']=origin;
  const reply=(status,data)=>Response.json(data,{status,headers});
  if(origin&&origin!==app.origin)return reply(403,{error:'Open colTRAIN to continue.'});
  if(request.method==='OPTIONS')return new Response(null,{status:204,headers:{...headers,'Access-Control-Allow-Methods':'POST, OPTIONS','Access-Control-Allow-Headers':'authorization, apikey, content-type, x-client-info'}});
  if(request.method!=='POST')return reply(405,{error:'Use POST'});
  try{
   let body={};try{body=await request.json();}catch{}
   const publicKey=env('WEB_PUSH_PUBLIC_KEY'),privateKey=env('WEB_PUSH_PRIVATE_KEY'),subject=env('WEB_PUSH_SUBJECT');
   if(body.action==='config'){
    const authorization=request.headers.get('Authorization');if(!authorization?.startsWith('Bearer '))return reply(401,{error:'Sign in first'});
    const caller=createClient(env('SUPABASE_URL'),env('SUPABASE_ANON_KEY'),{global:{headers:{Authorization:authorization}},auth:{persistSession:false,autoRefreshToken:false}});
    const identity=await caller.auth.getUser();if(identity.error||!identity.data?.user)return reply(401,{error:'Sign in again'});
    return publicKey&&privateKey&&subject?reply(200,{public_key:publicKey}):reply(503,{error:'Push configuration required'});
   }
   const secret=env('SUPPORT_WORKER_SECRET'),provided=request.headers.get('x-coltrain-support-worker');
   if(!secret||secret.length<32||!provided||provided.length>512)return reply(401,{error:'Worker authentication failed'});
   const digest=async s=>new Uint8Array(await crypto.subtle.digest('SHA-256',new TextEncoder().encode(s)));
   const [a,b]=await Promise.all([digest(secret),digest(provided)]);let diff=0;for(let i=0;i<a.length;i++)diff|=a[i]^b[i];if(diff)return reply(401,{error:'Worker authentication failed'});
   if(!publicKey||!privateKey||!subject)return reply(503,{error:'Push configuration required'});
   const service=createClient(env('SUPABASE_URL'),env('SUPABASE_SERVICE_ROLE_KEY'),{auth:{persistSession:false,autoRefreshToken:false}});let processed=0;
   const deadline=Date.now()+45000;
   for(let i=0;i<50&&Date.now()<deadline;i++){
    const claim=await service.rpc('claim_web_push',{});if(claim.error)throw Error();const job=claim.data;if(!job)break;if(job.skip)continue;
    // Defend privileged outbound HTTP independently of database validation.
    const endpoint=new URL(job.subscription.endpoint);
    if(endpoint.protocol!=='https:'||endpoint.username||endpoint.password||endpoint.port||!(/^(fcm\.googleapis\.com|updates\.push\.services\.mozilla\.com|web\.push\.apple\.com|[a-zA-Z0-9-]+\.notify\.windows\.com)$/).test(endpoint.hostname))throw Error();
    let outcome='failed';
    try{await sendNotification(job.subscription,JSON.stringify({count:job.count}),{vapidDetails:{subject,publicKey,privateKey},TTL:300,urgency:'normal',topic:'coltrain-unread',timeout:10000});outcome='sent';}
    catch(error){if(typeof error==='object'&&error!==null&&'statusCode' in error&&[404,410].includes(Number(error.statusCode)))outcome='expired';}
    const saved=await service.rpc('finish_web_push',{subscription_id:job.id,claim_lease:job.lease,unread_ids:job.ids,outcome});if(saved.error)throw Error();processed++;
   }
   return reply(200,{processed});
  }catch{return reply(500,{error:'Push delivery will retry. In-app updates remain available.'});}
 };
}
