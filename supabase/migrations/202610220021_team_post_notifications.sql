-- Notify active store teammates about new Team Corner posts only; no historical backfill.
begin;
create table private.team_post_audience(
 post_id uuid not null references public.team_corner_posts(id) on delete cascade,
 membership_id uuid not null references public.organization_memberships(id) on delete cascade,
 primary key(post_id,membership_id)
);
alter table private.team_post_audience enable row level security;
revoke all on private.team_post_audience from public,anon,authenticated;
create function private.notify_new_team_post() returns trigger
language plpgsql security definer set search_path='' as $$
begin
 if new.deleted_at is null then
  insert into private.team_post_audience(post_id,membership_id)
  select new.id,m.id from public.organization_memberships m where m.organization_id=new.organization_id
   and m.status='active' and m.user_id<>new.author_id
  on conflict do nothing;
 end if;
 return new;
end;$$;
revoke all on function private.notify_new_team_post() from public,anon,authenticated,service_role;
create trigger coltrain_new_team_post after insert on public.team_corner_posts
for each row execute function private.notify_new_team_post();
alter function private.training_notification_candidates(uuid) rename to notifications_before_team_posts;
revoke all on function private.notifications_before_team_posts(uuid) from public,anon,authenticated;
create function private.training_notification_candidates(store uuid)
returns table(event_key text,kind text,title text,body text,course_id uuid,target_view text,competition_id uuid,event_at timestamptz)
language sql stable security definer set search_path='' as $$
 select * from private.notifications_before_team_posts(store)
 union all
 select 'team-post:'||p.id::text,'team_post',case when p.announcement then 'New Team Corner announcement' else 'New Team Corner post' end,
 p.author_name||' shared a post with your team.',null::uuid,'team',null::uuid,p.created_at
 from private.team_post_audience a join public.team_corner_posts p on p.id=a.post_id
 join public.organization_memberships m on m.id=a.membership_id
 where p.organization_id=store and m.organization_id=store and m.user_id=auth.uid() and m.status='active'
  and m.user_id<>p.author_id and p.deleted_at is null;
$$;
revoke all on function private.training_notification_candidates(uuid) from public,anon,authenticated;
alter function public.get_my_training_notifications(uuid) set schema private;
alter function private.get_my_training_notifications(uuid) rename to notifications_before_team_post_details;
revoke all on function private.notifications_before_team_post_details(uuid) from public,anon,authenticated;
create function public.get_my_training_notifications(store uuid) returns jsonb
language plpgsql security definer set search_path='' as $$
declare base jsonb;items jsonb;
begin
 base:=private.notifications_before_team_post_details(store);
 select coalesce(jsonb_agg(i||case when p.id is not null then jsonb_build_object('team_post_id',p.id,'created_at',p.created_at) else '{}'::jsonb end order by position),'[]') into items
 from jsonb_array_elements(base->'items') with ordinality a(i,position)
 left join private.training_notifications n on n.id=(i->>'id')::uuid and n.user_id=auth.uid() and n.organization_id=store
 left join public.team_corner_posts p on n.event_key='team-post:'||p.id::text and p.organization_id=store and p.deleted_at is null;
 return base||jsonb_build_object('items',items);
end;$$;
create function public.get_team_corner_post(post uuid) returns jsonb
language plpgsql stable security definer set search_path='' as $$
declare result jsonb;
begin
 if not private.team_corner_post_visible(post) then raise exception 'Store feed access required';end if;
 select private.team_corner_post_json(p) into result from public.team_corner_posts p where p.id=post and p.deleted_at is null;
 return result;
end;$$;
revoke all on function public.get_my_training_notifications(uuid),public.get_team_corner_post(uuid) from public,anon;
grant execute on function public.get_my_training_notifications(uuid),public.get_team_corner_post(uuid) to authenticated;
notify pgrst,'reload schema';
commit;
