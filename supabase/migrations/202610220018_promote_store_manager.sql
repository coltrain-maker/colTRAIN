-- Apply once after 017. A store manager may promote active employees in their own store; platform admins may support any store.
begin;
create table private.store_role_changes (
 id uuid primary key default gen_random_uuid(),
 organization_id uuid not null references public.organizations(id), membership_id uuid not null,
 changed_by uuid not null references auth.users(id),
 previous_role text not null check(previous_role='employee'),new_role text not null check(new_role='manager'),
 changed_at timestamptz not null default clock_timestamp(),
 foreign key(organization_id,membership_id) references public.organization_memberships(organization_id,id)
);
alter table private.store_role_changes enable row level security;
revoke all on private.store_role_changes from public,anon,authenticated;
create function public.promote_store_manager(member uuid) returns jsonb
language plpgsql security definer set search_path='' as $$
declare target public.organization_memberships%rowtype;
begin
 select * into target from public.organization_memberships where id=member for update;
 if auth.uid() is null or not found or not private.can_manage(target.organization_id) then raise exception 'Manager access required for this store'; end if;
 if target.status<>'active' then raise exception 'Choose an active store member'; end if;
 if target.role='manager' then return jsonb_build_object('changed',false,'role','manager'); end if;
 update public.organization_memberships set role='manager' where id=member;
 insert into private.store_role_changes(organization_id,membership_id,changed_by,previous_role,new_role)
 values(target.organization_id,target.id,auth.uid(),'employee','manager');
 return jsonb_build_object('changed',true,'role','manager');
end;
$$;
revoke all on function public.promote_store_manager(uuid) from public,anon;
grant execute on function public.promote_store_manager(uuid) to authenticated;
notify pgrst,'reload schema';
commit;
