-- Run after migration 020 and the web-push function. Reuses the existing private worker credential.
do $$begin
 if not exists(select 1 from pg_extension where extname='pg_cron') or not exists(select 1 from pg_extension where extname='pg_net') then raise exception 'Enable Cron and pg_net';end if;
 if (select count(*) from vault.decrypted_secrets where name='coltrain_support_worker_key' and length(decrypted_secret)>=32)<>1 then raise exception 'Configure the existing private worker secret in Vault';end if;
end$$;
select cron.schedule('coltrain-web-push','* * * * *',$job$
 select net.http_post(url:='https://flhdeftduysnjvqnhhee.supabase.co/functions/v1/web-push',
 headers:=jsonb_build_object('Content-Type','application/json','x-coltrain-support-worker',
 (select decrypted_secret from vault.decrypted_secrets where name='coltrain_support_worker_key')),
 body:='{}'::jsonb,timeout_milliseconds:=120000);
$job$);
