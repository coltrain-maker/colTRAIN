"""Exercise the actual RF-101 import and training rules in isolated PostgreSQL.
No hosted writes, emails, website builds, or Netlify deployments.
"""
from pathlib import Path
import json
import subprocess
import time
import uuid

root = Path(__file__).resolve().parent.parent
subprocess.run(['python', 'scripts/build-rf101-import.py'], cwd=root, check=True)
data = json.loads((root / 'courses/RF-101/prepared-import.json').read_text())
script = (root / 'supabase/course-imports/RF-101_IMPORT_DRAFT.sql').read_text()
course = data['course']['id']
name = 'coltrain-rf101-' + uuid.uuid4().hex[:8]
image = 'postgres:17-alpine@sha256:b0f9560a2de083e2cc7382e75f808c7381a32852a7ec49117deedb300e552b24'
quote = lambda s: "'" + str(s).replace("'", "''") + "'"
admin = '00000000-0000-0000-0000-000000000001'
manager = '00000000-0000-0000-0000-000000000002'
employee = '00000000-0000-0000-0000-000000000004'
other = '00000000-0000-0000-0000-000000000005'
store = '10000000-0000-0000-0000-000000000001'
member = '20000000-0000-0000-0000-000000000002'
checks = 0


def sql(statement, check=True):
    r = subprocess.run(['docker', 'exec', '-i', name, 'psql', '-X', '-qAt', '-v',
                        'ON_ERROR_STOP=1', '-U', 'postgres'], input=statement,
                       text=True, capture_output=True)
    if check and r.returncode:
        raise RuntimeError(r.stderr)
    return r.stdout.strip() if check else r


def query(uid, statement, check=True):
    return sql(f"begin;set local role authenticated;set local request.jwt.claim.sub='{uid}';{statement};commit;", check)


def equal(actual, expected, label):
    global checks
    assert actual == expected, (label, actual, expected)
    checks += 1


def rejects(uid, statement, message):
    result = query(uid, statement, False)
    equal(result.returncode != 0 and message in result.stderr, True, message)


def answers(correct):
    return quote(json.dumps([{'question_id': q['id'], 'option': q['correct_option'] if i < correct
                              else (q['correct_option'] + 1) % 4}
                             for i, q in enumerate(data['questions'])])) + '::jsonb'


subprocess.run(['docker', 'run', '--rm', '-d', '--name', name, '--network', 'none',
                '-e', 'POSTGRES_HOST_AUTH_METHOD=trust', image], check=True, capture_output=True)
try:
    for attempt in range(60):
        if subprocess.run(['docker', 'exec', name, 'pg_isready', '-h', '127.0.0.1', '-U', 'postgres'], capture_output=True).returncode == 0:
            break
        time.sleep(.25)
    else:
        raise RuntimeError('PostgreSQL did not become ready')
    sql((root / 'tests/supabase-auth-fixture.sql').read_text())
    for migration in sorted((root / 'supabase/migrations').glob('*.sql')):
        sql(migration.read_text())
    # Reuse only identity/store setup, not other suites' deactivation scenarios.
    sql((root / 'tests/accounts-security.sql').read_text().split('\nset role authenticated;', 1)[0])
    baseline = sql("select to_jsonb(c) from public.training_courses c where slug='customer-trust'")
    invalid = sql(script.replace('"position": 1', '"position": 0', 1), False)
    equal(invalid.returncode != 0, True, 'invalid lesson aborts transaction')
    equal(sql(f"select count(*) from public.training_courses where id='{course}'"), '0', 'failed import leaves no partial course')
    sql(script)
    sql(script)
    equal(sql("select to_jsonb(c) from public.training_courses c where slug='customer-trust'"), baseline, 'original course untouched')
    equal(sql(f"select count(*)||':'||bool_or(published) from public.training_courses where id='{course}'"), '1:false', 'one unpublished draft')
    equal(sql(f"select count(*) from public.training_course_releases where course_id='{course}'"), '0', 'no automatic release')
    equal(sql(f"select count(*) from public.training_assignments where course_id='{course}'"), '0', 'no automatic assignment')
    equal(query(admin, f"select count(*) from public.training_lessons where course_id='{course}'"), '5', 'admin previews draft lessons')
    for uid in [employee, manager, other]:
        equal(query(uid, f"select count(*) from public.training_courses where id='{course}'"), '0', 'draft hidden from staff')
        equal(query(uid, f"select count(*) from public.training_questions where course_id='{course}'"), '0', 'draft questions hidden')
    rejects(employee, 'select * from private.training_answer_keys', 'permission denied')
    rejects(manager, 'select * from private.training_answer_keys', 'permission denied')
    rejects(admin, f"select public.release_training_course('{store}','{course}')", 'Published course not available')
    for lesson in data['lessons']:
        texts = [b['text'] for b in lesson['body']]
        equal(all(x in texts for x in ['Why this matters', 'Hardware-store example', 'What to say or do', 'Common mistakes', 'When to ask for help', 'Key takeaways']), True, 'editorial sections preserved')
        equal(any('[Needed]' in t for t in texts), False, 'no empty media placeholders')
        equal('Practice answer and explanation' in texts, True, 'practice includes feedback')
    conflict = script.replace('Learn how independent hardware stores serve their communities.', 'CHANGED DESCRIPTION', 1)
    result = sql(conflict, False)
    equal(result.returncode != 0 and 'course differs' in result.stderr, True, 'changed import refuses overwrite')
    equal(sql(f"select description from public.training_courses where id='{course}'"), data['course']['description'], 'conflict leaves original intact')
    # Publication/release here is LOCAL TEST DATA ONLY, never part of the import.
    sql(f"update public.training_courses set published=true where id='{course}'")
    equal(query(employee, f"select count(*) from public.training_courses where id='{course}'"), '0', 'publication alone does not grant store access')
    query(admin, f"select public.release_training_course('{store}','{course}')")
    equal(query(employee, f"select count(*) from public.training_courses where id='{course}'"), '1', 'released store sees course')
    equal(query(other, f"select count(*) from public.training_lessons where course_id='{course}'"), '0', 'other store cannot read lessons')
    query(manager, f"select public.assign_training('{course}','{store}',array['{member}'::uuid])")
    assignment = sql(f"select id from public.training_assignments where course_id='{course}'")
    rejects(employee, f"select public.submit_training_quiz('{assignment}',{answers(5)},gen_random_uuid())", 'Complete all lessons')
    for lesson in data['lessons']:
        query(employee, f"select public.complete_training_lesson('{assignment}','{lesson['id']}')")
    equal(sql(f"select count(*) from private.training_point_awards where course_id='{course}'"), '0', 'practice and lessons award no points')
    for correct, new in [(1, 10), (1, 0), (3, 20)]:
        result = json.loads(query(employee, f"select public.submit_training_quiz('{assignment}',{answers(correct)},gen_random_uuid())"))
        equal((result['passed'], result['new_points']), (False, new), 'failed attempt and one-time points')
    rejects(employee, f"select public.submit_training_quiz('{assignment}',{answers(5)},gen_random_uuid())", 'Ask your manager')
    query(manager, f"select public.unlock_training_retry('{assignment}','Reviewed the course together')")
    key = str(uuid.uuid4())
    result = json.loads(query(employee, f"select public.submit_training_quiz('{assignment}',{answers(5)},'{key}')"))
    equal((result['passed'], result['score'], result['new_points'], result['course_points']), (True, 100, 20, 50), 'supported retry awards only missing points')
    query(employee, f"select public.submit_training_quiz('{assignment}',{answers(5)},'{key}')")
    equal(sql(f"select count(*) from public.training_trophies where course_id='{course}'"), '1', 'one trophy after replay')
    rejects(manager, f"select public.get_training_attempt_review('{result['id']}')", 'Only the active learner')
    review = json.loads(query(employee, f"select public.get_training_attempt_review('{result['id']}')"))
    equal(len(review), 5, 'learner can review submitted answers')
    sql(script)
    equal(sql(f"select published from public.training_courses where id='{course}'"), 't', 'rerun does not unpublish')
    equal(sql(f"select count(*) from public.training_attempts where assignment_id='{assignment}'"), '4', 'rerun does not reset attempts')
    equal(sql(f"select sum(points) from private.training_point_awards where course_id='{course}'"), '50', 'rerun keeps awards')
    equal(sql(f"select count(*) from public.training_lessons where course_id='{course}'"), '5', 'rerun duplicates no content')
    manager_member = '20000000-0000-0000-0000-000000000001'
    query(manager, f"select public.assign_training('{course}','{store}',array['{manager_member}'::uuid])")
    second = sql(f"select id from public.training_assignments where course_id='{course}' and membership_id='{manager_member}'")
    for lesson in data['lessons']:
        query(manager, f"select public.complete_training_lesson('{second}','{lesson['id']}')")
    result = json.loads(query(manager, f"select public.submit_training_quiz('{second}',{answers(4)},gen_random_uuid())"))
    equal((result['passed'], result['score'], result['course_points']), (True, 80, 40), 'four of five passes at boundary')
    event = json.loads(query(manager, f"select public.create_training_competition('{store}','{course}','RF-101 Review',(now() at time zone 'America/New_York')::date,current_date+2,'Team lunch',employee_ids=>array['{member}'::uuid])"))['competition_id']
    result = json.loads(query(employee, f"select public.submit_training_challenge('{event}',{answers(5)},gen_random_uuid())"))
    equal(result['passed'], True, 'graduate can repeat quiz for competition')
    equal(sql(f"select sum(points) from private.training_point_awards where course_id='{course}' and user_id='{employee}'"), '50', 'review challenge duplicates no lifetime points')
    equal(sql(f"select count(*) from public.training_trophies where course_id='{course}' and user_id='{employee}'"), '1', 'review challenge duplicates no trophy')
    print(f'Passed {checks} RF-101 import/content/RLS/training assertions in isolated PostgreSQL.')
finally:
    subprocess.run(['docker', 'stop', name], check=False, capture_output=True)
