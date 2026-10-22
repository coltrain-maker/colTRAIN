-- Apply once after 018. Private employee/selected-manager support conversations.
begin;
create table private.support_threads (
 id uuid primary key default gen_random_uuid(),organization_id uuid not null references public.organizations(id),
 employee_id uuid not null,manager_id uuid not null,created_by uuid not null references auth.users(id),
 subject text not null check(length(btrim(subject)) between 1 and 150),
 category text not null check(category in ('emergency','work','app','customer','general','other')),
 created_at timestamptz not null default clock_timestamp(),updated_at timestamptz not null default clock_timestamp(),
 archived_at timestamptz,deleted_at timestamptz,changed_by uuid references auth.users(id),
 foreign key(organization_id,employee_id) references public.organization_memberships(organization_id,id),
 foreign key(organization_id,manager_id) references public.organization_memberships(organization_id,id),check(employee_id<>manager_id)
);
create table private.support_messages (
 id uuid primary key default gen_random_uuid(),seq bigint generated always as identity unique,
 thread_id uuid not null references private.support_threads(id) on delete cascade,
 author_id uuid not null references auth.users(id),author_member uuid not null references public.organization_memberships(id),
 author_name text not null,body text not null check(length(btrim(body)) between 1 and 5000),emergency boolean not null default false,
 submission_key uuid not null,created_at timestamptz not null default clock_timestamp(),unique(author_id,submission_key)
);
create index support_message_thread on private.support_messages(thread_id,seq);
create table private.support_receipts (
 message_id uuid not null references private.support_messages(id) on delete cascade,
 membership_id uuid not null references public.organization_memberships(id),read_at timestamptz,
 primary key(message_id,membership_id)
);
create table private.support_email_queue (
 id uuid primary key default gen_random_uuid(),message_id uuid not null unique references private.support_messages(id) on delete cascade,
 manager_id uuid not null references public.organization_memberships(id),email text,
 status text not null default 'queued' check(status in ('queued','working','sent','failed','canceled','review')),
 lease_id uuid,leased_at timestamptz,first_attempt_at timestamptz,provider_id text,last_error text
);
alter table private.support_threads enable row level security;
alter table private.support_messages enable row level security;
alter table private.support_receipts enable row level security;
alter table private.support_email_queue enable row level security;
revoke all on private.support_threads,private.support_messages,private.support_receipts,private.support_email_queue from public,anon,authenticated;
create index support_thread_people on private.support_threads(organization_id,employee_id,manager_id,updated_at desc);
create function private.support_access(thread uuid,person uuid default auth.uid()) returns boolean
language sql stable security definer set search_path='' as $$
 select exists(select 1 from private.support_threads t join public.organization_memberships m on m.organization_id=t.organization_id
 where t.id=thread and m.user_id=person and m.status='active' and (m.id=t.employee_id or m.id=t.manager_id and m.role='manager'));
$$;
create function private.support_manager(thread uuid,person uuid default auth.uid()) returns boolean
language sql stable security definer set search_path='' as $$
 select exists(select 1 from private.support_threads t join public.organization_memberships m on m.id=t.manager_id
 where t.id=thread and m.user_id=person and m.status='active' and m.role='manager');
$$;
create function private.purge_support_trash(store uuid) returns void
language plpgsql security definer set search_path='' as $$
begin
 -- Only threads assigned to this signed-in manager; no platform-admin bypass.
 delete from private.training_notifications n using private.support_messages m,private.support_threads t
 where t.organization_id=store and private.support_manager(t.id) and t.deleted_at<now()-interval '30 days'
 and m.thread_id=t.id and n.event_key='support-message:'||m.id::text;
 delete from private.support_threads t where t.organization_id=store and private.support_manager(t.id) and t.deleted_at<now()-interval '30 days';
end;
$$;
-- The scheduled cleanup has no user bypass: it only erases expired Trash, never live conversations.
create function private.purge_expired_support_trash() returns void
language plpgsql security definer set search_path='' as $$
begin
 delete from private.training_notifications n using private.support_messages m,private.support_threads t
 where t.deleted_at<now()-interval '30 days' and m.thread_id=t.id and n.event_key='support-message:'||m.id::text;
 delete from private.support_threads where deleted_at<now()-interval '30 days';
end;
$$;
revoke all on function private.purge_expired_support_trash() from public,anon,authenticated,service_role;
create function private.support_thread_json(thread uuid) returns jsonb
language sql stable security definer set search_path='' as $$
 select to_jsonb(t)||jsonb_build_object('can_manage',private.support_manager(t.id),
 'employee_name',coalesce(nullif(ep.full_name,''),split_part(e.email,'@',1)),
 'manager_name',coalesce(nullif(mp.full_name,''),split_part(m.email,'@',1)),
 'can_reply',t.deleted_at is null and e.status='active' and m.status='active' and m.role='manager',
 'unread_count',(select count(*) from private.support_receipts r join private.support_messages x on x.id=r.message_id
 join public.organization_memberships me on me.id=r.membership_id where x.thread_id=t.id and me.user_id=auth.uid() and r.read_at is null),
 'last_body',(select left(body,160) from private.support_messages where thread_id=t.id order by seq desc limit 1),
 'has_emergency',exists(select 1 from private.support_messages where thread_id=t.id and emergency),
 'email_pending',(select count(*) from private.support_email_queue q join private.support_messages x on x.id=q.message_id where x.thread_id=t.id and q.status in ('queued','working','failed')))
 from private.support_threads t join public.organization_memberships e on e.id=t.employee_id
 join public.organization_memberships m on m.id=t.manager_id left join public.profiles ep on ep.user_id=e.user_id left join public.profiles mp on mp.user_id=m.user_id
 where t.id=thread and private.support_access(t.id);
$$;
create function public.get_team_support_workspace(store uuid,folder text default 'inbox',keywords text default '',page integer default 0) returns jsonb
language plpgsql security definer set search_path='' as $$
declare me public.organization_memberships%rowtype; rows jsonb; recipients jsonb; total integer;
begin
 select * into me from public.organization_memberships where organization_id=store and user_id=auth.uid() and status='active';
 if not found then raise exception 'Active store membership required'; end if;
 if folder not in ('inbox','archive','trash') or page is null or page<0 or page>10000 or length(coalesce(keywords,''))>200 then raise exception 'Invalid message search'; end if;
 perform private.purge_support_trash(store);
 select coalesce(jsonb_agg(jsonb_build_object('id',m.id,'name',coalesce(nullif(p.full_name,''),split_part(m.email,'@',1)),'role',m.role) order by coalesce(p.full_name,m.email)),'[]') into recipients
 from public.organization_memberships m left join public.profiles p on p.user_id=m.user_id where m.organization_id=store and m.status='active' and m.id<>me.id and m.role=case when me.role='manager' then 'employee' else 'manager' end;
 with matches as (
 select t.id,t.updated_at from private.support_threads t where t.organization_id=store and private.support_access(t.id)
 and case folder when 'trash' then t.deleted_at is not null and t.deleted_at>=now()-interval '30 days' and private.support_manager(t.id)
 when 'archive' then t.deleted_at is null and t.archived_at is not null else t.deleted_at is null and t.archived_at is null end
 and (btrim(coalesce(keywords,''))='' or to_tsvector('english',t.subject||' '||coalesce((select string_agg(x.body,' ') from private.support_messages x where x.thread_id=t.id),'')) @@ websearch_to_tsquery('english',keywords))
 ), limited as (select * from matches order by updated_at desc,id limit 25 offset page*25)
 select (select count(*) from matches),coalesce(jsonb_agg(private.support_thread_json(l.id) order by l.updated_at desc,l.id),'[]') into total,rows from limited l;
 return jsonb_build_object('is_manager',me.role='manager','my_membership',me.id,'recipients',recipients,'threads',rows,'total',total,'page',page,'has_more',(page+1)*25<total);
end;
$$;
create function public.get_team_support_thread(thread uuid,before_seq bigint default null) returns jsonb
language plpgsql security definer set search_path='' as $$
declare target private.support_threads%rowtype; messages jsonb; cutoff bigint; earliest bigint;
begin
 select * into target from private.support_threads where id=thread;
 if not found or not private.support_access(thread) or target.deleted_at is not null and (not private.support_manager(thread) or target.deleted_at<now()-interval '30 days') then raise exception 'Private conversation not available'; end if;
 select coalesce(jsonb_agg(to_jsonb(x) order by x.seq),'[]'),max(x.seq),min(x.seq) into messages,cutoff,earliest
 from (select id,seq,author_member,author_name,body,emergency,created_at from private.support_messages where thread_id=thread and (before_seq is null or seq<before_seq) order by seq desc limit 50) x;
 return jsonb_build_object('thread',private.support_thread_json(thread),'messages',messages,'read_through',cutoff,
 'has_older',exists(select 1 from private.support_messages where thread_id=thread and seq<earliest),
 'email_counts',(select coalesce(jsonb_object_agg(s.status,s.n),'{}') from (select q.status,count(*) n from private.support_email_queue q join private.support_messages m on m.id=q.message_id where m.thread_id=thread group by q.status)s));
end;
$$;
create function public.mark_team_support_read(thread uuid,through_seq bigint,from_seq bigint default 0) returns integer
language plpgsql security definer set search_path='' as $$
begin
 if not private.support_access(thread) then raise exception 'Private conversation not available'; end if;
 update private.support_receipts r set read_at=coalesce(read_at,clock_timestamp()) from private.support_messages x,public.organization_memberships me
 where x.id=r.message_id and x.thread_id=thread and x.seq<=through_seq and x.seq>=from_seq and me.id=r.membership_id and me.user_id=auth.uid() and me.status='active';
 update private.training_notifications n set read_at=coalesce(n.read_at,r.read_at) from private.support_receipts r,private.support_messages x,public.organization_memberships me
 where r.message_id=x.id and x.thread_id=thread and me.id=r.membership_id and me.user_id=auth.uid() and n.user_id=auth.uid() and n.event_key='support-message:'||x.id::text;
 return (select count(*)::integer from private.support_receipts r join private.support_messages x on x.id=r.message_id join public.organization_memberships me on me.id=r.membership_id where x.thread_id=thread and me.user_id=auth.uid() and r.read_at is null);
end;
$$;
create function public.send_team_support_message(store uuid,submission_key uuid,message_body text,thread uuid default null,recipient uuid default null,category text default 'general',subject text default null,emergency boolean default false) returns jsonb
language plpgsql security definer set search_path='' as $$
declare me public.organization_memberships%rowtype; target private.support_threads%rowtype; other public.organization_memberships%rowtype; prior private.support_messages%rowtype; new_id uuid:=gen_random_uuid(); name text; urgent boolean;
begin
 select * into me from public.organization_memberships where organization_id=store and user_id=auth.uid() and status='active';
 if not found then raise exception 'Active store membership required'; end if;
 if submission_key is null then raise exception 'Submission key required'; end if;
 perform pg_advisory_xact_lock(hashtextextended(auth.uid()::text||':'||submission_key::text,0));
 select * into prior from private.support_messages x where x.author_id=auth.uid() and x.submission_key=send_team_support_message.submission_key;
 if found then
  if not private.support_access(prior.thread_id) or not exists(select 1 from private.support_threads where id=prior.thread_id and deleted_at is null) then raise exception 'Private conversation not available'; end if;
  return jsonb_build_object('thread_id',prior.thread_id,'message_id',prior.id,'emergency',prior.emergency);
 end if;
 if message_body is null or length(btrim(message_body)) not between 1 and 5000 then raise exception 'Enter a message of up to 5,000 characters'; end if;
 if thread is null then
  if category is null or category not in ('emergency','work','app','customer','general','other') or subject is null or length(btrim(subject)) not between 1 and 150 then raise exception 'Choose a category and enter a subject'; end if;
  select * into other from public.organization_memberships where id=recipient and organization_id=store and status='active' and role=case when me.role='manager' then 'employee' else 'manager' end;
  if not found then raise exception 'Choose an active recipient from this store'; end if;
  insert into private.support_threads(organization_id,employee_id,manager_id,created_by,subject,category)
  values(store,case when me.role='manager' then other.id else me.id end,case when me.role='manager' then me.id else other.id end,auth.uid(),btrim(subject),category) returning * into target;
 else
  select * into target from private.support_threads where id=thread for update;
  if not found or target.organization_id<>store or not private.support_access(thread) or target.deleted_at is not null then raise exception 'Private conversation not available'; end if;
  if not exists(select 1 from public.organization_memberships where id=target.employee_id and status='active') or not exists(select 1 from public.organization_memberships where id=target.manager_id and role='manager' and status='active') then raise exception 'A participant is no longer active; start a new conversation with an active manager'; end if;
 end if;
 select coalesce(nullif(full_name,''),split_part(me.email,'@',1)) into name from public.profiles where user_id=auth.uid();
 urgent:=coalesce(emergency,false) or target.category='emergency';
 insert into private.support_messages(id,thread_id,author_id,author_member,author_name,body,emergency,submission_key)
 values(new_id,target.id,auth.uid(),me.id,coalesce(name,split_part(me.email,'@',1)),btrim(message_body),urgent,submission_key);
 insert into private.support_receipts(message_id,membership_id) values(new_id,case when me.id=target.manager_id then target.employee_id else target.manager_id end);
 if urgent then insert into private.support_email_queue(message_id,manager_id) values(new_id,target.manager_id); end if;
 update private.support_threads set updated_at=clock_timestamp(),archived_at=null where id=target.id;
 return jsonb_build_object('thread_id',target.id,'message_id',new_id,'emergency',urgent);
end;
$$;
create function public.set_team_support_state(thread uuid,action text) returns void
language plpgsql security definer set search_path='' as $$
declare target private.support_threads%rowtype;
begin
 select * into target from private.support_threads where id=thread for update;
 if not found or not private.support_manager(thread) then raise exception 'Only the selected manager can manage this conversation'; end if;
 if target.deleted_at<now()-interval '30 days' then raise exception 'Recovery period has expired'; end if;
 if action='restore' and target.deleted_at is not null then
  update private.support_threads set deleted_at=null,archived_at=null,changed_by=auth.uid() where id=thread;
 elsif target.deleted_at is not null then raise exception 'Restore this conversation before making changes';
 elsif action='archive' then update private.support_threads set archived_at=clock_timestamp(),changed_by=auth.uid() where id=thread;
 elsif action='unarchive' then update private.support_threads set archived_at=null,changed_by=auth.uid() where id=thread;
 elsif action='delete' then update private.support_threads set deleted_at=clock_timestamp(),changed_by=auth.uid() where id=thread;
 else raise exception 'Choose archive, unarchive, delete or restore'; end if;
end;
$$;
-- Extend the existing inbox without exposing another person's private conversations.
alter function private.training_notification_candidates(uuid) rename to training_notification_candidates_before_support;
revoke all on function private.training_notification_candidates_before_support(uuid) from public,anon,authenticated;
create function private.training_notification_candidates(store uuid)
returns table(event_key text,kind text,title text,body text,course_id uuid,target_view text,competition_id uuid,event_at timestamptz)
language sql stable security definer set search_path='' as $$
 select * from private.training_notification_candidates_before_support(store)
 union all
 select 'support-message:'||x.id::text,'support_message',case when x.emergency then 'Emergency private message' else 'New private message' end,
 x.author_name||' · '||t.subject,null::uuid,'messages',null::uuid,x.created_at
 from private.support_receipts r join private.support_messages x on x.id=r.message_id
 join private.support_threads t on t.id=x.thread_id join public.organization_memberships me on me.id=r.membership_id
 where t.organization_id=store and me.user_id=auth.uid() and private.support_access(t.id) and t.deleted_at is null;
$$;
alter function public.get_my_training_notifications(uuid) set schema private;
alter function private.get_my_training_notifications(uuid) rename to notifications_before_private_support;
revoke all on function private.notifications_before_private_support(uuid) from public,anon,authenticated;
create function public.get_my_training_notifications(store uuid) returns jsonb
language plpgsql security definer set search_path='' as $$
declare base jsonb; items jsonb;
begin
 base:=private.notifications_before_private_support(store);
 update private.training_notifications n set read_at=coalesce(n.read_at,r.read_at) from private.support_receipts r,private.support_messages x,public.organization_memberships me
 where x.id=r.message_id and me.id=r.membership_id and me.user_id=auth.uid() and n.user_id=auth.uid() and n.organization_id=store and n.event_key='support-message:'||x.id::text;
 select coalesce(jsonb_agg(item||case when x.id is not null then jsonb_build_object('support_thread_id',x.thread_id,'read_at',n.read_at,'created_at',x.created_at) else '{}'::jsonb end order by position),'[]') into items
 from jsonb_array_elements(base->'items') with ordinality a(item,position)
 left join private.training_notifications n on n.id=(item->>'id')::uuid and n.user_id=auth.uid() and n.organization_id=store
 left join private.support_messages x on n.event_key='support-message:'||x.id::text;
 return base||jsonb_build_object('items',items,'unread_count',(select count(*) from jsonb_array_elements(items)i where i->>'read_at' is null));
end;
$$;
alter function public.mark_training_notifications_read(uuid,uuid[],boolean) set schema private;
alter function private.mark_training_notifications_read(uuid,uuid[],boolean) rename to mark_notifications_before_support;
revoke all on function private.mark_notifications_before_support(uuid,uuid[],boolean) from public,anon,authenticated;
create function public.mark_training_notifications_read(store uuid,notification_ids uuid[] default '{}',mark_all boolean default false) returns void
language plpgsql security definer set search_path='' as $$
begin
 perform private.mark_notifications_before_support(store,notification_ids,mark_all);
 update private.support_receipts r set read_at=coalesce(r.read_at,n.read_at) from private.support_messages x,private.training_notifications n,public.organization_memberships me
 where r.message_id=x.id and me.id=r.membership_id and me.user_id=auth.uid() and me.status='active'
 and n.organization_id=store and n.user_id=auth.uid() and n.event_key='support-message:'||x.id::text;
end;
$$;
-- Emergency email intentionally ignores optional email opt-out, as approved by the owner.
create function public.claim_support_email(actor uuid) returns jsonb
language plpgsql security definer set search_path='' as $$
declare job private.support_email_queue%rowtype; message private.support_messages%rowtype; target private.support_threads%rowtype; recipient record; token uuid:=gen_random_uuid();
begin
 select q.* into job from private.support_email_queue q join private.support_messages x on x.id=q.message_id
 where (actor is null or private.support_access(x.thread_id,actor)) and (q.status in ('queued','failed') or q.status='working' and q.leased_at<now()-interval '5 minutes')
 order by q.leased_at nulls first,q.id for update of q skip locked limit 1;
 if not found then return null; end if;
 select * into message from private.support_messages where id=job.message_id;
 select * into target from private.support_threads where id=message.thread_id;
 select m.*,u.email current_email into recipient from public.organization_memberships m join auth.users u on u.id=m.user_id where m.id=target.manager_id;
 if target.deleted_at is not null or recipient.status<>'active' or recipient.role<>'manager' or (job.first_attempt_at is not null and job.email is distinct from recipient.current_email) then
  update private.support_email_queue set status='canceled' where id=job.id;return jsonb_build_object('skip',true);
 end if;
 if job.first_attempt_at<now()-interval '23 hours' then
  update private.support_email_queue set status='review' where id=job.id;return jsonb_build_object('skip',true);
 end if;
 update private.support_email_queue set status='working',lease_id=token,email=recipient.current_email,leased_at=clock_timestamp(),first_attempt_at=coalesce(first_attempt_at,clock_timestamp()) where id=job.id;
 return jsonb_build_object('id',job.id,'lease_id',token,'email',recipient.current_email,'thread_id',target.id,
 'body','An Emergency private message from '||message.author_name||' is waiting for you in colTRAIN. Sign in to read it.');
end;
$$;
create function public.finish_support_email(delivery_id uuid,lease uuid,success boolean,provider_id text default null) returns void
language plpgsql security definer set search_path='' as $$
begin
 update private.support_email_queue q set status=case when success then 'sent' else 'failed' end,provider_id=finish_support_email.provider_id,
 last_error=case when success then null else 'Provider did not confirm acceptance' end
 where q.id=delivery_id and q.lease_id=lease and q.status='working';
 if not found then raise exception 'Email lease expired'; end if;
end;
$$;
revoke all on function private.support_access(uuid,uuid),private.support_manager(uuid,uuid),private.purge_support_trash(uuid),private.support_thread_json(uuid),private.training_notification_candidates(uuid) from public,anon,authenticated;
revoke all on function public.get_team_support_workspace(uuid,text,text,integer),public.get_team_support_thread(uuid,bigint),public.mark_team_support_read(uuid,bigint,bigint),public.send_team_support_message(uuid,uuid,text,uuid,uuid,text,text,boolean),public.set_team_support_state(uuid,text),public.get_my_training_notifications(uuid),public.mark_training_notifications_read(uuid,uuid[],boolean) from public,anon;
grant execute on function public.get_team_support_workspace(uuid,text,text,integer),public.get_team_support_thread(uuid,bigint),public.mark_team_support_read(uuid,bigint,bigint),public.send_team_support_message(uuid,uuid,text,uuid,uuid,text,text,boolean),public.set_team_support_state(uuid,text),public.get_my_training_notifications(uuid),public.mark_training_notifications_read(uuid,uuid[],boolean) to authenticated;
revoke all on function public.claim_support_email(uuid),public.finish_support_email(uuid,uuid,boolean,text) from public,anon,authenticated;
grant execute on function public.claim_support_email(uuid),public.finish_support_email(uuid,uuid,boolean,text) to service_role;
notify pgrst,'reload schema';
commit;
