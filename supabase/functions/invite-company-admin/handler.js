const uuid = /^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$/i;
export function createCompanyInviteHandler({createClient, env, log=details=>console.warn('colTRAIN company invitation email',details)}) {
 return async request => {
  let appUrl;
  try {
   appUrl = new URL(env('COLTRAIN_APP_URL')||'');
   if(appUrl.protocol !== 'https:' || appUrl.username || appUrl.password || appUrl.search || appUrl.hash || appUrl.pathname !== '/' || /^(localhost|127\.|\[::1\])/.test(appUrl.hostname)) throw new Error();
  } catch { return Response.json({error:'Email invitations are not available yet. Please contact colTRAIN support.'},{status:503}); }
  const origin = request.headers.get('Origin');
  const headers = {'Vary':'Origin','Cache-Control':'no-store'};
  if(origin === appUrl.origin) headers['Access-Control-Allow-Origin'] = origin;
  const reply = (status, body) => Response.json(body,{status,headers});
  if(origin && origin !== appUrl.origin) return reply(403,{error:'Open colTRAIN at its hosted website to send invitations.'});
  if(request.method === 'OPTIONS') return new Response(null,{status:204,headers:{...headers,'Access-Control-Allow-Methods':'POST, OPTIONS','Access-Control-Allow-Headers':'authorization, apikey, content-type, x-client-info'}});
  if(request.method !== 'POST') return reply(405,{error:'Use POST.'});
  const authorization = request.headers.get('Authorization');
  if(!authorization?.startsWith('Bearer ')) return reply(401,{error:'Sign in before inviting an administrator.'});
  try {
   const url = env('SUPABASE_URL'), anon = env('SUPABASE_ANON_KEY'), secret = env('SUPABASE_SERVICE_ROLE_KEY');
   if(!url || !anon || !secret) return reply(503,{error:'Email invitations are not available yet. Please contact colTRAIN support.'});
   const caller = createClient(url,anon,{global:{headers:{Authorization:authorization}},auth:{persistSession:false,autoRefreshToken:false}});
   const {data:identity,error:authError} = await caller.auth.getUser();
   if(authError || !identity?.user) return reply(401,{error:'Your session expired. Sign in again.'});
   const text = await request.text();
   if(text.length>4096) return reply(400,{error:'Invitation details are too long.'});
   let body;try{body=JSON.parse(text);}catch{return reply(400,{error:'Enter valid invitation details.'});}
   if(!body || !uuid.test(body.company||'') || !['create','resend'].includes(body.action) || (body.action==='resend'&&!uuid.test(body.invitation||''))) return reply(400,{error:'Choose a store and a valid invitation.'});
   if(body.action==='create' && (typeof body.name!=='string'||!body.name.trim()||body.name.trim().length>120||typeof body.email!=='string'||body.email.length>254||!['billing','training','both'].includes(body.capability))) return reply(400,{error:'Enter the administrator name, email, and role.'});
   const {data,error} = await caller.rpc('prepare_company_invitation',{company:body.company,account_email:body.email||'',person_name:body.name||'',capability:body.capability||'training',store:body.store||null,replace_invitation:body.action==='resend'?body.invitation:null});
   if(error) {
    const known = /Company owner access required|Choose administrator access|Enter a valid email address|Enter the administrator name|Store is not in this company|Use the pending invitation|already has owner access|Invitation not available|Wait one minute/;
    return reply(400,{error:known.test(error.message)?error.message:'Unable to prepare the invitation. Contact colTRAIN support.'});
   }
   const invite = data;
   if(!invite) throw new Error('Missing invitation');
   const callback = new URL('/accounts/',appUrl);
   callback.searchParams.set('company_invitation_id',invite.id);
   // No caller-provided redirect, email, or metadata reaches this privileged client.
   // All invitation details come back from the caller-authorized database operation.
   const server = createClient(url,secret,{auth:{persistSession:false,autoRefreshToken:false}});
   let {error:emailError} = await server.auth.admin.inviteUserByEmail(invite.email,{redirectTo:callback.href,data:{full_name:invite.name}});
   if(emailError && ['email_exists','user_already_exists'].includes(emailError.code||'')) {
    // Existing test/pilot accounts receive a recovery link to set their password.
    ({error:emailError} = await server.auth.resetPasswordForEmail(invite.email,{redirectTo:callback.href}));
   }
   const status = emailError?'failed':'sent';
   const {error:statusError} = await server.rpc('record_company_invitation_email',{invitation:invite.id,delivery_status:status});
   // Log only identifiers and error codes, never email links, tokens, or credentials.
   if(statusError) log({event:'delivery_status_failed',invitation_id:invite.id,code:statusError.code||'unknown'});
   if(emailError) {
    log({event:'email_request_failed',invitation_id:invite.id,code:emailError.code||'unknown',status:emailError.status});
    const limited = emailError.status===429 || emailError.code==='over_email_send_rate_limit';
    const restricted = emailError.code==='email_address_not_authorized';
    const message = limited?'The invitation was saved, but the email sending limit has been reached. Contact colTRAIN support before trying again.':restricted?'The invitation was saved, but the email service is not configured to send to this address. Contact colTRAIN support.':'The invitation was saved, but the email service could not send it. Contact colTRAIN support before trying again.';
    return reply(limited?429:502,{error:message,invitation_id:invite.id});
   }
   return reply(200,{invitation_id:invite.id,message:statusError?'Invitation email requested, but its status could not be saved. Contact colTRAIN support before resending.':'Invitation email requested. Ask the administrator to check their inbox and spam folder.'});
  } catch { return reply(500,{error:'The invitation could not be completed. Check pending administrator invitations before trying again.'}); }
 };
}
