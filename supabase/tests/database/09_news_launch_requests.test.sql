-- Launches by request: anyone asks, the post goes up as a Show, an admin
-- approves (a launch) or declines (it stays a Show). Once each.
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

create function tests.new_user(p_email text, p_username text) returns uuid language plpgsql as $$
declare
  v_id uuid := gen_random_uuid();
begin
  insert into auth.users (
    instance_id, id, aud, role, email, encrypted_password, email_confirmed_at,
    raw_app_meta_data, raw_user_meta_data, created_at, updated_at,
    confirmation_token, recovery_token, email_change_token_new, email_change,
    email_change_token_current, phone_change, phone_change_token, reauthentication_token)
  values ('00000000-0000-0000-0000-000000000000', v_id, 'authenticated', 'authenticated', p_email, '', now(),
          '{"provider": "email", "providers": ["email"]}', '{"signup_app": "news"}', now(), now(),
          '', '', '', '', '', '', '', '');
  perform set_config('request.jwt.claims', jsonb_build_object('sub', v_id, 'role', 'authenticated')::text, true);
  -- News is by invitation (20261028130000_news_invites.sql): let the address in.
  insert into news_private.allowed_emails (email) values (lower(p_email)) on conflict do nothing;
  perform news.claim_profile(p_username);
  perform set_config('request.jwt.claims', '', true);
  return v_id;
end $$;

-- The newest story whose title, read without its prefix, is p_name.
create function tests.post(p_name text) returns bigint language sql stable as $$
  select id from news.items
  where type = 'story' and regexp_replace(title, '^\s*(show|launch)\s+en\s*:\s*', '', 'i') = p_name
  order by id desc limit 1
$$;
create function tests.title(p_name text) returns text language sql stable as $$
  select title from news.items where id = tests.post(p_name)
$$;

create temp table u as
select name, tests.new_user('l_' || name || '@news.test', 'l_' || name) as id
from unnest(array['alice', 'bob', 'admin']) name;
grant select on u to anon, authenticated;
update news.profiles set is_admin = true where username = 'l_admin';
create function tests.uid(p_name text) returns uuid language sql stable as $$
  select id from u where name = p_name
$$;

select plan(22);

-- ----------------------------------------------------------------------------
-- Asking from the new post form
-- ----------------------------------------------------------------------------

select tests.as_user(tests.uid('alice'));
select lives_ok($$select news.submit_story('https://alice.example', 'Show EN: Alice Co (payroll)', '', true, true)$$,
                'anyone asks for a launch');
select is(tests.title('Alice Co (payroll)'), 'Show EN: Alice Co (payroll)', 'it goes up as a Show');
select is((select approved from news.launch_requests where item_id = tests.post('Alice Co (payroll)')), null,
          'with a request waiting');
select throws_ok($$select news.submit_story('', 'Alice again', 'Words.', true, true)$$, '22023', 'retry',
                 'a request is for a Show');
select throws_ok($$select news.submit_story('', 'Show EN: ' || repeat('x', 70), 'Words.', true, true)$$, '22023', 'toolong',
                 'its title has to fit as a launch');

-- ----------------------------------------------------------------------------
-- Who sees it, who decides
-- ----------------------------------------------------------------------------

select is((select count(*) from news.launch_requests), 1::bigint, 'its author sees the request');
select tests.as_user(tests.uid('bob'));
select is((select count(*) from news.launch_requests), 0::bigint, 'nobody else does');
select throws_ok($$select news.decide_launch(tests.post('Alice Co (payroll)'), true)$$, '42501', null,
                 'only admins decide');
select throws_ok($$select news.request_launch(tests.post('Alice Co (payroll)'))$$, '22023', 'noitem',
                 'nobody asks for someone else''s post');
select tests.as_anon();
select throws_ok($$select count(*) from news.launch_requests$$, '42501', null, 'visitors see no requests');

-- ----------------------------------------------------------------------------
-- No way around it
-- ----------------------------------------------------------------------------

select tests.as_user(tests.uid('alice'));
select news.edit_item(tests.post('Alice Co (payroll)'), '{"title": "Launch EN: Alice Co (payroll)"}');
select is(tests.title('Alice Co (payroll)'), 'Show EN: Alice Co (payroll)', 'an author can''t edit a Show into a launch');

-- ----------------------------------------------------------------------------
-- Approving
-- ----------------------------------------------------------------------------

select tests.as_user(tests.uid('admin'));
select is((select count(*) from news.launch_requests where approved is null), 1::bigint, 'admins see what waits');
select lives_ok($$select news.decide_launch(tests.post('Alice Co (payroll)'), true)$$, 'an admin approves');
select is(tests.title('Alice Co (payroll)'), 'Launch EN: Alice Co (payroll)', 'and the Show is a launch');
select throws_ok($$select news.decide_launch(tests.post('Alice Co (payroll)'), false)$$, '22023', 'noitem',
                 'an approved launch stays decided');

select tests.as_user(tests.uid('alice'));
select news.edit_item(tests.post('Alice Co (payroll)'), '{"title": "Alice Co (payroll)"}');
select is(tests.title('Alice Co (payroll)'), 'Launch EN: Alice Co (payroll)', 'nor edit a launch back');
select throws_ok($$select news.submit_story('', 'Show EN: Alice Two', 'Words.', true, true)$$, '22023', 'launched',
                 'once each, from the form');
select news.submit_story('', 'Show EN: Alice Three', 'Words.');
select throws_ok($$select news.request_launch(tests.post('Alice Three'))$$, '22023', 'launched',
                 'once each, from a Show');

-- ----------------------------------------------------------------------------
-- Asking from a Show, declining, and changing one's mind
-- ----------------------------------------------------------------------------

select tests.as_user(tests.uid('bob'));
select news.submit_story('', 'A link of Bob''s', 'Words.');
select throws_ok($$select news.request_launch(tests.post('A link of Bob''s'))$$, '22023', 'noitem',
                 'only a Show is asked for');
select news.submit_story('https://bob.example', 'Show EN: Bob Co', '');
select news.request_launch(tests.post('Bob Co'));

select tests.as_user(tests.uid('admin'));
select news.decide_launch(tests.post('Bob Co'), false);
select is(tests.title('Bob Co'), 'Show EN: Bob Co', 'a declined request stays a Show');

select tests.as_user(tests.uid('bob'));
select news.request_launch(tests.post('Bob Co'));
select is((select approved from news.launch_requests where item_id = tests.post('Bob Co')), false,
          'asking again doesn''t reopen it');

select tests.as_user(tests.uid('admin'));
select news.decide_launch(tests.post('Bob Co'), true);
select is(tests.title('Bob Co'), 'Launch EN: Bob Co', 'an admin can still approve it later');

select tests.as_postgres();
select * from finish();
rollback;
