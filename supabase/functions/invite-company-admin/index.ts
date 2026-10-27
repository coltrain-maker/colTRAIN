import {createClient} from 'npm:@supabase/supabase-js@2.118.0';
import {createCompanyInviteHandler} from './handler.js';
Deno.serve(createCompanyInviteHandler({createClient, env:(name: string)=>Deno.env.get(name)}));
