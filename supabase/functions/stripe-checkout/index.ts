import {createClient} from 'npm:@supabase/supabase-js@2.118.0';
import {createStripeCheckoutHandler} from './handler.ts';
Deno.serve(createStripeCheckoutHandler({createClient,env:(name:string)=>Deno.env.get(name)}));
