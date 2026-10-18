-- Team Corner: private store conversations, photos, and manager-requested support.
begin;
-- Enforce the existing private bucket configuration, including on upgraded projects.
update storage.buckets set public=false,file_size_limit=1048576,allowed_mime_types=array['image/jpeg','image/png','image/webp'] where id='team-media';
create table public.team_corner_posts (
 id uuid primary key, organization_id uuid not null references public.organizations(id),
 author_id uuid not null references auth.users(id), author_name text not null,
 body text not null check(length(body)<=5000), created_at timestamptz not null default clock_timestamp(),
 announcement boolean not null default false,pinned boolean not null default false,comments_open boolean not null default true,
 deleted_at timestamptz,deleted_by uuid references auth.users(id),unique(id,organization_id),check(not pinned or announcement)
);
create index team_corner_posts_feed on public.team_corner_posts(organization_id,pinned desc,created_at desc,id desc) where deleted_at is null;
create table public.team_corner_comments (
 id uuid primary key,post_id uuid not null,organization_id uuid not null,author_id uuid not null references auth.users(id),author_name text not null,
 body text not null check(length(body)<=2000),created_at timestamptz not null default clock_timestamp(),deleted_at timestamptz,deleted_by uuid references auth.users(id),
 unique(id,organization_id),foreign key(post_id,organization_id) references public.team_corner_posts(id,organization_id)
);
create index team_corner_comments_thread on public.team_corner_comments(post_id,created_at desc,id desc) where deleted_at is null;
create table public.team_corner_media (
 id uuid primary key,organization_id uuid not null references public.organizations(id),owner_id uuid not null references auth.users(id),
 object_name text not null unique,content_type text not null check(content_type in ('image/jpeg','image/png','image/webp')),created_at timestamptz not null default clock_timestamp(),
 post_id uuid,comment_id uuid,check(num_nonnulls(post_id,comment_id)<=1),
 foreign key(post_id,organization_id) references public.team_corner_posts(id,organization_id),
 foreign key(comment_id,organization_id) references public.team_corner_comments(id,organization_id)
);
create index team_corner_media_post on public.team_corner_media(post_id);
create index team_corner_media_comment on public.team_corner_media(comment_id);
create table public.team_corner_likes (
 post_id uuid not null references public.team_corner_posts(id),user_id uuid not null references auth.users(id),created_at timestamptz not null default clock_timestamp(),primary key(post_id,user_id)
);
create table private.team_corner_support (
 id uuid primary key default gen_random_uuid(),organization_id uuid not null references public.organizations(id),
 requested_by uuid not null references public.organization_memberships(id),reason text not null check(length(btrim(reason)) between 5 and 500),
 created_at timestamptz not null default clock_timestamp(),expires_at timestamptz not null default clock_timestamp()+interval '24 hours',
 revoked_at timestamptz,revoked_by uuid references auth.users(id)
);
create index team_corner_support_store on private.team_corner_support(organization_id,expires_at) where revoked_at is null;
alter table public.team_corner_posts enable row level security;
alter table public.team_corner_comments enable row level security;
alter table public.team_corner_media enable row level security;
alter table public.team_corner_likes enable row level security;
alter table private.team_corner_support enable row level security;
revoke all on public.team_corner_posts,public.team_corner_comments,public.team_corner_media,public.team_corner_likes,private.team_corner_support from public,anon,authenticated;
grant select on public.team_corner_posts,public.team_corner_comments,public.team_corner_media,public.team_corner_likes to authenticated;

-- These helpers deliberately do not use can_manage: platform admins have no automatic feed access.
create function private.team_corner_manager(store uuid) returns boolean language sql stable security definer set search_path='' as $$
 select exists(select 1 from public.organization_memberships where organization_id=store and user_id=auth.uid() and status='active' and role='manager');
$$;
create function private.team_corner_support_active(store uuid) returns boolean language sql stable security definer set search_path='' as $$
 select exists(select 1 from private.team_corner_support s join public.organization_memberships m on m.id=s.requested_by where s.organization_id=store and s.revoked_at is null and s.expires_at>now() and m.status='active' and m.role='manager');
$$;
create function private.team_corner_read(store uuid) returns boolean language sql stable security definer set search_path='' as $$
 select private.is_member(store) or (private.is_admin() and private.team_corner_support_active(store));
$$;
create function private.team_corner_post_visible(post uuid) returns boolean language sql stable security definer set search_path='' as $$
 select exists(select 1 from public.team_corner_posts where id=post and deleted_at is null and private.team_corner_read(organization_id));
$$;
create function private.team_corner_media_read(media uuid) returns boolean language sql stable security definer set search_path='' as $$
 select exists(select 1 from public.team_corner_media f where f.id=media and (
 (f.post_id is null and f.comment_id is null and f.owner_id=auth.uid() and private.is_member(f.organization_id)) or
 (private.team_corner_read(f.organization_id) and (exists(select 1 from public.team_corner_posts p where p.id=f.post_id and p.deleted_at is null) or exists(select 1 from public.team_corner_comments c join public.team_corner_posts p on p.id=c.post_id where c.id=f.comment_id and c.deleted_at is null and p.deleted_at is null)))
 ));
$$;
revoke all on function private.team_corner_manager(uuid),private.team_corner_support_active(uuid),private.team_corner_read(uuid),private.team_corner_post_visible(uuid),private.team_corner_media_read(uuid) from public,anon;
grant execute on function private.team_corner_read(uuid),private.team_corner_post_visible(uuid),private.team_corner_media_read(uuid) to authenticated;
create policy team_corner_posts_read on public.team_corner_posts for select to authenticated using(deleted_at is null and private.team_corner_read(organization_id));
create policy team_corner_comments_read on public.team_corner_comments for select to authenticated using(deleted_at is null and private.team_corner_post_visible(post_id));
create policy team_corner_media_read on public.team_corner_media for select to authenticated using(private.team_corner_media_read(id));
create policy team_corner_likes_read on public.team_corner_likes for select to authenticated using(private.team_corner_post_visible(post_id));

-- Keep legacy object permissions for old, unregistered files; all new UI uploads are registered.
create or replace function private.can_read_team_file(object_name text) returns boolean language sql stable security definer set search_path='' as $$
 select case when exists(select 1 from public.team_corner_media f where f.object_name=can_read_team_file.object_name)
 then exists(select 1 from public.team_corner_media f where f.object_name=can_read_team_file.object_name and private.team_corner_media_read(f.id))
 else exists(select 1 from public.organization_memberships where user_id=auth.uid() and status='active' and organization_id::text=split_part(object_name,'/',1)) end;
$$;
create or replace function private.can_write_team_file(object_name text) returns boolean language sql stable security definer set search_path='' as $$
 select exists(select 1 from public.team_corner_media f where f.object_name=can_write_team_file.object_name and f.owner_id=auth.uid() and f.post_id is null and f.comment_id is null and private.is_member(f.organization_id));
$$;
-- Uploaded pictures cannot be overwritten or renamed after attaching them to a conversation.
drop policy coltrain_team_media_update on storage.objects;

create function public.register_team_corner_media(store uuid,media uuid,content_type text default 'image/jpeg') returns jsonb language plpgsql security definer set search_path='' as $$
declare target public.team_corner_media%rowtype; extension text;
begin
 if auth.uid() is null or not private.is_member(store) then raise exception 'Active store membership required'; end if;
 if media is null or content_type is null or content_type not in ('image/jpeg','image/png','image/webp') then raise exception 'Choose a JPG, PNG, or WebP photo'; end if;
 extension:=case content_type when 'image/jpeg' then 'jpg' when 'image/png' then 'png' else 'webp' end;
 insert into public.team_corner_media(id,organization_id,owner_id,object_name,content_type) values(media,store,auth.uid(),store::text||'/'||auth.uid()::text||'/'||media::text||'.'||extension,content_type) on conflict(id) do nothing;
 select * into target from public.team_corner_media where id=media for update;
 if target.owner_id<>auth.uid() or target.organization_id<>store or target.post_id is not null or target.comment_id is not null then raise exception 'Photo is not available for this upload'; end if;
 return jsonb_build_object('id',target.id,'object_name',target.object_name);
end;
$$;
create function private.attach_team_corner_media(store uuid,media_ids uuid[],post uuid default null,comment uuid default null) returns void language plpgsql security definer set search_path='' as $$
declare photo uuid;
begin
 if cardinality(coalesce(media_ids,'{}'))>4 then raise exception 'Choose up to four photos'; end if;
 if cardinality(coalesce(media_ids,'{}'))<>(select count(distinct f) from unnest(coalesce(media_ids,'{}')) f) then raise exception 'Choose each photo once'; end if;
 -- Lock in a stable order so two submissions cannot attach one photo to different records.
 for photo in select f from unnest(coalesce(media_ids,'{}')) f order by f loop
  perform 1 from public.team_corner_media where id=photo and organization_id=store and owner_id=auth.uid() and post_id is null and comment_id is null for update;
  if not found then raise exception 'Photo is not available for this post'; end if;
  if not exists(select 1 from storage.objects o join public.team_corner_media f on f.object_name=o.name where f.id=photo and o.bucket_id='team-media') then raise exception 'Wait for each photo to finish uploading'; end if;
  update public.team_corner_media set post_id=post,comment_id=comment where id=photo;
 end loop;
end;
$$;
revoke all on function private.attach_team_corner_media(uuid,uuid[],uuid,uuid) from public,anon,authenticated;
create function public.create_team_corner_post(store uuid,submission uuid,message text,media_ids uuid[] default '{}',is_announcement boolean default false,pin boolean default false,allow_comments boolean default true) returns uuid language plpgsql security definer set search_path='' as $$
declare target public.team_corner_posts%rowtype; display_name text;
begin
 if auth.uid() is null or not private.is_member(store) then raise exception 'Active store membership required'; end if;
 if submission is null then raise exception 'A submission ID is required'; end if;
 perform pg_advisory_xact_lock(hashtextextended('team-post:'||submission::text,0));
 select * into target from public.team_corner_posts where id=submission;
 if found then
  if target.organization_id<>store or target.author_id<>auth.uid() or target.deleted_at is not null then raise exception 'Submission ID is not available'; end if;
  return target.id;
 end if;
 if message is null or length(message)>5000 or (length(btrim(message))=0 and cardinality(coalesce(media_ids,'{}'))=0) then raise exception 'Write a post or add a photo (up to 5000 characters)'; end if;
 if (coalesce(is_announcement,false) or coalesce(pin,false) or not coalesce(allow_comments,true)) and not private.team_corner_manager(store) then raise exception 'Store manager access required'; end if;
 select coalesce(nullif(full_name,''),split_part((select email from auth.users where id=auth.uid()),'@',1)) into display_name from public.profiles where user_id=auth.uid();
 insert into public.team_corner_posts(id,organization_id,author_id,author_name,body,announcement,pinned,comments_open)
 values(submission,store,auth.uid(),coalesce(display_name,'Teammate'),btrim(message),coalesce(is_announcement,false) or coalesce(pin,false),coalesce(pin,false),coalesce(allow_comments,true));
 perform private.attach_team_corner_media(store,media_ids,submission,null);
 return submission;
end;
$$;
create function public.create_team_corner_comment(post uuid,submission uuid,message text,media_ids uuid[] default '{}') returns uuid language plpgsql security definer set search_path='' as $$
declare target public.team_corner_posts%rowtype; existing public.team_corner_comments%rowtype; display_name text;
begin
 if auth.uid() is null then raise exception 'Active store membership required'; end if;
 select * into target from public.team_corner_posts where id=post for update;
 if not found or target.deleted_at is not null or not private.is_member(target.organization_id) then raise exception 'Post is not available'; end if;
 if submission is null then raise exception 'A submission ID is required'; end if;
 perform pg_advisory_xact_lock(hashtextextended('team-comment:'||submission::text,0));
 select * into existing from public.team_corner_comments where id=submission;
 if found then
  if existing.post_id<>post or existing.author_id<>auth.uid() or existing.deleted_at is not null then raise exception 'Submission ID is not available'; end if;
  return existing.id;
 end if;
 if not target.comments_open then raise exception 'Comments are turned off for this post'; end if;
 if message is null or length(message)>2000 or (length(btrim(message))=0 and cardinality(coalesce(media_ids,'{}'))=0) then raise exception 'Write a comment or add a photo (up to 2000 characters)'; end if;
 select coalesce(nullif(full_name,''),split_part((select email from auth.users where id=auth.uid()),'@',1)) into display_name from public.profiles where user_id=auth.uid();
 insert into public.team_corner_comments(id,post_id,organization_id,author_id,author_name,body) values(submission,post,target.organization_id,auth.uid(),coalesce(display_name,'Teammate'),btrim(message));
 perform private.attach_team_corner_media(target.organization_id,media_ids,null,submission);
 return submission;
end;
$$;
create function public.set_team_corner_like(post uuid,liked boolean) returns void language plpgsql security definer set search_path='' as $$
declare store uuid;
begin
 select organization_id into store from public.team_corner_posts where id=post and deleted_at is null for share;
 if not found or not private.is_member(store) then raise exception 'Post is not available'; end if;
 if coalesce(liked,false) then insert into public.team_corner_likes(post_id,user_id) values(post,auth.uid()) on conflict do nothing;
 else delete from public.team_corner_likes where post_id=post and user_id=auth.uid(); end if;
end;
$$;
create function public.set_team_corner_post_options(post uuid,is_pinned boolean,allow_comments boolean) returns void language plpgsql security definer set search_path='' as $$
declare target public.team_corner_posts%rowtype;
begin
 select * into target from public.team_corner_posts where id=post for update;
 if not found or target.deleted_at is not null or not private.team_corner_manager(target.organization_id) then raise exception 'Store manager access required'; end if;
 update public.team_corner_posts set pinned=coalesce(is_pinned,false),announcement=announcement or coalesce(is_pinned,false),comments_open=coalesce(allow_comments,true) where id=post;
end;
$$;
create function public.remove_team_corner_item(item uuid,is_comment boolean default false) returns void language plpgsql security definer set search_path='' as $$
declare store uuid; author uuid; parent uuid;
begin
 if coalesce(is_comment,false) then
  select post_id into parent from public.team_corner_comments where id=item;
  perform 1 from public.team_corner_posts where id=parent for update;
  select organization_id,author_id into store,author from public.team_corner_comments where id=item for update;
 else select organization_id,author_id into store,author from public.team_corner_posts where id=item for update; end if;
 if store is null or not private.is_member(store) or not(author=auth.uid() or private.team_corner_manager(store)) then raise exception 'Only the author or store manager can remove this item'; end if;
 if coalesce(is_comment,false) then update public.team_corner_comments set deleted_at=coalesce(deleted_at,clock_timestamp()),deleted_by=coalesce(deleted_by,auth.uid()) where id=item;
 else update public.team_corner_posts set deleted_at=coalesce(deleted_at,clock_timestamp()),deleted_by=coalesce(deleted_by,auth.uid()) where id=item; end if;
end;
$$;
create function public.request_team_corner_support(store uuid,support_reason text) returns timestamptz language plpgsql security definer set search_path='' as $$
declare member uuid; expiry timestamptz;
begin
 if not private.team_corner_manager(store) then raise exception 'Store manager access required'; end if;
 if support_reason is null or length(btrim(support_reason)) not between 5 and 500 then raise exception 'Describe the support you need (5–500 characters)'; end if;
 perform pg_advisory_xact_lock(hashtextextended('team-support:'||store::text,0));
 select id into member from public.organization_memberships where organization_id=store and user_id=auth.uid() and status='active' and role='manager';
 update private.team_corner_support set revoked_at=clock_timestamp(),revoked_by=auth.uid() where organization_id=store and revoked_at is null;
 insert into private.team_corner_support(organization_id,requested_by,reason) values(store,member,btrim(support_reason)) returning expires_at into expiry;
 return expiry;
end;
$$;
create function public.revoke_team_corner_support(store uuid) returns void language plpgsql security definer set search_path='' as $$
begin
 if not private.team_corner_manager(store) then raise exception 'Store manager access required'; end if;
 perform pg_advisory_xact_lock(hashtextextended('team-support:'||store::text,0));
 update private.team_corner_support set revoked_at=clock_timestamp(),revoked_by=auth.uid() where organization_id=store and revoked_at is null;
end;
$$;

create function private.team_corner_comment_json(comment public.team_corner_comments) returns jsonb language sql stable security definer set search_path='' as $$
 select jsonb_build_object('id',comment.id,'post_id',comment.post_id,'author_name',comment.author_name,'body',comment.body,'created_at',comment.created_at,
 'can_remove',private.is_member(comment.organization_id) and (comment.author_id=auth.uid() or private.team_corner_manager(comment.organization_id)),
 'media',coalesce((select jsonb_agg(jsonb_build_object('id',id,'object_name',object_name)) from public.team_corner_media where comment_id=comment.id),'[]'::jsonb));
$$;
create function public.get_team_corner_comments(post uuid,before_time timestamptz default null,before_id uuid default null) returns jsonb language plpgsql stable security definer set search_path='' as $$
declare result jsonb;
begin
 if not private.team_corner_post_visible(post) then raise exception 'Store feed access required'; end if;
 select coalesce(jsonb_agg(private.team_corner_comment_json(c) order by c.created_at,c.id),'[]'::jsonb) into result from (select * from public.team_corner_comments where post_id=post and deleted_at is null and (before_time is null or (created_at,id)<(before_time,before_id)) order by created_at desc,id desc limit 20)c;
 return jsonb_build_object('comments',result,'has_more',exists(select 1 from public.team_corner_comments where post_id=post and deleted_at is null and (created_at,id)<((result->0->>'created_at')::timestamptz,(result->0->>'id')::uuid)));
end;
$$;
create function private.team_corner_post_json(post public.team_corner_posts) returns jsonb language sql stable security definer set search_path='' as $$
 select jsonb_build_object('id',post.id,'author_name',post.author_name,'body',post.body,'created_at',post.created_at,'announcement',post.announcement,'pinned',post.pinned,'comments_open',post.comments_open,
 'can_remove',private.is_member(post.organization_id) and (post.author_id=auth.uid() or private.team_corner_manager(post.organization_id)),
 'like_count',(select count(*) from public.team_corner_likes where post_id=post.id),'liked',exists(select 1 from public.team_corner_likes where post_id=post.id and user_id=auth.uid()),
 'media',coalesce((select jsonb_agg(jsonb_build_object('id',id,'object_name',object_name)) from public.team_corner_media where post_id=post.id),'[]'::jsonb),
 'comments',(public.get_team_corner_comments(post.id)->'comments'),'more_comments',(public.get_team_corner_comments(post.id)->'has_more'));
$$;
revoke all on function private.team_corner_comment_json(public.team_corner_comments),private.team_corner_post_json(public.team_corner_posts) from public,anon,authenticated;
create function public.get_team_corner(store uuid,before_time timestamptz default null,before_id uuid default null) returns jsonb language plpgsql stable security definer set search_path='' as $$
declare posts jsonb; pin_rows jsonb; support jsonb; can_read boolean; managing boolean;
begin
 if auth.uid() is null or not(private.is_member(store) or private.is_admin()) then raise exception 'Store feed access required'; end if;
 can_read:=private.team_corner_read(store);managing:=private.team_corner_manager(store);
 if not can_read then return jsonb_build_object('can_read',false,'can_post',false,'is_manager',false,'posts','[]'::jsonb,'pinned','[]'::jsonb,'has_more',false,'support',null); end if;
 if managing or private.is_admin() then
 select jsonb_build_object('expires_at',s.expires_at,'reason',s.reason,'requested_by',coalesce(p.full_name,'Store manager')) into support from private.team_corner_support s join public.organization_memberships m on m.id=s.requested_by left join public.profiles p on p.user_id=m.user_id where s.organization_id=store and s.revoked_at is null and s.expires_at>now() and m.status='active' and m.role='manager' order by s.created_at desc limit 1;
 end if;
 select coalesce(jsonb_agg(private.team_corner_post_json(p) order by p.created_at desc,p.id desc),'[]'::jsonb) into posts from (select * from public.team_corner_posts where organization_id=store and deleted_at is null and not pinned and (before_time is null or (created_at,id)<(before_time,before_id)) order by created_at desc,id desc limit 20)p;
 select coalesce(jsonb_agg(private.team_corner_post_json(p) order by p.created_at desc,p.id desc),'[]'::jsonb) into pin_rows from public.team_corner_posts p where organization_id=store and deleted_at is null and p.pinned;
 return jsonb_build_object('can_read',true,'can_post',private.is_member(store),'is_manager',managing,'posts',posts,'pinned',pin_rows,'support',support,
 'has_more',exists(select 1 from public.team_corner_posts where organization_id=store and deleted_at is null and not team_corner_posts.pinned and (created_at,id)<((posts->-1->>'created_at')::timestamptz,(posts->-1->>'id')::uuid)));
end;
$$;
revoke all on function public.register_team_corner_media(uuid,uuid,text),public.create_team_corner_post(uuid,uuid,text,uuid[],boolean,boolean,boolean),public.create_team_corner_comment(uuid,uuid,text,uuid[]),public.set_team_corner_like(uuid,boolean),public.set_team_corner_post_options(uuid,boolean,boolean),public.remove_team_corner_item(uuid,boolean),public.request_team_corner_support(uuid,text),public.revoke_team_corner_support(uuid),public.get_team_corner_comments(uuid,timestamptz,uuid),public.get_team_corner(uuid,timestamptz,uuid) from public,anon;
grant execute on function public.register_team_corner_media(uuid,uuid,text),public.create_team_corner_post(uuid,uuid,text,uuid[],boolean,boolean,boolean),public.create_team_corner_comment(uuid,uuid,text,uuid[]),public.set_team_corner_like(uuid,boolean),public.set_team_corner_post_options(uuid,boolean,boolean),public.remove_team_corner_item(uuid,boolean),public.request_team_corner_support(uuid,text),public.revoke_team_corner_support(uuid),public.get_team_corner_comments(uuid,timestamptz,uuid),public.get_team_corner(uuid,timestamptz,uuid) to authenticated;
create function public.get_team_corner_support_requests() returns jsonb language plpgsql stable security definer set search_path='' as $$
begin
 if auth.uid() is null or not private.is_admin() then raise exception 'Administrator access required'; end if;
 return (select coalesce(jsonb_agg(jsonb_build_object('store_id',o.id,'store_name',o.name,'reason',s.reason,'expires_at',s.expires_at,'requested_by',coalesce(p.full_name,'Store manager')) order by s.created_at desc),'[]'::jsonb)
 from private.team_corner_support s join public.organizations o on o.id=s.organization_id join public.organization_memberships m on m.id=s.requested_by left join public.profiles p on p.user_id=m.user_id
 where s.revoked_at is null and s.expires_at>now() and m.status='active' and m.role='manager');
end;
$$;
revoke all on function public.get_team_corner_support_requests() from public,anon;
grant execute on function public.get_team_corner_support_requests() to authenticated;
notify pgrst,'reload schema';
commit;
