import {readFile,writeFile} from 'node:fs/promises';
const handler=(await readFile('supabase/functions/admin-update/handler.js','utf8')).replace('export function createAdminUpdateHandler','function createAdminUpdateHandler');
await writeFile('supabase/admin-update-function.ts','import {createClient} from "https://esm.sh/@supabase/supabase-js@2.118.0";\n'+handler+'\nDeno.serve(createAdminUpdateHandler({createClient,env:(name:string)=>Deno.env.get(name)}));\n');
console.log('Built pasteable admin-update Edge Function; contains no secrets.');
