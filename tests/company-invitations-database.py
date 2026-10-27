"""Actual permission boundaries and invitation lifecycle in an isolated database."""
from pathlib import Path
import json,subprocess,time,uuid
root=Path(__file__).resolve().parent.parent
name='coltrain-company-invites-'+uuid.uuid4().hex[:8]
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
def invite(n,email='person3@example.test',capability='training',store=None):return data(n,f"select public.prepare_company_invitation('{company}','{email}','New Administrator','{capability}',{repr(store) if store else 'null'})")
try:
 subprocess.run(['docker','run','--rm','-d','--network','none','--name',name,'-e','POSTGRES_PASSWORD=isolated-test',image],check=True,capture_output=True)
 for _ in range(100):
  if subprocess.run(['docker','exec',name,'pg_isready','-h','127.0.0.1','-U','postgres'],capture_output=True).returncode==0:break
  time.sleep(.2)
 sql((root/'tests/supabase-auth-fixture.sql').read_text())
 for p in sorted((root/'supabase/migrations').glob('*.sql')):sql(p.read_text())
 for n in range(1,10):sql(f"insert into auth.users(id,email,email_confirmed_at) values('{uid(n)}','person{n}@example.test',{'null' if n==9 else 'now()'});")
 sql(f"insert into public.platform_admins values('{uid(1)}');")
 store=data(1,"select to_jsonb(public.create_store('First Store',15))")
 other=data(1,"select to_jsonb(public.create_store('Other Store',15))")
 company=data(1,f"select to_jsonb(public.admin_initialize_company('{store}','{uid(2)}','First Company'))")
 # A company invitation authorizes only its owner, not arbitrary staff or delegated administrators.
 reject(3,f"select public.prepare_company_invitation('{company}','person3@example.test','Person')",'Company owner access required')
 reject(2,f"select public.prepare_company_invitation('{company}','person3@example.test','Person','platform_admin')",'Choose administrator access')
 reject(2,f"select public.prepare_company_invitation('{company}','person3@example.test','Person','billing','{other}')",'Store is not in this company')
 first=invite(2,store=store);ident=first['id']
 ok(first['email']=='person3@example.test','server returns canonical authorized email')
 ok(data(2,f"select public.get_company_access_settings('{company}')")['invitations'][0]['id']==ident,'owner sees pending invitation')
 reject(4,f"select public.get_company_access_settings('{company}')",'Company owner access required')
 reject(4,f"select public.accept_company_invitation('{ident}')",'not available for this account')
 reject(9,f"select public.accept_company_invitation('{ident}')",'Confirm your email first')
 reject(2,f"select public.prepare_company_invitation('{company}','person3@example.test','Person')",'Use the pending invitation')
 actor(3,f"select public.accept_company_invitation('{ident}')")
 ok(sql(f"select permission from private.company_permissions where user_id='{uid(3)}'").stdout.strip()=='training','training invitation grants only training')
 ok(sql(f"select organization_id from private.company_permissions where user_id='{uid(3)}'").stdout.strip()==store,'grant remains store scoped')
 actor(3,f"select public.accept_company_invitation('{ident}')")
 ok(sql(f"select count(*) from private.company_permissions where user_id='{uid(3)}'").stdout.strip()=='1','accepting twice is idempotent')
 reject(3,f"select public.prepare_company_invitation('{company}','person4@example.test','Person')",'Company owner access required')
 ok(sql(f"select count(*) from public.organization_memberships where user_id='{uid(3)}'").stdout.strip()=='0','administrator consumes no staff membership')
 ok(sql(f"select count(*) from public.platform_admins where user_id='{uid(3)}'").stdout.strip()=='0','administrator never gains platform admin')
 actor(2,f"select public.set_company_permission('{company}','{uid(3)}','training',false,'{store}')")
 actor(3,f"select public.accept_company_invitation('{ident}')")
 ok(sql(f"select count(*) from private.company_permissions where user_id='{uid(3)}'").stdout.strip()=='0','replayed accepted link never restores a removed permission')
 settings=data(2,f"select public.get_company_access_settings('{company}')");ok(settings['invitations']==[],'accepted invitation disappears from pending list')
 second=invite(2,'person4@example.test','both')
 reject(2,f"select public.prepare_company_invitation('{company}',replace_invitation:='{second['id']}')",'Wait one minute')
 sql(f"update private.company_invitations set last_email_attempt_at=now()-interval '2 minutes' where id='{second['id']}'")
 renewed=data(2,f"select public.prepare_company_invitation('{company}',replace_invitation:='{second['id']}')")
 ok(renewed['id']!=second['id'],'resend rotates identifier and invalidates original link')
 reject(4,f"select public.accept_company_invitation('{second['id']}')",'not available')
 actor(4,f"select public.accept_company_invitation('{renewed['id']}')")
 ok(sql(f"select string_agg(permission,',' order by permission) from private.company_permissions where user_id='{uid(4)}'").stdout.strip()=='billing,training','both grants both without staff access')
 third=invite(2,'person5@example.test','billing',store)
 reject(3,f"select public.revoke_company_invitation('{third['id']}')",'Company owner access required')
 actor(2,f"select public.revoke_company_invitation('{third['id']}')")
 reject(5,f"select public.accept_company_invitation('{third['id']}')",'not available')
 expired=invite(2,'person6@example.test','billing',store)
 sql(f"update private.company_invitations set expires_at=now()-interval '1 minute' where id='{expired['id']}'")
 reject(6,f"select public.accept_company_invitation('{expired['id']}')",'Invitation expired')
 renewed=invite(2,'person6@example.test','billing',store)
 actor(6,f"select public.accept_company_invitation('{renewed['id']}')")
 ok(sql(f"select permission from private.company_permissions where user_id='{uid(6)}'").stdout.strip()=='billing','replacement expired invitation grants only billing')
 pending=invite(2,'person7@example.test','training',store)
 sql(f"update private.companies set owner_user_id='{uid(8)}' where id='{company}'")
 reject(7,f"select public.accept_company_invitation('{pending['id']}')",'current owner')
 reject(2,f"select public.prepare_company_invitation('{company}','person5@example.test','Person')",'Company owner access required')
 reject(3,'select * from private.company_invitations','permission denied')
 reject(3,f"select public.record_company_invitation_email('{pending['id']}','sent')",'permission denied')
 sql(f"set role service_role;select public.record_company_invitation_email('{pending['id']}','failed')")
 ok(sql(f"select email_status from private.company_invitations where id='{pending['id']}'").stdout.strip()=='failed','service role records sanitized delivery outcome')
 print(f'Passed {checks} company invitation permission, role, isolation, expiry, resend, revoke and ownership checks.')
finally:subprocess.run(['docker','rm','-f',name],capture_output=True)
