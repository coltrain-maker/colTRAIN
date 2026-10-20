-- Publish the approved ten-module Daily pilot and enable it ONLY for Coltrain Hardware.
-- Requires migrations 012/013 and the pilot draft import. No website/Netlify action here.
-- This automatically enrolls active store members, including managers. Sends no emails.
-- Safe to rerun: existing completions, attempts and assignment dates are preserved.
begin;
do $dailyrelease$
declare target_store uuid; owner_id uuid:='2370c99a-9b5e-439a-b73a-00ada7a35661'; item record;
begin
 if (select count(*) from public.organizations where lower(btrim(name))='coltrain hardware')<>1 then
  raise exception 'Expected exactly one Coltrain Hardware store. No changes made; ask Codex to check the store name/ID.';
 end if;
 select id into target_store from public.organizations where lower(btrim(name))='coltrain hardware';
 if not exists(select 1 from public.platform_admins where user_id=owner_id) then
  raise exception 'The configured owner is not a colTRAIN administrator. No changes made; ask Codex to verify the administrator ID.';
 end if;
 -- Set the verified administrator identity for the existing permission-checked RPCs.
 -- The SQL Editor postgres role can do this; browser clients cannot set database session claims.
 perform set_config('request.jwt.claim.sub',owner_id::text,true);
 for item in select * from (values
 ('db87a4e2-a48e-5d8d-9a08-bf8eb2355c8c'::uuid,'CD-0001','0.1.0',1),
 ('efa9d26e-de7a-539f-b702-8588fdca0ddd'::uuid,'CD-0002','0.1.0',2),
 ('bb3f33ae-d715-5555-8861-ad7006e9945d'::uuid,'CD-0003','0.1.0',3),
 ('7c27d8c7-50d1-56c8-891e-84c6b1af50c9'::uuid,'CD-0004','0.2.0',4),
 ('15bea75b-3ca2-54b3-9268-ef0b1769ac61'::uuid,'CD-0005','0.2.0',5),
 ('b353a01d-52eb-57fa-b89a-1e0f14595d8c'::uuid,'CD-0006','0.1.0',6),
 ('3c15145a-85bd-5822-bd45-a7b9173043f7'::uuid,'CD-0007','0.1.0',7),
 ('c982a324-c83f-54eb-946a-e10ec58aa8d3'::uuid,'CD-0008','0.1.0',8),
 ('e70f9b09-4a6e-5d1f-8fd9-b671c5e12f75'::uuid,'CD-0009','0.2.0',9),
 ('e04c98b5-91f3-5bb7-a4ad-f81c44e0cf10'::uuid,'CD-0010','0.2.0',10)
 ) expected(id,code,version,slot) loop
  if not exists(select 1 from public.daily_modules d join public.daily_sequence s on s.module_id=d.id
   join private.daily_editorial e on e.module_id=d.id
   where d.id=item.id and d.code=item.code and d.version=item.version and d.skill_level='foundations'
   and s.skill_level='foundations' and s.position=item.slot
   and (e.source_document->'approval'->>'content_approved')::boolean is true
   and e.source_document->'metadata'->>'Stable module ID'=item.code
   and e.source_document->'metadata'->>'Version'=item.version) then
   raise exception 'Approved Daily % or its sequence is missing/different. No changes made. Complete the draft import and migration 013 first.',item.code;
  end if;
  perform public.publish_daily_module(item.id);
  perform public.release_daily_module(target_store,item.id);
 end loop;
end;
$dailyrelease$;
commit;
select d.code,d.title,d.published,
 exists(select 1 from public.daily_releases r where r.module_id=d.id and r.organization_id=o.id) as available_to_coltrain_hardware,
 (select count(*) from public.daily_assignments a join public.organization_memberships m on m.id=a.membership_id
  where a.module_id=d.id and a.organization_id=o.id and m.status='active') as active_members_enrolled
from public.daily_modules d join public.daily_sequence s on s.module_id=d.id
cross join public.organizations o
where lower(btrim(o.name))='coltrain hardware' and d.id in ('db87a4e2-a48e-5d8d-9a08-bf8eb2355c8c','efa9d26e-de7a-539f-b702-8588fdca0ddd','bb3f33ae-d715-5555-8861-ad7006e9945d','7c27d8c7-50d1-56c8-891e-84c6b1af50c9','15bea75b-3ca2-54b3-9268-ef0b1769ac61','b353a01d-52eb-57fa-b89a-1e0f14595d8c','3c15145a-85bd-5822-bd45-a7b9173043f7','c982a324-c83f-54eb-946a-e10ec58aa8d3','e70f9b09-4a6e-5d1f-8fd9-b671c5e12f75','e04c98b5-91f3-5bb7-a4ad-f81c44e0cf10')
order by s.position;
