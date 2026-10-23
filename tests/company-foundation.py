"""Real SQL company migration/security tests in an isolated, networkless database."""
from pathlib import Path
import concurrent.futures
import json
import subprocess
import time
import uuid

root = Path(__file__).resolve().parent.parent
name = 'coltrain-companies-' + uuid.uuid4().hex[:8]
image = 'postgres:17-alpine@sha256:b0f9560a2de083e2cc7382e75f808c7381a32852a7ec49117deedb300e552b24'
checks = 0

def uid(n): return f'00000000-0000-0000-0000-{900+n:012}'
def sid(n): return f'10000000-0000-0000-0000-{900+n:012}'
def mid(n): return f'20000000-0000-0000-0000-{900+n:012}'
def quote(value): return "'" + str(value).replace("'", "''") + "'"
def sql(query, check=True):
    result = subprocess.run(['docker','exec','-i',name,'psql','-X','-qAt','-v','ON_ERROR_STOP=1','-U','postgres'], input=query, text=True, capture_output=True)
    if check and result.returncode: raise AssertionError(result.stderr)
    return result
def actor(n, query, check=True):
    return sql(f"begin;set local role authenticated;set local request.jwt.claim.sub='{uid(n)}';{query};commit;", check)
def data(n, query): return json.loads(actor(n, query).stdout.strip())
def ok(value, label):
    global checks
    assert value, label
    checks += 1
def reject(n, query, message):
    result = actor(n, query, False)
    ok(result.returncode != 0 and message in result.stderr, (message, result.stderr))
def accounts(n): return data(n, 'select public.get_my_company_accounts()')
def grant(n, person, capability, enabled=True, store=None):
    actor(n, f"select public.set_company_permission('{company}','{uid(person)}','{capability}',{str(enabled).lower()},{quote(store)+'::uuid' if store else 'null'})")
def overview(n, target=None):
    return data(n, f"select public.get_company_training_overview('{company}',{quote(target)+'::uuid' if target else 'null'})")
def snapshot():
    return sql("""select jsonb_build_object(
      'stores',(select jsonb_agg(to_jsonb(x) order by id) from public.organizations x),
      'members',(select jsonb_agg(to_jsonb(x) order by id) from public.organization_memberships x),
      'seats',(select jsonb_agg(to_jsonb(x) order by id) from public.seats x),
      'invites',(select jsonb_agg(to_jsonb(x) order by id) from public.invitations x),
      'assignments',(select jsonb_agg(to_jsonb(x) order by id) from public.training_assignments x),
      'awards',(select jsonb_agg(to_jsonb(x) order by user_id,question_id) from private.training_point_awards x),
      'drills',(select jsonb_agg(to_jsonb(x) order by id) from public.daily_assignments x),
      'messages',(select jsonb_agg(to_jsonb(x) order by id) from private.support_messages x),
      'posts',(select jsonb_agg(to_jsonb(x) order by id) from public.team_corner_posts x));""").stdout.strip()

try:
    subprocess.run(['docker','run','--rm','-d','--network','none','--name',name,'-e','POSTGRES_PASSWORD=isolated-test',image], check=True, capture_output=True)
    for _ in range(100):
        if subprocess.run(['docker','exec',name,'pg_isready','-h','127.0.0.1','-U','postgres'], capture_output=True).returncode == 0: break
        time.sleep(.2)
    else: raise RuntimeError('PostgreSQL did not start')
    sql((root/'tests/supabase-auth-fixture.sql').read_text())
    migrations = sorted((root/'supabase/migrations').glob('*.sql'))
    for p in migrations:
        if p.name < '202610230023': sql(p.read_text())
    sql('\n'.join(f"insert into auth.users(id,email,email_confirmed_at) values('{uid(n)}','person{n}@example.test',{'null' if n==12 else 'now()'});" for n in range(1,15)))
    sql(f"insert into public.platform_admins(user_id) values('{uid(1)}');")
    sql('\n'.join(f"insert into public.organizations(id,name) values('{sid(n)}','Store {n}');" for n in range(1,5)))
    for person, store, role in [(3,1,'manager'),(4,1,'employee'),(5,2,'manager'),(6,2,'employee')]:
        sql(f"insert into public.organization_memberships(id,organization_id,user_id,email,role) values('{mid(person)}','{sid(store)}','{uid(person)}','person{person}@example.test','{role}');insert into public.seats(organization_id,membership_id) values('{sid(store)}','{mid(person)}');")
    sql(f"insert into public.seats(organization_id) values('{sid(1)}');")
    actor(1, f"select public.create_invitation('{sid(1)}','invite@example.test')")
    course = sql("insert into public.training_courses(slug,title) values('company-test','Company test') returning id").stdout.strip()
    question = sql(f"insert into public.training_questions(course_id,position,prompt,options) values('{course}',1,'Private answer?','[\"A\",\"B\"]') returning id").stdout.strip()
    assignment = sql(f"insert into public.training_assignments(organization_id,membership_id,course_id,assigned_by,completed_at) values('{sid(1)}','{mid(4)}','{course}','{uid(1)}',now()) returning id").stdout.strip()
    sql(f"insert into private.training_point_awards(user_id,question_id,course_id,assignment_id) values('{uid(4)}','{question}','{course}','{assignment}');")
    module = sql("insert into public.daily_modules(code,version,title,academy,skill_level,sections,estimated_minutes) values('CD-0901','1.0.0','Daily test','Plumbing','foundations','[{\"title\":\"Test\"}]',2) returning id").stdout.strip()
    sql(f"insert into public.daily_assignments(organization_id,membership_id,module_id,available_on,assigned_by,completed_at) values('{sid(1)}','{mid(4)}','{module}',current_date,'{uid(1)}',now());")
    thread = data(3, f"select public.send_team_support_message('{sid(1)}','{uuid.uuid4()}','Private staff discussion',recipients=>array['{mid(4)}'::uuid],subject=>'Private',category=>'work')")['thread_id']
    actor(3, f"select public.create_team_corner_post('{sid(1)}','{uuid.uuid4()}','Private store post')")
    before = snapshot()
    sql((root/'supabase/migrations/202610230023_company_foundation.sql').read_text())
    sql((root/'supabase/migrations/202610230024_company_settings.sql').read_text())
    ok(snapshot() == before, 'legacy stores, memberships, seats, invitations, training, points, posts and messages unchanged')
    ok(sql("select count(*) from private.company_stores").stdout.strip() == '4', 'one company per existing store')
    ok(sql("select count(*) from private.companies where owner_user_id is not null").stdout.strip() == '0', 'no ownership inferred from manager status')
    ok(sql("select count(*) from private.store_account_terms where access_mode='legacy_no_charge'").stdout.strip() == '4', 'legacy free access preserved')
    ok(accounts(3) == [] and accounts(4) == [], 'ordinary managers and employees receive no company authority')
    company = data(1, f"select to_jsonb(public.admin_initialize_company('{sid(1)}','{uid(2)}','Company One','555-0100','Test group'))")
    foreign = data(1, f"select to_jsonb(public.admin_initialize_company('{sid(3)}','{uid(7)}','Other Company'))")
    ok(accounts(2)[0]['is_owner'], 'explicit verified owner established without a training seat')
    ok(sql(f"select count(*) from public.organization_memberships where user_id='{uid(2)}'").stdout.strip() == '0', 'billing/owner role does not consume membership')
    settings = data(2, f"select public.get_company_access_settings('{company}')")
    ok(settings['people'][0]['email']=='person2@example.test', 'owner sees human-readable authorized account details')
    actor(2,f"select public.save_company_details('{company}','Company One Updated','555-0200','New group')")
    updated=data(2,f"select public.get_company_access_settings('{company}')")
    ok(updated['company']['name']=='Company One Updated' and updated['company']['phone']=='555-0200', 'owner can edit company contact details')
    reject(3,f"select public.save_company_details('{company}','Spoof')",'Company owner access required')
    reject(3,f"select public.set_company_permission_by_email('{company}','person12@example.test','billing',true)",'Company owner access required')
    reject(2,f"select public.set_company_permission_by_email('{company}','person12@example.test','billing',true)",'No confirmed account matches')
    ok(settings['company']['phone'] == '555-0100' and settings['company']['buying_group'] == 'Test group', 'company contact fields retained')
    reject(3, f"select public.admin_initialize_company('{sid(2)}','{uid(3)}','Spoof')", 'Administrator access required')
    reject(1, f"select public.admin_initialize_company('{sid(1)}','{uid(13)}','Spoof')", 'Use ownership transfer')
    reject(1, f"select public.admin_initialize_company('{sid(4)}','{uid(12)}','Unconfirmed')", 'Choose a confirmed account')
    reject(2, f"select public.admin_link_company_store('{company}','{sid(2)}')", 'Administrator access required')
    actor(1, f"select public.admin_link_company_store('{company}','{sid(2)}')")
    ok(len(accounts(2)[0]['stores']) == 2, 'owner sees two linked stores')
    reject(1, f"select public.admin_link_company_store('{company}','{sid(3)}')", 'Only an unowned standalone store')
    actor(2,f"select public.set_company_permission_by_email('{company}',' Person8@Example.Test ','billing',true)")
    named=data(2,f"select public.get_company_access_settings('{company}')")
    ok(any(p['email']=='person8@example.test' for p in named['people']), 'exact-email grant normalizes email and resolves authorized person')
    grant(2,9,'training')
    grant(2,10,'training',store=sid(2))
    grant(2,11,'billing',store=sid(1))
    ok(all(s['can_bill'] and not s['can_oversee_training'] for s in accounts(8)[0]['stores']), 'billing only never gains training oversight')
    ok(all(not s['can_bill'] and s['can_oversee_training'] for s in accounts(9)[0]['stores']), 'training only never gains billing')
    ok([s['store_id'] for s in accounts(10)[0]['stores']] == [sid(2)], 'store-scoped training sees only selected store')
    ok([s['store_id'] for s in accounts(11)[0]['stores']] == [sid(1)], 'store-scoped billing sees only selected store')
    for person in [3,4,7,8,11]:
        reject(person, f"select public.get_company_training_overview('{company}')", 'Company training access required')
    reject(10, f"select public.get_company_training_overview('{company}','{sid(1)}')", 'Company training access required')
    ok(len(overview(9)['stores']) == 2 and len(overview(10)['stores']) == 1, 'overview respects companywide and store scope')
    member = next(m for s in overview(2)['stores'] for m in s['members'] if m['membership_id']==mid(4))
    ok(member['completed_courses']==1 and member['completed_drills']==1, 'overview reports saved course and Daily progress')
    ok(member['points']=={'course_points':10,'daily_points':5,'lifetime_points':15}, 'course, Daily, lifetime totals remain separate')
    ok('person4@example.test' not in json.dumps(overview(2)) and 'Private staff discussion' not in json.dumps(overview(2)), 'overview excludes emails and message content')
    for person in [2,8,9,10]:
        reject(person, f"select public.create_invitation('{sid(1)}','illegal@example.test')", 'Manager access required')
        reject(person, f"select public.get_team_support_thread('{thread}')", 'Private conversation not available')
        ok(actor(person, 'select count(*) from public.team_corner_posts').stdout.strip()=='0', 'company access cannot read Team Corner')
        ok(actor(person, 'select count(*) from public.training_questions').stdout.strip()=='0', 'oversight grants no raw quiz access')
    ok(actor(3, f"select private.can_manage('{sid(1)}')").stdout.strip()=='t', 'existing manager retains own-store management')
    ok(actor(3, f"select private.can_manage('{sid(2)}')").stdout.strip()=='f', 'linked store does not broaden manager access')
    for person in [3,4,8,9]:
        reject(person, f"select public.set_company_permission('{company}','{uid(person)}','billing',true)", 'Company owner access required')
    reject(2, f"select public.set_company_permission('{company}','{uid(12)}','training',true)", 'Choose a confirmed account')
    reject(2, f"select public.set_company_permission('{company}','{uid(9)}','training',true,'{sid(3)}')", 'Store is not in this company')
    reject(2, f"select public.set_company_permission('{company}','{uid(9)}','owner',true)", 'Choose billing or training access')
    for table in ['companies','company_stores','company_permissions','store_account_terms','company_access_audit']:
        reject(2, f'select * from private.{table}', 'permission denied')
    for query in ['select public.get_my_company_accounts()', f"select public.admin_set_store_pilot('{sid(1)}',true,'Unauthorized')"]:
        r=sql('set role anon;'+query,False)
        ok(r.returncode!=0 and 'permission denied' in r.stderr, 'anonymous company RPC rejected')
    reject(2, f"select public.admin_set_store_pilot('{sid(1)}',true,'Unauthorized')", 'Administrator access required')
    actor(1, f"select public.admin_set_store_pilot('{sid(1)}',true,'Approved pilot')")
    ok(accounts(2)[0]['stores'][0]['access_mode']=='pilot', 'pilot is explicitly marked')
    actor(1, f"select public.admin_set_store_pilot('{sid(1)}',false,'Pilot ended without charge')")
    ok(sql(f"select access_mode from private.store_account_terms where organization_id='{sid(1)}'").stdout.strip()=='awaiting_paid_approval', 'ending pilot waits for paid approval')
    ok(snapshot()==before, 'role, linking and pilot changes preserve all legacy records')
    grant(2,9,'training',False)
    reject(9, f"select public.get_company_training_overview('{company}')", 'Company training access required')
    grant(2,9,'training')
    # Duplicate concurrent role requests serialize and cannot create duplicate grants.
    with concurrent.futures.ThreadPoolExecutor(max_workers=2) as pool:
        outcomes=list(pool.map(lambda _: actor(2,f"select public.set_company_permission('{company}','{uid(14)}','training',true)"),range(2)))
    ok(all(r.returncode==0 for r in outcomes), 'concurrent repeated permission changes succeed')
    ok(sql(f"select count(*) from private.company_permissions where company_id='{company}' and user_id='{uid(14)}'").stdout.strip()=='1', 'concurrent grant is unique')
    grant(2,2,'billing')
    actor(2, f"select public.transfer_company_ownership('{company}','{uid(13)}')")
    ok(accounts(2)==[], 'previous owner loses company authority including delegated grants')
    ok(accounts(13)[0]['is_owner'], 'new owner receives company oversight')
    reject(2, f"select public.get_company_access_settings('{company}')", 'Company owner access required')
    reject(8, f"select public.transfer_company_ownership('{company}','{uid(8)}')", 'Company owner access required')
    audit=data(13,f"select public.get_company_access_settings('{company}')")['audit']
    ok(any(a['event']=='ownership_transferred' for a in audit) and any(a['event']=='pilot_changed' for a in audit), 'owner can inspect audit of role and pilot actions')
    # A request queued behind ownership transfer must check the new owner, not
    # authorize itself using an earlier ownership snapshot.
    with concurrent.futures.ThreadPoolExecutor(max_workers=1) as pool:
        transfer=pool.submit(actor,13,f"set local application_name='company-transfer-test';select public.transfer_company_ownership('{company}','{uid(14)}');select pg_sleep(.7)")
        for _ in range(20):
            if sql("select count(*) from pg_stat_activity where application_name='company-transfer-test' and wait_event='PgSleep'").stdout.strip()=='1': break
            time.sleep(.02)
        reject(13,f"select public.set_company_permission('{company}','{uid(12)}','billing',true)",'Company owner access required')
        ok(transfer.result().returncode==0, 'ownership transfer commits before waiting role change is authorized')
    actor(1, "select public.create_store('Future manual pilot',15)")
    ok(sql("select count(*) from private.company_stores s join public.organizations o on o.id=s.organization_id where o.name='Future manual pilot'").stdout.strip()=='1', 'existing create_store automatically attaches company container')
    # Exercise the exact operator pilot script, including idempotence and duplicate-name rollback.
    admin='2370c99a-9b5e-439a-b73a-00ada7a35661'
    sql(f"insert into auth.users(id,email,email_confirmed_at) values('{admin}','pilot-admin@example.test',now());insert into public.platform_admins(user_id) values('{admin}');insert into public.organizations(name) values('Coltrain Hardware');")
    pilot_sql=(root/'supabase/PILOT_COMPANY_SETUP.sql').read_text()
    sql(pilot_sql)
    sql(pilot_sql)
    ok(sql("select count(*) from public.organizations where name='Keith Hardware'").stdout.strip()=='1', 'pilot setup rerun creates no duplicate Keith store')
    ok(sql("select count(*) from private.store_account_terms t join public.organizations o on o.id=t.organization_id where o.name in ('Coltrain Hardware','Keith Hardware') and t.access_mode='pilot'").stdout.strip()=='2', 'both approved pilots protected')
    ok(sql("select count(*) from public.seats s join public.organizations o on o.id=s.organization_id where o.name='Keith Hardware'").stdout.strip()=='15', 'Keith test capacity is explicit')
    sql("update private.store_account_terms t set access_mode='awaiting_paid_approval',pilot_ended_at=now() from public.organizations o where o.id=t.organization_id and o.name='Coltrain Hardware';")
    sql("insert into public.organizations(name) values('Keith Hardware');")
    r=sql(pilot_sql,False)
    ok(r.returncode!=0 and 'Multiple stores named Keith Hardware' in r.stderr, 'ambiguous pilot names block setup')
    ok(sql("select t.access_mode from private.store_account_terms t join public.organizations o on o.id=t.organization_id where o.name='Coltrain Hardware'").stdout.strip()=='awaiting_paid_approval', 'ambiguous setup rolls back earlier pilot changes too')
    ok(sql("select count(*) from pg_class c join pg_namespace n on n.oid=c.relnamespace where n.nspname='private' and c.relname in ('companies','company_stores','company_permissions','store_account_terms','company_access_audit') and c.relrowsecurity").stdout.strip()=='5', 'all company tables have RLS enabled')
    print(f'Passed {checks} company foundation, legacy preservation, role/store isolation, ownership, audit, pilot and concurrency checks.')
finally:
    subprocess.run(['docker','rm','-f',name],capture_output=True)
