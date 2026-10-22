import {readFile,writeFile} from 'node:fs/promises';
const handler=(await readFile('supabase/functions/team-support-email/handler.js','utf8')).replace('export function createSupportEmailHandler','function createSupportEmailHandler');
await writeFile('supabase/team-support-email-function.ts','import {createClient} from "https://esm.sh/@supabase/supabase-js@2.118.0";\n'+handler+'\nDeno.serve(createSupportEmailHandler({createClient,env:(name:string)=>Deno.env.get(name)}));\n');
console.log('Built team-support-email function; no secrets.');
