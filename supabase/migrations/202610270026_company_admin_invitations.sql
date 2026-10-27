-- Apply once after 025. Company invitations never grant platform or staff roles.
begin;
create table private.company_invitations(
 id uuid primary key default gen_random_uuid(),
 company_id uuid not null references private.companies(id),
 organization_id uuid,
 email text not null,
 invitee_name text not null,
 capability text not null check(capability in ('billing','training','both')),
 invited_by uuid not null references auth.users(id),
 created_at timestamptz not null default now(),
 expires_at timestamptz not null default now()+interval '7 days',
 accepted_at timestamptz,accepted_by uuid references auth.users(id),revoked_at timestamptz,
 email_status text not null default 'pending' check(email_status in ('pending','sent','failed')),
 last_email_attempt_at timestamptz not null default now(),
 foreign key(company_id,organization_id) references private.company_stores(company_id,organization_id)
);
create unique index company_invitation_pending on private.company_invitations(company_id,lower(email)) where accepted_at is null and revoked_at is null;
alter table private.company_invitations enable row level security;
revoke all on private.company_invitations from public,anon,authenticated,service_role;

create function public.prepare_company_invitation(company uuid, account_email text default '',
 person_name text default '', capability text default 'training', store uuid default null,
 replace_invitation uuid default null) returns jsonb
language plpgsql security definer set search_path='' as $$
declare invitation private.company_invitations; target_email text:=lower(btrim(account_email));
begin
 perform 1 from private.companies c where c.id=company for update;
 if not found or not private.can_administer_company(company) then raise exception 'Company owner access required';end if;
 if replace_invitation is not null then
  select i.* into invitation from private.company_invitations i where i.id=replace_invitation and i.company_id=company for update;
  if not found or invitation.accepted_at is not null or invitation.revoked_at is not null then raise exception 'Invitation not available';end if;
  if invitation.last_email_attempt_at>now()-interval '1 minute' then raise exception 'Wait one minute before resending';end if;
  -- Rotate the identifier on resend, invalidating old links while preserving scope.
  update private.company_invitations i set revoked_at=now() where i.id=invitation.id;
  insert into private.company_invitations(company_id,organization_id,email,invitee_name,capability,invited_by)
   values(company,invitation.organization_id,invitation.email,invitation.invitee_name,invitation.capability,auth.uid()) returning * into invitation;
 else
  if capability is null or capability not in ('billing','training','both') then raise exception 'Choose administrator access';end if;
  if target_email is null or length(target_email)>254 or target_email!~'^[^[:space:]@]+@[^[:space:]@]+\.[^[:space:]@]+$' then raise exception 'Enter a valid email address';end if;
  if person_name is null or length(btrim(person_name)) not between 1 and 120 then raise exception 'Enter the administrator name';end if;
  if store is not null and not exists(select 1 from private.company_stores s where s.company_id=company and s.organization_id=store) then raise exception 'Store is not in this company';end if;
  if target_email=(select lower(u.email) from auth.users u where u.id=auth.uid()) then raise exception 'Your account already has owner access';end if;
  update private.company_invitations i set revoked_at=now() where i.company_id=company and lower(i.email)=target_email and i.accepted_at is null and i.revoked_at is null and i.expires_at<=now();
  if exists(select 1 from private.company_invitations i where i.company_id=company and lower(i.email)=target_email and i.accepted_at is null and i.revoked_at is null) then raise exception 'Use the pending invitation to resend or cancel';end if;
  insert into private.company_invitations(company_id,organization_id,email,invitee_name,capability,invited_by)
   values(company,store,target_email,btrim(person_name),capability,auth.uid()) returning * into invitation;
 end if;
 insert into private.company_access_audit(company_id,organization_id,actor_id,event,details)
 values(company,invitation.organization_id,auth.uid(),'administrator_invited',jsonb_build_object('invitation_id',invitation.id,'capability',invitation.capability));
 return jsonb_build_object('id',invitation.id,'email',invitation.email,'name',invitation.invitee_name);
end;
$$;
create function public.record_company_invitation_email(invitation uuid, delivery_status text) returns void
language plpgsql security definer set search_path='' as $$
begin
 if delivery_status is null or delivery_status not in ('sent','failed') then raise exception 'Invalid delivery status';end if;
 update private.company_invitations i set email_status=delivery_status where i.id=invitation and i.accepted_at is null and i.revoked_at is null;
end;
$$;
create function public.revoke_company_invitation(invitation uuid) returns void
language plpgsql security definer set search_path='' as $$
declare company uuid;
begin
 select i.company_id into company from private.company_invitations i where i.id=invitation;
 perform 1 from private.companies c where c.id=company for update;
 if not found or not private.can_administer_company(company) then raise exception 'Company owner access required';end if;
 update private.company_invitations i set revoked_at=now() where i.id=invitation and i.accepted_at is null and i.revoked_at is null;
 insert into private.company_access_audit(company_id,actor_id,event,details) values(company,auth.uid(),'administrator_invitation_revoked',jsonb_build_object('invitation_id',invitation));
end;
$$;
create function public.accept_company_invitation(invitation uuid) returns void
language plpgsql security definer set search_path='' as $$
declare pending private.company_invitations; company uuid; target_email text; capability text;
begin
 if auth.uid() is null then raise exception 'Sign in to accept company access';end if;
 select lower(u.email) into target_email from auth.users u where u.id=auth.uid() and u.email_confirmed_at is not null;
 if target_email is null then raise exception 'Confirm your email first';end if;
 select i.company_id into company from private.company_invitations i where i.id=invitation;
 perform 1 from private.companies c where c.id=company for update;
 select i.* into pending from private.company_invitations i where i.id=invitation for update;
 if not found or pending.email<>target_email or pending.revoked_at is not null then raise exception 'Invitation not available for this account';end if;
 if pending.accepted_at is not null then
  if pending.accepted_by=auth.uid() then return;end if;
  raise exception 'Invitation already used';
 end if;
 if pending.expires_at<=now() then raise exception 'Invitation expired';end if;
 -- An invitation cannot outlive its issuer's ownership/administration authority.
 if not exists(select 1 from private.companies c where c.id=company and c.owner_user_id=pending.invited_by)
  and not exists(select 1 from public.platform_admins a where a.user_id=pending.invited_by) then raise exception 'Ask the current owner for a new invitation';end if;
 if pending.organization_id is not null and not exists(select 1 from private.company_stores s where s.company_id=company and s.organization_id=pending.organization_id) then raise exception 'Store access changed';end if;
 for capability in select unnest(case when pending.capability='both' then array['billing','training'] else array[pending.capability] end) loop
  insert into private.company_permissions(company_id,user_id,permission,organization_id,granted_by)
  values(company,auth.uid(),capability,pending.organization_id,pending.invited_by) on conflict do nothing;
 end loop;
 update private.company_invitations i set accepted_at=now(),accepted_by=auth.uid() where i.id=invitation;
 insert into private.company_access_audit(company_id,organization_id,actor_id,event,details)
 values(company,pending.organization_id,auth.uid(),'administrator_invitation_accepted',jsonb_build_object('capability',pending.capability));
end;
$$;
alter function public.get_company_access_settings(uuid) rename to get_company_access_settings_before_invitations;
revoke all on function public.get_company_access_settings_before_invitations(uuid) from public,anon,authenticated,service_role;
create function public.get_company_access_settings(company uuid) returns jsonb
language plpgsql stable security definer set search_path='' as $$
declare settings jsonb;
begin
 settings:=public.get_company_access_settings_before_invitations(company);
 return settings||jsonb_build_object('invitations',(select coalesce(jsonb_agg(jsonb_build_object('id',i.id,'email',i.email,'invitee_name',i.invitee_name,'capability',i.capability,'organization_id',i.organization_id,'email_status',i.email_status,'expires_at',i.expires_at) order by i.created_at),'[]')
 from private.company_invitations i where i.company_id=company and i.accepted_at is null and i.revoked_at is null));
end;
$$;
revoke all on function public.prepare_company_invitation(uuid,text,text,text,uuid,uuid),public.accept_company_invitation(uuid),public.revoke_company_invitation(uuid),public.get_company_access_settings(uuid) from public,anon,service_role;
grant execute on function public.prepare_company_invitation(uuid,text,text,text,uuid,uuid),public.accept_company_invitation(uuid),public.revoke_company_invitation(uuid),public.get_company_access_settings(uuid) to authenticated;
revoke all on function public.record_company_invitation_email(uuid,text) from public,anon,authenticated;
grant execute on function public.record_company_invitation_email(uuid,text) to service_role;
notify pgrst,'reload schema';
commit;
