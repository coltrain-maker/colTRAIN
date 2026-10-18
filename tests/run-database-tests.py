"""Run account/RLS tests in a fresh PostgreSQL container, without published ports."""
from pathlib import Path
import concurrent.futures
import subprocess
import time
import uuid

root = Path(__file__).resolve().parent.parent
name = 'coltrain-security-' + uuid.uuid4().hex[:10]
image = 'postgres:17-alpine@sha256:b0f9560a2de083e2cc7382e75f808c7381a32852a7ec49117deedb300e552b24'

def sql(text, check=True):
    result = subprocess.run(
        ['docker', 'exec', '-i', name, 'psql', '-X', '-qAt', '-v', 'ON_ERROR_STOP=1', '-U', 'postgres'],
        input=text, text=True, capture_output=True,
    )
    if check and result.returncode:
        raise RuntimeError(result.stderr)
    return result

subprocess.run(['docker', 'run', '--rm', '-d', '--name', name, '--network', 'none',
                '-e', 'POSTGRES_HOST_AUTH_METHOD=trust', image], check=True, capture_output=True)
try:
    for attempt in range(60):
        if subprocess.run(['docker', 'exec', name, 'pg_isready', '-h', '127.0.0.1', '-U', 'postgres'], capture_output=True).returncode == 0:
            break
        time.sleep(0.25)
    else:
        raise RuntimeError('PostgreSQL did not become ready')
    sql((root / 'tests/supabase-auth-fixture.sql').read_text())
    for migration in sorted((root / 'supabase/migrations').glob('*.sql')):
        sql(migration.read_text())
    result = sql((root / 'tests/accounts-security.sql').read_text())
    print(next(line for line in result.stdout.splitlines() if line.startswith('Passed ')))
    result = sql((root / 'tests/team-media-security.sql').read_text())
    print(next(line for line in result.stdout.splitlines() if line.startswith('Passed ')))
    result = sql((root / 'tests/email-invitations.sql').read_text())
    print(next(line for line in result.stdout.splitlines() if line.startswith('Passed ')))
    result = sql((root / 'tests/invitation-email-results.sql').read_text())
    print(next(line for line in result.stdout.splitlines() if line.startswith('Passed ')))
    result = sql((root / 'tests/training-security.sql').read_text())
    print(next(line for line in result.stdout.splitlines() if line.startswith('Passed ')))
    result = sql((root / 'tests/competitions-security.sql').read_text())
    print(next(line for line in result.stdout.splitlines() if line.startswith('Passed ')))
    result = sql((root / 'tests/team-corner-security.sql').read_text())
    print(next(line for line in result.stdout.splitlines() if line.startswith('Passed ')))
    result = sql((root / 'tests/notifications-security.sql').read_text())
    print(next(line for line in result.stdout.splitlines() if line.startswith('Passed ')))
    result = sql((root / 'tests/profile-avatars-security.sql').read_text())
    print(next(line for line in result.stdout.splitlines() if line.startswith('Passed ')))
    result = sql((root / 'tests/course-catalog-security.sql').read_text())
    print(next(line for line in result.stdout.splitlines() if line.startswith('Passed ')))
    sql("update public.organization_memberships set status='active',deactivated_at=null where id='20000000-0000-0000-0000-000000000062'; delete from private.training_notifications where user_id='00000000-0000-0000-0000-000000000062';")
    def read_notifications(index):
        return sql("begin;set local role authenticated;set local request.jwt.claim.sub='00000000-0000-0000-0000-000000000062';select public.get_my_training_notifications('10000000-0000-0000-0000-000000000060');select pg_sleep(.1);commit;",check=False)
    with concurrent.futures.ThreadPoolExecutor(max_workers=2) as pool:
        inboxes=list(pool.map(read_notifications,[1,2]))
    assert all(r.returncode==0 for r in inboxes),[r.stderr for r in inboxes]
    assert sql("select count(*) from private.training_notifications where user_id='00000000-0000-0000-0000-000000000062'").stdout.strip()=='1'
    print('Passed concurrent notification refresh: one persistent receipt per event across two tabs.')
    # Reproduce a legacy placeholder and exercise the incremental repair itself.
    sql("update public.team_corner_posts set author_name='Teammate' where id='92000000-0000-4000-8000-000000000052'; update public.team_corner_comments set author_name='Teammate' where id='93000000-0000-4000-8000-000000000052';")
    repair = (root / 'supabase/migrations/202610180008_team_corner_author_names.sql').read_text()
    sql(repair[repair.index('update public.team_corner_posts set author_name=private.team_corner_author_name(author_id)'):repair.index("notify pgrst")])
    assert sql("select author_name from public.team_corner_posts where id='92000000-0000-4000-8000-000000000052'").stdout.strip() == 'Sarah Updated'
    assert sql("select author_name from public.team_corner_comments where id='93000000-0000-4000-8000-000000000052'").stdout.strip() == 'Sarah Updated'
    print('Passed incremental repair of existing placeholder post and comment authors.')
    store = sql("select id from public.organizations where name='Concurrency test store';").stdout.strip()
    def reserve(index):
        return sql(f"""begin; set local role authenticated;
          set local request.jwt.claim.sub='00000000-0000-0000-0000-000000000001';
          select invitation_id from public.create_invitation('{store}','race{index}@example.test');
          select pg_sleep(0.25); commit;""", check=False)
    with concurrent.futures.ThreadPoolExecutor(max_workers=2) as pool:
        outcomes = list(pool.map(reserve, [1, 2]))
    assert sum(result.returncode == 0 for result in outcomes) == 1, 'A single free seat must have one successful reservation'
    assert all(result.returncode == 0 or 'No available seats' in result.stderr for result in outcomes)
    assert sql(f"select count(*) from public.invitations where organization_id='{store}' and revoked_at is null;").stdout.strip() == '1'
    print('Passed concurrent seat reservation test (one seat, two requests).')
    training_assignment = sql("select id from public.training_assignments where membership_id='20000000-0000-0000-0000-000000000022';").stdout.strip()
    duplicate_key = str(uuid.uuid4())
    def submit_training(key):
        return sql(f"""begin; set local role authenticated;
          set local request.jwt.claim.sub='00000000-0000-0000-0000-000000000022';
          select public.submit_training_quiz('{training_assignment}',test.training_answers(0),'{key}');
          select pg_sleep(0.15); commit;""", check=False)
    with concurrent.futures.ThreadPoolExecutor(max_workers=2) as pool:
        duplicates = list(pool.map(submit_training, [duplicate_key, duplicate_key]))
    assert all(result.returncode == 0 for result in duplicates), [r.stderr for r in duplicates]
    assert sql(f"select count(*) from public.training_attempts where assignment_id='{training_assignment}';").stdout.strip() == '2'
    with concurrent.futures.ThreadPoolExecutor(max_workers=2) as pool:
        remaining = list(pool.map(submit_training, [str(uuid.uuid4()), str(uuid.uuid4())]))
    assert sum(result.returncode == 0 for result in remaining) == 1, 'Only one final attempt may be consumed'
    assert all(result.returncode == 0 or 'Ask your manager' in result.stderr for result in remaining)
    assert sql(f"select count(*) from public.training_attempts where assignment_id='{training_assignment}';").stdout.strip() == '3'
    print('Passed concurrent quiz submissions: duplicate key uses one attempt; competing requests cannot exceed the attempt limit.')
    review_event = sql("""set role authenticated;set request.jwt.claim.sub='00000000-0000-0000-0000-000000000040';
      select public.create_training_competition('10000000-0000-0000-0000-000000000040','c1000000-0000-4000-8000-000000000001','Race review',(now() at time zone 'America/New_York')::date,current_date+2,'Lunch',all_employees=>true)->>'competition_id';""").stdout.strip()
    def submit_challenge(key):
        return sql(f"""begin;set local role authenticated;set local request.jwt.claim.sub='00000000-0000-0000-0000-000000000042';
          select public.submit_training_challenge('{review_event}',test.training_answers(5),'{key}');
          select pg_sleep(0.1);commit;""",check=False)
    review_key=str(uuid.uuid4())
    with concurrent.futures.ThreadPoolExecutor(max_workers=2) as pool:
        outcomes=list(pool.map(submit_challenge,[review_key,review_key]))
    assert all(result.returncode==0 for result in outcomes), [r.stderr for r in outcomes]
    assert sql(f"select count(*) from private.training_challenge_attempts where competition_id='{review_event}'").stdout.strip()=='1'
    assert submit_challenge(str(uuid.uuid4())).returncode==0
    with concurrent.futures.ThreadPoolExecutor(max_workers=2) as pool:
        outcomes=list(pool.map(submit_challenge,[str(uuid.uuid4()),str(uuid.uuid4())]))
    assert sum(result.returncode==0 for result in outcomes)==1, [r.stderr for r in outcomes]
    assert sql(f"select count(*) from private.training_challenge_attempts where competition_id='{review_event}'").stdout.strip()=='3'
    print('Passed concurrent review challenges: idempotent replay and three-attempt maximum.')
    corner_store='10000000-0000-0000-0000-000000000050'
    corner_user='00000000-0000-0000-0000-000000000052'
    corner_key=str(uuid.uuid4())
    def corner_post(index):
        return sql(f"""begin;set local role authenticated;set local request.jwt.claim.sub='{corner_user}';
          select public.create_team_corner_post('{corner_store}','{corner_key}','Concurrent post');
          select pg_sleep(.1);commit;""",check=False)
    with concurrent.futures.ThreadPoolExecutor(max_workers=2) as pool:
        outcomes=list(pool.map(corner_post,[1,2]))
    assert all(result.returncode==0 for result in outcomes),[r.stderr for r in outcomes]
    assert sql(f"select count(*) from public.team_corner_posts where id='{corner_key}'").stdout.strip()=='1'
    photo_key=str(uuid.uuid4())
    photo_path=sql(f"""set role authenticated;set request.jwt.claim.sub='{corner_user}';
      select public.register_team_corner_media('{corner_store}','{photo_key}')->>'object_name';""").stdout.strip()
    sql(f"set role authenticated;set request.jwt.claim.sub='{corner_user}';insert into storage.objects(bucket_id,name) values('team-media','{photo_path}');")
    race_keys=[str(uuid.uuid4()),str(uuid.uuid4())]
    def attach_photo(key):
        return sql(f"""begin;set local role authenticated;set local request.jwt.claim.sub='{corner_user}';
          select public.create_team_corner_post('{corner_store}','{key}','Attach once',array['{photo_key}'::uuid]);
          select pg_sleep(.1);commit;""",check=False)
    with concurrent.futures.ThreadPoolExecutor(max_workers=2) as pool:
        outcomes=list(pool.map(attach_photo,race_keys))
    assert sum(result.returncode==0 for result in outcomes)==1,[r.stderr for r in outcomes]
    assert all(r.returncode==0 or 'Photo is not available' in r.stderr for r in outcomes)
    assert sql(f"select count(*) from public.team_corner_posts where id in ('{race_keys[0]}','{race_keys[1]}')").stdout.strip()=='1'
    comment_key=str(uuid.uuid4())
    def corner_comment(index):
        return sql(f"""begin;set local role authenticated;set local request.jwt.claim.sub='{corner_user}';
          select public.create_team_corner_comment('{corner_key}','{comment_key}','Concurrent comment');
          select pg_sleep(.1);commit;""",check=False)
    with concurrent.futures.ThreadPoolExecutor(max_workers=2) as pool:
        outcomes=list(pool.map(corner_comment,[1,2]))
    assert all(r.returncode==0 for r in outcomes),[r.stderr for r in outcomes]
    assert sql(f"select count(*) from public.team_corner_comments where id='{comment_key}'").stdout.strip()=='1'
    print('Passed concurrent Team Corner submissions: one post/comment per key; a photo attaches only once.')



finally:
    subprocess.run(['docker', 'stop', name], check=False, capture_output=True)
