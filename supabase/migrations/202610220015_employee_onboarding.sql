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
