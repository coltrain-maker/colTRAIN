insert into storage.objects(bucket_id,name) values
 ('team-media','10000000-0000-0000-0000-000000000001/00000000-0000-0000-0000-000000000002/manager-photo.png'),
 ('team-media','10000000-0000-0000-0000-000000000001/00000000-0000-0000-0000-000000000008/employee-photo.png'),
 ('team-media','10000000-0000-0000-0000-000000000002/00000000-0000-0000-0000-000000000005/other-store.png');
set role authenticated;
set request.jwt.claim.sub='00000000-0000-0000-0000-000000000008';
select test.ok((select count(*) from storage.objects)=2,'employee reads team pictures only in own store');
select test.rejects('insert into storage.objects(bucket_id,name) values(''team-media'',''10000000-0000-0000-0000-000000000002/00000000-0000-0000-0000-000000000008/cross-store.png'')','row-level security','employee cannot upload into another store');
select test.rejects('insert into storage.objects(bucket_id,name) values(''team-media'',''10000000-0000-0000-0000-000000000001/00000000-0000-0000-0000-000000000002/impersonated.png'')','row-level security','employee cannot upload under another person');
select public.register_team_corner_media('10000000-0000-0000-0000-000000000001','80000000-0000-0000-0000-000000000008','image/png');
insert into storage.objects(bucket_id,name) values('team-media','10000000-0000-0000-0000-000000000001/00000000-0000-0000-0000-000000000008/80000000-0000-0000-0000-000000000008.png');
select test.ok((select count(*) from storage.objects)=3,'employee can upload to their own store folder');
with removed as(delete from storage.objects where name like '%manager-photo.png' returning id) select test.ok((select count(*) from removed)=0,'employee cannot delete manager picture');
with removed as(delete from storage.objects where name like '%80000000-0000-0000-0000-000000000008.png' returning id) select test.ok((select count(*) from removed)=1,'employee can remove own picture');
set request.jwt.claim.sub='00000000-0000-0000-0000-000000000002';
with removed as(delete from storage.objects where name like '%employee-photo.png' returning id) select test.ok((select count(*) from removed)=1,'manager can moderate own store picture');
with removed as(delete from storage.objects where name like '%other-store.png' returning id) select test.ok((select count(*) from removed)=0,'manager cannot delete another store picture');
set request.jwt.claim.sub='00000000-0000-0000-0000-000000000001';
select test.ok((select count(*) from storage.objects)=0,'administrator has no automatic team-feed picture access');
set request.jwt.claim.sub='00000000-0000-0000-0000-000000000004';
select test.ok((select count(*) from storage.objects)=0,'departed employee loses picture access');
reset role;
select 'Passed '||count(*)||' total account, media, and isolation assertions.' from test.results;
