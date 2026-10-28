-- Row level security on the news schema.
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

select plan(27);

-- ids from supabase/seeds/20_news_demo.sql
-- admin 20000000-0000-4000-a000-000000000001, alice ...02, bob ...03, grace ...04

-- ----------------------------------------------------------------------------
-- Anyone can read items and the public half of profiles.
-- ----------------------------------------------------------------------------

select tests.as_anon();
select ok((select count(*) from news.items) >= 6, 'anon reads items');
select ok(array['admin', 'alice', 'bob', 'grace'] <@ array(select username from news.profiles),
          'anon reads usernames');
select results_eq($$select badge from news.profiles where username = 'grace'$$,
                  array['launchpad'], 'anon reads badges');
select throws_ok('select is_admin from news.profiles', '42501', null, 'anon cannot read is_admin');
select throws_ok('select ignored from news.profiles', '42501', null, 'anon cannot read ignored');
select throws_ok('select showdead from news.profiles', '42501', null, 'anon cannot read settings');
select throws_ok('select * from news.profiles', '42501', null, 'anon cannot select * from profiles');
select throws_ok('select * from news.votes', '42501', null, 'anon cannot read votes at all');

-- ----------------------------------------------------------------------------
-- Votes and flags are private.
-- ----------------------------------------------------------------------------

select tests.as_postgres();
create temp table base as
select count(*) as alice_votes from news.votes where user_id = '20000000-0000-4000-a000-000000000002';
grant select on base to anon, authenticated;
-- Fresh stories for flags and hides, so earlier clicks in the app don't matter.
do $$
begin
  perform set_config('request.jwt.claims',
    '{"sub": "20000000-0000-4000-a000-000000000003", "role": "authenticated"}', true);
  perform news.submit_story('', 'Flag target', 'x');
  perform news.submit_story('', 'Hide target', 'x');
  perform set_config('request.jwt.claims', '', true);
end $$;

select tests.as_user('20000000-0000-4000-a000-000000000003');   -- bob
select is((select count(*) from news.votes where user_id = '20000000-0000-4000-a000-000000000002'),
          0::bigint, 'bob cannot see alice''s votes');
select tests.as_user('20000000-0000-4000-a000-000000000002');   -- alice
select is((select count(*) from news.votes where user_id = '20000000-0000-4000-a000-000000000002'),
          (select alice_votes from base), 'alice sees all her own votes');
select tests.as_user('20000000-0000-4000-a000-000000000001');   -- admin
select is((select count(*) from news.votes where user_id = '20000000-0000-4000-a000-000000000002'),
          (select alice_votes from base), 'an admin sees alice''s votes');

select tests.as_postgres();
update news.profiles set karma = 50 where username = 'alice';
select tests.as_user('20000000-0000-4000-a000-000000000002');
select ok(news.toggle_flag(tests.item('Flag target')), 'alice flags a story');
select is((select count(*) from news.flags where item_id = tests.item('Flag target')), 1::bigint, 'alice sees her flag');
select tests.as_user('20000000-0000-4000-a000-000000000003');
select is((select count(*) from news.flags where item_id = tests.item('Flag target')), 0::bigint, 'bob cannot see alice''s flag');

-- ----------------------------------------------------------------------------
-- Hides: your own, stories only.
-- ----------------------------------------------------------------------------

select tests.as_user('20000000-0000-4000-a000-000000000002');
select lives_ok($$insert into news.hides (user_id, item_id)
                  values ('20000000-0000-4000-a000-000000000002', tests.item('Hide target'))$$,
                'alice hides a story');
select throws_ok($$insert into news.hides (user_id, item_id)
                   values ('20000000-0000-4000-a000-000000000003', tests.item('Hide target'))$$,
                 '42501', null, 'alice cannot hide a story for bob');
select throws_ok($$insert into news.hides (user_id, item_id)
                   select '20000000-0000-4000-a000-000000000002', id from news.items
                   where type = 'comment' limit 1$$,
                 '42501', null, 'comments cannot be hidden');
select tests.as_user('20000000-0000-4000-a000-000000000003');
delete from news.hides where user_id = '20000000-0000-4000-a000-000000000002';
select tests.as_user('20000000-0000-4000-a000-000000000002');
select is((select count(*) from news.hides where item_id = tests.item('Hide target')), 1::bigint,
          'bob could not delete alice''s hide');

-- ----------------------------------------------------------------------------
-- A comment held back by its author's delay is theirs alone until it shows.
-- ----------------------------------------------------------------------------

select tests.as_postgres();
update news.profiles set delay = 5 where username = 'bob';
select tests.as_user('20000000-0000-4000-a000-000000000003');
select ok(news.post_comment(tests.item('Row Level Security in Supabase'), 'Held back five minutes.') > 0,
          'bob posts a delayed comment');
select is((select count(*) from news.items where text = 'Held back five minutes.'), 1::bigint,
          'bob sees his delayed comment');
select tests.as_user('20000000-0000-4000-a000-000000000002');
select is((select count(*) from news.items where text = 'Held back five minutes.'), 0::bigint,
          'alice does not see it yet');
select tests.as_anon();
select is((select count(*) from news.items where text = 'Held back five minutes.'), 0::bigint,
          'anon does not see it yet');

-- ----------------------------------------------------------------------------
-- No direct writes: everything goes through the RPCs.
-- ----------------------------------------------------------------------------

select tests.as_user('20000000-0000-4000-a000-000000000002');
select throws_ok($$insert into news.items (type, "by", by_name, title, url)
                   values ('story', '20000000-0000-4000-a000-000000000002', 'alice', 'Direct', 'https://example.com/x')$$,
                 '42501', null, 'no direct insert into items');
select throws_ok($$update news.items set score = 1000$$, '42501', null, 'no direct update of items');
select throws_ok($$update news.profiles set karma = 1000 where username = 'alice'$$, '42501', null,
                 'no direct update of profiles (karma)');
select throws_ok($$update news.profiles set badge = 'fellowship' where username = 'alice'$$, '42501', null,
                 'no direct update of profiles (badge)');
select throws_ok($$delete from news.votes$$, '42501', null, 'no direct delete of votes');

select tests.as_postgres();
select * from finish();
rollback;
