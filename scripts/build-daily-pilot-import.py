"""Build an unpublished Daily import; approved source text/keys are preserved."""
from pathlib import Path
import json
import re
import subprocess
import sys
import uuid

root=Path(__file__).resolve().parent.parent
subprocess.run([sys.executable,str(root/'scripts/validate-daily-pilot.py')],check=True)
source=root/'courses/daily/pilot-v1.0.0/source'
namespace=uuid.UUID('68261790-2977-47ef-82e1-b80f3810101f')
modules=[]
for p in sorted((source/'modules').glob('*/*.json')):
 d=json.loads(p.read_text());m=d['metadata'];code=m['Stable module ID'];version=m['Version']
 identifier=str(uuid.uuid5(namespace,code+':'+version))
 course={'id':identifier,'code':code,'version':version,'title':m['Title'],'academy':m['Academy'],'skill_level':m['Skill level'].lower(),
 'sections':[s for s in d['employee_facing_sections'] if not s['heading'].startswith('5.')],
 'sources':d['sources'],'keywords':[s.strip() for s in m['Search keywords'].split(',') if s.strip()],
 'relevant_departments':[s.strip() for s in m['Relevant departments'].split(';') if s.strip()],
 'estimated_minutes':int(re.search(r'\d+',m['Estimated completion time']).group()),'prior_knowledge':m['Prior knowledge'],
 'related_course_code':None if m['Related existing full-course code']=='None specified' else m['Related existing full-course code']}
 questions=[];keys=[]
 for pos,q in enumerate(d['questions'],1):
  k=next(k for k in d['answer_key'] if k['question_id']==q['id'])
  questions.append({'module_id':identifier,'id':q['id'],'position':pos,'prompt':q['wording'],'options':[q['options'][l] for l in 'ABCD']})
  keys.append({'module_id':identifier,'question_id':q['id'],'correct_option':'ABCD'.index(k['correct_answer']),'explanation':k['explanation'],'teaching_reference':k['teaching_reference']})
 modules.append({'module':course,'questions':questions,'keys':keys,'source_document':d})
payload=json.dumps(modules,ensure_ascii=False,indent=2)
assert '$dailypayload$' not in payload and '$dailyimport$' not in payload
sql='''-- Apply AFTER migration 012, as postgres. Imports 10 UNPUBLISHED Daily drafts only.
-- Does not publish, release, schedule, assign, award points or change full courses.
-- Identical reruns are safe; different content under an existing ID aborts the whole transaction.
begin;
do $dailyimport$
declare payload jsonb := $dailypayload$PAYLOAD$dailypayload$::jsonb;
 item jsonb; c jsonb; q jsonb; k jsonb; target uuid;
begin
 for item in select value from jsonb_array_elements(payload) loop
  c:=item->'module'; target:=(c->>'id')::uuid;
  perform pg_advisory_xact_lock(hashtextextended('coltrain-daily:'||target::text,0));
  if exists(select 1 from public.daily_modules where id=target) then
   if (select to_jsonb(d)-'published'-'created_at' from public.daily_modules d where id=target)<>c
   or (select coalesce(jsonb_agg(to_jsonb(question_row) order by question_row.position),'[]') from public.daily_questions question_row where module_id=target)<>item->'questions'
   or (select coalesce(jsonb_agg(to_jsonb(key_row) order by key_row.question_id),'[]') from private.daily_answer_keys key_row where module_id=target)<>item->'keys'
   or not exists(select 1 from private.daily_editorial e where e.module_id=target and e.source_document=item->'source_document') then
    raise exception 'Daily % content differs; create a new version rather than overwrite',c->>'code';
   end if;
  else
   insert into public.daily_modules(id,code,version,title,academy,skill_level,sections,sources,keywords,relevant_departments,estimated_minutes,prior_knowledge,related_course_code)
   values(target,c->>'code',c->>'version',c->>'title',c->>'academy',c->>'skill_level',c->'sections',c->'sources',
    array(select jsonb_array_elements_text(c->'keywords')),array(select jsonb_array_elements_text(c->'relevant_departments')),
    (c->>'estimated_minutes')::integer,c->>'prior_knowledge',c->>'related_course_code');
   for q in select value from jsonb_array_elements(item->'questions') loop
    insert into public.daily_questions(module_id,id,position,prompt,options) values(target,q->>'id',(q->>'position')::integer,q->>'prompt',q->'options');
   end loop;
   for k in select value from jsonb_array_elements(item->'keys') loop
    insert into private.daily_answer_keys(module_id,question_id,correct_option,explanation,teaching_reference) values(target,k->>'question_id',(k->>'correct_option')::integer,k->>'explanation',k->>'teaching_reference');
   end loop;
   insert into private.daily_editorial(module_id,source_document) values(target,item->'source_document');
  end if;
 end loop;
end;
$dailyimport$;
commit;
select code,version,title,published,
 (select count(*) from public.daily_questions q where q.module_id=d.id) as questions
from public.daily_modules d where id in (IDS) order by code;
'''.replace('PAYLOAD',payload).replace('IDS',','.join("'"+m['module']['id']+"'" for m in modules))
out=root/'supabase/daily-imports';out.mkdir(exist_ok=True)
(out/'PILOT_10_IMPORT_DRAFTS.sql').write_text(sql)
(root/'courses/daily/pilot-v1.0.0/prepared-import.json').write_text(payload+'\n')
print('Built 10 draft Daily records and private keys; no publish, release or assignment.')
