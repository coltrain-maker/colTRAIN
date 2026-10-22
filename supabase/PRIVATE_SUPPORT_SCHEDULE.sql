-- Run after migration 019 and deployment of team-support-email.
-- First enable Supabase Cron (pg_cron) and pg_net. In Vault, securely create
-- coltrain_support_worker_key with the same private value as the Edge Function's
-- SUPPORT_WORKER_SECRET (32+ random characters). Never paste its value into this SQL.
do $$begin
 if not exists(select 1 from pg_extension where extname='pg_cron') or not exists(select 1 from pg_extension where extname='pg_net') then
  raise exception 'Enable Supabase Cron (pg_cron) and pg_net, then run this query again';
 end if;
 if to_regclass('vault.decrypted_secrets') is null then
  raise exception 'Enable Supabase Vault before scheduling private support email';
 end if;
 if (select count(*) from vault.decrypted_secrets where name='coltrain_support_worker_key' and length(decrypted_secret)>=32)<>1 then
  raise exception 'Create exactly one Vault secret named coltrain_support_worker_key, matching SUPPORT_WORKER_SECRET, with at least 32 random characters';
 end if;
end$$;
select cron.schedule('coltrain-expired-support-trash','15 * * * *',$job$select private.purge_expired_support_trash();$job$);
select cron.schedule('coltrain-emergency-support-email','* * * * *',$job$
 select net.http_post(
  url:='https://flhdeftduysnjvqnhhee.supabase.co/functions/v1/team-support-email',
  headers:=jsonb_build_object('Content-Type','application/json','x-coltrain-support-worker',
   (select decrypted_secret from vault.decrypted_secrets where name='coltrain_support_worker_key')),
  body:='{}'::jsonb,timeout_milliseconds:=120000);
$job$);
