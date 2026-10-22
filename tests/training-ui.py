"""Exercise the browser against real local SQL/RLS; Auth HTTP responses are mocked.
No hosted database access, real credentials, or outbound emails are used.
"""
from pathlib import Path
from email.parser import BytesParser
from email.policy import default as mail_policy
import base64, json, os, re, subprocess, time, uuid
from urllib.parse import urlparse, parse_qs
from playwright.sync_api import sync_playwright, expect
root=Path(__file__).resolve().parent.parent
name='coltrain-training-ui-'+uuid.uuid4().hex[:8]
image='postgres:17-alpine@sha256:b0f9560a2de083e2cc7382e75f808c7381a32852a7ec49117deedb300e552b24'
subprocess.run(['node','scripts/build-accounts.mjs'],cwd=root,check=True,env={**os.environ,'SUPABASE_PUBLISHABLE_KEY':'sb_publishable_local_test_only'})
html=(root/'accounts/index.html').read_text()
def sql(statement):
 r=subprocess.run(['docker','exec','-i',name,'psql','-X','-qAt','-v','ON_ERROR_STOP=1','-U','postgres'],input=statement,text=True,capture_output=True)
 if r.returncode:raise RuntimeError(r.stderr)
 return r.stdout.strip()
def quote(value):return "'"+str(value).replace("'","''")+"'"
def arg(value):
 if value is None:return 'null'
 if isinstance(value,bool):return 'true' if value else 'false'
 if isinstance(value,list):
  if value and isinstance(value[0],dict):return quote(json.dumps(value))+'::jsonb'
  return 'array['+','.join(quote(v) for v in value)+']::uuid[]'
 if isinstance(value,dict):return quote(json.dumps(value))+'::jsonb'
 return quote(value)
def query_as(uid,statement):return sql('begin;set local role authenticated;set local request.jwt.claim.sub='+quote(uid)+';'+statement+';commit;')
encode=lambda value:base64.urlsafe_b64encode(json.dumps(value).encode()).decode().rstrip('=')
people={'admin@example.test':'00000000-0000-0000-0000-000000000001','manager.a@example.test':'00000000-0000-0000-0000-000000000002','employee.a@example.test':'00000000-0000-0000-0000-000000000004'}
def person(uid):return {'id':uid,'email':next(email for email,value in people.items() if value==uid),'aud':'authenticated','role':'authenticated','user_metadata':{},'app_metadata':{'provider':'email'}}
def token(uid):return encode({'alg':'HS256','typ':'JWT'})+'.'+encode({'sub':uid,'role':'authenticated','exp':int(time.time())+3600})+'.local-test'
storage_bytes={}
lost_upload_response=False
def handle(route):
 global lost_upload_response
 url=route.request.url
 asset_path=urlparse(url).path
 if url.startswith('https://training.example/accounts/') and asset_path in ['/accounts/manifest.webmanifest','/accounts/icons/coltrain.svg','/accounts/icons/apple-touch-icon.png','/accounts/icons/icon-192.png','/accounts/icons/icon-512.png','/accounts/icons/icon-maskable-512.png']:
     mime='application/manifest+json' if asset_path.endswith('.webmanifest') else 'image/svg+xml' if asset_path.endswith('.svg') else 'image/png'
     return route.fulfill(content_type=mime,body=(root/asset_path.lstrip('/')).read_bytes())
 if url.startswith('https://training.example/accounts/') and urlparse(url).path=='/accounts/':return route.fulfill(content_type='text/html',body=html)
 assert url.startswith('https://flhdeftduysnjvqnhhee.supabase.co/'),url
 parsed=urlparse(url);path=parsed.path;params=parse_qs(parsed.query)
 header=route.request.headers.get('authorization','').removeprefix('Bearer ')
 uid=json.loads(base64.urlsafe_b64decode(header.split('.')[1]+'==='))['sub'] if header.count('.')==2 else None
 try:
  if path=='/auth/v1/token':
   uid=people[route.request.post_data_json['email']];result={'access_token':token(uid),'refresh_token':'local-refresh','expires_in':3600,'token_type':'bearer','user':person(uid)}
  elif path=='/auth/v1/user':result=person(uid)
  elif path=='/auth/v1/logout':result={}
  elif path=='/functions/v1/team-support-email':result={'delivery_status':'processed','processed':0} # Mock email transport; private messages use real SQL.
  elif path=='/functions/v1/employee-login':result={'delivery_status':'processed','processed':0} # Email transport stub; first-login RPC remains real SQL.
  elif path.startswith('/storage/v1/object/'):
   storage_path=path.removeprefix('/storage/v1/object/').removeprefix('authenticated/')
   bucket,_,object_name=storage_path.partition('/')
   assert bucket in ('team-media','profile-photos')
   storage_key=bucket+'/'+object_name
   if route.request.method=='POST':
    if storage_key in storage_bytes:
     return route.fulfill(status=409,content_type='application/json',body=json.dumps({'statusCode':409,'error':'Duplicate','message':'The resource already exists'}))
    payload=route.request.post_data_buffer
    content_type=route.request.headers.get('content-type','')
    if content_type.startswith('multipart/form-data'):
     message=BytesParser(policy=mail_policy).parsebytes(('Content-Type: '+content_type+'\r\nMIME-Version: 1.0\r\n\r\n').encode()+payload)
     image_part=next(part for part in message.iter_parts() if part.get_content_maintype()=='image')
     payload=image_part.get_payload(decode=True);content_type=image_part.get_content_type()
    assert len(payload)<=1048576 and content_type=='image/jpeg'
    object_id=query_as(uid,"insert into storage.objects(bucket_id,name) values("+quote(bucket)+","+quote(object_name)+") returning id")
    storage_bytes[storage_key]=payload
    if lost_upload_response:
     lost_upload_response=False
     return route.fulfill(status=500,content_type='application/json',body=json.dumps({'statusCode':500,'error':'Test failure','message':'Test response lost after storage commit'}))
    result={'Key':storage_key,'Id':object_id}
   elif route.request.method=='GET':
    allowed=query_as(uid,"select count(*) from storage.objects where bucket_id="+quote(bucket)+" and name="+quote(object_name))
    if allowed!='1':return route.fulfill(status=403,content_type='application/json',body=json.dumps({'statusCode':403,'error':'Forbidden','message':'Photo not available'}))
    return route.fulfill(status=200,content_type='image/jpeg',body=storage_bytes[storage_key])
   elif route.request.method=='DELETE':
    removed=[]
    for name_to_remove in route.request.post_data_json['prefixes']:
     deleted=query_as(uid,'delete from storage.objects where bucket_id='+quote(bucket)+' and name='+quote(name_to_remove)+' returning name')
     if deleted:
      storage_bytes.pop(bucket+'/'+name_to_remove,None);removed.append({'name':name_to_remove})
    result=removed
   else:raise AssertionError('Unexpected storage method')
  elif path.startswith('/rest/v1/rpc/'):
   function=path.rsplit('/',1)[1];assert re.fullmatch('[a-z_]+',function)
   arguments=','.join('"'+key+'"=>'+arg(value) for key,value in route.request.post_data_json.items())
   result=json.loads(query_as(uid,'select to_jsonb(public."'+function+'"('+arguments+'))'))
  elif path.startswith('/rest/v1/'):
   table=path.rsplit('/',1)[1];assert re.fullmatch('[a-z_]+',table)
   columns=params.get('select',['*'])[0];assert columns=='*' or all(re.fullmatch('[a-z_]+',col) for col in columns.split(','))
   conditions=[]
   for key,values in params.items():
    if key in ('select','order'):continue
    assert re.fullmatch('[a-z_]+',key)
    for value in values:
     assert value.startswith('eq.')
     conditions.append('"'+key+'"='+quote(value[3:]))
   where=' where '+' and '.join(conditions) if conditions else ''
   order=''
   if 'order' in params:
    column,sort=params['order'][0].split('.')[:2];assert re.fullmatch('[a-z_]+',column) and sort in ('asc','desc')
    order=' order by "'+column+'" '+sort
   result=json.loads(query_as(uid,"select coalesce(jsonb_agg(to_jsonb(rows)),'[]') from (select "+columns+' from public."'+table+'"'+where+order+') rows'))
  else:raise AssertionError('Unexpected endpoint '+path)
  route.fulfill(status=200,content_type='application/json',headers={'access-control-allow-origin':'*'},body=json.dumps(result))
 except RuntimeError as error:
  route.fulfill(status=400,content_type='application/json',headers={'access-control-allow-origin':'*'},body=json.dumps({'code':'P0001','message':str(error)}))

subprocess.run(['docker','run','--rm','-d','--name',name,'--network','none','-e','POSTGRES_HOST_AUTH_METHOD=trust',image],check=True,capture_output=True)
try:
 for _ in range(60):
  if subprocess.run(['docker','exec',name,'pg_isready','-h','127.0.0.1','-U','postgres'],capture_output=True).returncode==0:break
  time.sleep(.25)
 sql((root/'tests/supabase-auth-fixture.sql').read_text())
 for migration in sorted((root/'supabase/migrations').glob('*.sql')):sql(migration.read_text())
 sql("""insert into auth.users(id,email,email_confirmed_at) values
 ('00000000-0000-0000-0000-000000000001','admin@example.test',now()),
 ('00000000-0000-0000-0000-000000000002','manager.a@example.test',now()),
 ('00000000-0000-0000-0000-000000000004','employee.a@example.test',now());
 insert into public.platform_admins(user_id) values('00000000-0000-0000-0000-000000000001');
 insert into public.profiles(user_id,full_name) values('00000000-0000-0000-0000-000000000001','Pilot Admin'),('00000000-0000-0000-0000-000000000002','Pilot Manager'),('00000000-0000-0000-0000-000000000004','Pilot Employee');
 insert into public.organizations(id,name) values('10000000-0000-0000-0000-000000000099','Coltrain Hardware');
 insert into public.organization_memberships(id,organization_id,user_id,email,role) values
 ('20000000-0000-0000-0000-000000000002','10000000-0000-0000-0000-000000000099','00000000-0000-0000-0000-000000000002','manager.a@example.test','manager'),
 ('20000000-0000-0000-0000-000000000004','10000000-0000-0000-0000-000000000099','00000000-0000-0000-0000-000000000004','employee.a@example.test','employee');
 insert into public.seats(organization_id,membership_id) select organization_id,id from public.organization_memberships;""")
 with sync_playwright() as p:
  browser=p.chromium.launch(executable_path='/usr/bin/chromium',args=['--no-sandbox'])
  page=browser.new_page(service_workers='block',viewport={'width':1280,'height':1000});errors=[]
  page.on('pageerror',lambda error:errors.append(str(error)))
  page.route('**/*',handle)
  page.goto('https://training.example/accounts/')
  def login(email):
   page.locator('#auth-form input[name=email]').fill(email)
   page.locator('#auth-form input[name=password]').fill('Local test password')
   page.locator('#auth-form button[type=submit]').click()
   expect(page.locator('.page-heading h1')).to_be_visible()
   expect(page.locator('header .account-identity')).to_contain_text('Coltrain Hardware')
   expect(page.locator('header .account-identity')).to_contain_text('Signed in as Pilot')
   expect(page.locator('header .brand small')).to_have_text('Knowledge is our power tool')
   page.get_by_role('button',name='Open menu').click()
   page.locator('.training-drawer h2').click()
   expect(page.locator('.training-drawer')).to_be_visible()
   page.locator('.training-menu-shade').click(position={'x':5,'y':200})
   expect(page.locator('.training-drawer')).to_have_count(0)
   page.get_by_role('button',name='Open menu').click()
   page.keyboard.press('Escape')
   expect(page.locator('.training-drawer')).to_have_count(0)
   assert page.get_by_role('button',name='Open training',exact=True).count()==0
  def navigate(label):
   page.get_by_role('button',name='Open menu').click()
   page.locator('.training-drawer').get_by_role('button',name=label,exact=True).click()
  def check_install_entry():
   page.get_by_role('button',name='Open menu').click()
   page.locator('.training-drawer').get_by_role('button',name='Add to home screen',exact=True).click()
   expect(page.get_by_role('heading',name='Add colTRAIN to your home screen',exact=True)).to_be_visible()
   page.get_by_role('button',name='Close installation instructions',exact=True).click()
   page.locator('.training-drawer').get_by_role('button',name='Close',exact=True).click()
  def signout():
   page.get_by_role('button',name='Open menu').click()
   page.locator('.training-drawer').get_by_role('button',name='Sign out and switch accounts',exact=True).click()
   expect(page.get_by_role('heading',name='Welcome to colTRAIN')).to_be_visible()
  def check_library_filters(is_admin=False):
   # Temporary local fixtures are removed before normal assignment checks.
   sql("""insert into public.training_courses(id,slug,title,description,category,published) values
    ('c9000000-0000-4000-8000-000000000001','pt-201','Project Consultation','Choose a suitable coating.','Paint & Decorating',true),
    ('c9000000-0000-4000-8000-000000000002','pt-301','Failure Analysis','Analyze paint problems.','Paint & Decorating',true),
    ('c9000000-0000-4000-8000-000000000003','hidden-library','Hidden Library Course','Not released.','Private Academy',true);
    insert into public.training_course_catalog(course_id,course_code,skill_level,topics,keywords) values
    ('c9000000-0000-4000-8000-000000000001','PT-201','application',array['Paint'],array['rollers','adhesion']),
    ('c9000000-0000-4000-8000-000000000002','PT-301','expertise',array['Paint'],array['adhesion']),
    ('c9000000-0000-4000-8000-000000000003','HIDDEN','expertise',array['Secret topic'],array['secret']);
    update public.training_course_catalog set learning_paths=array['Sales Floor Associate'] where course_code='PT-201';
    update public.training_course_catalog set learning_paths=array['Private path'] where course_code='HIDDEN';
    insert into public.training_course_releases(organization_id,course_id,released_by)
    select '10000000-0000-0000-0000-000000000099',id,'00000000-0000-0000-0000-000000000001'
    from public.training_courses where slug in ('pt-201','pt-301');""")
   navigate('Course library')
   expect(page.locator('.course-card')).to_have_count(4 if is_admin else 3)
   if not is_admin:
    assert 'Secret topic' not in page.locator('#training-search-form select[name=academy]').inner_text()
    assert 'Private Academy' not in page.locator('#training-search-form select[name=academy]').inner_text()
    assert 'Private path' not in page.get_by_label('Learning path',exact=True).inner_text()
   page.get_by_label('Skill level',exact=True).select_option('application')
   page.get_by_label('Academy',exact=True).select_option('Paint & Decorating')
   page.get_by_label('Subtopic',exact=True).select_option('Paint')
   page.get_by_label('Learning path',exact=True).select_option('Sales Floor Associate')
   page.get_by_label('Search courses',exact=True).fill('  ROLLERS coating  ')
   page.locator('#training-search-form').get_by_role('button',name='Search',exact=True).click()
   expect(page.locator('.course-card h2')).to_have_text('Project Consultation')
   expect(page.locator('.library-result-count')).to_have_text('1 course matches your search')
   expect(page.locator('.course-card')).to_contain_text('Level 2 — Application')
   navigate('Home' if not is_admin else 'Dashboard')
   navigate('Course library')
   expect(page.get_by_label('Skill level',exact=True)).to_have_value('application')
   expect(page.get_by_label('Learning path',exact=True)).to_have_value('Sales Floor Associate')
   expect(page.locator('.course-card h2')).to_have_text('Project Consultation')
   page.get_by_label('Skill level',exact=True).select_option('expertise')
   page.get_by_label('Learning path',exact=True).select_option('')
   page.get_by_label('Search courses',exact=True).fill('adhesion')
   page.locator('#training-search-form').get_by_role('button',name='Search',exact=True).click()
   expect(page.locator('.course-card h2')).to_have_text('Failure Analysis')
   page.get_by_label('Search courses',exact=True).fill('no such course')
   page.locator('#training-search-form').get_by_role('button',name='Search',exact=True).click()
   expect(page.get_by_role('heading',name='No matching courses')).to_be_visible()
   expect(page.get_by_label('Search courses',exact=True)).to_have_value('no such course')
   page.get_by_role('button',name='Clear filters',exact=True).click()
   expect(page.locator('.course-card')).to_have_count(4 if is_admin else 3)
   page.get_by_label('Search courses',exact=True).fill('pt-201')
   page.locator('#training-search-form').get_by_role('button',name='Search',exact=True).click()
   expect(page.locator('.course-card h2')).to_have_text('Project Consultation')
   page.set_viewport_size({'width':390,'height':844})
   assert page.locator('body').evaluate('element=>element.scrollWidth<=innerWidth')
   page.screenshot(path='/tmp/coltrain-library-mobile.png',full_page=True)
   page.set_viewport_size({'width':1280,'height':1000})
   page.get_by_role('button',name='Clear filters',exact=True).click()
   page.get_by_label('Academy',exact=True).select_option('Paint & Decorating')
   page.get_by_label('Subtopic',exact=True).select_option('Paint')
   page.get_by_label('Course',exact=True).select_option('c9000000-0000-4000-8000-000000000001')
   page.locator('#training-search-form').get_by_role('button',name='Search',exact=True).click()
   expect(page.locator('.course-card h2')).to_have_text('Project Consultation')
   page.get_by_label('Academy',exact=True).select_option('Customer Service & Retail Readiness')
   expect(page.get_by_label('Subtopic',exact=True)).to_have_value('')
   expect(page.get_by_label('Course',exact=True)).to_have_value('')
   if is_admin:
    navigate('Assign training')
    page.locator('#training-assign-form input[name=all]').check()
    deadline=page.locator('#training-assign-form input[name=deadline]').input_value()
    assert deadline==''
    assert page.locator('#training-assign-form input[name=deadline]').get_attribute('required') is None
    page.get_by_label('Academy',exact=True).select_option('Paint & Decorating')
    page.get_by_label('Subtopic',exact=True).select_option('Paint')
    page.get_by_label('Course',exact=True).select_option('c9000000-0000-4000-8000-000000000001')
    expect(page.locator('#training-assign-form input[name=all]')).to_be_checked()
    expect(page.locator('#training-assign-form input[name=deadline]')).to_have_value(deadline)
    navigate('Competitions')
    page.get_by_role('button',name='Start competition',exact=True).click()
    page.locator('#training-competition-form input[name=name]').fill('Keep this competition name')
    page.locator('#training-competition-form input[name=reward]').fill('Team lunch')
    page.get_by_label('Academy',exact=True).select_option('Paint & Decorating')
    page.get_by_label('Subtopic',exact=True).select_option('Paint')
    page.get_by_label('Required course',exact=True).select_option('c9000000-0000-4000-8000-000000000002')
    expect(page.locator('#training-competition-form input[name=name]')).to_have_value('Keep this competition name')
    expect(page.locator('#training-competition-form input[name=reward]')).to_have_value('Team lunch')
   navigate('Course library')
   page.get_by_role('button',name='Clear filters',exact=True).click()
   sql("""delete from public.training_course_releases where course_id::text like 'c9000000-%';
    delete from public.training_course_catalog where course_id::text like 'c9000000-%';
    delete from public.training_courses where id::text like 'c9000000-%';""")
   navigate('Course library')
   expect(page.locator('.course-card')).to_have_count(1)
  def check_full_catalog_cards():
   for filename in ['RF-101_IMPORT_DRAFT.sql','RF-102_103_104_IMPORT_DRAFTS.sql','REMAINING_21_IMPORT_DRAFTS.sql']:
    sql((root/'supabase/course-imports'/filename).read_text())
   navigate('Course library')
   expect(page.locator('.library-course-card')).to_have_count(26) # 25 + original sample
   expect(page.get_by_text('Academy plan: 10 academies · 260 planned modules',exact=True)).to_be_visible()
   page.get_by_text('Academy plan: 10 academies · 260 planned modules',exact=True).click()
   expect(page.get_by_role('table',name='Planned modules by skill level')).to_be_visible()
   expect(page.locator('tfoot')).to_contain_text('260')
   page.get_by_text('Academy plan: 10 academies · 260 planned modules',exact=True).click()
   page.get_by_label('Academy',exact=True).select_option('HVAC')
   page.locator('#training-search-form').get_by_role('button',name='Search',exact=True).click()
   expect(page.locator('.library-course-card h2')).to_have_text('Heating & Cooling Fundamentals')
   page.get_by_role('button',name='Clear filters',exact=True).click()
   assert page.locator('.library-cards .course-cover').count()==0
   rects=page.locator('.library-course-card').evaluate_all('nodes=>nodes.slice(0,3).map(n=>{const r=n.getBoundingClientRect();return {x:r.x,y:r.y,w:r.width,h:r.height}})')
   assert len({round(r['y']) for r in rects})==1,rects
   assert len({round(r['x']) for r in rects})==3,rects
   assert all(r['h']<460 for r in rects),rects
   page.screenshot(path='/tmp/coltrain-library-desktop-25.png',full_page=True)
   page.get_by_label('Learning path',exact=True).select_option('Department Lead/Supervisor')
   page.locator('#training-search-form').get_by_role('button',name='Search',exact=True).click()
   expect(page.locator('.library-course-card')).to_have_count(3)
   page.get_by_role('button',name='Clear filters',exact=True).click()
   page.get_by_label('Skill level',exact=True).select_option('foundations')
   page.get_by_label('Academy',exact=True).select_option('Paint & Surface Care')
   page.locator('#training-search-form').get_by_role('button',name='Search',exact=True).click()
   expect(page.locator('.library-course-card')).to_have_count(3)
   page.get_by_label('Search courses',exact=True).fill('sheen')
   page.locator('#training-search-form').get_by_role('button',name='Search',exact=True).click()
   expect(page.locator('.library-course-card h2')).to_have_text('Paint Fundamentals')
   page.get_by_role('button',name='Clear filters',exact=True).click()
   page.get_by_label('Search courses',exact=True).fill('CS-101')
   page.locator('#training-search-form').get_by_role('button',name='Search',exact=True).click()
   expect(page.locator('.library-course-card h2')).to_have_text('Customer Service Fundamentals')
   page.set_viewport_size({'width':390,'height':844})
   assert page.locator('body').evaluate('element=>element.scrollWidth<=innerWidth')
   assert page.locator('.library-course-card').evaluate('n=>n.getBoundingClientRect().height')<460
   page.screenshot(path='/tmp/coltrain-library-mobile-25.png',full_page=True)
   page.get_by_role('button',name='Preview course',exact=True).click()
   expected=json.loads((root/'courses/CS-101/prepared-import.json').read_text())['lessons']
   for i,lesson in enumerate(expected):
    expect(page.locator('.lesson-content h1')).to_have_text(lesson['title'])
    expect(page.locator('.lesson-content')).to_contain_text('Key takeaways')
    if i<4:page.locator('.lesson-content').get_by_role('button',name='Next lesson',exact=True).click()
   page.locator('.lesson-content').get_by_role('button',name='Back to library',exact=True).click()
   expect(page.locator('.library-course-card')).to_have_count(1)
   page.get_by_role('button',name='Clear filters',exact=True).click()
   page.set_viewport_size({'width':1280,'height':1000})
   sql("""delete from private.training_answer_keys where question_id in(select id from public.training_questions where course_id<>'c1000000-0000-4000-8000-000000000001');
    delete from public.training_questions where course_id<>'c1000000-0000-4000-8000-000000000001';
    delete from public.training_lessons where course_id<>'c1000000-0000-4000-8000-000000000001';
    delete from public.training_course_catalog where course_id<>'c1000000-0000-4000-8000-000000000001';
    delete from public.training_courses where id<>'c1000000-0000-4000-8000-000000000001';""")
   navigate('Course library')
   expect(page.locator('.course-card')).to_have_count(1)
   print('Passed compact library: all 25 real draft courses, three-column desktop, phone layout, level/topic/path/keyword filters and full imported-lesson preview.')
  login('admin@example.test')
  check_library_filters(True)
  check_full_catalog_cards()
  navigate('Course library')
  page.get_by_role('button',name='Make available to store',exact=True).click()
  expect(page.locator('#account-message')).to_contain_text('Course is available')
  navigate('Departments')
  page.locator('#training-department-form input[name=name]').fill('Paint')
  page.locator('#training-department-form button').click()
  expect(page.locator('#account-message')).to_have_text('Department created.')
  page.locator('#training-department-member').select_option('20000000-0000-0000-0000-000000000004')
  page.locator('#training-department-options input').check()
  page.get_by_role('button',name='Save departments',exact=True).click()
  expect(page.locator('#account-message')).to_have_text('Departments saved.')
  paint_id=sql("select id from public.training_departments where name='Paint'")
  page.locator('#training-department-form input[name=name]').fill('Receiving')
  page.locator('#training-department-form button').click()
  expect(page.locator('#account-message')).to_have_text('Department created.')
  page.get_by_role('button',name='Add starter departments',exact=True).click()
  expect(page.locator('#account-message')).to_have_text('5 starter departments added. Existing departments and employee placements are kept.')
  expect(page.get_by_role('button',name='Add starter departments',exact=True)).to_be_disabled()
  assert sql('select count(*) from public.training_departments')=='7'
  assert sql("select id from public.training_departments where name='Paint'")==paint_id
  assert sql("select department_id from public.training_member_departments where membership_id='20000000-0000-0000-0000-000000000004'")==paint_id
  assert sql("select count(*) from public.training_departments where name='Receiving'")=='1'
  navigate('Departments')
  expect(page.get_by_role('button',name='Add starter departments',exact=True)).to_be_disabled()
  assert sql('select count(*) from public.training_departments')=='7'
  navigate('Assign training')
  page.locator('#training-assign-form input[name=all]').check()
  page.locator('#training-assign-form input[name=department][value="'+paint_id+'"]').check()
  page.get_by_role('button',name='Assign course',exact=True).click()
  expect(page.locator('#account-message')).to_have_text('Training assigned to 1 person.')
  signout()
  login('employee.a@example.test')
  check_library_filters()
  navigate('Home')
  check_install_entry()
  expect(page.get_by_role('heading',name='Your next chapter',exact=True)).to_be_visible()
  expect(page.locator('.notification-dot')).to_be_visible()
  navigate('Notifications')
  expect(page.locator('.training-notification')).to_have_count(1)
  expect(page.locator('.training-notification h2')).to_have_text('Training assignment')
  page.set_viewport_size({'width':390,'height':844})
  assert page.locator('body').evaluate('element=>element.scrollWidth<=innerWidth')
  page.screenshot(path='/tmp/coltrain-notifications-employee-mobile.png',full_page=True)
  page.set_viewport_size({'width':1280,'height':1000})
  page.get_by_role('button',name='Mark all as read',exact=True).click()
  expect(page.locator('.notification-unread')).to_have_count(0)
  page.reload()
  expect(page.locator('.page-heading h1')).to_be_visible()
  navigate('Notifications')
  expect(page.locator('.training-notification .chip')).to_have_text('Read')
  page.get_by_role('button',name='View course',exact=True).click()
  expect(page.locator('.lesson-item').nth(1)).to_be_disabled()
  page.get_by_role('button',name='Mark complete & continue',exact=True).click()
  expect(page.locator('.lesson-content h1')).to_have_text('Teach, don’t just sell')
  page.get_by_role('button',name='Mark complete & continue',exact=True).click()
  expect(page.locator('.lesson-content h1')).to_have_text('Build your product knowledge')
  page.get_by_role('button',name='Complete & take quiz',exact=True).click()
  def quiz(correct):
   answers={'A customer asks a product question you cannot answer. What is the best response?':2,'Good customer service requires knowing every answer immediately.':1,'Which action best demonstrates “teach, don’t just sell”?':0,'Which is the best way to build product knowledge?':2,'Asking a knowledgeable teammate for help can build customer trust.':0}
   for i in range(5):
    prompt=page.locator('.quiz-panel h2').inner_text()
    choice=answers[prompt] if correct and (correct=='all' or prompt!='Asking a knowledgeable teammate for help can build customer trust.') else (answers[prompt]+1)%page.locator('.option').count()
    page.locator('.option input').nth(choice).check()
    page.locator('#training-quiz-form button[type=submit], #training-quiz-form button:not([type])').click()
  quiz(False)
  expect(page.get_by_role('heading',name='A few things to revisit')).to_be_visible()
  expect(page.locator('.result-stats strong').first).to_have_text('0%')
  def review_lessons():
   page.get_by_role('button',name='Review lessons',exact=True).click()
   expect(page.locator('.lesson-content h1')).to_have_text('Help customers find the answer')
   assert page.get_by_role('button',name='Mark complete & continue',exact=True).count()==0
   page.locator('.lesson-content').get_by_role('button',name='Next lesson',exact=True).click()
   expect(page.locator('.lesson-content h1')).to_have_text('Teach, don’t just sell')
   page.locator('.lesson-content').get_by_role('button',name='Next lesson',exact=True).click()
   expect(page.locator('.lesson-content h1')).to_have_text('Build your product knowledge')
   assert sql('select count(*) from public.training_lesson_completions')=='3'
  review_lessons()
  assert sql('select count(*) from public.training_attempts')=='1'
  page.locator('.lesson-content').get_by_role('button',name='Try knowledge check again',exact=True).click()
  quiz(False)
  review_lessons()
  page.locator('.lesson-content').get_by_role('button',name='Try knowledge check again',exact=True).click()
  quiz(False)
  review_lessons()
  page.locator('.lesson-content').get_by_role('button',name='Get manager help',exact=True).click()
  expect(page.get_by_role('heading',name='A little teamwork can help.')).to_be_visible()
  assert sql('select count(*) from public.training_attempts')=='3'
  signout()
  login('manager.a@example.test')
  check_install_entry()
  expect(page.get_by_role('heading',name='Help an employee retry')).to_be_visible()
  navigate('Notifications')
  login_notice=page.locator('.training-notification').filter(has=page.get_by_role('heading',name='An employee has signed in',exact=True))
  expect(login_notice).to_have_count(1)
  expect(login_notice).to_contain_text('for the first time.')
  help_notice=page.locator('.training-notification').filter(has=page.get_by_role('heading',name='An employee needs quiz help',exact=True))
  expect(help_notice).to_be_visible()
  help_notice.get_by_role('button',name='Go to dashboard',exact=True).click()
  expect(page.get_by_role('heading',name='Help an employee retry')).to_be_visible()
  page.locator('#training-unlock-form textarea').fill('Reviewed reliable product resources together.')
  page.get_by_role('button',name='Unlock one attempt',exact=True).click()
  expect(page.locator('#account-message')).to_have_text('One additional quiz attempt is available.')
  signout()
  login('employee.a@example.test')
  navigate('Notifications')
  retry_notice=page.locator('.training-notification').filter(has=page.get_by_role('heading',name='Another quiz attempt is ready',exact=True))
  expect(retry_notice).to_be_visible()
  retry_notice.get_by_role('button',name='View course',exact=True).click()
  page.locator('.lesson-content').get_by_role('button',name='Next lesson',exact=True).click()
  page.locator('.lesson-content').get_by_role('button',name='Next lesson',exact=True).click()
  page.locator('.lesson-content').get_by_role('button',name='Try knowledge check again',exact=True).click()
  quiz(True)
  expect(page.locator('.result-stats strong').first).to_have_text('80%')
  expect(page.locator('.result-stats strong').nth(1)).to_have_text('+40')
  page.get_by_role('button',name='Review course',exact=True).click()
  page.locator('.lesson-content').get_by_role('button',name='Next lesson',exact=True).click()
  page.locator('.lesson-content').get_by_role('button',name='Next lesson',exact=True).click()
  page.locator('.lesson-content').get_by_role('button',name='View course result',exact=True).click()
  expect(page.locator('.result-stats strong').first).to_have_text('80%')
  assert sql('select count(*) from public.training_attempts')=='4'
  page.screenshot(path=str(root/'design/training-results.png'),full_page=True)
  expect(page.locator('#account-message')).to_have_text('Course passed. Your points and trophy are saved.')
  page.set_viewport_size({'width':390,'height':844})
  page.get_by_role('button',name='Back to home',exact=True).click()
  expect(page.get_by_text('Lifetime points',exact=True)).to_be_visible()
  navigate('Notifications')
  expect(page.locator('.training-notification')).to_have_count(0)
  expect(page.get_by_role('heading',name='You’re all caught up.',exact=True)).to_be_visible()
  navigate('Home')
  expect(page.get_by_text('Lifetime points',exact=True)).to_be_visible()
  assert page.locator('body').evaluate('element=>element.scrollWidth<=innerWidth')
  page.screenshot(path=str(root/'design/training-employee-mobile.png'),full_page=True)
  page.reload()
  expect(page.locator('header .account-identity')).to_contain_text('Signed in as Pilot Employee')
  expect(page.get_by_text('You’re all caught up.',exact=True)).to_be_visible()
  signout()
  login('manager.a@example.test')
  row=page.locator('.table tbody tr').filter(has_text='Pilot Employee')
  expect(row).to_contain_text('Completed')
  expect(row).to_contain_text('Latest score 80%')
  expect(row.locator('td').last).to_have_text('40')
  assert page.get_by_text('A few things to revisit',exact=True).count()==0
  assert page.locator('body').evaluate('element=>element.scrollWidth<=innerWidth')
  page.set_viewport_size({'width':1280,'height':1000})
  page.screenshot(path=str(root/'design/training-manager.png'),full_page=True)
  navigate('Competitions')
  page.get_by_role('button',name='Start competition',exact=True).click()
  page.locator('#training-competition-form input[name=name]').fill('Service review challenge')
  page.locator('#training-competition-form input[name=reward]').fill('Pizza with the team')
  page.locator('#training-competition-form button').click()
  expect(page.locator('#account-message')).to_have_text('Competition saved for 1 employee.')
  expect(page.locator('.training-competition-card')).to_contain_text('Service review challenge')
  expect(page.locator('.competition-metrics').first).to_contain_text('0%')
  assert sql("select due_date is null from public.training_assignments")=='t'
  signout()
  login('employee.a@example.test')
  spotlight=page.locator('.training-competition-spotlight')
  expect(spotlight).to_contain_text('Service review challenge')
  assert spotlight.bounding_box()['y']<page.get_by_role('heading',name='Your next chapter').bounding_box()['y']
  expect(spotlight.get_by_role('button',name='Take competition quiz',exact=True)).to_be_visible()
  spotlight.get_by_role('button',name='Review lessons',exact=True).click()
  expect(page.get_by_role('heading',name='Review before your competition quiz')).to_be_visible()
  expect(page.locator('.lesson-content h1')).to_have_text('Help customers find the answer')
  page.locator('.lesson-content').get_by_role('button',name='Next lesson',exact=True).click()
  page.locator('.lesson-content').get_by_role('button',name='Next lesson',exact=True).click()
  assert sql('select count(*) from public.training_lesson_completions')=='3'
  assert sql('select count(*) from public.training_attempts')=='4'
  assert sql('select count(*) from private.training_challenge_attempts')=='0'
  assert sql('select sum(points) from private.training_point_awards')=='40'
  page.locator('.lesson-content').get_by_role('button',name='Take competition quiz',exact=True).click()
  quiz(False)
  expect(page.get_by_role('heading',name='Challenge saved')).to_be_visible()
  expect(page.locator('.answer-review')).to_contain_text('Correct answer:')
  page.get_by_role('button',name='See standings',exact=True).click()
  expect(page.locator('.training-standings tbody tr')).to_contain_text('Pilot Employee')
  assert page.get_by_text('Total team learning time',exact=True).count()==0
  page.get_by_role('button',name='Retake competition quiz',exact=True).click()
  quiz(True)
  page.get_by_role('button',name='See standings',exact=True).click()
  expect(page.locator('.training-standings tbody tr td').nth(2)).to_have_text('40')
  page.get_by_role('button',name='Retake competition quiz',exact=True).click()
  quiz('all')
  page.get_by_role('button',name='See standings',exact=True).click()
  expect(page.locator('.training-standings tbody tr td').nth(2)).to_have_text('50')
  expect(page.get_by_text('All challenge attempts used. Ask your manager for help.',exact=True)).to_be_visible()
  page.get_by_role('button',name='Lifetime',exact=True).click()
  expect(page.locator('.training-standings tbody tr td').nth(2)).to_have_text('40')
  expect(page.locator('.training-standings tbody tr td').nth(3)).to_have_text('0')
  expect(page.locator('.training-standings tbody tr td').nth(4)).to_have_text('40')
  assert sql('select count(*) from public.training_attempts')=='4'
  assert sql('select count(*) from public.training_trophies')=='1'
  page.set_viewport_size({'width':390,'height':844})
  assert page.locator('body').evaluate('element=>element.scrollWidth<=innerWidth')
  page.screenshot(path=str(root/'design/competition-employee-mobile.png'),full_page=True)
  signout()
  login('manager.a@example.test')
  row=page.locator('.table tbody tr').filter(has_text='Pilot Employee')
  expect(row.locator('td').nth(3)).to_have_text('50')
  expect(row.locator('td').nth(4)).to_have_text('40')
  expect(row.locator('td').nth(5)).to_have_text('0')
  expect(row.locator('td').nth(6)).to_have_text('40')
  navigate('Competitions')
  expect(page.locator('.competition-metrics').first).to_contain_text('100%')
  page.locator('#training-challenge-unlock-form textarea').fill('Reviewed the competition questions together.')
  page.get_by_role('button',name='Unlock one challenge attempt',exact=True).click()
  expect(page.locator('#account-message')).to_have_text('One additional challenge attempt is available.')
  page.set_viewport_size({'width':1280,'height':1000})
  page.screenshot(path=str(root/'design/competition-manager.png'),full_page=True)
  page.on('dialog',lambda dialog:dialog.accept())
  page.get_by_role('button',name='End competition now',exact=True).click()
  expect(page.locator('#account-message')).to_have_text('Competition closed. History is saved.')
  expect(page.locator('.competition-history')).to_contain_text('Service review challenge')
  expect(page.locator('.competition-history')).to_contain_text('100%')
  navigate('Account & team settings')
  expect(page.get_by_role('heading',name='Your store account')).to_be_visible()
  expect(page.get_by_role('button',name='Open menu')).to_be_visible()
  assert page.get_by_role('button',name='Open training',exact=True).count()==0
  page.locator('#profile-form input[name=name]').fill('Pilot Manager Updated')
  page.locator('#profile-form button[type=submit]').click()
  expect(page.locator('#account-message')).to_have_text('Profile and email preference saved.')
  expect(page.locator('header .account-identity')).to_contain_text('Signed in as Pilot Manager Updated')
  navigate('Dashboard')
  expect(page.get_by_role('heading',name='Your team, learning together.')).to_be_visible()
  page.set_viewport_size({'width':390,'height':844})
  expect(page.locator('header .account-identity')).to_be_visible()
  expect(page.locator('header .account-identity')).to_contain_text('Coltrain Hardware')
  assert page.locator('body').evaluate('element=>element.scrollWidth<=innerWidth')
  page.screenshot(path=str(root/'design/manager-header-mobile.png'),full_page=True)
  signout()
  expect(page.locator('header')).not_to_contain_text('Pilot Manager Updated')
  login('employee.a@example.test')
  expect(page.locator('header')).to_contain_text('Pilot Employee')
  expect(page.locator('header')).not_to_contain_text('Pilot Manager Updated')
  navigate('Account & team settings')
  expect(page.locator('#profile-form')).to_be_visible()
  navigate('Home')
  expect(page.get_by_role('heading',name='Your next chapter')).to_be_visible()
  # Team Corner: browser uploads and reads use actual SQL/RLS, with test-only byte storage.
  navigate('Team Corner')
  expect(page.get_by_role('heading',name='Team Corner',exact=True)).to_be_visible()
  expect(page.locator('.team-composer')).to_have_css('border-top-width','2px')
  png=base64.b64decode('iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAQAAAC1HAwCAAAAC0lEQVR42mNk+A8AAQUBAScY42YAAAAASUVORK5CYII=')
  photo={'name':'counter.png','mimeType':'image/png','buffer':png}
  message='A paint counter win. <img src=x onerror="window.teamAttack=1">'
  page.locator('#training-team-post-form textarea').fill(message)
  page.locator('[data-team-files="post"]').set_input_files(photo)
  expect(page.locator('.team-photo-previews img')).to_have_count(1)
  # Opening the menu must preserve the typed message and prepared photo.
  page.get_by_role('button',name='Open menu').click()
  page.locator('.training-drawer').get_by_role('button',name='Close',exact=True).click()
  expect(page.locator('#training-team-post-form textarea')).to_have_value(message)
  expect(page.locator('.team-photo-previews img')).to_have_count(1)
  lost_upload_response=True
  page.get_by_role('button',name='Post to team',exact=True).click()
  expect(page.locator('#account-message')).to_contain_text('The photo could not be uploaded')
  expect(page.locator('#training-team-post-form textarea')).to_have_value(message)
  assert sql('select count(*) from public.team_corner_posts')=='0'
  # Retry verifies the existing reserved upload and publishes exactly one post.
  page.get_by_role('button',name='Post to team',exact=True).click()
  expect(page.locator('#account-message')).to_have_text('Your post is shared with the team.')
  expect(page.locator('.team-post')).to_have_count(1)
  expect(page.locator('.team-post .team-message').first).to_have_text(message)
  assert page.evaluate('window.teamAttack') is None
  post_id=sql('select id from public.team_corner_posts')
  page.locator('.team-post .team-photo-grid img').scroll_into_view_if_needed()
  page.wait_for_function("document.querySelector('.team-post .team-photo-grid img').naturalWidth>0")
  assert sql('select count(*) from storage.objects')=='1'
  page.get_by_role('button',name='Like · 0',exact=True).click()
  expect(page.get_by_role('button',name='Liked · 1',exact=True)).to_be_visible()
  page.get_by_role('button',name='Liked · 1',exact=True).click()
  expect(page.get_by_role('button',name='Like · 0',exact=True)).to_be_visible()
  page.locator('[data-team-form="comment"] textarea').fill('Could we share this with the paint team?')
  page.locator('[data-team-files="'+post_id+'"]').set_input_files(photo)
  expect(page.locator('[data-team-form="comment"] .team-photo-previews img')).to_have_count(1)
  page.locator('[data-team-form="comment"]').get_by_role('button',name='Comment',exact=True).click()
  expect(page.locator('.team-comment')).to_have_count(1)
  expect(page.locator('.team-comment .team-message')).to_have_text('Could we share this with the paint team?')
  navigate('Account & team settings')
  page.locator('[data-profile-photo]').set_input_files(photo)
  expect(page.locator('#profile-photo-form img[alt="Selected profile picture"]')).to_be_visible()
  # Simulate an upload committed on the server whose response was lost.
  lost_upload_response=True
  page.get_by_role('button',name='Save photo',exact=True).click()
  expect(page.locator('#account-message')).to_have_text('Profile picture saved.')
  page.wait_for_function("document.querySelector('header .profile-avatar img')?.naturalWidth===512")
  expect(page.locator('header .profile-avatar img')).to_be_visible()
  first_avatar=sql("select avatar_path from public.profiles where user_id='00000000-0000-0000-0000-000000000004'")
  assert sql("select count(*) from storage.objects where bucket_id='profile-photos'")=='1'
  navigate('Team Corner')
  expect(page.locator('.team-post .panel-top .profile-avatar img')).to_be_visible()
  expect(page.locator('.team-comment-top .profile-avatar img')).to_be_visible()
  navigate('Store leaderboard')
  page.get_by_role('button',name='Lifetime',exact=True).click()
  expect(page.locator('.training-standings .profile-avatar img')).to_be_visible()
  navigate('Account & team settings')
  page.locator('[data-profile-photo]').set_input_files(photo)
  expect(page.locator('#profile-photo-form img[alt="Selected profile picture"]')).to_be_visible()
  page.get_by_role('button',name='Save photo',exact=True).click()
  expect(page.locator('#account-message')).to_have_text('Profile picture saved.')
  assert sql("select avatar_path from public.profiles where user_id='00000000-0000-0000-0000-000000000004'")!=first_avatar
  assert sql("select count(*) from storage.objects where bucket_id='profile-photos'")=='1'
  page.get_by_role('button',name='Remove photo',exact=True).click()
  expect(page.locator('#account-message')).to_have_text('Profile picture removed.')
  expect(page.locator('header .profile-avatar img')).to_have_count(0)
  assert sql("select count(*) from storage.objects where bucket_id='profile-photos'")=='0'
  navigate('Team Corner')
  expect(page.locator('.team-post .panel-top .profile-avatar img')).to_have_count(0)
  expect(page.locator('.team-comment-top .profile-avatar img')).to_have_count(0)

  navigate('Account & team settings')
  page.get_by_label('Team Corner nickname (optional)').fill('Paint Pro')
  page.locator('#profile-form button[type=submit]').click()
  expect(page.locator('#account-message')).to_have_text('Profile and email preference saved.')
  expect(page.locator('header .account-identity')).to_contain_text('Pilot Employee')
  expect(page.get_by_label('Team Corner nickname (optional)')).to_have_value('Paint Pro')
  navigate('Team Corner')
  expect(page.locator('.team-post h2')).to_have_text('Paint Pro')
  expect(page.locator('.team-comment-top strong')).to_have_text('Paint Pro')
  navigate('Account & team settings')
  page.get_by_label('Team Corner nickname (optional)').fill('')
  page.locator('#profile-form button[type=submit]').click()
  expect(page.locator('#account-message')).to_have_text('Profile and email preference saved.')
  navigate('Team Corner')
  expect(page.locator('.team-post h2')).to_have_text('Pilot Employee')
  expect(page.locator('.team-comment-top strong')).to_have_text('Pilot Employee')
  page.locator('.team-comment img').scroll_into_view_if_needed()
  page.wait_for_function("document.querySelector('.team-comment img').naturalWidth>0")
  assert sql('select count(*) from public.team_corner_media where comment_id is not null')=='1'
  assert page.locator('body').evaluate('element=>element.scrollWidth<=innerWidth')
  page.screenshot(path=str(root/'design/team-corner-employee-mobile.png'),full_page=True)
  signout()
  login('admin@example.test')
  navigate('Team Corner')
  expect(page.get_by_role('heading',name='This team feed is private')).to_be_visible()
  expect(page.locator('.team-post')).to_have_count(0)
  signout()
  login('manager.a@example.test')
  navigate('Team Corner')
  expect(page.locator('.team-post')).to_have_count(1)
  page.get_by_role('button',name='Pin announcement',exact=True).click()
  expect(page.locator('.team-post-pinned')).to_have_css('border-top-width','3px')
  page.get_by_role('button',name='Turn off comments',exact=True).click()
  expect(page.get_by_text('Comments are turned off for this post.',exact=True)).to_be_visible()
  expect(page.locator('[data-team-form="comment"]')).to_have_count(0)
  signout()
  login('employee.a@example.test')
  navigate('Team Corner')
  expect(page.get_by_text('Pinned announcement',exact=True)).to_be_visible()
  expect(page.locator('[data-team-form="comment"]')).to_have_count(0)
  expect(page.get_by_role('button',name='Turn on comments',exact=True)).to_have_count(0)
  signout()
  login('manager.a@example.test')
  navigate('Team Corner')
  page.get_by_role('button',name='Turn on comments',exact=True).click()
  page.locator('.team-comment').get_by_role('button',name='Remove',exact=True).click()
  expect(page.locator('.team-comment')).to_have_count(0)
  page.locator('#training-team-support-form textarea').fill('Please help us review this store announcement.')
  page.get_by_role('button',name='Request admin support',exact=True).click()
  expect(page.get_by_role('button',name='Revoke support access',exact=True)).to_be_visible()
  page.set_viewport_size({'width':1280,'height':1000})
  page.screenshot(path=str(root/'design/team-corner-manager.png'),full_page=True)
  signout()
  login('admin@example.test')
  navigate('Team Corner')
  navigate('Store feed support')
  expect(page.get_by_role('heading',name='Team support requests')).to_be_visible()
  page.get_by_role('button',name='Open store feed',exact=True).click()
  expect(page.get_by_role('heading',name='Read-only support access')).to_be_visible()
  expect(page.locator('.team-post')).to_have_count(1)
  expect(page.locator('.team-composer')).to_have_count(0)
  expect(page.get_by_role('button',name='Remove post',exact=True)).to_have_count(0)
  support_page=page
  page=browser.new_page(service_workers='block',viewport={'width':1280,'height':1000})
  page.on('pageerror',lambda error:errors.append(str(error)))
  page.on('dialog',lambda dialog:dialog.accept())
  page.route('**/*',handle)
  page.goto('https://training.example/accounts/')
  login('manager.a@example.test')
  navigate('Team Corner')
  page.get_by_role('button',name='Revoke support access',exact=True).click()
  expect(page.locator('#account-message')).to_have_text('Administrator support access revoked.')
  support_page.get_by_role('button',name='Refresh feed',exact=True).click()
  expect(support_page.get_by_role('heading',name='This team feed is private')).to_be_visible()
  page.get_by_role('button',name='Remove post',exact=True).click()
  expect(page.locator('.team-post')).to_have_count(0)
  assert sql('select count(*) from public.team_corner_posts where deleted_at is not null')=='1'
  assert query_as(people['employee.a@example.test'],"select count(*) from storage.objects")=='0'
  print('Passed Team Corner browser + SQL/RLS: draft preservation, lost upload response/retry without duplicates, private photos in posts/comments, escaped text, likes, manager pin/comment controls/removal, admin lock, read-only support and revocation, mobile layout.')
  # A new-post alert opens its exact post even after it leaves the first feed page.
  older_post=query_as(people['manager.a@example.test'],"select public.create_team_corner_post('10000000-0000-0000-0000-000000000099',gen_random_uuid(),'Read this older team announcement')")
  for i in range(22):
   query_as(people['manager.a@example.test'],f"select public.create_team_corner_post('10000000-0000-0000-0000-000000000099',gen_random_uuid(),'Newer team update {i}')")
  signout();login('employee.a@example.test');navigate('Notifications')
  expect(page.get_by_role('button',name='View team post',exact=True)).to_have_count(23)
  note=sql("select id from private.training_notifications where user_id='"+people['employee.a@example.test']+"' and event_key='team-post:"+older_post+"'")
  page.locator('.training-notification[data-notification="'+note+'"]').get_by_role('button',name='View team post',exact=True).click()
  target_post=page.locator('.team-post[data-post="'+older_post+'"]')
  expect(target_post).to_have_count(1)
  expect(target_post.locator('.team-message').first).to_have_text('Read this older team announcement')
  target_post.locator('textarea[name=message]').fill('Thanks for the refresher')
  target_post.get_by_role('button',name='Comment',exact=True).click()
  expect(target_post.locator('.team-comment')).to_contain_text('Thanks for the refresher')
  navigate('Notifications')
  expect(page.locator('.training-notification[data-notification="'+note+'"]')).not_to_have_class(re.compile('notification-unread'))
  signout();login('manager.a@example.test')
  print('Passed Team Corner post notifications: recipient inbox, exact older post, comment after opening, persistent read receipt.')
  navigate('Account & team settings')
  expect(page.get_by_role('button',name='Make store manager',exact=True)).to_have_count(1)
  page.get_by_role('button',name='Make store manager',exact=True).click()
  expect(page.locator('#account-message')).to_contain_text('Store manager role saved.')
  navigate('Account & team settings')
  expect(page.get_by_role('button',name='Make store manager',exact=True)).to_have_count(0)
  signout();login('employee.a@example.test')
  expect(page.get_by_role('heading',name='Your team, learning together.',exact=True)).to_be_visible()
  assert sql('select count(*) from private.store_role_changes')=='1'
  print('Passed manager promotion UI: same-store manager control, confirmation/save, updated role and manager dashboard on the existing login.')
  assert not errors,errors
  assert sql('select count(*) from public.training_trophies')=='1'
  assert sql('select sum(points) from private.training_point_awards')=='40'
  assert sql('select count(*) from public.training_attempts')=='4'
  print('Passed browser + actual SQL/RLS: admin release, starter departments preserving existing departments/placements without duplicates, assignment, sequential lessons, failed quiz explanations, completed-lesson review navigation, three-attempt block, manager unlock, passing retry, points/trophy, reload persistence, manager reporting, mobile, review competition for an already-passed employee, separate scores/attempts, three-attempt challenge limit, manager challenge unlock, lifetime leaderboard, competition history, direct manager/employee home entry, persistent settings menu, profile identity updates, mobile identity, sign-out and account switching.')
  browser.close()
finally:
 subprocess.run(['docker','stop',name],capture_output=True)
 subprocess.run(['node','scripts/build-accounts.mjs'],cwd=root,check=True)
