-- Run after the original security checks; these tests use a separate store.
insert into auth.users(id,email,email_confirmed_at) values
 ('00000000-0000-0000-0000-000000000010','email.manager@example.test',now()),
 ('00000000-0000-0000-0000-000000000011','email.employee@example.test',now()),
 ('00000000-0000-0000-0000-000000000012','email.wrong@example.test',now()),
 ('00000000-0000-0000-0000-000000000013','email.unconfirmed@example.test',null);
insert into public.organizations(id,name) values('10000000-0000-0000-0000-000000000010','Email invitation store');
insert into public.organization_memberships(id,organization_id,user_id,email,role) values
 ('20000000-0000-0000-0000-000000000010','10000000-0000-0000-0000-000000000010','00000000-0000-0000-0000-000000000010','email.manager@example.test','manager');
insert into public.seats(organization_id,membership_id) values
 ('10000000-0000-0000-0000-000000000010','20000000-0000-0000-0000-000000000010');
insert into public.seats(organization_id) select '10000000-0000-0000-0000-000000000010'::uuid from generate_series(1,4);
set role authenticated;
set request.jwt.claim.sub='00000000-0000-0000-0000-000000000010';
select test.rejects($q$select public.prepare_employee_invitation('10000000-0000-0000-0000-000000000001','x@example.test','Name')$q$,'Manager access required','email invitation cannot target another store');
select test.rejects($q$select public.prepare_employee_invitation('10000000-0000-0000-0000-000000000010','x@example.test','Name','manager')$q$,'Only an administrator','email invitation cannot elevate role');
select test.rejects($q$select public.prepare_employee_invitation('10000000-0000-0000-0000-000000000010','x@example.test',' ')$q$,'Enter the employee name','email invitation requires a name');
insert into test.codes select 'email-original-id',invitation_id::text from public.prepare_employee_invitation('10000000-0000-0000-0000-000000000010',' EMAIL.EMPLOYEE@example.test ',' Taylor Employee ');
select test.ok((select invitee_name='Taylor Employee' and email='email.employee@example.test' and email_status='pending' from public.invitations where id=(select code::uuid from test.codes where label='email-original-id')),'email invitation stores normalized name and email');
select test.rejects($q$select public.prepare_employee_invitation('10000000-0000-0000-0000-000000000010','','','employee',(select code::uuid from test.codes where label='email-original-id'))$q$,'Wait one minute','immediate resend throttled');
reset role;
update public.invitations set last_email_attempt_at=now()-interval '61 seconds' where id=(select code::uuid from test.codes where label='email-original-id');
set role authenticated;
set request.jwt.claim.sub='00000000-0000-0000-0000-000000000010';
insert into test.codes select 'email-resend-id',invitation_id::text from public.prepare_employee_invitation('10000000-0000-0000-0000-000000000010','ignored@example.test','Ignored','manager',(select code::uuid from test.codes where label='email-original-id'));
select test.ok((select invitee_name='Taylor Employee' and role='employee' and email='email.employee@example.test' from public.invitations where id=(select code::uuid from test.codes where label='email-resend-id')),'resend preserves database name/email/role instead of request values');
select test.ok((select revoked_at is not null from public.invitations where id=(select code::uuid from test.codes where label='email-original-id')),'resend revokes the original email invitation');
set request.jwt.claim.sub='00000000-0000-0000-0000-000000000012';
select test.rejects($q$select public.accept_email_invitation((select code::uuid from test.codes where label='email-resend-id'))$q$,'does not match your verified email','wrong email cannot claim by invitation ID');
select test.rejects($q$select public.prepare_employee_invitation('10000000-0000-0000-0000-000000000010','x@example.test','Name')$q$,'Manager access required','ordinary account cannot request invitation email');
select test.rejects($q$select private.consume_invitation((select code::uuid from test.codes where label='email-resend-id'))$q$,'permission denied','private invitation helper is not exposed');
set request.jwt.claim.sub='00000000-0000-0000-0000-000000000013';
select test.rejects($q$select public.accept_email_invitation((select code::uuid from test.codes where label='email-resend-id'))$q$,'Confirm your email','unconfirmed account cannot claim email invitation');
set request.jwt.claim.sub='00000000-0000-0000-0000-000000000011';
select test.rejects($q$select public.accept_email_invitation((select code::uuid from test.codes where label='email-original-id'))$q$,'Invitation is invalid','old email link cannot claim a seat after resend');
select public.accept_email_invitation((select code::uuid from test.codes where label='email-resend-id'));
select test.ok((select full_name='Taylor Employee' and not optional_email_notifications from public.profiles where user_id=auth.uid()),'joining copies invited name without opting into optional email');
select test.ok((select count(*) from public.organization_memberships where user_id=auth.uid() and role='employee' and status='active')=1,'email invitation creates employee membership');
select test.rejects($q$select public.accept_email_invitation((select code::uuid from test.codes where label='email-resend-id'))$q$,'Invitation is invalid','email invitation can only be claimed once');
reset role;
select 'Passed email invitation security checks ('||count(*)||' total SQL assertions).' from test.results;
