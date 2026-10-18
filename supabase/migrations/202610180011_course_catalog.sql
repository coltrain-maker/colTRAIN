-- Course classification is catalog metadata, separate from immutable graded content.
begin;
create table public.training_course_catalog (
 course_id uuid primary key references public.training_courses(id),
 course_code text not null default '' check(length(course_code)<=40),
 skill_level text not null default 'foundations' check(skill_level in ('foundations','application','expertise')),
 topics text[] not null default '{}' check(cardinality(topics)<=30 and array_position(topics,null) is null),
 learning_paths text[] not null default '{}' check(cardinality(learning_paths)<=20 and array_position(learning_paths,null) is null),
 keywords text[] not null default '{}' check(cardinality(keywords)<=100 and array_position(keywords,null) is null)
);
alter table public.training_course_catalog enable row level security;
create policy training_catalog_read on public.training_course_catalog for select to authenticated
 using(private.can_read_training_course(course_id));
revoke all on public.training_course_catalog from public,anon,authenticated;
grant select on public.training_course_catalog to authenticated;

-- The approved launch courses are Foundations. No proposed courses are created.
insert into public.training_course_catalog(course_id,course_code,skill_level,topics,keywords)
select id,coalesce(upper(substring(slug from '^([a-z]{2}-[0-9]{3})(-|$)')),''),
 'foundations',case when category<>'' then array[category] else '{}'::text[] end,'{}'::text[]
from public.training_courses;

-- Add useful topic/keyword tags to the supplied courses when they already exist.
update public.training_course_catalog m set
 topics=tags.topics,keywords=tags.keywords
from public.training_courses c join (values
 ('customer-trust',array['Customer service','Product knowledge'],array['customer trust','reliable answers','manufacturer resources']),
 ('rf-101-your-first-day-in-hardware-retail',array['Onboarding','Teamwork','Customer service'],array['first day','independent retail','acknowledge','ask','assist','close']),
 ('rf-102-retail-terms-and-hardware-vocabulary',array['Retail vocabulary','Inventory','Product knowledge'],array['SKU','UPC','stock keeping unit','barcode','nominal size','fasteners','trimmer line']),
 ('rf-103-store-safety-fundamentals',array['Safety','Equipment','Emergency response'],array['hazards','lifting','spills','near misses','evacuation','incident reporting']),
 ('rf-104-understanding-the-hardware-store',array['Store operations','Departments','Customer service'],array['store layout','receiving','backstock','store services','customer handoff'])
) tags(slug,topics,keywords) on tags.slug=c.slug
where m.course_id=c.id;

-- Approved paths are browse labels, not automatic assignments or prerequisite gates.
update public.training_course_catalog m set learning_paths=paths.names
from (values
 ('RF-101',array['New Retail Employee']::text[]),
 ('RF-102',array['New Retail Employee']::text[]),
 ('RF-103',array['New Retail Employee']::text[]),
 ('RF-104',array['New Retail Employee']::text[]),
 ('CS-101',array['New Retail Employee']::text[]),
 ('CS-102',array['Sales Floor Associate']::text[]),
 ('CS-103',array['New Retail Employee']::text[]),
 ('IM-101',array['Inventory & Merchandising Associate','Store Manager/Owner']::text[]),
 ('IM-102',array['Inventory & Merchandising Associate','Store Manager/Owner']::text[]),
 ('IM-103',array['Sales Floor Associate','Inventory & Merchandising Associate','Store Manager/Owner']::text[]),
 ('HT-101',array['Sales Floor Associate']::text[]),
 ('HT-102',array['Sales Floor Associate']::text[]),
 ('HT-103',array['Sales Floor Associate']::text[]),
 ('HB-101',array['Department Specialist']::text[]),
 ('HB-102',array['Department Specialist']::text[]),
 ('HB-103',array['Department Specialist']::text[]),
 ('HB-104',array['Department Specialist']::text[]),
 ('PD-101',array['Department Specialist']::text[]),
 ('PD-102',array['Department Specialist']::text[]),
 ('PD-103',array['Department Specialist']::text[]),
 ('LG-101',array['Department Specialist']::text[]),
 ('LG-102',array['Department Specialist']::text[]),
 ('BL-101',array['Department Lead/Supervisor','Store Manager/Owner']::text[]),
 ('BL-102',array['Department Lead/Supervisor','Store Manager/Owner']::text[]),
 ('BL-103',array['Department Lead/Supervisor','Store Manager/Owner']::text[])
) paths(code,names) where m.course_code=paths.code;

-- Keep every existing store/role/answer boundary in the underlying workspace.
alter function public.get_training_workspace(uuid) set schema private;
alter function private.get_training_workspace(uuid) rename to training_workspace_before_catalog;
revoke all on function private.training_workspace_before_catalog(uuid) from public,anon,authenticated;
create function public.get_training_workspace(store uuid) returns jsonb
language plpgsql stable security definer set search_path='' as $$
declare base jsonb; courses jsonb;
begin
 base:=private.training_workspace_before_catalog(store);
 select coalesce(jsonb_agg(item||jsonb_build_object(
  'course_code',coalesce(m.course_code,''),
  'skill_level',coalesce(m.skill_level,'foundations'),
  'topics',coalesce(to_jsonb(m.topics),'[]'::jsonb),
  'keywords',coalesce(to_jsonb(m.keywords),'[]'::jsonb),
  'learning_paths',coalesce(to_jsonb(m.learning_paths),'[]'::jsonb)
 ) order by position),'[]'::jsonb) into courses
 from jsonb_array_elements(base->'courses') with ordinality x(item,position)
 left join public.training_course_catalog m on m.course_id=(item->>'id')::uuid;
 return base||jsonb_build_object('courses',courses,'catalog_metadata_version',1);
end;
$$;
revoke all on function public.get_training_workspace(uuid) from public,anon;
grant execute on function public.get_training_workspace(uuid) to authenticated;
notify pgrst,'reload schema';
commit;
