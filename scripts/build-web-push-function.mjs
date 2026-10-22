import {readFile,writeFile} from 'node:fs/promises';
let handler=(await readFile('supabase/functions/web-push/handler.js','utf8'))
 .replace('export function createWebPushHandler({createClient,env,sendNotification})','function createWebPushHandler({createClient,env,sendNotification}: PushDependencies)')
 .replace('return async request=>','return async (request: Request)=>')
 .replace("headers={'Vary':'Origin'","headers: Record<string,string>={'Vary':'Origin'")
 .replace('const reply=(status,data)=>','const reply=(status: number,data: unknown)=>')
 .replace('let body={}','let body: {action?: string}={}')
 .replace('const digest=async s=>','const digest=async (s: string)=>');
const imports='import {createClient} from "npm:@supabase/supabase-js@2.118.0";\nimport webpush from "npm:web-push@3.6.7";\n';
const types=`type PushDependencies = {
 createClient: typeof createClient;
 env: (name: string)=>string;
 sendNotification: (subscription: {endpoint: string;keys: {p256dh: string;auth: string}},payload: string,options: Record<string,unknown>)=>Promise<unknown>;
};\n`;
await writeFile('supabase/web-push-function.ts',imports+types+handler+'\nDeno.serve(createWebPushHandler({createClient,env:(name:string)=>Deno.env.get(name)||"",sendNotification:webpush.sendNotification.bind(webpush)}));\n');
console.log('Built web-push function; no credentials included.');
