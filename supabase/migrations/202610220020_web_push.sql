-- Optional, personal-device Web Push. No live delivery until function/cron deployment.
begin;
create table private.web_push_subscriptions(
 id uuid primary key default gen_random_uuid(), user_id uuid not null references auth.users(id) on delete cascade,
 endpoint text not null unique, p256dh text not null, auth_key text not null,
 seen_ids jsonb not null default '[]', next_scan_at timestamptz not null default now(),
 lease uuid, leased_at timestamptz, created_at timestamptz not null default now(), failures integer not null default 0
);
alter table private.web_push_subscriptions enable row level security;
revoke all on private.web_push_subscriptions from public,anon,authenticated;
-- Internal snapshot evaluates existing recipient/role/store privacy rules as the owner.
create function private.push_snapshot(person uuid) returns jsonb
language plpgsql security definer set search_path='' as $$
declare old_sub text:=current_setting('request.jwt.claim.sub',true); old_claims text:=current_setting('request.jwt.claims',true); m record; result jsonb; ids jsonb:='[]';
begin
 perform set_config('request.jwt.claim.sub',person::text,true);
 perform set_config('request.jwt.claims',jsonb_build_object('sub',person,'role','authenticated')::text,true);
 for m in select distinct organization_id from public.organization_memberships where user_id=person and status='active' loop
  result:=public.get_my_training_notifications(m.organization_id);
  select ids||coalesce(jsonb_agg(i->>'id'),'[]') into ids from jsonb_array_elements(result->'items')i where i->>'read_at' is null;
 end loop;
 perform set_config('request.jwt.claim.sub',coalesce(old_sub,''),true);perform set_config('request.jwt.claims',coalesce(old_claims,''),true);
 return jsonb_build_object('ids',ids,'count',jsonb_array_length(ids));
exception when others then
 perform set_config('request.jwt.claim.sub',coalesce(old_sub,''),true);perform set_config('request.jwt.claims',coalesce(old_claims,''),true);raise;
end;$$;
revoke all on function private.push_snapshot(uuid) from public,anon,authenticated,service_role;
create function public.get_my_web_push_count() returns integer
language plpgsql security definer set search_path='' as $$
begin
 if auth.uid() is null then raise exception 'Sign in first';end if;
 return (private.push_snapshot(auth.uid())->>'count')::integer;
end;$$;
revoke all on function public.get_my_web_push_count() from public,anon;
grant execute on function public.get_my_web_push_count() to authenticated;
create function public.save_web_push(push_endpoint text,public_key text,auth_secret text) returns void
language plpgsql security definer set search_path='' as $$
begin
 if auth.uid() is null or not exists(select 1 from public.organization_memberships where user_id=auth.uid() and status='active') then raise exception 'Active store membership required';end if;
 if length(push_endpoint)>4096 or push_endpoint !~ '^https://(fcm\.googleapis\.com|updates\.push\.services\.mozilla\.com|web\.push\.apple\.com|[a-zA-Z0-9-]+\.notify\.windows\.com)/[^[:space:]]+$'
 or public_key !~ '^[A-Za-z0-9_-]{87}$' or auth_secret !~ '^[A-Za-z0-9_-]{22}$' then raise exception 'Invalid push subscription';end if;
 perform pg_advisory_xact_lock(hashtextextended(auth.uid()::text,20));
 if exists(select 1 from private.web_push_subscriptions where endpoint=push_endpoint and user_id<>auth.uid()) then raise exception 'Turn off notifications on this browser before switching accounts';end if;
 if (select count(*) from private.web_push_subscriptions where user_id=auth.uid())>=10 and not exists(select 1 from private.web_push_subscriptions where endpoint=push_endpoint and user_id=auth.uid()) then raise exception 'Up to 10 personal devices are supported';end if;
 insert into private.web_push_subscriptions(user_id,endpoint,p256dh,auth_key,seen_ids)
 values(auth.uid(),push_endpoint,public_key,auth_secret,private.push_snapshot(auth.uid())->'ids')
 on conflict(endpoint) do update set p256dh=excluded.p256dh,auth_key=excluded.auth_key,seen_ids=excluded.seen_ids,next_scan_at=now(),failures=0;
end;$$;
create function public.get_web_push_status(push_endpoint text) returns boolean
language sql stable security definer set search_path='' as $$
 select auth.uid() is not null and exists(select 1 from private.web_push_subscriptions where user_id=auth.uid() and endpoint=push_endpoint);
$$;
create function public.remove_web_push(push_endpoint text) returns void
language sql security definer set search_path='' as $$
 delete from private.web_push_subscriptions where user_id=auth.uid() and endpoint=push_endpoint;
$$;
-- Only the authenticated scheduled worker can call these service-only RPCs.
create function public.claim_web_push() returns jsonb
language plpgsql security definer set search_path='' as $$
declare s private.web_push_subscriptions%rowtype; snapshot jsonb; token uuid:=gen_random_uuid();fresh boolean;
begin
 select * into s from private.web_push_subscriptions where next_scan_at<=now() and (lease is null or leased_at<now()-interval '5 minutes') order by next_scan_at,id for update skip locked limit 1;
 if not found then return null;end if;
 snapshot:=private.push_snapshot(s.user_id);
 select exists(select 1 from jsonb_array_elements_text(snapshot->'ids')i where not s.seen_ids ? i) into fresh;
 if not fresh then
  update private.web_push_subscriptions set seen_ids=snapshot->'ids',next_scan_at=now()+interval '1 minute',lease=null where id=s.id;
  return jsonb_build_object('skip',true);
 end if;
 update private.web_push_subscriptions set lease=token,leased_at=now(),next_scan_at=now()+interval '1 minute' where id=s.id;
 return jsonb_build_object('id',s.id,'lease',token,'subscription',jsonb_build_object('endpoint',s.endpoint,'keys',jsonb_build_object('p256dh',s.p256dh,'auth',s.auth_key)),
 'ids',snapshot->'ids','count',snapshot->'count');
end;$$;
create function public.finish_web_push(subscription_id uuid,claim_lease uuid,unread_ids jsonb,outcome text) returns void
language plpgsql security definer set search_path='' as $$
begin
 if outcome='expired' then delete from private.web_push_subscriptions where id=subscription_id and lease=claim_lease;return;end if;
 update private.web_push_subscriptions set seen_ids=case when outcome='sent' then unread_ids else seen_ids end,
 failures=case when outcome='sent' then 0 else failures+1 end,lease=null,
 next_scan_at=now()+case when outcome='sent' then interval '1 minute' else interval '5 minutes' end
 where id=subscription_id and lease=claim_lease;
end;$$;
revoke all on function public.save_web_push(text,text,text),public.get_web_push_status(text),public.remove_web_push(text) from public,anon;
grant execute on function public.save_web_push(text,text,text),public.get_web_push_status(text),public.remove_web_push(text) to authenticated;
revoke all on function public.claim_web_push(),public.finish_web_push(uuid,uuid,jsonb,text) from public,anon,authenticated;
grant execute on function public.claim_web_push(),public.finish_web_push(uuid,uuid,jsonb,text) to service_role;
notify pgrst,'reload schema';
commit;
