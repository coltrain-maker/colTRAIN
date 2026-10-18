"""Classification for the owner-supplied launch courses; no proposed courses."""
from pathlib import Path
import json
catalog = {
 'RF-101': {'topics':['Onboarding','Teamwork','Customer service'],'keywords':['first day','independent retail','acknowledge','ask','assist','close']},
 'RF-102': {'topics':['Retail vocabulary','Inventory','Product knowledge'],'keywords':['SKU','UPC','stock keeping unit','barcode','nominal size','fasteners','trimmer line']},
 'RF-103': {'topics':['Safety','Equipment','Emergency response'],'keywords':['hazards','lifting','spills','near misses','evacuation','incident reporting']},
 'RF-104': {'topics':['Store operations','Departments','Customer service'],'keywords':['store layout','receiving','backstock','store services','customer handoff']},
}


def metadata(code,topics=None,keywords=None):
    approved=json.loads((Path(__file__).resolve().parent.parent/'courses/approved-launch-catalog.json').read_text())
    paths=[path['name'] for path in approved['learning_paths'] if code in path.get('core_courses',[])+path.get('select_from',[])]
    entry=next(c for academy in approved['academies'] for c in academy['courses'] if c['code']==code)
    defaults=catalog.get(code,{'topics':[entry['title'].replace(' Fundamentals','')],'keywords':[]})
    return {'course_code':code,'skill_level':'foundations',
            'topics':topics if topics is not None else defaults['topics'],
            'keywords':keywords if keywords is not None else defaults['keywords'],
            'learning_paths':paths}
