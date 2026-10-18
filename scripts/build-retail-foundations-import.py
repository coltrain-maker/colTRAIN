"""Convert the supplied RF-102–104 Markdown into unpublished course data.

No hosted access. Unsupported or incomplete source structure fails the build;
editorial notes are archived verbatim rather than interpreted as instructions.
"""
from pathlib import Path
import json
import hashlib
import re
import uuid

root = Path(__file__).resolve().parent.parent
namespace = uuid.UUID('16574c65-11aa-47dd-a055-e8ef7ca9498a')
titles = {'RF-102': 'Retail Terms & Hardware Vocabulary',
          'RF-103': 'Store Safety Fundamentals',
          'RF-104': 'Understanding the Hardware Store'}
slugs = {'RF-102': 'retail-terms-and-hardware-vocabulary',
         'RF-103': 'store-safety-fundamentals',
         'RF-104': 'understanding-the-hardware-store'}
plain = lambda text: text.replace('**', '').strip()
identifier = lambda text: str(uuid.uuid5(namespace, text))
template = (root / 'scripts/course-import-template.sql').read_text()


def sections(text, heading):
    match = re.search(rf'^## {heading}\..*?\n(.*?)(?=^## \d+\.|\Z)', text, re.M | re.S)
    if not match:
        raise ValueError(f'Missing section {heading}')
    return match.group(1)


def blocks(text):
    result = []
    for line in text.splitlines():
        line = line.strip()
        if not line:
            continue
        if line.startswith('#### '):
            kind, value = 'heading', line[5:]
        elif re.fullmatch(r'\*\*[^*]+\*\*', line):
            kind, value = 'heading', line
        elif line.startswith('- '):
            kind, value = 'bullet', line[2:]
        else:
            kind, value = 'paragraph', line
        result.append({'type': kind, 'text': plain(value)})
    return result


def read_course(code):
    folder = root / 'courses' / code
    source = (folder / f'source/{code}_complete_course_v1.0.0.md').read_text()
    assert '**Version:** 1.0.0' in source
    metadata = sections(source, 1)
    description = re.search(r'^\*\*(?:Short description|Description):\*\*\s*(.+)', metadata, re.M).group(1).strip()
    category = re.search(r'^\*\*Category:\*\*\s*(.+)', metadata, re.M).group(1).strip()
    assert category == 'Retail Foundations'
    lessons = []
    for segment in re.split(r'^### ', sections(source, 4), flags=re.M)[1:]:
        heading, rest = segment.split('\n', 1)
        lesson_match = re.search(rf'{code}-L(\d{{2}})', heading)
        if not lesson_match:
            raise ValueError(f'Unknown lesson heading: {heading}')
        position = int(lesson_match.group(1))
        source_id = f'{code}-L{position:02}'
        if heading.startswith('Lesson '):
            title = re.sub(r'\s*\(' + re.escape(source_id) + r'\)\s*$', '', heading.split(' — ', 1)[1])
        else:
            title = heading[len(source_id):].lstrip(': —').strip()
        rest = rest[rest.index('#### Why this matters'):]
        rest = re.sub(r'^#### Supporting materials\n.*?(?=^#### |\Z)', '', rest, flags=re.M | re.S)
        rest = re.sub(r'^#### Optional practice\n.*?(?=^#### |\Z)', '', rest, flags=re.M | re.S)
        body = blocks(rest)
        texts = [b['text'] for b in body]
        for needed in ['Why this matters', 'Lesson content', 'Hardware-store example', 'What to say or do', 'Common mistakes', 'When to ask for help', 'Key takeaways']:
            if needed not in texts:
                raise ValueError(f'Missing {needed} in {source_id}')
        practice = re.search(r'^#### Unscored lesson practice.*?\n(.*)', rest, re.M | re.S).group(1)
        if not re.search(r'\*\*Answer:\*\*\s*\S', practice) or not re.search(r'\*\*Explanation:\*\*\s*\S', practice):
            raise ValueError(f'Missing practice feedback in {source_id}')
        assert '[Needed]' not in '\n'.join(texts)
        lessons.append({'id': identifier(source_id + ':1.0.0'), 'position': position, 'title': title, 'body': body})
    assessment = sections(source, 5)
    key_start = re.search(r'^### [^\n]*(?:answer key|Answer key)[^\n]*\n', assessment, re.M)
    if not key_start:
        raise ValueError(f'No separated final answer key in {code}')
    facing, key = assessment[:key_start.start()], assessment[key_start.end():]
    q_heading = rf'^(?:### |\*\*)({code}-Q\d{{2}})(?:\*\*)?([^\n]*)\n'
    matches = list(re.finditer(q_heading, facing, re.M))
    key_pattern = rf'^(?:- )?\*\*({code}-Q\d{{2}})([^\n]*?)(?:\*\*)([^\n]*)(?:\n|$)'
    key_matches = list(re.finditer(key_pattern, key, re.M))
    keys = {}
    for i, m in enumerate(key_matches):
        chunk = key[m.start():key_matches[i+1].start() if i+1 < len(key_matches) else len(key)]
        clean = plain(chunk)
        correct = re.search(r'Correct answer:\s*([A-D])\b', clean)
        if not correct:
            correct = re.search(re.escape(m.group(1)) + r'\s*[:—]\s*([A-D])\b', clean)
        explanation = re.search(r'^-?\s*Explanation:\s*(.+)', clean, re.M)
        if explanation:
            explanation = explanation.group(1).strip()
        else:
            inline_explanation = re.search(r'· 10 points\. (.*?) Review:', clean)
            explanation = inline_explanation.group(1) if inline_explanation else None
        if not correct or not explanation:
            raise ValueError(f'Incomplete final key {m.group(1)}')
        keys[m.group(1)] = (correct.group(1), explanation)
    questions = []
    for i, m in enumerate(matches):
        source_id = m.group(1)
        chunk = facing[m.end():matches[i+1].start() if i+1 < len(matches) else len(facing)]
        lines = [plain(line) for line in chunk.splitlines() if line.strip()]
        options, prompt = [], []
        inline = m.group(2).strip().lstrip('—').strip()
        if inline:
            prompt.append(plain(inline))
        for line in lines:
            choice = re.match(r'^-?\s*([A-D])\.\s+(.+)', line)
            if choice:
                options.append((choice.group(1), choice.group(2)))
            elif line.startswith(('Objective:', 'Objective assessed:', 'Related lesson:', 'Points:')):
                continue
            elif not options:
                prompt.append(line.removeprefix('Question:').strip())
            else:
                raise ValueError(f'Unrecognized text after choices: {source_id}: {line}')
        if [o[0] for o in options] != list('ABCD') or len(prompt) != 1:
            raise ValueError(f'Incomplete question {source_id}: {prompt}, {options}')
        correct, explanation = keys[source_id]
        questions.append({'id': identifier(source_id + ':1.0.0'), 'position': i+1, 'prompt': prompt[0],
                          'options': [o[1] for o in options], 'correct_option': 'ABCD'.index(correct), 'explanation': explanation})
    assert len(lessons) == len(questions) == len(keys) == 5
    assert [l['position'] for l in lessons] == list(range(1, 6))
    assert [m.group(1) for m in matches] == [f'{code}-Q{i:02}' for i in range(1, 6)]
    assert set(keys) == {m.group(1) for m in matches}
    payload = {'course': {'id': identifier(code + ':1.0.0'), 'slug': code.lower() + '-' + slugs[code],
                          'version': 1, 'title': titles[code], 'description': description,
                          'category': category, 'passing_percent': 80}, 'lessons': lessons, 'questions': questions}
    (folder / 'prepared-import.json').write_text(json.dumps(payload, ensure_ascii=False, indent=2) + '\n')
    manifest = {'course_code': code, 'source_version': '1.0.0', 'database_revision': 1,
                'course_uuid': payload['course']['id'],
                'source_file': f'source/{code}_complete_course_v1.0.0.md',
                'source_sha256': hashlib.sha256(source.encode()).hexdigest(),
                'source_content_edits': [], 'published': False,
                'delivery': 'Text-only lessons, readable unscored practice, private-key final quiz',
                'not_imported_as_features': ['Empty media placeholders', 'Enforced prerequisites', 'Learning paths', 'Per-course completion messages', 'Estimated duration display'],
                'review_pending': ['Owner editorial approval', 'Store-specific terminology/procedures', 'Employee timing test']}
    if code == 'RF-103':
        manifest['review_pending'].append('Emergency response, equipment authorization, and incident procedures; no external safety references supplied')
    (folder / 'import-manifest.json').write_text(json.dumps(manifest, ensure_ascii=False, indent=2) + '\n')
    return payload


def render(code, payload):
    serialized = json.dumps(payload, ensure_ascii=False)
    assert '$coursedata$' not in serialized and '$courseimport$' not in serialized
    return template.replace('COURSE_CODE', code).replace('SOURCE_VERSION', '1.0.0').replace('COURSE_ID', payload['course']['id']).replace('PAYLOAD', serialized)


if __name__ == '__main__':
    documents = []
    course_ids = []
    for code in titles:
        payload = read_course(code)
        document = render(code, payload)
        (root / f'supabase/course-imports/{code}_IMPORT_DRAFT.sql').write_text(document)
        # One outer transaction ensures all three imports succeed or all roll back.
        core = document.split('begin;\ndo ', 1)[1].split('\ncommit;\n', 1)[0]
        documents.append('do ' + core)
        course_ids.append(payload['course']['id'])
        print(f"Prepared {code}: {payload['course']['title']}; five lessons/five questions; unpublished")
    combined = '-- RF-102, RF-103, RF-104: unpublished drafts only. Run in SQL Editor as postgres.\n-- No schema changes, releases, assignments, or edits to existing courses.\nbegin;\n'
    combined += '\n'.join(documents) + '\ncommit;\n'
    combined += "select slug,title,published,(select count(*) from public.training_lessons where course_id=c.id) as lessons,(select count(*) from public.training_questions where course_id=c.id) as quiz_questions from public.training_courses c where id in (" + ','.join("'"+value+"'" for value in course_ids) + ') order by slug;\n'
    (root / 'supabase/course-imports/RF-102_103_104_IMPORT_DRAFTS.sql').write_text(combined)
