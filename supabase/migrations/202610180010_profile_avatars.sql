-- Private account avatars. Apply once after 009; existing training/feed permissions remain.
begin;
create table private.profile_photos (
 id uuid primary key, user_id uuid not null references auth.users(id), object_name text not null unique,
 created_at timestamptz not null default clock_timestamp(), published_at timestamptz
);
alter table private.profile_photos enable row level security;
revoke all on private.profile_photos from public,anon,authenticated;
alter table public.profiles add column avatar_path text references private.profile_photos(object_name);
insert into storage.buckets(id,name,public,file_size_limit,allowed_mime_types)
values('profile-photos','profile-photos',false,1048576,array['image/jpeg']);

create function private.can_read_profile_photo(path text) returns boolean
language sql stable security definer set search_path='' as $$
 select exists(select 1 from private.profile_photos f where f.object_name=path and (
  f.user_id=auth.uid() or exists(select 1 from public.profiles p where p.user_id=f.user_id and p.avatar_path=path and private.can_view_profile(p.user_id))));
$$;
create function private.can_upload_profile_photo(path text) returns boolean
language sql stable security definer set search_path='' as $$
 select exists(select 1 from private.profile_photos where object_name=path and user_id=auth.uid() and published_at is null);
$$;
create function private.can_delete_profile_photo(path text) returns boolean
language sql stable security definer set search_path='' as $$
 select exists(select 1 from private.profile_photos f where f.object_name=path and f.user_id=auth.uid()
  and not exists(select 1 from public.profiles p where p.avatar_path=path));
$$;
revoke all on function private.can_read_profile_photo(text),private.can_upload_profile_photo(text),private.can_delete_profile_photo(text) from public,anon;
grant execute on function private.can_read_profile_photo(text),private.can_upload_profile_photo(text),private.can_delete_profile_photo(text) to authenticated;
create policy coltrain_profile_photo_read on storage.objects for select to authenticated
 using(bucket_id='profile-photos' and private.can_read_profile_photo(name));
create policy coltrain_profile_photo_insert on storage.objects for insert to authenticated
 with check(bucket_id='profile-photos' and private.can_upload_profile_photo(name));
create policy coltrain_profile_photo_delete on storage.objects for delete to authenticated
 using(bucket_id='profile-photos' and private.can_delete_profile_photo(name));
-- No update policy: a published photo path cannot be overwritten with different content.

create function public.reserve_profile_photo(photo uuid) returns text
language plpgsql security definer set search_path='' as $$
declare file private.profile_photos%rowtype;
begin
 if auth.uid() is null then raise exception 'Sign in first'; end if;
 if photo is null then raise exception 'A photo ID is required'; end if;
 perform pg_advisory_xact_lock(hashtextextended('profile-photo:'||photo::text,0));
 insert into private.profile_photos(id,user_id,object_name) values(photo,auth.uid(),auth.uid()::text||'/'||photo::text||'.jpg') on conflict(id) do nothing;
 select * into file from private.profile_photos where id=photo and user_id=auth.uid();
 if not found then raise exception 'Photo is not available'; end if;
 return file.object_name;
end;
$$;
create function public.set_my_profile_photo(photo uuid default null) returns jsonb
language plpgsql security definer set search_path='' as $$
declare previous text; file private.profile_photos%rowtype;
begin
 if auth.uid() is null then raise exception 'Sign in first'; end if;
 select avatar_path into previous from public.profiles where user_id=auth.uid() for update;
 if not found then raise exception 'Save your name before adding a profile picture'; end if;
 if photo is not null then
  select * into file from private.profile_photos where id=photo and user_id=auth.uid() for update;
  if not found or (file.published_at is not null and previous is distinct from file.object_name) then raise exception 'Photo is not available'; end if;
  perform id from storage.objects where bucket_id='profile-photos' and name=file.object_name for share;
  if not found then raise exception 'Finish uploading the photo first'; end if;
  update private.profile_photos set published_at=coalesce(published_at,clock_timestamp()) where id=photo;
 end if;
 update public.profiles set avatar_path=file.object_name,updated_at=clock_timestamp() where user_id=auth.uid();
 return jsonb_build_object('previous_object',previous,'object_name',file.object_name);
end;
$$;
revoke all on function public.reserve_profile_photo(uuid),public.set_my_profile_photo(uuid) from public,anon;
grant execute on function public.reserve_profile_photo(uuid),public.set_my_profile_photo(uuid) to authenticated;

create function private.profile_avatar(person uuid) returns text
language sql stable security definer set search_path='' as $$
 select avatar_path from public.profiles where user_id=person and private.can_view_profile(person);
$$;
create function private.member_avatar(member uuid) returns text
language sql stable security definer set search_path='' as $$
 select private.profile_avatar(user_id) from public.organization_memberships where id=member;
$$;
revoke all on function private.profile_avatar(uuid),private.member_avatar(uuid) from public,anon,authenticated;

-- Keep the existing training report's role/store/answer boundaries and add current photos.
alter function public.get_training_workspace(uuid) set schema private;
alter function private.get_training_workspace(uuid) rename to training_workspace_before_avatars;
revoke all on function private.training_workspace_before_avatars(uuid) from public,anon,authenticated;
create function public.get_training_workspace(store uuid) returns jsonb
language plpgsql stable security definer set search_path='' as $$
declare base jsonb; members jsonb; standings jsonb; competitions jsonb;
begin
 base:=private.training_workspace_before_avatars(store);
 select coalesce(jsonb_agg(item||jsonb_build_object('avatar_path',private.member_avatar((item->>'id')::uuid)) order by position),'[]'::jsonb)
 into members from jsonb_array_elements(base->'members') with ordinality x(item,position);
 select coalesce(jsonb_agg(item||jsonb_build_object('avatar_path',private.member_avatar((item->>'membership_id')::uuid)) order by position),'[]'::jsonb)
 into standings from jsonb_array_elements(base->'lifetime_standings') with ordinality x(item,position);
 select coalesce(jsonb_agg(item||jsonb_build_object('standings',(
  select coalesce(jsonb_agg(person||jsonb_build_object('avatar_path',private.member_avatar((person->>'membership_id')::uuid)) order by rank_position),'[]'::jsonb)
  from jsonb_array_elements(item->'standings') with ordinality y(person,rank_position))) order by position),'[]'::jsonb)
 into competitions from jsonb_array_elements(base->'competitions') with ordinality x(item,position);
 return base||jsonb_build_object('members',members,'lifetime_standings',standings,'competitions',competitions);
end;
$$;
revoke all on function public.get_training_workspace(uuid) from public,anon;
grant execute on function public.get_training_workspace(uuid) to authenticated;

create or replace function private.team_corner_comment_json(comment public.team_corner_comments) returns jsonb language sql stable security definer set search_path='' as $$
 select jsonb_build_object('id',comment.id,'post_id',comment.post_id,'author_name',comment.author_name,'avatar_path',private.profile_avatar(comment.author_id),'body',comment.body,'created_at',comment.created_at,
 'can_remove',private.is_member(comment.organization_id) and (comment.author_id=auth.uid() or private.team_corner_manager(comment.organization_id)),
 'media',coalesce((select jsonb_agg(jsonb_build_object('id',id,'object_name',object_name)) from public.team_corner_media where comment_id=comment.id),'[]'::jsonb));
$$;

create or replace function private.team_corner_post_json(post public.team_corner_posts) returns jsonb language sql stable security definer set search_path='' as $$
 select jsonb_build_object('id',post.id,'author_name',post.author_name,'avatar_path',private.profile_avatar(post.author_id),'body',post.body,'created_at',post.created_at,'announcement',post.announcement,'pinned',post.pinned,'comments_open',post.comments_open,
 'can_remove',private.is_member(post.organization_id) and (post.author_id=auth.uid() or private.team_corner_manager(post.organization_id)),
 'like_count',(select count(*) from public.team_corner_likes where post_id=post.id),'liked',exists(select 1 from public.team_corner_likes where post_id=post.id and user_id=auth.uid()),
 'media',coalesce((select jsonb_agg(jsonb_build_object('id',id,'object_name',object_name)) from public.team_corner_media where post_id=post.id),'[]'::jsonb),
 'comments',(public.get_team_corner_comments(post.id)->'comments'),'more_comments',(public.get_team_corner_comments(post.id)->'has_more'));
$$;

notify pgrst,'reload schema';
commit;
