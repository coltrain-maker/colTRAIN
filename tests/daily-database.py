"""Isolated Daily SQL/RLS/import checks. No hosted changes or mail/deploys."""
from pathlib import Path
import concurrent.futures
import copy
import json
import subprocess
import time
import uuid

root=Path(__file__).resolve().parent.parent
subprocess.run(['python','scripts/build-daily-pilot-import.py'],cwd=root,check=True)
payload=json.loads((root/'courses/daily/pilot-v1.0.0/prepared-import.json').read_text())
script=(root/'supabase/daily-imports/PILOT_10_IMPORT_DRAFTS.sql').read_text()
name='coltrain-daily-'+uuid.uuid4().hex[:10]
image='postgres:17-alpine@sha256:b0f9560a2de083e2cc7382e75f808c7381a32852a7ec49117deedb300e552b24'
checks=0

def sql(text,check=True):
 r=subprocess.run(['docker','exec','-i',name,'psql','-X','-qAt','-v','ON_ERROR_STOP=1','-U','postgres'],input=text,text=True,capture_output=True)
 if check and r.returncode: raise AssertionError(r.stderr)
 return r

def uid(n):return '00000000-0000-0000-0000-'+str(n).zfill(12)
def mid(n):return '20000000-0000-0000-0000-'+str(n).zfill(12)
def actor(n,query,check=True):return sql(f"begin;set local role authenticated;set local request.jwt.claim.sub='{uid(n)}';{query};commit;",check)
def ok(value,message):
 global checks
 assert value,message
 checks+=1

def reject(n,query,expected):
 r=actor(n,query,False)
 ok(r.returncode!=0 and expected in r.stderr,(query,r.stderr,expected))
def data(n,query):return json.loads(actor(n,query).stdout.strip())
def snapshot():return sql("select jsonb_build_array((select jsonb_agg(to_jsonb(t)) from public.training_courses t),(select jsonb_agg(to_jsonb(t)) from public.training_assignments t),(select jsonb_agg(to_jsonb(t)) from public.training_trophies t),(select jsonb_agg(to_jsonb(t)) from private.training_point_awards t));").stdout

subprocess.run(['docker','run','--rm','-d','--name',name,'--network','none','-e','POSTGRES_HOST_AUTH_METHOD=trust',image],check=True,capture_output=True)
try:
 for i in range(80):
  if subprocess.run(['docker','exec',name,'pg_isready','-h','127.0.0.1','-U','postgres'],capture_output=True).returncode==0:break
  time.sleep(.25)
 else:raise RuntimeError('PostgreSQL not ready')
 sql((root/'tests/supabase-auth-fixture.sql').read_text())
 # Preserve the tested migration-012 contract; latest sequencing has its own integration suite.
 for migration in sorted((root/'supabase/migrations').glob('*.sql')):
  if migration.name<='202610190012_daily.sql':sql(migration.read_text())
 sql("""insert into auth.users(id,email,email_confirmed_at)
 select ('00000000-0000-0000-0000-'||lpad(n::text,12,'0'))::uuid,'daily'||n||'@example.test',now() from generate_series(120,125) n;
 insert into public.profiles(user_id,full_name) select id,'Daily user' from auth.users where email like 'daily%@example.test';
 insert into public.platform_admins(user_id) values('00000000-0000-0000-0000-000000000120');
 insert into public.organizations(id,name) values('10000000-0000-0000-0000-000000000120','Daily A'),('10000000-0000-0000-0000-000000000123','Daily B');
 insert into public.organization_memberships(id,organization_id,user_id,email,role)
 select ('20000000-0000-0000-0000-'||lpad(n::text,12,'0'))::uuid,
 case when n in (123,124) then '10000000-0000-0000-0000-000000000123' else '10000000-0000-0000-0000-000000000120' end::uuid,
 ('00000000-0000-0000-0000-'||lpad(n::text,12,'0'))::uuid,'daily'||n||'@example.test',case when n in (121,123) then 'manager' else 'employee' end
 from generate_series(121,125) n;
 """)
 store='10000000-0000-0000-0000-000000000120';other='10000000-0000-0000-0000-000000000123'
 before=snapshot();sql(script);sql(script)
 ok(snapshot()==before,'Daily import changed full-course records')
 ok(sql('select count(*) from public.daily_modules').stdout.strip()=='10','10 modules exactly after rerun')
 for item in payload:
  module=item['module'];identifier=module['id']
  row=json.loads(sql(f"select to_jsonb(d)-'published'-'created_at' from public.daily_modules d where id='{identifier}'").stdout)
  ok(row==module,module['code']+' full learner content fidelity')
  source=json.loads(sql(f"select source_document from private.daily_editorial where module_id='{identifier}'").stdout)
  ok(source==item['source_document'],module['code']+' approved source fidelity')
  actual=json.loads(sql(f"select jsonb_agg(to_jsonb(q) order by position) from public.daily_questions q where module_id='{identifier}'").stdout)
  ok(actual==item['questions'],module['code']+' exact questions/options')
  keys=json.loads(sql(f"select jsonb_agg(to_jsonb(k) order by question_id) from private.daily_answer_keys k where module_id='{identifier}'").stdout)
  ok(keys==item['keys'],module['code']+' private keys fidelity')
  text=json.dumps(row)
  ok('answer_key' not in text and 'reviewer_sections' not in text and 'complete_markdown' not in text and all(k['explanation'] not in text for k in item['keys']),module['code']+' no answer/reviewer payload')
 ok(sql('select count(*) from public.daily_modules where published').stdout.strip()=='0','imports stay drafts')
 ok(sql('select count(*) from public.daily_releases').stdout.strip()=='0','imports never released')
 ok(sql('select count(*) from public.daily_assignments').stdout.strip()=='0','imports never assigned')
 ok(len(data(120,f"select public.get_daily_workspace('{store}')")['modules'])==10,'admin sees drafts')
 ok(data(121,f"select public.get_daily_workspace('{store}')")['modules']==[],'manager cannot see drafts')
 ok(actor(122,'select count(*) from public.daily_modules').stdout.strip()=='0','employee direct draft RLS')
 module=payload[0]['module']['id'];second=payload[1]['module']['id'];q=payload[0]['questions'][0];correct=payload[0]['keys'][0]['correct_option'];wrong=(correct+1)%4
 reject(122,'select * from private.daily_answer_keys','permission denied')
 reject(121,'select * from private.daily_editorial','permission denied')
 reject(121,'select * from private.daily_attempts','permission denied')
 reject(121,f"select public.publish_daily_module('{module}')",'Administrator access required')
 reject(121,f"select public.release_daily_module('{store}','{module}')",'Administrator access required')
 reject(120,f"select public.release_daily_module('{store}','{module}')",'Publish this Daily module first')
 reject(121,f"select public.assign_daily_module('{module}','{store}',all_employees=>true)",'Release this Daily module')
 for item in payload:actor(120,f"select public.publish_daily_module('{item['module']['id']}')")
 actor(120,f"select public.publish_daily_module('{module}')")
 for query in [f"update public.daily_modules set title='Changed' where id='{module}'",f"delete from public.daily_modules where id='{module}'",f"update public.daily_questions set prompt='Changed' where module_id='{module}'",f"update private.daily_answer_keys set correct_option=0 where module_id='{module}'"]:
  r=sql(query,False);ok(r.returncode!=0 and 'immutable' in r.stderr,'published content/key freeze')
 sql(script);ok(sql('select count(*) from public.daily_modules where published').stdout.strip()=='10','rerun retains publication')
 actor(120,f"select public.release_daily_module('{store}','{module}')")
 actor(120,f"select public.release_daily_module('{store}','{second}')")
 ok(actor(122,'select count(*) from public.daily_modules').stdout.strip()=='0','release alone does not expose lesson/quiz before assignment')
 ok(len(data(122,f"select public.get_daily_workspace('{store}')")['modules'])==2,'employee released catalog has summaries')
 reject(123,f"select public.get_daily_workspace('{store}')",'Active store access required')
 reject(121,f"select public.assign_daily_module('{module}','{other}',all_employees=>true)",'Manager access required')
 reject(121,f"select public.assign_daily_module('{module}','{store}',array['{mid(124)}'::uuid])",'Employee is not active')
 reject(122,f"select public.assign_daily_module('{module}','{store}',all_employees=>true)",'Manager access required')
 dept=actor(121,f"select public.create_training_department('{store}','Paint')").stdout.strip()
 foreign=actor(123,f"select public.create_training_department('{other}','Other')").stdout.strip()
 actor(121,f"select public.set_training_departments('{mid(122)}',array['{dept}'::uuid])")
 reject(121,f"select public.assign_daily_module('{module}','{store}',department_ids=>array['{foreign}'::uuid])",'Department is not in this store')
 reject(121,f"select public.assign_daily_module('{module}','{store}')",'Choose at least one')
 count=actor(121,f"select public.assign_daily_module('{module}','{store}',array['{mid(122)}'::uuid],array['{dept}'::uuid],start_date=>current_date+2)").stdout.strip()
 ok(count=='1','individual + department deduplicated')
 assignment=sql(f"select id from public.daily_assignments where membership_id='{mid(122)}' and module_id='{module}'").stdout.strip()
 reject(122,f"select public.get_daily_module('{assignment}')",'Active available Daily assignment required')
 ok(actor(122,'select count(*) from public.daily_questions').stdout.strip()=='0','future quiz direct RLS blocked')
 actor(121,f"select public.assign_daily_module('{module}','{store}',all_employees=>true,start_date=>current_date-1)")
 ok(sql(f"select count(*) from public.daily_assignments where module_id='{module}'").stdout.strip()=='2','all employees excludes manager and includes second employee')
 def submit(option,key=None,a=assignment):
  body=json.dumps([{'question_id':q['id'],'option':option}]);key=key or str(uuid.uuid4())
  return f"select public.submit_daily_check('{a}','{body}'::jsonb,'{key}')"
 reject(122,submit(correct),'Open your Daily module first')
 reject(125,f"select public.get_daily_module('{assignment}')",'Active available Daily assignment required')
 lesson=data(122,f"select public.get_daily_module('{assignment}')")
 ok(lesson['sections']==payload[0]['module']['sections'] and lesson['questions'][0]['id']==q['id'],'learner opens exact teaching and question')
 ok('correct_option' not in json.dumps(lesson),'pre-submit lesson has no key')
 reject(122,"update public.daily_assignments set completed_at=now()",'permission denied')
 reject(122,submit('0'),'Invalid Daily answers')
 reject(122,f"select public.submit_daily_check('{assignment}','[]',gen_random_uuid())",'Answer every Daily question')
 reject(122,f"select public.submit_daily_check('{assignment}','[{{\"question_id\":\"not-my-question\",\"option\":0}}]',gen_random_uuid())",'Invalid Daily answers')
 ok(sql(f"select attempt_count from public.daily_assignments where id='{assignment}'").stdout.strip()=='0','bad submissions do not consume attempts')
 token=str(uuid.uuid4());failed=data(122,submit(wrong,token));repeated=data(122,submit(correct,token))
 ok(failed==repeated and not failed['completed'],'idempotency ignores changed retry payload')
 ok(failed['feedback'][0]['correct_option']==correct and failed['feedback'][0]['explanation']==payload[0]['keys'][0]['explanation'],'feedback only after submission')
 reject(121,f"select public.get_daily_result('{assignment}')",'Only the active Daily learner')
 ok(data(122,f"select public.get_daily_result('{assignment}')")==failed,'own last result reload')
 for _ in range(3):data(122,submit(wrong))
 ok(sql(f"select attempt_count from public.daily_assignments where id='{assignment}'").stdout.strip()=='4','Daily permits retry beyond full-course limit')
 # Row locks make simultaneous same-key submissions one stored result.
 concurrent_key=str(uuid.uuid4())
 with concurrent.futures.ThreadPoolExecutor(max_workers=2) as pool:
  results=list(pool.map(lambda _:data(122,submit(wrong,concurrent_key)),range(2)))
 ok(results[0]==results[1],'concurrent same-key result identical')
 ok(sql(f"select attempt_count from public.daily_assignments where id='{assignment}'").stdout.strip()=='5','concurrent same-key only one attempt')
 actor(120,f"select public.release_daily_module('{store}','{module}',false)")
 ok(data(122,f"select public.get_daily_module('{assignment}')")['id']==module,'withdrawn release retains existing assignment')
 sql(f"update public.daily_assignments set last_activity_at=now()-interval '10 minutes' where id='{assignment}'")
 ok(actor(122,f"select public.record_daily_activity('{assignment}')").stdout.strip()=='60','activity gap capped at 60 seconds')
 ok(actor(122,f"select public.record_daily_activity('{assignment}')").stdout.strip()=='60','immediate heartbeat cannot double-count')
 reject(125,f"select public.record_daily_activity('{assignment}')",'Open your active Daily assignment')
 success=data(122,submit(correct));ok(success['completed'],'correct answers complete Daily')
 ok(data(122,submit(correct,concurrent_key))==results[0],'old idempotency key returns original wrong result after completion')
 reject(122,submit(correct),'Daily module already completed')
 ok(actor(122,f"select public.record_daily_activity('{assignment}')").stdout.strip()=='60','completed review does not add activity')
 actor(120,f"select public.release_daily_module('{store}','{module}')")
 actor(121,f"select public.assign_daily_module('{module}','{store}',all_employees=>true,start_date=>current_date+4)")
 ok(sql(f"select completed_at is not null and available_on<current_date and attempt_count=6 from public.daily_assignments where id='{assignment}'").stdout.strip()=='t','reassignment preserves completed work and started availability')
 ok(snapshot()==before,'Daily completion adds no full-course points/trophy/progress')
 ok(len(data(121,f"select public.get_daily_workspace('{store}')")['assignments'])==2,'manager sees store summary')
 ok(len(data(122,f"select public.get_daily_workspace('{store}')")['assignments'])==1,'employee sees only own assignment')
 ok(data(123,f"select public.get_daily_workspace('{other}')")['modules']==[],'other store sees no released modules')
 sql(f"update public.organization_memberships set status='inactive',deactivated_at=now() where id='{mid(122)}'")
 reject(122,f"select public.get_daily_module('{assignment}')",'Active available Daily assignment required')
 reject(122,f"select public.get_daily_result('{assignment}')",'Only the active Daily learner')
 reject(122,f"select public.get_daily_workspace('{store}')",'Active store access required')
 ok(actor(122,'select count(*) from public.daily_assignments').stdout.strip()=='0','inactive learner direct RLS blocked')
 # A changed record late in a batch rolls back earlier inserts too.
 sql('delete from private.daily_editorial where false')
 first=payload[0]['module']['id']
 changed=script.replace('Paint Sheen: Recognize the Finish','Changed approved title')
 r=sql(changed,False);ok(r.returncode!=0 and 'content differs' in r.stderr,'different import rejected')
 ok(snapshot()==before,'conflicting import leaves full courses unchanged')
 # Remove last draft from a fresh database is tested below using a separate transaction rollback.
 rollback_script=script.replace("begin;\ndo $dailyimport$","begin;\nupdate public.daily_assignments set active_seconds=999;\ndo $dailyimport$").replace('Write a Useful Shift Handoff','Conflicting handoff title')
 r=sql(rollback_script,False);ok(r.returncode!=0 and 'content differs' in r.stderr,'late batch mismatch aborts')
 ok(sql(f"select active_seconds from public.daily_assignments where id='{assignment}'").stdout.strip()=='60','whole failed transaction rolled back')
 ok(sql("select has_function_privilege('anon','public.submit_daily_check(uuid,jsonb,uuid)','execute')").stdout.strip()=='f','anonymous submit execute denied')
 ok(sql("select has_table_privilege('anon','public.daily_modules','select')").stdout.strip()=='f','anonymous table access denied')
 # Two-question fixtures prove duplicate handling, all-correct completion and publication readiness.
 fixture=str(uuid.uuid4())
 sql(f"insert into public.daily_modules(id,code,version,title,academy,skill_level,sections,estimated_minutes) values('{fixture}','CD-9999','1.0.0','Two-question fixture','Operations & Leadership','foundations','[{{\"heading\":\"Learn it\",\"content_markdown\":\"Fixture\"}}]',3)")
 for position in [1,2]:
  sql(f"insert into public.daily_questions(module_id,id,position,prompt,options) values('{fixture}','T-Q{position}',{position},'Fixture question','[\"One\",\"Two\",\"Three\",\"Four\"]')")
 reject(120,f"select public.publish_daily_module('{fixture}')",'Daily questions and private keys are incomplete')
 for position in [1,2]:
  sql(f"insert into private.daily_answer_keys(module_id,question_id,correct_option,explanation,teaching_reference) values('{fixture}','T-Q{position}',0,'Fixture explanation','Learn it')")
 actor(120,f"select public.publish_daily_module('{fixture}')")
 actor(120,f"select public.release_daily_module('{store}','{fixture}')")
 actor(121,f"select public.assign_daily_module('{fixture}','{store}',array['{mid(125)}'::uuid],start_date=>current_date-1)")
 double=sql(f"select id from public.daily_assignments where module_id='{fixture}'").stdout.strip()
 data(125,f"select public.get_daily_module('{double}')")
 body=json.dumps([{'question_id':'T-Q1','option':0},{'question_id':'T-Q1','option':0}])
 reject(125,f"select public.submit_daily_check('{double}','{body}',gen_random_uuid())",'Invalid Daily answers')
 body=json.dumps([{'question_id':'T-Q1','option':0},{'question_id':'T-Q2','option':1}])
 partial=data(125,f"select public.submit_daily_check('{double}','{body}',gen_random_uuid())")
 ok(not partial['completed'] and partial['correct_count']==1,'two-question completion requires both correct')
 body=json.dumps([{'question_id':'T-Q1','option':0},{'question_id':'T-Q2','option':0}])
 with concurrent.futures.ThreadPoolExecutor(max_workers=2) as pool:
  concurrent=list(pool.map(lambda _:actor(125,f"select public.submit_daily_check('{double}','{body}',gen_random_uuid())",False),range(2)))
 ok(sum(r.returncode==0 for r in concurrent)==1 and any('already completed' in r.stderr for r in concurrent),'different-key concurrent passes complete once')
 ok(sql(f"select attempt_count from public.daily_assignments where id='{double}'").stdout.strip()=='2','one partial plus one completed attempt')
 # A constraint error in the final new draft must roll back nine preceding new drafts.
 altered=copy.deepcopy(payload)
 for item in altered:
  identifier=str(uuid.uuid4());item['module']['id']=identifier;item['module']['version']='9.0.0'
  for qrow in item['questions']:qrow['module_id']=identifier
  for keyrow in item['keys']:keyrow['module_id']=identifier
 altered[-1]['keys'][0]['correct_option']=99
 start=script.index('$dailypayload$')+len('$dailypayload$');end=script.index('$dailypayload$',start)
 malformed=script[:start]+json.dumps(altered)+script[end:]
 r=sql(malformed,False)
 ok(r.returncode!=0 and 'check constraint' in r.stderr,'invalid late private key rejected')
 ok(sql("select count(*) from public.daily_modules where version='9.0.0'").stdout.strip()=='0','late error leaves no partially imported drafts')
 ok(snapshot()==before,'all Daily operations preserve full-course state')
 print(f'Passed {checks} Daily database checks: source/import fidelity, private keys, store/role isolation, dated assignments, deduplication, server grading, unlimited learning retries, idempotency/concurrency, completion persistence, activity bounds, published-content freeze and full-course isolation.')
finally:
 subprocess.run(['docker','rm','-f',name],capture_output=True)
