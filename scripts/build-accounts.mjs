import {readFile,writeFile,mkdir} from 'node:fs/promises';
import {existsSync} from 'node:fs';
import {build} from 'esbuild';
if(existsSync('.env.local'))process.loadEnvFile('.env.local');
const publicConfig=existsSync('accounts/public-config.json')?JSON.parse(await readFile('accounts/public-config.json','utf8')):{};
const url=process.env.SUPABASE_URL||publicConfig.supabaseUrl||'https://flhdeftduysnjvqnhhee.supabase.co';
const key=process.env.SUPABASE_PUBLISHABLE_KEY||publicConfig.supabasePublishableKey||'';
if(!/^https:\/\/[a-z0-9-]+\.supabase\.co$/.test(url))throw new Error('SUPABASE_URL must be the project HTTPS URL.');
if(key&&!key.startsWith('sb_publishable_')){
 let role;
 try{role=JSON.parse(Buffer.from(key.split('.')[1],'base64url').toString()).role;}catch{}
 if(role!=='anon')throw new Error('Only a Supabase publishable key or legacy anon key may be bundled. Never use a secret/service-role key.');
}
const bundle=await build({entryPoints:['accounts/accounts.js'],bundle:true,write:false,format:'iife',platform:'browser',target:['es2022'],minify:true,define:{__SUPABASE_URL__:JSON.stringify(url),__SUPABASE_KEY__:JSON.stringify(key)},logLevel:'warning'});
const template=await readFile('accounts/template.html','utf8');
const css=(await readFile('styles.css','utf8'))+'\n'+(await readFile('accounts/accounts.css','utf8'))+'\n'+(await readFile('accounts/training.css','utf8'))+'\n'+(await readFile('accounts/team-corner.css','utf8'));
// Escape closing script sequences in the generated inline bundle.
const js=bundle.outputFiles[0].text.replace(/<\/script/gi,'<\\/script');
await mkdir('accounts',{recursive:true});
const html=template.replace('</head>',()=>'<style>'+css+'</style></head>').replace('</body>',()=>'<script>'+js+'</script></body>');
await writeFile('accounts/index.html',html);
await mkdir('design',{recursive:true});
await writeFile('design/coltrain-accounts.html',html);
console.log(key?'Built account interface with public Supabase configuration.':'Built account interface in unconfigured state; SUPABASE_PUBLISHABLE_KEY is still required.');
