"""Sandbox provisioning, SQL permissions, retries, seats and catalog privacy."""
from pathlib import Path
import concurrent.futures,json,subprocess,time,uuid
root=Path(__file__).resolve().parent.parent
name='coltrain-signup-'+uuid.uuid4().hex[:8]
image='postgres:17-alpine@sha256:b0f9560a2de083e2cc7382e75f808c7381a32852a7ec49117deedb300e552b24'
checks=0
def uid(n):return f'00000000-0000-0000-0000-{950+n:012}'
def q(value):return "'"+str(value).replace("'","''")+"'"
def sql(text,check=True):
 r=subprocess.run(['docker','exec','-i',name,'psql','-X','-qAt','-v','ON_ERROR_STOP=1','-U','postgres'],input=text,text=True,capture_output=True)
 if check and r.returncode:raise AssertionError(r.stderr)
 return r
def actor(n,text,check=True):return sql(f"begin;set local role authenticated;set local request.jwt.claim.sub='{uid(n)}';{text};commit;",check)
def service(text,check=True):return sql('set role service_role;'+text,check)
def data(n,text):return json.loads(actor(n,text).stdout.strip() or 'null')
def ok(value,label):
 global checks
 assert value,label
 checks+=1
def reject(n,text,expected):
 r=actor(n,text,False);ok(r.returncode!=0 and expected in r.stderr,(expected,r.stderr))
def details(**kwargs):return {'company_name':'Sandbox Company','store_name':'Sandbox Store','contact_name':'Owner One','phone':'555-0100','buying_group':'','street':'100 Test St','city':'Test City','region':'NC','postal_code':'28501','time_zone':'America/New_York','plan_code':'store_25','become_manager':True,'purchase_authority':True,'terms_accepted':True,**kwargs}
def prepare(n,d):return data(n,f"select to_jsonb(public.prepare_store_signup({q(json.dumps(d))}::jsonb,'{uuid.uuid4()}'))")
def provision(s,session='SessionOne',customer='CustomerOne',subscription='SubscriptionOne',event='evt_first',plan='store_25',check=True):
 return service(f"select public.provision_sandbox_store_signup('{s}','{event}','cs_test_{session}','cus_{customer}','sub_{subscription}','{plan}','trialing',now()+interval '14 days',now()+interval '14 days')",check)
try:
 subprocess.run(['docker','run','--rm','-d','--network','none','--name',name,'-e','POSTGRES_PASSWORD=isolated-test',image],check=True,capture_output=True)
 for _ in range(100):
  if subprocess.run(['docker','exec',name,'pg_isready','-h','127.0.0.1','-U','postgres'],capture_output=True).returncode==0:break
  time.sleep(.2)
 sql((root/'tests/supabase-auth-fixture.sql').read_text())
 migrations=sorted((root/'supabase/migrations').glob('*.sql'))
 for p in migrations:
  if p.name<'202610260025':sql(p.read_text())
 for n in range(1,10):sql(f"insert into auth.users(id,email,email_confirmed_at) values('{uid(n)}','signup{n}@example.test',{'null' if n==5 else 'now()'});")
 sql(f"insert into public.platform_admins(user_id) values('{uid(1)}');")
 pilot=data(1,"select to_jsonb(public.create_store('Coltrain Hardware',10))")
 actor(1,f"select public.admin_set_store_pilot('{pilot}',true,'Existing approved pilot')")
 pilot_before=sql(f"select to_jsonb(t) from private.store_account_terms t where organization_id='{pilot}'").stdout.strip()
 sql((root/'supabase/migrations/202610260025_sandbox_store_signup.sql').read_text())
 ok(sql(f"select to_jsonb(t) from private.store_account_terms t where organization_id='{pilot}'").stdout.strip()==pilot_before,'migration preserves existing pilot arrangement')
 reject(2,f"select public.prepare_store_signup({q(json.dumps(details()))}::jsonb,'{uuid.uuid4()}')",'not open')
 reject(2,'select public.set_sandbox_store_signup_enabled(true)','Administrator access required')
 actor(1,'select public.set_sandbox_store_signup_enabled(true)')
 reject(5,f"select public.prepare_store_signup({q(json.dumps(details()))}::jsonb,'{uuid.uuid4()}')",'confirmed email')
 for override in [{'purchase_authority':False},{'terms_accepted':False},{'plan_code':'attacker'},{'postal_code':'bad'},{'time_zone':'Not/AZone'},{'become_manager':'true'}]:
  r=actor(2,f"select public.prepare_store_signup({q(json.dumps(details(**override)))}::jsonb,'{uuid.uuid4()}')",False);ok(r.returncode!=0,'invalid signup details rejected')
 # Ready standard content, a private store course, and an incomplete published course.
 course=sql("insert into public.training_courses(slug,title) values('signup-standard','Standard sandbox course') returning id").stdout.strip()
 lesson=sql(f"insert into public.training_lessons(course_id,position,title,body) values('{course}',1,'Lesson','[]') returning id").stdout.strip()
 question=sql(f"insert into public.training_questions(course_id,position,prompt,options) values('{course}',1,'Question','[\"A\",\"B\"]') returning id").stdout.strip()
 sql(f"insert into private.training_answer_keys values('{question}',0,'Explanation');update public.training_courses set published=true where id='{course}';")
 private_course=sql(f"insert into public.training_courses(slug,title,owner_organization_id,published) values('private-onboarding','Private mission','{pilot}',true) returning id").stdout.strip()
 # A private store revision must neither leak nor hide the standard version.
 sql(f"insert into public.training_courses(slug,version,title,owner_organization_id,published) values('signup-standard',2,'Private revision','{pilot}',true);")
 broken=sql("insert into public.training_courses(slug,title,published) values('not-ready','Incomplete',true) returning id").stdout.strip()
 module=sql("insert into public.daily_modules(code,version,title,academy,skill_level,sections,estimated_minutes,published) values('CD-0951','1.0.0','Standard Daily','Plumbing','foundations','[{\"title\":\"Lesson\"}]',2,false) returning id").stdout.strip()
 sql(f"insert into public.daily_questions(module_id,id,position,prompt,options) values('{module}','check',1,'Daily question','[\"A\",\"B\",\"C\",\"D\"]');insert into private.daily_answer_keys values('{module}','check',0,'Explanation','Lesson');")
 sql(f"insert into public.daily_sequence(module_id,skill_level,position) values('{module}','foundations',1);update public.daily_modules set published=true where id='{module}';")
 d=details(seat_count=999,owner_user_id=uid(1),pilot=True)
 signup=prepare(2,d)
 reject(7,f"select public.prepare_store_signup({q(json.dumps(details(store_name='sandbox store')))}::jsonb,'{uuid.uuid4()}')",'signup in progress')
 ok(bool(prepare(9,details(store_name='Sandbox Store',street='200 Different Street'))),'same trading name at another address does not merge companies or block signup')
 ok(prepare(2,d)==signup,'repeated same details reuse the signup instead of a second trial')
 ok(data(3,'select public.get_my_store_signup()') is None,'another account cannot read signup')
 own=data(2,'select public.get_my_store_signup()');ok(own['state']=='prepared' and 'seat_count' not in own['details'] and 'pilot' not in own['details'],'browser extras cannot choose capacity, owner or pilot status')
 ok(sql("select count(*) from public.organizations").stdout.strip()=='1','no store created before webhook confirmation')
 reject(2,f"select public.claim_store_signup_checkout('{signup}','{uid(2)}')",'permission denied')
 rejected=service(f"select public.claim_store_signup_checkout('{signup}','{uid(3)}')",False);ok(rejected.returncode!=0,'checkout claim is bound to verified actor')
 claim=json.loads(service(f"select public.claim_store_signup_checkout('{signup}','{uid(2)}')").stdout)
 ok(claim['plan_code']=='store_25' and claim['actor']==uid(2),'checkout claim uses saved plan and verified email')
 busy=json.loads(service(f"select public.claim_store_signup_checkout('{signup}','{uid(2)}')").stdout);ok(busy['busy'],'concurrent checkout caller cannot acquire second lease')
 service(f"select public.finish_store_signup_checkout('{signup}','{uid(2)}','{claim['lease']}','cs_test_SessionOne','https://checkout.stripe.com/c/pay/cs_test_SessionOne',now()+interval '1 day')")
 resume=json.loads(service(f"select public.claim_store_signup_checkout('{signup}','{uid(2)}')").stdout);ok(resume['url'].endswith('cs_test_SessionOne'),'saved checkout resumes same session')
 first=json.loads(provision(signup).stdout);store=first['store_id']
 ok(first['created'],'verified signup provisions store')
 ok(sql(f"select count(*) from public.seats where organization_id='{store}'").stdout.strip()=='25','capacity comes from saved package, not client seat count')
 ok(sql(f"select count(*) from public.seats where organization_id='{store}' and membership_id is not null").stdout.strip()=='1','initial manager consumes exactly one seat')
 ok(sql(f"select role from public.organization_memberships where user_id='{uid(2)}'").stdout.strip()=='manager','initial owner can opt into manager role')
 ok(sql(f"select count(*) from public.training_departments where organization_id='{store}'").stdout.strip()=='6','starter departments created')
 ok(sql(f"select count(*) from public.training_assignments where organization_id='{store}' and course_id='{course}' and due_date is null").stdout.strip()=='1','manager receives standard course with no automatic deadline')
 ok(sql(f"select count(*) from public.training_course_releases where organization_id='{store}' and course_id in ('{private_course}','{broken}')").stdout.strip()=='0','private and incomplete courses not copied')
 ok(sql(f"select count(*) from public.daily_assignments where organization_id='{store}' and module_id='{module}'").stdout.strip()=='1','Daily Drill enrolls initial manager')
 ok(data(2,'select public.get_my_store_signup()')['state']=='provisioned','return page can observe webhook-completed state')
 ok(data(2,'select public.get_my_company_accounts()')[0]['stores'][0]['access_mode']=='sandbox','company screen identifies sandbox subscription')
 ok(sql(f"select to_jsonb(t) from private.store_account_terms t where organization_id='{pilot}'").stdout.strip()==pilot_before,'new signup does not change pilot status or timestamps')
 for event in ['evt_first','evt_duplicate']:
  ok(not json.loads(provision(signup,event=event).stdout)['created'],'duplicate webhook cannot duplicate store or seats')
 r=provision(signup,subscription='WrongSub',event='evt_wrong',check=False);ok(r.returncode!=0,'replay with different subscription is rejected')
 reject(2,f"select public.provision_sandbox_store_signup('{signup}','evt_forged','cs_test_Forged','cus_Forged','sub_Forged','store_25','trialing',now(),now())",'permission denied')
 for table in ['store_signup_requests','sandbox_store_subscriptions','stripe_signup_events','store_signup_settings']:reject(2,f'select * from private.{table}','permission denied')
 owner_only=prepare(3,details(store_name='Billing-only owner store',company_name='Second company',become_manager=False,plan_code='store_15'))
 second=json.loads(provision(owner_only,session='SessionTwo',customer='CustomerTwo',subscription='SubscriptionTwo',event='evt_second',plan='store_15').stdout)
 ok(sql(f"select count(*) from public.organization_memberships where user_id='{uid(3)}'").stdout.strip()=='0','billing-only owner has no training membership')
 ok(sql(f"select count(*) from public.seats where organization_id='{second['store_id']}' and membership_id is not null").stdout.strip()=='0','billing-only owner consumes no training seat')
 ok(data(3,'select public.get_my_company_accounts()')[0]['is_owner'],'billing-only owner still has company ownership')
 invite=data(3,f"select to_jsonb(x) from public.prepare_employee_invitation('{second['store_id']}','signup8@example.test','Separate Manager','manager') x")
 ok(invite['email']=='signup8@example.test','billing-only owner can reserve a seat and invite the separate store manager')
 reject(3,f"select public.prepare_employee_invitation('{second['store_id']}','signup9@example.test','Employee','employee')",'Manager access required')
 actor(8,f"select public.accept_email_invitation('{invite['invitation_id']}')")
 ok(sql(f"select count(*) from public.organization_memberships where organization_id='{second['store_id']}' and user_id='{uid(8)}' and role='manager'").stdout.strip()=='1','invited manager joins the correct store independently of the billing-only owner')
 ok(sql(f"select count(*) from public.organization_memberships where user_id='{uid(3)}'").stdout.strip()=='0','designating manager does not give the owner an implicit training membership')
 ok(sql(f"select count(*) from public.training_assignments a join public.organization_memberships m on m.id=a.membership_id where m.user_id='{uid(8)}' and a.course_id='{course}' and a.due_date is null").stdout.strip()=='1','separately invited manager receives standard training without a default deadline')
 reject(3,f"select public.prepare_store_signup({q(json.dumps(details(store_name='Another location')))}::jsonb,'{uuid.uuid4()}')",'signup already exists')
 # Two deliveries for the same new signup serialize into exactly one store.
 third=prepare(4,details(store_name='Concurrent signup',plan_code='store_35'))
 with concurrent.futures.ThreadPoolExecutor(max_workers=2) as pool:
  responses=list(pool.map(lambda e:json.loads(provision(third,session='SessionThree',customer='CustomerThree',subscription='SubscriptionThree',event=e,plan='store_35').stdout),['evt_race1','evt_race2']))
 ok(sum(r['created'] for r in responses)==1 and len({r['store_id'] for r in responses})==1,'concurrent webhooks provision once')
 late=prepare(6,details(store_name='Late conflicting account'))
 sql(f"insert into public.organization_memberships(organization_id,user_id,email,role) values('{pilot}','{uid(6)}','signup6@example.test','employee');")
 before=sql('select count(*) from public.organizations').stdout
 r=provision(late,session='Late',customer='Late',subscription='Late',event='evt_late',check=False)
 ok(r.returncode!=0 and sql('select count(*) from public.organizations').stdout==before,'changed owner membership rolls back provisioning without partial store')
 # Future published standard courses reach existing sandbox staff; draft/private content stays out.
 future=sql("insert into public.training_courses(slug,title) values('future-standard','Future standard') returning id").stdout.strip()
 future_question=sql(f"insert into public.training_questions(course_id,position,prompt,options) values('{future}',1,'Question','[\"A\",\"B\"]') returning id").stdout.strip()
 sql(f"insert into public.training_lessons(course_id,position,title,body) values('{future}',1,'Lesson','[]');insert into private.training_answer_keys values('{future_question}',0,'Explanation');update public.training_courses set published=true where id='{future}';")
 ok(sql(f"select count(*) from public.training_assignments where organization_id='{store}' and course_id='{future}' and due_date is null").stdout.strip()=='1','new standard publication automatically reaches existing sandbox staff')
 ok(sql(f"select count(*) from public.training_course_releases where organization_id='{pilot}' and course_id='{future}'").stdout.strip()=='0','publication does not modify pilot catalog arrangements')
 print(f'Passed {checks} sandbox signup database, isolation, idempotency, concurrency, seat, catalog and pilot checks.')
finally:subprocess.run(['docker','rm','-f',name],capture_output=True)
