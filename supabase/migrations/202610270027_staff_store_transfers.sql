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
