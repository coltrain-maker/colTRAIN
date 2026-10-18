"""Prepare RF-101 for the existing schema; does not contact Supabase or deploy.

The uploaded editorial source is retained verbatim. Final assessment changes are
explicit in approved-assessment.json. Rebuild outputs with this script.
"""
from pathlib import Path
import json
import re
import uuid

root = Path(__file__).resolve().parent.parent
folder = root / 'courses/RF-101'
source = json.loads((folder / 'source/RF-101_course_v1.1.json').read_text())
editorial = (folder / 'source/RF-101_full_course_v1.1.md').read_text()
assessment = json.loads((folder / 'approved-assessment.json').read_text())
namespace = uuid.UUID('16574c65-11aa-47dd-a055-e8ef7ca9498a')
identifier = lambda name: str(uuid.uuid5(namespace, name))
course_id = identifier('RF-101:1.1.0')


def plain(text):
    return text.replace('**', '').strip()


def lesson_blocks(lesson):
    number = lesson['position']
    match = re.search(rf'^### Lesson {number} — .*?\n(.*?)(?=^### Lesson |^## 5\.|\Z)', editorial, re.M | re.S)
    if not match:
        raise ValueError(f'Missing editorial lesson {number}')
    body = match.group(1)
    body = body[body.index('#### Why this matters'):]
    # Preserve these sections in the editorial archive, but do not show empty
    # media placeholders or an instruction to implement an interactive check.
    body = re.sub(r'^#### Supporting materials\n.*?(?=^#### |\Z)', '', body, flags=re.M | re.S)
    body = re.sub(r'^#### Optional practice\n.*?(?=^#### |\Z)', '', body, flags=re.M | re.S)
    body = re.sub(r'^#### Lesson knowledge check \(unscored\).*', '', body, flags=re.M | re.S)
    blocks = []
    for line in body.splitlines():
        line = line.strip()
        if not line:
            continue
        if line.startswith('#### '):
            kind, text = 'heading', line[5:]
        elif line.startswith('**') and line.endswith('**'):
            kind, text = 'heading', line
        elif line.startswith('- '):
            kind, text = 'bullet', line[2:]
        else:
            kind, text = 'paragraph', line
        blocks.append({'type': kind, 'text': plain(text)})
    check = lesson['knowledge_check']
    options = {o['id']: o['text'] for o in check['options']}
    if check['correct_option_id'] not in options:
        raise ValueError('Invalid practice answer')
    blocks += [{'type': 'heading', 'text': 'Practice question — unscored'},
               {'type': 'paragraph', 'text': check['prompt']}]
    blocks += [{'type': 'bullet', 'text': f"{o['id']}. {o['text']}"} for o in check['options']]
    blocks += [{'type': 'callout', 'text': 'Pause and choose an answer before reading the explanation. This practice does not use a quiz attempt or earn points.'},
               {'type': 'heading', 'text': 'Practice answer and explanation'},
               {'type': 'paragraph', 'text': f"{check['correct_option_id']}. {options[check['correct_option_id']]} {check['explanation']}"}]
    return blocks


lessons = [{'id': identifier(l['lesson_id'] + ':1.1.0'), 'position': l['position'],
            'title': l['title'], 'body': lesson_blocks(l)} for l in source['lessons']]
questions = []
for q in assessment['questions']:
    choices = [o['id'] for o in q['options']]
    if len(choices) != 4 or len(set(choices)) != 4 or q['points'] != 10:
        raise ValueError('Invalid final question')
    questions.append({'id': identifier(q['question_id'] + ':1.1.0'), 'position': q['position'],
                      'prompt': q['prompt'], 'options': [o['text'] for o in q['options']],
                      'correct_option': choices.index(q['correct_option_id']), 'explanation': q['explanation']})
assert len(lessons) == len(questions) == 5
assert [l['position'] for l in lessons] == list(range(1, 6))
assert [q['position'] for q in questions] == list(range(1, 6))
course = {'id': course_id, 'slug': 'rf-101-your-first-day-in-hardware-retail', 'version': 1,
          'title': source['title'], 'description': source['description'],
          'category': source['academy'], 'passing_percent': 80}
payload = {'course': course, 'lessons': lessons, 'questions': questions}
# This file contains final answers: it is an administrator/developer artifact,
# deliberately outside hosting/ and the public website build allowlist.
(folder / 'prepared-import.json').write_text(json.dumps(payload, ensure_ascii=False, indent=2) + '\n')
data = json.dumps(payload, ensure_ascii=False)
assert '$rf101data$' not in data
sql = """-- RF-101 source package 1.1.0; database revision 1.
-- Run ONLY this file in the existing project's SQL Editor as postgres.
-- Imports an unpublished draft. No release, assignment, schema or scoring changes.
-- An identical rerun is a no-op, including after publication/assignment.
-- Different content under these identifiers aborts instead of overwriting records.
begin;
do $rf101import$
declare
 payload jsonb := $rf101data$PAYLOAD$rf101data$::jsonb;
 c jsonb; l jsonb; q jsonb; target uuid;
begin
 c := payload->'course'; target := (c->>'id')::uuid;
 perform pg_advisory_xact_lock(hashtextextended('coltrain-course:' || target::text, 0));
 if exists(select 1 from public.training_courses where id=target) then
  if not exists(select 1 from public.training_courses t where t.id=target
   and t.slug=c->>'slug' and t.version=(c->>'version')::integer
   and t.title=c->>'title' and t.description=c->>'description'
   and t.category=c->>'category' and t.passing_percent=(c->>'passing_percent')::integer
   and t.owner_organization_id is null) then
   raise exception 'RF-101 course differs; create a new version rather than overwrite';
  end if;
  if (select count(*) from public.training_lessons where course_id=target) <> jsonb_array_length(payload->'lessons')
   or (select count(*) from public.training_questions where course_id=target) <> jsonb_array_length(payload->'questions') then
   raise exception 'RF-101 content differs; draft import was not changed';
  end if;
  for l in select value from jsonb_array_elements(payload->'lessons') loop
   if not exists(select 1 from public.training_lessons t where t.id=(l->>'id')::uuid
    and t.course_id=target and t.position=(l->>'position')::integer
    and t.title=l->>'title' and t.body=l->'body') then
    raise exception 'RF-101 lesson differs; draft import was not changed';
   end if;
  end loop;
  for q in select value from jsonb_array_elements(payload->'questions') loop
   if not exists(select 1 from public.training_questions t join private.training_answer_keys k on k.question_id=t.id
    where t.id=(q->>'id')::uuid and t.course_id=target and t.position=(q->>'position')::integer
    and t.prompt=q->>'prompt' and t.options=q->'options'
    and k.correct_option=(q->>'correct_option')::integer and k.explanation=q->>'explanation') then
    raise exception 'RF-101 question differs; draft import was not changed';
   end if;
  end loop;
 else
  insert into public.training_courses(id,slug,version,title,description,category,passing_percent,published)
   values(target,c->>'slug',(c->>'version')::integer,c->>'title',c->>'description',c->>'category',(c->>'passing_percent')::integer,false);
  for l in select value from jsonb_array_elements(payload->'lessons') loop
   insert into public.training_lessons(id,course_id,position,title,body)
    values((l->>'id')::uuid,target,(l->>'position')::integer,l->>'title',l->'body');
  end loop;
  for q in select value from jsonb_array_elements(payload->'questions') loop
   insert into public.training_questions(id,course_id,position,prompt,options)
    values((q->>'id')::uuid,target,(q->>'position')::integer,q->>'prompt',q->'options');
   insert into private.training_answer_keys(question_id,correct_option,explanation)
    values((q->>'id')::uuid,(q->>'correct_option')::integer,q->>'explanation');
  end loop;
 end if;
end;
$rf101import$;
commit;
select slug,title,published,
 (select count(*) from public.training_lessons where course_id=c.id) as lessons,
 (select count(*) from public.training_questions where course_id=c.id) as quiz_questions
from public.training_courses c where id='COURSE_ID';
""".replace('PAYLOAD', data).replace('COURSE_ID', course_id)
destination = root / 'supabase/course-imports/RF-101_IMPORT_DRAFT.sql'
destination.write_text(sql)
print(f'Prepared RF-101: {len(lessons)} lessons, {len(questions)} final questions; unpublished; {course_id}')
