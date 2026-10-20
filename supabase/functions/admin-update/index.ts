import {createClient} from 'https://esm.sh/@supabase/supabase-js@2.118.0';
import {createAdminUpdateHandler} from './handler.js';
Deno.serve(createAdminUpdateHandler({createClient,env:(name: string)=>Deno.env.get(name)}));
