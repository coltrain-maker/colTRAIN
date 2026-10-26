import type {createClient as SupabaseFactory} from 'npm:@supabase/supabase-js@2.118.0';
import signupConfiguration from '../../billing/stripe-sandbox-prices.json' with {type:'json'};
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
