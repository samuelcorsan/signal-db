-- Reports a moderator reviews: any member reports, moderators remove or
-- keep, and only established members' reports remove anything on their own.
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

create function tests.item(p_title text) returns bigint language sql stable as $$
  select id from news.items where title = p_title order by id desc limit 1
$$;

-- An author, a new member, a moderator, an admin, and eight of each: new
-- members and members with more than 30 points.
create temp table u as
select name, tests.new_user('r_' || name || '@news.test', 'r_' || name) as id
from unnest(array['alice', 'bob', 'mod', 'admin',
                  'n1', 'n2', 'n3', 'n4', 'n5', 'n6', 'n7', 'n8',
                  'o1', 'o2', 'o3', 'o4', 'o5', 'o6', 'o7', 'o8']) name;
grant select on u to anon, authenticated;
update news.profiles set auth = 1 where username = 'r_mod';
update news.profiles set is_admin = true where username = 'r_admin';
update news.profiles set karma = 31 where username like 'r_o_';
create function tests.uid(p_name text) returns uuid language sql stable as $$
  select id from u where name = p_name
$$;
create function tests.report_as(p_names text[], p_item bigint) returns void language plpgsql as $$
declare
  n text;
begin
  foreach n in array p_names loop
    perform tests.as_user(tests.uid(n));
    perform news.toggle_flag(p_item);
  end loop;
  perform tests.as_postgres();
end $$;

select tests.as_user(tests.uid('alice'));
select news.submit_story('', 'Noisy post', 'Buy now.');
select news.submit_story('', 'Crowded post', 'Words.');
select news.submit_story('', 'Established post', 'Words.');
select news.submit_story('', 'Protected post', 'Words.');
select tests.as_postgres();
update news.items set keys = array['nokill'] where id = tests.item('Protected post');

select plan(17);

-- ----------------------------------------------------------------------------
-- Reporting
-- ----------------------------------------------------------------------------

select tests.as_user(tests.uid('bob'));
select is(news.toggle_flag(tests.item('Noisy post')), true, 'a new member reports');
select tests.as_user(tests.uid('alice'));
select is(news.toggle_flag(tests.item('Noisy post')), false, 'nobody reports their own');
select tests.as_user(tests.uid('bob'));
select throws_ok($$select * from news.reported_items()$$, '42501', null, 'members don''t see the queue');
select throws_ok($$select * from news.flag_reviews$$, '42501', null, 'nor the reviews');
select tests.as_anon();
select throws_ok($$select * from news.reported_items()$$, '42501', null, 'nor do visitors');

-- ----------------------------------------------------------------------------
-- The queue, and keeping
-- ----------------------------------------------------------------------------

select tests.as_user(tests.uid('mod'));
select is((select reports from news.reported_items() where item_id = tests.item('Noisy post')), 1::bigint,
          'a moderator sees it waiting, with its count');
select is(news.reported_count(), 1::bigint, 'and how many wait');
select news.review_reports(tests.item('Noisy post'), false);
select is((select count(*) from news.reported_items() where item_id = tests.item('Noisy post')), 0::bigint,
          'kept, it leaves the queue');
select is((select dead from news.items where id = tests.item('Noisy post')), false, 'and stays up');

-- A test is one transaction, where now() stands still: put the keep a minute back.
select tests.as_postgres();
update news.flag_reviews set reviewed_at = now() - interval '1 minute' where item_id = tests.item('Noisy post');
select tests.as_user(tests.uid('bob'));
select news.toggle_flag(tests.item('Noisy post'));  -- takes the report back
select news.toggle_flag(tests.item('Noisy post'));  -- and makes it again
select tests.as_user(tests.uid('mod'));
select is((select reports from news.reported_items() where item_id = tests.item('Noisy post')), 1::bigint,
          'a report after it was kept brings it back');

-- ----------------------------------------------------------------------------
-- Removing
-- ----------------------------------------------------------------------------

select news.review_reports(tests.item('Noisy post'), true);
select is((select dead from news.items where id = tests.item('Noisy post')), true, 'a moderator removes it');
select is((select count(*) from news.reported_items() where item_id = tests.item('Noisy post')), 0::bigint,
          'and it leaves the queue');

select tests.report_as(array['bob'], tests.item('Protected post'));
select tests.as_user(tests.uid('mod'));
select throws_ok($$select news.review_reports(tests.item('Protected post'), true)$$, '22023', 'nokill',
                 'what an admin kept up, a moderator can''t remove');
select tests.as_user(tests.uid('admin'));
select lives_ok($$select news.review_reports(tests.item('Protected post'), true)$$, 'an admin can');

-- ----------------------------------------------------------------------------
-- Removal by numbers: established members' reports only
-- ----------------------------------------------------------------------------

select tests.report_as(array['n1', 'n2', 'n3', 'n4', 'n5', 'n6', 'n7', 'n8'], tests.item('Crowded post'));
select is((select dead from news.items where id = tests.item('Crowded post')), false,
          'eight new members can''t take a post down');
select tests.as_user(tests.uid('mod'));
select is((select reports from news.reported_items() where item_id = tests.item('Crowded post')), 8::bigint,
          'they put it in front of a moderator');
select tests.report_as(array['o1', 'o2', 'o3', 'o4', 'o5', 'o6', 'o7', 'o8'], tests.item('Established post'));
select is((select dead from news.items where id = tests.item('Established post')), true,
          'eight established members still can, as before');

select tests.as_postgres();
select * from finish();
rollback;
