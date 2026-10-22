"""Isolated PostgreSQL integration checks; no hosted writes or email."""
from pathlib import Path
import concurrent.futures,json,subprocess,time,uuid
root=Path(__file__).resolve().parent.parent
name='coltrain-portal-'+uuid.uuid4().hex[:8]
image='postgres:17-alpine@sha256:b0f9560a2de083e2cc7382e75f808c7381a32852a7ec49117deedb300e552b24'
checks=0
store='10000000-0000-0000-0000-000000000180';other='10000000-0000-0000-0000-000000000185'
def uid(n):return f'00000000-0000-0000-0000-{n:012}'
def mid(n):return f'20000000-0000-0000-0000-{n:012}'
def sql(q,check=True):
 r=subprocess.run(['docker','exec','-i',name,'psql','-X','-qAt','-v','ON_ERROR_STOP=1','-U','postgres'],input=q,text=True,capture_output=True)
 if check and r.returncode:raise AssertionError(r.stderr)
 return r
def actor(n,q,check=True):return sql(f"begin;set local role authenticated;set local request.jwt.claim.sub='{uid(n)}';{q};commit;",check)
def data(n,q):return json.loads(actor(n,q).stdout.strip() or 'null')
def ok(v,msg):
 global checks
 assert v,msg
 checks+=1

def reject(n,q,needle='permission denied'):
 r=actor(n,q,False);ok(r.returncode and needle in r.stderr,(q,r.stderr))
def member(n,role='employee',s=store):sql(f"insert into public.organization_memberships(id,organization_id,user_id,email,role) values('{mid(n)}','{s}','{uid(n)}','portal{n}@example.test','{role}')")
def inbox(n,s=store):return data(n,f"select public.get_my_training_notifications('{s}')")
def workspace(n):return data(n,f"select public.get_training_workspace('{store}')")
def assignment(n,module):return sql(f"select id from public.daily_assignments where membership_id='{mid(n)}' and module_id='{module}'").stdout.strip()
def pass_drill(n,module,key=None):
 a=assignment(n,module);actor(n,f"select public.get_daily_module('{a}')")
 answers=sql(f"select jsonb_agg(jsonb_build_object('question_id',question_id,'option',correct_option)) from private.daily_answer_keys where module_id='{module}'").stdout.strip()
 return data(n,f"select public.submit_daily_check('{a}','{answers}','{key or uuid.uuid4()}')")
subprocess.run(['docker','run','--rm','-d','--name',name,'--network','none','-e','POSTGRES_HOST_AUTH_METHOD=trust',image],check=True,capture_output=True)
try:
 for _ in range(80):
  if subprocess.run(['docker','exec',name,'pg_isready','-h','127.0.0.1','-U','postgres'],capture_output=True).returncode==0:break
  time.sleep(.25)
 sql((root/'tests/supabase-auth-fixture.sql').read_text())
 for p in sorted((root/'supabase/migrations').glob('*.sql')):
  if p.name<'202610220015':sql(p.read_text())
 sql(f"""insert into auth.users(id,email,email_confirmed_at) select ('00000000-0000-0000-0000-'||lpad(n::text,12,'0'))::uuid,'portal'||n||'@example.test',now() from generate_series(180,190) n;
 insert into public.profiles(user_id,full_name,optional_email_notifications) select id,'Portal '||email,email<>'portal184@example.test' from auth.users;
 insert into public.platform_admins values('{uid(180)}');
 insert into public.organizations(id,name) values('{store}','Portal A'),('{other}','Portal B');""")
 member(181,'manager');member(182);member(184,'manager');member(185,'manager',other)
 sql((root/'supabase/daily-imports/PILOT_10_IMPORT_DRAFTS.sql').read_text())
 first=sql("select module_id from public.daily_sequence where position=1 and skill_level='foundations'").stdout.strip()
 second=sql("select module_id from public.daily_sequence where position=2 and skill_level='foundations'").stdout.strip()
 for module in [first,second]:
  actor(180,f"select public.publish_daily_module('{module}');select public.release_daily_module('{store}','{module}')")
 pass_drill(182,first)
 sql((root/'supabase/migrations/202610220015_employee_onboarding.sql').read_text())
 ok(not data(182,'select public.record_employee_first_login()')['recorded'],'old member baseline produces no new-login alert')
 ok(not any(x['kind']=='employee_first_login' for x in inbox(181)['items']),'baseline sends no manager alerts')
 # Published ready courses, two versions of one slug, an unreleased course, and a draft.
 courses=[]
 for version,slug,published,released in [(1,'portal',True,True),(2,'portal',True,True),(1,'other',True,False),(1,'draft',False,True)]:
  c=str(uuid.uuid4());q=str(uuid.uuid4());courses.append(c)
  sql(f"insert into public.training_courses(id,slug,version,title,published) values('{c}','{slug}',{version},'Fixture {slug}',{str(published).lower()});insert into public.training_lessons(course_id,position,title,body) values('{c}',1,'Lesson','[]');insert into public.training_questions(id,course_id,position,prompt,options) values('{q}','{c}',1,'Question','[\"A\",\"B\"]');insert into private.training_answer_keys values('{q}',0,'Explanation');")
  if released:sql(f"insert into public.training_course_releases values('{store}','{c}','{uid(180)}',now())")
 member(183)
 ok(sql(f"select course_id from public.training_assignments where membership_id='{mid(183)}'").stdout.strip()==courses[1],'new employee receives latest ready released course only, no draft/unreleased/old version')
 ok(sql(f"select due_date=(now() at time zone o.time_zone)::date+30 from public.training_assignments a join public.organizations o on o.id=a.organization_id where a.membership_id='{mid(183)}'").stdout.strip()=='t','new deadline thirty store-local days')
 sql(f"update public.training_assignments set due_date=current_date+40 where membership_id='{mid(183)}';update public.organization_memberships set status='inactive' where id='{mid(183)}';update public.organization_memberships set status='active' where id='{mid(183)}'")
 ok(sql(f"select count(*)=1 and min(due_date)=current_date+40 from public.training_assignments where membership_id='{mid(183)}'").stdout.strip()=='t','reactivation preserves assignment and manager deadline')
 ok(sql(f"select count(*) from public.training_assignments where membership_id='{mid(182)}'").stdout.strip()=='0','existing employee not bulk assigned')
 with concurrent.futures.ThreadPoolExecutor(2) as pool:results=list(pool.map(lambda _:data(183,'select public.record_employee_first_login()'),range(2)))
 ok(sum(r['recorded'] for r in results)==1,'concurrent first logins record once')
 ok(len([x for x in inbox(181)['items'] if x['kind']=='employee_first_login'])==1,'manager sees one first-login alert')
 ok(len([x for x in inbox(184)['items'] if x['kind']=='employee_first_login'])==1,'email opt-out manager still receives in-app')
 ok(not any(x['kind']=='employee_first_login' for x in inbox(183)['items']),'employee cannot see manager alert')
 ok(not any(x['kind']=='employee_first_login' for x in inbox(185,other)['items']),'other store cannot see manager alert')
 reject(183,"select * from private.employee_first_logins")
 reject(183,f"select public.claim_employee_login_email('{uid(183)}')")
 claim=lambda n:json.loads(sql(f"set role service_role;select public.claim_employee_login_email('{uid(n)}')").stdout.strip() or 'null')
 ok(claim(185) is None,'unrelated verified user cannot claim another store email')
 job=claim(183);ok(job['email']=='portal181@example.test','employee event claims only opted-in manager email')
 ok(claim(183) is None,'active lease prevents duplicate provider request')
 sql(f"set role service_role;select public.finish_employee_login_email('{job['id']}','{job['lease_id']}',true,'provider-fixture')")
 ok(claim(181) is None,'accepted delivery never repeats')
 member(186)
 data(186,'select public.record_employee_first_login()')
 sql(f"update public.profiles set optional_email_notifications=false where user_id='{uid(181)}'")
 ok(claim(186)=={'skip':True},'worker rechecks opt-out just before delivery')
 sql((root/'supabase/migrations/202610220016_daily_points.sql').read_text())
 ok(workspace(182)['totals']['daily_points']==5 and workspace(182)['totals']['lifetime_points']==5,'previous completed drill credited exactly once')
 key=str(uuid.uuid4());result=pass_drill(183,first,key)
 ok(result['new_points']==5 and result['daily_points']==5,'correct completion earns five points')
 again=pass_drill(183,first,key);ok(result==again,'lost-response submission replay identical, no duplicate')
 reject(183,f"select public.submit_daily_check('{assignment(183,first)}','[]',gen_random_uuid())",'already completed')
 ok(workspace(183)['totals']['daily_points']==5,'reviews/retries never multiply points')
 a=assignment(183,second);actor(183,f"select public.get_daily_module('{a}')")
 wrong=sql(f"select jsonb_agg(jsonb_build_object('question_id',question_id,'option',(correct_option+1)%4)) from private.daily_answer_keys where module_id='{second}'").stdout.strip()
 failed=data(183,f"select public.submit_daily_check('{a}','{wrong}',gen_random_uuid())")
 ok(not failed['completed'] and failed['new_points']==0,'incorrect check earns zero points')
 pass_drill(183,second)
 w=workspace(183);ok(w['totals']['daily_points']==10 and w['totals']['lifetime_points']==w['totals']['course_points']+10,'combined totals consistent')
 ok(w['lifetime_standings'][0]['membership_id']==mid(183) and w['lifetime_standings'][0]['daily_points']==10,'lifetime standings rank combined total with Daily breakdown')
 mw=workspace(181);ok(next(m for m in mw['members'] if m['id']==mid(183))['daily_points']==10,'manager roster reports same Daily total')
 reject(183,'select * from private.daily_point_awards')
 reject(183,f"select private.learner_point_totals('{uid(182)}')")
 reject(185,f"select public.get_training_workspace('{store}')",'Active store access required')
 ok(sql('select count(*) from public.training_trophies').stdout.strip()=='0','Daily points do not invent full-course trophies')
 # Concurrent successful submissions must share one saved award and one attempt.
 a=assignment(186,first);actor(186,f"select public.get_daily_module('{a}')")
 answers=sql(f"select jsonb_agg(jsonb_build_object('question_id',question_id,'option',correct_option)) from private.daily_answer_keys where module_id='{first}'").stdout.strip();key=str(uuid.uuid4())
 with concurrent.futures.ThreadPoolExecutor(2) as pool:
  results=list(pool.map(lambda _:data(186,f"select public.submit_daily_check('{a}','{answers}','{key}')"),range(2)))
 ok(results[0]==results[1] and results[0]['new_points']==5,'concurrent same-key attempts return one immutable result')
 ok(workspace(186)['totals']['daily_points']==5,'concurrent requests award only five points')
 # A future content version with the same stable code cannot pay a second completion bonus.
 version=str(uuid.uuid4());new_assignment=str(uuid.uuid4())
 sql(f"insert into public.daily_modules(id,code,version,title,academy,skill_level,sections,estimated_minutes) select '{version}',code,'9.0.0',title,academy,skill_level,sections,estimated_minutes from public.daily_modules where id='{first}';insert into public.daily_assignments(id,organization_id,membership_id,module_id,available_on,assigned_by,completed_at) values('{new_assignment}','{store}','{mid(186)}','{version}',current_date,'{uid(180)}',now())")
 ok(workspace(186)['totals']['daily_points']==5,'same stable drill code across versions earns only once')
 # Full-course points still add normally and remain separately identifiable.
 course_assignment=sql(f"select id from public.training_assignments where membership_id='{mid(183)}'").stdout.strip()
 lesson=sql(f"select id from public.training_lessons where course_id='{courses[1]}'").stdout.strip()
 question=sql(f"select id from public.training_questions where course_id='{courses[1]}'").stdout.strip()
 actor(183,f"select public.complete_training_lesson('{course_assignment}','{lesson}');select public.submit_training_quiz('{course_assignment}','[{{\"question_id\":\"{question}\",\"option\":0}}]',gen_random_uuid())")
 totals=workspace(183)['totals'];ok(totals['course_points']==10 and totals['daily_points']==10 and totals['lifetime_points']==20,'course and Daily awards add to the overall total without mixing ledgers')
 actor(180,f"select public.release_training_course('{store}','{courses[1]}',false);select public.release_training_course('{store}','{courses[0]}',false)");member(187)
 ok(sql(f"select count(*) from public.training_assignments where membership_id='{mid(187)}'").stdout.strip()=='0','joining after withdrawal does not assign unavailable courses')
 print(f'Passed {checks} employee-portal SQL checks: enrollment, first-login privacy/consent/leases, retroactive and new Daily points, idempotency and reporting.')
finally:subprocess.run(['docker','rm','-f',name],capture_output=True)
