"""Staff transfers retain personal credit without sharing former store data."""
from pathlib import Path
import concurrent.futures,json,subprocess,time,uuid
root=Path(__file__).resolve().parent.parent
name='coltrain-transfers-'+uuid.uuid4().hex[:8]
image='postgres:17-alpine@sha256:b0f9560a2de083e2cc7382e75f808c7381a32852a7ec49117deedb300e552b24'
checks=0
def uid(n):return f'00000000-0000-0000-0000-{n:012}'
def sql(text,check=True):
 r=subprocess.run(['docker','exec','-i',name,'psql','-X','-qAt','-v','ON_ERROR_STOP=1','-U','postgres'],input=text,text=True,capture_output=True)
 if check and r.returncode:raise AssertionError(r.stderr)
 return r
def actor(n,text,check=True):return sql(f"begin;set local role authenticated;set local request.jwt.claim.sub='{uid(n)}';{text};commit;",check)
def data(n,text):return json.loads(actor(n,text).stdout.strip() or 'null')
def ok(value,label):
 global checks
 assert value,label
 checks+=1
def reject(n,text,expected):
 r=actor(n,text,False);ok(r.returncode!=0 and expected in r.stderr,(expected,r.stderr))
def inv(store,email='person2@example.test',role='employee'):
 return data(1,f"select to_jsonb(i) from public.prepare_employee_invitation('{store}','{email}','Invited Person','{role}') i")['invitation_id']
def scalar(text):return sql(text).stdout.strip()
try:
 subprocess.run(['docker','run','--rm','-d','--network','none','--name',name,'-e','POSTGRES_PASSWORD=isolated-test',image],check=True,capture_output=True)
 for _ in range(100):
  if subprocess.run(['docker','exec',name,'pg_isready','-h','127.0.0.1','-U','postgres'],capture_output=True).returncode==0:break
  time.sleep(.2)
 sql((root/'tests/supabase-auth-fixture.sql').read_text())
 for p in sorted((root/'supabase/migrations').glob('*.sql')):
  if p.name<'202610270027':sql(p.read_text())
 for n in range(1,6):sql(f"insert into auth.users(id,email,email_confirmed_at) values('{uid(n)}','person{n}@example.test',now());")
 sql(f"insert into public.platform_admins values('{uid(1)}');")
 old=data(1,"select to_jsonb(public.create_store('Former Store',5))")
 new=data(1,"select to_jsonb(public.create_store('New Store',5))")
 third=data(1,"select to_jsonb(public.create_store('Other New Store',5))")
 course=scalar("insert into public.training_courses(slug,title,published) values('portable-standard','Shared standard',true) returning id")
 lesson=scalar(f"insert into public.training_lessons(course_id,position,title,body) values('{course}',1,'Lesson','[]') returning id")
 question=scalar(f"insert into public.training_questions(course_id,position,prompt,options) values('{course}',1,'Question','[\"A\",\"B\"]') returning id")
 sql(f"insert into private.training_answer_keys values('{question}',0,'Why');")
 custom=scalar(f"insert into public.training_courses(slug,title,published,owner_organization_id) values('private-old','Former store onboarding',true,'{old}') returning id")
 for store in [old,new]:actor(1,f"select public.release_training_course('{store}','{course}')")
 module=scalar("insert into public.daily_modules(code,version,title,academy,skill_level,sections,estimated_minutes,published) values('CD-0991','1.0.0','Portable Daily','Plumbing','foundations','[{\"title\":\"Lesson\"}]',2,true) returning id")
 sql(f"insert into public.daily_sequence(module_id,skill_level,position) values('{module}','foundations',1);")
 for store in [old,new]:sql(f"insert into public.daily_releases(organization_id,module_id,released_by) values('{store}','{module}','{uid(1)}')")
 initial=inv(old);member=data(2,f"select to_jsonb(public.accept_email_invitation('{initial}'))")
 assignment=scalar(f"select id from public.training_assignments where membership_id='{member}' and course_id='{course}'")
 actor(2,f"select public.complete_training_lesson('{assignment}','{lesson}')")
 actor(2,f"select public.submit_training_quiz('{assignment}','[{{\"question_id\":\"{question}\",\"option\":0}}]','{uuid.uuid4()}')")
 sql(f"insert into public.training_assignments(organization_id,membership_id,course_id,assigned_by,completed_at) values('{old}','{member}','{custom}','{uid(1)}',now())")
 daily=scalar(f"select id from public.daily_assignments where membership_id='{member}' and module_id='{module}'")
 sql(f"update public.daily_assignments set started_at=now(),completed_at=now() where id='{daily}'")
 before=scalar(f"select private.learner_point_totals('{uid(2)}')")
 # An already-moved user receives retrospective completion credit on migration too.
 existing=inv(new,role='manager')
 actor(1,f"select public.deactivate_member('{member}')")
 transferred=data(2,f"select to_jsonb(public.accept_email_invitation('{existing}'))")
 actor(1,f"select public.assign_training('{course}','{new}',array['{transferred}'::uuid])")
 sql((root/'supabase/migrations/202610270027_staff_store_transfers.sql').read_text())
 company=data(1,f"select to_jsonb(public.admin_initialize_company('{new}','{uid(5)}','New Company'))")
 manager_pending=data(5,f"select to_jsonb(i) from public.prepare_employee_invitation('{new}','person3@example.test','Separate Manager','manager') i")['invitation_id']
 ok(data(5,f"select public.get_company_access_settings('{company}')")['manager_invitations'][0]['id']==manager_pending,'billing-only owner can see pending manager invitation')
 reject(4,f"select public.revoke_invitation('{manager_pending}')",'Invitation not available')
 sql("update public.invitations set last_email_attempt_at=now()-interval '2 minutes'")
 resent=data(5,f"select to_jsonb(i) from public.prepare_employee_invitation('{new}','','',replace_invitation:='{manager_pending}') i")['invitation_id']
 ok(resent!=manager_pending,'owner can resend a pending manager invitation')
 actor(5,f"select public.revoke_invitation('{resent}')")
 ok(data(5,f"select public.get_company_access_settings('{company}')")['manager_invitations']==[],'owner can cancel manager reservation')
 employee_pending=inv(new,'person5@example.test')
 reject(5,f"select public.revoke_invitation('{employee_pending}')",'Invitation not available')
 actor(1,f"select public.revoke_invitation('{employee_pending}')")

 ok(scalar(f"select carried_credit and completed_at is not null from public.training_assignments where membership_id='{transferred}' and course_id='{course}'")=='t','migration backfills a transfer already made')
 ok(scalar(f"select carried_credit and completed_at is not null from public.daily_assignments where membership_id='{transferred}' and module_id='{module}'")=='t','migration backfills completed Daily credit')
 ok(scalar(f"select private.learner_point_totals('{uid(2)}')")==before,'backfill does not award points again')
 ok(scalar(f"select count(*) from public.training_trophies where user_id='{uid(2)}'")=='1','trophy remains one award on the same account')
 ok(scalar(f"select count(*) from public.training_lesson_completions l join public.training_assignments a on a.id=l.assignment_id where a.membership_id='{transferred}'")=='1','new standard assignment retains lesson completion')
 ok(scalar(f"select count(*) from public.training_assignments where membership_id='{transferred}' and course_id='{custom}'")=='0','former private onboarding is not assigned to destination')
 ok(scalar(f"select status from public.organization_memberships where id='{member}'")=='inactive','former membership remains an inactive historical record')
 ok(scalar(f"select count(*) from public.seats where organization_id='{old}' and membership_id is not null")=='0','former seat is released')
 ok(scalar(f"select count(*) from public.seats where organization_id='{new}' and membership_id='{transferred}'")=='1','new manager uses one destination seat')
 ok(data(2,f"select public.get_my_store_invitation('{existing}')")['accepted'],'accepted invitation can be safely retried')
 reject(2,f"select public.accept_email_invitation('{existing}')",'already used')
 ok(scalar(f"select count(*) from public.seats where membership_id='{transferred}'")=='1','used invitation never claims a second seat')
 history=data(2,'select public.get_my_training_history()')
 ok(history['points']['lifetime_points']==15,'personal history retains course and Daily lifetime points')
 ok(any(c['title']=='Former store onboarding' for c in history['courses']),'learner retains personal completion metadata for store-specific training')
 ok('organization_id' not in json.dumps(history) and 'answers' not in json.dumps(history),'personal transcript exposes no old store IDs or quiz answers')
 ok(data(3,'select public.get_my_training_history()')['courses']==[],'another account cannot read this transcript')
 reject(2,f"select public.get_training_workspace('{old}')",'store access')
 ok(actor(2,f"select count(*) from public.training_assignments where organization_id='{old}'").stdout.strip()=='0','RLS still hides former store assignments')
 reject(2,f"select public.get_my_store_invitation('{inv(third,'person3@example.test')}')",'does not match')
 # Move again after installation; normal triggers carry credit on new assignments.
 next_inv=inv(third,role='manager')
 reject(2,f"select public.accept_email_invitation('{next_inv}')",'current store must remove')
 ok(not data(2,f"select public.get_my_store_invitation('{next_inv}')")['can_join'],'preview explains active-store conflict without silently transferring')
 actor(1,f"select public.deactivate_member('{transferred}')")
 ok(data(2,'select public.get_my_training_history()')['points']['lifetime_points']==15,'personal transcript remains available with no active store')
 next_member=data(2,f"select to_jsonb(public.accept_email_invitation('{next_inv}'))")
 actor(1,f"select public.release_training_course('{third}','{course}');select public.assign_training('{course}','{third}',array['{next_member}'::uuid])")
 sql(f"insert into public.daily_releases(organization_id,module_id,released_by) values('{third}','{module}','{uid(1)}')")
 ok(scalar(f"select carried_credit and completed_at is not null from public.training_assignments where membership_id='{next_member}' and course_id='{course}'")=='t','future course assignments carry earned standard credit')
 ok(scalar(f"select carried_credit and completed_at is not null from public.daily_assignments where membership_id='{next_member}' and module_id='{module}'")=='t','future Daily assignments carry earned credit')
 ok(scalar(f"select private.learner_point_totals('{uid(2)}')")==before,'repeated moves never farm points')
 ok(scalar(f"select count(*) from public.training_assignments where id='{assignment}' and completed_at is not null")=='1','original completion record is unchanged')
 # Returning to a prior store creates a fresh membership while preserving its former row.
 sql("update public.invitations set last_email_attempt_at=now()-interval '2 minutes'")
 back=inv(old)
 actor(1,f"select public.deactivate_member('{next_member}')")
 back_member=data(2,f"select to_jsonb(public.accept_email_invitation('{back}'))")
 ok(back_member!=member,'returning to old store does not overwrite former membership')
 ok(scalar(f"select count(*) from public.organization_memberships where user_id='{uid(2)}' and status='active'")=='1','person still belongs to only one active store')
 # Competing invitations can claim only one active store and one seat.
 a=inv(new,'person4@example.test');b=inv(third,'person4@example.test')
 with concurrent.futures.ThreadPoolExecutor() as pool:
  results=list(pool.map(lambda i:actor(4,f"select public.accept_email_invitation('{i}')",False),[a,b]))
 ok(sum(r.returncode==0 for r in results)==1,'concurrent store joins cannot create two active memberships')
 print(f'Passed {checks} transfer, credit, history, privacy, seat and concurrency checks.')
finally:subprocess.run(['docker','rm','-f',name],capture_output=True)
