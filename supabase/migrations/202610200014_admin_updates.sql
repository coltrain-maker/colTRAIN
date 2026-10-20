-- Role- and store-targeted in-app admin updates. Apply once after migration 013.
-- No existing posts/learning records changed. Queues opt-in email; delivery requires the new Edge Function.
begin;
create table private.admin_updates (
 id uuid primary key default gen_random_uuid(), created_by uuid not null references auth.users(id),
 submission_key uuid not null, title text not null check(length(btrim(title)) between 1 and 150),
 body text not null check(length(btrim(body)) between 1 and 6000),
 audience text not null check(audience in ('manager','employee','both')),
 store_ids uuid[] not null, all_stores boolean not null, link_url text,
 created_at timestamptz not null default clock_timestamp(), archived_at timestamptz,
 unique(created_by,submission_key),
 check(link_url is null or (length(link_url)<=2048 and link_url ~ '^https://[^[:space:]<>"'']+$'))
);
create table private.admin_update_recipients (
 update_id uuid not null references private.admin_updates(id), membership_id uuid not null,
 organization_id uuid not null, user_id uuid not null references auth.users(id), role_at_send text not null check(role_at_send in ('manager','employee')),
 primary key(update_id,membership_id),
 foreign key(organization_id,membership_id) references public.organization_memberships(organization_id,id)
);
create index admin_update_recipient_owner on private.admin_update_recipients(organization_id,user_id);
alter table private.admin_updates enable row level security;
alter table private.admin_update_recipients enable row level security;
revoke all on private.admin_updates,private.admin_update_recipients from public,anon,authenticated;

create table private.admin_update_email_queue (
 id uuid primary key default gen_random_uuid(), update_id uuid not null references private.admin_updates(id),
 membership_id uuid not null references public.organization_memberships(id), email text not null,
 status text not null default 'queued' check(status in ('queued','working','sent','failed','canceled','review')),
 lease_id uuid, leased_at timestamptz, first_attempt_at timestamptz, attempts integer not null default 0,
 provider_id text, last_error text, sent_at timestamptz, unique(update_id,membership_id)
);
alter table private.admin_update_email_queue enable row level security;
revoke all on private.admin_update_email_queue from public,anon,authenticated;

create function private.validate_admin_update(title text,body text,link_url text) returns void
language plpgsql set search_path='' as $$
begin
 if length(btrim(coalesce(title,''))) not between 1 and 150 then raise exception 'Add a title of 1–150 characters'; end if;
 if length(btrim(coalesce(body,''))) not between 1 and 6000 then raise exception 'Add a message of 1–6000 characters'; end if;
 if nullif(btrim(link_url),'') is not null and (length(link_url)>2048 or link_url !~ '^https://[^[:space:]<>"'']+$') then raise exception 'Use a complete https:// link without spaces'; end if;
end;
$$;
create function private.admin_update_targets(audience text,store_ids uuid[],all_stores boolean)
returns table(organization_id uuid,membership_id uuid,user_id uuid,member_role text)
language plpgsql stable security definer set search_path='' as $$
begin
 if auth.uid() is null or not private.is_admin() then raise exception 'Administrator access required'; end if;
 if audience is null or audience not in ('manager','employee','both') then raise exception 'Choose managers, employees, or both'; end if;
 if all_stores is null then raise exception 'Choose a store audience'; end if;
 if all_stores and cardinality(coalesce(store_ids,'{}'))>0 then raise exception 'Choose all stores or specific stores'; end if;
 if not all_stores and cardinality(coalesce(store_ids,'{}'))=0 then raise exception 'Choose at least one store'; end if;
 if exists(select 1 from unnest(coalesce(store_ids,'{}')) requested(store_id) where requested.store_id is null or not exists(select 1 from public.organizations o where o.id=requested.store_id)) then raise exception 'A selected store does not exist'; end if;
 return query select m.organization_id,m.id,m.user_id,m.role from public.organization_memberships m
 where m.status='active' and (all_stores or m.organization_id=any(store_ids)) and (audience='both' or m.role=audience);
end;
$$;
create function public.preview_admin_update(title text,body text,audience text,store_ids uuid[] default '{}',all_stores boolean default false,link_url text default null) returns jsonb
language plpgsql stable security definer set search_path='' as $$
declare result jsonb;
begin
 if not private.is_admin() then raise exception 'Administrator access required'; end if;
 perform private.validate_admin_update(title,body,link_url);
 select jsonb_build_object('recipient_count',coalesce(sum(t.managers+t.employees),0),'stores',coalesce(jsonb_agg(to_jsonb(t)),'[]'),'email_count',(select count(*) from private.admin_update_targets(audience,store_ids,all_stores) r join public.profiles p on p.user_id=r.user_id where p.optional_email_notifications)) into result
 from (select o.id,o.name,count(*) filter(where r.member_role='manager') managers,count(*) filter(where r.member_role='employee') employees
 from private.admin_update_targets(audience,store_ids,all_stores) r join public.organizations o on o.id=r.organization_id group by o.id,o.name order by o.name,o.id) t;
 if (result->>'recipient_count')::integer=0 then raise exception 'No active recipients match this audience'; end if;
 return result;
end;
$$;
create function public.send_admin_update(title text,body text,audience text,submission_key uuid,store_ids uuid[] default '{}',all_stores boolean default false,link_url text default null) returns jsonb
language plpgsql security definer set search_path='' as $$
declare target uuid; recipients integer; scope uuid[];
begin
 if auth.uid() is null or not private.is_admin() then raise exception 'Administrator access required'; end if;
 if submission_key is null then raise exception 'Submission key required'; end if;
 perform pg_advisory_xact_lock(hashtextextended('admin-update:'||auth.uid()::text||submission_key::text,0));
 select a.id into target from private.admin_updates a where a.created_by=auth.uid() and a.submission_key=send_admin_update.submission_key;
 if found then
  return jsonb_build_object('id',target,'recipient_count',(select count(*) from private.admin_update_recipients where update_id=target),'already_sent',true);
 end if;
 perform private.validate_admin_update(title,body,link_url);
 -- Materialize the validated current audience once inside this statement. No future members are subscribed retroactively.
 select array_agg(distinct r.organization_id) into scope from private.admin_update_targets(audience,store_ids,all_stores) r;
 if scope is null then raise exception 'No active recipients match this audience'; end if;
 insert into private.admin_updates(created_by,submission_key,title,body,audience,store_ids,all_stores,link_url)
 values(auth.uid(),submission_key,btrim(title),btrim(body),audience,scope,all_stores,nullif(btrim(link_url),'')) returning id into target;
 insert into private.admin_update_recipients(update_id,membership_id,organization_id,user_id,role_at_send)
 select target,r.membership_id,r.organization_id,r.user_id,r.member_role from private.admin_update_targets(audience,store_ids,all_stores) r;
 get diagnostics recipients=row_count;
 if recipients=0 then raise exception 'No active recipients match this audience'; end if;
 insert into private.admin_update_email_queue(update_id,membership_id,email)
 select target,r.membership_id,u.email from private.admin_update_recipients r join public.profiles p on p.user_id=r.user_id
 join auth.users u on u.id=r.user_id where r.update_id=target and p.optional_email_notifications and u.email is not null;

 return jsonb_build_object('id',target,'recipient_count',recipients,'already_sent',false);
end;
$$;
create function public.get_admin_updates() returns jsonb
language plpgsql stable security definer set search_path='' as $$
begin
 if not private.is_admin() then raise exception 'Administrator access required'; end if;
 return (select coalesce(jsonb_agg(jsonb_build_object('id',a.id,'title',a.title,'body',a.body,'audience',a.audience,
 'all_stores',a.all_stores,'link_url',a.link_url,'created_at',a.created_at,'archived_at',a.archived_at,
 'stores',(select coalesce(jsonb_agg(o.name order by o.name),'[]') from public.organizations o where o.id=any(a.store_ids)),
 'recipient_count',(select count(*) from private.admin_update_recipients r where r.update_id=a.id),
 'email_counts',(select coalesce(jsonb_object_agg(t.status,t.count),'{}') from (select status,count(*) from private.admin_update_email_queue q where q.update_id=a.id group by status) t),
 'read_count',(select count(*) from private.admin_update_recipients r join private.training_notifications n on n.user_id=r.user_id and n.organization_id=r.organization_id and n.event_key='admin-update:'||a.id::text where r.update_id=a.id and n.read_at is not null)) order by a.created_at desc,a.id),'[]') from private.admin_updates a);
end;
$$;
create function public.archive_admin_update(update_id uuid) returns void
language plpgsql security definer set search_path='' as $$
begin
 if not private.is_admin() then raise exception 'Administrator access required'; end if;
 update private.admin_updates set archived_at=coalesce(archived_at,clock_timestamp()) where id=update_id;
 if not found then raise exception 'Admin update not found'; end if;
end;
$$;

-- Service-only worker: recheck consent, active membership, role and archival before each delivery.
create function public.claim_admin_update_email(update_id uuid,retry_failed boolean default false) returns jsonb
language plpgsql security definer set search_path='' as $$
declare job private.admin_update_email_queue%rowtype; token uuid:=gen_random_uuid(); message private.admin_updates%rowtype; current_email text;
begin
 select * into message from private.admin_updates where id=update_id;
 if not found then return null; end if;
 for job in select q.* from private.admin_update_email_queue q where q.update_id=claim_admin_update_email.update_id
 and (q.status='queued' or q.status='failed' and retry_failed or q.status='working' and q.leased_at<now()-interval '5 minutes')
 order by q.attempts,q.id for update skip locked loop
  select u.email into current_email from public.organization_memberships m join public.profiles p on p.user_id=m.user_id join auth.users u on u.id=m.user_id
  where m.id=job.membership_id and m.status='active' and p.optional_email_notifications and (message.audience='both' or m.role=message.audience);
  if message.archived_at is not null or current_email is null or (job.first_attempt_at is not null and current_email<>job.email) then
   update private.admin_update_email_queue set status='canceled' where id=job.id;continue;
  end if;
  -- Resend retains idempotency keys for 24 hours; do not blindly replay ambiguous older sends.
  if job.first_attempt_at<now()-interval '23 hours' then
   update private.admin_update_email_queue set status='review',last_error='Review delivery before retrying an older request' where id=job.id;continue;
  end if;
  update private.admin_update_email_queue set status='working',lease_id=token,leased_at=clock_timestamp(),
   first_attempt_at=coalesce(first_attempt_at,clock_timestamp()),attempts=attempts+1,email=current_email where id=job.id;
  return jsonb_build_object('id',job.id,'lease_id',token,'email',current_email,'title',message.title,'body',message.body,'link_url',message.link_url);
 end loop;
 return null;
end;
$$;
create function public.finish_admin_update_email(delivery_id uuid,lease uuid,success boolean,provider_id text default null,error_message text default null) returns void
language plpgsql security definer set search_path='' as $$
begin
 update private.admin_update_email_queue set status=case when success then 'sent' else 'failed' end,
 provider_id=finish_admin_update_email.provider_id,last_error=case when success then null else left(error_message,300) end,
 sent_at=case when success then clock_timestamp() else null end
 where id=delivery_id and lease_id=lease and status='working';
 if not found then raise exception 'Email delivery lease is no longer active'; end if;
end;
$$;
revoke all on function public.claim_admin_update_email(uuid,boolean),public.finish_admin_update_email(uuid,uuid,boolean,text,text) from public,anon,authenticated;
grant execute on function public.claim_admin_update_email(uuid,boolean),public.finish_admin_update_email(uuid,uuid,boolean,text,text) to service_role;

-- Existing training reminders retain their original behavior. Announcements persist until archived.
alter function private.training_notification_candidates(uuid) rename to training_notification_candidates_before_admin;
revoke all on function private.training_notification_candidates_before_admin(uuid) from public,anon,authenticated;
create function private.training_notification_candidates(store uuid)
returns table(event_key text,kind text,title text,body text,course_id uuid,target_view text,competition_id uuid,event_at timestamptz)
language sql stable security definer set search_path='' as $$
 select * from private.training_notification_candidates_before_admin(store)
 union all
 select 'admin-update:'||a.id::text,'admin_update',a.title,a.body,null::uuid,'notifications',null::uuid,a.created_at
 from private.admin_updates a join private.admin_update_recipients r on r.update_id=a.id
 join public.organization_memberships m on m.id=r.membership_id
 where r.organization_id=store and r.user_id=auth.uid() and m.user_id=auth.uid() and m.status='active'
 and a.archived_at is null and (a.audience='both' or m.role=a.audience);
$$;
alter function public.get_my_training_notifications(uuid) set schema private;
alter function private.get_my_training_notifications(uuid) rename to notifications_before_admin_updates;
revoke all on function private.notifications_before_admin_updates(uuid) from public,anon,authenticated;
create function public.get_my_training_notifications(store uuid) returns jsonb
language plpgsql security definer set search_path='' as $$
declare base jsonb; items jsonb;
begin
 base:=private.notifications_before_admin_updates(store);
 select coalesce(jsonb_agg(x.item||case when a.id is not null then jsonb_build_object('admin_update_id',a.id,'link_url',a.link_url) else '{}'::jsonb end order by x.position),'[]') into items
 from jsonb_array_elements(base->'items') with ordinality x(item,position)
 left join private.training_notifications n on n.id=(x.item->>'id')::uuid and n.user_id=auth.uid() and n.organization_id=store
 left join private.admin_updates a on n.event_key='admin-update:'||a.id::text;
 return base||jsonb_build_object('items',items);
end;
$$;
revoke all on function private.validate_admin_update(text,text,text),private.admin_update_targets(text,uuid[],boolean),private.training_notification_candidates(uuid) from public,anon,authenticated;
revoke all on function public.preview_admin_update(text,text,text,uuid[],boolean,text),public.send_admin_update(text,text,text,uuid,uuid[],boolean,text),public.get_admin_updates(),public.archive_admin_update(uuid),public.get_my_training_notifications(uuid) from public,anon;
grant execute on function public.preview_admin_update(text,text,text,uuid[],boolean,text),public.send_admin_update(text,text,text,uuid,uuid[],boolean,text),public.get_admin_updates(),public.archive_admin_update(uuid),public.get_my_training_notifications(uuid) to authenticated;
notify pgrst,'reload schema';
commit;
