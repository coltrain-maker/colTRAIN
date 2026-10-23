-- Publish the approved Daily modules CD-0011 through CD-0020 and enable it ONLY for Coltrain Hardware.
-- Requires migrations 012/013 and the modules 11–20 draft import. No website/Netlify action here.
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
 if (select count(*) from public.daily_sequence s join public.daily_modules d on d.id=s.module_id join public.daily_releases r on r.module_id=d.id
  where r.organization_id=target_store and d.published and s.skill_level='foundations' and s.position between 1 and 10)<>10 then
  raise exception 'Release the first ten Daily modules to Coltrain Hardware before adding modules 11–20';
 end if;
 for item in select * from (values
 ('9ae3aae9-e747-5eac-a014-9245073a7d82'::uuid,'CD-0011','0.2.0',11),
 ('c184c565-89e3-5ad7-8c75-8ebcfad81d4e'::uuid,'CD-0012','0.2.0',12),
 ('9a575dc0-ce8e-54a0-a9c6-98a5b01e959d'::uuid,'CD-0013','0.1.0',13),
 ('1f0a9dbe-8400-55c4-a270-015646780d47'::uuid,'CD-0014','0.1.0',14),
 ('9e4908d2-ae9f-5f24-888f-e98e1618b323'::uuid,'CD-0015','0.1.0',15),
 ('7c183467-6272-5bae-8f97-699a835ea832'::uuid,'CD-0016','0.1.0',16),
 ('2c90f1bb-3a95-5a64-abab-d7412717a069'::uuid,'CD-0017','0.1.0',17),
 ('ae611e9b-9efa-5ef2-9d04-d721369aa9c7'::uuid,'CD-0018','0.1.0',18),
 ('94ed37f7-4df5-5087-a5a8-c355317b2cd0'::uuid,'CD-0019','0.1.0',19),
 ('e18a448a-042a-5b40-adb1-f4a7c6c63970'::uuid,'CD-0020','0.1.0',20)
 ) expected(id,code,version,slot) loop
  if not exists(select 1 from public.daily_modules d join public.daily_sequence s on s.module_id=d.id
   join private.daily_editorial e on e.module_id=d.id
   where d.id=item.id and d.code=item.code and d.version=item.version and d.skill_level='foundations'
   and s.skill_level='foundations' and s.position=item.slot
   and (e.source_document->'approval'->>'content_approved')::boolean is true
   and e.source_document->'metadata'->>'Stable module ID'=item.code
   and e.source_document->'metadata'->>'Version'=item.version) then
   raise exception 'Approved Daily % or its sequence is missing/different. No changes made. Complete the modules 11–20 draft import and migration 013 first.',item.code;
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
where lower(btrim(o.name))='coltrain hardware' and d.id in ('9ae3aae9-e747-5eac-a014-9245073a7d82','c184c565-89e3-5ad7-8c75-8ebcfad81d4e','9a575dc0-ce8e-54a0-a9c6-98a5b01e959d','1f0a9dbe-8400-55c4-a270-015646780d47','9e4908d2-ae9f-5f24-888f-e98e1618b323','7c183467-6272-5bae-8f97-699a835ea832','2c90f1bb-3a95-5a64-abab-d7412717a069','ae611e9b-9efa-5ef2-9d04-d721369aa9c7','94ed37f7-4df5-5087-a5a8-c355317b2cd0','e18a448a-042a-5b40-adb1-f4a7c6c63970')
order by s.position;
