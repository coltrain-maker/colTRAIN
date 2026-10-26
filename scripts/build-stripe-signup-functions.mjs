import {readFile,writeFile} from 'node:fs/promises';
const config=JSON.parse(await readFile('supabase/billing/stripe-sandbox-prices.json','utf8'));
const shared=(await readFile('supabase/functions/_shared/stripe-signup.ts','utf8'))
 .replace("import signupConfiguration from '../../billing/stripe-sandbox-prices.json' with {type:'json'};",'const signupConfiguration='+JSON.stringify(config,null,2)+';');
for(const [name,factory] of [['stripe-checkout','createStripeCheckoutHandler'],['stripe-signup-webhook','createStripeSignupWebhook']]){
 const handler=(await readFile(`supabase/functions/${name}/handler.ts`,'utf8')).replace(/^import .* from '\.\.\/_shared\/stripe-signup.ts';\n/,'');
 await writeFile(`supabase/${name}-function.ts`,"// Generated standalone dashboard function. No credentials are included.\nimport {createClient} from 'npm:@supabase/supabase-js@2.118.0';\n"+shared+'\n'+handler+`\nDeno.serve(${factory}({createClient,env:(name:string)=>Deno.env.get(name)}));\n`);
}
console.log('Built sandbox checkout and signed webhook functions.');
