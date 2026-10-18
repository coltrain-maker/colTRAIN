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
