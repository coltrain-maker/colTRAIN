"""Classification for the owner-supplied launch courses; no proposed courses."""
from pathlib import Path
import json
catalog = {
 'RF-101': {'topics':['Onboarding','Teamwork','Customer service'],'keywords':['first day','independent retail','acknowledge','ask','assist','close']},
 'RF-102': {'topics':['Retail vocabulary','Inventory','Product knowledge'],'keywords':['SKU','UPC','stock keeping unit','barcode','nominal size','fasteners','trimmer line']},
 'RF-103': {'topics':['Safety','Equipment','Emergency response'],'keywords':['hazards','lifting','spills','near misses','evacuation','incident reporting']},
 'RF-104': {'topics':['Store operations','Departments','Customer service'],'keywords':['store layout','receiving','backstock','store services','customer handoff']},
}


def metadata(code):
    approved=json.loads((Path(__file__).resolve().parent.parent/'courses/approved-launch-catalog.json').read_text())
    paths=[path['name'] for path in approved['learning_paths'] if code in path.get('core_courses',[])+path.get('select_from',[])]
    return {'course_code':code,'skill_level':'foundations',**catalog[code],'learning_paths':paths}
