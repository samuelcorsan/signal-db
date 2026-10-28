-- Exponential's staff (Signal's public.staff) are staff on News: admins, with
-- a mark they can wear. Signal's list stays the one source, and news_owner
-- still can't read it.
begin;
create extension if not exists pgtap with schema extensions;

create schema tests;
grant usage on schema tests to anon, authenticated;

create function tests.as_user(p_id uuid) returns void language plpgsql as $$
begin
  perform set_config('request.jwt.claims', jsonb_build_object('sub', p_id, 'role', 'authenticated')::text, true);
  perform set_config('role', 'authenticated', true);
end $$;

create function tests.as_anon() returns void language plpgsql as $$
begin
  perform set_config('request.jwt.claims', '{"role": "anon"}', true);
  perform set_config('role', 'anon', true);
end $$;

create function tests.as_postgres() returns void language plpgsql as $$
begin
  perform set_config('role', 'none', true);
  perform set_config('request.jwt.claims', '', true);
end $$;

create function tests.new_user(p_email text) returns uuid language plpgsql as $$
declare
  v_id uuid := gen_random_uuid();
begin
  insert into auth.users (
    instance_id, id, aud, role, email, encrypted_password, email_confirmed_at,
    raw_app_meta_data, raw_user_meta_data, created_at, updated_at,
    confirmation_token, recovery_token, email_change_token_new, email_change,
    email_change_token_current, phone_change, phone_change_token, reauthentication_token)
  values ('00000000-0000-0000-0000-000000000000', v_id, 'authenticated', 'authenticated', p_email, '', now(),
          '{"provider": "github", "providers": ["github"]}', '{"signup_app": "news"}', now(), now(),
          '', '', '', '', '', '', '', '');
  return v_id;
end $$;

create temp table u as
select 'staffer' as name, tests.new_user('t_staffer@exponential.test') as id
union all select 'reader', tests.new_user('t_reader@news.test')
union all select 'handmade', tests.new_user('t_handmade@news.test');
grant select on u to anon, authenticated;
insert into public.staff (user_id, email) select id, 't_staffer@exponential.test' from u where name = 'staffer';
-- Staff need no invitation; everyone else here is let in by address.
insert into news_private.allowed_emails (email) values ('t_reader@news.test'), ('t_handmade@news.test');
create function tests.uid(p_name text) returns uuid language sql stable as $$
  select id from u where name = p_name
$$;
create function tests.profile(p_name text) returns news.profiles language sql stable as $$
  select * from news.profiles where id = tests.uid(p_name)
$$;

select plan(12);

select ok(not has_table_privilege('news_owner', 'public.staff', 'SELECT'), 'news_owner still can''t read public.staff');
select ok(not has_function_privilege('authenticated', 'news_private.signal_staff()', 'EXECUTE')
          and not has_function_privilege('anon', 'news_private.signal_staff()', 'EXECUTE'),
          'only news_owner can ask who is staff');

select tests.as_user(tests.uid('staffer'));
select news.claim_profile('t_staffer');
select tests.as_postgres();
select is((tests.profile('staffer')).staff, true, 'a staff member who joins News is staff there at once');
select is((tests.profile('staffer')).is_admin, true, 'and an admin');
select tests.as_user(tests.uid('staffer'));
select is(news.is_admin(), true, 'News treats their session as an admin''s');
select is((select staff from news.profile_private()), true, 'and their profile says so');

select tests.as_user(tests.uid('reader'));
select news.claim_profile('t_reader');
select tests.as_user(tests.uid('handmade'));
select news.claim_profile('t_handmade');
select tests.as_postgres();
select is((tests.profile('reader')).staff, false, 'anyone else is not staff');
update news.profiles set is_admin = true where id = tests.uid('handmade');

delete from public.staff where user_id = tests.uid('staffer');
select is(news_private.apply_staff(), 1, 'leaving the staff list changes one profile');
select is((tests.profile('staffer')).staff, false, 'it is no longer staff');
select is((tests.profile('staffer')).is_admin, false, 'nor an admin');
select is((tests.profile('handmade')).is_admin, true, 'an admin made by hand is left alone');

select tests.as_anon();
select lives_ok($$select staff from news.profiles limit 1$$, 'anyone can see who is staff');

select tests.as_postgres();
select * from finish();
rollback;
