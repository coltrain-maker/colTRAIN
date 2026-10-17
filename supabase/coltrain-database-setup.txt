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
