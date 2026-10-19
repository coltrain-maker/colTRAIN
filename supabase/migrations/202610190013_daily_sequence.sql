-- Apply once AFTER migration 012 and the 10-module draft import.
-- Shared Daily path: 88 Foundations -> 112 Application -> 60 Expertise.
begin;
alter table public.daily_modules add constraint daily_modules_id_level unique(id,skill_level);
create table public.daily_sequence (
 module_id uuid primary key, skill_level text not null check(skill_level in ('foundations','application','expertise')),
 position integer not null,
 unique(skill_level,position),
 foreign key(module_id,skill_level) references public.daily_modules(id,skill_level),
 check(position>=1 and position<=case skill_level when 'foundations' then 88 when 'application' then 112 else 60 end)
);
alter table public.daily_sequence enable row level security;
create policy daily_sequence_read on public.daily_sequence for select to authenticated using(private.can_read_daily(module_id));
revoke all on public.daily_sequence from public,anon,authenticated;
grant select on public.daily_sequence to authenticated;

create function private.daily_ordinal(level text,slot integer) returns integer
language sql immutable set search_path='' as $$
 select slot+case level when 'foundations' then 0 when 'application' then 88 else 200 end;
$$;
create function private.freeze_daily_sequence() returns trigger language plpgsql set search_path='' as $$
begin
 -- Assigned slots can never be moved/removed or replaced underneath learners.
 if tg_op<>'INSERT' and exists(select 1 from public.daily_assignments where module_id=old.module_id) then
  raise exception 'Assigned Daily sequence is fixed; preserve learner progress';
 end if;
 if tg_op='DELETE' then return old; end if;return new;
end;
$$;
create trigger daily_sequence_frozen before update or delete on public.daily_sequence for each row execute function private.freeze_daily_sequence();
create function public.set_daily_sequence(module uuid,slot integer) returns void
language plpgsql security definer set search_path='' as $$
declare level text;
begin
 if not private.is_admin() then raise exception 'Administrator access required'; end if;
 select skill_level into level from public.daily_modules where id=module for update;
 if not found then raise exception 'Daily module not found'; end if;
 if exists(select 1 from public.daily_sequence s where s.module_id=module and s.position=set_daily_sequence.slot) then return; end if;
 if exists(select 1 from public.daily_releases where module_id=module) then raise exception 'Set the sequence before releasing this module'; end if;
 insert into public.daily_sequence(module_id,skill_level,position) values(module,level,slot)
 on conflict(module_id) do update set position=excluded.position;
end;
$$;
-- Map only the exact imported pilot versions. No placeholder modules are created.
insert into public.daily_sequence(module_id,skill_level,position)
select d.id,d.skill_level,v.position from (values
 ('db87a4e2-a48e-5d8d-9a08-bf8eb2355c8c'::uuid,1),
 ('efa9d26e-de7a-539f-b702-8588fdca0ddd'::uuid,2),
 ('bb3f33ae-d715-5555-8861-ad7006e9945d'::uuid,3),
 ('7c27d8c7-50d1-56c8-891e-84c6b1af50c9'::uuid,4),
 ('15bea75b-3ca2-54b3-9268-ef0b1769ac61'::uuid,5),
 ('b353a01d-52eb-57fa-b89a-1e0f14595d8c'::uuid,6),
 ('3c15145a-85bd-5822-bd45-a7b9173043f7'::uuid,7),
 ('c982a324-c83f-54eb-946a-e10ec58aa8d3'::uuid,8),
 ('e70f9b09-4a6e-5d1f-8fd9-b671c5e12f75'::uuid,9),
 ('e04c98b5-91f3-5bb7-a4ad-f81c44e0cf10'::uuid,10)
) v(id,position) join public.daily_modules d on d.id=v.id;

create function private.enroll_daily_store(store uuid) returns void
language sql security definer set search_path='' as $$
 insert into public.daily_assignments(organization_id,membership_id,module_id,available_on,assigned_by)
 select store,m.id,r.module_id,(now() at time zone o.time_zone)::date,r.released_by
 from public.daily_releases r join public.daily_sequence s on s.module_id=r.module_id
 join public.organizations o on o.id=r.organization_id
 join public.organization_memberships m on m.organization_id=r.organization_id and m.status='active'
 where r.organization_id=store
 on conflict(membership_id,module_id) do nothing;
$$;
create function private.auto_enroll_daily() returns trigger
language plpgsql security definer set search_path='' as $$
begin
 if tg_table_name='organization_memberships' then
  if new.status='active' then perform private.enroll_daily_store(new.organization_id);end if;
 else
  perform private.enroll_daily_store(new.organization_id);
 end if;
 return new;
end;
$$;
create trigger daily_enroll_members after insert or update of status,role on public.organization_memberships for each row execute function private.auto_enroll_daily();
create trigger daily_enroll_releases after insert on public.daily_releases for each row execute function private.auto_enroll_daily();
create or replace function public.release_daily_module(store uuid,module uuid,available boolean default true) returns void
language plpgsql security definer set search_path='' as $$
begin
 if not private.is_admin() then raise exception 'Administrator access required'; end if;
 if available is null then raise exception 'Choose availability'; end if;
 if not exists(select 1 from public.daily_modules where id=module and published) then raise exception 'Publish this Daily module first'; end if;
 if available then
  if not exists(select 1 from public.daily_sequence where module_id=module) then raise exception 'Set this module sequence before release'; end if;
  insert into public.daily_releases(organization_id,module_id,released_by) values(store,module,auth.uid()) on conflict do nothing;
  perform private.enroll_daily_store(store);
 else delete from public.daily_releases where organization_id=store and module_id=module;
 end if;
end;
$$;
create or replace function public.assign_daily_module(module uuid,store uuid,employee_ids uuid[] default '{}',department_ids uuid[] default '{}',all_employees boolean default false,start_date date default null) returns integer
language plpgsql security definer set search_path='' as $$
begin
 raise exception 'Daily enrollment is automatic for all active store members; managers do not assign departments or dates';
end;
$$;
create or replace function private.daily_is_learner(assignment uuid,ready boolean default true) returns boolean
language sql stable security definer set search_path='' as $$
 select exists(select 1 from public.daily_assignments a
 join public.organization_memberships m on m.id=a.membership_id
 join public.organizations o on o.id=a.organization_id
 left join public.daily_sequence s on s.module_id=a.module_id
 where a.id=assignment and m.user_id=auth.uid() and m.status='active'
 and (not ready or (
 a.available_on<=(now() at time zone o.time_zone)::date and (
 a.completed_at is not null or (
 s.module_id is not null and
 (select count(*) from public.daily_assignments prior
 join public.daily_sequence ps on ps.module_id=prior.module_id
 where prior.membership_id=a.membership_id and prior.completed_at is not null
 and private.daily_ordinal(ps.skill_level,ps.position)<private.daily_ordinal(s.skill_level,s.position))
 =private.daily_ordinal(s.skill_level,s.position)-1
 )))));
$$;

-- Keep the existing store/role boundaries and add sequence-aware summaries.
alter function public.get_daily_workspace(uuid) set schema private;
alter function private.get_daily_workspace(uuid) rename to daily_workspace_before_sequence;
revoke all on function private.daily_workspace_before_sequence(uuid) from public,anon,authenticated;
create function public.get_daily_workspace(store uuid) returns jsonb
language plpgsql stable security definer set search_path='' as $$
declare base jsonb; assignments jsonb; modules jsonb; next_id uuid; foundation_count integer; application_count integer; expertise_count integer;
begin
 base:=private.daily_workspace_before_sequence(store);
 select coalesce(jsonb_agg(x.item||jsonb_build_object('sequence_position',s.position,'sequence_level',s.skill_level)
 order by private.daily_ordinal(s.skill_level,s.position),x.item->>'code'),'[]') into modules
 from jsonb_array_elements(base->'modules') x(item) left join public.daily_sequence s on s.module_id=(x.item->>'id')::uuid;
 select coalesce(jsonb_agg(x.item||jsonb_build_object('sequence_position',s.position,'sequence_level',s.skill_level,
 'can_open',private.daily_is_learner((x.item->>'id')::uuid)) order by private.daily_ordinal(s.skill_level,s.position),x.item->>'id'),'[]') into assignments
 from jsonb_array_elements(base->'assignments') x(item) left join public.daily_sequence s on s.module_id=(x.item->>'module_id')::uuid;
 select a.id into next_id from public.daily_assignments a join public.daily_sequence s on s.module_id=a.module_id
 join public.organization_memberships m on m.id=a.membership_id
 where a.organization_id=store and m.user_id=auth.uid() and m.status='active' and a.completed_at is null and private.daily_is_learner(a.id)
 order by private.daily_ordinal(s.skill_level,s.position) limit 1;
 select count(*) filter(where s.skill_level='foundations'),count(*) filter(where s.skill_level='application'),count(*) filter(where s.skill_level='expertise')
 into foundation_count,application_count,expertise_count
 from public.daily_assignments a join public.daily_sequence s on s.module_id=a.module_id
 join public.organization_memberships m on m.id=a.membership_id
 where a.organization_id=store and m.user_id=auth.uid() and m.status='active' and a.completed_at is not null;
 return base||jsonb_build_object('modules',modules,'assignments',assignments,'progression',jsonb_build_object(
 'next_assignment_id',next_id,'completed',jsonb_build_object('foundations',foundation_count,'application',application_count,'expertise',expertise_count),
 'planned',jsonb_build_object('foundations',88,'application',112,'expertise',60),
 'pathway_complete',foundation_count=88 and application_count=112 and expertise_count=60,
 'badge_eligible',foundation_count=88 and application_count=112 and expertise_count=60,
 'badge_issued',false,'automatic_enrollment',true));
end;
$$;
-- Enroll already active members for already released, sequenced modules without resetting records.
do $$declare store uuid;begin
 for store in select distinct organization_id from public.daily_releases loop perform private.enroll_daily_store(store);end loop;
end;$$;
revoke all on function private.daily_ordinal(text,integer),private.freeze_daily_sequence(),private.enroll_daily_store(uuid),private.auto_enroll_daily() from public,anon,authenticated;
revoke all on function public.set_daily_sequence(uuid,integer),public.get_daily_workspace(uuid) from public,anon;
grant execute on function public.set_daily_sequence(uuid,integer),public.get_daily_workspace(uuid) to authenticated;
notify pgrst,'reload schema';
commit;
