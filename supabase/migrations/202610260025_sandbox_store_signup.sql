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
