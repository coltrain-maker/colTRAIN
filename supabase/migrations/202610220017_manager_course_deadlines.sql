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
