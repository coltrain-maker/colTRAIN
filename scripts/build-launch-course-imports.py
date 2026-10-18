"""Prepare the owner's remaining 21 launch courses, without hosted access.

Markdown supplies the full employee text. Structured files are cross-checked;
their instructions are never executed. All outputs are unpublished drafts.
"""
from pathlib import Path
import hashlib
import json
import re
import unicodedata
import uuid
from course_catalog import metadata

root=Path(__file__).resolve().parent.parent
approved=json.loads((root/'courses/approved-launch-catalog.json').read_text())
entries={c['code']:{**c,'academy':a['name']} for a in approved['academies'] for c in a['courses'] if not c['code'].startswith('RF-')}
namespace=uuid.UUID('16574c65-11aa-47dd-a055-e8ef7ca9498a')
identifier=lambda value:str(uuid.uuid5(namespace,value))
plain=lambda value:value.replace('**','').strip()
normalize=lambda value:re.sub(r'[^\w]+',' ',unicodedata.normalize('NFKC',plain(str(value))).lower()).strip()
template=(root/'scripts/course-import-template.sql').read_text()


def section(text,number):
    m=re.search(rf'^## {number}\..*?\n(.*?)(?=^## \d+\.|\Z)',text,re.M|re.S)
    if not m:raise ValueError(f'Missing section {number}')
    return m.group(1)


def parse_lessons(text,code):
    lessons=[]
    for segment in re.split(r'^### ',section(text,4),flags=re.M)[1:]:
        heading,rest=segment.split('\n',1)
        match=re.search(rf'{code}-L(\d{{2}})',heading)
        if not match:raise ValueError('Unknown lesson heading '+heading)
        source_id=match.group();position=int(match.group(1))
        if heading.startswith('Lesson '):
            title=re.sub(r'\s*\('+re.escape(source_id)+r'\)\s*$','',re.split(r': | — ',heading,maxsplit=1)[1])
        else:
            title=re.sub(r'\s*\(\d+ minutes\)\s*$','',heading[len(source_id):].lstrip(': —'))
        start=re.search(r'^(?:#### Why this matters|\*\*Why this matters)',rest,re.M)
        if not start:raise ValueError('No lesson introduction in '+source_id)
        rest=rest[start.start():]
        # Only empty/unsupplied media instructions are removed; all instructional
        # text, takeaways, examples, and unscored practice stay in the lesson.
        rest=re.sub(r'^(?:#### Supporting materials?[^\n]*|\*\*Supporting materials?[^\n]*).*?(?=^(?:#### Key takeaways|\*\*Key takeaways)|\Z)','',rest,flags=re.M|re.S)
        body=[]
        for line in rest.splitlines():
            line=line.strip()
            if not line:continue
            if line.startswith('#### '):kind,value='heading',line[5:]
            elif re.fullmatch(r'\*\*[^*]+\*\*',line):kind,value='heading',line
            elif line.startswith('- '):kind,value='bullet',line[2:]
            else:kind,value='paragraph',line
            body.append({'type':kind,'text':plain(value)})
        joined='\n'.join(b['text'] for b in body)
        for phrase in ['Why this matters','Hardware-store example','What to say or do','Common mistakes','When to ask for help','Key takeaways']:
            if phrase not in joined:raise ValueError(f'{source_id} missing {phrase}')
        if re.search(r'needed|not embedded',joined,re.I) and re.search(r'\[Needed|IMG\d+',joined):
            raise ValueError('Unremoved media placeholder in '+source_id)
        if not re.search(r'Answer:|Sample answer:',joined):raise ValueError('Missing practice feedback in '+source_id)
        lessons.append({'id':identifier(source_id+':1.0.0'),'position':position,'title':title.strip(),'body':body})
    if len(lessons)!=5 or [l['position'] for l in lessons]!=list(range(1,6)):raise ValueError('Expected five ordered lessons')
    return lessons


def parse_assessment(text,code):
    assessment=section(text,5)
    split=re.search(r'^### [^\n]*answer key[^\n]*\n',assessment,re.M|re.I)
    if not split:raise ValueError('Missing separated final answer key')
    facing,key=assessment[:split.start()],assessment[split.end():]
    keys={}
    for line in key.splitlines():
        clean=plain(line)
        table=re.match(r'\|\s*('+code+r'-Q\d{2})\s*\|\s*([A-D])\s*\|(.*)',clean)
        inline=re.match(r'-\s*('+code+r'-Q\d{2})\s*:\s*([A-D])\s*—\s*(.*)',clean)
        if table:
            cells=[x.strip() for x in table.group(3).split('|')]
            explanation=cells[1] if cells[0]=='10' else cells[0]
            explanation=re.split(r'\s+Review\s+'+code+r'-L',explanation,maxsplit=1)[0]
            keys[table.group(1)]=(table.group(2),explanation)
        elif inline:
            explanation=re.split(r'\s+(?:Objective:|Review:|Review '+code+r'-L)',inline.group(3),maxsplit=1)[0]
            keys[inline.group(1)]=(inline.group(2),explanation)
    # CS-101's key uses one multi-line block per question.
    if not keys:
        starts=list(re.finditer(r'^\*\*('+code+r'-Q\d{2})\*\*\s*$',key,re.M))
        for i,m in enumerate(starts):
            chunk=plain(key[m.end():starts[i+1].start() if i+1<len(starts) else len(key)])
            correct=re.search(r'Correct answer:\s*([A-D])\b',chunk)
            explanation=re.search(r'^-?\s*Explanation:\s*(.+)',chunk,re.M)
            if not correct or not explanation:raise ValueError('Incomplete key '+m.group(1))
            keys[m.group(1)]=(correct.group(1),explanation.group(1))
    starts=list(re.finditer(r'^(?:### |\*\*)('+code+r'-Q\d{2})(?:\*\*)?([^\n]*)\n',facing,re.M))
    questions=[]
    for i,m in enumerate(starts):
        source_id=m.group(1)
        chunk=facing[m.end():starts[i+1].start() if i+1<len(starts) else len(facing)]
        prompt=[];options=[]
        inline=m.group(2).strip()
        if inline.startswith('—'):prompt.append(inline[1:].strip())
        elif inline and not inline.startswith('('):raise ValueError('Unrecognized question heading '+source_id)
        for line in chunk.splitlines():
            line=plain(line)
            if not line:continue
            choice=re.match(r'^-?\s*([A-D])\.\s+(.+)',line)
            if choice:options.append((choice.group(1),choice.group(2)))
            elif re.match(r'^(?:Learning objective assessed|Objective|Related lesson|Lesson|Assesses|Points|Review):',line):continue
            elif not options:prompt.append(line.removeprefix('Question:').strip())
            else:raise ValueError(f'Unexpected text after {source_id} choices: {line}')
        if len(prompt)!=1 or [o[0] for o in options]!=list('ABCD'):raise ValueError(f'Incomplete question {source_id}: {prompt}')
        answer,explanation=keys[source_id]
        questions.append({'id':identifier(source_id+':1.0.0'),'position':i+1,'prompt':plain(prompt[0]),'options':[o[1] for o in options],
                          'correct_option':'ABCD'.index(answer),'explanation':explanation.strip()})
    if len(questions)!=5 or set(keys)!={f'{code}-Q{i:02}' for i in range(1,6)}:raise ValueError('Expected five matching final questions/keys')
    return questions


def choices(question):
    value=question.get('choices',question.get('options'))
    if isinstance(value,dict):return [value[c] for c in 'ABCD']
    if isinstance(value,list) and all(isinstance(x,dict) for x in value):
        if [v['id'] for v in value]!=list('ABCD'):raise ValueError('Unexpected option identifiers')
        return [v['text'] for v in value]
    raise ValueError('Unknown choice structure')


def check_structured(data,payload,text,code):
    notes=[]
    info=data.get('course_information',data)
    if normalize(info['title'])!=normalize(entries[code]['title']):raise ValueError('Title disagrees with approved catalog')
    academy=info['academy']
    if academy!=entries[code]['academy']:raise ValueError('Academy disagrees with approved catalog')
    if 'foundations' not in str(info.get('skill_level',info.get('level','Foundations'))).lower():raise ValueError('Unexpected launch skill level')
    if info.get('version','1.0.0')!='1.0.0':raise ValueError('Unexpected source version')
    quiz=data.get('final_quiz',data.get('final_scored_quiz',{}))
    variants=[quiz[key] for key in ['questions','questions_full','employee_facing_questions','questions_employee_facing'] if isinstance(quiz.get(key),list)]
    key_rows=next((quiz[key] for key in ['answer_key','instructor_answer_key','answer_key_manager_only'] if isinstance(quiz.get(key),list)),[])
    key_map={q.get('id',q.get('question_id')):q for q in key_rows}
    for variant in variants:
        if len(variant)!=5:raise ValueError('Structured final question count mismatch')
        for i,(source,q) in enumerate(zip(variant,payload['questions'])):
            source_id=f'{code}-Q{i+1:02}'
            if source.get('id',source.get('question_id'))!=source_id:raise ValueError('Structured question ID/order mismatch')
            if normalize(source.get('question',source.get('prompt')))!=normalize(q['prompt']):raise ValueError('Markdown/JSON question mismatch '+source_id)
            if [normalize(v) for v in choices(source)]!=[normalize(v) for v in q['options']]:raise ValueError('Markdown/JSON choices mismatch '+source_id)
            answer=source.get('correct_answer',key_map.get(source_id,{}).get('correct_answer'))
            if answer and answer!='ABCD'[q['correct_option']]:raise ValueError('Markdown/JSON answer mismatch '+source_id)
            if source.get('points',10)!=10:raise ValueError('Structured quiz points mismatch')
            explanation=source.get('explanation',key_map.get(source_id,{}).get('explanation'))
            if explanation and normalize(explanation)!=normalize(q['explanation']):notes.append(f'{source_id}: explanatory wording differs; full Markdown explanation retained.')
    if not variants:raise ValueError('No structured final assessment')
    # Check all core instructional strings, not just the first content block.
    if len(data['lessons'])!=5:raise ValueError('Structured lesson count mismatch')
    for source,lesson in zip(data['lessons'],payload['lessons']):
        if normalize(source['title'])!=normalize(lesson['title']):raise ValueError('Lesson title mismatch')
        body=normalize(' '.join(b['text'] for b in lesson['body']))
        content=source.get('content_sections',source.get('lesson_content',source.get('content',[])))
        required=[source['why_this_matters'],source['hardware_store_example'],source['what_to_say_or_do'],source['common_mistakes'],source['when_to_ask_for_help'],source['key_takeaways'],content]
        def strings(value):
            if isinstance(value,str):yield value
            elif isinstance(value,list):
                for v in value:yield from strings(v)
            elif isinstance(value,dict):
                for v in value.values():yield from strings(v)
        for value in strings(required):
            if normalize(value) not in body:raise ValueError('Missing/discrepant core lesson text '+source['id']+': '+value[:70])
        practice=source.get('unscored_practice',source.get('practice',source.get('optional_practice',{})))
        if isinstance(practice,dict):
            for name in ['question','explanation']:
                if practice.get(name) and normalize(practice[name]) not in body:
                    notes.append(f"{source['id']}: structured practice {name} differs; complete Markdown practice retained.")
    return list(dict.fromkeys(notes))


def build(code):
    folder=root/'courses'/code;source=folder/'source'
    md=next(source.glob('*complete_course*.md'));text=md.read_text()
    information=section(text,1)
    description=re.search(r'^(?:- )?\*\*(?:Short description|Description):\*\*\s*(.+)',information,re.M)
    if description:description=description.group(1).strip()
    else:
        first=next((line.strip() for line in information.splitlines() if line.strip()),'')
        if not first or first.startswith(('-', '|', '**')):raise ValueError('Missing description')
        description=first
    entry=entries[code]
    slug=code.lower()+'-'+re.sub(r'[^a-z0-9]+','-',entry['title'].lower()).strip('-')
    payload={'course':{'id':identifier(code+':1.0.0'),'slug':slug,'version':1,'title':entry['title'],
                       'description':description,'category':entry['academy'],'passing_percent':80},
             'lessons':parse_lessons(text,code),'questions':parse_assessment(text,code)}
    headings=[l['title'] for l in payload['lessons']]+[b['text'] for l in payload['lessons'] for b in l['body'] if b['type']=='heading']
    acronyms=sorted(set(re.findall(r'\b[A-Z][A-Z0-9-]{1,7}\b',' '.join(b['text'] for l in payload['lessons'] for b in l['body'])))-{'IMG','HTML','README',code.split('-')[0]})
    keywords=list(dict.fromkeys(headings+acronyms))[:100]
    payload['catalog']=metadata(code,keywords=keywords)
    notes=[];structured=list(source.glob('*.json'))
    if structured:notes=check_structured(json.loads(structured[0].read_text()),payload,text,code)
    else:notes.append('Markdown-only handoff; matching structured import generated here.')
    pattern=''.join('ABCD'[q['correct_option']] for q in payload['questions'])
    if len(set(pattern))<=2:notes.append('Final answer positions are repetitive ('+pattern+'); review distractors before publishing.')
    if code.startswith('HB-'):notes.append('Final prompts include the recommended action in the scenario; revise for stronger assessment before publishing.')
    if code.startswith(('HB-','HT-','PD-','LG-')):notes.append('Product-specific/manufacturer references and technical review are still pending in the supplied source.')
    notes.append('No media assets supplied; retain text-only draft or add reviewed, licensed instructional media later.')
    manifest={'course_code':code,'source_version':'1.0.0','database_revision':1,'course_uuid':payload['course']['id'],
              'source_files':{p.name:hashlib.sha256(p.read_bytes()).hexdigest() for p in sorted(source.iterdir()) if p.is_file()},
              'source_content_edits':[],'published':False,'review_notes':list(dict.fromkeys(notes))}
    (folder/'prepared-import.json').write_text(json.dumps(payload,ensure_ascii=False,indent=2)+'\n')
    (folder/'import-manifest.json').write_text(json.dumps(manifest,ensure_ascii=False,indent=2)+'\n')
    serialized=json.dumps(payload,ensure_ascii=False)
    if '$coursedata$' in serialized or '$courseimport$' in serialized:raise ValueError('Unsafe SQL delimiter in source')
    sql=template.replace('COURSE_CODE',code).replace('SOURCE_VERSION','1.0.0').replace('COURSE_ID',payload['course']['id']).replace('PAYLOAD',serialized)
    (root/f'supabase/course-imports/{code}_IMPORT_DRAFT.sql').write_text(sql)
    return payload,manifest,sql


if __name__=='__main__':
    documents=[];ids=[];manifests=[];errors=[]
    for code in entries:
        try:
            payload,manifest,sql=build(code)
            documents.append('do '+sql.split('begin;\ndo ',1)[1].split('\ncommit;\n',1)[0]);ids.append(payload['course']['id']);manifests.append(manifest)
            print(f'{code}: five lessons, five questions; unpublished; {len(manifest["review_notes"])} review notes')
        except Exception as error:errors.append(code+': '+str(error))
    if errors:raise SystemExit('\n'.join(errors))
    assert len(ids)==21 and len(set(ids))==21
    sql='-- Remaining 21 approved launch courses: unpublished drafts. Requires existing account/training schema.\n-- Does not publish, release, assign, reset progress, or change existing course content.\nbegin;\n'+'\n'.join(documents)+'\ncommit;\n'
    sql+="select slug,title,published,(select count(*) from public.training_lessons where course_id=c.id) as lessons,(select count(*) from public.training_questions where course_id=c.id) as quiz_questions from public.training_courses c where id in ("+','.join("'"+value+"'" for value in ids)+') order by category,slug;\n'
    (root/'supabase/course-imports/REMAINING_21_IMPORT_DRAFTS.sql').write_text(sql)
    (root/'courses/remaining-launch-review.json').write_text(json.dumps(manifests,ensure_ascii=False,indent=2)+'\n')
    print('Built one transactional 21-course batch; no hosted writes.')
