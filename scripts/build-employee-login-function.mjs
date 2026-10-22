import {readFile,writeFile} from 'node:fs/promises';
const handler=(await readFile('supabase/functions/employee-login/handler.js','utf8')).replace('export function createEmployeeLoginHandler','function createEmployeeLoginHandler');
await writeFile('supabase/employee-login-function.ts','import {createClient} from "https://esm.sh/@supabase/supabase-js@2.118.0";\n'+handler+'\nDeno.serve(createEmployeeLoginHandler({createClient,env:(name:string)=>Deno.env.get(name)}));\n');
console.log('Built employee-login function; no secrets.');
