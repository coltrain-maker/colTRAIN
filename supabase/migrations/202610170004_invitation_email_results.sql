begin;
-- BYPASSRLS does not grant table privileges. Expose only this delivery-status
-- operation to the server, without granting browser users direct table writes.
create function public.record_invitation_email_result(invitation uuid, delivery_status text)
returns void language plpgsql security definer set search_path='' as $$
begin
 if delivery_status is null or delivery_status not in ('sent','failed') then
  raise exception 'Invalid delivery status';
 end if;
 update public.invitations
 set email_status=delivery_status
 where id=invitation and email_status='pending'
   and accepted_at is null and revoked_at is null;
end;
$$;
revoke all on function public.record_invitation_email_result(uuid,text) from public,anon,authenticated;
grant execute on function public.record_invitation_email_result(uuid,text) to service_role;
commit;
