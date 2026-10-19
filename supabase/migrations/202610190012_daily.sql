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
