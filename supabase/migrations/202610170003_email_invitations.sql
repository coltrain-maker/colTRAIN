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
