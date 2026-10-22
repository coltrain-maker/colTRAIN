import {createClient} from "https://esm.sh/@supabase/supabase-js@2.118.0";
import {createEmployeeLoginHandler} from './handler.js';
Deno.serve(createEmployeeLoginHandler({createClient,env:(name:string)=>Deno.env.get(name)}));
