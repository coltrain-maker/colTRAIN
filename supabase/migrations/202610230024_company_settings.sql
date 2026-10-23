-- Apply once after 023. Human-readable company settings and exact-email grants.
begin;
create function public.save_company_details(company uuid, company_name text,
 company_phone text default '', affiliation text default '') returns void
language plpgsql security definer set search_path='' as $$
begin
 perform 1 from private.companies c where c.id=company for update;
 if not found or not private.can_administer_company(company) then raise exception 'Company owner access required'; end if;
 update private.companies set name=btrim(company_name),phone=btrim(company_phone),buying_group=btrim(affiliation) where id=company;
 insert into private.company_access_audit(company_id,actor_id,event)
 values(company,auth.uid(),'company_details_updated');
end;
$$;
create function public.set_company_permission_by_email(company uuid, account_email text,
 capability text, enabled boolean, store uuid default null) returns void
language plpgsql security definer set search_path='' as $$
declare person uuid;
begin
 -- Authorization precedes lookup; this is not a public account-directory endpoint.
 perform 1 from private.companies c where c.id=company for update;
 if not found or not private.can_administer_company(company) then raise exception 'Company owner access required'; end if;
 if account_email is null or length(account_email)>254 then raise exception 'Enter the confirmed account email'; end if;
 select u.id into person from auth.users u where lower(u.email)=lower(btrim(account_email)) and u.email_confirmed_at is not null;
 if person is null then raise exception 'No confirmed account matches. Ask this person to create and confirm their colTRAIN account first'; end if;
 perform public.set_company_permission(company,person,capability,enabled,store);
end;
$$;
create or replace function public.get_company_access_settings(company uuid) returns jsonb
language plpgsql stable security definer set search_path='' as $$
begin
 if not private.can_administer_company(company) or not exists(select 1 from private.companies c where c.id=company)
 then raise exception 'Company owner access required'; end if;
 return jsonb_build_object('company',(select to_jsonb(c) from private.companies c where c.id=company),
  'people',(select coalesce(jsonb_agg(jsonb_build_object('user_id',u.id,'name',coalesce(p.full_name,split_part(u.email,'@',1)),
   'email',u.email) order by u.email),'[]') from auth.users u left join public.profiles p on p.user_id=u.id
   where u.id=(select c.owner_user_id from private.companies c where c.id=company)
    or exists(select 1 from private.company_permissions g where g.company_id=company and g.user_id=u.id)),
  'permissions',(select coalesce(jsonb_agg(to_jsonb(p) order by p.created_at,p.id),'[]') from private.company_permissions p where p.company_id=company),
  'audit',(select coalesce(jsonb_agg(to_jsonb(a) order by a.id desc),'[]') from
   (select * from private.company_access_audit where company_id=company order by id desc limit 100) a));
end;
$$;
revoke all on function public.save_company_details(uuid,text,text,text),
 public.set_company_permission_by_email(uuid,text,text,boolean,uuid) from public,anon,service_role;
grant execute on function public.save_company_details(uuid,text,text,text),
 public.set_company_permission_by_email(uuid,text,text,boolean,uuid) to authenticated;
notify pgrst,'reload schema';
commit;
