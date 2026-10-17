insert into auth.users(id,email,email_confirmed_at) values
 ('00000000-0000-0000-0000-000000000001','admin@example.test',now()),
 ('00000000-0000-0000-0000-000000000002','manager.a@example.test',now()),
 ('00000000-0000-0000-0000-000000000003','manager.b@example.test',now()),
 ('00000000-0000-0000-0000-000000000004','employee.a@example.test',now()),
 ('00000000-0000-0000-0000-000000000005','employee.b@example.test',now()),
 ('00000000-0000-0000-0000-000000000006','replacement@example.test',now()),
 ('00000000-0000-0000-0000-000000000007','unconfirmed@example.test',null),
 ('00000000-0000-0000-0000-000000000008','new.employee@example.test',now()),
 ('00000000-0000-0000-0000-000000000009','outsider@example.test',now());
insert into public.profiles(user_id,full_name) select id,split_part(email,'@',1) from auth.users;
insert into public.platform_admins(user_id) values('00000000-0000-0000-0000-000000000001');
insert into public.organizations(id,name) values
 ('10000000-0000-0000-0000-000000000001','Store A'),('10000000-0000-0000-0000-000000000002','Store B');
insert into public.organization_memberships(id,organization_id,user_id,email,role) values
 ('20000000-0000-0000-0000-000000000001','10000000-0000-0000-0000-000000000001','00000000-0000-0000-0000-000000000002','manager.a@example.test','manager'),
 ('20000000-0000-0000-0000-000000000002','10000000-0000-0000-0000-000000000001','00000000-0000-0000-0000-000000000004','employee.a@example.test','employee'),
 ('20000000-0000-0000-0000-000000000003','10000000-0000-0000-0000-000000000002','00000000-0000-0000-0000-000000000003','manager.b@example.test','manager'),
 ('20000000-0000-0000-0000-000000000004','10000000-0000-0000-0000-000000000002','00000000-0000-0000-0000-000000000005','employee.b@example.test','employee');
insert into public.seats(id,organization_id,membership_id) values
 ('30000000-0000-0000-0000-000000000001','10000000-0000-0000-0000-000000000001','20000000-0000-0000-0000-000000000001'),
 ('30000000-0000-0000-0000-000000000002','10000000-0000-0000-0000-000000000001','20000000-0000-0000-0000-000000000002'),
 ('30000000-0000-0000-0000-000000000003','10000000-0000-0000-0000-000000000001',null),
 ('30000000-0000-0000-0000-000000000004','10000000-0000-0000-0000-000000000001',null),
 ('30000000-0000-0000-0000-000000000005','10000000-0000-0000-0000-000000000002','20000000-0000-0000-0000-000000000003'),
 ('30000000-0000-0000-0000-000000000006','10000000-0000-0000-0000-000000000002','20000000-0000-0000-0000-000000000004'),
 ('30000000-0000-0000-0000-000000000007','10000000-0000-0000-0000-000000000002',null);

set role authenticated;
set request.jwt.claim.sub='00000000-0000-0000-0000-000000000004';
select test.ok((select count(*) from public.organizations)=1,'employee sees own store only');
select test.ok((select count(*) from public.organization_memberships)=1,'employee cannot read coworker emails or memberships');
select test.ok((select count(*) from public.profiles)=2,'employee sees own team names only');
select test.ok((select count(*) from public.seats)=0,'employee cannot read seat administration');
select test.ok((select count(id) from public.invitations)=0,'employee cannot read invitations');
select test.rejects('select token_hash from public.invitations','permission denied','invitation token hashes are not exposed');
select test.rejects('update public.organization_memberships set role=''manager''','permission denied','employee cannot promote themselves');
select test.rejects('insert into public.platform_admins values(auth.uid(),now())','permission denied','employee cannot become administrator');
select test.rejects('select public.create_store(''Unauthorized'',10)','Administrator access required','employee cannot create a store');
select test.rejects('select public.create_invitation(''10000000-0000-0000-0000-000000000001'',''new@example.test'')','Manager access required','employee cannot invite');
select set_config('request.jwt.claims','{"user_metadata":{"role":"manager"}}',false);
select test.ok(not private.can_manage('10000000-0000-0000-0000-000000000001'),'user metadata cannot elevate a role');
select public.save_my_profile('Employee A',true);
select test.ok((select full_name='Employee A' and optional_email_notifications from public.profiles where user_id=auth.uid()),'employee can update their own name and email preferences');

set request.jwt.claim.sub='00000000-0000-0000-0000-000000000002';
select test.ok((select count(*) from public.organization_memberships)=2,'manager sees own team memberships');
select test.ok((select count(*) from public.seats)=4,'manager sees own seats only');
select test.rejects('select public.create_invitation(''10000000-0000-0000-0000-000000000002'',''new@example.test'')','Manager access required','manager cannot invite into another store');
select test.rejects('select public.deactivate_member(''20000000-0000-0000-0000-000000000004'')','Member not available','manager cannot deactivate another store employee');
select test.rejects('select public.create_invitation(''10000000-0000-0000-0000-000000000001'',''new@example.test'',''manager'')','Only an administrator','manager cannot create elevated roles');
insert into test.codes select 'replacement',invitation_code from public.create_invitation('10000000-0000-0000-0000-000000000001',' REPLACEMENT@example.test ');
select test.ok((select count(id) from public.invitations where email='replacement@example.test')=1,'invitation normalizes the email');
select test.rejects('select public.create_invitation(''10000000-0000-0000-0000-000000000001'',''replacement@example.test'')','Revoke the pending invitation','duplicate pending email rejected');
insert into test.codes select 'replacement-renewed',invitation_code from public.reissue_invitation((select id from public.invitations where email='replacement@example.test' and revoked_at is null));
select test.ok((select count(id) from public.invitations where email='replacement@example.test' and revoked_at is null)=1,'replacement code revokes previous reservation atomically');
insert into test.codes select 'unconfirmed',invitation_code from public.create_invitation('10000000-0000-0000-0000-000000000001','unconfirmed@example.test');
select test.rejects('select public.create_invitation(''10000000-0000-0000-0000-000000000001'',''extra@example.test'')','No available seats','reserved invitations consume available seats');

set request.jwt.claim.sub='00000000-0000-0000-0000-000000000003';
select test.ok((select count(id) from public.invitations)=0,'other store manager cannot see invitations');
set request.jwt.claim.sub='00000000-0000-0000-0000-000000000009';
select test.rejects('select public.accept_invitation((select code from test.codes where label=''replacement-renewed''))','does not match your verified email','wrong email cannot redeem a code');
set request.jwt.claim.sub='00000000-0000-0000-0000-000000000007';
select test.rejects('select public.accept_invitation((select code from test.codes where label=''unconfirmed''))','Confirm your email','unconfirmed account cannot redeem');
set request.jwt.claim.sub='00000000-0000-0000-0000-000000000006';
select test.rejects('select public.accept_invitation((select code from test.codes where label=''replacement''))','Invitation is invalid','previous code invalidated when reissued');
select public.accept_invitation((select code from test.codes where label='replacement-renewed'));
select test.ok((select count(*) from public.organization_memberships where user_id=auth.uid() and status='active')=1,'correct verified user joins store');
select test.rejects('select public.accept_invitation((select code from test.codes where label=''replacement-renewed''))','Invitation is invalid','code cannot be used twice');
select test.rejects('select public.accept_invitation(''made-up-code'')','Invitation is invalid','unknown codes rejected');

set request.jwt.claim.sub='00000000-0000-0000-0000-000000000002';
select public.deactivate_member('20000000-0000-0000-0000-000000000002');
select test.ok((select status from public.organization_memberships where id='20000000-0000-0000-0000-000000000002')='inactive','departing membership retained as inactive');
select test.ok((select membership_id from public.seats where id='30000000-0000-0000-0000-000000000002') is null,'departure frees its seat');
insert into test.codes select 'new-employee',invitation_code from public.create_invitation('10000000-0000-0000-0000-000000000001','new.employee@example.test');
select test.rejects('select public.deactivate_member(''20000000-0000-0000-0000-000000000001'')','Only an administrator','manager cannot remove a manager');
set request.jwt.claim.sub='00000000-0000-0000-0000-000000000004';
select test.ok((select count(*) from public.organizations)=0,'departed employee loses store access immediately');
select test.ok((select count(*) from public.profiles)=1,'departed employee cannot read team profiles');
set request.jwt.claim.sub='00000000-0000-0000-0000-000000000008';
select public.accept_invitation((select code from test.codes where label='new-employee'));
select test.ok((select count(*) from public.organization_memberships where user_id=auth.uid() and role='employee')=1,'replacement has independent membership');
reset role;
select test.ok((select m.user_id='00000000-0000-0000-0000-000000000008' from public.seats s join public.organization_memberships m on m.id=s.membership_id where s.id='30000000-0000-0000-0000-000000000002'),'freed seat reused without transferring old records');

set role authenticated;
set request.jwt.claim.sub='00000000-0000-0000-0000-000000000002';
select public.revoke_invitation((select id from public.invitations where email='unconfirmed@example.test'));
insert into test.codes select 'expired',invitation_code from public.create_invitation('10000000-0000-0000-0000-000000000001','outsider@example.test');
reset role;
update public.invitations set expires_at=now()-interval '1 second' where email='outsider@example.test';
set role authenticated;
set request.jwt.claim.sub='00000000-0000-0000-0000-000000000009';
select test.rejects('select public.accept_invitation((select code from test.codes where label=''expired''))','Invitation is invalid','expired code rejected');
set request.jwt.claim.sub='00000000-0000-0000-0000-000000000002';
insert into test.codes select 'renewed',invitation_code from public.create_invitation('10000000-0000-0000-0000-000000000001','outsider@example.test');
select test.ok((select count(id) from public.invitations where email='outsider@example.test' and revoked_at is null)=1,'expired reservation reclaimed for a new code');
set request.jwt.claim.sub='00000000-0000-0000-0000-000000000009';
select public.accept_invitation((select code from test.codes where label='renewed'));

set request.jwt.claim.sub='00000000-0000-0000-0000-000000000001';
select test.ok((select count(*) from public.organizations)=2,'administrator can oversee stores');
insert into test.codes select 'manager-b-invite',invitation_code from public.create_invitation('10000000-0000-0000-0000-000000000002','manager.a@example.test','manager');
select test.ok((select count(id) from public.invitations where role='manager')=1,'administrator can invite manager');
select test.rejects('select public.create_store(''Bad seat count'',0)','Choose 1 to 1000 seats','invalid store seat count rejected');
select public.create_store('Concurrency test store',1);
set request.jwt.claim.sub='00000000-0000-0000-0000-000000000002';
select test.rejects('select public.accept_invitation((select code from test.codes where label=''manager-b-invite''))','already belong to a store','person cannot join two active stores');
reset role;
select 'Passed '||count(*)||' account and isolation assertions.' from test.results;
