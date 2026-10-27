import {readFile,writeFile} from 'node:fs/promises';
const handler=await readFile('supabase/functions/invite-company-admin/handler.js','utf8');
const typed=handler.replace('export function','function')
 .replace("log=details=>console.warn('colTRAIN company invitation email',details)})", "log=details=>console.warn('colTRAIN company invitation email',details)}: {createClient:SupabaseFactory;env:(name:string)=>string|undefined;log?:(details:Record<string,unknown>)=>void})")
 .replace('return async request =>','return async (request:Request) =>')
 .replace('const headers =','const headers:Record<string,string> =')
 .replace('const reply = (status, body)', 'const reply = (status:number, body:unknown)');
await writeFile('supabase/invite-company-admin-function.ts',"import {createClient} from 'npm:@supabase/supabase-js@2.118.0';\ntype SupabaseFactory=typeof createClient;\n"+typed+"\nDeno.serve(createCompanyInviteHandler({createClient,env:(name: string)=>Deno.env.get(name)}));\n");
