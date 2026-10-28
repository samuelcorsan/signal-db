-- Signals handle_new_user leaves News sign-ups out of public.profiles.
begin;
create extension if not exists pgtap with schema extensions;

-- Test helpers, rolled back with the rest of the file.
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

-- Back to postgres with no JWT (a direct database session).
create function tests.as_postgres() returns void language plpgsql as $$
begin
  perform set_config('role', 'none', true);
  perform set_config('request.jwt.claims', '', true);
end $$;

-- An auth user, optionally with a News profile claimed under p_username.
create function tests.new_user(p_email text, p_username text default null,
                               p_confirmed boolean default true,
                               p_meta jsonb default '{"signup_app": "news"}')
returns uuid language plpgsql as $$
declare
  v_id uuid := gen_random_uuid();
begin
  insert into auth.users (
    instance_id, id, aud, role, email, encrypted_password, email_confirmed_at,
    raw_app_meta_data, raw_user_meta_data, created_at, updated_at,
    confirmation_token, recovery_token, email_change_token_new, email_change,
    email_change_token_current, phone_change, phone_change_token, reauthentication_token)
  values ('00000000-0000-0000-0000-000000000000', v_id, 'authenticated', 'authenticated', p_email, '',
          case when p_confirmed then now() end,
          '{"provider": "email", "providers": ["email"]}', p_meta, now(), now(),
          '', '', '', '', '', '', '', '');
  if p_username is not null then
    perform set_config('request.jwt.claims', jsonb_build_object('sub', v_id, 'role', 'authenticated')::text, true);
    -- News is by invitation (20261028130000_news_invites.sql): let the address in.
    insert into news_private.allowed_emails (email) values (lower(p_email)) on conflict do nothing;
    perform news.claim_profile(p_username);
    perform set_config('request.jwt.claims', '', true);
  end if;
  return v_id;
end $$;

create function tests.item(p_title text) returns bigint language sql stable as $$
  select id from news.items where title = p_title order by id desc limit 1
$$;

-- Run one statement as another database role (one without access to pgTAP)
-- and report back to postgres: a count, or the SQLSTATE it failed with.
create function tests.count_as(p_role text, p_sql text) returns bigint language plpgsql as $$
declare
  n bigint;
begin
  execute format('set local role %I', p_role);
  execute p_sql into n;
  execute 'reset role';
  return n;
end $$;

create function tests.sqlstate_as(p_role text, p_sql text) returns text language plpgsql as $$
begin
  begin
    execute format('set local role %I', p_role);
    execute p_sql;
    execute 'reset role';
    return 'ok';
  exception when others then
    return sqlstate;
  end;
end $$;

select plan(4);

-- public.profiles (the old community site) is readable by anyone. News
-- sign-ups must not land there, and no one's email may.

create temp table signups as
select tests.new_user('t_news_signup@news.test') as news_user,
       tests.new_user('t_other_signup@example.com', p_meta => '{"user_name": "someone"}') as other_user;

select is_empty($$select 1 from public.profiles where id = (select news_user from signups)$$,
                'a News sign-up gets no community profile');
select is((select email from public.profiles where id = (select other_user from signups)),
          '', 'any other sign-up still gets one, without its email');

select ok(not has_function_privilege('anon', 'public.handle_new_user()', 'EXECUTE')
          and not has_function_privilege('authenticated', 'public.handle_new_user()', 'EXECUTE'),
          'the trigger function cannot be called over the API');

select tests.as_anon();
select is_empty($$select 1 from public.profiles where email = 't_news_signup@news.test'$$,
                'the News user''s email is not in the public profiles');
select tests.as_postgres();

select * from finish();
rollback;
