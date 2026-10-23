-- Apply once after 022. Company permissions are separate from store membership.
-- This foundation neither charges customers nor changes existing store permissions.
begin;
create table private.companies (
 id uuid primary key default gen_random_uuid(),
 name text not null check(length(btrim(name)) between 1 and 120),
 phone text not null default '' check(length(phone)<=50),
 buying_group text not null default '' check(length(buying_group)<=160),
 owner_user_id uuid references auth.users(id),
 created_at timestamptz not null default now()
);
create table private.company_stores (
 organization_id uuid primary key references public.organizations(id),
 company_id uuid not null references private.companies(id),
 unique(company_id,organization_id)
);
create table private.company_permissions (
 id uuid primary key default gen_random_uuid(),
 company_id uuid not null references private.companies(id),
 user_id uuid not null references auth.users(id),
 permission text not null check(permission in ('billing','training')),
 organization_id uuid,
 granted_by uuid not null references auth.users(id),
 created_at timestamptz not null default now(),
 foreign key(company_id,organization_id) references private.company_stores(company_id,organization_id),
 unique nulls not distinct(company_id,user_id,permission,organization_id)
);
create index company_permissions_person on private.company_permissions(user_id,company_id);
create table private.store_account_terms (
 organization_id uuid primary key references public.organizations(id),
 access_mode text not null default 'legacy_no_charge'
  check(access_mode in ('legacy_no_charge','pilot','awaiting_paid_approval')),
 pilot_started_at timestamptz, pilot_ended_at timestamptz,
 updated_at timestamptz not null default now(),
 check(access_mode<>'pilot' or (pilot_started_at is not null and pilot_ended_at is null))
);
create table private.company_access_audit (
 id bigint generated always as identity primary key,
 company_id uuid not null references private.companies(id),
 organization_id uuid references public.organizations(id),
 actor_id uuid not null references auth.users(id),
 event text not null,
 details jsonb not null default '{}',
 created_at timestamptz not null default clock_timestamp()
);
alter table private.companies enable row level security;
alter table private.company_stores enable row level security;
alter table private.company_permissions enable row level security;
alter table private.store_account_terms enable row level security;
alter table private.company_access_audit enable row level security;
revoke all on private.companies,private.company_stores,private.company_permissions,
 private.store_account_terms,private.company_access_audit from public,anon,authenticated,service_role;
revoke all on sequence private.company_access_audit_id_seq from public,anon,authenticated,service_role;

-- Give every legacy store an independent, unowned company. Do not guess its owner,
-- merge businesses by name/email, change seats, or infer payment obligations.
create function private.attach_store_company() returns trigger
language plpgsql security definer set search_path='' as $$
declare company uuid;
begin
 insert into private.companies(name) values(new.name) returning id into company;
 insert into private.company_stores(organization_id,company_id) values(new.id,company);
 insert into private.store_account_terms(organization_id) values(new.id);
 return new;
end;
$$;
create trigger attach_store_company after insert on public.organizations
 for each row execute function private.attach_store_company();
do $$
declare store record; company uuid;
begin
 for store in select id,name from public.organizations order by id loop
  insert into private.companies(name) values(store.name) returning id into company;
  insert into private.company_stores values(store.id,company);
  insert into private.store_account_terms(organization_id) values(store.id);
 end loop;
end;
$$;

create function private.can_administer_company(company uuid) returns boolean
language sql stable security definer set search_path='' as $$
 select auth.uid() is not null and (private.is_admin() or exists(
  select 1 from private.companies c where c.id=company and c.owner_user_id=auth.uid()));
$$;
create function private.has_company_permission(company uuid, capability text, store uuid) returns boolean
language sql stable security definer set search_path='' as $$
 select auth.uid() is not null and exists(select 1 from private.company_stores s
 where s.company_id=company and s.organization_id=store and (
  private.can_administer_company(company) or exists(select 1 from private.company_permissions p
   where p.company_id=company and p.user_id=auth.uid() and p.permission=capability
    and (p.organization_id is null or p.organization_id=store))));
$$;

-- Only the platform admin can initialize an existing unowned company. Future
-- checkout provisioning will assign its verified purchaser through a separate path.
create function public.admin_initialize_company(store uuid, owner_user uuid, company_name text,
 company_phone text default '', affiliation text default '') returns uuid
language plpgsql security definer set search_path='' as $$
declare company uuid; prior uuid;
begin
 if auth.uid() is null or not private.is_admin() then raise exception 'Administrator access required'; end if;
 select s.company_id into company from private.company_stores s where s.organization_id=store;
 if company is null then raise exception 'Store not available'; end if;
 select c.owner_user_id into prior from private.companies c where c.id=company for update;
 perform 1 from private.company_stores s where s.organization_id=store and s.company_id=company for update;
 if not found then raise exception 'Store company changed; reload and retry'; end if;
 if prior is not null and prior is distinct from owner_user then raise exception 'Use ownership transfer for an owned company'; end if;
 if owner_user is null or not exists(select 1 from auth.users where id=owner_user and email_confirmed_at is not null)
 then raise exception 'Choose a confirmed account'; end if;
 update private.companies set owner_user_id=owner_user,name=btrim(company_name),
  phone=btrim(company_phone),buying_group=btrim(affiliation) where id=company;
 insert into private.company_access_audit(company_id,organization_id,actor_id,event,details)
 values(company,store,auth.uid(),'company_initialized',jsonb_build_object('owner_user_id',owner_user));
 return company;
end;
$$;

create function public.set_company_permission(company uuid, person uuid, capability text,
 enabled boolean, store uuid default null) returns void
language plpgsql security definer set search_path='' as $$
begin
 -- Serialize permission changes with ownership transfer and store linking.
 perform 1 from private.companies c where c.id=company for update;
 if not found or not private.can_administer_company(company) then raise exception 'Company owner access required'; end if;
 if capability is null or capability not in ('billing','training') or enabled is null then raise exception 'Choose billing or training access'; end if;
 if store is not null and not exists(select 1 from private.company_stores s where s.company_id=company and s.organization_id=store)
 then raise exception 'Store is not in this company'; end if;
 if person is null or not exists(select 1 from auth.users where id=person and email_confirmed_at is not null)
 then raise exception 'Choose a confirmed account'; end if;
 if enabled then
  insert into private.company_permissions(company_id,user_id,permission,organization_id,granted_by)
  values(company,person,capability,store,auth.uid()) on conflict do nothing;
 else
  delete from private.company_permissions p where p.company_id=company and p.user_id=person
   and p.permission=capability and p.organization_id is not distinct from store;
 end if;
 insert into private.company_access_audit(company_id,organization_id,actor_id,event,details)
 values(company,store,auth.uid(),'permission_changed',jsonb_build_object('user_id',person,'permission',capability,'enabled',enabled));
end;
$$;

create function public.transfer_company_ownership(company uuid, new_owner uuid) returns void
language plpgsql security definer set search_path='' as $$
declare prior uuid;
begin
 select c.owner_user_id into prior from private.companies c where c.id=company for update;
 if not found or not private.can_administer_company(company) then raise exception 'Company owner access required'; end if;
 if new_owner is null or not exists(select 1 from auth.users where id=new_owner and email_confirmed_at is not null)
 then raise exception 'Choose a confirmed account'; end if;
 if prior=new_owner then return; end if;
 update private.companies set owner_user_id=new_owner where id=company;
 -- Ownership never leaves hidden delegated company access for the previous owner.
 delete from private.company_permissions p where p.company_id=company and p.user_id=prior;
 insert into private.company_access_audit(company_id,actor_id,event,details)
 values(company,auth.uid(),'ownership_transferred',jsonb_build_object('previous_owner',prior,'new_owner',new_owner));
 -- Existing paid store memberships are intentionally unchanged.
end;
$$;

-- Assisted additional locations only. Refuse to merge an already administered
-- company or move it while any permission could follow the store unexpectedly.
create function public.admin_link_company_store(company uuid, store uuid) returns void
language plpgsql security definer set search_path='' as $$
declare source_company uuid;
begin
 if auth.uid() is null or not private.is_admin() then raise exception 'Administrator access required'; end if;
 select s.company_id into source_company from private.company_stores s where s.organization_id=store;
 if source_company is null then raise exception 'Store not available'; end if;
 -- Company locks precede store locks, matching initialization and grant FK checks.
 perform 1 from private.companies c where c.id in(company,source_company) order by c.id for update;
 if not exists(select 1 from private.companies c where c.id=company) then raise exception 'Company not available'; end if;
 perform 1 from private.company_stores s where s.organization_id=store and s.company_id=source_company for update;
 if not found then raise exception 'Store company changed; reload and retry'; end if;
 if source_company=company then return; end if;
 if exists(select 1 from private.companies c where c.id=source_company and c.owner_user_id is not null)
 or exists(select 1 from private.company_permissions p where p.company_id=source_company)
 or (select count(*) from private.company_stores s where s.company_id=source_company)<>1
 then raise exception 'Only an unowned standalone store can be linked'; end if;
 update private.company_stores set company_id=company where organization_id=store;
 insert into private.company_access_audit(company_id,organization_id,actor_id,event,details)
 values(company,store,auth.uid(),'store_linked',jsonb_build_object('previous_company_id',source_company));
 -- Keep the empty source company for audit references; it grants no store access.
end;
$$;

create function public.admin_set_store_pilot(store uuid, enabled boolean, reason text) returns void
language plpgsql security definer set search_path='' as $$
declare company uuid; previous_mode text;
begin
 if auth.uid() is null or not private.is_admin() then raise exception 'Administrator access required'; end if;
 if enabled is null or reason is null or length(btrim(reason)) not between 5 and 500 then raise exception 'Give a reason of 5 to 500 characters'; end if;
 select s.company_id into company from private.company_stores s where s.organization_id=store;
 select t.access_mode into previous_mode from private.store_account_terms t where t.organization_id=store for update;
 if not found then raise exception 'Store not available'; end if;
 if (enabled and previous_mode='pilot') or (not enabled and previous_mode='awaiting_paid_approval') then return; end if;
 if not enabled and previous_mode<>'pilot' then raise exception 'This store is not a pilot'; end if;
 update private.store_account_terms set access_mode=case when enabled then 'pilot' else 'awaiting_paid_approval' end,
  pilot_started_at=case when enabled then now() else pilot_started_at end,
  pilot_ended_at=case when enabled then null else now() end,updated_at=now() where organization_id=store;
 insert into private.company_access_audit(company_id,organization_id,actor_id,event,details)
 values(company,store,auth.uid(),'pilot_changed',jsonb_build_object('previous_mode',previous_mode,'enabled',enabled,'reason',btrim(reason)));
 -- No Stripe API call, subscription, card, or charge is created by this operation.
end;
$$;

create function public.get_my_company_accounts() returns jsonb
language sql stable security definer set search_path='' as $$
 select coalesce(jsonb_agg(jsonb_build_object('company_id',c.id,'name',c.name,
  'is_owner',coalesce(c.owner_user_id=auth.uid(),false),'can_administer',private.can_administer_company(c.id),
  'stores',(select coalesce(jsonb_agg(jsonb_build_object('store_id',o.id,'name',o.name,
   'can_bill',private.has_company_permission(c.id,'billing',o.id),
   'can_oversee_training',private.has_company_permission(c.id,'training',o.id),
   'access_mode',case when private.has_company_permission(c.id,'billing',o.id) then t.access_mode else null end)
   order by o.name,o.id),'[]') from private.company_stores s join public.organizations o on o.id=s.organization_id
   join private.store_account_terms t on t.organization_id=o.id
   where s.company_id=c.id and (private.has_company_permission(c.id,'billing',o.id) or private.has_company_permission(c.id,'training',o.id))))
  order by c.name,c.id),'[]') from private.companies c
 where auth.uid() is not null and exists(select 1 from private.company_stores s where s.company_id=c.id
  and (private.has_company_permission(c.id,'billing',s.organization_id) or private.has_company_permission(c.id,'training',s.organization_id)));
$$;

-- Explicit overview, not a broadening of can_manage/is_member. No employee
-- answers, private conversations, feed content, email addresses, or payment data.
create function public.get_company_training_overview(company uuid, store uuid default null) returns jsonb
language plpgsql stable security definer set search_path='' as $$
declare result jsonb;
begin
 if auth.uid() is null or not exists(select 1 from private.company_stores s where s.company_id=company
  and (store is null or s.organization_id=store) and private.has_company_permission(company,'training',s.organization_id))
 then raise exception 'Company training access required'; end if;
 select coalesce(jsonb_agg(jsonb_build_object('store_id',o.id,'name',o.name,
  'members',(select coalesce(jsonb_agg(jsonb_build_object('membership_id',m.id,'name',coalesce(p.full_name,'Team member'),
   'role',m.role,'status',m.status,'points',private.learner_point_totals(m.user_id),
   'assigned_courses',(select count(*) from public.training_assignments a where a.membership_id=m.id),
   'completed_courses',(select count(*) from public.training_assignments a where a.membership_id=m.id and a.completed_at is not null),
   'completed_drills',(select count(*) from public.daily_assignments a where a.membership_id=m.id and a.completed_at is not null))
   order by coalesce(p.full_name,'Team member'),m.id),'[]') from public.organization_memberships m
   left join public.profiles p on p.user_id=m.user_id where m.organization_id=o.id and m.status='active')) order by o.name,o.id),'[]')
 into result from private.company_stores s join public.organizations o on o.id=s.organization_id
 where s.company_id=company and (store is null or s.organization_id=store)
 and private.has_company_permission(company,'training',s.organization_id);
 return jsonb_build_object('company_id',company,'stores',result);
end;
$$;

create function public.get_company_access_settings(company uuid) returns jsonb
language plpgsql stable security definer set search_path='' as $$
begin
 if not private.can_administer_company(company) or not exists(select 1 from private.companies c where c.id=company)
 then raise exception 'Company owner access required'; end if;
 return jsonb_build_object('company',(select to_jsonb(c) from private.companies c where c.id=company),
  'permissions',(select coalesce(jsonb_agg(to_jsonb(p) order by p.created_at,p.id),'[]') from private.company_permissions p where p.company_id=company),
  'audit',(select coalesce(jsonb_agg(to_jsonb(a) order by a.id desc),'[]') from
   (select * from private.company_access_audit where company_id=company order by id desc limit 100) a));
end;
$$;

revoke all on function private.attach_store_company(),private.can_administer_company(uuid),
 private.has_company_permission(uuid,text,uuid) from public,anon,authenticated,service_role;
revoke all on function public.admin_initialize_company(uuid,uuid,text,text,text),
 public.set_company_permission(uuid,uuid,text,boolean,uuid),public.transfer_company_ownership(uuid,uuid),
 public.admin_link_company_store(uuid,uuid),public.admin_set_store_pilot(uuid,boolean,text),
 public.get_my_company_accounts(),public.get_company_training_overview(uuid,uuid),
 public.get_company_access_settings(uuid) from public,anon,service_role;
grant execute on function public.admin_initialize_company(uuid,uuid,text,text,text),
 public.set_company_permission(uuid,uuid,text,boolean,uuid),public.transfer_company_ownership(uuid,uuid),
 public.admin_link_company_store(uuid,uuid),public.admin_set_store_pilot(uuid,boolean,text),
 public.get_my_company_accounts(),public.get_company_training_overview(uuid,uuid),
 public.get_company_access_settings(uuid) to authenticated;
notify pgrst,'reload schema';
commit;
