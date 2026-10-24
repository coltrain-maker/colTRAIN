import {createClient} from 'npm:@supabase/supabase-js@2.118.0';
import {createStripeSandboxHandler} from './handler.ts';
Deno.serve(createStripeSandboxHandler({createClient,env:(name:string)=>Deno.env.get(name)}));
