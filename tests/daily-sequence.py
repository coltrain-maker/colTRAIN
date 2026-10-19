"""Latest Daily automatic enrollment, level progression and badge-readiness checks."""
from pathlib import Path
import concurrent.futures
import json
import subprocess
import sys
import time
import uuid

root=Path(__file__).resolve().parent.parent
subprocess.run(['python','scripts/build-daily-pilot-import.py'],cwd=root,check=True)
payload=json.loads((root/'courses/daily/pilot-v1.0.0/prepared-import.json').read_text())
name='coltrain-daily-path-'+uuid.uuid4().hex[:10]
image='postgres:17-alpine@sha256:b0f9560a2de083e2cc7382e75f808c7381a32852a7ec49117deedb300e552b24'
checks=0
store='10000000-0000-0000-0000-000000000140';other='10000000-0000-0000-0000-000000000141'
def person(n):return '00000000-0000-0000-0000-'+str(n).zfill(12)
def member(n):return '20000000-0000-0000-0000-'+str(n).zfill(12)
def sql(text,check=True):
 r=subprocess.run(['docker','exec','-i',name,'psql','-X','-qAt','-v','ON_ERROR_STOP=1','-U','postgres'],input=text,text=True,capture_output=True)
 if check and r.returncode:raise AssertionError(r.stderr)
 return r

def actor(n,text,check=True):return sql(f"begin;set local role authenticated;set local request.jwt.claim.sub='{person(n)}';{text};commit;",check)
def ok(value,msg):
 global checks
 assert value,msg
 checks+=1

def reject(n,text,needle):
 r=actor(n,text,False);ok(r.returncode!=0 and needle in r.stderr,(needle,r.stderr))
def workspace(n=142):return json.loads(actor(n,f"select public.get_daily_workspace('{store}')").stdout)
def assignment(module,n=142):return sql(f"select id from public.daily_assignments where module_id='{module}' and membership_id='{member(n)}'").stdout.strip()
def pass_module(module,n=142):
 a=assignment(module,n);actor(n,f"select public.get_daily_module('{a}')")
 q=json.loads(sql(f"select jsonb_agg(jsonb_build_object('question_id',question_id,'option',correct_option)) from private.daily_answer_keys where module_id='{module}'").stdout)
 return json.loads(actor(n,f"select public.submit_daily_check('{a}','{json.dumps(q)}',gen_random_uuid())").stdout)
subprocess.run(['docker','run','--rm','-d','--name',name,'--network','none','-e','POSTGRES_HOST_AUTH_METHOD=trust',image],check=True,capture_output=True)
try:
 for _ in range(80):
  if subprocess.run(['docker','exec',name,'pg_isready','-h','127.0.0.1','-U','postgres'],capture_output=True).returncode==0:break
  time.sleep(.25)
 else:raise RuntimeError('PostgreSQL not ready')
 sql((root/'tests/supabase-auth-fixture.sql').read_text())
 for p in sorted((root/'supabase/migrations').glob('*.sql')):
  if p.name<'202610190013_daily_sequence.sql':sql(p.read_text())
 if '--fresh' in sys.argv:
  sql((root/'supabase/migrations/202610190013_daily_sequence.sql').read_text())
  sql((root/'supabase/daily-imports/PILOT_10_IMPORT_DRAFTS.sql').read_text())
  sql((root/'supabase/daily-imports/PILOT_10_IMPORT_DRAFTS.sql').read_text())
  ok(sql('select count(*) from public.daily_sequence').stdout.strip()=='10','fresh project import creates ten sequence slots')
  ok(sql('select count(*) from public.daily_modules where published').stdout.strip()=='0','fresh import stays drafts')
  ok(sql('select count(*) from public.daily_assignments').stdout.strip()=='0','fresh import does not enroll without store release')
  print('Passed 3 fresh-project Daily import checks with migration 013 installed before importing.')
  raise SystemExit(0)
 sql((root/'supabase/daily-imports/PILOT_10_IMPORT_DRAFTS.sql').read_text())
 sql("""insert into auth.users(id,email,email_confirmed_at)
 select ('00000000-0000-0000-0000-'||lpad(n::text,12,'0'))::uuid,'path'||n||'@example.test',now() from generate_series(140,146) n;
 insert into public.platform_admins(user_id) values('00000000-0000-0000-0000-000000000140');
 insert into public.organizations(id,name) values('10000000-0000-0000-0000-000000000140','Path A'),('10000000-0000-0000-0000-000000000141','Path B');
 insert into public.organization_memberships(id,organization_id,user_id,email,role,status)
 select ('20000000-0000-0000-0000-'||lpad(n::text,12,'0'))::uuid,
 case when n=144 then '10000000-0000-0000-0000-000000000141' else '10000000-0000-0000-0000-000000000140' end::uuid,
 ('00000000-0000-0000-0000-'||lpad(n::text,12,'0'))::uuid,'path'||n||'@example.test',
 case when n=141 then 'manager' else 'employee' end,case when n=143 then 'inactive' else 'active' end
 from generate_series(141,144) n;
 """)
 # Simulate one release made with the previous foundation: upgrade must enroll it safely.
 module=payload[0]['module']['id'];second=payload[1]['module']['id']
 actor(140,f"select public.publish_daily_module('{module}')")
 actor(140,f"select public.release_daily_module('{store}','{module}')")
 sql((root/'supabase/migrations/202610190013_daily_sequence.sql').read_text())
 ok(sql('select count(*) from public.daily_sequence').stdout.strip()=='10','maps exact ten pilot versions')
 ok(sql('select count(*) from public.daily_assignments').stdout.strip()=='2','upgrade enrolls active manager and employee, excludes inactive and other store')
 for item in payload[1:]:
  m=item['module']['id'];actor(140,f"select public.publish_daily_module('{m}')");actor(140,f"select public.release_daily_module('{store}','{m}')")
 ok(sql('select count(*) from public.daily_assignments').stdout.strip()=='20','ten modules automatically assigned across active roles without department membership')
 ok(workspace()['progression']['next_assignment_id']==assignment(module),'first module is next')
 ok(sum(a['can_open'] for a in workspace()['assignments'])==1,'only first incomplete assignment opens')
 reject(142,f"select public.get_daily_module('{assignment(second)}')",'Active available Daily assignment required')
 reject(142,f"select public.submit_daily_check('{assignment(second)}','[]',gen_random_uuid())",'Active available Daily assignment required')
 ok(actor(142,'select count(*) from public.daily_questions').stdout.strip()=='1','direct questions RLS cannot bypass sequence')
 reject(141,f"select public.assign_daily_module('{module}','{store}',all_employees=>true)",'enrollment is automatic')
 reject(141,f"select public.set_daily_sequence('{module}',2)",'Administrator access required')
 reject(140,f"select public.set_daily_sequence('{module}',2)",'before releasing')
 r=sql(f"delete from public.daily_sequence where module_id='{module}'",False)
 ok(r.returncode!=0 and 'sequence is fixed' in r.stderr,'assigned slot cannot be removed')
 ok(pass_module(module)['completed'],'first check completes')
 ok(workspace()['progression']['next_assignment_id']==assignment(second),'second opens after first passes')
 ok(actor(142,f"select public.get_daily_module('{assignment(module)}')").returncode==0,'completed lesson review stays open')
 for item in payload[1:]:ok(pass_module(item['module']['id'])['completed'],'pilot next completes in order')
 progress=workspace()['progression']
 ok(progress['completed']['foundations']==10 and progress['next_assignment_id'] is None,'caught up after ten waits for additional Foundations')
 ok(not progress['badge_eligible'] and not progress['pathway_complete'] and not progress['badge_issued'],'pilot cannot earn final Expertise badge')
 # New joiners enroll automatically from the beginning; seat reuse does not inherit prior completion.
 sql(f"insert into public.organization_memberships(id,organization_id,user_id,email,role) values('{member(145)}','{store}','{person(145)}','path145@example.test','employee')")
 ok(len(workspace(145)['assignments'])==10 and workspace(145)['progression']['next_assignment_id']==assignment(module,145),'new employee auto-enrolled at beginning')
 sql(f"update public.organization_memberships set status='active' where id='{member(143)}'")
 ok(len(workspace(143)['assignments'])==10,'reactivation auto-enrolls')
 sql(f"update public.organization_memberships set role='manager' where id='{member(145)}'")
 ok(workspace(145)['progression']['completed']['foundations']==0,'role change does not skip training')
 # Missing planned slots stop advanced levels even if their module has been released early.
 fixtures=[]
 for code,level,position in [('CD-9001','application',1),('CD-9002','expertise',1)]:
  m=str(uuid.uuid4());fixtures.append(m)
  sql(f"insert into public.daily_modules(id,code,version,title,academy,skill_level,sections,estimated_minutes) values('{m}','{code}','1.0.0','Advanced fixture','Operations & Leadership','{level}','[{{\"heading\":\"Learn\",\"content_markdown\":\"Fixture\"}}]',3)")
  sql(f"insert into public.daily_questions values('{m}','{code}-Q01',1,'Fixture','[\"A\",\"B\",\"C\",\"D\"]');insert into private.daily_answer_keys values('{m}','{code}-Q01',0,'Fixture explanation','Learn')")
  actor(140,f"select public.publish_daily_module('{m}')")
  reject(140,f"select public.release_daily_module('{store}','{m}')",'sequence before release')
  actor(140,f"select public.set_daily_sequence('{m}',{position})")
  actor(140,f"select public.release_daily_module('{store}','{m}')")
  reject(142,f"select public.get_daily_module('{assignment(m)}')",'Active available Daily assignment required')
 ok(workspace()['progression']['next_assignment_id'] is None,'cannot advance past missing Foundations')
 # Fill remaining planned positions with local fixtures, never production placeholders.
 for level,start,end in [('foundations',11,88),('application',2,112),('expertise',2,60)]:
  for position in range(start,end+1):
   m=str(uuid.uuid4());code=f'CD-{10000+len(fixtures)}';fixtures.append(m)
   sql(f"insert into public.daily_modules(id,code,version,title,academy,skill_level,sections,estimated_minutes) values('{m}','{code}','1.0.0','Local path fixture','Operations & Leadership','{level}','[{{\"heading\":\"Learn\",\"content_markdown\":\"Fixture\"}}]',3);insert into public.daily_sequence values('{m}','{level}',{position});")
   # Direct owner fixtures represent completed prerequisite records, no production awards.
   sql(f"insert into public.daily_assignments(organization_id,membership_id,module_id,available_on,assigned_by,completed_at) values('{store}','{member(142)}','{m}',current_date-1,'{person(140)}',now())")
 ok(workspace()['progression']['next_assignment_id']==assignment(fixtures[0]),'all Foundations complete unlocks Application')
 ok(not workspace()['progression']['badge_eligible'],'completed prerequisites with two unfinished modules cannot earn badge')
 ok(pass_module(fixtures[0])['completed'],'Application completed through normal RPC')
 ok(workspace()['progression']['next_assignment_id']==assignment(fixtures[1]),'all Application complete unlocks Expertise')
 ok(pass_module(fixtures[1])['completed'],'Expertise completed through normal RPC')
 p=workspace()['progression']
 ok(p['completed']=={'foundations':88,'application':112,'expertise':60} and p['pathway_complete'] and p['badge_eligible'],'all 260 required completions unlock final badge readiness')
 ok(not p['badge_issued'],'badge readiness does not invent issued awards')
 ok(sql('select count(*) from public.training_trophies').stdout.strip()=='0','Daily path never issues full-course trophies')
 # Release replay and concurrent joins cannot duplicate enrollment/completions.
 with concurrent.futures.ThreadPoolExecutor(max_workers=2) as pool:
  results=list(pool.map(lambda _:actor(140,f"select public.release_daily_module('{store}','{module}')"),range(2)))
 ok(all(r.returncode==0 for r in results),'concurrent release replays succeed')
 ok(workspace()['progression']['completed']['expertise']==60,'release replay preserves completion')
 sql(f"update public.organization_memberships set status='inactive',deactivated_at=now() where id='{member(142)}'")
 reject(142,f"select public.get_daily_workspace('{store}')",'Active store access required')
 ok(actor(144,'select count(*) from public.daily_sequence').stdout.strip()=='0','other store cannot read hidden sequence content')
 ok(sql("select has_function_privilege('authenticated','private.enroll_daily_store(uuid)','execute')").stdout.strip()=='f','client cannot invoke internal enrollment')
 print(f'Passed {checks} Daily sequence checks: automatic enrollment across roles/new hires/reactivation, stable order, direct/RPC skip prevention, missing-content and level gates, 260-module badge readiness, store isolation, safe upgrade and concurrent replay.')
finally:
 subprocess.run(['docker','rm','-f',name],capture_output=True)
