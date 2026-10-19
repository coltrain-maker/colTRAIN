"""Validate the approved Daily source handoff; never publish it or alter text."""
from pathlib import Path
from collections import Counter
import hashlib
import json

root = Path(__file__).resolve().parent.parent
pilot = root / 'courses/daily/pilot-v1.0.0'
source = pilot / 'source'
plan = json.loads((root / 'courses/academy-plan.json').read_text())
academies = {a['name'] for a in plan['academies']}
manifest = json.loads((source / 'MANIFEST.json').read_text())
aggregate = json.loads((source / 'ALL_MODULES.json').read_text())
assert manifest['package_version'] == aggregate['package_version'] == '1.0.0'
assert manifest['module_count'] == len(manifest['modules']) == len(aggregate['modules']) == 10
ids, question_ids, counts, modules = set(), set(), Counter(), []
for item in manifest['modules']:
    code = item['module_id']
    assert code not in ids
    ids.add(code)
    json_path = source / item['json_file']
    md_path = source / item['markdown_file']
    assert json_path.resolve().is_relative_to(source.resolve())
    assert md_path.resolve().is_relative_to(source.resolve())
    data = json.loads(json_path.read_text())
    meta = data['metadata']
    md = md_path.read_text()
    assert data['complete_markdown'] == md, code + ': Markdown differs'
    assert sum(d == data for d in aggregate['modules']) == 1, code + ': aggregate differs'
    assert md in (source / 'ALL_MODULES.md').read_text(), code + ': combined Markdown differs'
    for field, key in [('Stable module ID','module_id'),('Title','title'),('Version','version'),('Academy','academy'),('Skill level','level')]:
        assert meta[field] == item[key], (code, field)
    assert meta['Academy'] in academies
    assert meta['Skill level'] == 'Foundations'
    assert data['approval']['content_approved'] is True
    assert data['approval']['publication_status'] == 'not published'
    assert data['actual_media_assets'] == []
    assert len(data['employee_facing_sections']) == 6
    for section in data['employee_facing_sections'] + data['reviewer_sections']:
        assert section['content_markdown'] in md, (code, section['heading'])
    questions = data['questions']
    assert len(questions) == len(data['answer_key']) == 1
    for q in questions:
        assert q['id'] not in question_ids
        question_ids.add(q['id'])
        assert q['id'].startswith(code + '-Q')
        assert set(q['options']) == set('ABCD')
        key = next(k for k in data['answer_key'] if k['question_id'] == q['id'])
        assert key['correct_answer'] in q['options']
        assert key['explanation'] and key['teaching_reference']
        check = data['employee_facing_sections'][4]['content_markdown']
        assert q['id'] in check and q['wording'] in check
        for letter, answer in q['options'].items():
            assert f'{letter}. {answer}' in check
        assert key['explanation'] not in '\n'.join(s['content_markdown'] for s in data['employee_facing_sections'])
    counts[meta['Academy']] += 1
    modules.append({'module_id': code, 'title': meta['Title'], 'academy': meta['Academy'],
                    'skill_level': 'foundations', 'source_version': meta['Version'],
                    'text_approved': True, 'published': False,
                    'media_asset_count': 0, 'media_required_for_text_pilot': False,
                    'markdown_sha256': hashlib.sha256(md_path.read_bytes()).hexdigest(),
                    'json_sha256': hashlib.sha256(json_path.read_bytes()).hexdigest()})
assert ids == {f'CD-{i:04}' for i in range(1,11)}
assert set(counts) == academies and set(counts.values()) == {1}
# Reproducible local handoff, never part of the public hosting allowlist.
report = {'package_version':'1.0.0', 'content_approval_source':'User confirmed text reviewed and approved in chat on 2026-10-19',
          'integration_status':'Daily database, automatic shared sequence and draft import prepared; hosted application and Daily UI pending',
          'approved_modules':10, 'remaining_planned_modules':250,
          'counts_by_academy':dict(counts), 'modules':modules}
(pilot / 'handoff-manifest.json').write_text(json.dumps(report, indent=2, ensure_ascii=False)+'\n')
print('Passed 10 Daily modules: exact Markdown/JSON/aggregate fidelity, metadata/versions, 10 academy coverage, question/options/keys, no supplied media, approved unpublished state. Wrote handoff-manifest.json.')
