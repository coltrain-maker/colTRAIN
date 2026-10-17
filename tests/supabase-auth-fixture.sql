-- Minimal Supabase Auth interfaces for disposable PostgreSQL tests only.
create role anon nologin;
create role authenticated nologin;
create schema auth;
create table auth.users(id uuid primary key,email text not null unique,email_confirmed_at timestamptz);
create function auth.uid() returns uuid language sql stable as $$
 select nullif(current_setting('request.jwt.claim.sub',true),'')::uuid;
$$;
grant usage on schema public,auth to anon,authenticated;
grant execute on function auth.uid() to anon,authenticated;
create schema test;
grant usage on schema test to authenticated,anon;
create table test.results(name text);
create table test.codes(label text primary key,code text);
grant select,insert on test.results,test.codes to authenticated;
create function test.ok(condition boolean,label text) returns void language plpgsql as $$
begin
 if condition is distinct from true then raise exception 'FAILED: %',label; end if;
 insert into test.results values(label);
end;
$$;
create function test.rejects(command text,expected text,label text) returns void language plpgsql as $$
declare rejected boolean:=false;
begin
 begin execute command;
 exception when others then
   if position(expected in sqlerrm)=0 then raise exception 'FAILED: %; unexpected error: %',label,sqlerrm; end if;
   rejected:=true;
 end;
 perform test.ok(rejected,label);
end;
$$;
grant execute on all functions in schema test to authenticated;
create schema storage;
grant usage on schema storage to authenticated;
create table storage.buckets(id text primary key,name text,public boolean,file_size_limit bigint,allowed_mime_types text[]);
create table storage.objects(id uuid primary key default gen_random_uuid(),bucket_id text references storage.buckets(id),name text not null);
alter table storage.objects enable row level security;
grant select,insert,update,delete on storage.objects to authenticated;
