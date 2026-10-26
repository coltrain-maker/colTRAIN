import {createClient} from 'npm:@supabase/supabase-js@2.118.0';
import {createStripeSignupWebhook} from './handler.ts';
Deno.serve(createStripeSignupWebhook({createClient,env:(name:string)=>Deno.env.get(name)}));
