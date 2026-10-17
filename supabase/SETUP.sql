-- colTRAIN: run once in a NEW Supabase project. No sample users or passwords are included.
-- 202610170001_accounts.sql
-- colTRAIN account foundation. Run once on a new Supabase project.
-- Public clients can read only what RLS permits. All writes use constrained RPCs.
begin;
create schema if not exists extensions;
create extension if not exists pgcrypto with schema extensions;
create schema if not exists private;
revoke all on schema private from public;
grant usage on schema private to authenticated;

create table public.platform_admins (
  user_id uuid primary key references auth.users(id),
  created_at timestamptz not null default now()
);
create table public.organizations (
  id uuid primary key default gen_random_uuid(),
  name text not null check (length(btrim(name)) between 1 and 120),
  time_zone text not null default 'America/New_York',
  created_at timestamptz not null default now()
);
create table public.profiles (
  user_id uuid primary key references auth.users(id),
  full_name text not null check (length(btrim(full_name)) between 1 and 120),
  optional_email_notifications boolean not null default false,
  updated_at timestamptz not null default now()
);
create table public.organization_memberships (
  id uuid primary key default gen_random_uuid(),
  organization_id uuid not null references public.organizations(id),
  user_id uuid not null references auth.users(id),
  email text not null check (email=lower(btrim(email))),
  role text not null check (role in ('manager','employee')),
  status text not null default 'active' check (status in ('active','inactive')),
  joined_at timestamptz not null default now(),
  deactivated_at timestamptz,
  unique (organization_id,id)
);
-- Historic memberships can remain, but a person has only one active store.
create unique index memberships_one_active_store on public.organization_memberships(user_id) where status='active';
create index memberships_store_lookup on public.organization_memberships(organization_id,user_id,status);
create table public.seats (
  id uuid primary key default gen_random_uuid(),
  organization_id uuid not null references public.organizations(id),
  membership_id uuid unique,
  created_at timestamptz not null default now(),
  unique (organization_id,id),
  foreign key (organization_id,membership_id) references public.organization_memberships(organization_id,id)
);
create table public.invitations (
  id uuid primary key default gen_random_uuid(),
  organization_id uuid not null references public.organizations(id),
  seat_id uuid not null,
  email text not null check (email=lower(btrim(email))),
  role text not null check (role in ('manager','employee')),
  token_hash text not null unique,
  created_by uuid not null references auth.users(id),
  created_at timestamptz not null default now(),
  expires_at timestamptz not null default now()+interval '7 days',
  accepted_by uuid references auth.users(id),
  accepted_at timestamptz,
  revoked_at timestamptz,
  foreign key (organization_id,seat_id) references public.seats(organization_id,id)
);
create unique index invitations_one_pending_per_seat on public.invitations(seat_id) where accepted_at is null and revoked_at is null;
create unique index invitations_one_pending_per_email on public.invitations(organization_id,email) where accepted_at is null and revoked_at is null;
create index invitations_store_lookup on public.invitations(organization_id,created_at);

create function private.is_admin() returns boolean language sql stable security definer set search_path='' as $$
 select exists(select 1 from public.platform_admins where user_id=auth.uid());
$$;
create function private.is_member(store uuid) returns boolean language sql stable security definer set search_path='' as $$
 select exists(select 1 from public.organization_memberships where organization_id=store and user_id=auth.uid() and status='active');
$$;
create function private.can_manage(store uuid) returns boolean language sql stable security definer set search_path='' as $$
 select private.is_admin() or exists(select 1 from public.organization_memberships where organization_id=store and user_id=auth.uid() and status='active' and role='manager');
$$;
create function private.can_view_profile(person uuid) returns boolean language sql stable security definer set search_path='' as $$
 select person=auth.uid() or private.is_admin() or exists(
   select 1 from public.organization_memberships target
   where target.user_id=person and (private.can_manage(target.organization_id) or (
     target.status='active' and private.is_member(target.organization_id)
   ))
 );
$$;
revoke all on all functions in schema private from public;
grant execute on all functions in schema private to authenticated;

alter table public.platform_admins enable row level security;
alter table public.organizations enable row level security;
alter table public.profiles enable row level security;
alter table public.organization_memberships enable row level security;
alter table public.seats enable row level security;
alter table public.invitations enable row level security;
create policy admin_self on public.platform_admins for select to authenticated using (user_id=auth.uid());
create policy store_read on public.organizations for select to authenticated using (private.is_admin() or private.is_member(id));
create policy profile_read on public.profiles for select to authenticated using (private.can_view_profile(user_id));
create policy membership_read on public.organization_memberships for select to authenticated using (user_id=auth.uid() or private.can_manage(organization_id));
create policy seats_read on public.seats for select to authenticated using (private.can_manage(organization_id));
create policy invitations_read on public.invitations for select to authenticated using (private.can_manage(organization_id));

-- Explicit grants avoid inheriting Supabase's broad default table privileges.
revoke all on public.platform_admins,public.organizations,public.profiles,public.organization_memberships,public.seats,public.invitations from anon,authenticated;
grant select on public.platform_admins,public.organizations,public.profiles,public.organization_memberships,public.seats to authenticated;
grant select (id,organization_id,seat_id,email,role,created_by,created_at,expires_at,accepted_by,accepted_at,revoked_at) on public.invitations to authenticated;

create function public.save_my_profile(display_name text, email_notifications boolean default false)
returns void language plpgsql security definer set search_path='' as $$
begin
 if auth.uid() is null then raise exception 'Sign in first'; end if;
 insert into public.profiles(user_id,full_name,optional_email_notifications)
 values(auth.uid(),btrim(display_name),email_notifications)
 on conflict(user_id) do update set full_name=excluded.full_name,optional_email_notifications=excluded.optional_email_notifications,updated_at=now();
end;
$$;
create function public.create_store(store_name text, seat_count integer)
returns uuid language plpgsql security definer set search_path='' as $$
declare store uuid;
begin
 if not private.is_admin() then raise exception 'Administrator access required'; end if;
 if seat_count<1 or seat_count>1000 or seat_count is null then raise exception 'Choose 1 to 1000 seats'; end if;
 insert into public.organizations(name) values(btrim(store_name)) returning id into store;
 insert into public.seats(organization_id) select store from generate_series(1,seat_count);
 return store;
end;
$$;
create function public.create_invitation(store uuid, employee_email text, member_role text default 'employee')
returns table(invitation_id uuid, invitation_code text, expires_at timestamptz)
language plpgsql security definer set search_path='' as $$
declare chosen_seat uuid; code text; target text:=lower(btrim(employee_email));
begin
 if auth.uid() is null or not private.can_manage(store) then raise exception 'Manager access required'; end if;
 if member_role not in ('employee','manager') or member_role is null then raise exception 'Invalid role'; end if;
 if member_role='manager' and not private.is_admin() then raise exception 'Only an administrator can invite a manager'; end if;
 if target is null or length(target)>254 or target !~ '^[^[:space:]@]+@[^[:space:]@]+[.][^[:space:]@]+$' then raise exception 'Enter an email address'; end if;
 -- Reclaim expired reservations. A new invitation never overwrites a valid one.
 update public.invitations i set revoked_at=now() where i.organization_id=store and i.accepted_at is null and i.revoked_at is null and i.expires_at<=now();
 if exists(select 1 from public.invitations i where i.organization_id=store and i.email=target and i.accepted_at is null and i.revoked_at is null) then raise exception 'Revoke the pending invitation before issuing a new code'; end if;
 if exists(select 1 from public.organization_memberships where organization_id=store and email=target and status='active') then raise exception 'This employee is already active'; end if;
 select s.id into chosen_seat from public.seats s where s.organization_id=store and s.membership_id is null
 and not exists(select 1 from public.invitations i where i.seat_id=s.id and i.accepted_at is null and i.revoked_at is null)
 order by s.created_at,s.id for update of s skip locked limit 1;
 if chosen_seat is null then raise exception 'No available seats'; end if;
 code:=upper(encode(extensions.gen_random_bytes(16),'hex'));
 return query insert into public.invitations as i(organization_id,seat_id,email,role,token_hash,created_by)
 values(store,chosen_seat,target,member_role,encode(extensions.digest(code,'sha256'),'hex'),auth.uid())
 returning i.id,code,i.expires_at;
end;
$$;
create function public.revoke_invitation(invitation uuid)
returns void language plpgsql security definer set search_path='' as $$
declare target public.invitations%rowtype;
begin
 select * into target from public.invitations where id=invitation for update;
 if not found or not private.can_manage(target.organization_id) then raise exception 'Invitation not available'; end if;
 if target.accepted_at is not null then raise exception 'This invitation was already used'; end if;
 update public.invitations set revoked_at=now() where id=invitation;
end;
$$;
create function public.accept_invitation(invitation_code text)
returns uuid language plpgsql security definer set search_path='' as $$
declare invite public.invitations%rowtype; verified_email text; member uuid; seat_member uuid;
begin
 if auth.uid() is null then raise exception 'Sign in first'; end if;
 select lower(email) into verified_email from auth.users where id=auth.uid() and email_confirmed_at is not null;
 if verified_email is null then raise exception 'Confirm your email before joining'; end if;
 select * into invite from public.invitations where token_hash=encode(extensions.digest(upper(btrim(invitation_code)),'sha256'),'hex') for update;
 if not found or invite.revoked_at is not null or invite.accepted_at is not null or invite.expires_at<=now() or invite.email<>verified_email then raise exception 'Invitation is invalid, expired, or does not match your verified email'; end if;
 if exists(select 1 from public.organization_memberships where user_id=auth.uid() and status='active') then raise exception 'You already belong to a store'; end if;
 select membership_id into seat_member from public.seats where id=invite.seat_id and organization_id=invite.organization_id for update;
 if seat_member is not null then raise exception 'Seat is not available'; end if;
 insert into public.organization_memberships(organization_id,user_id,email,role) values(invite.organization_id,auth.uid(),verified_email,invite.role) returning id into member;
 update public.seats set membership_id=member where id=invite.seat_id;
 update public.invitations set accepted_by=auth.uid(),accepted_at=now() where id=invite.id;
 return member;
end;
$$;
create function public.reissue_invitation(invitation uuid)
returns table(invitation_id uuid, invitation_code text, expires_at timestamptz)
language plpgsql security definer set search_path='' as $$
declare target public.invitations%rowtype;
begin
 select * into target from public.invitations where id=invitation for update;
 if not found or not private.can_manage(target.organization_id) then raise exception 'Invitation not available'; end if;
 if target.accepted_at is not null then raise exception 'This invitation was already used'; end if;
 if target.role='manager' and not private.is_admin() then raise exception 'Only an administrator can invite a manager'; end if;
 update public.invitations set revoked_at=now() where id=invitation;
 return query select * from public.create_invitation(target.organization_id,target.email,target.role);
end;
$$;
create function public.deactivate_member(member uuid)
returns void language plpgsql security definer set search_path='' as $$
declare target public.organization_memberships%rowtype;
begin
 select * into target from public.organization_memberships where id=member for update;
 if not found or not private.can_manage(target.organization_id) then raise exception 'Member not available'; end if;
 if target.role='manager' and not private.is_admin() then raise exception 'Only an administrator can deactivate a manager'; end if;
 if target.user_id=auth.uid() then raise exception 'You cannot remove yourself'; end if;
 update public.organization_memberships set status='inactive',deactivated_at=now() where id=member;
 update public.seats set membership_id=null where membership_id=member;
end;
$$;
-- No automatic account, profile, organization, or elevated-role provisioning.
-- The first platform administrator must be explicitly appointed in the SQL editor.
revoke all on function public.save_my_profile(text,boolean),public.create_store(text,integer),public.create_invitation(uuid,text,text),public.revoke_invitation(uuid),public.accept_invitation(text),public.reissue_invitation(uuid),public.deactivate_member(uuid) from public,anon;
grant execute on function public.save_my_profile(text,boolean),public.create_store(text,integer),public.create_invitation(uuid,text,text),public.revoke_invitation(uuid),public.accept_invitation(text),public.reissue_invitation(uuid),public.deactivate_member(uuid) to authenticated;
commit;


-- 202610170002_team_media.sql
-- Private Team Corner pictures. Admin status alone never grants feed access.
begin;
insert into storage.buckets(id,name,public,file_size_limit,allowed_mime_types)
values('team-media','team-media',false,1048576,array['image/jpeg','image/png','image/webp']);
create function private.can_read_team_file(object_name text)
returns boolean language sql stable security definer set search_path='' as $$
 select exists(select 1 from public.organization_memberships where user_id=auth.uid() and status='active' and organization_id::text=split_part(object_name,'/',1));
$$;
create function private.can_write_team_file(object_name text)
returns boolean language sql stable security definer set search_path='' as $$
 select private.can_read_team_file(object_name) and split_part(object_name,'/',2)=auth.uid()::text and length(split_part(object_name,'/',3))>0;
$$;
create function private.can_moderate_team_file(object_name text)
returns boolean language sql stable security definer set search_path='' as $$
 select private.can_read_team_file(object_name) and exists(
  select 1 from public.organization_memberships where user_id=auth.uid() and status='active' and role='manager' and organization_id::text=split_part(object_name,'/',1)
 );
$$;
revoke all on function private.can_read_team_file(text),private.can_write_team_file(text),private.can_moderate_team_file(text) from public,anon;
grant execute on function private.can_read_team_file(text),private.can_write_team_file(text),private.can_moderate_team_file(text) to authenticated;
create policy coltrain_team_media_read on storage.objects for select to authenticated
 using(bucket_id='team-media' and private.can_read_team_file(name));
create policy coltrain_team_media_insert on storage.objects for insert to authenticated
 with check(bucket_id='team-media' and private.can_write_team_file(name));
create policy coltrain_team_media_update on storage.objects for update to authenticated
 using(bucket_id='team-media' and (private.can_write_team_file(name) or private.can_moderate_team_file(name)))
 with check(bucket_id='team-media' and (private.can_write_team_file(name) or private.can_moderate_team_file(name)));
create policy coltrain_team_media_delete on storage.objects for delete to authenticated
 using(bucket_id='team-media' and (private.can_write_team_file(name) or private.can_moderate_team_file(name)));
commit;
