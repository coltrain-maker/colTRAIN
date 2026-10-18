"""Test all 21 remaining draft imports with actual PostgreSQL/RLS/training.
No hosted access, emails or Netlify deployments. Tests publish local fixtures only.
"""
from pathlib import Path
import copy
import importlib.util
import json
import subprocess
import time
import uuid

root=Path(__file__).resolve().parent.parent
subprocess.run(['python','scripts/build-launch-course-imports.py'],cwd=root,check=True)
spec=importlib.util.spec_from_file_location('launch_builder',root/'scripts/build-launch-course-imports.py')
import sys
sys.path.insert(0,str(root/'scripts'))
builder=importlib.util.module_from_spec(spec);spec.loader.exec_module(builder)
codes=list(builder.entries)
payloads={code:json.loads((root/f'courses/{code}/prepared-import.json').read_text()) for code in codes}
script=(root/'supabase/course-imports/REMAINING_21_IMPORT_DRAFTS.sql').read_text()
name='coltrain-launch-'+uuid.uuid4().hex[:8]
image='postgres:17-alpine@sha256:b0f9560a2de083e2cc7382e75f808c7381a32852a7ec49117deedb300e552b24'
quote=lambda s:"'"+str(s).replace("'","''")+"'"
admin='00000000-0000-0000-0000-000000000001'
manager='00000000-0000-0000-0000-000000000002'
employee='00000000-0000-0000-0000-000000000004'
other='00000000-0000-0000-0000-000000000005'
store='10000000-0000-0000-0000-000000000001'
member='20000000-0000-0000-0000-000000000002'
course_ids=','.join(quote(d['course']['id']) for d in payloads.values())


def sql(text,check=True):
    r=subprocess.run(['docker','exec','-i',name,'psql','-X','-qAt','-v','ON_ERROR_STOP=1','-U','postgres'],input=text,text=True,capture_output=True)
    if check and r.returncode:raise RuntimeError(r.stderr)
    return r.stdout.strip() if check else r


def answers(data,count):
    return quote(json.dumps([{'question_id':q['id'],'option':q['correct_option'] if i<count else (q['correct_option']+1)%4} for i,q in enumerate(data['questions'])]))+'::jsonb'


def role(uid):return f"set local role authenticated;set local request.jwt.claim.sub='{uid}';"


def ok(condition,label):return f'select test.ok({condition},{quote(label)});'


def rejects(command,message,label):
    return f'select test.rejects({quote(command)},{quote(message)},{quote(label)});'


subprocess.run(['docker','run','--rm','-d','--name',name,'--network','none','-e','POSTGRES_HOST_AUTH_METHOD=trust',image],check=True,capture_output=True)
try:
    for _ in range(60):
        if subprocess.run(['docker','exec',name,'pg_isready','-h','127.0.0.1','-U','postgres'],capture_output=True).returncode==0:break
        time.sleep(.25)
    else:raise RuntimeError('Database not ready')
    sql((root/'tests/supabase-auth-fixture.sql').read_text())
    for p in sorted((root/'supabase/migrations').glob('*.sql')):sql(p.read_text())
    sql((root/'tests/accounts-security.sql').read_text().split('\nset role authenticated;',1)[0])
    sql((root/'supabase/course-imports/RF-101_IMPORT_DRAFT.sql').read_text())
    sql((root/'supabase/course-imports/RF-102_103_104_IMPORT_DRAFTS.sql').read_text())
    rf=json.loads((root/'courses/RF-101/prepared-import.json').read_text());rfid=rf['course']['id']
    sql(f"update public.training_courses set published=true where id='{rfid}'")
    sql(f"begin;{role(admin)}select public.release_training_course('{store}','{rfid}');{role(manager)}select public.assign_training('{rfid}','{store}',array['{member}'::uuid]);commit;")
    assignment=sql(f"select id from public.training_assignments where course_id='{rfid}'")
    sql('begin;'+role(employee)+''.join(f"select public.complete_training_lesson('{assignment}','{l['id']}');" for l in rf['lessons'])+f"select public.submit_training_quiz('{assignment}',{answers(rf,5)},gen_random_uuid());commit;")
    baseline=sql("select jsonb_build_object('courses',(select jsonb_agg(to_jsonb(c) order by id) from public.training_courses c),'assignments',(select jsonb_agg(to_jsonb(a) order by id) from public.training_assignments a),'points',(select jsonb_agg(to_jsonb(p) order by question_id) from private.training_point_awards p),'trophies',(select jsonb_agg(to_jsonb(t) order by course_id) from public.training_trophies t))")
    old_ids=sql("select string_agg(quote_literal(id::text),',') from public.training_courses")
    index=script.rfind('"position": 1')
    failure=sql(script[:index]+script[index:].replace('"position": 1','"position": 0',1),False)
    assert failure.returncode!=0
    assert sql(f'select count(*) from public.training_courses where id in ({course_ids})')=='0'
    assert sql(f'select count(*) from public.training_course_catalog where course_id in ({course_ids})')=='0'
    print('Passed atomic rollback: a final-course error leaves no partial courses or metadata.')
    sql(script);sql(script)
    statements='begin;'
    statements+=ok(f'(select count(*) from public.training_courses where id in ({course_ids}) and not published)=21','21 unpublished drafts')
    statements+=ok(f'(select count(*) from public.training_lessons where course_id in ({course_ids}))=105','105 full lessons')
    statements+=ok(f'(select count(*) from public.training_questions where course_id in ({course_ids}))=105','105 final questions')
    statements+=ok(f'(select count(*) from private.training_answer_keys k join public.training_questions q on q.id=k.question_id where q.course_id in ({course_ids}))=105','105 private keys')
    statements+=ok(f'(select count(*) from public.training_course_releases where course_id in ({course_ids}))=0','no automatic release')
    statements+=ok(f'(select count(*) from public.training_assignments where course_id in ({course_ids}))=0','no automatic assignment')
    statements+=ok("(select count(distinct course_code) from public.training_course_catalog where course_code<>'')=25",'25 distinct approved catalog entries')
    statements+=role(employee)
    statements+=ok(f'(select count(*) from public.training_courses where id in ({course_ids}))=0','drafts hidden from employee')
    statements+=ok(f'(select count(*) from public.training_course_catalog where course_id in ({course_ids}))=0','draft tags hidden from employee')
    statements+=role(manager)
    statements+=ok(f'(select count(*) from public.training_courses where id in ({course_ids}))=0','drafts hidden from manager')
    statements+=rejects('select * from private.training_answer_keys','permission denied','manager cannot read final keys')
    statements+='commit;';sql(statements)
    for code,data in payloads.items():
        course=data['course']['id'];key=str(uuid.uuid4());label=code+'-result'
        # Imported data matches actual database rows, not just generated files.
        assert json.loads(sql(f"select jsonb_agg(body order by position) from public.training_lessons where course_id='{course}'"))==[l['body'] for l in data['lessons']]
        actual=json.loads(sql(f"select jsonb_agg(jsonb_build_object('prompt',q.prompt,'options',q.options,'correct_option',k.correct_option,'explanation',k.explanation) order by q.position) from public.training_questions q join private.training_answer_keys k on k.question_id=q.id where q.course_id='{course}'"))
        assert actual==[{k:q[k] for k in ('prompt','options','correct_option','explanation')} for q in data['questions']]
        steps=f"begin;update public.training_courses set published=true where id='{course}';"+role(admin)
        steps+=f"select public.release_training_course('{store}','{course}');"+role(other)
        steps+=ok(f"(select count(*) from public.training_courses where id='{course}')=0",code+' cross-store course isolation')
        steps+=ok(f"(select count(*) from public.training_course_catalog where course_id='{course}')=0",code+' cross-store metadata isolation')
        steps+=role(manager)+f"select public.assign_training('{course}','{store}',array['{member}'::uuid]);commit;"
        sql(steps)
        assignment=sql(f"select id from public.training_assignments where course_id='{course}' and membership_id='{member}'")
        steps='begin;'+role(employee)
        steps+=rejects(f"select public.submit_training_quiz('{assignment}',{answers(data,5)},gen_random_uuid())",'Complete all lessons',code+' lesson gating')
        steps+=''.join(f"select public.complete_training_lesson('{assignment}','{l['id']}');" for l in data['lessons'])
        steps+=ok(f"exists(select 1 from jsonb_array_elements(public.get_training_workspace('{store}')->'assignments') a where a->>'course_id'='{course}' and a->>'lessons_completed'='5' and a->>'course_points'='0')",code+' lessons/practice unscored')
        steps+=f"insert into test.codes values('{label}',public.submit_training_quiz('{assignment}',{answers(data,3)},gen_random_uuid())::text);"
        steps+=ok(f"(select (code::jsonb->>'score')::int=60 and code::jsonb->>'passed'='false' and code::jsonb->>'new_points'='30' from test.codes where label='{label}')",code+' server grades failed attempt')
        steps+=ok(f"public.submit_training_quiz('{assignment}',{answers(data,3)},gen_random_uuid())->>'new_points'='0'",code+' retry does not duplicate points')
        steps+=f"select public.submit_training_quiz('{assignment}',{answers(data,3)},gen_random_uuid());"
        steps+=rejects(f"select public.submit_training_quiz('{assignment}',{answers(data,5)},gen_random_uuid())",'Ask your manager',code+' three-attempt limit')
        steps+=role(manager)+f"select public.unlock_training_retry('{assignment}','Reviewed the course together');"+role(employee)
        steps+=f"insert into test.codes values('{label}-pass',public.submit_training_quiz('{assignment}',{answers(data,4)},'{key}')::text);"
        steps+=ok(f"(select code::jsonb->>'score'='80' and code::jsonb->>'passed'='true' and code::jsonb->>'new_points'='10' and code::jsonb->>'course_points'='40' from test.codes where label='{label}-pass')",code+' 80 percent pass and one-time points')
        steps+=f"select public.submit_training_quiz('{assignment}',{answers(data,4)},'{key}');"
        steps+=ok(f"(select count(*) from public.training_trophies where course_id='{course}')=1",code+' one trophy after replay')
        steps+=ok(f"jsonb_array_length(public.get_training_attempt_review((select (code::jsonb->>'id')::uuid from test.codes where label='{label}-pass')))=5",code+' learner feedback')
        steps+=role(manager)
        steps+=rejects(f"select public.get_training_attempt_review((select (code::jsonb->>'id')::uuid from test.codes where label='{label}-pass'))",'Only the active learner',code+' missed-answer privacy')
        steps+=f"insert into test.codes values('{label}-event',public.create_training_competition('{store}','{course}','{code} review',(now() at time zone 'America/New_York')::date,current_date+2,'Team reward',employee_ids=>array['{member}'::uuid])->>'competition_id');"+role(employee)
        steps+=ok(f"(public.submit_training_challenge((select code::uuid from test.codes where label='{label}-event'),{answers(data,5)},gen_random_uuid())->>'passed')::boolean",code+' separate graduate review quiz')
        steps+=role(manager)+f"select public.finish_training_competition((select code::uuid from test.codes where label='{label}-event'));"
        steps+='reset role;'
        steps+=ok(f"(select sum(points) from private.training_point_awards where course_id='{course}' and user_id='{employee}')=40",code+' review awards no duplicate lifetime points')
        steps+=ok(f"(select count(*) from public.training_trophies where course_id='{course}' and user_id='{employee}')=1",code+' review awards no duplicate trophy')
        steps+=ok(f"(select count(*) from public.training_attempts where assignment_id='{assignment}')=4",code+' attempt count preserved')
        steps+='commit;';sql(steps)
    # Published/assigned versions and later catalog edits survive identical imports.
    sql("update public.training_course_catalog set keywords=array['Owner reviewed keyword'] where course_code='CS-101'")
    sql(script)
    assert sql("select keywords[1] from public.training_course_catalog where course_code='CS-101'")=='Owner reviewed keyword'
    after=sql(f"select jsonb_build_object('courses',(select jsonb_agg(to_jsonb(c) order by id) from public.training_courses c where id in ({old_ids})),'assignments',(select jsonb_agg(to_jsonb(a) order by id) from public.training_assignments a where course_id in ({old_ids})),'points',(select jsonb_agg(to_jsonb(p) order by question_id) from private.training_point_awards p where course_id in ({old_ids})),'trophies',(select jsonb_agg(to_jsonb(t) order by course_id) from public.training_trophies t where course_id in ({old_ids})))")
    assert after==baseline,'Existing RF courses and earned records changed'
    conflict=script.replace(payloads[codes[0]]['course']['description'],'Changed course description',1)
    rejected=sql(conflict,False);assert rejected.returncode!=0 and 'course differs' in rejected.stderr
    # A wrong structured answer must be rejected rather than silently imported.
    sample=json.loads(next((root/'courses/CS-102/source').glob('*.json')).read_text())
    broken=copy.deepcopy(sample);broken['final_quiz']['questions'][0]['correct_answer']='D'
    try:builder.check_structured(broken,payloads['CS-102'],'','CS-102')
    except ValueError as error:assert 'answer mismatch' in str(error)
    else:raise AssertionError('Wrong structured key was accepted')
    count=sql('select count(*) from test.results')
    print(f'Passed {count} launch-course SQL/RLS assertions across all 21 courses, plus full data fidelity, atomic rollback, safe reruns/conflicts, existing RF progress preservation and structured-key mismatch rejection.')
finally:
    subprocess.run(['docker','stop',name],capture_output=True,check=False)
