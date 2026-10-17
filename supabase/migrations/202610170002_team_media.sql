-- Private Team Corner pictures. Admin status alone never grants feed access.
begin;
insert into storage.buckets(id,name,public,file_size_limit,allowed_mime_types)
values('team-media','team-media',false,1048576,array['image/jpeg','image/png','image/webp']);
create function private.can_read_team_file(object_name text)
returns boolean language sql stable security definer set search_path='' as $$
 select exists(select 1 from public.organization_memberships where user_id=auth.uid() and status='active' and organization_id::text=split_part(object_name,'/',1));
$$;
create function private.can_write_team_file(object_name text)
returns boolean language sql stable security definer set search_path='' as $$
 select private.can_read_team_file(object_name) and split_part(object_name,'/',2)=auth.uid()::text and length(split_part(object_name,'/',3))>0;
$$;
create function private.can_moderate_team_file(object_name text)
returns boolean language sql stable security definer set search_path='' as $$
 select private.can_read_team_file(object_name) and exists(
  select 1 from public.organization_memberships where user_id=auth.uid() and status='active' and role='manager' and organization_id::text=split_part(object_name,'/',1)
 );
$$;
revoke all on function private.can_read_team_file(text),private.can_write_team_file(text),private.can_moderate_team_file(text) from public,anon;
grant execute on function private.can_read_team_file(text),private.can_write_team_file(text),private.can_moderate_team_file(text) to authenticated;
create policy coltrain_team_media_read on storage.objects for select to authenticated
 using(bucket_id='team-media' and private.can_read_team_file(name));
create policy coltrain_team_media_insert on storage.objects for insert to authenticated
 with check(bucket_id='team-media' and private.can_write_team_file(name));
create policy coltrain_team_media_update on storage.objects for update to authenticated
 using(bucket_id='team-media' and (private.can_write_team_file(name) or private.can_moderate_team_file(name)))
 with check(bucket_id='team-media' and (private.can_write_team_file(name) or private.can_moderate_team_file(name)));
create policy coltrain_team_media_delete on storage.objects for delete to authenticated
 using(bucket_id='team-media' and (private.can_write_team_file(name) or private.can_moderate_team_file(name)));
commit;
