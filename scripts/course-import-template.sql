-- COURSE_CODE source package SOURCE_VERSION; database revision 1.
-- Run ONLY this file in the existing project's SQL Editor as postgres.
-- Imports an unpublished draft. No release, assignment, schema or scoring changes.
-- An identical rerun is a no-op, including after publication/assignment.
-- Different content under these identifiers aborts instead of overwriting records.
begin;
do $courseimport$
declare
 payload jsonb := $coursedata$PAYLOAD$coursedata$::jsonb;
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
   raise exception 'COURSE_CODE course differs; create a new version rather than overwrite';
  end if;
  if (select count(*) from public.training_lessons where course_id=target) <> jsonb_array_length(payload->'lessons')
   or (select count(*) from public.training_questions where course_id=target) <> jsonb_array_length(payload->'questions') then
   raise exception 'COURSE_CODE content differs; draft import was not changed';
  end if;
  for l in select value from jsonb_array_elements(payload->'lessons') loop
   if not exists(select 1 from public.training_lessons t where t.id=(l->>'id')::uuid
    and t.course_id=target and t.position=(l->>'position')::integer
    and t.title=l->>'title' and t.body=l->'body') then
    raise exception 'COURSE_CODE lesson differs; draft import was not changed';
   end if;
  end loop;
  for q in select value from jsonb_array_elements(payload->'questions') loop
   if not exists(select 1 from public.training_questions t join private.training_answer_keys k on k.question_id=t.id
    where t.id=(q->>'id')::uuid and t.course_id=target and t.position=(q->>'position')::integer
    and t.prompt=q->>'prompt' and t.options=q->'options'
    and k.correct_option=(q->>'correct_option')::integer and k.explanation=q->>'explanation') then
    raise exception 'COURSE_CODE question differs; draft import was not changed';
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
$courseimport$;
commit;
select slug,title,published,
 (select count(*) from public.training_lessons where course_id=c.id) as lessons,
 (select count(*) from public.training_questions where course_id=c.id) as quiz_questions
from public.training_courses c where id='COURSE_ID';
