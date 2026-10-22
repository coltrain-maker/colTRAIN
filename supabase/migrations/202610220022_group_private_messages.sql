-- Apply once after 021. Preserve existing messages; expand fixed participant groups.
begin;
-- Finish the previously approved cleanup before migrating legacy Trash.
do $$begin perform private.purge_expired_support_trash();end$$;
alter table private.support_threads alter column employee_id drop not null;
alter table private.support_threads alter column manager_id drop not null;
alter table private.support_threads add unique(id,organization_id);
create table private.support_participants(
 thread_id uuid not null, organization_id uuid not null,membership_id uuid not null,
 archived_at timestamptz,deleted_at timestamptz,
 primary key(thread_id,membership_id),
 foreign key(thread_id,organization_id) references private.support_threads(id,organization_id) on delete cascade,
 foreign key(organization_id,membership_id) references public.organization_memberships(organization_id,id)
);
alter table private.support_participants enable row level security;
revoke all on private.support_participants from public,anon,authenticated;
insert into private.support_participants(thread_id,organization_id,membership_id,archived_at,deleted_at)
select id,organization_id,employee_id,archived_at,deleted_at from private.support_threads
union all select id,organization_id,manager_id,archived_at,deleted_at from private.support_threads;
-- Inbox state belongs to participants from now on. Legacy identities remain for audit/history.
update private.support_threads set archived_at=null,deleted_at=null;
alter table private.support_email_queue drop constraint support_email_queue_message_id_key;
alter table private.support_email_queue add unique(message_id,manager_id);
create or replace function private.support_access(thread uuid,person uuid default auth.uid()) returns boolean
language sql stable security definer set search_path='' as $$
 select exists(select 1 from private.support_participants p join public.organization_memberships m on m.id=p.membership_id and m.organization_id=p.organization_id
 where p.thread_id=thread and m.user_id=person and m.status='active' and (p.deleted_at is null or p.deleted_at>=now()-interval '30 days'));
$$;
create or replace function private.support_manager(thread uuid,person uuid default auth.uid()) returns boolean
language sql stable security definer set search_path='' as $$
 select exists(select 1 from private.support_participants p join public.organization_memberships m on m.id=p.membership_id
 where p.thread_id=thread and m.user_id=person and m.status='active' and m.role='manager' and (p.deleted_at is null or p.deleted_at>=now()-interval '30 days'));
$$;
create or replace function private.purge_expired_support_trash() returns void
language plpgsql security definer set search_path='' as $$
begin
 -- Expired personal copies lose access even when other participants keep their history.
 delete from private.training_notifications n using private.support_messages x,private.support_participants p,public.organization_memberships m
 where n.event_key='support-message:'||x.id::text and x.thread_id=p.thread_id and m.id=p.membership_id and n.user_id=m.user_id and p.deleted_at<now()-interval '30 days';
 delete from private.support_threads t where exists(select 1 from private.support_participants where thread_id=t.id)
 and not exists(select 1 from private.support_participants p where p.thread_id=t.id and (p.deleted_at is null or p.deleted_at>=now()-interval '30 days'));
end;$$;
create or replace function private.purge_support_trash(store uuid) returns void
language plpgsql security definer set search_path='' as $$
begin
 -- Physical group cleanup is handled by the existing hourly owner job.
 delete from private.training_notifications n using private.support_messages x,private.support_participants p,public.organization_memberships m
 where p.organization_id=store and n.event_key='support-message:'||x.id::text and x.thread_id=p.thread_id and m.id=p.membership_id and n.user_id=m.user_id and m.user_id=auth.uid() and p.deleted_at<now()-interval '30 days';
end;$$;
create or replace function private.support_thread_json(thread uuid) returns jsonb
language sql stable security definer set search_path='' as $$
 select to_jsonb(t)||jsonb_build_object('archived_at',own.archived_at,'deleted_at',own.deleted_at,'can_manage',true,
 'participants',(select jsonb_agg(jsonb_build_object('id',m.id,'name',coalesce(nullif(pr.full_name,''),split_part(m.email,'@',1)),
 'role',m.role,'active',m.status='active','is_me',m.user_id=auth.uid()) order by coalesce(pr.full_name,m.email),m.id)
 from private.support_participants p join public.organization_memberships m on m.id=p.membership_id left join public.profiles pr on pr.user_id=m.user_id where p.thread_id=t.id),
 'can_reply',own.deleted_at is null and exists(select 1 from private.support_participants p join public.organization_memberships m on m.id=p.membership_id
 where p.thread_id=t.id and p.membership_id<>own.membership_id and m.status='active' and (p.deleted_at is null or p.deleted_at>=now()-interval '30 days')),
 'unread_count',(select count(*) from private.support_receipts r join private.support_messages x on x.id=r.message_id where x.thread_id=t.id and r.membership_id=own.membership_id and r.read_at is null),
 'last_body',(select left(body,160) from private.support_messages where thread_id=t.id order by seq desc limit 1),
 'has_emergency',exists(select 1 from private.support_messages where thread_id=t.id and emergency),
 'email_pending',(select count(*) from private.support_email_queue q join private.support_messages x on x.id=q.message_id where x.thread_id=t.id and q.status in ('queued','working','failed')))
 from private.support_threads t join private.support_participants own on own.thread_id=t.id
 join public.organization_memberships me on me.id=own.membership_id where t.id=thread and me.user_id=auth.uid() and private.support_access(t.id);
$$;
create or replace function public.get_team_support_workspace(store uuid,folder text default 'inbox',keywords text default '',page integer default 0) returns jsonb
language plpgsql security definer set search_path='' as $$
declare me public.organization_memberships%rowtype; rows jsonb; contacts jsonb;total integer;
begin
 select * into me from public.organization_memberships where organization_id=store and user_id=auth.uid() and status='active';
 if not found then raise exception 'Active store membership required';end if;
 if folder not in ('inbox','archive','trash') or page is null or page<0 or page>10000 or length(coalesce(keywords,''))>200 then raise exception 'Invalid message search';end if;
 perform private.purge_support_trash(store);
 select coalesce(jsonb_agg(jsonb_build_object('id',m.id,'name',coalesce(nullif(p.full_name,''),split_part(m.email,'@',1)),'role',m.role) order by coalesce(p.full_name,m.email),m.id),'[]') into contacts
 from public.organization_memberships m left join public.profiles p on p.user_id=m.user_id where m.organization_id=store and m.status='active' and m.id<>me.id;
 with matches as(
 select t.id,t.updated_at from private.support_threads t join private.support_participants p on p.thread_id=t.id and p.membership_id=me.id
 where t.organization_id=store and private.support_access(t.id)
 and case folder when 'trash' then p.deleted_at is not null when 'archive' then p.deleted_at is null and p.archived_at is not null else p.deleted_at is null and p.archived_at is null end
 and (btrim(coalesce(keywords,''))='' or to_tsvector('english',t.subject||' '||coalesce((select string_agg(x.body,' ') from private.support_messages x where x.thread_id=t.id),'')) @@ websearch_to_tsquery('english',keywords))
 ), limited as(select * from matches order by updated_at desc,id limit 25 offset page*25)
 select (select count(*) from matches),coalesce(jsonb_agg(private.support_thread_json(l.id) order by l.updated_at desc,l.id),'[]') into total,rows from limited l;
 return jsonb_build_object('is_manager',me.role='manager','my_membership',me.id,'recipients',contacts,'threads',rows,'total',total,'page',page,'has_more',(page+1)*25<total);
end;$$;
create or replace function public.get_team_support_thread(thread uuid,before_seq bigint default null) returns jsonb
language plpgsql security definer set search_path='' as $$
declare messages jsonb;cutoff bigint;earliest bigint;
begin
 if not private.support_access(thread) then raise exception 'Private conversation not available';end if;
 select coalesce(jsonb_agg(to_jsonb(x) order by x.seq),'[]'),max(x.seq),min(x.seq) into messages,cutoff,earliest
 from(select id,seq,author_member,author_name,body,emergency,created_at from private.support_messages where thread_id=thread and (before_seq is null or seq<before_seq) order by seq desc limit 50)x;
 return jsonb_build_object('thread',private.support_thread_json(thread),'messages',messages,'read_through',cutoff,
 'has_older',exists(select 1 from private.support_messages where thread_id=thread and seq<earliest),
 'email_counts',(select coalesce(jsonb_object_agg(s.status,s.n),'{}') from(select q.status,count(*) n from private.support_email_queue q join private.support_messages m on m.id=q.message_id where m.thread_id=thread group by q.status)s));
end;$$;
drop function public.send_team_support_message(uuid,uuid,text,uuid,uuid,text,text,boolean);
create function public.send_team_support_message(store uuid,submission_key uuid,message_body text,thread uuid default null,recipient uuid default null,category text default 'general',subject text default null,emergency boolean default false,recipients uuid[] default '{}') returns jsonb
language plpgsql security definer set search_path='' as $$
declare me public.organization_memberships%rowtype;target private.support_threads%rowtype;prior private.support_messages%rowtype;ids uuid[];new_id uuid:=gen_random_uuid();name text;urgent boolean;manager_count integer;
begin
 select * into me from public.organization_memberships where organization_id=store and user_id=auth.uid() and status='active';
 if not found then raise exception 'Active store membership required';end if;
 if submission_key is null then raise exception 'Submission key required';end if;
 perform pg_advisory_xact_lock(hashtextextended(auth.uid()::text||':'||submission_key::text,0));
 select * into prior from private.support_messages x where x.author_id=auth.uid() and x.submission_key=send_team_support_message.submission_key;
 if found then
  if not private.support_access(prior.thread_id) or not exists(select 1 from private.support_participants where thread_id=prior.thread_id and membership_id=me.id and deleted_at is null) then raise exception 'Private conversation not available';end if;
  return jsonb_build_object('thread_id',prior.thread_id,'message_id',prior.id,'emergency',prior.emergency);
 end if;
 if message_body is null or length(btrim(message_body)) not between 1 and 5000 then raise exception 'Enter a message of up to 5,000 characters';end if;
 if thread is null then
  if category is null or category not in ('emergency','work','app','customer','general','other') or subject is null or length(btrim(subject)) not between 1 and 150 then raise exception 'Choose a category and enter a subject';end if;
  if cardinality(coalesce(recipients,'{}'))>50 then raise exception 'Choose up to 50 recipients';end if;
  select array_agg(distinct x order by x) into ids from unnest(coalesce(recipients,'{}')||case when recipient is null then '{}'::uuid[] else array[recipient] end)x;
  if coalesce(cardinality(ids),0) not between 1 and 50 or me.id=any(ids) or exists(select 1 from unnest(ids)x where x is null)
   or (select count(*) from public.organization_memberships where id=any(ids) and organization_id=store and status='active')<>cardinality(ids) then raise exception 'Choose active recipients from this store, excluding yourself';end if;
  urgent:=coalesce(emergency,false) or category='emergency';
  select count(*) into manager_count from public.organization_memberships where (id=any(ids) or id=me.id) and role='manager' and status='active';
  if urgent and manager_count=0 then raise exception 'Include an active manager in every Emergency conversation';end if;
  insert into private.support_threads(organization_id,created_by,subject,category) values(store,auth.uid(),btrim(subject),category) returning * into target;
  insert into private.support_participants(thread_id,organization_id,membership_id) select target.id,store,x from unnest(ids||array[me.id])x;
 else
  select * into target from private.support_threads where id=thread for update;
  if not found or target.organization_id<>store or not private.support_access(thread) or not exists(select 1 from private.support_participants where thread_id=thread and membership_id=me.id and deleted_at is null) then raise exception 'Private conversation not available';end if;
  if not exists(select 1 from private.support_participants p join public.organization_memberships m on m.id=p.membership_id where p.thread_id=thread and m.id<>me.id and m.status='active' and (p.deleted_at is null or p.deleted_at>=now()-interval '30 days')) then raise exception 'No other active participants remain; start a new conversation';end if;
  urgent:=coalesce(emergency,false) or target.category='emergency';
  select count(*) into manager_count from private.support_participants p join public.organization_memberships m on m.id=p.membership_id where p.thread_id=thread and m.role='manager' and m.status='active' and p.deleted_at is null;
  if urgent and manager_count=0 then raise exception 'Include an active manager in every Emergency conversation; start a new conversation with a manager';end if;
 end if;
 select coalesce(nullif(full_name,''),split_part(me.email,'@',1)) into name from public.profiles where user_id=auth.uid();
 insert into private.support_messages(id,thread_id,author_id,author_member,author_name,body,emergency,submission_key)
 values(new_id,target.id,auth.uid(),me.id,coalesce(name,split_part(me.email,'@',1)),btrim(message_body),urgent,submission_key);
 insert into private.support_receipts(message_id,membership_id)
 select new_id,p.membership_id from private.support_participants p join public.organization_memberships m on m.id=p.membership_id
 where p.thread_id=target.id and m.status='active' and p.deleted_at is null and m.id<>me.id;
 if urgent then
  insert into private.support_email_queue(message_id,manager_id)
  select new_id,m.id from private.support_participants p join public.organization_memberships m on m.id=p.membership_id where p.thread_id=target.id and m.status='active' and m.role='manager' and p.deleted_at is null;
 end if;
 update private.support_threads set updated_at=clock_timestamp() where id=target.id;
 update private.support_participants set archived_at=null where thread_id=target.id and deleted_at is null;
 return jsonb_build_object('thread_id',target.id,'message_id',new_id,'emergency',urgent);
end;$$;
create or replace function public.set_team_support_state(thread uuid,action text) returns void
language plpgsql security definer set search_path='' as $$
declare own private.support_participants%rowtype;
begin
 select p.* into own from private.support_participants p join public.organization_memberships m on m.id=p.membership_id where p.thread_id=thread and m.user_id=auth.uid() and m.status='active' for update of p;
 if not found then raise exception 'Private conversation not available';end if;
 if own.deleted_at<now()-interval '30 days' then raise exception 'Recovery period has expired';end if;
 if action='restore' and own.deleted_at is not null then
  update private.support_participants set deleted_at=null,archived_at=null where thread_id=thread and membership_id=own.membership_id;
 elsif own.deleted_at is not null then raise exception 'Restore this conversation before making changes';
 elsif action='archive' then update private.support_participants set archived_at=clock_timestamp() where thread_id=thread and membership_id=own.membership_id;
 elsif action='unarchive' then update private.support_participants set archived_at=null where thread_id=thread and membership_id=own.membership_id;
 elsif action='delete' then update private.support_participants set deleted_at=clock_timestamp() where thread_id=thread and membership_id=own.membership_id;
 else raise exception 'Choose archive, unarchive, delete or restore';end if;
end;$$;
-- Replace only the support branch of the existing notification chain; preserve training/admin/feed.
create or replace function private.notifications_before_team_posts(store uuid)
returns table(event_key text,kind text,title text,body text,course_id uuid,target_view text,competition_id uuid,event_at timestamptz)
language sql stable security definer set search_path='' as $$
 select * from private.training_notification_candidates_before_support(store)
 union all
 select 'support-message:'||x.id::text,'support_message',case when x.emergency then 'Emergency private message' else 'New private message' end,
 x.author_name||' · '||t.subject,null::uuid,'messages',null::uuid,x.created_at
 from private.support_receipts r join private.support_messages x on x.id=r.message_id join private.support_threads t on t.id=x.thread_id
 join public.organization_memberships me on me.id=r.membership_id join private.support_participants p on p.thread_id=t.id and p.membership_id=me.id
 where t.organization_id=store and me.user_id=auth.uid() and me.status='active' and private.support_access(t.id) and p.deleted_at is null;
$$;
create or replace function public.claim_support_email(actor uuid) returns jsonb
language plpgsql security definer set search_path='' as $$
declare job private.support_email_queue%rowtype;message private.support_messages%rowtype;recipient record;token uuid:=gen_random_uuid();
begin
 select q.* into job from private.support_email_queue q join private.support_messages x on x.id=q.message_id
 where (actor is null or private.support_access(x.thread_id,actor)) and (q.status in ('queued','failed') or q.status='working' and q.leased_at<now()-interval '5 minutes')
 order by q.leased_at nulls first,q.id for update of q skip locked limit 1;
 if not found then return null;end if;
 select * into message from private.support_messages where id=job.message_id;
 select m.*,u.email current_email,p.deleted_at personal_deleted into recipient from public.organization_memberships m join auth.users u on u.id=m.user_id join private.support_participants p on p.membership_id=m.id and p.thread_id=message.thread_id where m.id=job.manager_id;
 if not found or recipient.status<>'active' or recipient.role<>'manager' or recipient.personal_deleted is not null or (job.first_attempt_at is not null and job.email is distinct from recipient.current_email) then
  update private.support_email_queue set status='canceled' where id=job.id;return jsonb_build_object('skip',true);
 end if;
 if job.first_attempt_at<now()-interval '23 hours' then update private.support_email_queue set status='review' where id=job.id;return jsonb_build_object('skip',true);end if;
 update private.support_email_queue set status='working',lease_id=token,email=recipient.current_email,leased_at=clock_timestamp(),first_attempt_at=coalesce(first_attempt_at,clock_timestamp()) where id=job.id;
 return jsonb_build_object('id',job.id,'lease_id',token,'email',recipient.current_email,'thread_id',message.thread_id,
 'body','An Emergency private message from '||message.author_name||' is waiting for you in colTRAIN. Sign in to read it.');
end;$$;
revoke all on function public.send_team_support_message(uuid,uuid,text,uuid,uuid,text,text,boolean,uuid[]) from public,anon;
grant execute on function public.send_team_support_message(uuid,uuid,text,uuid,uuid,text,text,boolean,uuid[]) to authenticated;
notify pgrst,'reload schema';
commit;
