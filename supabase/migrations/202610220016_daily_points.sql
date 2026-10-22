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
