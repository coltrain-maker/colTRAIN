import {createClient} from 'npm:@supabase/supabase-js@2.118.0';
import {createInviteHandler} from './handler.js';
Deno.serve(createInviteHandler({createClient, env:(name: string)=>Deno.env.get(name)}));
