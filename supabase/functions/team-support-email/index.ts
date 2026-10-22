import {createClient} from "https://esm.sh/@supabase/supabase-js@2.118.0";
import {createSupportEmailHandler} from "./handler.js";
Deno.serve(createSupportEmailHandler({createClient,env:(name:string)=>Deno.env.get(name)}));
