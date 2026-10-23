"""Validate the Modules 11–20 handoff and prepare owner-run imports; no hosted writes."""
from pathlib import Path
from collections import Counter
import ast,hashlib,json,re,uuid
root=Path(__file__).resolve().parent.parent
batch=root/'courses/daily/modules-11-20-v1.0.0';source=batch/'source'
manifest=json.loads((source/'MANIFEST.json').read_text());aggregate=json.loads((source/'ALL_MODULES.json').read_text())
assert manifest['package_version']==aggregate['package_version']=='1.0.0'
assert manifest['module_count']==len(manifest['modules'])==len(aggregate['modules'])==10
academies={a['name'] for a in json.loads((root/'courses/academy-plan.json').read_text())['academies']}
namespace=uuid.UUID('68261790-2977-47ef-82e1-b80f3810101f')
modules=[];seen=set();question_ids=set();counts=Counter();report=[]
for item in sorted(manifest['modules'],key=lambda x:x['module_id']):
 code=item['module_id'];assert code not in seen;seen.add(code)
 path=source/item['json_file'];md_path=source/item['markdown_file']
 assert path.resolve().is_relative_to(source.resolve()) and md_path.resolve().is_relative_to(source.resolve())
 d=json.loads(path.read_text());m=d['metadata'];md=md_path.read_text()
 assert d['complete_markdown']==md and sum(x==d for x in aggregate['modules'])==1
 assert md in (source/'ALL_MODULES.md').read_text()
 for field,key in [('Stable module ID','module_id'),('Title','title'),('Version','version'),('Academy','academy'),('Skill level','level')]:assert m[field]==item[key],(code,field)
 assert m['Academy'] in academies and m['Skill level']=='Foundations'
 assert d['approval']['content_approved'] is True and d['approval']['publication_status']=='not published'
 assert d['actual_media_assets']==[] and len(d['employee_facing_sections'])==6
 for section in d['employee_facing_sections']+d['reviewer_sections']:assert section['content_markdown'] in md
 assert len(d['questions'])==len(d['answer_key'])==1
 # Extract links already supplied in the reviewer source inventory; invent no references.
 inventory=next(s['content_markdown'] for s in d['reviewer_sections'] if s['heading'].startswith('7.'))
 sources=[]
 for match in re.finditer(r'^- \[(Source \d+)\] (.*?), \[([^\]]+)\]\((https://[^)]+)\)(.*)$',inventory,re.M):
  ref,publisher,title,url,description=match.groups()
  sources.append({'id':ref,'publisher':publisher,'title':title,'url':url,'supports':description.lstrip(': ,'),'checked':'2026-10-22'})
 source_lines=[line for line in inventory.splitlines() if line.startswith('- [Source ')]
 assert len(sources)==len(source_lines),(code,'source reference could not be normalized')
 if not sources:
  assert code in ('CD-0019','CD-0020')
  note=re.search(r'\*\*Sources and authorship:\*\* (.+)',inventory).group(1)
  sources=[{'id':'Authorship','publisher':'colTRAIN','title':note,'url':''}]
 for ref in re.findall(r'\[Source (\d+)\]','\n'.join(s['content_markdown'] for s in d['employee_facing_sections'])):assert 'Source '+ref in {x['id'] for x in sources}
 identifier=str(uuid.uuid5(namespace,code+':'+m['Version']))
 module={'id':identifier,'code':code,'version':m['Version'],'title':m['Title'],'academy':m['Academy'],'skill_level':'foundations',
 'sections':[s for s in d['employee_facing_sections'] if not s['heading'].startswith('5.')],
 'sources':sources,'keywords':[v.strip() for v in m['Search keywords'].split(',') if v.strip()],
 'relevant_departments':[v.strip() for v in m['Relevant departments'].split(';') if v.strip()],
 'estimated_minutes':int(re.search(r'\d+',m['Estimated completion time']).group()),'prior_knowledge':m['Prior knowledge'],
 'related_course_code':None if m['Related existing full-course code']=='None specified' else m['Related existing full-course code']}
 questions=[];keys=[]
 for pos,q in enumerate(d['questions'],1):
  assert q['id'] not in question_ids and q['id'].startswith(code+'-Q');question_ids.add(q['id'])
  assert set(q['options'])==set('ABCD')
  k=next(k for k in d['answer_key'] if k['question_id']==q['id']);assert k['correct_answer'] in q['options'] and k['explanation'] and k['teaching_reference']
  check=d['employee_facing_sections'][4]['content_markdown'];assert q['id'] in check and q['wording'] in check
  for label,text in q['options'].items():assert f'{label}. {text}' in check
  assert k['explanation'] not in '\n'.join(s['content_markdown'] for s in d['employee_facing_sections'])
  questions.append({'module_id':identifier,'id':q['id'],'position':pos,'prompt':q['wording'],'options':[q['options'][label] for label in 'ABCD']})
  keys.append({'module_id':identifier,'question_id':q['id'],'correct_option':'ABCD'.index(k['correct_answer']),'explanation':k['explanation'],'teaching_reference':k['teaching_reference']})
 modules.append({'module':module,'questions':questions,'keys':keys,'source_document':d})
 counts[m['Academy']]+=1
 report.append({'code':code,'version':m['Version'],'title':m['Title'],'position':int(code.split('-')[1]),'text_approved_in_package':True,
 'media_assets':0,'sources':len(sources),'markdown_sha256':hashlib.sha256(md_path.read_bytes()).hexdigest(),'json_sha256':hashlib.sha256(path.read_bytes()).hexdigest(),
 'review_needs':next(s['content_markdown'] for s in d['reviewer_sections'] if s['heading'].startswith('9.'))})
assert seen=={f'CD-{n:04}' for n in range(11,21)} and set(counts)==academies and set(counts.values())=={1}
# Reuse the existing tested import SQL contract; this batch occupies positions 11–20.
tree=ast.parse((root/'scripts/build-daily-pilot-import.py').read_text())
template=next(n.value for n in ast.walk(tree) if isinstance(n,ast.Constant) and isinstance(n.value,str) and 'do $dailyimport$' in n.value)
payload=json.dumps(modules,ensure_ascii=False,indent=2);assert '$dailypayload$' not in payload and '$dailyimport$' not in payload
sql=template.replace('pilot_slot integer:=0','pilot_slot integer:=10').replace('10 UNPUBLISHED Daily drafts','10 UNPUBLISHED Daily drafts (CD-0011 through CD-0020)').replace('the pilot import','this import')
sql=sql.replace('  if to_regclass(\'public.daily_sequence\') is not null then', '''  if to_regclass('public.daily_sequence') is null then raise exception 'Apply the Daily sequence migration 013 first';end if;
  if to_regclass('public.daily_sequence') is not null then
   if exists(select 1 from public.daily_sequence where module_id=target and (skill_level<>c->>'skill_level' or position<>pilot_slot))
    or exists(select 1 from public.daily_sequence where skill_level=c->>'skill_level' and position=pilot_slot and module_id<>target) then
    raise exception 'Daily sequence slot % conflicts with %; no changes made',pilot_slot,c->>'code';
   end if;''')
sql=sql.replace('PAYLOAD',payload).replace('IDS',','.join("'"+m['module']['id']+"'" for m in modules))
out=root/'supabase/daily-imports';(out/'MODULES_11_20_IMPORT_DRAFTS.sql').write_text(sql)
(batch/'prepared-import.json').write_text(payload+'\n')
(batch/'handoff-manifest.json').write_text(json.dumps({'package_version':'1.0.0','module_count':10,'approval_source':'Uploaded package reports content approved; owner requested adding these modules on 2026-10-23.',
 'status':'Draft and store-specific release SQL prepared; not run on hosted database','source_link_verification':'URLs preserved from package, not independently rechecked','counts_by_academy':dict(counts),'modules':report},ensure_ascii=False,indent=2)+'\n')
release=(out/'PILOT_10_RELEASE_COLTRAIN_HARDWARE.sql').read_text()
release=release.replace('approved ten-module Daily pilot','approved Daily modules CD-0011 through CD-0020').replace('the pilot draft import','the modules 11–20 draft import')
start=release.index(' for item in select * from (values');end=release.index(' ) expected(id,code,version,slot) loop',start)
values=',\n'.join(f" ('{x['module']['id']}'::uuid,'{x['module']['code']}','{x['module']['version']}',{int(x['module']['code'].split('-')[1])})" for x in modules)
prerequisite=''' if (select count(*) from public.daily_sequence s join public.daily_modules d on d.id=s.module_id join public.daily_releases r on r.module_id=d.id
  where r.organization_id=target_store and d.published and s.skill_level='foundations' and s.position between 1 and 10)<>10 then
  raise exception 'Release the first ten Daily modules to Coltrain Hardware before adding modules 11–20';
 end if;
'''
release=release[:start]+prerequisite+' for item in select * from (values\n'+values+'\n'+release[end:]
# Replace only the final verification ID allowlist, not module metadata/slot checks.
a=release.rindex('d.id in (');b=release.index(')',a)
release=release[:a]+'d.id in ('+','.join("'"+x['module']['id']+"'" for x in modules)+release[b:]
release=release.replace('Complete the draft import and migration 013 first.','Complete the modules 11–20 draft import and migration 013 first.')
(out/'MODULES_11_20_RELEASE_COLTRAIN_HARDWARE.sql').write_text(release)
print('Validated exact source/Markdown/aggregates, approved versions, one quiz per module, private answers, source normalization and ten academies. Prepared draft import and store-specific release in positions 11–20; no hosted changes.')
