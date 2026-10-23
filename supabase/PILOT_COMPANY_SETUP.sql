-- Existing project only, AFTER migration 023. Run in Supabase SQL Editor as postgres.
-- Confirms the known platform administrator, preserves existing stores, and creates
-- Keith Hardware only if absent. No invitations, subscriptions, emails, or charges.
begin;
set local request.jwt.claim.sub='2370c99a-9b5e-439a-b73a-00ada7a35661';
do $$
declare pilot_name text; store uuid; matches integer;
begin
 if not private.is_admin() then raise exception 'The expected colTRAIN administrator is not configured; no changes made'; end if;
 foreach pilot_name in array array['Coltrain Hardware','Keith Hardware'] loop
  select count(*) into matches from public.organizations where lower(btrim(name))=lower(pilot_name);
  if matches>1 then raise exception 'Multiple stores named %. Resolve the store IDs before continuing; no changes made',pilot_name; end if;
  if matches=0 then
   if pilot_name='Coltrain Hardware' then raise exception 'Existing Coltrain Hardware store not found; no changes made'; end if;
   -- Fifteen test seats; existing Keith Hardware seat counts are never changed.
   store:=public.create_store(pilot_name,15);
  else
   select id into store from public.organizations where lower(btrim(name))=lower(pilot_name);
  end if;
  perform public.admin_set_store_pilot(store,true,'Approved no-charge pilot; paid subscription requires explicit approval');
 end loop;
end;
$$;
select o.id as store_id,o.name,t.access_mode,
 (select count(*) from public.seats s where s.organization_id=o.id) as training_seats,
 c.owner_user_id
from public.organizations o join private.store_account_terms t on t.organization_id=o.id
join private.company_stores s on s.organization_id=o.id
join private.companies c on c.id=s.company_id
where lower(btrim(o.name)) in ('coltrain hardware','keith hardware') order by o.name;
commit;
