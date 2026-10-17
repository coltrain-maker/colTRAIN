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
