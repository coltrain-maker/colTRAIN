insert into auth.users(id,email,email_confirmed_at) select ('00000000-0000-0000-0000-'||lpad(n::text,12,'0'))::uuid,'catalog'||n||'@example.test',now() from generate_series(80,83)n;
insert into public.organizations(id,name) values('10000000-0000-0000-0000-000000000080','Catalog A'),('10000000-0000-0000-0000-000000000081','Catalog B');
insert into public.organization_memberships(id,organization_id,user_id,email,role)
select ('20000000-0000-0000-0000-'||lpad(n::text,12,'0'))::uuid,
 case when n<82 then '10000000-0000-0000-0000-000000000080' else '10000000-0000-0000-0000-000000000081' end::uuid,
 ('00000000-0000-0000-0000-'||lpad(n::text,12,'0'))::uuid,'catalog'||n||'@example.test',case when n in(80,82) then 'manager' else 'employee' end
from generate_series(80,83)n;
insert into public.training_courses(id,slug,title,category,published) values
 ('c1000000-0000-4000-8000-000000000080','catalog-application','Application test','Paint & Decorating',true),
 ('c1000000-0000-4000-8000-000000000081','catalog-secret','Unreleased catalog test','Private Academy',true);
insert into public.training_course_catalog(course_id,course_code,skill_level,topics,keywords) values
 ('c1000000-0000-4000-8000-000000000080','TEST-201','application',array['Paint'],array['adhesion']),
 ('c1000000-0000-4000-8000-000000000081','SECRET-301','expertise',array['Secret topic'],array['secret term']);
update public.training_course_catalog set learning_paths=array['Sales Floor Associate'] where course_code='TEST-201';
insert into public.training_course_releases(organization_id,course_id,released_by) values
 ('10000000-0000-0000-0000-000000000080','c1000000-0000-4000-8000-000000000080','00000000-0000-0000-0000-000000000001');
set role authenticated;
set request.jwt.claim.sub='00000000-0000-0000-0000-000000000081';
select test.ok((select count(*) from public.training_course_catalog)=1,'employee reads catalog tags only for available course');
select test.ok(public.get_training_workspace('10000000-0000-0000-0000-000000000080')->'courses'->0->>'skill_level'='application','workspace includes real application level');
select test.ok(public.get_training_workspace('10000000-0000-0000-0000-000000000080')->'courses'->0->'keywords'='["adhesion"]','workspace includes keywords without quiz keys');
select test.ok(public.get_training_workspace('10000000-0000-0000-0000-000000000080')->'courses'->0->'learning_paths'='["Sales Floor Associate"]','workspace includes learning paths');
select test.ok(position('Secret topic' in public.get_training_workspace('10000000-0000-0000-0000-000000000080')::text)=0,'hidden course topic is not returned');
select test.rejects($q$update public.training_course_catalog set skill_level='expertise'$q$,'permission denied','employee cannot change course level');
select test.rejects($q$insert into public.training_course_catalog(course_id) values('c1000000-0000-4000-8000-000000000001')$q$,'permission denied','employee cannot insert classification');
set request.jwt.claim.sub='00000000-0000-0000-0000-000000000080';
select test.ok((select count(*) from public.training_course_catalog)=1,'manager cannot see hidden course topics');
select test.rejects($q$delete from public.training_course_catalog$q$,'permission denied','manager cannot delete classification');
set request.jwt.claim.sub='00000000-0000-0000-0000-000000000083';
select test.ok((select count(*) from public.training_course_catalog)=0,'other store has no catalog tag access');
select test.ok(jsonb_array_length(public.get_training_workspace('10000000-0000-0000-0000-000000000081')->'courses')=0,'other store library stays empty');
set request.jwt.claim.sub='00000000-0000-0000-0000-000000000001';
select test.ok(exists(select 1 from public.training_course_catalog where course_code='SECRET-301'),'administrator can review unreleased catalog metadata');
reset role;
select test.ok(not has_function_privilege('authenticated','private.training_workspace_before_catalog(uuid)','execute'),'catalog wrapper cannot be bypassed');
select test.ok(not has_table_privilege('anon','public.training_course_catalog','select'),'anonymous catalog access denied');
select test.rejects($q$insert into public.training_course_catalog(course_id,skill_level) values('c1000000-0000-4000-8000-000000000001','manager')$q$,'check constraint','job title is not a skill level');
-- Catalog updates do not edit assigned graded content or reset progress.
insert into public.training_assignments(organization_id,membership_id,course_id,due_date,assigned_by)
values('10000000-0000-0000-0000-000000000080','20000000-0000-0000-0000-000000000081','c1000000-0000-4000-8000-000000000080',current_date+30,'00000000-0000-0000-0000-000000000080');
update public.training_course_catalog set keywords=array['adhesion','surface preparation'] where course_code='TEST-201';
select test.ok((select count(*) from public.training_assignments where course_id='c1000000-0000-4000-8000-000000000080')=1,'metadata update preserves assignment');
select test.rejects($q$update public.training_courses set passing_percent=60 where id='c1000000-0000-4000-8000-000000000080'$q$,'Assigned course versions cannot be edited','graded content remains immutable');
select 'Passed course catalog privacy, classification and immutable-content integration ('||count(*)||' total SQL assertions).' from test.results;
