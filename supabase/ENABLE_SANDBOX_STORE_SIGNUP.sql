-- Run AFTER migration 025, both function deployments, and the webhook signing secret.
-- Enables sandbox signup only. No subscription, store, email, or charge is created.
begin;
set local request.jwt.claim.sub='2370c99a-9b5e-439a-b73a-00ada7a35661';
select public.set_sandbox_store_signup_enabled(true);
select public.get_store_signup_availability();
commit;
