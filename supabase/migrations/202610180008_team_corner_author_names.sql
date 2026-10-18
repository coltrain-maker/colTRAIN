-- Fix authors without a saved profile and repair existing placeholder names.
-- Apply only this update to an existing project already using Team Corner.
begin;
alter table public.profiles add column team_corner_nickname text
 check(team_corner_nickname is null or length(btrim(team_corner_nickname)) between 1 and 60);
create function public.save_my_account_preferences(display_name text,email_notifications boolean default false,team_nickname text default null)
returns void language plpgsql security definer set search_path='' as $$
begin
 if auth.uid() is null then raise exception 'Sign in first'; end if;
 if team_nickname is not null and length(btrim(team_nickname))>60 then raise exception 'Use a nickname of 60 characters or fewer'; end if;
 perform public.save_my_profile(display_name,email_notifications);
 update public.profiles set team_corner_nickname=nullif(btrim(team_nickname),'') where user_id=auth.uid();
end;
$$;
revoke all on function public.save_my_account_preferences(text,boolean,text) from public,anon;
grant execute on function public.save_my_account_preferences(text,boolean,text) to authenticated;
create or replace function private.team_corner_author_name(person uuid) returns text
language sql stable security definer set search_path='' as $$
 select coalesce(
  (select coalesce(nullif(btrim(team_corner_nickname),''),nullif(btrim(full_name),'')) from public.profiles where user_id=person),
  (select nullif(split_part(email,'@',1),'') from auth.users where id=person),
  'Teammate');
$$;
revoke all on function private.team_corner_author_name(uuid) from public,anon,authenticated;
create or replace function public.create_team_corner_post(store uuid,submission uuid,message text,media_ids uuid[] default '{}',is_announcement boolean default false,pin boolean default false,allow_comments boolean default true) returns uuid language plpgsql security definer set search_path='' as $$
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
 display_name := private.team_corner_author_name(auth.uid());
 insert into public.team_corner_posts(id,organization_id,author_id,author_name,body,announcement,pinned,comments_open)
 values(submission,store,auth.uid(),coalesce(display_name,'Teammate'),btrim(message),coalesce(is_announcement,false) or coalesce(pin,false),coalesce(pin,false),coalesce(allow_comments,true));
 perform private.attach_team_corner_media(store,media_ids,submission,null);
 return submission;
end;
$$;

create or replace function public.create_team_corner_comment(post uuid,submission uuid,message text,media_ids uuid[] default '{}') returns uuid language plpgsql security definer set search_path='' as $$
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
 display_name := private.team_corner_author_name(auth.uid());
 insert into public.team_corner_comments(id,post_id,organization_id,author_id,author_name,body) values(submission,post,target.organization_id,auth.uid(),coalesce(display_name,'Teammate'),btrim(message));
 perform private.attach_team_corner_media(target.organization_id,media_ids,null,submission);
 return submission;
end;
$$;

-- Profile names are the display identity for both old and new conversation.
create or replace function private.refresh_team_corner_author_name() returns trigger
language plpgsql security definer set search_path='' as $$
begin
 update public.team_corner_posts set author_name=private.team_corner_author_name(new.user_id) where author_id=new.user_id and author_name is distinct from private.team_corner_author_name(new.user_id);
 update public.team_corner_comments set author_name=private.team_corner_author_name(new.user_id) where author_id=new.user_id and author_name is distinct from private.team_corner_author_name(new.user_id);
 return new;
end;
$$;
revoke all on function private.refresh_team_corner_author_name() from public,anon,authenticated;
create or replace trigger team_corner_profile_name after insert or update of full_name,team_corner_nickname on public.profiles
for each row execute function private.refresh_team_corner_author_name();
update public.team_corner_posts set author_name=private.team_corner_author_name(author_id) where author_name='Teammate';
update public.team_corner_comments set author_name=private.team_corner_author_name(author_id) where author_name='Teammate';
notify pgrst,'reload schema';
commit;
