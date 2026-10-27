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


-- 202610170003_email_invitations.sql
begin;
alter table public.invitations
 add column invitee_name text not null default '' check(length(btrim(invitee_name))<=120),
 add column email_status text not null default 'not_sent' check(email_status in ('not_sent','pending','sent','failed')),
 add column last_email_attempt_at timestamptz;
create index invitation_email_attempts on public.invitations(organization_id,email,last_email_attempt_at desc);
grant select(invitee_name,email_status,last_email_attempt_at) on public.invitations to authenticated;

-- Use the same locked, email-bound seat claim for manual codes and email links.
-- An invitation ID is not a credential: the signed-in, confirmed email must match.
create function private.consume_invitation(invitation uuid)
returns uuid language plpgsql security definer set search_path='' as $$
declare invite public.invitations%rowtype; verified_email text; member uuid; seat_member uuid;
begin
 if auth.uid() is null then raise exception 'Sign in first'; end if;
 select lower(email) into verified_email from auth.users where id=auth.uid() and email_confirmed_at is not null;
 if verified_email is null then raise exception 'Confirm your email before joining'; end if;
 select * into invite from public.invitations where id=invitation for update;
 if not found or invite.revoked_at is not null or invite.accepted_at is not null or invite.expires_at<=now() or invite.email<>verified_email then raise exception 'Invitation is invalid, expired, or does not match your verified email'; end if;
 if exists(select 1 from public.organization_memberships where user_id=auth.uid() and status='active') then raise exception 'You already belong to a store'; end if;
 select membership_id into seat_member from public.seats where id=invite.seat_id and organization_id=invite.organization_id for update;
 if seat_member is not null then raise exception 'Seat is not available'; end if;
 insert into public.organization_memberships(organization_id,user_id,email,role) values(invite.organization_id,auth.uid(),verified_email,invite.role) returning id into member;
 update public.seats set membership_id=member where id=invite.seat_id;
 update public.invitations set accepted_by=auth.uid(),accepted_at=now() where id=invite.id;
 if length(btrim(invite.invitee_name))>0 then
  insert into public.profiles(user_id,full_name) values(auth.uid(),btrim(invite.invitee_name)) on conflict(user_id) do nothing;
 end if;
 return member;
end;
$$;
revoke all on function private.consume_invitation(uuid) from public,anon,authenticated;
create or replace function public.accept_invitation(invitation_code text)
returns uuid language plpgsql security definer set search_path='' as $$
declare invitation uuid;
begin
 select id into invitation from public.invitations where token_hash=encode(extensions.digest(upper(btrim(invitation_code)),'sha256'),'hex');
 return private.consume_invitation(invitation);
end;
$$;
create function public.accept_email_invitation(invitation uuid)
returns uuid language sql security definer set search_path='' as $$
 select private.consume_invitation(invitation);
$$;

create or replace function public.reissue_invitation(invitation uuid)
returns table(invitation_id uuid, invitation_code text, expires_at timestamptz)
language plpgsql security definer set search_path='' as $$
declare target public.invitations%rowtype; replacement record;
begin
 select * into target from public.invitations where id=invitation for update;
 if not found or not private.can_manage(target.organization_id) then raise exception 'Invitation not available'; end if;
 if target.accepted_at is not null then raise exception 'This invitation was already used'; end if;
 if target.role='manager' and not private.is_admin() then raise exception 'Only an administrator can invite a manager'; end if;
 update public.invitations set revoked_at=now() where id=invitation;
 select * into replacement from public.create_invitation(target.organization_id,target.email,target.role);
 update public.invitations set invitee_name=target.invitee_name where id=replacement.invitation_id;
 return query select replacement.invitation_id,replacement.invitation_code,replacement.expires_at;
end;
$$;

-- Called with the manager's JWT, never the server's elevated role.
-- The returned ID alone cannot claim a seat or create an Auth session.
create function public.prepare_employee_invitation(store uuid, employee_email text, employee_name text, member_role text default 'employee', replace_invitation uuid default null)
returns table(invitation_id uuid,email text,invitee_name text,expires_at timestamptz)
language plpgsql security definer set search_path='' as $$
declare target public.invitations%rowtype; prepared record; normalized_email text:=lower(btrim(employee_email)); name text:=btrim(employee_name);
begin
 if auth.uid() is null or not private.can_manage(store) then raise exception 'Manager access required'; end if;
 if replace_invitation is not null then
  select * into target from public.invitations where id=replace_invitation;
  if not found or target.organization_id<>store then raise exception 'Invitation not available'; end if;
  normalized_email:=target.email; name:=target.invitee_name;
 end if;
 if name is null or length(name) not between 1 and 120 then raise exception 'Enter the employee name'; end if;
 -- Serialize email attempts per store/address, including revoked invitations.
 perform pg_advisory_xact_lock(hashtextextended(store::text||':'||normalized_email,0));
 if exists(select 1 from public.invitations i where i.organization_id=store and i.email=normalized_email and i.last_email_attempt_at>now()-interval '60 seconds') then raise exception 'Wait one minute before sending another invitation'; end if;
 if replace_invitation is null then
  select * into prepared from public.create_invitation(store,normalized_email,member_role);
 else
  select * into prepared from public.reissue_invitation(replace_invitation);
 end if;
 update public.invitations i set invitee_name=name,email_status='pending',last_email_attempt_at=now() where i.id=prepared.invitation_id;
 return query select i.id,i.email,i.invitee_name,i.expires_at from public.invitations i where i.id=prepared.invitation_id;
end;
$$;
revoke all on function public.accept_email_invitation(uuid),public.prepare_employee_invitation(uuid,text,text,text,uuid) from public,anon;
grant execute on function public.accept_email_invitation(uuid),public.prepare_employee_invitation(uuid,text,text,text,uuid) to authenticated;
commit;


-- 202610170004_invitation_email_results.sql
begin;
-- BYPASSRLS does not grant table privileges. Expose only this delivery-status
-- operation to the server, without granting browser users direct table writes.
create function public.record_invitation_email_result(invitation uuid, delivery_status text)
returns void language plpgsql security definer set search_path='' as $$
begin
 if delivery_status is null or delivery_status not in ('sent','failed') then
  raise exception 'Invalid delivery status';
 end if;
 update public.invitations
 set email_status=delivery_status
 where id=invitation and email_status='pending'
   and accepted_at is null and revoked_at is null;
end;
$$;
revoke all on function public.record_invitation_email_result(uuid,text) from public,anon,authenticated;
grant execute on function public.record_invitation_email_result(uuid,text) to service_role;
commit;


-- 202610170005_training.sql
-- Step 3: apply once after the account and invitation migrations.
begin;
create table public.training_courses (
 id uuid primary key default gen_random_uuid(), slug text not null, version integer not null default 1 check(version>0),
 title text not null check(length(btrim(title))>0), description text not null default '', category text not null default '',
 owner_organization_id uuid references public.organizations(id), published boolean not null default false,
 passing_percent integer not null default 80 check(passing_percent between 1 and 100), created_at timestamptz not null default now(),
 unique(slug,version)
);
create table public.training_course_releases (
 organization_id uuid not null references public.organizations(id), course_id uuid not null references public.training_courses(id),
 released_by uuid not null references auth.users(id), released_at timestamptz not null default now(), primary key(organization_id,course_id)
);
create table public.training_lessons (
 id uuid primary key default gen_random_uuid(), course_id uuid not null references public.training_courses(id),
 position integer not null check(position>0), title text not null, body jsonb not null check(jsonb_typeof(body)='array'),
 unique(course_id,position), unique(id,course_id)
);
create table public.training_questions (
 id uuid primary key default gen_random_uuid(), course_id uuid not null references public.training_courses(id),
 position integer not null check(position>0), prompt text not null,
 options jsonb not null check(jsonb_typeof(options)='array' and jsonb_array_length(options) between 2 and 10),
 unique(course_id,position), unique(id,course_id)
);
create table private.training_answer_keys (
 question_id uuid primary key references public.training_questions(id), correct_option integer not null check(correct_option>=0), explanation text not null
);
create table public.training_departments (
 id uuid primary key default gen_random_uuid(), organization_id uuid not null references public.organizations(id),
 name text not null check(length(btrim(name)) between 1 and 100), unique(id,organization_id)
);
create unique index training_department_names on public.training_departments(organization_id,lower(name));
create table public.training_member_departments (
 organization_id uuid not null references public.organizations(id), membership_id uuid not null, department_id uuid not null,
 primary key(membership_id,department_id),
 foreign key(organization_id,membership_id) references public.organization_memberships(organization_id,id),
 foreign key(department_id,organization_id) references public.training_departments(id,organization_id)
);
create table public.training_assignments (
 id uuid primary key default gen_random_uuid(), organization_id uuid not null references public.organizations(id),
 membership_id uuid not null, course_id uuid not null references public.training_courses(id),
 due_date date not null, assigned_at timestamptz not null default now(), assigned_by uuid not null references auth.users(id),
 started_at timestamptz, completed_at timestamptz, attempt_limit integer not null default 3 check(attempt_limit>=3),
 unique(membership_id,course_id), unique(id,course_id),
 foreign key(organization_id,membership_id) references public.organization_memberships(organization_id,id)
);
create index training_assignments_store on public.training_assignments(organization_id,membership_id);
create table public.training_lesson_completions (
 assignment_id uuid not null, course_id uuid not null, lesson_id uuid not null, completed_at timestamptz not null default now(),
 primary key(assignment_id,lesson_id), foreign key(assignment_id,course_id) references public.training_assignments(id,course_id),
 foreign key(lesson_id,course_id) references public.training_lessons(id,course_id)
);
create table public.training_attempts (
 id uuid primary key default gen_random_uuid(), assignment_id uuid not null references public.training_assignments(id),
 attempt_number integer not null check(attempt_number>0), submission_key uuid not null,
 correct_count integer not null, question_count integer not null check(question_count>0), score integer not null check(score between 0 and 100),
 passed boolean not null, new_points integer not null default 0, submitted_at timestamptz not null default now(),
 unique(assignment_id,attempt_number), unique(assignment_id,submission_key)
);
create table private.training_attempt_answers (
 attempt_id uuid not null references public.training_attempts(id), question_id uuid not null references public.training_questions(id),
 selected_option integer not null, is_correct boolean not null, primary key(attempt_id,question_id)
);
create table private.training_point_awards (
 user_id uuid not null references auth.users(id), question_id uuid not null references public.training_questions(id),
 course_id uuid not null references public.training_courses(id), assignment_id uuid not null references public.training_assignments(id),
 points integer not null default 10 check(points=10), earned_at timestamptz not null default now(), primary key(user_id,question_id)
);
create table public.training_trophies (
 id uuid primary key default gen_random_uuid(), user_id uuid not null references auth.users(id), course_id uuid not null references public.training_courses(id),
 assignment_id uuid not null references public.training_assignments(id), awarded_at timestamptz not null default now(), unique(user_id,course_id)
);
create table public.training_retry_unlocks (
 id uuid primary key default gen_random_uuid(), assignment_id uuid not null references public.training_assignments(id),
 unlocked_by uuid not null references auth.users(id), reason text not null check(length(btrim(reason)) between 5 and 500),
 attempt_limit_after integer not null, created_at timestamptz not null default now(), unique(assignment_id,attempt_limit_after)
);

create function private.can_view_training_assignment(assignment uuid)
returns boolean language sql stable security definer set search_path='' as $$
 select exists(select 1 from public.training_assignments a join public.organization_memberships m on m.id=a.membership_id
 where a.id=assignment and (private.can_manage(a.organization_id) or (m.user_id=auth.uid() and m.status='active')));
$$;
create function private.can_read_training_course(course uuid)
returns boolean language sql stable security definer set search_path='' as $$
 select private.is_admin() or exists(select 1 from public.training_courses c where c.id=course and (
 (c.owner_organization_id is not null and private.can_manage(c.owner_organization_id)) or
 (c.published and exists(select 1 from public.training_course_releases r where r.course_id=c.id and private.is_member(r.organization_id))) or
 exists(select 1 from public.training_assignments a join public.organization_memberships m on m.id=a.membership_id
 where a.course_id=c.id and ((m.user_id=auth.uid() and m.status='active') or private.can_manage(a.organization_id)))
 ));
$$;
revoke all on function private.can_view_training_assignment(uuid),private.can_read_training_course(uuid) from public,anon;
grant execute on function private.can_view_training_assignment(uuid),private.can_read_training_course(uuid) to authenticated;

alter table public.training_courses enable row level security;
alter table public.training_course_releases enable row level security;
alter table public.training_lessons enable row level security;
alter table public.training_questions enable row level security;
alter table public.training_departments enable row level security;
alter table public.training_member_departments enable row level security;
alter table public.training_assignments enable row level security;
alter table public.training_lesson_completions enable row level security;
alter table public.training_attempts enable row level security;
alter table public.training_trophies enable row level security;
alter table public.training_retry_unlocks enable row level security;
create policy training_courses_read on public.training_courses for select to authenticated using(private.can_read_training_course(id));
create policy training_releases_read on public.training_course_releases for select to authenticated using(private.can_manage(organization_id) or private.is_member(organization_id));
create policy training_lessons_read on public.training_lessons for select to authenticated using(private.can_read_training_course(course_id));
create policy training_questions_read on public.training_questions for select to authenticated using(private.can_read_training_course(course_id));
create policy training_departments_read on public.training_departments for select to authenticated using(private.can_manage(organization_id) or private.is_member(organization_id));
create policy training_member_departments_read on public.training_member_departments for select to authenticated using(private.can_manage(organization_id) or exists(select 1 from public.organization_memberships m where m.id=membership_id and m.user_id=auth.uid() and m.status='active'));
create policy training_assignments_read on public.training_assignments for select to authenticated using(private.can_view_training_assignment(id));
create policy training_lesson_completions_read on public.training_lesson_completions for select to authenticated using(private.can_view_training_assignment(assignment_id));
create policy training_attempts_read on public.training_attempts for select to authenticated using(private.can_view_training_assignment(assignment_id));
create policy training_trophies_read on public.training_trophies for select to authenticated using(private.can_view_training_assignment(assignment_id));
create policy training_retry_unlocks_read on public.training_retry_unlocks for select to authenticated using(private.can_view_training_assignment(assignment_id));
revoke all on public.training_courses,public.training_course_releases,public.training_lessons,public.training_questions,public.training_departments,public.training_member_departments,public.training_assignments,public.training_lesson_completions,public.training_attempts,public.training_trophies,public.training_retry_unlocks from anon,authenticated;
grant select on public.training_courses,public.training_course_releases,public.training_lessons,public.training_questions,public.training_departments,public.training_member_departments,public.training_assignments,public.training_lesson_completions,public.training_attempts,public.training_trophies,public.training_retry_unlocks to authenticated;
revoke all on private.training_answer_keys,private.training_attempt_answers,private.training_point_awards from public,anon,authenticated;

create function public.release_training_course(store uuid, course uuid, available boolean default true)
returns void language plpgsql security definer set search_path='' as $$
begin
 if not private.is_admin() then raise exception 'Administrator access required'; end if;
 if not exists(select 1 from public.training_courses where id=course and published and (owner_organization_id is null or owner_organization_id=store)) then raise exception 'Published course not available'; end if;
 if available then
  insert into public.training_course_releases(organization_id,course_id,released_by) values(store,course,auth.uid()) on conflict do nothing;
 else delete from public.training_course_releases where organization_id=store and course_id=course;
 end if;
end;
$$;
create function public.create_training_department(store uuid, department_name text)
returns uuid language plpgsql security definer set search_path='' as $$
declare department uuid;
begin
 if not private.can_manage(store) then raise exception 'Manager access required'; end if;
 insert into public.training_departments(organization_id,name) values(store,btrim(department_name)) returning id into department;
 return department;
end;
$$;
create function public.set_training_departments(member uuid, departments uuid[])
returns void language plpgsql security definer set search_path='' as $$
declare target public.organization_memberships%rowtype;
begin
 select * into target from public.organization_memberships where id=member for update;
 if not found or not private.can_manage(target.organization_id) then raise exception 'Manager access required'; end if;
 if exists(select 1 from unnest(coalesce(departments,'{}'::uuid[])) d where d is null or not exists(select 1 from public.training_departments where id=d and organization_id=target.organization_id)) then raise exception 'Department is not in this store'; end if;
 delete from public.training_member_departments where membership_id=member;
 insert into public.training_member_departments(organization_id,membership_id,department_id) select target.organization_id,member,d from (select distinct unnest(coalesce(departments,'{}'::uuid[])) d) selected;
end;
$$;
create function public.assign_training(course uuid, store uuid, employee_ids uuid[] default '{}', department_ids uuid[] default '{}', all_employees boolean default false, deadline date default null)
returns integer language plpgsql security definer set search_path='' as $$
declare assigned_count integer; target_date date;
begin
 if auth.uid() is null or not private.can_manage(store) then raise exception 'Manager access required'; end if;
 if not exists(select 1 from public.training_course_releases r join public.training_courses c on c.id=r.course_id where r.organization_id=store and r.course_id=course and c.published) then raise exception 'Release this course to the store before assigning it'; end if;
 if not exists(select 1 from public.training_lessons where course_id=course) or not exists(select 1 from public.training_questions where course_id=course) or exists(select 1 from public.training_questions q left join private.training_answer_keys k on k.question_id=q.id where q.course_id=course and (k.question_id is null or k.correct_option>=jsonb_array_length(q.options))) then raise exception 'Course content is not ready for assignment'; end if;
 if exists(select 1 from unnest(coalesce(employee_ids,'{}'::uuid[])) e where e is null or not exists(select 1 from public.organization_memberships where id=e and organization_id=store and status='active')) then raise exception 'Employee is not active in this store'; end if;
 if exists(select 1 from unnest(coalesce(department_ids,'{}'::uuid[])) d where d is null or not exists(select 1 from public.training_departments where id=d and organization_id=store)) then raise exception 'Department is not in this store'; end if;
 select coalesce(deadline,(now() at time zone time_zone)::date+30) into target_date from public.organizations where id=store;
 insert into public.training_assignments(organization_id,membership_id,course_id,due_date,assigned_by)
 select store,m.id,course,target_date,auth.uid() from public.organization_memberships m
 where m.organization_id=store and m.status='active' and (
 (coalesce(all_employees,false) and m.role='employee') or m.id=any(coalesce(employee_ids,'{}'::uuid[])) or exists(select 1 from public.training_member_departments d where d.membership_id=m.id and d.department_id=any(coalesce(department_ids,'{}'::uuid[]))))
 on conflict(membership_id,course_id) do update set due_date=excluded.due_date;
 get diagnostics assigned_count=row_count;
 if assigned_count=0 then raise exception 'Choose at least one active employee or populated department'; end if;
 return assigned_count;
end;
$$;
create function public.complete_training_lesson(assignment uuid, lesson uuid)
returns void language plpgsql security definer set search_path='' as $$
declare target public.training_assignments%rowtype; lesson_position integer;
begin
 select a.* into target from public.training_assignments a join public.organization_memberships m on m.id=a.membership_id
 where a.id=assignment and m.user_id=auth.uid() and m.status='active' for update of a;
 if not found then raise exception 'Active course assignment required'; end if;
 select position into lesson_position from public.training_lessons where id=lesson and course_id=target.course_id;
 if not found then raise exception 'Lesson is not in this course'; end if;
 if exists(select 1 from public.training_lessons l where l.course_id=target.course_id and l.position<lesson_position and not exists(select 1 from public.training_lesson_completions d where d.assignment_id=assignment and d.lesson_id=l.id)) then raise exception 'Complete the earlier lessons first'; end if;
 insert into public.training_lesson_completions(assignment_id,course_id,lesson_id) values(assignment,target.course_id,lesson) on conflict do nothing;
 update public.training_assignments set started_at=coalesce(started_at,now()) where id=assignment;
end;
$$;
create function private.training_attempt_result(attempt public.training_attempts)
returns jsonb language sql stable security definer set search_path='' as $$
 select to_jsonb(attempt)||jsonb_build_object('attempts_used',(select count(*) from public.training_attempts where assignment_id=attempt.assignment_id),'attempt_limit',a.attempt_limit,'course_points',coalesce((select sum(p.points) from private.training_point_awards p join public.organization_memberships m on m.user_id=p.user_id where m.id=a.membership_id and p.course_id=a.course_id),0),'trophy_earned',exists(select 1 from public.training_trophies t join public.organization_memberships m on m.user_id=t.user_id where m.id=a.membership_id and t.course_id=a.course_id)) from public.training_assignments a where a.id=attempt.assignment_id;
$$;
revoke all on function private.training_attempt_result(public.training_attempts) from public,anon,authenticated;
create function public.submit_training_quiz(assignment uuid, answers jsonb, submission uuid)
returns jsonb language plpgsql security definer set search_path='' as $$
declare target public.training_assignments%rowtype; learner uuid; question_total integer; correct_total integer; used integer; attempt public.training_attempts%rowtype; points_added integer; passed_quiz boolean;
begin
 -- Lock the assignment before checking attempts or awarding anything.
 select a.* into target from public.training_assignments a join public.organization_memberships m on m.id=a.membership_id
 where a.id=assignment and m.user_id=auth.uid() and m.status='active' for update of a;
 if not found then raise exception 'Active course assignment required'; end if;
 learner:=auth.uid();
 if submission is null then raise exception 'A submission identifier is required'; end if;
 select * into attempt from public.training_attempts where assignment_id=assignment and submission_key=submission;
 if found then return private.training_attempt_result(attempt); end if;
 if target.completed_at is not null then raise exception 'This course is already passed'; end if;
 if exists(select 1 from public.training_lessons l where l.course_id=target.course_id and not exists(select 1 from public.training_lesson_completions d where d.assignment_id=assignment and d.lesson_id=l.id)) then raise exception 'Complete all lessons before taking the quiz'; end if;
 select count(*) into question_total from public.training_questions where course_id=target.course_id;
 if question_total=0 or jsonb_typeof(answers) is distinct from 'array' then raise exception 'Answer every quiz question'; end if;
 if jsonb_array_length(answers)<>question_total or (select count(distinct x->>'question_id') from jsonb_array_elements(answers) x)<>question_total then raise exception 'Answer every quiz question exactly once'; end if;
 if exists(select 1 from jsonb_array_elements(answers) x where jsonb_typeof(x) is distinct from 'object' or jsonb_typeof(x->'option') is distinct from 'number' or coalesce(x->>'option','') !~ '^[0-9]{1,2}$' or not exists(select 1 from public.training_questions q where q.course_id=target.course_id and q.id::text=x->>'question_id' and (x->>'option')::integer<jsonb_array_length(q.options))) then raise exception 'Invalid question or answer option'; end if;
 select count(*) into used from public.training_attempts where assignment_id=assignment;
 if used>=target.attempt_limit then raise exception 'Ask your manager to unlock another attempt'; end if;
 select count(*) into correct_total from jsonb_array_elements(answers) x join private.training_answer_keys k on k.question_id::text=x->>'question_id' where k.correct_option=(x->>'option')::integer;
 select correct_total*100>=passing_percent*question_total into passed_quiz from public.training_courses where id=target.course_id;
 insert into public.training_attempts(assignment_id,attempt_number,submission_key,correct_count,question_count,score,passed) values(assignment,used+1,submission,correct_total,question_total,correct_total*100/question_total,passed_quiz) returning * into attempt;
 insert into private.training_attempt_answers(attempt_id,question_id,selected_option,is_correct)
 select attempt.id,q.id,(x->>'option')::integer,k.correct_option=(x->>'option')::integer from jsonb_array_elements(answers) x join public.training_questions q on q.id::text=x->>'question_id' join private.training_answer_keys k on k.question_id=q.id;
 insert into private.training_point_awards(user_id,question_id,course_id,assignment_id)
 select learner,q.id,target.course_id,assignment from jsonb_array_elements(answers) x join public.training_questions q on q.id::text=x->>'question_id' join private.training_answer_keys k on k.question_id=q.id where k.correct_option=(x->>'option')::integer on conflict(user_id,question_id) do nothing;
 get diagnostics points_added=row_count;
 update public.training_attempts set new_points=points_added*10 where id=attempt.id returning * into attempt;
 update public.training_assignments set started_at=coalesce(started_at,now()),completed_at=case when passed_quiz then now() else completed_at end where id=assignment;
 if passed_quiz then insert into public.training_trophies(user_id,course_id,assignment_id) values(learner,target.course_id,assignment) on conflict(user_id,course_id) do nothing; end if;
 return private.training_attempt_result(attempt);
end;
$$;
create function public.get_training_attempt_review(attempt uuid)
returns jsonb language plpgsql stable security definer set search_path='' as $$
begin
 if not exists(select 1 from public.training_attempts t join public.training_assignments a on a.id=t.assignment_id join public.organization_memberships m on m.id=a.membership_id where t.id=attempt and m.user_id=auth.uid() and m.status='active') then raise exception 'Only the active learner can review their answers'; end if;
 return (select coalesce(jsonb_agg(jsonb_build_object('question_id',q.id,'prompt',q.prompt,'options',q.options,'selected_option',x.selected_option,'is_correct',x.is_correct,'correct_option',k.correct_option,'explanation',k.explanation) order by q.position),'[]'::jsonb) from private.training_attempt_answers x join public.training_questions q on q.id=x.question_id join private.training_answer_keys k on k.question_id=q.id where x.attempt_id=attempt);
end;
$$;
create function public.unlock_training_retry(assignment uuid, support_note text)
returns integer language plpgsql security definer set search_path='' as $$
declare target public.training_assignments%rowtype; next_limit integer;
begin
 select * into target from public.training_assignments where id=assignment for update;
 if not found or not private.can_manage(target.organization_id) then raise exception 'Manager access required'; end if;
 if target.completed_at is not null then raise exception 'This course is already passed'; end if;
 if not exists(select 1 from public.organization_memberships where id=target.membership_id and status='active') then raise exception 'Employee is no longer active'; end if;
 if (select count(*) from public.training_attempts where assignment_id=assignment)<target.attempt_limit then raise exception 'An attempt is still available'; end if;
 if support_note is null or length(btrim(support_note)) not between 5 and 500 then raise exception 'Add a short note about the help you provided'; end if;
 update public.training_assignments set attempt_limit=attempt_limit+1 where id=assignment returning attempt_limit into next_limit;
 insert into public.training_retry_unlocks(assignment_id,unlocked_by,reason,attempt_limit_after) values(assignment,auth.uid(),btrim(support_note),next_limit);
 return next_limit;
end;
$$;
create function public.get_training_question_alerts(store uuid default null)
returns jsonb language plpgsql stable security definer set search_path='' as $$
begin
 if store is null then
  if not private.is_admin() then raise exception 'Administrator access required'; end if;
 elsif not private.can_manage(store) then raise exception 'Manager access required'; end if;
 return (select coalesce(jsonb_agg(to_jsonb(alert)),'[]'::jsonb) from (
 select q.id question_id,q.prompt,c.title course_title,count(distinct m.user_id) missed_count
 from private.training_attempt_answers x join public.training_attempts t on t.id=x.attempt_id
 join public.training_assignments a on a.id=t.assignment_id join public.organization_memberships m on m.id=a.membership_id
 join public.training_questions q on q.id=x.question_id join public.training_courses c on c.id=q.course_id
 where t.attempt_number=1 and not x.is_correct and m.role='employee' and (store is null or a.organization_id=store)
 group by q.id,q.prompt,c.title having count(distinct m.user_id)>=3 order by count(distinct m.user_id) desc,q.id) alert);
end;
$$;
create function public.get_training_workspace(store uuid)
returns jsonb language plpgsql stable security definer set search_path='' as $$
declare managing boolean; roster jsonb; courses jsonb; assignments jsonb; departments jsonb; mine uuid;
begin
 if auth.uid() is null or not (private.is_admin() or private.is_member(store)) then raise exception 'Active store access required'; end if;
 managing:=private.can_manage(store);
 select id into mine from public.organization_memberships where organization_id=store and user_id=auth.uid() and status='active';
 select coalesce(jsonb_agg(jsonb_build_object('id',m.id,'name',coalesce(p.full_name,split_part(m.email,'@',1)),'email',case when managing then m.email else null end,'role',m.role,'status',m.status,'departments',coalesce((select jsonb_agg(d.department_id) from public.training_member_departments d where d.membership_id=m.id),'[]'::jsonb),'lifetime_points',coalesce((select sum(points) from private.training_point_awards where user_id=m.user_id),0)) order by coalesce(p.full_name,m.email)),'[]'::jsonb) into roster from public.organization_memberships m left join public.profiles p on p.user_id=m.user_id where m.organization_id=store and (managing or m.id=mine);
 select coalesce(jsonb_agg(to_jsonb(c)||jsonb_build_object('released',exists(select 1 from public.training_course_releases r where r.organization_id=store and r.course_id=c.id),'lesson_count',(select count(*) from public.training_lessons where course_id=c.id),'question_count',(select count(*) from public.training_questions where course_id=c.id)) order by c.title),'[]'::jsonb) into courses from public.training_courses c where (private.is_admin() and (c.owner_organization_id is null or c.owner_organization_id=store)) or exists(select 1 from public.training_course_releases r where r.organization_id=store and r.course_id=c.id and c.published) or exists(select 1 from public.training_assignments a where a.course_id=c.id and a.organization_id=store and (managing or a.membership_id=mine));
 select coalesce(jsonb_agg(to_jsonb(a)||jsonb_build_object('lessons_completed',(select count(*) from public.training_lesson_completions d where d.assignment_id=a.id),'attempts_used',(select count(*) from public.training_attempts t where t.assignment_id=a.id),'latest_attempt',(select to_jsonb(t) from public.training_attempts t where t.assignment_id=a.id order by attempt_number desc limit 1),'course_points',coalesce((select sum(p.points) from private.training_point_awards p join public.organization_memberships m on m.user_id=p.user_id where m.id=a.membership_id and p.course_id=a.course_id),0),'overdue',a.completed_at is null and a.due_date<(now() at time zone o.time_zone)::date) order by a.due_date,a.assigned_at),'[]'::jsonb) into assignments from public.training_assignments a join public.organizations o on o.id=a.organization_id where a.organization_id=store and (managing or a.membership_id=mine);
 select coalesce(jsonb_agg(to_jsonb(d) order by d.name),'[]'::jsonb) into departments from public.training_departments d where d.organization_id=store;
 return jsonb_build_object('store',(select to_jsonb(o) from public.organizations o where id=store),'my_membership',mine,'can_manage',managing,'is_admin',private.is_admin(),'members',roster,'courses',courses,'assignments',assignments,'departments',departments,
 'totals',jsonb_build_object('lifetime_points',coalesce((select sum(points) from private.training_point_awards where user_id=auth.uid()),0),'trophies',(select count(*) from public.training_trophies where user_id=auth.uid()),'completed_courses',(select count(*) from public.training_assignments where membership_id=mine and completed_at is not null)),
 'question_alerts',case when managing then public.get_training_question_alerts(store) else '[]'::jsonb end,'global_question_alerts',case when private.is_admin() then public.get_training_question_alerts(null) else '[]'::jsonb end);
end;
$$;

-- Once assigned, a course version is immutable. Publish a new version instead.
create function private.freeze_assigned_training_content()
returns trigger language plpgsql security definer set search_path='' as $$
declare course uuid; old_course uuid;
begin
 if tg_table_name='training_courses' then
  course:=coalesce(new.id,old.id); old_course:=old.id;
 elsif tg_table_name='training_answer_keys' then
  select course_id into course from public.training_questions where id=coalesce(new.question_id,old.question_id);
  select course_id into old_course from public.training_questions where id=old.question_id;
 else course:=coalesce(new.course_id,old.course_id); old_course:=old.course_id;
 end if;
 if exists(select 1 from public.training_assignments where course_id=course or course_id=old_course) then raise exception 'Assigned course versions cannot be edited; create a new version'; end if;
 if tg_op='DELETE' then return old; else return new; end if;
end;
$$;
revoke all on function private.freeze_assigned_training_content() from public,anon,authenticated;
create trigger freeze_training_courses before update or delete on public.training_courses for each row execute function private.freeze_assigned_training_content();
create trigger freeze_training_lessons before insert or update or delete on public.training_lessons for each row execute function private.freeze_assigned_training_content();
create trigger freeze_training_questions before insert or update or delete on public.training_questions for each row execute function private.freeze_assigned_training_content();
create trigger freeze_training_answers before insert or update or delete on private.training_answer_keys for each row execute function private.freeze_assigned_training_content();

revoke all on function public.release_training_course(uuid,uuid,boolean),public.create_training_department(uuid,text),public.set_training_departments(uuid,uuid[]),public.assign_training(uuid,uuid,uuid[],uuid[],boolean,date),public.complete_training_lesson(uuid,uuid),public.submit_training_quiz(uuid,jsonb,uuid),public.get_training_attempt_review(uuid),public.unlock_training_retry(uuid,text),public.get_training_question_alerts(uuid),public.get_training_workspace(uuid) from public,anon;
grant execute on function public.release_training_course(uuid,uuid,boolean),public.create_training_department(uuid,text),public.set_training_departments(uuid,uuid[]),public.assign_training(uuid,uuid,uuid[],uuid[],boolean,date),public.complete_training_lesson(uuid,uuid),public.submit_training_quiz(uuid,jsonb,uuid),public.get_training_attempt_review(uuid),public.unlock_training_retry(uuid,text),public.get_training_question_alerts(uuid),public.get_training_workspace(uuid) to authenticated;

-- Approved sample content only. No Toolbox Tuesday or attendance rules.
insert into public.training_courses(id,slug,title,description,category,published) values('c1000000-0000-4000-8000-000000000001','customer-trust','Customer Service: Building Customer Trust','Find reliable answers, explain recommendations, and build product knowledge to serve customers with confidence.','Customer Service',true);
insert into public.training_lessons(id,course_id,position,title,body) values('c1100000-0000-4000-8000-000000000001','c1000000-0000-4000-8000-000000000001',1,'Help customers find the answer','[{"type": "paragraph", "text": "Customers do not expect you to know everything. They do expect you to care enough to help."}, {"type": "paragraph", "text": "When you don''t know an answer, be honest and take the next step. Instead of ending the conversation with “I don''t know,” try:"}, {"type": "callout", "text": "“That''s a great question. Let me find out for you.”\n“I haven''t run into that before. Let''s find the right information.”\n“Let me get someone who specializes in that area.”"}, {"type": "heading", "text": "Put it into practice"}, {"type": "paragraph", "text": "A customer asks which fertilizer will help their hydrangeas bloom. Rather than guessing, connect them with a knowledgeable teammate or consult an appropriate product resource."}, {"type": "callout", "text": "The takeaway\nYou can provide good service without knowing the answer immediately. Take responsibility for helping the customer find reliable information."}]'::jsonb);
insert into public.training_lessons(id,course_id,position,title,body) values('c1100000-0000-4000-8000-000000000002','c1000000-0000-4000-8000-000000000001',2,'Teach, don’t just sell','[{"type": "paragraph", "text": "Explaining how a product works and why it suits the customer''s project builds confidence and trust."}, {"type": "heading", "text": "Start with their project"}, {"type": "paragraph", "text": "Ask what the customer wants to accomplish. Then explain your recommendation in plain language. Use product instructions and knowledgeable teammates to help confirm that the recommendation fits."}, {"type": "callout", "text": "A useful question\n“Tell me a little about what you''re working on. What are you hoping to achieve?”"}, {"type": "paragraph", "text": "Give the customer time to ask questions. A clear explanation can help them feel confident about both the product and the next step."}, {"type": "callout", "text": "The takeaway\nHelp the customer understand the solution, rather than simply pointing to a product."}]'::jsonb);
insert into public.training_lessons(id,course_id,position,title,body) values('c1100000-0000-4000-8000-000000000003','c1000000-0000-4000-8000-000000000001',3,'Build your product knowledge','[{"type": "paragraph", "text": "You don''t have to learn the entire store overnight. A little curiosity each day makes a difference."}, {"type": "heading", "text": "Five ways to keep learning"}, {"type": "bullet", "text": "Ask experienced teammates."}, {"type": "bullet", "text": "Read product packaging and instructions."}, {"type": "bullet", "text": "Review manufacturer websites and training videos."}, {"type": "bullet", "text": "Learn about products stocked in your department."}, {"type": "bullet", "text": "Ask your manager about available supplier training."}, {"type": "callout", "text": "A moment to reflect · optional\nWhich product or department would you like to understand better? Choose one resource you could use to learn more this week."}, {"type": "callout", "text": "The takeaway\nLearning more about your products helps you serve customers more confidently."}]'::jsonb);
insert into public.training_questions(id,course_id,position,prompt,options) values('c1200000-0000-4000-8000-000000000001','c1000000-0000-4000-8000-000000000001',1,'A customer asks a product question you cannot answer. What is the best response?','["Recommend the most popular product without checking.", "Say “I don’t know” and end the conversation.", "Offer to find the answer using a reliable resource or knowledgeable teammate.", "Ask the customer to choose without assistance."]'::jsonb);
insert into private.training_answer_keys(question_id,correct_option,explanation) values('c1200000-0000-4000-8000-000000000001',2,'Being honest while helping find the answer shows care and ownership.');
insert into public.training_questions(id,course_id,position,prompt,options) values('c1200000-0000-4000-8000-000000000002','c1000000-0000-4000-8000-000000000001',2,'Good customer service requires knowing every answer immediately.','["True", "False"]'::jsonb);
insert into private.training_answer_keys(question_id,correct_option,explanation) values('c1200000-0000-4000-8000-000000000002',1,'Acknowledge uncertainty and help find reliable information.');
insert into public.training_questions(id,course_id,position,prompt,options) values('c1200000-0000-4000-8000-000000000003','c1000000-0000-4000-8000-000000000001',3,'Which action best demonstrates “teach, don’t just sell”?','["Explain how the recommended product fits the customer’s project.", "Always recommend the highest-priced option.", "Point to the aisle without discussing the project.", "Promise a result without checking the instructions."]'::jsonb);
insert into private.training_answer_keys(question_id,correct_option,explanation) values('c1200000-0000-4000-8000-000000000003',0,'An explanation helps the customer understand the recommendation.');
insert into public.training_questions(id,course_id,position,prompt,options) values('c1200000-0000-4000-8000-000000000004','c1000000-0000-4000-8000-000000000001',4,'Which is the best way to build product knowledge?','["Rely only on what you already know.", "Assume similar-looking products work identically.", "Learn from experienced teammates, product instructions, and manufacturer resources.", "Wait until a customer complains."]'::jsonb);
insert into private.training_answer_keys(question_id,correct_option,explanation) values('c1200000-0000-4000-8000-000000000004',2,'These resources help develop useful product knowledge.');
insert into public.training_questions(id,course_id,position,prompt,options) values('c1200000-0000-4000-8000-000000000005','c1000000-0000-4000-8000-000000000001',5,'Asking a knowledgeable teammate for help can build customer trust.','["True", "False"]'::jsonb);
insert into private.training_answer_keys(question_id,correct_option,explanation) values('c1200000-0000-4000-8000-000000000005',0,'Connecting the customer with the right help demonstrates teamwork and care.');
-- No store receives the course automatically: the administrator releases it explicitly.
notify pgrst, 'reload schema';
commit;


-- 202610170006_competitions.sql
-- Step 4a: store competitions and active-learning estimates. Apply once.
begin;
alter table public.training_assignments add constraint training_assignment_identity unique(id,organization_id,membership_id,course_id);
create table public.training_competitions (
 id uuid primary key default gen_random_uuid(), organization_id uuid not null references public.organizations(id),
 course_id uuid not null references public.training_courses(id), name text not null check(length(btrim(name)) between 1 and 120),
 start_date date not null, end_date date not null, time_zone text not null,
 starts_at timestamptz not null, ends_at timestamptz not null,
 reward text not null check(length(btrim(reward)) between 1 and 500), reward_type text not null default 'team' check(reward_type in ('team','individual')),
 created_by uuid not null references auth.users(id), created_at timestamptz not null default clock_timestamp(),
 ended_early_at timestamptz, canceled_at timestamptz,
 check(end_date>=start_date and ends_at>starts_at), unique(id,organization_id,course_id)
);
create index training_competitions_store_dates on public.training_competitions(organization_id,starts_at,ends_at);
create table public.training_competition_participants (
 competition_id uuid not null, organization_id uuid not null, course_id uuid not null, membership_id uuid not null,
 assignment_id uuid not null, display_name text not null, attempt_limit integer not null default 3 check(attempt_limit>=3), joined_at timestamptz not null default clock_timestamp(),
 primary key(competition_id,membership_id),
 foreign key(competition_id,organization_id,course_id) references public.training_competitions(id,organization_id,course_id),
 foreign key(assignment_id,organization_id,membership_id,course_id) references public.training_assignments(id,organization_id,membership_id,course_id)
);
create table private.training_challenge_attempts (
 id uuid primary key default gen_random_uuid(), competition_id uuid not null, membership_id uuid not null,
 submission_key uuid not null, attempt_number integer not null, points integer not null check(points>=0),
 passed boolean not null, result jsonb not null, submitted_at timestamptz not null default clock_timestamp(),
 foreign key(competition_id,membership_id) references public.training_competition_participants(competition_id,membership_id),
 unique(competition_id,membership_id,submission_key), unique(competition_id,membership_id,attempt_number)
);
create table private.training_challenge_unlocks (
 id bigint generated always as identity primary key, competition_id uuid not null,membership_id uuid not null,
 actor uuid not null references auth.users(id),note text not null,created_at timestamptz not null default clock_timestamp(),
 foreign key(competition_id,membership_id) references public.training_competition_participants(competition_id,membership_id)
);
alter table private.training_challenge_attempts enable row level security;
alter table private.training_challenge_unlocks enable row level security;
revoke all on private.training_challenge_attempts,private.training_challenge_unlocks from public,anon,authenticated;
-- Neither timing nor point-level evidence is exposed as a browser-readable table.
create table private.training_activity_sessions (
 user_id uuid primary key references auth.users(id), assignment_id uuid references public.training_assignments(id), last_seen timestamptz not null
);
create table private.training_learning_intervals (
 id bigint generated always as identity primary key, user_id uuid not null references auth.users(id),
 assignment_id uuid not null references public.training_assignments(id), started_at timestamptz not null, ended_at timestamptz not null,
 seconds integer not null check(seconds between 1 and 20), check(ended_at>started_at)
);
create index training_learning_intervals_assignment on private.training_learning_intervals(assignment_id,ended_at);
alter table public.training_competitions enable row level security;
alter table public.training_competition_participants enable row level security;
alter table private.training_activity_sessions enable row level security;
alter table private.training_learning_intervals enable row level security;
create policy training_competitions_read on public.training_competitions for select to authenticated using(private.can_manage(organization_id) or private.is_member(organization_id));
create policy training_competition_participants_read on public.training_competition_participants for select to authenticated using(private.can_manage(organization_id) or private.is_member(organization_id));
revoke all on public.training_competitions,public.training_competition_participants from public,anon,authenticated;
grant select on public.training_competitions,public.training_competition_participants to authenticated;
revoke all on private.training_activity_sessions,private.training_learning_intervals from public,anon,authenticated;

create function public.record_training_activity(assignment uuid, active boolean default true)
returns integer language plpgsql security definer set search_path='' as $$
declare session private.training_activity_sessions%rowtype; stamp timestamptz; elapsed numeric; credited integer:=0;
begin
 if not exists(select 1 from public.training_assignments a join public.organization_memberships m on m.id=a.membership_id where a.id=assignment and m.user_id=auth.uid() and m.status='active') then raise exception 'Active course assignment required'; end if;
 insert into private.training_activity_sessions(user_id,last_seen) values(auth.uid(),clock_timestamp()) on conflict do nothing;
 select * into session from private.training_activity_sessions where user_id=auth.uid() for update;
 stamp:=clock_timestamp(); elapsed:=extract(epoch from stamp-session.last_seen);
 if session.assignment_id=assignment and elapsed between 0 and 45 then
  credited:=least(20,floor(elapsed)::integer);
  if credited>0 then insert into private.training_learning_intervals(user_id,assignment_id,started_at,ended_at,seconds)
   values(auth.uid(),assignment,stamp-make_interval(secs=>credited),stamp,credited); end if;
 end if;
 update private.training_activity_sessions set assignment_id=case when coalesce(active,false) then assignment else null end,last_seen=stamp where user_id=auth.uid();
 return credited;
end;
$$;
create function public.create_training_competition(store uuid, course uuid, competition_name text, starts_on date, ends_on date, prize text, prize_type text default 'team', employee_ids uuid[] default '{}', department_ids uuid[] default '{}', all_employees boolean default false)
returns jsonb language plpgsql security definer set search_path='' as $$
declare zone text; stamp timestamptz; start_stamp timestamptz; end_stamp timestamptz; competition uuid; targets uuid[]; eligible uuid[]; total integer;
begin
 if auth.uid() is null or not private.can_manage(store) then raise exception 'Manager access required'; end if;
 select time_zone into zone from public.organizations where id=store;
 stamp:=clock_timestamp();
 if competition_name is null or length(btrim(competition_name)) not between 1 and 120 then raise exception 'Enter a competition name'; end if;
 if prize is null or length(btrim(prize)) not between 1 and 500 then raise exception 'Enter the reward'; end if;
 if prize_type is null or prize_type not in ('team','individual') then raise exception 'Choose a reward rule'; end if;
 if starts_on is null or ends_on is null or starts_on<(stamp at time zone zone)::date or ends_on<starts_on then raise exception 'Choose today or a future start date and an end date on or after it'; end if;
 start_stamp:=starts_on::timestamp at time zone zone; end_stamp:=(ends_on+1)::timestamp at time zone zone;
 if not exists(select 1 from public.training_course_releases r join public.training_courses c on c.id=r.course_id where r.organization_id=store and c.id=course and c.published) then raise exception 'Release this course to the store before starting a competition'; end if;
 if not exists(select 1 from public.training_lessons where course_id=course) or not exists(select 1 from public.training_questions where course_id=course) or exists(select 1 from public.training_questions q left join private.training_answer_keys k on k.question_id=q.id where q.course_id=course and (k.question_id is null or k.correct_option>=jsonb_array_length(q.options))) then raise exception 'Course content is not ready'; end if;
 if exists(select 1 from unnest(coalesce(employee_ids,'{}'::uuid[])) member where member is null or not exists(select 1 from public.organization_memberships where id=member and organization_id=store and status='active' and role='employee')) then raise exception 'Choose active employees from this store'; end if;
 if exists(select 1 from unnest(coalesce(department_ids,'{}'::uuid[])) department where department is null or not exists(select 1 from public.training_departments where id=department and organization_id=store)) then raise exception 'Department is not in this store'; end if;
 select coalesce(array_agg(m.id),'{}'::uuid[]) into targets from public.organization_memberships m where m.organization_id=store and m.status='active' and m.role='employee' and (coalesce(all_employees,false) or m.id=any(coalesce(employee_ids,'{}'::uuid[])) or exists(select 1 from public.training_member_departments d where d.membership_id=m.id and d.department_id=any(coalesce(department_ids,'{}'::uuid[]))));
 eligible:=targets; total:=cardinality(eligible);
 if total=0 then raise exception 'Choose at least one active employee'; end if;
 -- Serialize competing schedules for this store; touching midnight boundaries is allowed.
 perform pg_advisory_xact_lock(hashtextextended('competition:'||store::text,0));
 stamp:=clock_timestamp();
 if exists(select 1 from public.training_competitions c where c.organization_id=store and c.canceled_at is null and tstzrange(greatest(c.starts_at,c.created_at),least(c.ends_at,coalesce(c.ended_early_at,c.ends_at)),'[)') && tstzrange(greatest(start_stamp,stamp),end_stamp,'[)')) then raise exception 'These dates overlap another competition in this store'; end if;
 insert into public.training_competitions(organization_id,course_id,name,start_date,end_date,time_zone,starts_at,ends_at,reward,reward_type,created_by,created_at)
 values(store,course,btrim(competition_name),starts_on,ends_on,zone,start_stamp,end_stamp,btrim(prize),prize_type,auth.uid(),stamp) returning id into competition;
 -- The manager explicitly assigns the required course to the selected cohort.
 -- Existing assignments keep their deadlines, completions, attempts, and points.
 insert into public.training_assignments(organization_id,membership_id,course_id,due_date,assigned_by)
 select store,member,course,ends_on,auth.uid() from unnest(eligible) member on conflict(membership_id,course_id) do nothing;
 insert into public.training_competition_participants(competition_id,organization_id,course_id,membership_id,assignment_id,display_name,joined_at)
 select competition,store,course,m.id,a.id,coalesce(p.full_name,split_part(m.email,'@',1)),stamp
 from public.organization_memberships m join public.training_assignments a on a.membership_id=m.id and a.course_id=course
 left join public.profiles p on p.user_id=m.user_id where m.id=any(eligible);
 return jsonb_build_object('competition_id',competition,'participants',total,'excluded_completed',0);
end;
$$;
create function public.finish_training_competition(competition uuid)
returns void language plpgsql security definer set search_path='' as $$
declare target public.training_competitions%rowtype; stamp timestamptz;
begin
 select * into target from public.training_competitions where id=competition for update;
 if not found or not private.can_manage(target.organization_id) then raise exception 'Manager access required'; end if;
 stamp:=clock_timestamp();
 if target.canceled_at is not null or target.ended_early_at is not null or target.ends_at<=stamp then raise exception 'This competition is already closed'; end if;
 if target.starts_at>stamp then update public.training_competitions set canceled_at=stamp where id=competition;
 else update public.training_competitions set ended_early_at=stamp where id=competition; end if;
end;
$$;

create function private.training_competition_report(competition uuid)
returns jsonb language plpgsql stable security definer set search_path='' as $$
declare target public.training_competitions%rowtype; closing timestamptz; opening timestamptz; managing boolean; rows jsonb; result jsonb; eligible_count integer; done_count integer; current_state text;
begin
 select * into target from public.training_competitions where id=competition;
 if not found or not(private.can_manage(target.organization_id) or private.is_member(target.organization_id)) then raise exception 'Active store access required'; end if;
 managing:=private.can_manage(target.organization_id);
 closing:=least(target.ends_at,coalesce(target.ended_early_at,target.ends_at),coalesce(target.canceled_at,target.ends_at));
 opening:=greatest(target.starts_at,target.created_at);
 current_state:=case when target.canceled_at is not null then 'canceled' when now()<target.starts_at then 'scheduled' when now()<closing then 'active' else 'ended' end;
 with participants as (
  select p.*,m.user_id,m.deactivated_at,case when m.deactivated_at is not null and m.deactivated_at<=closing then true else false end withdrawn,
   a.completed_at is not null and a.completed_at<=closing and exists(select 1 from private.training_challenge_attempts t where t.competition_id=p.competition_id and t.membership_id=p.membership_id and t.passed and t.submitted_at<closing) completed,
   coalesce((select max(t.points) from private.training_challenge_attempts t where t.competition_id=p.competition_id and t.membership_id=p.membership_id and t.submitted_at>=opening and t.submitted_at<closing and (m.deactivated_at is null or t.submitted_at<m.deactivated_at)),0)::integer competition_points,
   (select count(*) from private.training_challenge_attempts t where t.competition_id=p.competition_id and t.membership_id=p.membership_id) attempts_used,
   a.completed_at is not null course_completed,
   coalesce((select sum(aw.points) from private.training_point_awards aw where aw.user_id=m.user_id),0)::integer lifetime_points,
   case when managing then coalesce((select sum(greatest(0,extract(epoch from least(i.ended_at,closing,coalesce(m.deactivated_at,closing))-greatest(i.started_at,opening))))::integer from private.training_learning_intervals i where i.assignment_id=p.assignment_id and i.ended_at>opening and i.started_at<closing),0) else null end learning_seconds
  from public.training_competition_participants p join public.organization_memberships m on m.id=p.membership_id join public.training_assignments a on a.id=p.assignment_id where p.competition_id=competition
 ), ranked as (
  select p.*,case when not withdrawn then (select count(*)+1 from participants other where not other.withdrawn and other.competition_points>p.competition_points) end rank from participants p
 ) select coalesce(jsonb_agg(jsonb_build_object('membership_id',membership_id,'name',display_name,'is_you',user_id=auth.uid(),'withdrawn',withdrawn,'completed',completed,'competition_points',competition_points,'lifetime_points',lifetime_points,'learning_seconds',learning_seconds,'rank',rank,'attempts_used',attempts_used,'attempt_limit',attempt_limit,'course_completed',course_completed) order by withdrawn,competition_points desc,display_name,membership_id),'[]'::jsonb),count(*) filter(where not withdrawn),count(*) filter(where not withdrawn and completed)
 into rows,eligible_count,done_count from ranked;
 result:=to_jsonb(target)||jsonb_build_object('course_title',(select title from public.training_courses where id=target.course_id),'status',current_state,'standings',rows,'participants',eligible_count,'completed',done_count,'completion_percent',case when eligible_count>0 then done_count*100/eligible_count else 0 end,'learning_seconds',case when managing then (select coalesce(sum((x->>'learning_seconds')::integer),0) from jsonb_array_elements(rows) x) else null end,
 'team_goal_met',current_state<>'canceled' and eligible_count>0 and done_count=eligible_count,
 'top_score',coalesce((select max((x->>'competition_points')::integer) from jsonb_array_elements(rows) x where not (x->>'withdrawn')::boolean),0));
 return result;
end;
$$;
revoke all on function private.training_competition_report(uuid) from public,anon,authenticated;
create function public.get_training_competitions(store uuid)
returns jsonb language plpgsql stable security definer set search_path='' as $$
begin
 if auth.uid() is null or not(private.can_manage(store) or private.is_member(store)) then raise exception 'Active store access required'; end if;
 return (select coalesce(jsonb_agg(private.training_competition_report(c.id) order by c.starts_at desc,c.created_at desc),'[]'::jsonb) from public.training_competitions c where c.organization_id=store);
end;
$$;
-- A separate challenge gives new and experienced learners the same scoring opportunity.
-- It never writes lifetime awards, original quiz attempts, completions, or trophies.
create function public.submit_training_challenge(competition uuid,answers jsonb,submission uuid)
returns jsonb language plpgsql security definer set search_path='' as $$
declare event public.training_competitions%rowtype; participant public.training_competition_participants%rowtype;
 used integer; total integer; correct integer; output jsonb; prior jsonb; stamp timestamptz;
begin
 select * into event from public.training_competitions where id=competition for share;
 select p.* into participant from public.training_competition_participants p join public.organization_memberships m on m.id=p.membership_id
 where p.competition_id=competition and m.user_id=auth.uid() and m.status='active' for update of p;
 if not found then raise exception 'Active competition participation required'; end if;
 select result into prior from private.training_challenge_attempts where competition_id=competition and membership_id=participant.membership_id and submission_key=submission;
 if found then return prior; end if;
 stamp:=clock_timestamp();
 if event.canceled_at is not null or stamp<greatest(event.starts_at,event.created_at) or stamp>=least(event.ends_at,coalesce(event.ended_early_at,event.ends_at)) then raise exception 'This competition is not running'; end if;
 if not exists(select 1 from public.training_assignments where id=participant.assignment_id and completed_at is not null) then raise exception 'Pass the required course before taking the competition challenge'; end if;
 select count(*) into used from private.training_challenge_attempts where competition_id=competition and membership_id=participant.membership_id;
 if used>=participant.attempt_limit then raise exception 'Ask your manager to unlock another challenge attempt'; end if;
 select count(*) into total from public.training_questions where course_id=event.course_id;
 if submission is null or jsonb_typeof(answers) is distinct from 'array' then raise exception 'Answer every challenge question'; end if;
 if jsonb_array_length(answers)<>total or (select count(distinct x->>'question_id') from jsonb_array_elements(answers) x)<>total then raise exception 'Answer every challenge question exactly once'; end if;
 if exists(select 1 from jsonb_array_elements(answers) x left join public.training_questions q on q.id::text=x->>'question_id' and q.course_id=event.course_id where q.id is null or jsonb_typeof(x->'option') is distinct from 'number' or (x->>'option')!~'^[0-9]+$' or (x->>'option')::numeric>=jsonb_array_length(q.options)) then raise exception 'Invalid challenge answer'; end if;
 select count(*) into correct from jsonb_array_elements(answers) x join private.training_answer_keys k on k.question_id::text=x->>'question_id' where k.correct_option=(x->>'option')::integer;
 output:=jsonb_build_object('points',correct*10,'score',correct*100/total,'correct_count',correct,'question_count',total,'passed',correct*100>=total*(select passing_percent from public.training_courses where id=event.course_id),'attempts_used',used+1,'attempt_limit',participant.attempt_limit,
 'review',(select jsonb_agg(jsonb_build_object('prompt',q.prompt,'correct_answer',q.options->>k.correct_option,'explanation',k.explanation,'is_correct',k.correct_option=(x->>'option')::integer) order by q.position) from jsonb_array_elements(answers) x join public.training_questions q on q.id::text=x->>'question_id' join private.training_answer_keys k on k.question_id=q.id));
 insert into private.training_challenge_attempts(competition_id,membership_id,submission_key,attempt_number,points,passed,result,submitted_at)
 values(competition,participant.membership_id,submission,used+1,correct*10,(output->>'passed')::boolean,output,stamp);
 return output;
end;
$$;
create function public.unlock_training_challenge(competition uuid,member uuid,support_note text)
returns integer language plpgsql security definer set search_path='' as $$
declare event public.training_competitions%rowtype; participant public.training_competition_participants%rowtype;
begin
 select * into event from public.training_competitions where id=competition for share;
 if not found or not private.can_manage(event.organization_id) then raise exception 'Manager access required'; end if;
 if event.canceled_at is not null or clock_timestamp()<event.starts_at or clock_timestamp()>=least(event.ends_at,coalesce(event.ended_early_at,event.ends_at)) then raise exception 'This competition is not running'; end if;
 select * into participant from public.training_competition_participants where competition_id=competition and membership_id=member for update;
 if not found or not exists(select 1 from public.organization_memberships where id=member and status='active') then raise exception 'Active competition participation required'; end if;
 if support_note is null or length(btrim(support_note)) not between 5 and 500 then raise exception 'Add a short note about the help you provided'; end if;
 if (select count(*) from private.training_challenge_attempts where competition_id=competition and membership_id=member)<participant.attempt_limit then raise exception 'An attempt is still available'; end if;
 update public.training_competition_participants set attempt_limit=attempt_limit+1 where competition_id=competition and membership_id=member;
 insert into private.training_challenge_unlocks(competition_id,membership_id,actor,note) values(competition,member,auth.uid(),btrim(support_note));
 return participant.attempt_limit+1;
end;
$$;
revoke all on function public.submit_training_challenge(uuid,jsonb,uuid),public.unlock_training_challenge(uuid,uuid,text) from public,anon;
grant execute on function public.submit_training_challenge(uuid,jsonb,uuid),public.unlock_training_challenge(uuid,uuid,text) to authenticated;
-- Keep the original private training report unchanged and wrap it with Step 4 data.
alter function public.get_training_workspace(uuid) set schema private;
alter function private.get_training_workspace(uuid) rename to training_workspace_core;
revoke all on function private.training_workspace_core(uuid) from public,anon,authenticated;
create function public.get_training_workspace(store uuid)
returns jsonb language plpgsql stable security definer set search_path='' as $$
declare base jsonb; standings jsonb; eligibility jsonb; managing boolean;
begin
 base:=private.training_workspace_core(store); managing:=(base->>'can_manage')::boolean;
 select coalesce(jsonb_agg(jsonb_build_object('membership_id',m.id,'name',coalesce(p.full_name,split_part(m.email,'@',1)),'is_you',m.user_id=auth.uid(),'points',coalesce((select sum(points) from private.training_point_awards where user_id=m.user_id),0)) order by coalesce((select sum(points) from private.training_point_awards where user_id=m.user_id),0) desc,coalesce(p.full_name,m.email)),'[]'::jsonb) into standings from public.organization_memberships m left join public.profiles p on p.user_id=m.user_id where m.organization_id=store and m.status='active' and m.role='employee';
 if managing then
  select coalesce(jsonb_agg(jsonb_build_object('membership_id',m.id,'course_id',r.course_id,'eligible',true)),'[]'::jsonb) into eligibility from public.organization_memberships m cross join public.training_course_releases r where m.organization_id=store and r.organization_id=store and m.status='active' and m.role='employee';
 end if;
 return base||jsonb_build_object('competitions',public.get_training_competitions(store),'lifetime_standings',standings,'competition_eligibility',coalesce(eligibility,'[]'::jsonb),
 'team_learning_seconds',case when managing then (select coalesce(sum(i.seconds),0) from private.training_learning_intervals i join public.training_assignments a on a.id=i.assignment_id where a.organization_id=store) else null end);
end;
$$;
revoke all on function public.record_training_activity(uuid,boolean),public.create_training_competition(uuid,uuid,text,date,date,text,text,uuid[],uuid[],boolean),public.finish_training_competition(uuid),public.get_training_competitions(uuid),public.get_training_workspace(uuid) from public,anon;
grant execute on function public.record_training_activity(uuid,boolean),public.create_training_competition(uuid,uuid,text,date,date,text,text,uuid[],uuid[],boolean),public.finish_training_competition(uuid),public.get_training_competitions(uuid),public.get_training_workspace(uuid) to authenticated;
notify pgrst, 'reload schema';
commit;


-- 202610170007_team_corner.sql
-- Team Corner: private store conversations, photos, and manager-requested support.
begin;
-- Enforce the existing private bucket configuration, including on upgraded projects.
update storage.buckets set public=false,file_size_limit=1048576,allowed_mime_types=array['image/jpeg','image/png','image/webp'] where id='team-media';
create table public.team_corner_posts (
 id uuid primary key, organization_id uuid not null references public.organizations(id),
 author_id uuid not null references auth.users(id), author_name text not null,
 body text not null check(length(body)<=5000), created_at timestamptz not null default clock_timestamp(),
 announcement boolean not null default false,pinned boolean not null default false,comments_open boolean not null default true,
 deleted_at timestamptz,deleted_by uuid references auth.users(id),unique(id,organization_id),check(not pinned or announcement)
);
create index team_corner_posts_feed on public.team_corner_posts(organization_id,pinned desc,created_at desc,id desc) where deleted_at is null;
create table public.team_corner_comments (
 id uuid primary key,post_id uuid not null,organization_id uuid not null,author_id uuid not null references auth.users(id),author_name text not null,
 body text not null check(length(body)<=2000),created_at timestamptz not null default clock_timestamp(),deleted_at timestamptz,deleted_by uuid references auth.users(id),
 unique(id,organization_id),foreign key(post_id,organization_id) references public.team_corner_posts(id,organization_id)
);
create index team_corner_comments_thread on public.team_corner_comments(post_id,created_at desc,id desc) where deleted_at is null;
create table public.team_corner_media (
 id uuid primary key,organization_id uuid not null references public.organizations(id),owner_id uuid not null references auth.users(id),
 object_name text not null unique,content_type text not null check(content_type in ('image/jpeg','image/png','image/webp')),created_at timestamptz not null default clock_timestamp(),
 post_id uuid,comment_id uuid,check(num_nonnulls(post_id,comment_id)<=1),
 foreign key(post_id,organization_id) references public.team_corner_posts(id,organization_id),
 foreign key(comment_id,organization_id) references public.team_corner_comments(id,organization_id)
);
create index team_corner_media_post on public.team_corner_media(post_id);
create index team_corner_media_comment on public.team_corner_media(comment_id);
create table public.team_corner_likes (
 post_id uuid not null references public.team_corner_posts(id),user_id uuid not null references auth.users(id),created_at timestamptz not null default clock_timestamp(),primary key(post_id,user_id)
);
create table private.team_corner_support (
 id uuid primary key default gen_random_uuid(),organization_id uuid not null references public.organizations(id),
 requested_by uuid not null references public.organization_memberships(id),reason text not null check(length(btrim(reason)) between 5 and 500),
 created_at timestamptz not null default clock_timestamp(),expires_at timestamptz not null default clock_timestamp()+interval '24 hours',
 revoked_at timestamptz,revoked_by uuid references auth.users(id)
);
create index team_corner_support_store on private.team_corner_support(organization_id,expires_at) where revoked_at is null;
alter table public.team_corner_posts enable row level security;
alter table public.team_corner_comments enable row level security;
alter table public.team_corner_media enable row level security;
alter table public.team_corner_likes enable row level security;
alter table private.team_corner_support enable row level security;
revoke all on public.team_corner_posts,public.team_corner_comments,public.team_corner_media,public.team_corner_likes,private.team_corner_support from public,anon,authenticated;
grant select on public.team_corner_posts,public.team_corner_comments,public.team_corner_media,public.team_corner_likes to authenticated;

-- These helpers deliberately do not use can_manage: platform admins have no automatic feed access.
create function private.team_corner_manager(store uuid) returns boolean language sql stable security definer set search_path='' as $$
 select exists(select 1 from public.organization_memberships where organization_id=store and user_id=auth.uid() and status='active' and role='manager');
$$;
create function private.team_corner_support_active(store uuid) returns boolean language sql stable security definer set search_path='' as $$
 select exists(select 1 from private.team_corner_support s join public.organization_memberships m on m.id=s.requested_by where s.organization_id=store and s.revoked_at is null and s.expires_at>now() and m.status='active' and m.role='manager');
$$;
create function private.team_corner_read(store uuid) returns boolean language sql stable security definer set search_path='' as $$
 select private.is_member(store) or (private.is_admin() and private.team_corner_support_active(store));
$$;
create function private.team_corner_post_visible(post uuid) returns boolean language sql stable security definer set search_path='' as $$
 select exists(select 1 from public.team_corner_posts where id=post and deleted_at is null and private.team_corner_read(organization_id));
$$;
create function private.team_corner_media_read(media uuid) returns boolean language sql stable security definer set search_path='' as $$
 select exists(select 1 from public.team_corner_media f where f.id=media and (
 (f.post_id is null and f.comment_id is null and f.owner_id=auth.uid() and private.is_member(f.organization_id)) or
 (private.team_corner_read(f.organization_id) and (exists(select 1 from public.team_corner_posts p where p.id=f.post_id and p.deleted_at is null) or exists(select 1 from public.team_corner_comments c join public.team_corner_posts p on p.id=c.post_id where c.id=f.comment_id and c.deleted_at is null and p.deleted_at is null)))
 ));
$$;
revoke all on function private.team_corner_manager(uuid),private.team_corner_support_active(uuid),private.team_corner_read(uuid),private.team_corner_post_visible(uuid),private.team_corner_media_read(uuid) from public,anon;
grant execute on function private.team_corner_read(uuid),private.team_corner_post_visible(uuid),private.team_corner_media_read(uuid) to authenticated;
create policy team_corner_posts_read on public.team_corner_posts for select to authenticated using(deleted_at is null and private.team_corner_read(organization_id));
create policy team_corner_comments_read on public.team_corner_comments for select to authenticated using(deleted_at is null and private.team_corner_post_visible(post_id));
create policy team_corner_media_read on public.team_corner_media for select to authenticated using(private.team_corner_media_read(id));
create policy team_corner_likes_read on public.team_corner_likes for select to authenticated using(private.team_corner_post_visible(post_id));

-- Keep legacy object permissions for old, unregistered files; all new UI uploads are registered.
create or replace function private.can_read_team_file(object_name text) returns boolean language sql stable security definer set search_path='' as $$
 select case when exists(select 1 from public.team_corner_media f where f.object_name=can_read_team_file.object_name)
 then exists(select 1 from public.team_corner_media f where f.object_name=can_read_team_file.object_name and private.team_corner_media_read(f.id))
 else exists(select 1 from public.organization_memberships where user_id=auth.uid() and status='active' and organization_id::text=split_part(object_name,'/',1)) end;
$$;
create or replace function private.can_write_team_file(object_name text) returns boolean language sql stable security definer set search_path='' as $$
 select exists(select 1 from public.team_corner_media f where f.object_name=can_write_team_file.object_name and f.owner_id=auth.uid() and f.post_id is null and f.comment_id is null and private.is_member(f.organization_id));
$$;
-- Uploaded pictures cannot be overwritten or renamed after attaching them to a conversation.
drop policy coltrain_team_media_update on storage.objects;

create function public.register_team_corner_media(store uuid,media uuid,content_type text default 'image/jpeg') returns jsonb language plpgsql security definer set search_path='' as $$
declare target public.team_corner_media%rowtype; extension text;
begin
 if auth.uid() is null or not private.is_member(store) then raise exception 'Active store membership required'; end if;
 if media is null or content_type is null or content_type not in ('image/jpeg','image/png','image/webp') then raise exception 'Choose a JPG, PNG, or WebP photo'; end if;
 extension:=case content_type when 'image/jpeg' then 'jpg' when 'image/png' then 'png' else 'webp' end;
 insert into public.team_corner_media(id,organization_id,owner_id,object_name,content_type) values(media,store,auth.uid(),store::text||'/'||auth.uid()::text||'/'||media::text||'.'||extension,content_type) on conflict(id) do nothing;
 select * into target from public.team_corner_media where id=media for update;
 if target.owner_id<>auth.uid() or target.organization_id<>store or target.post_id is not null or target.comment_id is not null then raise exception 'Photo is not available for this upload'; end if;
 return jsonb_build_object('id',target.id,'object_name',target.object_name);
end;
$$;
create function private.attach_team_corner_media(store uuid,media_ids uuid[],post uuid default null,comment uuid default null) returns void language plpgsql security definer set search_path='' as $$
declare photo uuid;
begin
 if cardinality(coalesce(media_ids,'{}'))>4 then raise exception 'Choose up to four photos'; end if;
 if cardinality(coalesce(media_ids,'{}'))<>(select count(distinct f) from unnest(coalesce(media_ids,'{}')) f) then raise exception 'Choose each photo once'; end if;
 -- Lock in a stable order so two submissions cannot attach one photo to different records.
 for photo in select f from unnest(coalesce(media_ids,'{}')) f order by f loop
  perform 1 from public.team_corner_media where id=photo and organization_id=store and owner_id=auth.uid() and post_id is null and comment_id is null for update;
  if not found then raise exception 'Photo is not available for this post'; end if;
  if not exists(select 1 from storage.objects o join public.team_corner_media f on f.object_name=o.name where f.id=photo and o.bucket_id='team-media') then raise exception 'Wait for each photo to finish uploading'; end if;
  update public.team_corner_media set post_id=post,comment_id=comment where id=photo;
 end loop;
end;
$$;
revoke all on function private.attach_team_corner_media(uuid,uuid[],uuid,uuid) from public,anon,authenticated;
create function public.create_team_corner_post(store uuid,submission uuid,message text,media_ids uuid[] default '{}',is_announcement boolean default false,pin boolean default false,allow_comments boolean default true) returns uuid language plpgsql security definer set search_path='' as $$
declare target public.team_corner_posts%rowtype; display_name text;
begin
 if auth.uid() is null or not private.is_member(store) then raise exception 'Active store membership required'; end if;
 if submission is null then raise exception 'A submission ID is required'; end if;
 perform pg_advisory_xact_lock(hashtextextended('team-post:'||submission::text,0));
 select * into target from public.team_corner_posts where id=submission;
 if found then
  if target.organization_id<>store or target.author_id<>auth.uid() or target.deleted_at is not null then raise exception 'Submission ID is not available'; end if;
  return target.id;
 end if;
 if message is null or length(message)>5000 or (length(btrim(message))=0 and cardinality(coalesce(media_ids,'{}'))=0) then raise exception 'Write a post or add a photo (up to 5000 characters)'; end if;
 if (coalesce(is_announcement,false) or coalesce(pin,false) or not coalesce(allow_comments,true)) and not private.team_corner_manager(store) then raise exception 'Store manager access required'; end if;
 select coalesce(nullif(full_name,''),split_part((select email from auth.users where id=auth.uid()),'@',1)) into display_name from public.profiles where user_id=auth.uid();
 insert into public.team_corner_posts(id,organization_id,author_id,author_name,body,announcement,pinned,comments_open)
 values(submission,store,auth.uid(),coalesce(display_name,'Teammate'),btrim(message),coalesce(is_announcement,false) or coalesce(pin,false),coalesce(pin,false),coalesce(allow_comments,true));
 perform private.attach_team_corner_media(store,media_ids,submission,null);
 return submission;
end;
$$;
create function public.create_team_corner_comment(post uuid,submission uuid,message text,media_ids uuid[] default '{}') returns uuid language plpgsql security definer set search_path='' as $$
declare target public.team_corner_posts%rowtype; existing public.team_corner_comments%rowtype; display_name text;
begin
 if auth.uid() is null then raise exception 'Active store membership required'; end if;
 select * into target from public.team_corner_posts where id=post for update;
 if not found or target.deleted_at is not null or not private.is_member(target.organization_id) then raise exception 'Post is not available'; end if;
 if submission is null then raise exception 'A submission ID is required'; end if;
 perform pg_advisory_xact_lock(hashtextextended('team-comment:'||submission::text,0));
 select * into existing from public.team_corner_comments where id=submission;
 if found then
  if existing.post_id<>post or existing.author_id<>auth.uid() or existing.deleted_at is not null then raise exception 'Submission ID is not available'; end if;
  return existing.id;
 end if;
 if not target.comments_open then raise exception 'Comments are turned off for this post'; end if;
 if message is null or length(message)>2000 or (length(btrim(message))=0 and cardinality(coalesce(media_ids,'{}'))=0) then raise exception 'Write a comment or add a photo (up to 2000 characters)'; end if;
 select coalesce(nullif(full_name,''),split_part((select email from auth.users where id=auth.uid()),'@',1)) into display_name from public.profiles where user_id=auth.uid();
 insert into public.team_corner_comments(id,post_id,organization_id,author_id,author_name,body) values(submission,post,target.organization_id,auth.uid(),coalesce(display_name,'Teammate'),btrim(message));
 perform private.attach_team_corner_media(target.organization_id,media_ids,null,submission);
 return submission;
end;
$$;
create function public.set_team_corner_like(post uuid,liked boolean) returns void language plpgsql security definer set search_path='' as $$
declare store uuid;
begin
 select organization_id into store from public.team_corner_posts where id=post and deleted_at is null for share;
 if not found or not private.is_member(store) then raise exception 'Post is not available'; end if;
 if coalesce(liked,false) then insert into public.team_corner_likes(post_id,user_id) values(post,auth.uid()) on conflict do nothing;
 else delete from public.team_corner_likes where post_id=post and user_id=auth.uid(); end if;
end;
$$;
create function public.set_team_corner_post_options(post uuid,is_pinned boolean,allow_comments boolean) returns void language plpgsql security definer set search_path='' as $$
declare target public.team_corner_posts%rowtype;
begin
 select * into target from public.team_corner_posts where id=post for update;
 if not found or target.deleted_at is not null or not private.team_corner_manager(target.organization_id) then raise exception 'Store manager access required'; end if;
 update public.team_corner_posts set pinned=coalesce(is_pinned,false),announcement=announcement or coalesce(is_pinned,false),comments_open=coalesce(allow_comments,true) where id=post;
end;
$$;
create function public.remove_team_corner_item(item uuid,is_comment boolean default false) returns void language plpgsql security definer set search_path='' as $$
declare store uuid; author uuid; parent uuid;
begin
 if coalesce(is_comment,false) then
  select post_id into parent from public.team_corner_comments where id=item;
  perform 1 from public.team_corner_posts where id=parent for update;
  select organization_id,author_id into store,author from public.team_corner_comments where id=item for update;
 else select organization_id,author_id into store,author from public.team_corner_posts where id=item for update; end if;
 if store is null or not private.is_member(store) or not(author=auth.uid() or private.team_corner_manager(store)) then raise exception 'Only the author or store manager can remove this item'; end if;
 if coalesce(is_comment,false) then update public.team_corner_comments set deleted_at=coalesce(deleted_at,clock_timestamp()),deleted_by=coalesce(deleted_by,auth.uid()) where id=item;
 else update public.team_corner_posts set deleted_at=coalesce(deleted_at,clock_timestamp()),deleted_by=coalesce(deleted_by,auth.uid()) where id=item; end if;
end;
$$;
create function public.request_team_corner_support(store uuid,support_reason text) returns timestamptz language plpgsql security definer set search_path='' as $$
declare member uuid; expiry timestamptz;
begin
 if not private.team_corner_manager(store) then raise exception 'Store manager access required'; end if;
 if support_reason is null or length(btrim(support_reason)) not between 5 and 500 then raise exception 'Describe the support you need (5–500 characters)'; end if;
 perform pg_advisory_xact_lock(hashtextextended('team-support:'||store::text,0));
 select id into member from public.organization_memberships where organization_id=store and user_id=auth.uid() and status='active' and role='manager';
 update private.team_corner_support set revoked_at=clock_timestamp(),revoked_by=auth.uid() where organization_id=store and revoked_at is null;
 insert into private.team_corner_support(organization_id,requested_by,reason) values(store,member,btrim(support_reason)) returning expires_at into expiry;
 return expiry;
end;
$$;
create function public.revoke_team_corner_support(store uuid) returns void language plpgsql security definer set search_path='' as $$
begin
 if not private.team_corner_manager(store) then raise exception 'Store manager access required'; end if;
 perform pg_advisory_xact_lock(hashtextextended('team-support:'||store::text,0));
 update private.team_corner_support set revoked_at=clock_timestamp(),revoked_by=auth.uid() where organization_id=store and revoked_at is null;
end;
$$;

create function private.team_corner_comment_json(comment public.team_corner_comments) returns jsonb language sql stable security definer set search_path='' as $$
 select jsonb_build_object('id',comment.id,'post_id',comment.post_id,'author_name',comment.author_name,'body',comment.body,'created_at',comment.created_at,
 'can_remove',private.is_member(comment.organization_id) and (comment.author_id=auth.uid() or private.team_corner_manager(comment.organization_id)),
 'media',coalesce((select jsonb_agg(jsonb_build_object('id',id,'object_name',object_name)) from public.team_corner_media where comment_id=comment.id),'[]'::jsonb));
$$;
create function public.get_team_corner_comments(post uuid,before_time timestamptz default null,before_id uuid default null) returns jsonb language plpgsql stable security definer set search_path='' as $$
declare result jsonb;
begin
 if not private.team_corner_post_visible(post) then raise exception 'Store feed access required'; end if;
 select coalesce(jsonb_agg(private.team_corner_comment_json(c) order by c.created_at,c.id),'[]'::jsonb) into result from (select * from public.team_corner_comments where post_id=post and deleted_at is null and (before_time is null or (created_at,id)<(before_time,before_id)) order by created_at desc,id desc limit 20)c;
 return jsonb_build_object('comments',result,'has_more',exists(select 1 from public.team_corner_comments where post_id=post and deleted_at is null and (created_at,id)<((result->0->>'created_at')::timestamptz,(result->0->>'id')::uuid)));
end;
$$;
create function private.team_corner_post_json(post public.team_corner_posts) returns jsonb language sql stable security definer set search_path='' as $$
 select jsonb_build_object('id',post.id,'author_name',post.author_name,'body',post.body,'created_at',post.created_at,'announcement',post.announcement,'pinned',post.pinned,'comments_open',post.comments_open,
 'can_remove',private.is_member(post.organization_id) and (post.author_id=auth.uid() or private.team_corner_manager(post.organization_id)),
 'like_count',(select count(*) from public.team_corner_likes where post_id=post.id),'liked',exists(select 1 from public.team_corner_likes where post_id=post.id and user_id=auth.uid()),
 'media',coalesce((select jsonb_agg(jsonb_build_object('id',id,'object_name',object_name)) from public.team_corner_media where post_id=post.id),'[]'::jsonb),
 'comments',(public.get_team_corner_comments(post.id)->'comments'),'more_comments',(public.get_team_corner_comments(post.id)->'has_more'));
$$;
revoke all on function private.team_corner_comment_json(public.team_corner_comments),private.team_corner_post_json(public.team_corner_posts) from public,anon,authenticated;
create function public.get_team_corner(store uuid,before_time timestamptz default null,before_id uuid default null) returns jsonb language plpgsql stable security definer set search_path='' as $$
declare posts jsonb; pin_rows jsonb; support jsonb; can_read boolean; managing boolean;
begin
 if auth.uid() is null or not(private.is_member(store) or private.is_admin()) then raise exception 'Store feed access required'; end if;
 can_read:=private.team_corner_read(store);managing:=private.team_corner_manager(store);
 if not can_read then return jsonb_build_object('can_read',false,'can_post',false,'is_manager',false,'posts','[]'::jsonb,'pinned','[]'::jsonb,'has_more',false,'support',null); end if;
 if managing or private.is_admin() then
 select jsonb_build_object('expires_at',s.expires_at,'reason',s.reason,'requested_by',coalesce(p.full_name,'Store manager')) into support from private.team_corner_support s join public.organization_memberships m on m.id=s.requested_by left join public.profiles p on p.user_id=m.user_id where s.organization_id=store and s.revoked_at is null and s.expires_at>now() and m.status='active' and m.role='manager' order by s.created_at desc limit 1;
 end if;
 select coalesce(jsonb_agg(private.team_corner_post_json(p) order by p.created_at desc,p.id desc),'[]'::jsonb) into posts from (select * from public.team_corner_posts where organization_id=store and deleted_at is null and not pinned and (before_time is null or (created_at,id)<(before_time,before_id)) order by created_at desc,id desc limit 20)p;
 select coalesce(jsonb_agg(private.team_corner_post_json(p) order by p.created_at desc,p.id desc),'[]'::jsonb) into pin_rows from public.team_corner_posts p where organization_id=store and deleted_at is null and p.pinned;
 return jsonb_build_object('can_read',true,'can_post',private.is_member(store),'is_manager',managing,'posts',posts,'pinned',pin_rows,'support',support,
 'has_more',exists(select 1 from public.team_corner_posts where organization_id=store and deleted_at is null and not team_corner_posts.pinned and (created_at,id)<((posts->-1->>'created_at')::timestamptz,(posts->-1->>'id')::uuid)));
end;
$$;
revoke all on function public.register_team_corner_media(uuid,uuid,text),public.create_team_corner_post(uuid,uuid,text,uuid[],boolean,boolean,boolean),public.create_team_corner_comment(uuid,uuid,text,uuid[]),public.set_team_corner_like(uuid,boolean),public.set_team_corner_post_options(uuid,boolean,boolean),public.remove_team_corner_item(uuid,boolean),public.request_team_corner_support(uuid,text),public.revoke_team_corner_support(uuid),public.get_team_corner_comments(uuid,timestamptz,uuid),public.get_team_corner(uuid,timestamptz,uuid) from public,anon;
grant execute on function public.register_team_corner_media(uuid,uuid,text),public.create_team_corner_post(uuid,uuid,text,uuid[],boolean,boolean,boolean),public.create_team_corner_comment(uuid,uuid,text,uuid[]),public.set_team_corner_like(uuid,boolean),public.set_team_corner_post_options(uuid,boolean,boolean),public.remove_team_corner_item(uuid,boolean),public.request_team_corner_support(uuid,text),public.revoke_team_corner_support(uuid),public.get_team_corner_comments(uuid,timestamptz,uuid),public.get_team_corner(uuid,timestamptz,uuid) to authenticated;
create function public.get_team_corner_support_requests() returns jsonb language plpgsql stable security definer set search_path='' as $$
begin
 if auth.uid() is null or not private.is_admin() then raise exception 'Administrator access required'; end if;
 return (select coalesce(jsonb_agg(jsonb_build_object('store_id',o.id,'store_name',o.name,'reason',s.reason,'expires_at',s.expires_at,'requested_by',coalesce(p.full_name,'Store manager')) order by s.created_at desc),'[]'::jsonb)
 from private.team_corner_support s join public.organizations o on o.id=s.organization_id join public.organization_memberships m on m.id=s.requested_by left join public.profiles p on p.user_id=m.user_id
 where s.revoked_at is null and s.expires_at>now() and m.status='active' and m.role='manager');
end;
$$;
revoke all on function public.get_team_corner_support_requests() from public,anon;
grant execute on function public.get_team_corner_support_requests() to authenticated;
notify pgrst,'reload schema';
commit;


-- 202610180008_team_corner_author_names.sql
-- Fix authors without a saved profile and repair existing placeholder names.
-- Apply only this update to an existing project already using Team Corner.
begin;
alter table public.profiles add column team_corner_nickname text
 check(team_corner_nickname is null or length(btrim(team_corner_nickname)) between 1 and 60);
create function public.save_my_account_preferences(display_name text,email_notifications boolean default false,team_nickname text default null)
returns void language plpgsql security definer set search_path='' as $$
begin
 if auth.uid() is null then raise exception 'Sign in first'; end if;
 if team_nickname is not null and length(btrim(team_nickname))>60 then raise exception 'Use a nickname of 60 characters or fewer'; end if;
 perform public.save_my_profile(display_name,email_notifications);
 update public.profiles set team_corner_nickname=nullif(btrim(team_nickname),'') where user_id=auth.uid();
end;
$$;
revoke all on function public.save_my_account_preferences(text,boolean,text) from public,anon;
grant execute on function public.save_my_account_preferences(text,boolean,text) to authenticated;
create or replace function private.team_corner_author_name(person uuid) returns text
language sql stable security definer set search_path='' as $$
 select coalesce(
  (select coalesce(nullif(btrim(team_corner_nickname),''),nullif(btrim(full_name),'')) from public.profiles where user_id=person),
  (select nullif(split_part(email,'@',1),'') from auth.users where id=person),
  'Teammate');
$$;
revoke all on function private.team_corner_author_name(uuid) from public,anon,authenticated;
create or replace function public.create_team_corner_post(store uuid,submission uuid,message text,media_ids uuid[] default '{}',is_announcement boolean default false,pin boolean default false,allow_comments boolean default true) returns uuid language plpgsql security definer set search_path='' as $$
declare target public.team_corner_posts%rowtype; display_name text;
begin
 if auth.uid() is null or not private.is_member(store) then raise exception 'Active store membership required'; end if;
 if submission is null then raise exception 'A submission ID is required'; end if;
 perform pg_advisory_xact_lock(hashtextextended('team-post:'||submission::text,0));
 select * into target from public.team_corner_posts where id=submission;
 if found then
  if target.organization_id<>store or target.author_id<>auth.uid() or target.deleted_at is not null then raise exception 'Submission ID is not available'; end if;
  return target.id;
 end if;
 if message is null or length(message)>5000 or (length(btrim(message))=0 and cardinality(coalesce(media_ids,'{}'))=0) then raise exception 'Write a post or add a photo (up to 5000 characters)'; end if;
 if (coalesce(is_announcement,false) or coalesce(pin,false) or not coalesce(allow_comments,true)) and not private.team_corner_manager(store) then raise exception 'Store manager access required'; end if;
 display_name := private.team_corner_author_name(auth.uid());
 insert into public.team_corner_posts(id,organization_id,author_id,author_name,body,announcement,pinned,comments_open)
 values(submission,store,auth.uid(),coalesce(display_name,'Teammate'),btrim(message),coalesce(is_announcement,false) or coalesce(pin,false),coalesce(pin,false),coalesce(allow_comments,true));
 perform private.attach_team_corner_media(store,media_ids,submission,null);
 return submission;
end;
$$;

create or replace function public.create_team_corner_comment(post uuid,submission uuid,message text,media_ids uuid[] default '{}') returns uuid language plpgsql security definer set search_path='' as $$
declare target public.team_corner_posts%rowtype; existing public.team_corner_comments%rowtype; display_name text;
begin
 if auth.uid() is null then raise exception 'Active store membership required'; end if;
 select * into target from public.team_corner_posts where id=post for update;
 if not found or target.deleted_at is not null or not private.is_member(target.organization_id) then raise exception 'Post is not available'; end if;
 if submission is null then raise exception 'A submission ID is required'; end if;
 perform pg_advisory_xact_lock(hashtextextended('team-comment:'||submission::text,0));
 select * into existing from public.team_corner_comments where id=submission;
 if found then
  if existing.post_id<>post or existing.author_id<>auth.uid() or existing.deleted_at is not null then raise exception 'Submission ID is not available'; end if;
  return existing.id;
 end if;
 if not target.comments_open then raise exception 'Comments are turned off for this post'; end if;
 if message is null or length(message)>2000 or (length(btrim(message))=0 and cardinality(coalesce(media_ids,'{}'))=0) then raise exception 'Write a comment or add a photo (up to 2000 characters)'; end if;
 display_name := private.team_corner_author_name(auth.uid());
 insert into public.team_corner_comments(id,post_id,organization_id,author_id,author_name,body) values(submission,post,target.organization_id,auth.uid(),coalesce(display_name,'Teammate'),btrim(message));
 perform private.attach_team_corner_media(target.organization_id,media_ids,null,submission);
 return submission;
end;
$$;

-- Profile names are the display identity for both old and new conversation.
create or replace function private.refresh_team_corner_author_name() returns trigger
language plpgsql security definer set search_path='' as $$
begin
 update public.team_corner_posts set author_name=private.team_corner_author_name(new.user_id) where author_id=new.user_id and author_name is distinct from private.team_corner_author_name(new.user_id);
 update public.team_corner_comments set author_name=private.team_corner_author_name(new.user_id) where author_id=new.user_id and author_name is distinct from private.team_corner_author_name(new.user_id);
 return new;
end;
$$;
revoke all on function private.refresh_team_corner_author_name() from public,anon,authenticated;
create or replace trigger team_corner_profile_name after insert or update of full_name,team_corner_nickname on public.profiles
for each row execute function private.refresh_team_corner_author_name();
update public.team_corner_posts set author_name=private.team_corner_author_name(author_id) where author_name='Teammate';
update public.team_corner_comments set author_name=private.team_corner_author_name(author_id) where author_name='Teammate';
notify pgrst,'reload schema';
commit;


-- 202610180009_training_notifications.sql
-- Step 5a: private in-app training reminders and persistent read status.
-- Apply once after 008. No emails, browser push, or background jobs are enabled.
begin;
create table private.training_notifications (
 id uuid primary key default gen_random_uuid(),
 organization_id uuid not null references public.organizations(id),
 user_id uuid not null references auth.users(id),
 event_key text not null, created_at timestamptz not null default clock_timestamp(), read_at timestamptz,
 unique(organization_id,user_id,event_key)
);
alter table private.training_notifications enable row level security;
revoke all on private.training_notifications from public,anon,authenticated;
create index training_notifications_owner on private.training_notifications(organization_id,user_id);

-- Derive only actionable notifications. Resolved work disappears without resetting read receipts.
-- No caller-supplied recipient and no platform-admin bypass into another person's inbox.
create function private.training_notification_candidates(store uuid)
returns table(event_key text,kind text,title text,body text,course_id uuid,target_view text,competition_id uuid,event_at timestamptz)
language sql stable security definer set search_path='' as $$
 with me as (
  select m.* from public.organization_memberships m where m.organization_id=store and m.user_id=auth.uid() and m.status='active'
 ), pending as (
  select a.*,m.user_id,m.role,coalesce(p.full_name,split_part(m.email,'@',1)) person,c.title course_title,
   (now() at time zone o.time_zone)::date today,
   (select count(*) from public.training_attempts t where t.assignment_id=a.id) used,
   (select max(t.submitted_at) from public.training_attempts t where t.assignment_id=a.id) latest_attempt,
   (select max(u.created_at) from public.training_retry_unlocks u where u.assignment_id=a.id) latest_unlock
  from public.training_assignments a join public.organization_memberships m on m.id=a.membership_id
  join public.training_courses c on c.id=a.course_id join public.organizations o on o.id=a.organization_id
  left join public.profiles p on p.user_id=m.user_id
  where a.organization_id=store and m.status='active' and a.completed_at is null
   and (m.user_id=auth.uid() or exists(select 1 from me where role='manager'))
 ), regular as (
  select v.event_key,v.kind,v.title,v.body,a.course_id,v.target_view,null::uuid competition_id,v.event_at
  from pending a cross join lateral (
   values
   ('assignment:'||a.id||':'||a.due_date,'assignment','Training assignment',a.course_title||' · Due '||to_char(a.due_date,'Mon DD, YYYY'),'course',a.assigned_at,a.user_id=auth.uid()),
   ('deadline:'||a.id||':'||a.due_date||':'||case when a.due_date<a.today then 'overdue' when a.due_date=a.today then 'today' when a.due_date=a.today+1 then 'tomorrow' else 'soon' end,
    'deadline',case when a.due_date<a.today then 'Training overdue' when a.due_date=a.today then 'Training due today' when a.due_date=a.today+1 then 'Training due tomorrow' else 'Training due soon' end,
    a.course_title||' · Due '||to_char(a.due_date,'Mon DD, YYYY')||case when a.due_date<a.today then '. You can still complete this course.' else '.' end,
    'course',now(),a.user_id=auth.uid() and a.due_date<=a.today+3),
   ('help:'||a.id||':'||a.attempt_limit,'help_needed',case when a.user_id=auth.uid() then 'Ask your manager for help' else 'An employee needs quiz help' end,
    case when a.user_id=auth.uid() then a.course_title||' · Review the material with your manager before another attempt.' else a.person||' · '||a.course_title||' · Review the material together, then unlock one attempt.' end,
    case when a.user_id=auth.uid() then 'course' else 'home' end,coalesce(a.latest_attempt,a.assigned_at),a.used>=a.attempt_limit),
   ('retry:'||a.id||':'||a.attempt_limit,'retry_unlocked','Another quiz attempt is ready',a.course_title||' · Your manager unlocked one additional attempt. Your previous points are saved.',
    'course',coalesce(a.latest_unlock,a.assigned_at),a.user_id=auth.uid() and a.attempt_limit>3 and a.used<a.attempt_limit)
  ) v(event_key,kind,title,body,target_view,event_at,visible)
  where v.visible
 ), challenge as (
  select e.*,p.membership_id,p.attempt_limit,m.user_id,p.display_name,
   (select count(*) from private.training_challenge_attempts t where t.competition_id=e.id and t.membership_id=p.membership_id) used,
   (select max(t.submitted_at) from private.training_challenge_attempts t where t.competition_id=e.id and t.membership_id=p.membership_id) latest_attempt,
   (select max(t.created_at) from private.training_challenge_unlocks t where t.competition_id=e.id and t.membership_id=p.membership_id) latest_unlock
  from public.training_competitions e join public.training_competition_participants p on p.competition_id=e.id
  join public.organization_memberships m on m.id=p.membership_id
  where e.organization_id=store and m.status='active' and e.canceled_at is null and e.ended_early_at is null and now()>=e.starts_at and now()<e.ends_at
   and (m.user_id=auth.uid() or exists(select 1 from me where role='manager'))
   and not exists(select 1 from private.training_challenge_attempts t where t.competition_id=e.id and t.membership_id=p.membership_id and t.passed)
 )
 select * from regular
 union all
 select v.event_key,v.kind,v.title,v.body,c.course_id,'competitions',c.id,v.event_at
 from challenge c cross join lateral (
  values
  ('challenge-help:'||c.id||':'||c.membership_id||':'||c.attempt_limit,'challenge_help',case when c.user_id=auth.uid() then 'Ask for competition quiz help' else 'An employee needs competition quiz help' end,
   case when c.user_id=auth.uid() then c.name||' · Review the material with your manager before another competition attempt.' else c.display_name||' · '||c.name||' · Review together, then unlock one competition attempt.' end,
   coalesce(c.latest_attempt,c.created_at),c.used>=c.attempt_limit),
  ('challenge-retry:'||c.id||':'||c.membership_id||':'||c.attempt_limit,'challenge_retry','Another competition attempt is ready',c.name||' · Your manager unlocked one additional competition quiz attempt.',coalesce(c.latest_unlock,c.created_at),c.user_id=auth.uid() and c.attempt_limit>3 and c.used<c.attempt_limit)
 ) v(event_key,kind,title,body,event_at,visible) where v.visible;
$$;
revoke all on function private.training_notification_candidates(uuid) from public,anon,authenticated;

create function public.get_my_training_notifications(store uuid) returns jsonb
language plpgsql security definer set search_path='' as $$
declare candidates jsonb; result jsonb;
begin
 if auth.uid() is null then raise exception 'Sign in first'; end if;
 if not private.is_member(store) then
  if private.is_admin() then return jsonb_build_object('items','[]'::jsonb,'unread_count',0); end if;
  raise exception 'Active store membership required';
 end if;
 select coalesce(jsonb_agg(to_jsonb(c)),'[]') into candidates from private.training_notification_candidates(store) c;
 insert into private.training_notifications(organization_id,user_id,event_key)
 select store,auth.uid(),c->>'event_key' from jsonb_array_elements(candidates)c order by c->>'event_key'
 on conflict(organization_id,user_id,event_key) do nothing;
 select jsonb_build_object('items',coalesce(jsonb_agg(jsonb_build_object(
  'id',n.id,'kind',c->>'kind','title',c->>'title','body',c->>'body','course_id',c->>'course_id',
  'target_view',c->>'target_view','competition_id',c->>'competition_id','created_at',n.created_at,'read_at',n.read_at
 ) order by n.read_at nulls first,n.created_at desc,n.id),'[]'::jsonb),'unread_count',count(*) filter(where n.read_at is null))
 into result from jsonb_array_elements(candidates)c join private.training_notifications n
 on n.organization_id=store and n.user_id=auth.uid() and n.event_key=c->>'event_key';
 return result;
end;
$$;

create function public.mark_training_notifications_read(store uuid,notification_ids uuid[] default '{}',mark_all boolean default false) returns void
language plpgsql security definer set search_path='' as $$
begin
 if auth.uid() is null or not private.is_member(store) then raise exception 'Active store membership required'; end if;
 if cardinality(coalesce(notification_ids,'{}'))>500 then raise exception 'Choose up to 500 notifications'; end if;
 -- mark_all is limited to current tasks, so later reminders never start already read.
 update private.training_notifications n set read_at=coalesce(n.read_at,clock_timestamp())
 where n.organization_id=store and n.user_id=auth.uid() and n.read_at is null
  and (n.id=any(coalesce(notification_ids,'{}')) or coalesce(mark_all,false) and exists(
   select 1 from private.training_notification_candidates(store)c where c.event_key=n.event_key));
end;
$$;
revoke all on function public.get_my_training_notifications(uuid),public.mark_training_notifications_read(uuid,uuid[],boolean) from public,anon;
grant execute on function public.get_my_training_notifications(uuid),public.mark_training_notifications_read(uuid,uuid[],boolean) to authenticated;
notify pgrst,'reload schema';
commit;


-- 202610180010_profile_avatars.sql
-- Private account avatars. Apply once after 009; existing training/feed permissions remain.
begin;
create table private.profile_photos (
 id uuid primary key, user_id uuid not null references auth.users(id), object_name text not null unique,
 created_at timestamptz not null default clock_timestamp(), published_at timestamptz
);
alter table private.profile_photos enable row level security;
revoke all on private.profile_photos from public,anon,authenticated;
alter table public.profiles add column avatar_path text references private.profile_photos(object_name);
insert into storage.buckets(id,name,public,file_size_limit,allowed_mime_types)
values('profile-photos','profile-photos',false,1048576,array['image/jpeg']);

create function private.can_read_profile_photo(path text) returns boolean
language sql stable security definer set search_path='' as $$
 select exists(select 1 from private.profile_photos f where f.object_name=path and (
  f.user_id=auth.uid() or exists(select 1 from public.profiles p where p.user_id=f.user_id and p.avatar_path=path and private.can_view_profile(p.user_id))));
$$;
create function private.can_upload_profile_photo(path text) returns boolean
language sql stable security definer set search_path='' as $$
 select exists(select 1 from private.profile_photos where object_name=path and user_id=auth.uid() and published_at is null);
$$;
create function private.can_delete_profile_photo(path text) returns boolean
language sql stable security definer set search_path='' as $$
 select exists(select 1 from private.profile_photos f where f.object_name=path and f.user_id=auth.uid()
  and not exists(select 1 from public.profiles p where p.avatar_path=path));
$$;
revoke all on function private.can_read_profile_photo(text),private.can_upload_profile_photo(text),private.can_delete_profile_photo(text) from public,anon;
grant execute on function private.can_read_profile_photo(text),private.can_upload_profile_photo(text),private.can_delete_profile_photo(text) to authenticated;
create policy coltrain_profile_photo_read on storage.objects for select to authenticated
 using(bucket_id='profile-photos' and private.can_read_profile_photo(name));
create policy coltrain_profile_photo_insert on storage.objects for insert to authenticated
 with check(bucket_id='profile-photos' and private.can_upload_profile_photo(name));
create policy coltrain_profile_photo_delete on storage.objects for delete to authenticated
 using(bucket_id='profile-photos' and private.can_delete_profile_photo(name));
-- No update policy: a published photo path cannot be overwritten with different content.

create function public.reserve_profile_photo(photo uuid) returns text
language plpgsql security definer set search_path='' as $$
declare file private.profile_photos%rowtype;
begin
 if auth.uid() is null then raise exception 'Sign in first'; end if;
 if photo is null then raise exception 'A photo ID is required'; end if;
 perform pg_advisory_xact_lock(hashtextextended('profile-photo:'||photo::text,0));
 insert into private.profile_photos(id,user_id,object_name) values(photo,auth.uid(),auth.uid()::text||'/'||photo::text||'.jpg') on conflict(id) do nothing;
 select * into file from private.profile_photos where id=photo and user_id=auth.uid();
 if not found then raise exception 'Photo is not available'; end if;
 return file.object_name;
end;
$$;
create function public.set_my_profile_photo(photo uuid default null) returns jsonb
language plpgsql security definer set search_path='' as $$
declare previous text; file private.profile_photos%rowtype;
begin
 if auth.uid() is null then raise exception 'Sign in first'; end if;
 select avatar_path into previous from public.profiles where user_id=auth.uid() for update;
 if not found then raise exception 'Save your name before adding a profile picture'; end if;
 if photo is not null then
  select * into file from private.profile_photos where id=photo and user_id=auth.uid() for update;
  if not found or (file.published_at is not null and previous is distinct from file.object_name) then raise exception 'Photo is not available'; end if;
  perform id from storage.objects where bucket_id='profile-photos' and name=file.object_name for share;
  if not found then raise exception 'Finish uploading the photo first'; end if;
  update private.profile_photos set published_at=coalesce(published_at,clock_timestamp()) where id=photo;
 end if;
 update public.profiles set avatar_path=file.object_name,updated_at=clock_timestamp() where user_id=auth.uid();
 return jsonb_build_object('previous_object',previous,'object_name',file.object_name);
end;
$$;
revoke all on function public.reserve_profile_photo(uuid),public.set_my_profile_photo(uuid) from public,anon;
grant execute on function public.reserve_profile_photo(uuid),public.set_my_profile_photo(uuid) to authenticated;

create function private.profile_avatar(person uuid) returns text
language sql stable security definer set search_path='' as $$
 select avatar_path from public.profiles where user_id=person and private.can_view_profile(person);
$$;
create function private.member_avatar(member uuid) returns text
language sql stable security definer set search_path='' as $$
 select private.profile_avatar(user_id) from public.organization_memberships where id=member;
$$;
revoke all on function private.profile_avatar(uuid),private.member_avatar(uuid) from public,anon,authenticated;

-- Keep the existing training report's role/store/answer boundaries and add current photos.
alter function public.get_training_workspace(uuid) set schema private;
alter function private.get_training_workspace(uuid) rename to training_workspace_before_avatars;
revoke all on function private.training_workspace_before_avatars(uuid) from public,anon,authenticated;
create function public.get_training_workspace(store uuid) returns jsonb
language plpgsql stable security definer set search_path='' as $$
declare base jsonb; members jsonb; standings jsonb; competitions jsonb;
begin
 base:=private.training_workspace_before_avatars(store);
 select coalesce(jsonb_agg(item||jsonb_build_object('avatar_path',private.member_avatar((item->>'id')::uuid)) order by position),'[]'::jsonb)
 into members from jsonb_array_elements(base->'members') with ordinality x(item,position);
 select coalesce(jsonb_agg(item||jsonb_build_object('avatar_path',private.member_avatar((item->>'membership_id')::uuid)) order by position),'[]'::jsonb)
 into standings from jsonb_array_elements(base->'lifetime_standings') with ordinality x(item,position);
 select coalesce(jsonb_agg(item||jsonb_build_object('standings',(
  select coalesce(jsonb_agg(person||jsonb_build_object('avatar_path',private.member_avatar((person->>'membership_id')::uuid)) order by rank_position),'[]'::jsonb)
  from jsonb_array_elements(item->'standings') with ordinality y(person,rank_position))) order by position),'[]'::jsonb)
 into competitions from jsonb_array_elements(base->'competitions') with ordinality x(item,position);
 return base||jsonb_build_object('members',members,'lifetime_standings',standings,'competitions',competitions);
end;
$$;
revoke all on function public.get_training_workspace(uuid) from public,anon;
grant execute on function public.get_training_workspace(uuid) to authenticated;

create or replace function private.team_corner_comment_json(comment public.team_corner_comments) returns jsonb language sql stable security definer set search_path='' as $$
 select jsonb_build_object('id',comment.id,'post_id',comment.post_id,'author_name',comment.author_name,'avatar_path',private.profile_avatar(comment.author_id),'body',comment.body,'created_at',comment.created_at,
 'can_remove',private.is_member(comment.organization_id) and (comment.author_id=auth.uid() or private.team_corner_manager(comment.organization_id)),
 'media',coalesce((select jsonb_agg(jsonb_build_object('id',id,'object_name',object_name)) from public.team_corner_media where comment_id=comment.id),'[]'::jsonb));
$$;

create or replace function private.team_corner_post_json(post public.team_corner_posts) returns jsonb language sql stable security definer set search_path='' as $$
 select jsonb_build_object('id',post.id,'author_name',post.author_name,'avatar_path',private.profile_avatar(post.author_id),'body',post.body,'created_at',post.created_at,'announcement',post.announcement,'pinned',post.pinned,'comments_open',post.comments_open,
 'can_remove',private.is_member(post.organization_id) and (post.author_id=auth.uid() or private.team_corner_manager(post.organization_id)),
 'like_count',(select count(*) from public.team_corner_likes where post_id=post.id),'liked',exists(select 1 from public.team_corner_likes where post_id=post.id and user_id=auth.uid()),
 'media',coalesce((select jsonb_agg(jsonb_build_object('id',id,'object_name',object_name)) from public.team_corner_media where post_id=post.id),'[]'::jsonb),
 'comments',(public.get_team_corner_comments(post.id)->'comments'),'more_comments',(public.get_team_corner_comments(post.id)->'has_more'));
$$;

notify pgrst,'reload schema';
commit;


-- 202610180011_course_catalog.sql
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


-- 202610190012_daily.sql
-- Daily foundation. Apply once after migration 011. No existing course records are changed.
begin;
create table public.daily_modules (
 id uuid primary key default gen_random_uuid(), code text not null check(code ~ '^CD-[0-9]{4,}$'),
 version text not null check(version ~ '^[0-9]+\.[0-9]+\.[0-9]+$'),
 title text not null check(length(btrim(title)) between 1 and 200), academy text not null check(academy in (
 'Paint & Surface Care','Plumbing','Electrical','HVAC','Hand Tools & Fasteners','Power Tools & Accessories',
 'Lawn, Garden & Outdoor Equipment','Building & Home Maintenance','Customer Service & Retail Readiness','Operations & Leadership')),
 skill_level text not null check(skill_level in ('foundations','application','expertise')),
 sections jsonb not null check(jsonb_typeof(sections)='array' and jsonb_array_length(sections)>0),
 sources jsonb not null default '[]' check(jsonb_typeof(sources)='array'),
 keywords text[] not null default '{}', relevant_departments text[] not null default '{}',
 estimated_minutes integer not null check(estimated_minutes between 1 and 60),
 prior_knowledge text not null default 'None', related_course_code text,
 published boolean not null default false, created_at timestamptz not null default now(), unique(code,version)
);
create table public.daily_questions (
 module_id uuid not null references public.daily_modules(id), id text not null,
 position integer not null check(position between 1 and 2), prompt text not null check(length(btrim(prompt))>0),
 options jsonb not null check(jsonb_typeof(options)='array' and jsonb_array_length(options)=4),
 primary key(module_id,id), unique(module_id,position)
);
create table private.daily_answer_keys (
 module_id uuid not null, question_id text not null, correct_option integer not null check(correct_option between 0 and 3),
 explanation text not null check(length(btrim(explanation))>0), teaching_reference text not null,
 primary key(module_id,question_id), foreign key(module_id,question_id) references public.daily_questions(module_id,id)
);
create table private.daily_editorial (
 module_id uuid primary key references public.daily_modules(id), source_document jsonb not null
);
create table public.daily_releases (
 organization_id uuid not null references public.organizations(id), module_id uuid not null references public.daily_modules(id),
 released_by uuid not null references auth.users(id), released_at timestamptz not null default now(), primary key(organization_id,module_id)
);
create table public.daily_assignments (
 id uuid primary key default gen_random_uuid(), organization_id uuid not null references public.organizations(id),
 membership_id uuid not null, module_id uuid not null references public.daily_modules(id),
 available_on date not null, assigned_by uuid not null references auth.users(id), assigned_at timestamptz not null default now(),
 started_at timestamptz, completed_at timestamptz, attempt_count integer not null default 0 check(attempt_count>=0),
 active_seconds integer not null default 0 check(active_seconds>=0), last_activity_at timestamptz,
 unique(membership_id,module_id), foreign key(organization_id,membership_id) references public.organization_memberships(organization_id,id)
);
create index daily_assignments_store on public.daily_assignments(organization_id,membership_id);
create table private.daily_attempts (
 id uuid primary key default gen_random_uuid(), assignment_id uuid not null references public.daily_assignments(id),
 submission_key uuid not null, attempt_number integer not null, answers jsonb not null, result jsonb not null,
 submitted_at timestamptz not null default now(), unique(assignment_id,submission_key), unique(assignment_id,attempt_number)
);

create function private.daily_is_learner(assignment uuid, ready boolean default true) returns boolean
language sql stable security definer set search_path='' as $$
 select exists(select 1 from public.daily_assignments a
 join public.organization_memberships m on m.id=a.membership_id
 join public.organizations o on o.id=a.organization_id
 where a.id=assignment and m.user_id=auth.uid() and m.status='active'
 and (not ready or a.available_on <= (now() at time zone o.time_zone)::date));
$$;
create function private.can_read_daily(module uuid) returns boolean
language sql stable security definer set search_path='' as $$
 select private.is_admin() or exists(select 1 from public.daily_releases r
 where r.module_id=module and private.can_manage(r.organization_id))
 or exists(select 1 from public.daily_assignments a where a.module_id=module
 and (private.can_manage(a.organization_id) or private.daily_is_learner(a.id)));
$$;
alter table public.daily_modules enable row level security;
alter table public.daily_questions enable row level security;
alter table public.daily_releases enable row level security;
alter table public.daily_assignments enable row level security;
create policy daily_modules_read on public.daily_modules for select to authenticated using(private.can_read_daily(id));
create policy daily_questions_read on public.daily_questions for select to authenticated using(private.can_read_daily(module_id));
create policy daily_releases_read on public.daily_releases for select to authenticated using(private.can_manage(organization_id) or private.is_member(organization_id));
create policy daily_assignments_read on public.daily_assignments for select to authenticated using(private.can_manage(organization_id) or private.daily_is_learner(id,false));
revoke all on public.daily_modules,public.daily_questions,public.daily_releases,public.daily_assignments from public,anon,authenticated;
grant select on public.daily_modules,public.daily_questions,public.daily_releases,public.daily_assignments to authenticated;
revoke all on private.daily_answer_keys,private.daily_editorial,private.daily_attempts from public,anon,authenticated;
revoke all on function private.daily_is_learner(uuid,boolean),private.can_read_daily(uuid) from public,anon;
grant execute on function private.daily_is_learner(uuid,boolean),private.can_read_daily(uuid) to authenticated;

-- Once published, use a new version for any content/key change. Parent locks serialize publication with child edits.
create function private.freeze_daily_content() returns trigger language plpgsql set search_path='' as $$
declare target uuid; other uuid;
begin
 if tg_table_name='daily_modules' then
  if old.published then raise exception 'Published Daily content is immutable; create a new version'; end if;
 else
  if tg_op<>'INSERT' then target:=old.module_id; end if;
  if tg_op<>'DELETE' then other:=new.module_id; end if;
  perform 1 from public.daily_modules where id in (target,other) order by id for update;
  if exists(select 1 from public.daily_modules where id in (target,other) and published) then
   raise exception 'Published Daily content is immutable; create a new version';
  end if;
 end if;
 if tg_op='DELETE' then return old; end if; return new;
end;
$$;
create trigger daily_modules_frozen before update or delete on public.daily_modules for each row execute function private.freeze_daily_content();
create trigger daily_questions_frozen before insert or update or delete on public.daily_questions for each row execute function private.freeze_daily_content();
create trigger daily_keys_frozen before insert or update or delete on private.daily_answer_keys for each row execute function private.freeze_daily_content();

create function public.publish_daily_module(module uuid) returns void
language plpgsql security definer set search_path='' as $$
begin
 if not private.is_admin() then raise exception 'Administrator access required'; end if;
 perform 1 from public.daily_modules where id=module for update;
 if not found then raise exception 'Daily module not found'; end if;
 if exists(select 1 from public.daily_modules where id=module and published) then return; end if;
 if (select count(*) from public.daily_questions where module_id=module) not between 1 and 2
 or exists(select 1 from public.daily_questions q left join private.daily_answer_keys k on k.module_id=q.module_id and k.question_id=q.id
 where q.module_id=module and (k.question_id is null or exists(select 1 from jsonb_array_elements(q.options) x where jsonb_typeof(x)<>'string' or length(btrim(x#>>'{}'))=0))) then
  raise exception 'Daily questions and private keys are incomplete';
 end if;
 update public.daily_modules set published=true where id=module;
end;
$$;
create function public.release_daily_module(store uuid,module uuid,available boolean default true) returns void
language plpgsql security definer set search_path='' as $$
begin
 if not private.is_admin() then raise exception 'Administrator access required'; end if;
 if available is null then raise exception 'Choose availability'; end if;
 if not exists(select 1 from public.daily_modules where id=module and published) then raise exception 'Publish this Daily module first'; end if;
 if available then
  insert into public.daily_releases(organization_id,module_id,released_by) values(store,module,auth.uid()) on conflict do nothing;
 else delete from public.daily_releases where organization_id=store and module_id=module;
 end if;
end;
$$;
create function public.assign_daily_module(module uuid,store uuid,employee_ids uuid[] default '{}',department_ids uuid[] default '{}',all_employees boolean default false,start_date date default null) returns integer
language plpgsql security definer set search_path='' as $$
declare target_date date; affected integer;
begin
 if auth.uid() is null or not private.can_manage(store) then raise exception 'Manager access required'; end if;
 if not exists(select 1 from public.daily_releases r join public.daily_modules d on d.id=r.module_id where r.organization_id=store and d.id=module and d.published) then raise exception 'Release this Daily module to the store first'; end if;
 if exists(select 1 from unnest(coalesce(employee_ids,'{}'::uuid[])) e where e is null or not exists(select 1 from public.organization_memberships where id=e and organization_id=store and status='active')) then raise exception 'Employee is not active in this store'; end if;
 if exists(select 1 from unnest(coalesce(department_ids,'{}'::uuid[])) d where d is null or not exists(select 1 from public.training_departments where id=d and organization_id=store)) then raise exception 'Department is not in this store'; end if;
 select coalesce(start_date,(now() at time zone time_zone)::date) into target_date from public.organizations where id=store;
 insert into public.daily_assignments(organization_id,membership_id,module_id,available_on,assigned_by)
 select store,m.id,module,target_date,auth.uid() from public.organization_memberships m
 where m.organization_id=store and m.status='active' and (
 (coalesce(all_employees,false) and m.role='employee') or m.id=any(coalesce(employee_ids,'{}'::uuid[]))
 or exists(select 1 from public.training_member_departments d where d.membership_id=m.id and d.department_id=any(coalesce(department_ids,'{}'::uuid[]))))
 on conflict(membership_id,module_id) do update set available_on=case when daily_assignments.started_at is null then excluded.available_on else daily_assignments.available_on end;
 get diagnostics affected=row_count;
 if affected=0 then raise exception 'Choose at least one active employee or populated department'; end if;
 return affected;
end;
$$;

create function public.get_daily_workspace(store uuid) returns jsonb
language plpgsql stable security definer set search_path='' as $$
declare modules jsonb; assignments jsonb;
begin
 if auth.uid() is null or not (private.is_admin() or private.is_member(store)) then raise exception 'Active store access required'; end if;
 select coalesce(jsonb_agg(jsonb_build_object('id',d.id,'code',d.code,'version',d.version,'title',d.title,'academy',d.academy,
 'skill_level',d.skill_level,'keywords',d.keywords,'estimated_minutes',d.estimated_minutes,'published',d.published,
 'released',exists(select 1 from public.daily_releases r where r.organization_id=store and r.module_id=d.id)) order by d.code,d.created_at),'[]') into modules
 from public.daily_modules d where private.is_admin() or (d.published and exists(select 1 from public.daily_releases r where r.organization_id=store and r.module_id=d.id))
 or exists(select 1 from public.daily_assignments a where a.organization_id=store and a.module_id=d.id and (private.can_manage(store) or private.daily_is_learner(a.id,false)));
 select coalesce(jsonb_agg(jsonb_build_object('id',a.id,'membership_id',a.membership_id,'module_id',a.module_id,'available_on',a.available_on,
 'started_at',a.started_at,'completed_at',a.completed_at,'attempt_count',a.attempt_count,'active_seconds',a.active_seconds) order by a.available_on,a.assigned_at),'[]') into assignments
 from public.daily_assignments a where a.organization_id=store and (private.can_manage(store) or private.daily_is_learner(a.id,false));
 return jsonb_build_object('modules',modules,'assignments',assignments,'can_manage',private.can_manage(store),
 'is_admin',private.is_admin(),'today',(select (now() at time zone time_zone)::date from public.organizations where id=store));
end;
$$;
create function public.get_daily_module(assignment uuid) returns jsonb
language plpgsql security definer set search_path='' as $$
declare module uuid; data jsonb;
begin
 if not private.daily_is_learner(assignment) then raise exception 'Active available Daily assignment required'; end if;
 update public.daily_assignments set started_at=coalesce(started_at,now()),last_activity_at=now() where id=assignment returning module_id into module;
 select to_jsonb(d)||jsonb_build_object('questions',(select jsonb_agg(jsonb_build_object('id',q.id,'prompt',q.prompt,'options',q.options) order by q.position) from public.daily_questions q where q.module_id=d.id)) into data
 from public.daily_modules d where d.id=module;
 return data;
end;
$$;
create function public.record_daily_activity(assignment uuid) returns integer
language plpgsql security definer set search_path='' as $$
declare target public.daily_assignments%rowtype; delta integer;
begin
 select * into target from public.daily_assignments where id=assignment for update;
 if not found or not private.daily_is_learner(assignment) or target.started_at is null then raise exception 'Open your active Daily assignment first'; end if;
 if target.completed_at is not null then return target.active_seconds; end if;
 delta:=least(60,greatest(0,floor(extract(epoch from now()-target.last_activity_at))::integer));
 update public.daily_assignments set active_seconds=active_seconds+delta,last_activity_at=now() where id=assignment returning active_seconds into delta;
 return delta;
end;
$$;
create function public.submit_daily_check(assignment uuid,answers jsonb,submission_key uuid) returns jsonb
language plpgsql security definer set search_path='' as $$
declare target public.daily_assignments%rowtype; prior jsonb; graded record; selected integer; correct integer:=0; total integer; feedback jsonb:='[]'; result jsonb; attempt uuid:=gen_random_uuid();
begin
 select * into target from public.daily_assignments where id=assignment for update;
 if not found or not private.daily_is_learner(assignment) then raise exception 'Active available Daily assignment required'; end if;
 if submission_key is null then raise exception 'Submission key required'; end if;
 select a.result into prior from private.daily_attempts a where a.assignment_id=assignment and a.submission_key=submit_daily_check.submission_key;
 if found then return prior; end if;
 if target.completed_at is not null then raise exception 'Daily module already completed'; end if;
 if target.started_at is null then raise exception 'Open your Daily module first'; end if;
 if answers is null or jsonb_typeof(answers)<>'array' then raise exception 'Answer every Daily question'; end if;
 select count(*) into total from public.daily_questions where module_id=target.module_id;
 if total not between 1 and 2 or jsonb_array_length(answers)<>total then raise exception 'Answer every Daily question'; end if;
 if exists(select 1 from jsonb_array_elements(answers) a where jsonb_typeof(a)<>'object'
 or not (a ? 'question_id' and a ? 'option') or jsonb_typeof(a->'question_id')<>'string' or jsonb_typeof(a->'option')<>'number'
 or (a->>'option') !~ '^[0-3]$'
 or not exists(select 1 from public.daily_questions q where q.module_id=target.module_id and q.id=a->>'question_id'))
 or (select count(distinct a->>'question_id') from jsonb_array_elements(answers) a)<>total then raise exception 'Invalid Daily answers'; end if;
 for graded in select p.*,k.correct_option,k.explanation,k.teaching_reference from public.daily_questions p join private.daily_answer_keys k on k.module_id=p.module_id and k.question_id=p.id where p.module_id=target.module_id order by p.position loop
  select (a->>'option')::integer into selected from jsonb_array_elements(answers) a where a->>'question_id'=graded.id;
  if selected=graded.correct_option then correct:=correct+1; end if;
  feedback:=feedback||jsonb_build_array(jsonb_build_object('question_id',graded.id,'selected_option',selected,'correct_option',graded.correct_option,'is_correct',selected=graded.correct_option,'explanation',graded.explanation,'teaching_reference',graded.teaching_reference));
 end loop;
 if jsonb_array_length(feedback)<>total then raise exception 'Daily answer keys incomplete'; end if;
 update public.daily_assignments set attempt_count=attempt_count+1,completed_at=case when correct=total then now() else null end where id=assignment;
 result:=jsonb_build_object('id',attempt,'assignment_id',assignment,'attempt_number',target.attempt_count+1,'correct_count',correct,'question_count',total,'completed',correct=total,'feedback',feedback);
 insert into private.daily_attempts(id,assignment_id,submission_key,attempt_number,answers,result) values(attempt,assignment,submission_key,target.attempt_count+1,answers,result);
 return result;
end;
$$;
create function public.get_daily_result(assignment uuid) returns jsonb
language plpgsql stable security definer set search_path='' as $$
begin
 if not private.daily_is_learner(assignment) then raise exception 'Only the active Daily learner may view answers'; end if;
 return (select result from private.daily_attempts where assignment_id=assignment order by attempt_number desc limit 1);
end;
$$;

revoke all on function private.freeze_daily_content() from public,anon,authenticated;
revoke all on function public.publish_daily_module(uuid),public.release_daily_module(uuid,uuid,boolean),public.assign_daily_module(uuid,uuid,uuid[],uuid[],boolean,date),public.get_daily_workspace(uuid),public.get_daily_module(uuid),public.record_daily_activity(uuid),public.submit_daily_check(uuid,jsonb,uuid),public.get_daily_result(uuid) from public,anon;
grant execute on function public.publish_daily_module(uuid),public.release_daily_module(uuid,uuid,boolean),public.assign_daily_module(uuid,uuid,uuid[],uuid[],boolean,date),public.get_daily_workspace(uuid),public.get_daily_module(uuid),public.record_daily_activity(uuid),public.submit_daily_check(uuid,jsonb,uuid),public.get_daily_result(uuid) to authenticated;
notify pgrst,'reload schema';
commit;


-- 202610190013_daily_sequence.sql
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


-- 202610200014_admin_updates.sql
-- Role- and store-targeted in-app admin updates. Apply once after migration 013.
-- No existing posts/learning records changed. Queues opt-in email; delivery requires the new Edge Function.
begin;
create table private.admin_updates (
 id uuid primary key default gen_random_uuid(), created_by uuid not null references auth.users(id),
 submission_key uuid not null, title text not null check(length(btrim(title)) between 1 and 150),
 body text not null check(length(btrim(body)) between 1 and 6000),
 audience text not null check(audience in ('manager','employee','both')),
 store_ids uuid[] not null, all_stores boolean not null, link_url text,
 created_at timestamptz not null default clock_timestamp(), archived_at timestamptz,
 unique(created_by,submission_key),
 check(link_url is null or (length(link_url)<=2048 and link_url ~ '^https://[^[:space:]<>"'']+$'))
);
create table private.admin_update_recipients (
 update_id uuid not null references private.admin_updates(id), membership_id uuid not null,
 organization_id uuid not null, user_id uuid not null references auth.users(id), role_at_send text not null check(role_at_send in ('manager','employee')),
 primary key(update_id,membership_id),
 foreign key(organization_id,membership_id) references public.organization_memberships(organization_id,id)
);
create index admin_update_recipient_owner on private.admin_update_recipients(organization_id,user_id);
alter table private.admin_updates enable row level security;
alter table private.admin_update_recipients enable row level security;
revoke all on private.admin_updates,private.admin_update_recipients from public,anon,authenticated;

create table private.admin_update_email_queue (
 id uuid primary key default gen_random_uuid(), update_id uuid not null references private.admin_updates(id),
 membership_id uuid not null references public.organization_memberships(id), email text not null,
 status text not null default 'queued' check(status in ('queued','working','sent','failed','canceled','review')),
 lease_id uuid, leased_at timestamptz, first_attempt_at timestamptz, attempts integer not null default 0,
 provider_id text, last_error text, sent_at timestamptz, unique(update_id,membership_id)
);
alter table private.admin_update_email_queue enable row level security;
revoke all on private.admin_update_email_queue from public,anon,authenticated;

create function private.validate_admin_update(title text,body text,link_url text) returns void
language plpgsql set search_path='' as $$
begin
 if length(btrim(coalesce(title,''))) not between 1 and 150 then raise exception 'Add a title of 1–150 characters'; end if;
 if length(btrim(coalesce(body,''))) not between 1 and 6000 then raise exception 'Add a message of 1–6000 characters'; end if;
 if nullif(btrim(link_url),'') is not null and (length(link_url)>2048 or link_url !~ '^https://[^[:space:]<>"'']+$') then raise exception 'Use a complete https:// link without spaces'; end if;
end;
$$;
create function private.admin_update_targets(audience text,store_ids uuid[],all_stores boolean)
returns table(organization_id uuid,membership_id uuid,user_id uuid,member_role text)
language plpgsql stable security definer set search_path='' as $$
begin
 if auth.uid() is null or not private.is_admin() then raise exception 'Administrator access required'; end if;
 if audience is null or audience not in ('manager','employee','both') then raise exception 'Choose managers, employees, or both'; end if;
 if all_stores is null then raise exception 'Choose a store audience'; end if;
 if all_stores and cardinality(coalesce(store_ids,'{}'))>0 then raise exception 'Choose all stores or specific stores'; end if;
 if not all_stores and cardinality(coalesce(store_ids,'{}'))=0 then raise exception 'Choose at least one store'; end if;
 if exists(select 1 from unnest(coalesce(store_ids,'{}')) requested(store_id) where requested.store_id is null or not exists(select 1 from public.organizations o where o.id=requested.store_id)) then raise exception 'A selected store does not exist'; end if;
 return query select m.organization_id,m.id,m.user_id,m.role from public.organization_memberships m
 where m.status='active' and (all_stores or m.organization_id=any(store_ids)) and (audience='both' or m.role=audience);
end;
$$;
create function public.preview_admin_update(title text,body text,audience text,store_ids uuid[] default '{}',all_stores boolean default false,link_url text default null) returns jsonb
language plpgsql stable security definer set search_path='' as $$
declare result jsonb;
begin
 if not private.is_admin() then raise exception 'Administrator access required'; end if;
 perform private.validate_admin_update(title,body,link_url);
 select jsonb_build_object('recipient_count',coalesce(sum(t.managers+t.employees),0),'stores',coalesce(jsonb_agg(to_jsonb(t)),'[]'),'email_count',(select count(*) from private.admin_update_targets(audience,store_ids,all_stores) r join public.profiles p on p.user_id=r.user_id where p.optional_email_notifications)) into result
 from (select o.id,o.name,count(*) filter(where r.member_role='manager') managers,count(*) filter(where r.member_role='employee') employees
 from private.admin_update_targets(audience,store_ids,all_stores) r join public.organizations o on o.id=r.organization_id group by o.id,o.name order by o.name,o.id) t;
 if (result->>'recipient_count')::integer=0 then raise exception 'No active recipients match this audience'; end if;
 return result;
end;
$$;
create function public.send_admin_update(title text,body text,audience text,submission_key uuid,store_ids uuid[] default '{}',all_stores boolean default false,link_url text default null) returns jsonb
language plpgsql security definer set search_path='' as $$
declare target uuid; recipients integer; scope uuid[];
begin
 if auth.uid() is null or not private.is_admin() then raise exception 'Administrator access required'; end if;
 if submission_key is null then raise exception 'Submission key required'; end if;
 perform pg_advisory_xact_lock(hashtextextended('admin-update:'||auth.uid()::text||submission_key::text,0));
 select a.id into target from private.admin_updates a where a.created_by=auth.uid() and a.submission_key=send_admin_update.submission_key;
 if found then
  return jsonb_build_object('id',target,'recipient_count',(select count(*) from private.admin_update_recipients where update_id=target),'already_sent',true);
 end if;
 perform private.validate_admin_update(title,body,link_url);
 -- Materialize the validated current audience once inside this statement. No future members are subscribed retroactively.
 select array_agg(distinct r.organization_id) into scope from private.admin_update_targets(audience,store_ids,all_stores) r;
 if scope is null then raise exception 'No active recipients match this audience'; end if;
 insert into private.admin_updates(created_by,submission_key,title,body,audience,store_ids,all_stores,link_url)
 values(auth.uid(),submission_key,btrim(title),btrim(body),audience,scope,all_stores,nullif(btrim(link_url),'')) returning id into target;
 insert into private.admin_update_recipients(update_id,membership_id,organization_id,user_id,role_at_send)
 select target,r.membership_id,r.organization_id,r.user_id,r.member_role from private.admin_update_targets(audience,store_ids,all_stores) r;
 get diagnostics recipients=row_count;
 if recipients=0 then raise exception 'No active recipients match this audience'; end if;
 insert into private.admin_update_email_queue(update_id,membership_id,email)
 select target,r.membership_id,u.email from private.admin_update_recipients r join public.profiles p on p.user_id=r.user_id
 join auth.users u on u.id=r.user_id where r.update_id=target and p.optional_email_notifications and u.email is not null;

 return jsonb_build_object('id',target,'recipient_count',recipients,'already_sent',false);
end;
$$;
create function public.get_admin_updates() returns jsonb
language plpgsql stable security definer set search_path='' as $$
begin
 if not private.is_admin() then raise exception 'Administrator access required'; end if;
 return (select coalesce(jsonb_agg(jsonb_build_object('id',a.id,'title',a.title,'body',a.body,'audience',a.audience,
 'all_stores',a.all_stores,'link_url',a.link_url,'created_at',a.created_at,'archived_at',a.archived_at,
 'stores',(select coalesce(jsonb_agg(o.name order by o.name),'[]') from public.organizations o where o.id=any(a.store_ids)),
 'recipient_count',(select count(*) from private.admin_update_recipients r where r.update_id=a.id),
 'email_counts',(select coalesce(jsonb_object_agg(t.status,t.count),'{}') from (select status,count(*) from private.admin_update_email_queue q where q.update_id=a.id group by status) t),
 'read_count',(select count(*) from private.admin_update_recipients r join private.training_notifications n on n.user_id=r.user_id and n.organization_id=r.organization_id and n.event_key='admin-update:'||a.id::text where r.update_id=a.id and n.read_at is not null)) order by a.created_at desc,a.id),'[]') from private.admin_updates a);
end;
$$;
create function public.archive_admin_update(update_id uuid) returns void
language plpgsql security definer set search_path='' as $$
begin
 if not private.is_admin() then raise exception 'Administrator access required'; end if;
 update private.admin_updates set archived_at=coalesce(archived_at,clock_timestamp()) where id=update_id;
 if not found then raise exception 'Admin update not found'; end if;
end;
$$;

-- Service-only worker: recheck consent, active membership, role and archival before each delivery.
create function public.claim_admin_update_email(update_id uuid,retry_failed boolean default false) returns jsonb
language plpgsql security definer set search_path='' as $$
declare job private.admin_update_email_queue%rowtype; token uuid:=gen_random_uuid(); message private.admin_updates%rowtype; current_email text;
begin
 select * into message from private.admin_updates where id=update_id;
 if not found then return null; end if;
 for job in select q.* from private.admin_update_email_queue q where q.update_id=claim_admin_update_email.update_id
 and (q.status='queued' or q.status='failed' and retry_failed or q.status='working' and q.leased_at<now()-interval '5 minutes')
 order by q.attempts,q.id for update skip locked loop
  select u.email into current_email from public.organization_memberships m join public.profiles p on p.user_id=m.user_id join auth.users u on u.id=m.user_id
  where m.id=job.membership_id and m.status='active' and p.optional_email_notifications and (message.audience='both' or m.role=message.audience);
  if message.archived_at is not null or current_email is null or (job.first_attempt_at is not null and current_email<>job.email) then
   update private.admin_update_email_queue set status='canceled' where id=job.id;continue;
  end if;
  -- Resend retains idempotency keys for 24 hours; do not blindly replay ambiguous older sends.
  if job.first_attempt_at<now()-interval '23 hours' then
   update private.admin_update_email_queue set status='review',last_error='Review delivery before retrying an older request' where id=job.id;continue;
  end if;
  update private.admin_update_email_queue set status='working',lease_id=token,leased_at=clock_timestamp(),
   first_attempt_at=coalesce(first_attempt_at,clock_timestamp()),attempts=attempts+1,email=current_email where id=job.id;
  return jsonb_build_object('id',job.id,'lease_id',token,'email',current_email,'title',message.title,'body',message.body,'link_url',message.link_url);
 end loop;
 return null;
end;
$$;
create function public.finish_admin_update_email(delivery_id uuid,lease uuid,success boolean,provider_id text default null,error_message text default null) returns void
language plpgsql security definer set search_path='' as $$
begin
 update private.admin_update_email_queue set status=case when success then 'sent' else 'failed' end,
 provider_id=finish_admin_update_email.provider_id,last_error=case when success then null else left(error_message,300) end,
 sent_at=case when success then clock_timestamp() else null end
 where id=delivery_id and lease_id=lease and status='working';
 if not found then raise exception 'Email delivery lease is no longer active'; end if;
end;
$$;
revoke all on function public.claim_admin_update_email(uuid,boolean),public.finish_admin_update_email(uuid,uuid,boolean,text,text) from public,anon,authenticated;
grant execute on function public.claim_admin_update_email(uuid,boolean),public.finish_admin_update_email(uuid,uuid,boolean,text,text) to service_role;

-- Existing training reminders retain their original behavior. Announcements persist until archived.
alter function private.training_notification_candidates(uuid) rename to training_notification_candidates_before_admin;
revoke all on function private.training_notification_candidates_before_admin(uuid) from public,anon,authenticated;
create function private.training_notification_candidates(store uuid)
returns table(event_key text,kind text,title text,body text,course_id uuid,target_view text,competition_id uuid,event_at timestamptz)
language sql stable security definer set search_path='' as $$
 select * from private.training_notification_candidates_before_admin(store)
 union all
 select 'admin-update:'||a.id::text,'admin_update',a.title,a.body,null::uuid,'notifications',null::uuid,a.created_at
 from private.admin_updates a join private.admin_update_recipients r on r.update_id=a.id
 join public.organization_memberships m on m.id=r.membership_id
 where r.organization_id=store and r.user_id=auth.uid() and m.user_id=auth.uid() and m.status='active'
 and a.archived_at is null and (a.audience='both' or m.role=a.audience);
$$;
alter function public.get_my_training_notifications(uuid) set schema private;
alter function private.get_my_training_notifications(uuid) rename to notifications_before_admin_updates;
revoke all on function private.notifications_before_admin_updates(uuid) from public,anon,authenticated;
create function public.get_my_training_notifications(store uuid) returns jsonb
language plpgsql security definer set search_path='' as $$
declare base jsonb; items jsonb;
begin
 base:=private.notifications_before_admin_updates(store);
 select coalesce(jsonb_agg(x.item||case when a.id is not null then jsonb_build_object('admin_update_id',a.id,'link_url',a.link_url) else '{}'::jsonb end order by x.position),'[]') into items
 from jsonb_array_elements(base->'items') with ordinality x(item,position)
 left join private.training_notifications n on n.id=(x.item->>'id')::uuid and n.user_id=auth.uid() and n.organization_id=store
 left join private.admin_updates a on n.event_key='admin-update:'||a.id::text;
 return base||jsonb_build_object('items',items);
end;
$$;
revoke all on function private.validate_admin_update(text,text,text),private.admin_update_targets(text,uuid[],boolean),private.training_notification_candidates(uuid) from public,anon,authenticated;
revoke all on function public.preview_admin_update(text,text,text,uuid[],boolean,text),public.send_admin_update(text,text,text,uuid,uuid[],boolean,text),public.get_admin_updates(),public.archive_admin_update(uuid),public.get_my_training_notifications(uuid) from public,anon;
grant execute on function public.preview_admin_update(text,text,text,uuid[],boolean,text),public.send_admin_update(text,text,text,uuid,uuid[],boolean,text),public.get_admin_updates(),public.archive_admin_update(uuid),public.get_my_training_notifications(uuid) to authenticated;
notify pgrst,'reload schema';
commit;


-- 202610220015_employee_onboarding.sql
-- Apply once after 014. No invitation emails or historical login alerts are sent.
begin;
-- Only new/reactivated employee memberships receive courses; current assignments are preserved.
create function private.enroll_employee_courses() returns trigger
language plpgsql security definer set search_path='' as $$
begin
 if new.status='active' and new.role='employee' then
  insert into public.training_assignments(organization_id,membership_id,course_id,due_date,assigned_by)
  select new.organization_id,new.id,c.id,(now() at time zone o.time_zone)::date+30,r.released_by
  from public.training_course_releases r join public.training_courses c on c.id=r.course_id
  join public.organizations o on o.id=r.organization_id
  where r.organization_id=new.organization_id and c.published
   and (c.owner_organization_id is null or c.owner_organization_id=new.organization_id)
   and not exists(select 1 from public.training_course_releases nr join public.training_courses nc on nc.id=nr.course_id
    where nr.organization_id=new.organization_id and nc.published and nc.slug=c.slug and nc.version>c.version)
   and exists(select 1 from public.training_lessons where course_id=c.id)
   and exists(select 1 from public.training_questions where course_id=c.id)
   and not exists(select 1 from public.training_questions q left join private.training_answer_keys k on k.question_id=q.id
    where q.course_id=c.id and (k.question_id is null or k.correct_option>=jsonb_array_length(q.options)))
  on conflict(membership_id,course_id) do nothing;
 end if;
 return new;
end;
$$;
create trigger employee_course_enrollment after insert or update of status,role on public.organization_memberships
 for each row execute function private.enroll_employee_courses();
revoke all on function private.enroll_employee_courses() from public,anon,authenticated;

create table private.employee_first_logins (
 membership_id uuid primary key references public.organization_memberships(id),
 first_login_at timestamptz, baseline boolean not null default false
);
create table private.employee_login_recipients (
 id uuid primary key default gen_random_uuid(),
 employee_membership_id uuid not null references private.employee_first_logins(membership_id),
 manager_membership_id uuid not null references public.organization_memberships(id),
 organization_id uuid not null references public.organizations(id),
 email text, status text not null check(status in ('queued','working','sent','failed','canceled','review')),
 lease_id uuid,leased_at timestamptz,first_attempt_at timestamptz,provider_id text,last_error text,
 unique(employee_membership_id,manager_membership_id)
);
alter table private.employee_first_logins enable row level security;
alter table private.employee_login_recipients enable row level security;
revoke all on private.employee_first_logins,private.employee_login_recipients from public,anon,authenticated;
-- Existing accounts start as a baseline, so upgrading does not announce old users as new.
insert into private.employee_first_logins(membership_id,baseline)
 select id,true from public.organization_memberships;

create function public.record_employee_first_login() returns jsonb
language plpgsql security definer set search_path='' as $$
declare mine public.organization_memberships%rowtype; fresh uuid;
begin
 if auth.uid() is null then raise exception 'Sign in first'; end if;
 select * into mine from public.organization_memberships where user_id=auth.uid() and status='active' limit 1;
 if not found then return jsonb_build_object('recorded',false); end if;
 if mine.role='employee' then
  insert into private.employee_first_logins(membership_id,first_login_at) values(mine.id,clock_timestamp())
   on conflict do nothing returning membership_id into fresh;
  if fresh is not null then
   insert into private.employee_login_recipients(employee_membership_id,manager_membership_id,organization_id,email,status)
   select mine.id,m.id,m.organization_id,u.email,case when coalesce(p.optional_email_notifications,false) then 'queued' else 'canceled' end
   from public.organization_memberships m join auth.users u on u.id=m.user_id
   left join public.profiles p on p.user_id=m.user_id
   where m.organization_id=mine.organization_id and m.role='manager' and m.status='active';
  end if;
 end if;
 return jsonb_build_object('recorded',fresh is not null);
end;
$$;

alter function private.training_notification_candidates(uuid) rename to training_notification_candidates_before_login;
revoke all on function private.training_notification_candidates_before_login(uuid) from public,anon,authenticated;
create function private.training_notification_candidates(store uuid)
returns table(event_key text,kind text,title text,body text,course_id uuid,target_view text,competition_id uuid,event_at timestamptz)
language sql stable security definer set search_path='' as $$
 select * from private.training_notification_candidates_before_login(store)
 union all
 select 'employee-first-login:'||f.membership_id::text,'employee_first_login','An employee has signed in',
 coalesce(nullif(p.full_name,''),split_part(e.email,'@',1))||' has signed in to '||o.name||' for the first time.',
 null::uuid,'home',null::uuid,f.first_login_at
 from private.employee_first_logins f join public.organization_memberships e on e.id=f.membership_id
 join private.employee_login_recipients r on r.employee_membership_id=f.membership_id
 join public.organization_memberships m on m.id=r.manager_membership_id
 join public.organizations o on o.id=m.organization_id left join public.profiles p on p.user_id=e.user_id
 where not f.baseline and m.organization_id=store and m.user_id=auth.uid() and m.role='manager' and m.status='active';
$$;
revoke all on function private.training_notification_candidates(uuid) from public,anon,authenticated;

-- The worker passes the user ID independently verified with Auth. Browser roles cannot call these RPCs.
create function public.claim_employee_login_email(actor uuid) returns jsonb
language plpgsql security definer set search_path='' as $$
declare job private.employee_login_recipients%rowtype; recipient record; employee record; token uuid:=gen_random_uuid();
begin
 select r.* into job from private.employee_login_recipients r
 join public.organization_memberships e on e.id=r.employee_membership_id
 join public.organization_memberships m on m.id=r.manager_membership_id
 where (e.user_id=actor and e.status='active' or m.user_id=actor and m.role='manager' and m.status='active')
 and (r.status in ('queued','failed') or r.status='working' and r.leased_at<now()-interval '5 minutes')
 order by r.id for update of r skip locked limit 1;
 if not found then return null; end if;
 select m.*,u.email current_email,p.optional_email_notifications into recipient
 from public.organization_memberships m join auth.users u on u.id=m.user_id
 left join public.profiles p on p.user_id=m.user_id where m.id=job.manager_membership_id;
 select coalesce(nullif(p.full_name,''),split_part(m.email,'@',1)) person,o.name store_name,m.status
 into employee from public.organization_memberships m join public.organizations o on o.id=m.organization_id
 left join public.profiles p on p.user_id=m.user_id where m.id=job.employee_membership_id;
 if recipient.status<>'active' or recipient.role<>'manager' or not coalesce(recipient.optional_email_notifications,false)
 or employee.status<>'active' or (job.first_attempt_at is not null and job.email is distinct from recipient.current_email) then
  update private.employee_login_recipients set status='canceled' where id=job.id;
  return jsonb_build_object('skip',true);
 end if;
 if job.first_attempt_at<now()-interval '23 hours' then
  update private.employee_login_recipients set status='review' where id=job.id;
  return jsonb_build_object('skip',true);
 end if;
 update private.employee_login_recipients set status='working',email=recipient.current_email,lease_id=token,leased_at=clock_timestamp(),
 first_attempt_at=coalesce(first_attempt_at,clock_timestamp()) where id=job.id;
 return jsonb_build_object('id',job.id,'lease_id',token,'email',recipient.current_email,
 'title','An employee has signed in to colTRAIN','body',employee.person||' has signed in to '||employee.store_name||' for the first time.');
end;
$$;
create function public.finish_employee_login_email(delivery_id uuid,lease uuid,success boolean,provider_id text default null,error_message text default null)
returns void language plpgsql security definer set search_path='' as $$
begin
 update private.employee_login_recipients r set status=case when success then 'sent' else 'failed' end,
 provider_id=finish_employee_login_email.provider_id,last_error=left(error_message,200)
 where r.id=delivery_id and r.lease_id=lease and r.status='working';
 if not found then raise exception 'Email lease expired'; end if;
end;
$$;
revoke all on function public.record_employee_first_login() from public,anon;
grant execute on function public.record_employee_first_login() to authenticated;
revoke all on function public.claim_employee_login_email(uuid),public.finish_employee_login_email(uuid,uuid,boolean,text,text) from public,anon,authenticated;
grant execute on function public.claim_employee_login_email(uuid),public.finish_employee_login_email(uuid,uuid,boolean,text,text) to service_role;
notify pgrst,'reload schema';
commit;


-- 202610220016_daily_points.sql
-- Apply once after 015. Credit prior completed drills, once per person and stable module code.
begin;
create table private.daily_point_awards (
 user_id uuid not null references auth.users(id), module_code text not null,
 module_id uuid not null references public.daily_modules(id), assignment_id uuid not null references public.daily_assignments(id),
 points integer not null default 5 check(points=5),earned_at timestamptz not null default clock_timestamp(),
 primary key(user_id,module_code)
);
alter table private.daily_point_awards enable row level security;
revoke all on private.daily_point_awards from public,anon,authenticated;
insert into private.daily_point_awards(user_id,module_code,module_id,assignment_id,earned_at)
 select distinct on(m.user_id,d.code) m.user_id,d.code,d.id,a.id,a.completed_at
 from public.daily_assignments a join public.organization_memberships m on m.id=a.membership_id
 join public.daily_modules d on d.id=a.module_id where a.completed_at is not null
 order by m.user_id,d.code,a.completed_at,a.id;
create function private.award_daily_completion() returns trigger
language plpgsql security definer set search_path='' as $$
begin
 if new.completed_at is not null then
  insert into private.daily_point_awards(user_id,module_code,module_id,assignment_id,earned_at)
  select m.user_id,d.code,d.id,new.id,new.completed_at from public.organization_memberships m
  join public.daily_modules d on d.id=new.module_id where m.id=new.membership_id
  on conflict(user_id,module_code) do nothing;
 end if;
 return new;
end;
$$;
create trigger daily_completion_points after insert or update of completed_at on public.daily_assignments
 for each row execute function private.award_daily_completion();
revoke all on function private.award_daily_completion() from public,anon,authenticated;
create function private.learner_point_totals(learner uuid) returns jsonb
language sql stable security definer set search_path='' as $$
 select jsonb_build_object('course_points',c,'daily_points',d,'lifetime_points',c+d)
 from (select coalesce(sum(points),0) c from private.training_point_awards where user_id=learner) a
 cross join (select coalesce(sum(points),0) d from private.daily_point_awards where user_id=learner) b;
$$;
revoke all on function private.learner_point_totals(uuid) from public,anon,authenticated;

alter function public.submit_daily_check(uuid,jsonb,uuid) set schema private;
alter function private.submit_daily_check(uuid,jsonb,uuid) rename to submit_daily_before_points;
create or replace function private.submit_daily_before_points(assignment uuid,answers jsonb,submission_key uuid) returns jsonb
language plpgsql security definer set search_path='' as $$
declare target public.daily_assignments%rowtype; prior jsonb; graded record; selected integer; correct integer:=0; total integer; feedback jsonb:='[]'; result jsonb; attempt uuid:=gen_random_uuid();
begin
 select * into target from public.daily_assignments where id=assignment for update;
 if not found or not private.daily_is_learner(assignment) then raise exception 'Active available Daily assignment required'; end if;
 if submission_key is null then raise exception 'Submission key required'; end if;
 select a.result into prior from private.daily_attempts a where a.assignment_id=assignment and a.submission_key=submit_daily_before_points.submission_key;
 if found then return prior; end if;
 if target.completed_at is not null then raise exception 'Daily module already completed'; end if;
 if target.started_at is null then raise exception 'Open your Daily module first'; end if;
 if answers is null or jsonb_typeof(answers)<>'array' then raise exception 'Answer every Daily question'; end if;
 select count(*) into total from public.daily_questions where module_id=target.module_id;
 if total not between 1 and 2 or jsonb_array_length(answers)<>total then raise exception 'Answer every Daily question'; end if;
 if exists(select 1 from jsonb_array_elements(answers) a where jsonb_typeof(a)<>'object'
 or not (a ? 'question_id' and a ? 'option') or jsonb_typeof(a->'question_id')<>'string' or jsonb_typeof(a->'option')<>'number'
 or (a->>'option') !~ '^[0-3]$'
 or not exists(select 1 from public.daily_questions q where q.module_id=target.module_id and q.id=a->>'question_id'))
 or (select count(distinct a->>'question_id') from jsonb_array_elements(answers) a)<>total then raise exception 'Invalid Daily answers'; end if;
 for graded in select p.*,k.correct_option,k.explanation,k.teaching_reference from public.daily_questions p join private.daily_answer_keys k on k.module_id=p.module_id and k.question_id=p.id where p.module_id=target.module_id order by p.position loop
  select (a->>'option')::integer into selected from jsonb_array_elements(answers) a where a->>'question_id'=graded.id;
  if selected=graded.correct_option then correct:=correct+1; end if;
  feedback:=feedback||jsonb_build_array(jsonb_build_object('question_id',graded.id,'selected_option',selected,'correct_option',graded.correct_option,'is_correct',selected=graded.correct_option,'explanation',graded.explanation,'teaching_reference',graded.teaching_reference));
 end loop;
 if jsonb_array_length(feedback)<>total then raise exception 'Daily answer keys incomplete'; end if;
 update public.daily_assignments set attempt_count=attempt_count+1,completed_at=case when correct=total then now() else null end where id=assignment;
 result:=jsonb_build_object('id',attempt,'assignment_id',assignment,'attempt_number',target.attempt_count+1,'correct_count',correct,'question_count',total,'completed',correct=total,'feedback',feedback);
 insert into private.daily_attempts(id,assignment_id,submission_key,attempt_number,answers,result) values(attempt,assignment,submission_key,target.attempt_count+1,answers,result);
 return result;
end;
$$;

revoke all on function private.submit_daily_before_points(uuid,jsonb,uuid) from public,anon,authenticated;
create function public.submit_daily_check(assignment uuid,answers jsonb,submission_key uuid) returns jsonb
language plpgsql security definer set search_path='' as $$
declare check_result jsonb; already_awarded boolean; prior jsonb;
begin
 -- Serialize competing submissions before inspecting awards; the grader enforces learner/sequence access.
 perform 1 from public.daily_assignments a where a.id=assignment for update;
 if not private.daily_is_learner(assignment) then raise exception 'Active available Daily assignment required'; end if;
 select a.result into prior from private.daily_attempts a where a.assignment_id=assignment and a.submission_key=submit_daily_check.submission_key;
 if prior ? 'new_points' then return prior; end if;
 select exists(select 1 from private.daily_point_awards p join public.daily_modules d on d.code=p.module_code
  join public.daily_assignments a on a.module_id=d.id where a.id=assignment and p.user_id=auth.uid()) into already_awarded;
 check_result:=private.submit_daily_before_points(assignment,answers,submission_key);
 check_result:=check_result||jsonb_build_object('new_points',case when (check_result->>'completed')::boolean and not already_awarded and exists(select 1 from private.daily_point_awards p where p.assignment_id=assignment and p.user_id=auth.uid()) then 5 else 0 end,
 'daily_points',(private.learner_point_totals(auth.uid())->>'daily_points')::bigint);
 update private.daily_attempts a set result=check_result where a.id=(check_result->>'id')::uuid;
 return check_result;
end;
$$;
-- Preserve old feedback without claiming that retroactive points were earned on a new attempt.
update private.daily_attempts set result=result||jsonb_build_object('new_points',0) where not(result ? 'new_points');

alter function public.get_daily_workspace(uuid) set schema private;
alter function private.get_daily_workspace(uuid) rename to daily_workspace_before_points;
revoke all on function private.daily_workspace_before_points(uuid) from public,anon,authenticated;
create function public.get_daily_workspace(store uuid) returns jsonb
language plpgsql stable security definer set search_path='' as $$
declare base jsonb;
begin
 base:=private.daily_workspace_before_points(store);
 return base||jsonb_build_object('points_per_drill',5,'daily_points',(private.learner_point_totals(auth.uid())->>'daily_points')::bigint);
end;
$$;

create or replace function private.training_competition_report(competition uuid)
returns jsonb language plpgsql stable security definer set search_path='' as $$
declare target public.training_competitions%rowtype; closing timestamptz; opening timestamptz; managing boolean; rows jsonb; result jsonb; eligible_count integer; done_count integer; current_state text;
begin
 select * into target from public.training_competitions where id=competition;
 if not found or not(private.can_manage(target.organization_id) or private.is_member(target.organization_id)) then raise exception 'Active store access required'; end if;
 managing:=private.can_manage(target.organization_id);
 closing:=least(target.ends_at,coalesce(target.ended_early_at,target.ends_at),coalesce(target.canceled_at,target.ends_at));
 opening:=greatest(target.starts_at,target.created_at);
 current_state:=case when target.canceled_at is not null then 'canceled' when now()<target.starts_at then 'scheduled' when now()<closing then 'active' else 'ended' end;
 with participants as (
  select p.*,m.user_id,m.deactivated_at,case when m.deactivated_at is not null and m.deactivated_at<=closing then true else false end withdrawn,
   a.completed_at is not null and a.completed_at<=closing and exists(select 1 from private.training_challenge_attempts t where t.competition_id=p.competition_id and t.membership_id=p.membership_id and t.passed and t.submitted_at<closing) completed,
   coalesce((select max(t.points) from private.training_challenge_attempts t where t.competition_id=p.competition_id and t.membership_id=p.membership_id and t.submitted_at>=opening and t.submitted_at<closing and (m.deactivated_at is null or t.submitted_at<m.deactivated_at)),0)::integer competition_points,
   (select count(*) from private.training_challenge_attempts t where t.competition_id=p.competition_id and t.membership_id=p.membership_id) attempts_used,
   a.completed_at is not null course_completed,
   (private.learner_point_totals(m.user_id)->>'lifetime_points')::bigint lifetime_points,
   case when managing then coalesce((select sum(greatest(0,extract(epoch from least(i.ended_at,closing,coalesce(m.deactivated_at,closing))-greatest(i.started_at,opening))))::integer from private.training_learning_intervals i where i.assignment_id=p.assignment_id and i.ended_at>opening and i.started_at<closing),0) else null end learning_seconds
  from public.training_competition_participants p join public.organization_memberships m on m.id=p.membership_id join public.training_assignments a on a.id=p.assignment_id where p.competition_id=competition
 ), ranked as (
  select p.*,case when not withdrawn then (select count(*)+1 from participants other where not other.withdrawn and other.competition_points>p.competition_points) end rank from participants p
 ) select coalesce(jsonb_agg(jsonb_build_object('membership_id',membership_id,'name',display_name,'is_you',user_id=auth.uid(),'withdrawn',withdrawn,'completed',completed,'competition_points',competition_points,'lifetime_points',lifetime_points,'learning_seconds',learning_seconds,'rank',rank,'attempts_used',attempts_used,'attempt_limit',attempt_limit,'course_completed',course_completed) order by withdrawn,competition_points desc,display_name,membership_id),'[]'::jsonb),count(*) filter(where not withdrawn),count(*) filter(where not withdrawn and completed)
 into rows,eligible_count,done_count from ranked;
 result:=to_jsonb(target)||jsonb_build_object('course_title',(select title from public.training_courses where id=target.course_id),'status',current_state,'standings',rows,'participants',eligible_count,'completed',done_count,'completion_percent',case when eligible_count>0 then done_count*100/eligible_count else 0 end,'learning_seconds',case when managing then (select coalesce(sum((x->>'learning_seconds')::integer),0) from jsonb_array_elements(rows) x) else null end,
 'team_goal_met',current_state<>'canceled' and eligible_count>0 and done_count=eligible_count,
 'top_score',coalesce((select max((x->>'competition_points')::integer) from jsonb_array_elements(rows) x where not (x->>'withdrawn')::boolean),0));
 return result;
end;
$$;
revoke all on function private.training_competition_report(uuid) from public,anon,authenticated;

alter function public.get_training_workspace(uuid) set schema private;
alter function private.get_training_workspace(uuid) rename to training_workspace_before_daily_points;
revoke all on function private.training_workspace_before_daily_points(uuid) from public,anon,authenticated;
create function public.get_training_workspace(store uuid) returns jsonb
language plpgsql stable security definer set search_path='' as $$
declare base jsonb; roster jsonb; standings jsonb; competitions jsonb;
begin
 base:=private.training_workspace_before_daily_points(store);
 -- Enrich only members already authorized by the original store-scoped report.
 select coalesce(jsonb_agg(x.item||private.learner_point_totals(m.user_id) order by x.position),'[]') into roster
 from jsonb_array_elements(base->'members') with ordinality x(item,position)
 join public.organization_memberships m on m.id=(x.item->>'id')::uuid and m.organization_id=store;
 select coalesce(jsonb_agg(x.item||p.totals||jsonb_build_object('points',(p.totals->>'lifetime_points')::bigint)
 order by (p.totals->>'lifetime_points')::bigint desc,x.item->>'name',x.item->>'membership_id'),'[]') into standings
 from jsonb_array_elements(base->'lifetime_standings') x(item)
 join public.organization_memberships m on m.id=(x.item->>'membership_id')::uuid and m.organization_id=store
 cross join lateral (select private.learner_point_totals(m.user_id) totals) p;
 select coalesce(jsonb_agg(x.item||jsonb_build_object('standings',(
 select coalesce(jsonb_agg(y.person||private.learner_point_totals(m.user_id) order by y.position),'[]')
 from jsonb_array_elements(x.item->'standings') with ordinality y(person,position)
 join public.organization_memberships m on m.id=(y.person->>'membership_id')::uuid and m.organization_id=store
 )) order by x.position),'[]') into competitions
 from jsonb_array_elements(base->'competitions') with ordinality x(item,position);
 return base||jsonb_build_object('members',roster,'lifetime_standings',standings,'competitions',competitions,
 'totals',(base->'totals')||private.learner_point_totals(auth.uid()));
end;
$$;
revoke all on function public.submit_daily_check(uuid,jsonb,uuid),public.get_daily_workspace(uuid),public.get_training_workspace(uuid) from public,anon;
grant execute on function public.submit_daily_check(uuid,jsonb,uuid),public.get_daily_workspace(uuid),public.get_training_workspace(uuid) to authenticated;
notify pgrst,'reload schema';
commit;


-- 202610220017_manager_course_deadlines.sql
-- Apply once after updates 015 and 016. Managers choose course deadlines; no automatic 30-day dates.
begin;
alter table public.training_assignments alter column due_date drop not null;
create or replace function private.enroll_employee_courses() returns trigger
language plpgsql security definer set search_path='' as $$
begin
 if new.status='active' and new.role='employee' then
  insert into public.training_assignments(organization_id,membership_id,course_id,due_date,assigned_by)
  select new.organization_id,new.id,c.id,null::date,r.released_by
  from public.training_course_releases r join public.training_courses c on c.id=r.course_id
  join public.organizations o on o.id=r.organization_id
  where r.organization_id=new.organization_id and c.published
   and (c.owner_organization_id is null or c.owner_organization_id=new.organization_id)
   and not exists(select 1 from public.training_course_releases nr join public.training_courses nc on nc.id=nr.course_id
    where nr.organization_id=new.organization_id and nc.published and nc.slug=c.slug and nc.version>c.version)
   and exists(select 1 from public.training_lessons where course_id=c.id)
   and exists(select 1 from public.training_questions where course_id=c.id)
   and not exists(select 1 from public.training_questions q left join private.training_answer_keys k on k.question_id=q.id
    where q.course_id=c.id and (k.question_id is null or k.correct_option>=jsonb_array_length(q.options)))
  on conflict(membership_id,course_id) do nothing;
 end if;
 return new;
end;
$$;

create or replace function public.assign_training(course uuid, store uuid, employee_ids uuid[] default '{}', department_ids uuid[] default '{}', all_employees boolean default false, deadline date default null)
returns integer language plpgsql security definer set search_path='' as $$
declare assigned_count integer; target_date date;
begin
 if auth.uid() is null or not private.can_manage(store) then raise exception 'Manager access required'; end if;
 if not exists(select 1 from public.training_course_releases r join public.training_courses c on c.id=r.course_id where r.organization_id=store and r.course_id=course and c.published) then raise exception 'Release this course to the store before assigning it'; end if;
 if not exists(select 1 from public.training_lessons where course_id=course) or not exists(select 1 from public.training_questions where course_id=course) or exists(select 1 from public.training_questions q left join private.training_answer_keys k on k.question_id=q.id where q.course_id=course and (k.question_id is null or k.correct_option>=jsonb_array_length(q.options))) then raise exception 'Course content is not ready for assignment'; end if;
 if exists(select 1 from unnest(coalesce(employee_ids,'{}'::uuid[])) e where e is null or not exists(select 1 from public.organization_memberships where id=e and organization_id=store and status='active')) then raise exception 'Employee is not active in this store'; end if;
 if exists(select 1 from unnest(coalesce(department_ids,'{}'::uuid[])) d where d is null or not exists(select 1 from public.training_departments where id=d and organization_id=store)) then raise exception 'Department is not in this store'; end if;
 target_date:=deadline;
 insert into public.training_assignments(organization_id,membership_id,course_id,due_date,assigned_by)
 select store,m.id,course,target_date,auth.uid() from public.organization_memberships m
 where m.organization_id=store and m.status='active' and (
 (coalesce(all_employees,false) and m.role='employee') or m.id=any(coalesce(employee_ids,'{}'::uuid[])) or exists(select 1 from public.training_member_departments d where d.membership_id=m.id and d.department_id=any(coalesce(department_ids,'{}'::uuid[]))))
 on conflict(membership_id,course_id) do update set due_date=excluded.due_date;
 get diagnostics assigned_count=row_count;
 if assigned_count=0 then raise exception 'Choose at least one active employee or populated department'; end if;
 return assigned_count;
end;
$$;

create or replace function private.training_notification_candidates_before_admin(store uuid)
returns table(event_key text,kind text,title text,body text,course_id uuid,target_view text,competition_id uuid,event_at timestamptz)
language sql stable security definer set search_path='' as $$
 with me as (
  select m.* from public.organization_memberships m where m.organization_id=store and m.user_id=auth.uid() and m.status='active'
 ), pending as (
  select a.*,m.user_id,m.role,coalesce(p.full_name,split_part(m.email,'@',1)) person,c.title course_title,
   (now() at time zone o.time_zone)::date today,
   (select count(*) from public.training_attempts t where t.assignment_id=a.id) used,
   (select max(t.submitted_at) from public.training_attempts t where t.assignment_id=a.id) latest_attempt,
   (select max(u.created_at) from public.training_retry_unlocks u where u.assignment_id=a.id) latest_unlock
  from public.training_assignments a join public.organization_memberships m on m.id=a.membership_id
  join public.training_courses c on c.id=a.course_id join public.organizations o on o.id=a.organization_id
  left join public.profiles p on p.user_id=m.user_id
  where a.organization_id=store and m.status='active' and a.completed_at is null
   and (m.user_id=auth.uid() or exists(select 1 from me where role='manager'))
 ), regular as (
  select v.event_key,v.kind,v.title,v.body,a.course_id,v.target_view,null::uuid competition_id,v.event_at
  from pending a cross join lateral (
   values
   ('assignment:'||a.id||':'||coalesce(a.due_date::text,'no-deadline'),'assignment','Training assignment',a.course_title||case when a.due_date is null then ' · No deadline set' else ' · Due '||to_char(a.due_date,'Mon DD, YYYY') end,'course',a.assigned_at,a.user_id=auth.uid()),
   ('deadline:'||a.id||':'||a.due_date||':'||case when a.due_date<a.today then 'overdue' when a.due_date=a.today then 'today' when a.due_date=a.today+1 then 'tomorrow' else 'soon' end,
    'deadline',case when a.due_date<a.today then 'Training overdue' when a.due_date=a.today then 'Training due today' when a.due_date=a.today+1 then 'Training due tomorrow' else 'Training due soon' end,
    a.course_title||' · Due '||to_char(a.due_date,'Mon DD, YYYY')||case when a.due_date<a.today then '. You can still complete this course.' else '.' end,
    'course',now(),a.user_id=auth.uid() and a.due_date<=a.today+3),
   ('help:'||a.id||':'||a.attempt_limit,'help_needed',case when a.user_id=auth.uid() then 'Ask your manager for help' else 'An employee needs quiz help' end,
    case when a.user_id=auth.uid() then a.course_title||' · Review the material with your manager before another attempt.' else a.person||' · '||a.course_title||' · Review the material together, then unlock one attempt.' end,
    case when a.user_id=auth.uid() then 'course' else 'home' end,coalesce(a.latest_attempt,a.assigned_at),a.used>=a.attempt_limit),
   ('retry:'||a.id||':'||a.attempt_limit,'retry_unlocked','Another quiz attempt is ready',a.course_title||' · Your manager unlocked one additional attempt. Your previous points are saved.',
    'course',coalesce(a.latest_unlock,a.assigned_at),a.user_id=auth.uid() and a.attempt_limit>3 and a.used<a.attempt_limit)
  ) v(event_key,kind,title,body,target_view,event_at,visible)
  where v.visible
 ), challenge as (
  select e.*,p.membership_id,p.attempt_limit,m.user_id,p.display_name,
   (select count(*) from private.training_challenge_attempts t where t.competition_id=e.id and t.membership_id=p.membership_id) used,
   (select max(t.submitted_at) from private.training_challenge_attempts t where t.competition_id=e.id and t.membership_id=p.membership_id) latest_attempt,
   (select max(t.created_at) from private.training_challenge_unlocks t where t.competition_id=e.id and t.membership_id=p.membership_id) latest_unlock
  from public.training_competitions e join public.training_competition_participants p on p.competition_id=e.id
  join public.organization_memberships m on m.id=p.membership_id
  where e.organization_id=store and m.status='active' and e.canceled_at is null and e.ended_early_at is null and now()>=e.starts_at and now()<e.ends_at
   and (m.user_id=auth.uid() or exists(select 1 from me where role='manager'))
   and not exists(select 1 from private.training_challenge_attempts t where t.competition_id=e.id and t.membership_id=p.membership_id and t.passed)
 )
 select * from regular
 union all
 select v.event_key,v.kind,v.title,v.body,c.course_id,'competitions',c.id,v.event_at
 from challenge c cross join lateral (
  values
  ('challenge-help:'||c.id||':'||c.membership_id||':'||c.attempt_limit,'challenge_help',case when c.user_id=auth.uid() then 'Ask for competition quiz help' else 'An employee needs competition quiz help' end,
   case when c.user_id=auth.uid() then c.name||' · Review the material with your manager before another competition attempt.' else c.display_name||' · '||c.name||' · Review together, then unlock one competition attempt.' end,
   coalesce(c.latest_attempt,c.created_at),c.used>=c.attempt_limit),
  ('challenge-retry:'||c.id||':'||c.membership_id||':'||c.attempt_limit,'challenge_retry','Another competition attempt is ready',c.name||' · Your manager unlocked one additional competition quiz attempt.',coalesce(c.latest_unlock,c.created_at),c.user_id=auth.uid() and c.attempt_limit>3 and c.used<c.attempt_limit)
 ) v(event_key,kind,title,body,event_at,visible) where v.visible;
$$;

revoke all on function private.enroll_employee_courses(),private.training_notification_candidates_before_admin(uuid) from public,anon,authenticated;
revoke all on function public.assign_training(uuid,uuid,uuid[],uuid[],boolean,date) from public,anon;
grant execute on function public.assign_training(uuid,uuid,uuid[],uuid[],boolean,date) to authenticated;
-- Existing deadlines are preserved: they may have been chosen by a manager.
notify pgrst,'reload schema';
commit;


-- 202610220018_promote_store_manager.sql
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


-- 202610220019_private_team_support.sql
-- Apply once after 018. Private employee/selected-manager support conversations.
begin;
create table private.support_threads (
 id uuid primary key default gen_random_uuid(),organization_id uuid not null references public.organizations(id),
 employee_id uuid not null,manager_id uuid not null,created_by uuid not null references auth.users(id),
 subject text not null check(length(btrim(subject)) between 1 and 150),
 category text not null check(category in ('emergency','work','app','customer','general','other')),
 created_at timestamptz not null default clock_timestamp(),updated_at timestamptz not null default clock_timestamp(),
 archived_at timestamptz,deleted_at timestamptz,changed_by uuid references auth.users(id),
 foreign key(organization_id,employee_id) references public.organization_memberships(organization_id,id),
 foreign key(organization_id,manager_id) references public.organization_memberships(organization_id,id),check(employee_id<>manager_id)
);
create table private.support_messages (
 id uuid primary key default gen_random_uuid(),seq bigint generated always as identity unique,
 thread_id uuid not null references private.support_threads(id) on delete cascade,
 author_id uuid not null references auth.users(id),author_member uuid not null references public.organization_memberships(id),
 author_name text not null,body text not null check(length(btrim(body)) between 1 and 5000),emergency boolean not null default false,
 submission_key uuid not null,created_at timestamptz not null default clock_timestamp(),unique(author_id,submission_key)
);
create index support_message_thread on private.support_messages(thread_id,seq);
create table private.support_receipts (
 message_id uuid not null references private.support_messages(id) on delete cascade,
 membership_id uuid not null references public.organization_memberships(id),read_at timestamptz,
 primary key(message_id,membership_id)
);
create table private.support_email_queue (
 id uuid primary key default gen_random_uuid(),message_id uuid not null unique references private.support_messages(id) on delete cascade,
 manager_id uuid not null references public.organization_memberships(id),email text,
 status text not null default 'queued' check(status in ('queued','working','sent','failed','canceled','review')),
 lease_id uuid,leased_at timestamptz,first_attempt_at timestamptz,provider_id text,last_error text
);
alter table private.support_threads enable row level security;
alter table private.support_messages enable row level security;
alter table private.support_receipts enable row level security;
alter table private.support_email_queue enable row level security;
revoke all on private.support_threads,private.support_messages,private.support_receipts,private.support_email_queue from public,anon,authenticated;
create index support_thread_people on private.support_threads(organization_id,employee_id,manager_id,updated_at desc);
create function private.support_access(thread uuid,person uuid default auth.uid()) returns boolean
language sql stable security definer set search_path='' as $$
 select exists(select 1 from private.support_threads t join public.organization_memberships m on m.organization_id=t.organization_id
 where t.id=thread and m.user_id=person and m.status='active' and (m.id=t.employee_id or m.id=t.manager_id and m.role='manager'));
$$;
create function private.support_manager(thread uuid,person uuid default auth.uid()) returns boolean
language sql stable security definer set search_path='' as $$
 select exists(select 1 from private.support_threads t join public.organization_memberships m on m.id=t.manager_id
 where t.id=thread and m.user_id=person and m.status='active' and m.role='manager');
$$;
create function private.purge_support_trash(store uuid) returns void
language plpgsql security definer set search_path='' as $$
begin
 -- Only threads assigned to this signed-in manager; no platform-admin bypass.
 delete from private.training_notifications n using private.support_messages m,private.support_threads t
 where t.organization_id=store and private.support_manager(t.id) and t.deleted_at<now()-interval '30 days'
 and m.thread_id=t.id and n.event_key='support-message:'||m.id::text;
 delete from private.support_threads t where t.organization_id=store and private.support_manager(t.id) and t.deleted_at<now()-interval '30 days';
end;
$$;
-- The scheduled cleanup has no user bypass: it only erases expired Trash, never live conversations.
create function private.purge_expired_support_trash() returns void
language plpgsql security definer set search_path='' as $$
begin
 delete from private.training_notifications n using private.support_messages m,private.support_threads t
 where t.deleted_at<now()-interval '30 days' and m.thread_id=t.id and n.event_key='support-message:'||m.id::text;
 delete from private.support_threads where deleted_at<now()-interval '30 days';
end;
$$;
revoke all on function private.purge_expired_support_trash() from public,anon,authenticated,service_role;
create function private.support_thread_json(thread uuid) returns jsonb
language sql stable security definer set search_path='' as $$
 select to_jsonb(t)||jsonb_build_object('can_manage',private.support_manager(t.id),
 'employee_name',coalesce(nullif(ep.full_name,''),split_part(e.email,'@',1)),
 'manager_name',coalesce(nullif(mp.full_name,''),split_part(m.email,'@',1)),
 'can_reply',t.deleted_at is null and e.status='active' and m.status='active' and m.role='manager',
 'unread_count',(select count(*) from private.support_receipts r join private.support_messages x on x.id=r.message_id
 join public.organization_memberships me on me.id=r.membership_id where x.thread_id=t.id and me.user_id=auth.uid() and r.read_at is null),
 'last_body',(select left(body,160) from private.support_messages where thread_id=t.id order by seq desc limit 1),
 'has_emergency',exists(select 1 from private.support_messages where thread_id=t.id and emergency),
 'email_pending',(select count(*) from private.support_email_queue q join private.support_messages x on x.id=q.message_id where x.thread_id=t.id and q.status in ('queued','working','failed')))
 from private.support_threads t join public.organization_memberships e on e.id=t.employee_id
 join public.organization_memberships m on m.id=t.manager_id left join public.profiles ep on ep.user_id=e.user_id left join public.profiles mp on mp.user_id=m.user_id
 where t.id=thread and private.support_access(t.id);
$$;
create function public.get_team_support_workspace(store uuid,folder text default 'inbox',keywords text default '',page integer default 0) returns jsonb
language plpgsql security definer set search_path='' as $$
declare me public.organization_memberships%rowtype; rows jsonb; recipients jsonb; total integer;
begin
 select * into me from public.organization_memberships where organization_id=store and user_id=auth.uid() and status='active';
 if not found then raise exception 'Active store membership required'; end if;
 if folder not in ('inbox','archive','trash') or page is null or page<0 or page>10000 or length(coalesce(keywords,''))>200 then raise exception 'Invalid message search'; end if;
 perform private.purge_support_trash(store);
 select coalesce(jsonb_agg(jsonb_build_object('id',m.id,'name',coalesce(nullif(p.full_name,''),split_part(m.email,'@',1)),'role',m.role) order by coalesce(p.full_name,m.email)),'[]') into recipients
 from public.organization_memberships m left join public.profiles p on p.user_id=m.user_id where m.organization_id=store and m.status='active' and m.id<>me.id and m.role=case when me.role='manager' then 'employee' else 'manager' end;
 with matches as (
 select t.id,t.updated_at from private.support_threads t where t.organization_id=store and private.support_access(t.id)
 and case folder when 'trash' then t.deleted_at is not null and t.deleted_at>=now()-interval '30 days' and private.support_manager(t.id)
 when 'archive' then t.deleted_at is null and t.archived_at is not null else t.deleted_at is null and t.archived_at is null end
 and (btrim(coalesce(keywords,''))='' or to_tsvector('english',t.subject||' '||coalesce((select string_agg(x.body,' ') from private.support_messages x where x.thread_id=t.id),'')) @@ websearch_to_tsquery('english',keywords))
 ), limited as (select * from matches order by updated_at desc,id limit 25 offset page*25)
 select (select count(*) from matches),coalesce(jsonb_agg(private.support_thread_json(l.id) order by l.updated_at desc,l.id),'[]') into total,rows from limited l;
 return jsonb_build_object('is_manager',me.role='manager','my_membership',me.id,'recipients',recipients,'threads',rows,'total',total,'page',page,'has_more',(page+1)*25<total);
end;
$$;
create function public.get_team_support_thread(thread uuid,before_seq bigint default null) returns jsonb
language plpgsql security definer set search_path='' as $$
declare target private.support_threads%rowtype; messages jsonb; cutoff bigint; earliest bigint;
begin
 select * into target from private.support_threads where id=thread;
 if not found or not private.support_access(thread) or target.deleted_at is not null and (not private.support_manager(thread) or target.deleted_at<now()-interval '30 days') then raise exception 'Private conversation not available'; end if;
 select coalesce(jsonb_agg(to_jsonb(x) order by x.seq),'[]'),max(x.seq),min(x.seq) into messages,cutoff,earliest
 from (select id,seq,author_member,author_name,body,emergency,created_at from private.support_messages where thread_id=thread and (before_seq is null or seq<before_seq) order by seq desc limit 50) x;
 return jsonb_build_object('thread',private.support_thread_json(thread),'messages',messages,'read_through',cutoff,
 'has_older',exists(select 1 from private.support_messages where thread_id=thread and seq<earliest),
 'email_counts',(select coalesce(jsonb_object_agg(s.status,s.n),'{}') from (select q.status,count(*) n from private.support_email_queue q join private.support_messages m on m.id=q.message_id where m.thread_id=thread group by q.status)s));
end;
$$;
create function public.mark_team_support_read(thread uuid,through_seq bigint,from_seq bigint default 0) returns integer
language plpgsql security definer set search_path='' as $$
begin
 if not private.support_access(thread) then raise exception 'Private conversation not available'; end if;
 update private.support_receipts r set read_at=coalesce(read_at,clock_timestamp()) from private.support_messages x,public.organization_memberships me
 where x.id=r.message_id and x.thread_id=thread and x.seq<=through_seq and x.seq>=from_seq and me.id=r.membership_id and me.user_id=auth.uid() and me.status='active';
 update private.training_notifications n set read_at=coalesce(n.read_at,r.read_at) from private.support_receipts r,private.support_messages x,public.organization_memberships me
 where r.message_id=x.id and x.thread_id=thread and me.id=r.membership_id and me.user_id=auth.uid() and n.user_id=auth.uid() and n.event_key='support-message:'||x.id::text;
 return (select count(*)::integer from private.support_receipts r join private.support_messages x on x.id=r.message_id join public.organization_memberships me on me.id=r.membership_id where x.thread_id=thread and me.user_id=auth.uid() and r.read_at is null);
end;
$$;
create function public.send_team_support_message(store uuid,submission_key uuid,message_body text,thread uuid default null,recipient uuid default null,category text default 'general',subject text default null,emergency boolean default false) returns jsonb
language plpgsql security definer set search_path='' as $$
declare me public.organization_memberships%rowtype; target private.support_threads%rowtype; other public.organization_memberships%rowtype; prior private.support_messages%rowtype; new_id uuid:=gen_random_uuid(); name text; urgent boolean;
begin
 select * into me from public.organization_memberships where organization_id=store and user_id=auth.uid() and status='active';
 if not found then raise exception 'Active store membership required'; end if;
 if submission_key is null then raise exception 'Submission key required'; end if;
 perform pg_advisory_xact_lock(hashtextextended(auth.uid()::text||':'||submission_key::text,0));
 select * into prior from private.support_messages x where x.author_id=auth.uid() and x.submission_key=send_team_support_message.submission_key;
 if found then
  if not private.support_access(prior.thread_id) or not exists(select 1 from private.support_threads where id=prior.thread_id and deleted_at is null) then raise exception 'Private conversation not available'; end if;
  return jsonb_build_object('thread_id',prior.thread_id,'message_id',prior.id,'emergency',prior.emergency);
 end if;
 if message_body is null or length(btrim(message_body)) not between 1 and 5000 then raise exception 'Enter a message of up to 5,000 characters'; end if;
 if thread is null then
  if category is null or category not in ('emergency','work','app','customer','general','other') or subject is null or length(btrim(subject)) not between 1 and 150 then raise exception 'Choose a category and enter a subject'; end if;
  select * into other from public.organization_memberships where id=recipient and organization_id=store and status='active' and role=case when me.role='manager' then 'employee' else 'manager' end;
  if not found then raise exception 'Choose an active recipient from this store'; end if;
  insert into private.support_threads(organization_id,employee_id,manager_id,created_by,subject,category)
  values(store,case when me.role='manager' then other.id else me.id end,case when me.role='manager' then me.id else other.id end,auth.uid(),btrim(subject),category) returning * into target;
 else
  select * into target from private.support_threads where id=thread for update;
  if not found or target.organization_id<>store or not private.support_access(thread) or target.deleted_at is not null then raise exception 'Private conversation not available'; end if;
  if not exists(select 1 from public.organization_memberships where id=target.employee_id and status='active') or not exists(select 1 from public.organization_memberships where id=target.manager_id and role='manager' and status='active') then raise exception 'A participant is no longer active; start a new conversation with an active manager'; end if;
 end if;
 select coalesce(nullif(full_name,''),split_part(me.email,'@',1)) into name from public.profiles where user_id=auth.uid();
 urgent:=coalesce(emergency,false) or target.category='emergency';
 insert into private.support_messages(id,thread_id,author_id,author_member,author_name,body,emergency,submission_key)
 values(new_id,target.id,auth.uid(),me.id,coalesce(name,split_part(me.email,'@',1)),btrim(message_body),urgent,submission_key);
 insert into private.support_receipts(message_id,membership_id) values(new_id,case when me.id=target.manager_id then target.employee_id else target.manager_id end);
 if urgent then insert into private.support_email_queue(message_id,manager_id) values(new_id,target.manager_id); end if;
 update private.support_threads set updated_at=clock_timestamp(),archived_at=null where id=target.id;
 return jsonb_build_object('thread_id',target.id,'message_id',new_id,'emergency',urgent);
end;
$$;
create function public.set_team_support_state(thread uuid,action text) returns void
language plpgsql security definer set search_path='' as $$
declare target private.support_threads%rowtype;
begin
 select * into target from private.support_threads where id=thread for update;
 if not found or not private.support_manager(thread) then raise exception 'Only the selected manager can manage this conversation'; end if;
 if target.deleted_at<now()-interval '30 days' then raise exception 'Recovery period has expired'; end if;
 if action='restore' and target.deleted_at is not null then
  update private.support_threads set deleted_at=null,archived_at=null,changed_by=auth.uid() where id=thread;
 elsif target.deleted_at is not null then raise exception 'Restore this conversation before making changes';
 elsif action='archive' then update private.support_threads set archived_at=clock_timestamp(),changed_by=auth.uid() where id=thread;
 elsif action='unarchive' then update private.support_threads set archived_at=null,changed_by=auth.uid() where id=thread;
 elsif action='delete' then update private.support_threads set deleted_at=clock_timestamp(),changed_by=auth.uid() where id=thread;
 else raise exception 'Choose archive, unarchive, delete or restore'; end if;
end;
$$;
-- Extend the existing inbox without exposing another person's private conversations.
alter function private.training_notification_candidates(uuid) rename to training_notification_candidates_before_support;
revoke all on function private.training_notification_candidates_before_support(uuid) from public,anon,authenticated;
create function private.training_notification_candidates(store uuid)
returns table(event_key text,kind text,title text,body text,course_id uuid,target_view text,competition_id uuid,event_at timestamptz)
language sql stable security definer set search_path='' as $$
 select * from private.training_notification_candidates_before_support(store)
 union all
 select 'support-message:'||x.id::text,'support_message',case when x.emergency then 'Emergency private message' else 'New private message' end,
 x.author_name||' · '||t.subject,null::uuid,'messages',null::uuid,x.created_at
 from private.support_receipts r join private.support_messages x on x.id=r.message_id
 join private.support_threads t on t.id=x.thread_id join public.organization_memberships me on me.id=r.membership_id
 where t.organization_id=store and me.user_id=auth.uid() and private.support_access(t.id) and t.deleted_at is null;
$$;
alter function public.get_my_training_notifications(uuid) set schema private;
alter function private.get_my_training_notifications(uuid) rename to notifications_before_private_support;
revoke all on function private.notifications_before_private_support(uuid) from public,anon,authenticated;
create function public.get_my_training_notifications(store uuid) returns jsonb
language plpgsql security definer set search_path='' as $$
declare base jsonb; items jsonb;
begin
 base:=private.notifications_before_private_support(store);
 update private.training_notifications n set read_at=coalesce(n.read_at,r.read_at) from private.support_receipts r,private.support_messages x,public.organization_memberships me
 where x.id=r.message_id and me.id=r.membership_id and me.user_id=auth.uid() and n.user_id=auth.uid() and n.organization_id=store and n.event_key='support-message:'||x.id::text;
 select coalesce(jsonb_agg(item||case when x.id is not null then jsonb_build_object('support_thread_id',x.thread_id,'read_at',n.read_at,'created_at',x.created_at) else '{}'::jsonb end order by position),'[]') into items
 from jsonb_array_elements(base->'items') with ordinality a(item,position)
 left join private.training_notifications n on n.id=(item->>'id')::uuid and n.user_id=auth.uid() and n.organization_id=store
 left join private.support_messages x on n.event_key='support-message:'||x.id::text;
 return base||jsonb_build_object('items',items,'unread_count',(select count(*) from jsonb_array_elements(items)i where i->>'read_at' is null));
end;
$$;
alter function public.mark_training_notifications_read(uuid,uuid[],boolean) set schema private;
alter function private.mark_training_notifications_read(uuid,uuid[],boolean) rename to mark_notifications_before_support;
revoke all on function private.mark_notifications_before_support(uuid,uuid[],boolean) from public,anon,authenticated;
create function public.mark_training_notifications_read(store uuid,notification_ids uuid[] default '{}',mark_all boolean default false) returns void
language plpgsql security definer set search_path='' as $$
begin
 perform private.mark_notifications_before_support(store,notification_ids,mark_all);
 update private.support_receipts r set read_at=coalesce(r.read_at,n.read_at) from private.support_messages x,private.training_notifications n,public.organization_memberships me
 where r.message_id=x.id and me.id=r.membership_id and me.user_id=auth.uid() and me.status='active'
 and n.organization_id=store and n.user_id=auth.uid() and n.event_key='support-message:'||x.id::text;
end;
$$;
-- Emergency email intentionally ignores optional email opt-out, as approved by the owner.
create function public.claim_support_email(actor uuid) returns jsonb
language plpgsql security definer set search_path='' as $$
declare job private.support_email_queue%rowtype; message private.support_messages%rowtype; target private.support_threads%rowtype; recipient record; token uuid:=gen_random_uuid();
begin
 select q.* into job from private.support_email_queue q join private.support_messages x on x.id=q.message_id
 where (actor is null or private.support_access(x.thread_id,actor)) and (q.status in ('queued','failed') or q.status='working' and q.leased_at<now()-interval '5 minutes')
 order by q.leased_at nulls first,q.id for update of q skip locked limit 1;
 if not found then return null; end if;
 select * into message from private.support_messages where id=job.message_id;
 select * into target from private.support_threads where id=message.thread_id;
 select m.*,u.email current_email into recipient from public.organization_memberships m join auth.users u on u.id=m.user_id where m.id=target.manager_id;
 if target.deleted_at is not null or recipient.status<>'active' or recipient.role<>'manager' or (job.first_attempt_at is not null and job.email is distinct from recipient.current_email) then
  update private.support_email_queue set status='canceled' where id=job.id;return jsonb_build_object('skip',true);
 end if;
 if job.first_attempt_at<now()-interval '23 hours' then
  update private.support_email_queue set status='review' where id=job.id;return jsonb_build_object('skip',true);
 end if;
 update private.support_email_queue set status='working',lease_id=token,email=recipient.current_email,leased_at=clock_timestamp(),first_attempt_at=coalesce(first_attempt_at,clock_timestamp()) where id=job.id;
 return jsonb_build_object('id',job.id,'lease_id',token,'email',recipient.current_email,'thread_id',target.id,
 'body','An Emergency private message from '||message.author_name||' is waiting for you in colTRAIN. Sign in to read it.');
end;
$$;
create function public.finish_support_email(delivery_id uuid,lease uuid,success boolean,provider_id text default null) returns void
language plpgsql security definer set search_path='' as $$
begin
 update private.support_email_queue q set status=case when success then 'sent' else 'failed' end,provider_id=finish_support_email.provider_id,
 last_error=case when success then null else 'Provider did not confirm acceptance' end
 where q.id=delivery_id and q.lease_id=lease and q.status='working';
 if not found then raise exception 'Email lease expired'; end if;
end;
$$;
revoke all on function private.support_access(uuid,uuid),private.support_manager(uuid,uuid),private.purge_support_trash(uuid),private.support_thread_json(uuid),private.training_notification_candidates(uuid) from public,anon,authenticated;
revoke all on function public.get_team_support_workspace(uuid,text,text,integer),public.get_team_support_thread(uuid,bigint),public.mark_team_support_read(uuid,bigint,bigint),public.send_team_support_message(uuid,uuid,text,uuid,uuid,text,text,boolean),public.set_team_support_state(uuid,text),public.get_my_training_notifications(uuid),public.mark_training_notifications_read(uuid,uuid[],boolean) from public,anon;
grant execute on function public.get_team_support_workspace(uuid,text,text,integer),public.get_team_support_thread(uuid,bigint),public.mark_team_support_read(uuid,bigint,bigint),public.send_team_support_message(uuid,uuid,text,uuid,uuid,text,text,boolean),public.set_team_support_state(uuid,text),public.get_my_training_notifications(uuid),public.mark_training_notifications_read(uuid,uuid[],boolean) to authenticated;
revoke all on function public.claim_support_email(uuid),public.finish_support_email(uuid,uuid,boolean,text) from public,anon,authenticated;
grant execute on function public.claim_support_email(uuid),public.finish_support_email(uuid,uuid,boolean,text) to service_role;
notify pgrst,'reload schema';
commit;


-- 202610220020_web_push.sql
-- Optional, personal-device Web Push. No live delivery until function/cron deployment.
begin;
create table private.web_push_subscriptions(
 id uuid primary key default gen_random_uuid(), user_id uuid not null references auth.users(id) on delete cascade,
 endpoint text not null unique, p256dh text not null, auth_key text not null,
 seen_ids jsonb not null default '[]', next_scan_at timestamptz not null default now(),
 lease uuid, leased_at timestamptz, created_at timestamptz not null default now(), failures integer not null default 0
);
alter table private.web_push_subscriptions enable row level security;
revoke all on private.web_push_subscriptions from public,anon,authenticated;
-- Internal snapshot evaluates existing recipient/role/store privacy rules as the owner.
create function private.push_snapshot(person uuid) returns jsonb
language plpgsql security definer set search_path='' as $$
declare old_sub text:=current_setting('request.jwt.claim.sub',true); old_claims text:=current_setting('request.jwt.claims',true); m record; result jsonb; ids jsonb:='[]';
begin
 perform set_config('request.jwt.claim.sub',person::text,true);
 perform set_config('request.jwt.claims',jsonb_build_object('sub',person,'role','authenticated')::text,true);
 for m in select distinct organization_id from public.organization_memberships where user_id=person and status='active' loop
  result:=public.get_my_training_notifications(m.organization_id);
  select ids||coalesce(jsonb_agg(i->>'id'),'[]') into ids from jsonb_array_elements(result->'items')i where i->>'read_at' is null;
 end loop;
 perform set_config('request.jwt.claim.sub',coalesce(old_sub,''),true);perform set_config('request.jwt.claims',coalesce(old_claims,''),true);
 return jsonb_build_object('ids',ids,'count',jsonb_array_length(ids));
exception when others then
 perform set_config('request.jwt.claim.sub',coalesce(old_sub,''),true);perform set_config('request.jwt.claims',coalesce(old_claims,''),true);raise;
end;$$;
revoke all on function private.push_snapshot(uuid) from public,anon,authenticated,service_role;
create function public.get_my_web_push_count() returns integer
language plpgsql security definer set search_path='' as $$
begin
 if auth.uid() is null then raise exception 'Sign in first';end if;
 return (private.push_snapshot(auth.uid())->>'count')::integer;
end;$$;
revoke all on function public.get_my_web_push_count() from public,anon;
grant execute on function public.get_my_web_push_count() to authenticated;
create function public.save_web_push(push_endpoint text,public_key text,auth_secret text) returns void
language plpgsql security definer set search_path='' as $$
begin
 if auth.uid() is null or not exists(select 1 from public.organization_memberships where user_id=auth.uid() and status='active') then raise exception 'Active store membership required';end if;
 if length(push_endpoint)>4096 or push_endpoint !~ '^https://(fcm\.googleapis\.com|updates\.push\.services\.mozilla\.com|web\.push\.apple\.com|[a-zA-Z0-9-]+\.notify\.windows\.com)/[^[:space:]]+$'
 or public_key !~ '^[A-Za-z0-9_-]{87}$' or auth_secret !~ '^[A-Za-z0-9_-]{22}$' then raise exception 'Invalid push subscription';end if;
 perform pg_advisory_xact_lock(hashtextextended(auth.uid()::text,20));
 if exists(select 1 from private.web_push_subscriptions where endpoint=push_endpoint and user_id<>auth.uid()) then raise exception 'Turn off notifications on this browser before switching accounts';end if;
 if (select count(*) from private.web_push_subscriptions where user_id=auth.uid())>=10 and not exists(select 1 from private.web_push_subscriptions where endpoint=push_endpoint and user_id=auth.uid()) then raise exception 'Up to 10 personal devices are supported';end if;
 insert into private.web_push_subscriptions(user_id,endpoint,p256dh,auth_key,seen_ids)
 values(auth.uid(),push_endpoint,public_key,auth_secret,private.push_snapshot(auth.uid())->'ids')
 on conflict(endpoint) do update set p256dh=excluded.p256dh,auth_key=excluded.auth_key,seen_ids=excluded.seen_ids,next_scan_at=now(),failures=0;
end;$$;
create function public.get_web_push_status(push_endpoint text) returns boolean
language sql stable security definer set search_path='' as $$
 select auth.uid() is not null and exists(select 1 from private.web_push_subscriptions where user_id=auth.uid() and endpoint=push_endpoint);
$$;
create function public.remove_web_push(push_endpoint text) returns void
language sql security definer set search_path='' as $$
 delete from private.web_push_subscriptions where user_id=auth.uid() and endpoint=push_endpoint;
$$;
-- Only the authenticated scheduled worker can call these service-only RPCs.
create function public.claim_web_push() returns jsonb
language plpgsql security definer set search_path='' as $$
declare s private.web_push_subscriptions%rowtype; snapshot jsonb; token uuid:=gen_random_uuid();fresh boolean;
begin
 select * into s from private.web_push_subscriptions where next_scan_at<=now() and (lease is null or leased_at<now()-interval '5 minutes') order by next_scan_at,id for update skip locked limit 1;
 if not found then return null;end if;
 snapshot:=private.push_snapshot(s.user_id);
 select exists(select 1 from jsonb_array_elements_text(snapshot->'ids')i where not s.seen_ids ? i) into fresh;
 if not fresh then
  update private.web_push_subscriptions set seen_ids=snapshot->'ids',next_scan_at=now()+interval '1 minute',lease=null where id=s.id;
  return jsonb_build_object('skip',true);
 end if;
 update private.web_push_subscriptions set lease=token,leased_at=now(),next_scan_at=now()+interval '1 minute' where id=s.id;
 return jsonb_build_object('id',s.id,'lease',token,'subscription',jsonb_build_object('endpoint',s.endpoint,'keys',jsonb_build_object('p256dh',s.p256dh,'auth',s.auth_key)),
 'ids',snapshot->'ids','count',snapshot->'count');
end;$$;
create function public.finish_web_push(subscription_id uuid,claim_lease uuid,unread_ids jsonb,outcome text) returns void
language plpgsql security definer set search_path='' as $$
begin
 if outcome='expired' then delete from private.web_push_subscriptions where id=subscription_id and lease=claim_lease;return;end if;
 update private.web_push_subscriptions set seen_ids=case when outcome='sent' then unread_ids else seen_ids end,
 failures=case when outcome='sent' then 0 else failures+1 end,lease=null,
 next_scan_at=now()+case when outcome='sent' then interval '1 minute' else interval '5 minutes' end
 where id=subscription_id and lease=claim_lease;
end;$$;
revoke all on function public.save_web_push(text,text,text),public.get_web_push_status(text),public.remove_web_push(text) from public,anon;
grant execute on function public.save_web_push(text,text,text),public.get_web_push_status(text),public.remove_web_push(text) to authenticated;
revoke all on function public.claim_web_push(),public.finish_web_push(uuid,uuid,jsonb,text) from public,anon,authenticated;
grant execute on function public.claim_web_push(),public.finish_web_push(uuid,uuid,jsonb,text) to service_role;
notify pgrst,'reload schema';
commit;


-- 202610220021_team_post_notifications.sql
-- Notify active store teammates about new Team Corner posts only; no historical backfill.
begin;
create table private.team_post_audience(
 post_id uuid not null references public.team_corner_posts(id) on delete cascade,
 membership_id uuid not null references public.organization_memberships(id) on delete cascade,
 primary key(post_id,membership_id)
);
alter table private.team_post_audience enable row level security;
revoke all on private.team_post_audience from public,anon,authenticated;
create function private.notify_new_team_post() returns trigger
language plpgsql security definer set search_path='' as $$
begin
 if new.deleted_at is null then
  insert into private.team_post_audience(post_id,membership_id)
  select new.id,m.id from public.organization_memberships m where m.organization_id=new.organization_id
   and m.status='active' and m.user_id<>new.author_id
  on conflict do nothing;
 end if;
 return new;
end;$$;
revoke all on function private.notify_new_team_post() from public,anon,authenticated,service_role;
create trigger coltrain_new_team_post after insert on public.team_corner_posts
for each row execute function private.notify_new_team_post();
alter function private.training_notification_candidates(uuid) rename to notifications_before_team_posts;
revoke all on function private.notifications_before_team_posts(uuid) from public,anon,authenticated;
create function private.training_notification_candidates(store uuid)
returns table(event_key text,kind text,title text,body text,course_id uuid,target_view text,competition_id uuid,event_at timestamptz)
language sql stable security definer set search_path='' as $$
 select * from private.notifications_before_team_posts(store)
 union all
 select 'team-post:'||p.id::text,'team_post',case when p.announcement then 'New Team Corner announcement' else 'New Team Corner post' end,
 p.author_name||' shared a post with your team.',null::uuid,'team',null::uuid,p.created_at
 from private.team_post_audience a join public.team_corner_posts p on p.id=a.post_id
 join public.organization_memberships m on m.id=a.membership_id
 where p.organization_id=store and m.organization_id=store and m.user_id=auth.uid() and m.status='active'
  and m.user_id<>p.author_id and p.deleted_at is null;
$$;
revoke all on function private.training_notification_candidates(uuid) from public,anon,authenticated;
alter function public.get_my_training_notifications(uuid) set schema private;
alter function private.get_my_training_notifications(uuid) rename to notifications_before_team_post_details;
revoke all on function private.notifications_before_team_post_details(uuid) from public,anon,authenticated;
create function public.get_my_training_notifications(store uuid) returns jsonb
language plpgsql security definer set search_path='' as $$
declare base jsonb;items jsonb;
begin
 base:=private.notifications_before_team_post_details(store);
 select coalesce(jsonb_agg(i||case when p.id is not null then jsonb_build_object('team_post_id',p.id,'created_at',p.created_at) else '{}'::jsonb end order by position),'[]') into items
 from jsonb_array_elements(base->'items') with ordinality a(i,position)
 left join private.training_notifications n on n.id=(i->>'id')::uuid and n.user_id=auth.uid() and n.organization_id=store
 left join public.team_corner_posts p on n.event_key='team-post:'||p.id::text and p.organization_id=store and p.deleted_at is null;
 return base||jsonb_build_object('items',items);
end;$$;
create function public.get_team_corner_post(post uuid) returns jsonb
language plpgsql stable security definer set search_path='' as $$
declare result jsonb;
begin
 if not private.team_corner_post_visible(post) then raise exception 'Store feed access required';end if;
 select private.team_corner_post_json(p) into result from public.team_corner_posts p where p.id=post and p.deleted_at is null;
 return result;
end;$$;
revoke all on function public.get_my_training_notifications(uuid),public.get_team_corner_post(uuid) from public,anon;
grant execute on function public.get_my_training_notifications(uuid),public.get_team_corner_post(uuid) to authenticated;
notify pgrst,'reload schema';
commit;


-- 202610220022_group_private_messages.sql
-- Apply once after 021. Preserve existing messages; expand fixed participant groups.
begin;
-- Finish the previously approved cleanup before migrating legacy Trash.
do $$begin perform private.purge_expired_support_trash();end$$;
alter table private.support_threads alter column employee_id drop not null;
alter table private.support_threads alter column manager_id drop not null;
alter table private.support_threads add unique(id,organization_id);
create table private.support_participants(
 thread_id uuid not null, organization_id uuid not null,membership_id uuid not null,
 archived_at timestamptz,deleted_at timestamptz,
 primary key(thread_id,membership_id),
 foreign key(thread_id,organization_id) references private.support_threads(id,organization_id) on delete cascade,
 foreign key(organization_id,membership_id) references public.organization_memberships(organization_id,id)
);
alter table private.support_participants enable row level security;
revoke all on private.support_participants from public,anon,authenticated;
insert into private.support_participants(thread_id,organization_id,membership_id,archived_at,deleted_at)
select id,organization_id,employee_id,archived_at,deleted_at from private.support_threads
union all select id,organization_id,manager_id,archived_at,deleted_at from private.support_threads;
-- Inbox state belongs to participants from now on. Legacy identities remain for audit/history.
update private.support_threads set archived_at=null,deleted_at=null;
alter table private.support_email_queue drop constraint support_email_queue_message_id_key;
alter table private.support_email_queue add unique(message_id,manager_id);
create or replace function private.support_access(thread uuid,person uuid default auth.uid()) returns boolean
language sql stable security definer set search_path='' as $$
 select exists(select 1 from private.support_participants p join public.organization_memberships m on m.id=p.membership_id and m.organization_id=p.organization_id
 where p.thread_id=thread and m.user_id=person and m.status='active' and (p.deleted_at is null or p.deleted_at>=now()-interval '30 days'));
$$;
create or replace function private.support_manager(thread uuid,person uuid default auth.uid()) returns boolean
language sql stable security definer set search_path='' as $$
 select exists(select 1 from private.support_participants p join public.organization_memberships m on m.id=p.membership_id
 where p.thread_id=thread and m.user_id=person and m.status='active' and m.role='manager' and (p.deleted_at is null or p.deleted_at>=now()-interval '30 days'));
$$;
create or replace function private.purge_expired_support_trash() returns void
language plpgsql security definer set search_path='' as $$
begin
 -- Expired personal copies lose access even when other participants keep their history.
 delete from private.training_notifications n using private.support_messages x,private.support_participants p,public.organization_memberships m
 where n.event_key='support-message:'||x.id::text and x.thread_id=p.thread_id and m.id=p.membership_id and n.user_id=m.user_id and p.deleted_at<now()-interval '30 days';
 delete from private.support_threads t where exists(select 1 from private.support_participants where thread_id=t.id)
 and not exists(select 1 from private.support_participants p where p.thread_id=t.id and (p.deleted_at is null or p.deleted_at>=now()-interval '30 days'));
end;$$;
create or replace function private.purge_support_trash(store uuid) returns void
language plpgsql security definer set search_path='' as $$
begin
 -- Physical group cleanup is handled by the existing hourly owner job.
 delete from private.training_notifications n using private.support_messages x,private.support_participants p,public.organization_memberships m
 where p.organization_id=store and n.event_key='support-message:'||x.id::text and x.thread_id=p.thread_id and m.id=p.membership_id and n.user_id=m.user_id and m.user_id=auth.uid() and p.deleted_at<now()-interval '30 days';
end;$$;
create or replace function private.support_thread_json(thread uuid) returns jsonb
language sql stable security definer set search_path='' as $$
 select to_jsonb(t)||jsonb_build_object('archived_at',own.archived_at,'deleted_at',own.deleted_at,'can_manage',true,
 'participants',(select jsonb_agg(jsonb_build_object('id',m.id,'name',coalesce(nullif(pr.full_name,''),split_part(m.email,'@',1)),
 'role',m.role,'active',m.status='active','is_me',m.user_id=auth.uid()) order by coalesce(pr.full_name,m.email),m.id)
 from private.support_participants p join public.organization_memberships m on m.id=p.membership_id left join public.profiles pr on pr.user_id=m.user_id where p.thread_id=t.id),
 'can_reply',own.deleted_at is null and exists(select 1 from private.support_participants p join public.organization_memberships m on m.id=p.membership_id
 where p.thread_id=t.id and p.membership_id<>own.membership_id and m.status='active' and (p.deleted_at is null or p.deleted_at>=now()-interval '30 days')),
 'unread_count',(select count(*) from private.support_receipts r join private.support_messages x on x.id=r.message_id where x.thread_id=t.id and r.membership_id=own.membership_id and r.read_at is null),
 'last_body',(select left(body,160) from private.support_messages where thread_id=t.id order by seq desc limit 1),
 'has_emergency',exists(select 1 from private.support_messages where thread_id=t.id and emergency),
 'email_pending',(select count(*) from private.support_email_queue q join private.support_messages x on x.id=q.message_id where x.thread_id=t.id and q.status in ('queued','working','failed')))
 from private.support_threads t join private.support_participants own on own.thread_id=t.id
 join public.organization_memberships me on me.id=own.membership_id where t.id=thread and me.user_id=auth.uid() and private.support_access(t.id);
$$;
create or replace function public.get_team_support_workspace(store uuid,folder text default 'inbox',keywords text default '',page integer default 0) returns jsonb
language plpgsql security definer set search_path='' as $$
declare me public.organization_memberships%rowtype; rows jsonb; contacts jsonb;total integer;
begin
 select * into me from public.organization_memberships where organization_id=store and user_id=auth.uid() and status='active';
 if not found then raise exception 'Active store membership required';end if;
 if folder not in ('inbox','archive','trash') or page is null or page<0 or page>10000 or length(coalesce(keywords,''))>200 then raise exception 'Invalid message search';end if;
 perform private.purge_support_trash(store);
 select coalesce(jsonb_agg(jsonb_build_object('id',m.id,'name',coalesce(nullif(p.full_name,''),split_part(m.email,'@',1)),'role',m.role) order by coalesce(p.full_name,m.email),m.id),'[]') into contacts
 from public.organization_memberships m left join public.profiles p on p.user_id=m.user_id where m.organization_id=store and m.status='active' and m.id<>me.id;
 with matches as(
 select t.id,t.updated_at from private.support_threads t join private.support_participants p on p.thread_id=t.id and p.membership_id=me.id
 where t.organization_id=store and private.support_access(t.id)
 and case folder when 'trash' then p.deleted_at is not null when 'archive' then p.deleted_at is null and p.archived_at is not null else p.deleted_at is null and p.archived_at is null end
 and (btrim(coalesce(keywords,''))='' or to_tsvector('english',t.subject||' '||coalesce((select string_agg(x.body,' ') from private.support_messages x where x.thread_id=t.id),'')) @@ websearch_to_tsquery('english',keywords))
 ), limited as(select * from matches order by updated_at desc,id limit 25 offset page*25)
 select (select count(*) from matches),coalesce(jsonb_agg(private.support_thread_json(l.id) order by l.updated_at desc,l.id),'[]') into total,rows from limited l;
 return jsonb_build_object('is_manager',me.role='manager','my_membership',me.id,'recipients',contacts,'threads',rows,'total',total,'page',page,'has_more',(page+1)*25<total);
end;$$;
create or replace function public.get_team_support_thread(thread uuid,before_seq bigint default null) returns jsonb
language plpgsql security definer set search_path='' as $$
declare messages jsonb;cutoff bigint;earliest bigint;
begin
 if not private.support_access(thread) then raise exception 'Private conversation not available';end if;
 select coalesce(jsonb_agg(to_jsonb(x) order by x.seq),'[]'),max(x.seq),min(x.seq) into messages,cutoff,earliest
 from(select id,seq,author_member,author_name,body,emergency,created_at from private.support_messages where thread_id=thread and (before_seq is null or seq<before_seq) order by seq desc limit 50)x;
 return jsonb_build_object('thread',private.support_thread_json(thread),'messages',messages,'read_through',cutoff,
 'has_older',exists(select 1 from private.support_messages where thread_id=thread and seq<earliest),
 'email_counts',(select coalesce(jsonb_object_agg(s.status,s.n),'{}') from(select q.status,count(*) n from private.support_email_queue q join private.support_messages m on m.id=q.message_id where m.thread_id=thread group by q.status)s));
end;$$;
drop function public.send_team_support_message(uuid,uuid,text,uuid,uuid,text,text,boolean);
create function public.send_team_support_message(store uuid,submission_key uuid,message_body text,thread uuid default null,recipient uuid default null,category text default 'general',subject text default null,emergency boolean default false,recipients uuid[] default '{}') returns jsonb
language plpgsql security definer set search_path='' as $$
declare me public.organization_memberships%rowtype;target private.support_threads%rowtype;prior private.support_messages%rowtype;ids uuid[];new_id uuid:=gen_random_uuid();name text;urgent boolean;manager_count integer;
begin
 select * into me from public.organization_memberships where organization_id=store and user_id=auth.uid() and status='active';
 if not found then raise exception 'Active store membership required';end if;
 if submission_key is null then raise exception 'Submission key required';end if;
 perform pg_advisory_xact_lock(hashtextextended(auth.uid()::text||':'||submission_key::text,0));
 select * into prior from private.support_messages x where x.author_id=auth.uid() and x.submission_key=send_team_support_message.submission_key;
 if found then
  if not private.support_access(prior.thread_id) or not exists(select 1 from private.support_participants where thread_id=prior.thread_id and membership_id=me.id and deleted_at is null) then raise exception 'Private conversation not available';end if;
  return jsonb_build_object('thread_id',prior.thread_id,'message_id',prior.id,'emergency',prior.emergency);
 end if;
 if message_body is null or length(btrim(message_body)) not between 1 and 5000 then raise exception 'Enter a message of up to 5,000 characters';end if;
 if thread is null then
  if category is null or category not in ('emergency','work','app','customer','general','other') or subject is null or length(btrim(subject)) not between 1 and 150 then raise exception 'Choose a category and enter a subject';end if;
  if cardinality(coalesce(recipients,'{}'))>50 then raise exception 'Choose up to 50 recipients';end if;
  select array_agg(distinct x order by x) into ids from unnest(coalesce(recipients,'{}')||case when recipient is null then '{}'::uuid[] else array[recipient] end)x;
  if coalesce(cardinality(ids),0) not between 1 and 50 or me.id=any(ids) or exists(select 1 from unnest(ids)x where x is null)
   or (select count(*) from public.organization_memberships where id=any(ids) and organization_id=store and status='active')<>cardinality(ids) then raise exception 'Choose active recipients from this store, excluding yourself';end if;
  urgent:=coalesce(emergency,false) or category='emergency';
  select count(*) into manager_count from public.organization_memberships where (id=any(ids) or id=me.id) and role='manager' and status='active';
  if urgent and manager_count=0 then raise exception 'Include an active manager in every Emergency conversation';end if;
  insert into private.support_threads(organization_id,created_by,subject,category) values(store,auth.uid(),btrim(subject),category) returning * into target;
  insert into private.support_participants(thread_id,organization_id,membership_id) select target.id,store,x from unnest(ids||array[me.id])x;
 else
  select * into target from private.support_threads where id=thread for update;
  if not found or target.organization_id<>store or not private.support_access(thread) or not exists(select 1 from private.support_participants where thread_id=thread and membership_id=me.id and deleted_at is null) then raise exception 'Private conversation not available';end if;
  if not exists(select 1 from private.support_participants p join public.organization_memberships m on m.id=p.membership_id where p.thread_id=thread and m.id<>me.id and m.status='active' and (p.deleted_at is null or p.deleted_at>=now()-interval '30 days')) then raise exception 'No other active participants remain; start a new conversation';end if;
  urgent:=coalesce(emergency,false) or target.category='emergency';
  select count(*) into manager_count from private.support_participants p join public.organization_memberships m on m.id=p.membership_id where p.thread_id=thread and m.role='manager' and m.status='active' and p.deleted_at is null;
  if urgent and manager_count=0 then raise exception 'Include an active manager in every Emergency conversation; start a new conversation with a manager';end if;
 end if;
 select coalesce(nullif(full_name,''),split_part(me.email,'@',1)) into name from public.profiles where user_id=auth.uid();
 insert into private.support_messages(id,thread_id,author_id,author_member,author_name,body,emergency,submission_key)
 values(new_id,target.id,auth.uid(),me.id,coalesce(name,split_part(me.email,'@',1)),btrim(message_body),urgent,submission_key);
 insert into private.support_receipts(message_id,membership_id)
 select new_id,p.membership_id from private.support_participants p join public.organization_memberships m on m.id=p.membership_id
 where p.thread_id=target.id and m.status='active' and p.deleted_at is null and m.id<>me.id;
 if urgent then
  insert into private.support_email_queue(message_id,manager_id)
  select new_id,m.id from private.support_participants p join public.organization_memberships m on m.id=p.membership_id where p.thread_id=target.id and m.status='active' and m.role='manager' and p.deleted_at is null;
 end if;
 update private.support_threads set updated_at=clock_timestamp() where id=target.id;
 update private.support_participants set archived_at=null where thread_id=target.id and deleted_at is null;
 return jsonb_build_object('thread_id',target.id,'message_id',new_id,'emergency',urgent);
end;$$;
create or replace function public.set_team_support_state(thread uuid,action text) returns void
language plpgsql security definer set search_path='' as $$
declare own private.support_participants%rowtype;
begin
 select p.* into own from private.support_participants p join public.organization_memberships m on m.id=p.membership_id where p.thread_id=thread and m.user_id=auth.uid() and m.status='active' for update of p;
 if not found then raise exception 'Private conversation not available';end if;
 if own.deleted_at<now()-interval '30 days' then raise exception 'Recovery period has expired';end if;
 if action='restore' and own.deleted_at is not null then
  update private.support_participants set deleted_at=null,archived_at=null where thread_id=thread and membership_id=own.membership_id;
 elsif own.deleted_at is not null then raise exception 'Restore this conversation before making changes';
 elsif action='archive' then update private.support_participants set archived_at=clock_timestamp() where thread_id=thread and membership_id=own.membership_id;
 elsif action='unarchive' then update private.support_participants set archived_at=null where thread_id=thread and membership_id=own.membership_id;
 elsif action='delete' then update private.support_participants set deleted_at=clock_timestamp() where thread_id=thread and membership_id=own.membership_id;
 else raise exception 'Choose archive, unarchive, delete or restore';end if;
end;$$;
-- Replace only the support branch of the existing notification chain; preserve training/admin/feed.
create or replace function private.notifications_before_team_posts(store uuid)
returns table(event_key text,kind text,title text,body text,course_id uuid,target_view text,competition_id uuid,event_at timestamptz)
language sql stable security definer set search_path='' as $$
 select * from private.training_notification_candidates_before_support(store)
 union all
 select 'support-message:'||x.id::text,'support_message',case when x.emergency then 'Emergency private message' else 'New private message' end,
 x.author_name||' · '||t.subject,null::uuid,'messages',null::uuid,x.created_at
 from private.support_receipts r join private.support_messages x on x.id=r.message_id join private.support_threads t on t.id=x.thread_id
 join public.organization_memberships me on me.id=r.membership_id join private.support_participants p on p.thread_id=t.id and p.membership_id=me.id
 where t.organization_id=store and me.user_id=auth.uid() and me.status='active' and private.support_access(t.id) and p.deleted_at is null;
$$;
create or replace function public.claim_support_email(actor uuid) returns jsonb
language plpgsql security definer set search_path='' as $$
declare job private.support_email_queue%rowtype;message private.support_messages%rowtype;recipient record;token uuid:=gen_random_uuid();
begin
 select q.* into job from private.support_email_queue q join private.support_messages x on x.id=q.message_id
 where (actor is null or private.support_access(x.thread_id,actor)) and (q.status in ('queued','failed') or q.status='working' and q.leased_at<now()-interval '5 minutes')
 order by q.leased_at nulls first,q.id for update of q skip locked limit 1;
 if not found then return null;end if;
 select * into message from private.support_messages where id=job.message_id;
 select m.*,u.email current_email,p.deleted_at personal_deleted into recipient from public.organization_memberships m join auth.users u on u.id=m.user_id join private.support_participants p on p.membership_id=m.id and p.thread_id=message.thread_id where m.id=job.manager_id;
 if not found or recipient.status<>'active' or recipient.role<>'manager' or recipient.personal_deleted is not null or (job.first_attempt_at is not null and job.email is distinct from recipient.current_email) then
  update private.support_email_queue set status='canceled' where id=job.id;return jsonb_build_object('skip',true);
 end if;
 if job.first_attempt_at<now()-interval '23 hours' then update private.support_email_queue set status='review' where id=job.id;return jsonb_build_object('skip',true);end if;
 update private.support_email_queue set status='working',lease_id=token,email=recipient.current_email,leased_at=clock_timestamp(),first_attempt_at=coalesce(first_attempt_at,clock_timestamp()) where id=job.id;
 return jsonb_build_object('id',job.id,'lease_id',token,'email',recipient.current_email,'thread_id',message.thread_id,
 'body','An Emergency private message from '||message.author_name||' is waiting for you in colTRAIN. Sign in to read it.');
end;$$;
revoke all on function public.send_team_support_message(uuid,uuid,text,uuid,uuid,text,text,boolean,uuid[]) from public,anon;
grant execute on function public.send_team_support_message(uuid,uuid,text,uuid,uuid,text,text,boolean,uuid[]) to authenticated;
notify pgrst,'reload schema';
commit;


-- 202610230023_company_foundation.sql
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


-- 202610230024_company_settings.sql
-- Apply once after 023. Human-readable company settings and exact-email grants.
begin;
create function public.save_company_details(company uuid, company_name text,
 company_phone text default '', affiliation text default '') returns void
language plpgsql security definer set search_path='' as $$
begin
 perform 1 from private.companies c where c.id=company for update;
 if not found or not private.can_administer_company(company) then raise exception 'Company owner access required'; end if;
 update private.companies set name=btrim(company_name),phone=btrim(company_phone),buying_group=btrim(affiliation) where id=company;
 insert into private.company_access_audit(company_id,actor_id,event)
 values(company,auth.uid(),'company_details_updated');
end;
$$;
create function public.set_company_permission_by_email(company uuid, account_email text,
 capability text, enabled boolean, store uuid default null) returns void
language plpgsql security definer set search_path='' as $$
declare person uuid;
begin
 -- Authorization precedes lookup; this is not a public account-directory endpoint.
 perform 1 from private.companies c where c.id=company for update;
 if not found or not private.can_administer_company(company) then raise exception 'Company owner access required'; end if;
 if account_email is null or length(account_email)>254 then raise exception 'Enter the confirmed account email'; end if;
 select u.id into person from auth.users u where lower(u.email)=lower(btrim(account_email)) and u.email_confirmed_at is not null;
 if person is null then raise exception 'No confirmed account matches. Ask this person to create and confirm their colTRAIN account first'; end if;
 perform public.set_company_permission(company,person,capability,enabled,store);
end;
$$;
create or replace function public.get_company_access_settings(company uuid) returns jsonb
language plpgsql stable security definer set search_path='' as $$
begin
 if not private.can_administer_company(company) or not exists(select 1 from private.companies c where c.id=company)
 then raise exception 'Company owner access required'; end if;
 return jsonb_build_object('company',(select to_jsonb(c) from private.companies c where c.id=company),
  'people',(select coalesce(jsonb_agg(jsonb_build_object('user_id',u.id,'name',coalesce(p.full_name,split_part(u.email,'@',1)),
   'email',u.email) order by u.email),'[]') from auth.users u left join public.profiles p on p.user_id=u.id
   where u.id=(select c.owner_user_id from private.companies c where c.id=company)
    or exists(select 1 from private.company_permissions g where g.company_id=company and g.user_id=u.id)),
  'permissions',(select coalesce(jsonb_agg(to_jsonb(p) order by p.created_at,p.id),'[]') from private.company_permissions p where p.company_id=company),
  'audit',(select coalesce(jsonb_agg(to_jsonb(a) order by a.id desc),'[]') from
   (select * from private.company_access_audit where company_id=company order by id desc limit 100) a));
end;
$$;
revoke all on function public.save_company_details(uuid,text,text,text),
 public.set_company_permission_by_email(uuid,text,text,boolean,uuid) from public,anon,service_role;
grant execute on function public.save_company_details(uuid,text,text,text),
 public.set_company_permission_by_email(uuid,text,text,boolean,uuid) to authenticated;
notify pgrst,'reload schema';
commit;


-- 202610260025_sandbox_store_signup.sql
-- Apply once after 024. Sandbox only; existing pilot stores are not modified.
begin;
create table private.store_signup_settings(singleton boolean primary key default true check(singleton),enabled boolean not null default false);
insert into private.store_signup_settings default values;
create table private.store_signup_requests (
 id uuid primary key default gen_random_uuid(),user_id uuid not null unique references auth.users(id),
 submission_key uuid not null,details jsonb not null,plan_code text not null check(plan_code in ('store_15','store_25','store_35')),
 terms_version text not null default 'sandbox-signup-v1',accepted_at timestamptz not null default now(),
 state text not null default 'prepared' check(state in ('prepared','checkout','provisioned')),
 lease_id uuid,leased_at timestamptz,first_attempt_at timestamptz,
 checkout_id text unique,checkout_url text,checkout_expires_at timestamptz,
 organization_id uuid unique references public.organizations(id),created_at timestamptz not null default now()
);
-- Independent businesses may share a trading name. Reserve the name + address,
-- never infer company ownership or merge stores just because names match.
create unique index store_signup_reserved_location on private.store_signup_requests(
 lower(btrim(details->>'store_name')),lower(btrim(details->>'street')),lower(btrim(details->>'city')),
 (details->>'region'),(details->>'postal_code'));
create table private.sandbox_store_subscriptions (
 organization_id uuid primary key references public.organizations(id),signup_id uuid not null unique references private.store_signup_requests(id),
 customer_id text not null,subscription_id text not null unique,plan_code text not null,
 status text not null check(status in ('trialing','active')),trial_end timestamptz,period_end timestamptz not null,
 created_at timestamptz not null default now()
);
create table private.stripe_signup_events (
 event_id text primary key,signup_id uuid not null references private.store_signup_requests(id),processed_at timestamptz not null default now()
);
alter table private.store_signup_settings enable row level security;
alter table private.store_signup_requests enable row level security;
alter table private.sandbox_store_subscriptions enable row level security;
alter table private.stripe_signup_events enable row level security;
revoke all on private.store_signup_settings,private.store_signup_requests,private.sandbox_store_subscriptions,private.stripe_signup_events from public,anon,authenticated,service_role;

create function public.get_store_signup_availability() returns jsonb
language sql stable security definer set search_path='' as $$
 select jsonb_build_object('enabled',enabled,'environment','sandbox') from private.store_signup_settings;
$$;
create function public.set_sandbox_store_signup_enabled(available boolean) returns void
language plpgsql security definer set search_path='' as $$
begin
 if auth.uid() is null or not private.is_admin() then raise exception 'Administrator access required'; end if;
 if available is null then raise exception 'Choose availability'; end if;
 update private.store_signup_settings set enabled=available;
end;
$$;
create function public.prepare_store_signup(details jsonb,submission_key uuid) returns uuid
language plpgsql security definer set search_path='' as $$
declare existing private.store_signup_requests%rowtype; person uuid:=auth.uid(); k text; cleaned jsonb;
begin
 if person is null or not exists(select 1 from auth.users where id=person and email_confirmed_at is not null) then raise exception 'Sign in with a confirmed email first'; end if;
 perform 1 from auth.users where id=person for update;
 if not (select enabled from private.store_signup_settings) then raise exception 'Sandbox store signup is not open yet'; end if;
 if submission_key is null or details is null or jsonb_typeof(details)<>'object' then raise exception 'Complete the store details'; end if;
 if details->'purchase_authority' is distinct from 'true'::jsonb or details->'terms_accepted' is distinct from 'true'::jsonb then raise exception 'Confirm purchase authority and sandbox signup terms'; end if;
 if jsonb_typeof(details->'become_manager') is distinct from 'boolean' then raise exception 'Choose whether you will manage training'; end if;
 if details->>'plan_code' not in ('store_15','store_25','store_35') or details->>'plan_code' is null then raise exception 'Choose a package'; end if;
 foreach k in array array['company_name','store_name','contact_name','phone','street','city','region','postal_code','time_zone'] loop
  if jsonb_typeof(details->k) is distinct from 'string' or length(btrim(details->>k)) not between 1 and 200 then raise exception 'Complete required store details'; end if;
 end loop;
 if length(btrim(details->>'company_name'))>120 or length(btrim(details->>'store_name'))>120 or length(btrim(details->>'contact_name'))>120
 or length(btrim(details->>'phone'))>50 or length(coalesce(details->>'buying_group',''))>160 then raise exception 'Store details are too long'; end if;
 if upper(btrim(details->>'region')) !~ '^[A-Z]{2}$' or btrim(details->>'postal_code') !~ '^[0-9]{5}(-[0-9]{4})?$'
 or not exists(select 1 from pg_catalog.pg_timezone_names where name=details->>'time_zone') then raise exception 'Choose a US state, ZIP code and valid time zone'; end if;
 cleaned:=jsonb_build_object('plan_code',details->>'plan_code','purchase_authority',true,'become_manager',(details->>'become_manager')::boolean,
  'company_name',btrim(details->>'company_name'),'store_name',btrim(details->>'store_name'),'contact_name',btrim(details->>'contact_name'),
  'phone',btrim(details->>'phone'),'buying_group',btrim(coalesce(details->>'buying_group','')),'street',btrim(details->>'street'),
  'city',btrim(details->>'city'),'region',upper(btrim(details->>'region')),'postal_code',btrim(details->>'postal_code'),'country','US','time_zone',details->>'time_zone');
 select * into existing from private.store_signup_requests where user_id=person for update;
 if found then
  if existing.details=cleaned then return existing.id; end if;
  raise exception 'A signup already exists. Resume it or contact colTRAIN support to change the details';
 end if;
 if exists(select 1 from public.organization_memberships where user_id=person and status='active')
 or exists(select 1 from private.companies where owner_user_id=person)
 or exists(select 1 from private.company_permissions where user_id=person) then raise exception 'Contact colTRAIN to add another location or change an existing account'; end if;
 begin
  insert into private.store_signup_requests(user_id,submission_key,details,plan_code)
  values(person,submission_key,cleaned,details->>'plan_code') returning id into person;
 exception when unique_violation then raise exception 'This store address already has a signup in progress; contact colTRAIN support';
 end;
 return person;
end;
$$;
create function public.get_my_store_signup() returns jsonb
language sql stable security definer set search_path='' as $$
 select jsonb_build_object('id',id,'state',state,'details',details,'store_id',organization_id,
  'checkout_expires_at',checkout_expires_at) from private.store_signup_requests where user_id=auth.uid();
$$;
create function public.claim_store_signup_checkout(signup uuid,actor uuid) returns jsonb
language plpgsql security definer set search_path='' as $$
declare r private.store_signup_requests%rowtype; token uuid:=gen_random_uuid(); email text;
begin
 if not (select enabled from private.store_signup_settings) then raise exception 'Sandbox signup is not open'; end if;
 select * into r from private.store_signup_requests where id=signup and user_id=actor for update;
 if not found then raise exception 'Signup not available'; end if;
 if r.state='provisioned' then return jsonb_build_object('ready',true); end if;
 select u.email into email from auth.users u where u.id=actor and u.email_confirmed_at is not null;
 if email is null then raise exception 'Confirmed account required'; end if;
 if exists(select 1 from public.organization_memberships where user_id=actor and status='active') then raise exception 'Account already joined a store; contact support'; end if;
 if r.checkout_id is not null then
  if r.checkout_expires_at<=now() then raise exception 'Checkout has expired; contact colTRAIN support before restarting'; end if;
  return jsonb_build_object('url',r.checkout_url);
 end if;
 if r.first_attempt_at<now()-interval '23 hours' then raise exception 'Checkout needs support review before retrying'; end if;
 if r.lease_id is not null and r.leased_at>now()-interval '2 minutes' then return jsonb_build_object('busy',true); end if;
 update private.store_signup_requests set lease_id=token,leased_at=now(),first_attempt_at=coalesce(first_attempt_at,now()) where id=signup;
 return jsonb_build_object('id',r.id,'actor',actor,'email',email,'plan_code',r.plan_code,'lease',token);
end;
$$;
create function public.finish_store_signup_checkout(signup uuid,actor uuid,lease uuid,session_id text,session_url text,expires_at timestamptz) returns void
language plpgsql security definer set search_path='' as $$
begin
 if session_id !~ '^cs_test_[A-Za-z0-9]+$' or session_url !~ '^https://checkout[.]stripe[.]com/' or expires_at<=now()
 or session_id is null or session_url is null or expires_at is null then raise exception 'Invalid sandbox checkout'; end if;
 update private.store_signup_requests set checkout_id=session_id,checkout_url=session_url,checkout_expires_at=expires_at,state=case when state='provisioned' then state else 'checkout' end,lease_id=null
 where id=signup and user_id=actor and lease_id=lease;
 if not found then raise exception 'Checkout lease expired; retry with the same signup'; end if;
end;
$$;
create function public.release_store_signup_checkout(signup uuid,actor uuid,lease uuid) returns void
language sql security definer set search_path='' as $$
 update private.store_signup_requests set lease_id=null where id=signup and user_id=actor and lease_id=lease;
$$;

create function private.sync_sandbox_standard_training(store uuid,author uuid) returns void
language plpgsql security definer set search_path='' as $$
begin
 insert into public.training_course_releases(organization_id,course_id,released_by)
 select store,c.id,author from public.training_courses c where c.published and c.owner_organization_id is null
 and exists(select 1 from public.training_lessons where course_id=c.id)
 and exists(select 1 from public.training_questions where course_id=c.id)
 and not exists(select 1 from public.training_questions q left join private.training_answer_keys k on k.question_id=q.id
  where q.course_id=c.id and (k.question_id is null or k.correct_option>=jsonb_array_length(q.options)))
 and not exists(select 1 from public.training_courses newer where newer.slug=c.slug and newer.owner_organization_id is null and newer.published and newer.version>c.version)
 on conflict do nothing;
 insert into public.daily_releases(organization_id,module_id,released_by)
 select store,d.id,author from public.daily_modules d join public.daily_sequence s on s.module_id=d.id where d.published
 and (select count(*) from public.daily_questions q where q.module_id=d.id) between 1 and 2
 and not exists(select 1 from public.daily_questions q left join private.daily_answer_keys k on k.module_id=q.module_id and k.question_id=q.id where q.module_id=d.id and k.question_id is null)
 on conflict do nothing;
 insert into public.training_assignments(organization_id,membership_id,course_id,due_date,assigned_by)
 select store,m.id,c.id,null::date,author from public.training_course_releases r join public.training_courses c on c.id=r.course_id
 join public.organization_memberships m on m.organization_id=store and m.status='active'
 where r.organization_id=store and c.published and c.owner_organization_id is null
 and not exists(select 1 from public.training_courses newer where newer.slug=c.slug and newer.owner_organization_id is null and newer.published and newer.version>c.version)
 and not exists(select 1 from public.training_assignments a join public.training_courses prior on prior.id=a.course_id
  where a.membership_id=m.id and prior.slug=c.slug and a.completed_at is not null)
 on conflict(membership_id,course_id) do nothing;
 perform private.enroll_daily_store(store);
end;
$$;
create function public.get_store_signup_for_webhook(signup uuid) returns jsonb
language sql stable security definer set search_path='' as $$
 select jsonb_build_object('id',id,'user_id',user_id,'plan_code',plan_code,'checkout_id',checkout_id,'state',state)
 from private.store_signup_requests where id=signup;
$$;
create function public.provision_sandbox_store_signup(signup uuid,event_id text,session_id text,customer text,
 subscription text,plan text,subscription_status text,trial_end timestamptz,period_end timestamptz) returns jsonb
language plpgsql security definer set search_path='' as $$
declare r private.store_signup_requests%rowtype; store uuid; company uuid; member uuid; capacity integer; email text;
begin
 select * into r from private.store_signup_requests where id=signup;
 if not found then raise exception 'Signup not available'; end if;
 -- Match preparation's user-then-signup lock order.
 perform 1 from auth.users where id=r.user_id for update;
 select * into r from private.store_signup_requests where id=signup for update;
 if event_id is null or event_id !~ '^evt_[A-Za-z0-9_]+$' or session_id is null or session_id !~ '^cs_test_[A-Za-z0-9]+$'
 or customer is null or customer !~ '^cus_[A-Za-z0-9]+$' or subscription is null or subscription !~ '^sub_[A-Za-z0-9]+$'
 or plan is distinct from r.plan_code or subscription_status is null or subscription_status not in ('trialing','active') or period_end is null
 or (subscription_status='trialing' and trial_end is null) then raise exception 'Verified sandbox subscription required'; end if;
 if r.checkout_id is not null and r.checkout_id<>session_id then raise exception 'Checkout does not match signup'; end if;
 if exists(select 1 from private.stripe_signup_events e where e.event_id=provision_sandbox_store_signup.event_id and e.signup_id<>signup) then raise exception 'Event belongs to another signup'; end if;
 if r.state='provisioned' then
  if not exists(select 1 from private.sandbox_store_subscriptions where signup_id=signup and subscription_id=subscription and customer_id=customer) then raise exception 'Subscription does not match provisioned store'; end if;
  insert into private.stripe_signup_events values(event_id,signup,now()) on conflict do nothing;
  return jsonb_build_object('store_id',r.organization_id,'created',false);
 end if;
 select u.email into email from auth.users u where u.id=r.user_id and u.email_confirmed_at is not null;
 if email is null or exists(select 1 from public.organization_memberships where user_id=r.user_id and status='active')
 or exists(select 1 from private.companies where owner_user_id=r.user_id) then raise exception 'Owner account changed; support review required'; end if;
 capacity:=case plan when 'store_15' then 15 when 'store_25' then 25 when 'store_35' then 35 end;
 insert into public.organizations(name,time_zone) values(r.details->>'store_name',r.details->>'time_zone') returning id into store;
 select s.company_id into company from private.company_stores s where s.organization_id=store;
 update private.companies set name=r.details->>'company_name',phone=r.details->>'phone',buying_group=r.details->>'buying_group',owner_user_id=r.user_id where id=company;
 insert into public.profiles(user_id,full_name) values(r.user_id,r.details->>'contact_name') on conflict(user_id) do nothing;
 insert into public.seats(organization_id) select store from generate_series(1,capacity);
 insert into private.sandbox_store_subscriptions values(store,signup,customer,subscription,plan,subscription_status,trial_end,period_end,now());
 insert into public.training_departments(organization_id,name) select store,n from unnest(array['Front Counter & Customer Service','Paint','Hardware & Fasteners','Plumbing','Electrical','Lawn & Garden']) n;
 if (r.details->>'become_manager')::boolean then
  insert into public.organization_memberships(organization_id,user_id,email,role) values(store,r.user_id,email,'manager') returning id into member;
  update public.seats set membership_id=member where id=(select id from public.seats where organization_id=store order by id limit 1);
 end if;
 perform private.sync_sandbox_standard_training(store,r.user_id);
 update private.store_signup_requests set organization_id=store,state='provisioned',checkout_id=session_id where id=signup;
 insert into private.stripe_signup_events values(event_id,signup,now());
 insert into private.company_access_audit(company_id,organization_id,actor_id,event,details)
 values(company,store,r.user_id,'sandbox_store_provisioned',jsonb_build_object('plan_code',plan,'signup_id',signup));
 return jsonb_build_object('store_id',store,'created',true);
end;
$$;
-- Existing access modes stay unchanged. Sandbox subscription state is separate;
-- lifecycle enforcement will be built before commercial signup is enabled.
create function private.sync_new_sandbox_content() returns trigger
language plpgsql security definer set search_path='' as $$
declare s record; should_sync boolean;
begin
 if tg_table_name='daily_sequence' then should_sync:=true;else should_sync:=new.published;end if;
 if should_sync then
  for s in select b.organization_id,c.owner_user_id from private.sandbox_store_subscriptions b
   join private.company_stores l on l.organization_id=b.organization_id join private.companies c on c.id=l.company_id loop
   perform private.sync_sandbox_standard_training(s.organization_id,s.owner_user_id);
  end loop;
 end if;
 return new;
end;
$$;
create trigger sandbox_standard_courses after insert or update of published on public.training_courses for each row execute function private.sync_new_sandbox_content();
create trigger sandbox_standard_drills after insert or update of published on public.daily_modules for each row execute function private.sync_new_sandbox_content();
create trigger sandbox_standard_daily_sequence after insert on public.daily_sequence for each row execute function private.sync_new_sandbox_content();
create function private.enroll_sandbox_member() returns trigger
language plpgsql security definer set search_path='' as $$
declare author uuid;
begin
 if new.status='active' and exists(select 1 from private.sandbox_store_subscriptions where organization_id=new.organization_id) then
  select c.owner_user_id into author from private.company_stores s join private.companies c on c.id=s.company_id where s.organization_id=new.organization_id;
  perform private.sync_sandbox_standard_training(new.organization_id,author);
 end if;
 return new;
end;
$$;
create trigger sandbox_member_training after insert or update of status,role on public.organization_memberships for each row execute function private.enroll_sandbox_member();
revoke all on function private.enroll_sandbox_member() from public,anon,authenticated,service_role;

alter function public.get_my_company_accounts() set schema private;
alter function private.get_my_company_accounts() rename to company_accounts_before_sandbox;
revoke all on function private.company_accounts_before_sandbox() from public,anon,authenticated,service_role;
create function public.get_my_company_accounts() returns jsonb
language sql stable security definer set search_path='' as $$
 select coalesce(jsonb_agg(c.item||jsonb_build_object('stores',(
  select coalesce(jsonb_agg(s.item||case when (s.item->>'can_bill')::boolean and exists(
   select 1 from private.sandbox_store_subscriptions b where b.organization_id=(s.item->>'store_id')::uuid)
   then jsonb_build_object('access_mode','sandbox') else '{}'::jsonb end order by s.position),'[]')
  from jsonb_array_elements(c.item->'stores') with ordinality s(item,position))) order by c.position),'[]')
 from jsonb_array_elements(private.company_accounts_before_sandbox()) with ordinality c(item,position);
$$;
revoke all on function public.get_my_company_accounts() from public,anon,service_role;
grant execute on function public.get_my_company_accounts() to authenticated;

-- Owners can designate a manager without acquiring staff/feed/message access.
create function private.is_company_store_owner(store uuid) returns boolean
language sql stable security definer set search_path='' as $$
 select exists(select 1 from private.company_stores s join private.companies c on c.id=s.company_id
 where s.organization_id=store and c.owner_user_id=auth.uid());
$$;
revoke all on function private.is_company_store_owner(uuid) from public,anon,authenticated,service_role;
create or replace function public.create_invitation(store uuid, employee_email text, member_role text default 'employee')
returns table(invitation_id uuid, invitation_code text, expires_at timestamptz)
language plpgsql security definer set search_path='' as $$
declare chosen_seat uuid; code text; target text:=lower(btrim(employee_email));
begin
 if auth.uid() is null or not (private.can_manage(store) or (member_role='manager' and private.is_company_store_owner(store))) then raise exception 'Manager access required'; end if;
 if member_role not in ('employee','manager') or member_role is null then raise exception 'Invalid role'; end if;
 if member_role='manager' and not (private.is_admin() or private.is_company_store_owner(store)) then raise exception 'Only an administrator or company owner can invite a manager'; end if;
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
create or replace function public.reissue_invitation(invitation uuid)
returns table(invitation_id uuid, invitation_code text, expires_at timestamptz)
language plpgsql security definer set search_path='' as $$
declare target public.invitations%rowtype; replacement record;
begin
 select * into target from public.invitations where id=invitation for update;
 if not found or not (private.can_manage(target.organization_id) or (target.role='manager' and private.is_company_store_owner(target.organization_id))) then raise exception 'Invitation not available'; end if;
 if target.accepted_at is not null then raise exception 'This invitation was already used'; end if;
 if target.role='manager' and not (private.is_admin() or private.is_company_store_owner(target.organization_id)) then raise exception 'Only an administrator or company owner can invite a manager'; end if;
 update public.invitations set revoked_at=now() where id=invitation;
 select * into replacement from public.create_invitation(target.organization_id,target.email,target.role);
 update public.invitations set invitee_name=target.invitee_name where id=replacement.invitation_id;
 return query select replacement.invitation_id,replacement.invitation_code,replacement.expires_at;
end;
$$;

create or replace function public.prepare_employee_invitation(store uuid, employee_email text, employee_name text, member_role text default 'employee', replace_invitation uuid default null)
returns table(invitation_id uuid,email text,invitee_name text,expires_at timestamptz)
language plpgsql security definer set search_path='' as $$
declare target public.invitations%rowtype; prepared record; normalized_email text:=lower(btrim(employee_email)); name text:=btrim(employee_name);
begin

 if replace_invitation is not null then
  select * into target from public.invitations where id=replace_invitation;
  if not found or target.organization_id<>store then raise exception 'Invitation not available'; end if;
  normalized_email:=target.email; name:=target.invitee_name;
 end if;
 if auth.uid() is null or not (private.can_manage(store) or (private.is_company_store_owner(store) and case when replace_invitation is null then member_role='manager' else target.role='manager' end)) then raise exception 'Manager access required'; end if;
 if name is null or length(name) not between 1 and 120 then raise exception 'Enter the employee name'; end if;
 -- Serialize email attempts per store/address, including revoked invitations.
 perform pg_advisory_xact_lock(hashtextextended(store::text||':'||normalized_email,0));
 if exists(select 1 from public.invitations i where i.organization_id=store and i.email=normalized_email and i.last_email_attempt_at>now()-interval '60 seconds') then raise exception 'Wait one minute before sending another invitation'; end if;
 if replace_invitation is null then
  select * into prepared from public.create_invitation(store,normalized_email,member_role);
 else
  select * into prepared from public.reissue_invitation(replace_invitation);
 end if;
 update public.invitations i set invitee_name=name,email_status='pending',last_email_attempt_at=now() where i.id=prepared.invitation_id;
 return query select i.id,i.email,i.invitee_name,i.expires_at from public.invitations i where i.id=prepared.invitation_id;
end;
$$;

revoke all on function private.sync_sandbox_standard_training(uuid,uuid),private.sync_new_sandbox_content() from public,anon,authenticated,service_role;
revoke all on function public.get_store_signup_availability(),public.set_sandbox_store_signup_enabled(boolean),public.prepare_store_signup(jsonb,uuid),public.get_my_store_signup(),
 public.claim_store_signup_checkout(uuid,uuid),public.finish_store_signup_checkout(uuid,uuid,uuid,text,text,timestamptz),public.release_store_signup_checkout(uuid,uuid,uuid),
 public.get_store_signup_for_webhook(uuid),public.provision_sandbox_store_signup(uuid,text,text,text,text,text,text,timestamptz,timestamptz) from public,anon,authenticated,service_role;
grant execute on function public.get_store_signup_availability() to anon,authenticated;
grant execute on function public.set_sandbox_store_signup_enabled(boolean),public.prepare_store_signup(jsonb,uuid),public.get_my_store_signup() to authenticated;
grant execute on function public.claim_store_signup_checkout(uuid,uuid),public.finish_store_signup_checkout(uuid,uuid,uuid,text,text,timestamptz),public.release_store_signup_checkout(uuid,uuid,uuid),
 public.get_store_signup_for_webhook(uuid),public.provision_sandbox_store_signup(uuid,text,text,text,text,text,text,timestamptz,timestamptz) to service_role;
notify pgrst,'reload schema';
commit;


-- 202610270026_company_admin_invitations.sql
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


-- 202610270027_staff_store_transfers.sql
-- Apply once after 026. Reuse the person's account; never move/delete former store records.
begin;
create function public.get_employee_invitation_email_details(invitation uuid) returns jsonb
language sql stable security definer set search_path='' as $$
 select jsonb_build_object('email',i.email,'store_name',o.name,'role',i.role)
 from public.invitations i join public.organizations o on o.id=i.organization_id
 where i.id=invitation and i.revoked_at is null and i.accepted_at is null and i.expires_at>now();
$$;
revoke all on function public.get_employee_invitation_email_details(uuid) from public,anon,authenticated;
grant execute on function public.get_employee_invitation_email_details(uuid) to service_role;
create function public.get_my_store_invitation(invitation uuid) returns jsonb
language plpgsql stable security definer set search_path='' as $$
declare invite public.invitations; verified_email text;
begin
 select lower(email) into verified_email from auth.users where id=auth.uid() and email_confirmed_at is not null;
 select i.* into invite from public.invitations i where i.id=invitation;
 if verified_email is null or invite.id is null or invite.email<>verified_email or invite.revoked_at is not null
 or (invite.accepted_at is null and invite.expires_at<=now()) or (invite.accepted_at is not null and invite.accepted_by is distinct from auth.uid()) then
  raise exception 'This invitation is unavailable or does not match your confirmed email';end if;
 return jsonb_build_object('store_name',(select name from public.organizations where id=invite.organization_id),'role',invite.role,
 'accepted',invite.accepted_at is not null,
 'can_join',not exists(select 1 from public.organization_memberships where user_id=auth.uid() and status='active'));
end;
$$;
revoke all on function public.get_my_store_invitation(uuid) from public,anon,service_role;
grant execute on function public.get_my_store_invitation(uuid) to authenticated;
-- Serialize claims on a person's Auth row as well as the reserved seat. A single
-- account may move between stores, but cannot hold two active staff memberships.
create or replace function private.consume_invitation(invitation uuid)
returns uuid language plpgsql security definer set search_path='' as $$
declare invite public.invitations; verified_email text; member uuid; seat_member uuid;
begin
 if auth.uid() is null then raise exception 'Sign in first';end if;
 select lower(email) into verified_email from auth.users where id=auth.uid() and email_confirmed_at is not null for update;
 if verified_email is null then raise exception 'Confirm your email before joining';end if;
 select * into invite from public.invitations where id=invitation for update;
 if not found or invite.revoked_at is not null or invite.email<>verified_email then raise exception 'Invitation is invalid, expired, or does not match your verified email';end if;
 if invite.accepted_at is not null then raise exception 'Invitation is invalid or already used; ask for a new invitation';end if;
 if invite.expires_at<=now() then raise exception 'Invitation is invalid, expired, or does not match your verified email';end if;
 if exists(select 1 from public.organization_memberships where user_id=auth.uid() and status='active') then raise exception 'You already belong to a store. Your current store must remove your staff access before you can join another store';end if;
 select membership_id into seat_member from public.seats where id=invite.seat_id and organization_id=invite.organization_id for update;
 if not found or seat_member is not null then raise exception 'Seat is not available';end if;
 insert into public.organization_memberships(organization_id,user_id,email,role) values(invite.organization_id,auth.uid(),verified_email,invite.role) returning id into member;
 update public.seats set membership_id=member where id=invite.seat_id;
 update public.invitations set accepted_by=auth.uid(),accepted_at=now() where id=invite.id;
 if length(btrim(invite.invitee_name))>0 then insert into public.profiles(user_id,full_name) values(auth.uid(),btrim(invite.invitee_name)) on conflict(user_id) do nothing;end if;
 return member;
end;
$$;
-- Copy completion credit only for the identical shared standard content already
-- assigned by the destination store. Never release former store-owned content.
alter table public.training_assignments add column carried_credit boolean not null default false;
alter table public.daily_assignments add column carried_credit boolean not null default false;
create function private.carry_standard_course_credit() returns trigger
language plpgsql security definer set search_path='' as $$
declare prior public.training_assignments;
begin
 if new.completed_at is null and exists(select 1 from public.training_courses c where c.id=new.course_id and c.owner_organization_id is null) then
  select a.* into prior from public.training_assignments a join public.organization_memberships previous on previous.id=a.membership_id
  join public.organization_memberships current on current.id=new.membership_id and current.user_id=previous.user_id
  where a.membership_id<>new.membership_id and a.course_id=new.course_id and a.completed_at is not null order by a.completed_at,a.id limit 1;
  if found then new.completed_at:=prior.completed_at;new.started_at:=coalesce(prior.started_at,prior.completed_at);new.carried_credit:=true;end if;
 end if;
 return new;
end;
$$;
create function private.carry_standard_lesson_credit() returns trigger
language plpgsql security definer set search_path='' as $$
begin
 if new.carried_credit then
  insert into public.training_lesson_completions(assignment_id,course_id,lesson_id,completed_at)
  select new.id,new.course_id,l.lesson_id,min(l.completed_at) from public.training_lesson_completions l
  join public.training_assignments a on a.id=l.assignment_id join public.organization_memberships previous on previous.id=a.membership_id
  join public.organization_memberships current on current.id=new.membership_id and current.user_id=previous.user_id
  where a.membership_id<>new.membership_id and a.course_id=new.course_id and a.completed_at is not null
  group by l.lesson_id on conflict do nothing;
 end if;
 return new;
end;
$$;
create trigger carry_standard_course_credit before insert or update of membership_id on public.training_assignments for each row execute function private.carry_standard_course_credit();
create trigger carry_standard_lesson_credit after insert or update on public.training_assignments for each row execute function private.carry_standard_lesson_credit();
create function private.carry_daily_credit() returns trigger
language plpgsql security definer set search_path='' as $$
declare prior public.daily_assignments;
begin
 if new.completed_at is null then
  select a.* into prior from public.daily_assignments a join public.organization_memberships previous on previous.id=a.membership_id
  join public.organization_memberships current on current.id=new.membership_id and current.user_id=previous.user_id
  where a.membership_id<>new.membership_id and a.module_id=new.module_id and a.completed_at is not null order by a.completed_at,a.id limit 1;
  if found then new.completed_at:=prior.completed_at;new.started_at:=coalesce(prior.started_at,prior.completed_at);new.carried_credit:=true;end if;
 end if;
 return new;
end;
$$;
create trigger carry_daily_credit before insert or update of membership_id on public.daily_assignments for each row execute function private.carry_daily_credit();
create or replace function private.award_daily_completion() returns trigger
language plpgsql security definer set search_path='' as $$
begin
 if new.completed_at is not null and not new.carried_credit then
  insert into private.daily_point_awards(user_id,module_code,module_id,assignment_id,earned_at)
  select m.user_id,d.code,d.id,new.id,new.completed_at from public.organization_memberships m
  join public.daily_modules d on d.id=new.module_id where m.id=new.membership_id
  on conflict(user_id,module_code) do nothing;
 end if;
 return new;
end;
$$;
revoke all on function private.carry_standard_course_credit(),private.carry_standard_lesson_credit(),private.carry_daily_credit() from public,anon,authenticated,service_role;
-- Also credit people who already moved stores before this update. Original rows,
-- points, trophies and time remain unchanged, and no new deadline is introduced.
update public.training_assignments a set membership_id=a.membership_id from public.organization_memberships m
 where m.id=a.membership_id and m.status='active' and a.completed_at is null;
update public.daily_assignments a set membership_id=a.membership_id from public.organization_memberships m
 where m.id=a.membership_id and m.status='active' and a.completed_at is null;
-- Owners who delegate training need to manage pending manager invitations too.
create or replace function public.revoke_invitation(invitation uuid)
returns void language plpgsql security definer set search_path='' as $$
declare target public.invitations;
begin
 select * into target from public.invitations where id=invitation for update;
 if not found or not(private.can_manage(target.organization_id) or (target.role='manager' and private.is_company_store_owner(target.organization_id))) then raise exception 'Invitation not available';end if;
 if target.accepted_at is not null then raise exception 'This invitation was already used';end if;
 update public.invitations set revoked_at=now() where id=invitation;
end;
$$;
alter function public.get_company_access_settings(uuid) rename to get_company_access_settings_before_staff_transfers;
revoke all on function public.get_company_access_settings_before_staff_transfers(uuid) from public,anon,authenticated,service_role;
create function public.get_company_access_settings(company uuid) returns jsonb
language plpgsql stable security definer set search_path='' as $$
declare settings jsonb;
begin
 settings:=public.get_company_access_settings_before_staff_transfers(company);
 return settings||jsonb_build_object('manager_invitations',(select coalesce(jsonb_agg(jsonb_build_object('id',i.id,'email',i.email,'invitee_name',i.invitee_name,
 'organization_id',i.organization_id,'store_name',o.name,'email_status',i.email_status,'expires_at',i.expires_at) order by i.created_at),'[]')
 from public.invitations i join private.company_stores s on s.organization_id=i.organization_id join public.organizations o on o.id=i.organization_id
 where s.company_id=company and i.role='manager' and i.accepted_at is null and i.revoked_at is null));
end;
$$;
revoke all on function public.get_company_access_settings(uuid) from public,anon,service_role;
grant execute on function public.get_company_access_settings(uuid) to authenticated;
-- Transcript belongs to the authenticated person, not the current store. Titles,
-- dates and earned credit only: no former store feed, messages, documents or answers.
create function public.get_my_training_history() returns jsonb
language plpgsql stable security definer set search_path='' as $$
begin
 if auth.uid() is null then raise exception 'Sign in first';end if;
 return jsonb_build_object('points',private.learner_point_totals(auth.uid()),
 'trophies',(select count(*) from public.training_trophies where user_id=auth.uid()),
 'courses',(select coalesce(jsonb_agg(jsonb_build_object('title',c.title,'version',c.version,'standard',c.owner_organization_id is null,
 'completed_at',a.completed_at,'started_at',a.started_at,'lessons_completed',(select count(*) from public.training_lesson_completions l where l.assignment_id=a.id),
 'attempts_used',(select count(*) from public.training_attempts t where t.assignment_id=a.id)) order by a.assigned_at desc),'[]')
 from public.training_assignments a join public.organization_memberships m on m.id=a.membership_id join public.training_courses c on c.id=a.course_id where m.user_id=auth.uid() and not a.carried_credit),
 'daily',(select coalesce(jsonb_agg(jsonb_build_object('title',d.title,'code',d.code,'completed_at',a.completed_at,'started_at',a.started_at) order by a.assigned_at desc),'[]')
 from public.daily_assignments a join public.organization_memberships m on m.id=a.membership_id join public.daily_modules d on d.id=a.module_id where m.user_id=auth.uid() and not a.carried_credit));
end;
$$;
revoke all on function public.get_my_training_history() from public,anon,service_role;
grant execute on function public.get_my_training_history() to authenticated;
notify pgrst,'reload schema';
commit;
