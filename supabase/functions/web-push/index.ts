import {createClient} from "npm:@supabase/supabase-js@2.118.0";
import webpush from "npm:web-push@3.6.7";
import {createWebPushHandler} from "./handler.js";
Deno.serve(createWebPushHandler({createClient,env:(name:string)=>Deno.env.get(name),sendNotification:webpush.sendNotification.bind(webpush)}));
