-- The production fixes of 20261008100000..100300: community profiles keep no
-- emails and no self-assigned roles, no SECURITY DEFINER function in the
-- exposed schema is callable by anon, the community tables' policies still
-- work, and no cron job carries a secret.
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

-- Run one statement as another database role and report the SQLSTATE it
-- failed with, or 'ok'.
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

select plan(20);

-- --------------------------------------------------------------------------
-- public.profiles
-- --------------------------------------------------------------------------

create temp table t as
select tests.new_user('t_member@example.com', p_meta => '{"user_name": "member"}') as member,
       tests.new_user('t_mod@example.com', p_meta => '{"user_name": "mod"}') as mod,
       tests.new_user('t_outsider@example.com', p_meta => '{"user_name": "outsider"}') as outsider;
grant select on t to anon, authenticated;

select is_empty($$select 1 from public.profiles where email <> ''$$, 'no community profile keeps an email');

select tests.as_user((select member from t));
update public.profiles set role = 'fellow', email = 'me@example.com', bio = 'hi' where id = (select member from t);
select tests.as_postgres();
select results_eq($$select role, email, bio from public.profiles where id = (select member from t)$$,
                  $$values ('user'::text, ''::text, 'hi'::text)$$,
                  'a user can edit their profile but not give themselves a role or store an email');

select tests.as_user((select member from t));
select is(tests.sqlstate_as('authenticated',
  $$insert into public.fellows (id, cohort, status) values ((select member from t), 'x', 'active')$$),
  '42501', 'so they cannot publish themselves as a fellow');
select tests.as_postgres();

delete from public.profiles where id = (select outsider from t);
select tests.as_user((select outsider from t));
insert into public.profiles (id, email, role) values ((select outsider from t), 'x@example.com', 'admin');
select tests.as_postgres();
select results_eq($$select role, email from public.profiles where id = (select outsider from t)$$,
                  $$values ('user'::text, ''::text)$$,
                  'creating your own profile as admin gives you a plain user profile');

update public.profiles set role = 'fellow' where id = (select member from t);
select is((select role from public.profiles where id = (select member from t)), 'fellow',
          'roles still change from a direct database session');

-- --------------------------------------------------------------------------
-- SECURITY DEFINER functions
-- --------------------------------------------------------------------------

select is_empty($$
  select p.oid::regprocedure from pg_proc p join pg_namespace n on n.oid = p.pronamespace
  where n.nspname in ('public', 'graphql_public', 'news') and p.prosecdef
    and has_function_privilege('anon', p.oid, 'EXECUTE')
    and p.oid::regprocedure::text not in ('news.is_admin()', 'news.leaders(integer)',
      'news.username_available(text)', 'news.profile_private(uuid)', 'news.points_curve(bigint)',
      'news.sees_gated()', 'news.gated_item(bigint)', 'news.username_now(text)',
      'news.invite_from(text)', 'news.invite_leaders(integer)')
$$, 'anon can call no SECURITY DEFINER function in an exposed schema (but News'' own read helpers)');

select ok(not has_schema_privilege('anon', 'community_private', 'USAGE')
          and not has_schema_privilege('authenticated', 'community_private', 'USAGE'),
          'community_private is closed to the API roles');
select is((select count(*)::int from pg_proc p join pg_namespace n on n.oid = p.pronamespace
           where n.nspname = 'public' and p.proname in ('get_community_type', 'is_community_admin',
             'is_community_member', 'is_community_moderator', 'is_user_banned', 'user_has_role', 'get_user_roles')),
          0, 'the community helpers are gone from public (no /rest/v1/rpc/ for them)');
select ok(not has_function_privilege('anon', 'community_private.is_user_banned(uuid, uuid)', 'EXECUTE')
          and not has_function_privilege('authenticated', 'community_private.get_user_roles(uuid)', 'EXECUTE'),
          'helpers no policy uses are executable by nobody but the service role');
select ok(not has_function_privilege('anon', 'public.update_post_comment_count()', 'EXECUTE')
          and not has_function_privilege('authenticated', 'public.record_bucket_transition()', 'EXECUTE'),
          'trigger functions are not executable by the API roles');

-- The community tables' policies call the moved helpers; they must still work.
insert into public.communities (id, name, display_name, type) values
  ('a0000000-0000-4000-a000-000000000001', 't_open', 'Open', 'public'),
  ('a0000000-0000-4000-a000-000000000002', 't_closed', 'Closed', 'private');
insert into public.community_memberships (user_id, community_id, role) values
  ((select member from t), 'a0000000-0000-4000-a000-000000000002', 'member'),
  ((select mod from t), 'a0000000-0000-4000-a000-000000000001', 'moderator');
insert into public.posts (author_id, title, community_id, is_removed) values
  ((select member from t), 't_visible', 'a0000000-0000-4000-a000-000000000001', false),
  ((select member from t), 't_removed', 'a0000000-0000-4000-a000-000000000001', true);

select tests.as_anon();
select is((select count(*)::int from public.communities where name like 't\_%'), 1,
          'anon sees the public community, not the private one');
select is((select count(*)::int from public.posts where title like 't\_%'), 1, 'anon sees live posts only');
select is((select count(*)::int from public.community_memberships
           where community_id = 'a0000000-0000-4000-a000-000000000001'), 1,
          'anon sees memberships of a public community');
select tests.as_user((select member from t));
select is((select count(*)::int from public.communities where name like 't\_%'), 2,
          'a member sees their private community');
select tests.as_user((select mod from t));
select is((select count(*)::int from public.posts where title like 't\_%'), 2,
          'a moderator sees removed posts in their community');
select tests.as_user((select outsider from t));
select is((select count(*)::int from public.posts where title like 't\_%'), 1,
          'anyone else sees live posts only');
select tests.as_postgres();

-- --------------------------------------------------------------------------
-- Cron jobs
-- --------------------------------------------------------------------------

select is_empty($$select jobname from cron.job where command ~* 'secret|bearer|apikey|eyJ'$$,
                'no cron job carries a secret');
select is((select command from cron.job where jobname = 'scrape-events'),
          'select public.trigger_scrape_events()', 'scrape-events reads its url and secret from Vault');
select ok(not has_function_privilege('anon', 'public.trigger_scrape_events()', 'EXECUTE')
          and not has_function_privilege('authenticated', 'public.trigger_scrape_events()', 'EXECUTE'),
          'and only the scheduler can start it');

create temp table q as select count(*) as n from net.http_request_queue;
select public.trigger_scrape_events();
select is((select count(*) from net.http_request_queue), (select n from q),
          'without the Vault secrets it calls nothing (so local never calls production)');

select * from finish();
rollback;
