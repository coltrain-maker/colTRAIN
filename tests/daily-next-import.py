"""Latest-schema integration for the owner's second Daily batch. No hosted writes or mail."""
from pathlib import Path
import json,subprocess,time,uuid
root=Path(__file__).resolve().parent.parent
subprocess.run(['python','scripts/build-daily-next-import.py'],cwd=root,check=True)
new=json.loads((root/'courses/daily/modules-11-20-v1.0.0/prepared-import.json').read_text())
pilot=json.loads((root/'courses/daily/pilot-v1.0.0/prepared-import.json').read_text())
script=(root/'supabase/daily-imports/MODULES_11_20_IMPORT_DRAFTS.sql').read_text();release=(root/'supabase/daily-imports/MODULES_11_20_RELEASE_COLTRAIN_HARDWARE.sql').read_text()
name='coltrain-next-daily-'+uuid.uuid4().hex[:8];image='postgres:17-alpine@sha256:b0f9560a2de083e2cc7382e75f808c7381a32852a7ec49117deedb300e552b24'
owner='2370c99a-9b5e-439a-b73a-00ada7a35661';store='10000000-0000-0000-0000-000000000140';other='10000000-0000-0000-0000-000000000141';checks=0
person=lambda n:f'00000000-0000-0000-0000-{n:012}'
member=lambda n:f'20000000-0000-0000-0000-{n:012}'
def sql(q,check=True):
 r=subprocess.run(['docker','exec','-i',name,'psql','-X','-qAt','-v','ON_ERROR_STOP=1','-U','postgres'],input=q,text=True,capture_output=True)
 if check and r.returncode:raise AssertionError(r.stderr)
 return r

def actor(n,q,check=True):return sql(f"begin;set local role authenticated;set local request.jwt.claim.sub='{person(n)}';{q};commit;",check)
def data(n,q):return json.loads(actor(n,q).stdout.strip() or 'null')
def ok(v,msg):
 global checks
 assert v,msg
 checks+=1

def assignment(module,n=142):return sql(f"select id from public.daily_assignments where module_id='{module}' and membership_id='{member(n)}'").stdout.strip()
def complete(module,n=142):
 a=assignment(module,n);actor(n,f"select public.get_daily_module('{a}')")
 keys=json.loads(sql(f"select jsonb_agg(jsonb_build_object('question_id',question_id,'option',correct_option)) from private.daily_answer_keys where module_id='{module}'").stdout)
 return data(n,f"select public.submit_daily_check('{a}','{json.dumps(keys)}',gen_random_uuid())")
def pilot_state():return sql("select coalesce(jsonb_agg(to_jsonb(a) order by a.id),'[]') from public.daily_assignments a join public.daily_modules d on d.id=a.module_id where d.code between 'CD-0001' and 'CD-0010'").stdout
subprocess.run(['docker','run','--rm','-d','--name',name,'--network','none','-e','POSTGRES_HOST_AUTH_METHOD=trust',image],check=True,capture_output=True)
try:
 for _ in range(100):
  if subprocess.run(['docker','exec',name,'pg_isready','-h','127.0.0.1','-U','postgres'],capture_output=True).returncode==0:break
  time.sleep(.2)
 sql((root/'tests/supabase-auth-fixture.sql').read_text())
 for p in sorted((root/'supabase/migrations').glob('*.sql')):sql(p.read_text())
 sql(f"""insert into auth.users(id,email,email_confirmed_at) values('{owner}','owner@example.test',now());insert into public.platform_admins values('{owner}');
 insert into auth.users(id,email,email_confirmed_at) select ('00000000-0000-0000-0000-'||lpad(n::text,12,'0'))::uuid,'next'||n||'@example.test',now() from generate_series(141,145)n;
 insert into public.profiles(user_id,full_name) select id,'Daily batch tester' from auth.users;
 insert into public.organizations(id,name) values('{store}','Coltrain Hardware'),('{other}','Other Store');
 insert into public.organization_memberships(id,organization_id,user_id,email,role,status)
 select ('20000000-0000-0000-0000-'||lpad(n::text,12,'0'))::uuid,case when n=144 then '{other}' else '{store}' end::uuid,
 ('00000000-0000-0000-0000-'||lpad(n::text,12,'0'))::uuid,'next'||n||'@example.test',case when n=141 then 'manager' else 'employee' end,case when n=143 then 'inactive' else 'active' end from generate_series(141,144)n;""")
 # A conflicting pre-existing sequence slot must roll back every inserted row.
 placeholder='90000000-0000-0000-0000-000000000011'
 sql(f"insert into public.daily_modules(id,code,version,title,academy,skill_level,sections,estimated_minutes) values('{placeholder}','CD-9999','0.1.0','Test sequence occupant','Paint & Surface Care','foundations','[{{\"heading\":\"Test\",\"content_markdown\":\"Fixture only\"}}]',1);insert into public.daily_sequence values('{placeholder}','foundations',11)")
 failed=sql(script,False);ok(failed.returncode!=0 and 'Daily sequence slot 11 conflicts' in failed.stderr,'occupied sequence slot refuses import')
 ok(sql('select count(*) from public.daily_modules').stdout.strip()=='1','sequence conflict rolls back new module/questions/keys atomically')
 sql(f"delete from public.daily_sequence where module_id='{placeholder}';delete from public.daily_modules where id='{placeholder}'")
 sql(script);sql(script)
 ok(sql('select count(*) from public.daily_modules').stdout.strip()=='10','draft rerun has exactly ten new records')
 ok(sql('select count(*) from public.daily_modules where published').stdout.strip()=='0','drafts not published')
 ok(sql('select count(*) from public.daily_assignments').stdout.strip()=='0','draft import does not assign')
 failed=sql(release,False);ok(failed.returncode!=0 and 'first ten' in failed.stderr,'release refuses to skip first ten modules')
 for item in new:
  m=item['module'];ident=m['id']
  actual=json.loads(sql(f"select to_jsonb(d)-'created_at'-'published' from public.daily_modules d where id='{ident}'").stdout)
  ok(actual==m,m['code']+' full teaching/sources fidelity')
  original=json.loads(sql(f"select source_document from private.daily_editorial where module_id='{ident}'").stdout)
  ok(original==item['source_document'],m['code']+' private original/review fidelity')
  questions=json.loads(sql(f"select jsonb_agg(to_jsonb(q) order by position) from public.daily_questions q where module_id='{ident}'").stdout)
  keys=json.loads(sql(f"select jsonb_agg(to_jsonb(k) order by question_id) from private.daily_answer_keys k where module_id='{ident}'").stdout)
  ok(questions==item['questions'] and keys==item['keys'],m['code']+' exact questions, answers and explanations')
  ok('answer_key' not in json.dumps(actual) and all(k['explanation'] not in json.dumps(actual) for k in keys),m['code']+' answers excluded from learner module')
 sql((root/'supabase/daily-imports/PILOT_10_IMPORT_DRAFTS.sql').read_text());sql((root/'supabase/daily-imports/PILOT_10_RELEASE_COLTRAIN_HARDWARE.sql').read_text())
 complete(pilot[0]['module']['id']);complete(pilot[1]['module']['id']);before=pilot_state()
 points_before=sql("select coalesce(sum(points),0) from private.daily_point_awards").stdout.strip();ok(points_before=='10','existing completed Daily points present before new release')
 sql(release);sql(release);sql(script)
 ok(pilot_state()==before,'import/release/reruns preserve original assignment IDs, dates, attempts/completions')
 ok(sql('select count(*) from public.daily_modules where published').stdout.strip()=='20','twenty published modules after approved release')
 ok(sql('select count(*) from public.daily_assignments').stdout.strip()=='40','twenty assignments each for active employee and manager')
 ok(sql(f"select count(*) from public.daily_assignments where organization_id='{other}' or membership_id='{member(143)}'").stdout.strip()=='0','no other-store or inactive enrollments')
 ok(sql('select coalesce(sum(points),0) from private.daily_point_awards').stdout.strip()==points_before,'release never awards unearned points')
 w=data(142,f"select public.get_daily_workspace('{store}')")
 ok(len(w['assignments'])==20 and w['progression']['completed']['foundations']==2,'workspace totals update to twenty without resetting progress')
 next_id=assignment(pilot[2]['module']['id']);ok(w['progression']['next_assignment_id']==next_id,'existing learner continues at original next module')
 # A released later drill is assigned but remains sequentially locked.
 a=assignment(new[0]['module']['id']);blocked=actor(142,f"select public.get_daily_module('{a}')",False)
 ok(blocked.returncode!=0,'module eleven cannot be skipped to before completing pilot')
 for item in pilot[2:]:complete(item['module']['id'])
 w=data(142,f"select public.get_daily_workspace('{store}')")
 ok(w['progression']['next_assignment_id']==a,'finishing module ten opens module eleven')
 lesson=data(142,f"select public.get_daily_module('{a}')");ok('Read a Paint Coverage Statement' in json.dumps(lesson) and 'correct_option' not in json.dumps(lesson),'new lesson loads without answer keys')
 complete(new[0]['module']['id']);ok(sql('select sum(points) from private.daily_point_awards').stdout.strip()=='55','first new drill earns exactly five more points')
 sql(release);ok(sql('select sum(points) from private.daily_point_awards').stdout.strip()=='55','release replay cannot award duplicate points')
 sql(f"insert into public.organization_memberships(id,organization_id,user_id,email,role) values('{member(145)}','{store}','{person(145)}','next145@example.test','employee')")
 ok(sql(f"select count(*) from public.daily_assignments where membership_id='{member(145)}'").stdout.strip()=='20','future enrollment gets all twenty drills')
 # Reject altered content and occupied sequence slots atomically.
 changed=script.replace('Read a Paint Coverage Statement','ALTERED lesson')
 failed=sql(changed,False);ok(failed.returncode!=0 and 'content differs' in failed.stderr,'different content under an existing ID is rejected')
 ok(sql('select title from public.daily_modules where code=\'CD-0011\'').stdout.strip()=='Read a Paint Coverage Statement','failed import preserves approved title')
 fail=actor(142,'select * from private.daily_answer_keys',False);ok(fail.returncode!=0,'employees cannot directly query private keys')
 print(f'Passed {checks} Daily batch checks: exact content/private keys, safe reruns, store release, automatic enrollment, preserved progress/points, sequence 10→11 and future members. No hosted changes.')
finally:subprocess.run(['docker','rm','-f',name],capture_output=True)
