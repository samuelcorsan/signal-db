-- What HN regulars reach for: read markers, favorites, nominations and
-- highlights, the second-chance pool, settings, hats and Launch EN.
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

create temp table u as
select name, tests.new_user('d_' || name || '@news.test', 'd_' || name) as id
from unnest(array['alice', 'bob', 'admin', 'fel']) name;
grant select on u to anon, authenticated;
update news.profiles set is_admin = true where username = 'd_admin';
update news.profiles set badge = 'fellowship' where username = 'd_fel';
create function tests.uid(p_name text) returns uuid language sql stable as $$
  select id from u where name = p_name
$$;

-- Where a story sits among the top stories (1 = first).
create function tests.rank_of(p_id bigint) returns bigint language sql stable as $$
  select n from news.top_story_ids(1000) with ordinality as t(id, n) where t.id = p_id
$$;

select plan(26);

-- ----------------------------------------------------------------------------
-- Read markers
-- ----------------------------------------------------------------------------

select tests.as_user(tests.uid('alice'));
select news.submit_story('', 'Delight story', 'Words.');
select is(news.mark_read(tests.item('Delight story')), null, 'the first read has no earlier one');
select isnt(news.mark_read(tests.item('Delight story')), null, 'the next read says when the last was');
select tests.as_postgres();
update news.reads set seen_at = now() - interval '1 hour';

select tests.as_user(tests.uid('bob'));
select news.post_comment(tests.item('Delight story'), 'From Bob.');
select is(news.mark_read(tests.item('Delight story')), null, 'every reader has their own markers');
select tests.as_user(tests.uid('alice'));
select news.post_comment(tests.item('Delight story'), 'From Alice.');
select is((select n from news.unread_counts(array[tests.item('Delight story')])), 1::bigint,
          'unread counts what others wrote since the last read');
select tests.as_user(tests.uid('bob'));
select is((select count(*) from news.reads where user_id = tests.uid('alice')), 0::bigint,
          'nobody sees anyone else''s read markers');
select tests.as_anon();
select throws_ok($$select news.mark_read(1)$$, '42501', null, 'anon can''t mark anything read');

-- ----------------------------------------------------------------------------
-- Favorites, nominations, highlights
-- ----------------------------------------------------------------------------

select tests.as_user(tests.uid('bob'));
select is(news.toggle_favorite(tests.item('Delight story')), true, 'a favorite is kept');
select is((select score from news.items where id = tests.item('Delight story')), 1,
          'without upvoting');
select tests.as_anon();
select is((select count(*) from news.favorites where user_id = tests.uid('bob')), 1::bigint,
          'favorites are public, as on HN');
select tests.as_user(tests.uid('bob'));
select is(news.toggle_favorite(tests.item('Delight story')), false, 'and a second toggle lets it go');

create temp table c as select id from news.items where text = 'From Alice.';
grant select on c to anon, authenticated;
select throws_ok($$select news.toggle_nomination((select id from news.items where text = 'From Bob.'))$$, '22023', 'noitem',
                 'nobody nominates their own comment');
select is(news.toggle_nomination((select id from c)), true, 'readers nominate others'' comments');
select tests.as_user(tests.uid('alice'));
select is((select count(*) from news.nominations), 0::bigint, 'a nomination is private');
select throws_ok($$select news.set_highlight((select id from c), true)$$, '42501', null,
                 'only admins highlight');
select tests.as_user(tests.uid('admin'));
select is((select count(*) from news.nominations where item_id = (select id from c)), 1::bigint,
          'admins see nominations');
select lives_ok($$select news.set_highlight((select id from c), true)$$, 'admins highlight');
select tests.as_anon();
select is((select count(*) from news.highlights where item_id = (select id from c)), 1::bigint,
          'highlights are public');

-- ----------------------------------------------------------------------------
-- The second-chance pool
-- ----------------------------------------------------------------------------

select tests.as_user(tests.uid('bob'));
select news.submit_story('https://example.com/overlooked', 'Overlooked', '');
select news.submit_story('https://example.com/fresh', 'Fresh', '');
select tests.as_postgres();
update news.items set created_at = now() - interval '3 days', score = 5 where id = tests.item('Overlooked');
update news.items set score = 3 where id = tests.item('Fresh');
select ok(tests.rank_of(tests.item('Fresh')) < tests.rank_of(tests.item('Overlooked')),
          'an old story ranks below a fresh one');
select tests.as_user(tests.uid('bob'));
select throws_ok($$select news.set_pool(tests.item('Overlooked'), true)$$, '42501', null, 'only admins pool');
select tests.as_user(tests.uid('admin'));
select news.set_pool(tests.item('Overlooked'), true);
select ok(tests.rank_of(tests.item('Overlooked')) < tests.rank_of(tests.item('Fresh')),
          'pooled, it gets another run');

-- ----------------------------------------------------------------------------
-- Settings
-- ----------------------------------------------------------------------------

select throws_ok($$select news.set_setting('bar_color', 'red')$$, '22023', 'value', 'colours are six hex digits');
select news.set_setting('bar_color', '0A0A0A');
select tests.as_anon();
select is((select value from news.settings where key = 'bar_color'), '0a0a0a', 'everyone reads the bar colour');

-- ----------------------------------------------------------------------------
-- The points curve, hats, Launch EN
-- ----------------------------------------------------------------------------

select is((select max(points) from news.points_curve(tests.item('Fresh'))), 1,
          'the curve is the running total of votes, for anyone');

select tests.as_user(tests.uid('fel'));
select news.post_comment(tests.item('Delight story'), 'Hat off.', false);
select is((select hat from news.items where text = 'Hat off.'), false, 'a comment can go without its hat');
-- A launch is asked for, never posted (09_news_launch_requests).
select tests.as_user(tests.uid('alice'));
select throws_ok($$select news.submit_story('https://example.com/a', 'Launch EN: Alice Co', '')$$,
                 '22023', 'launch', 'nobody posts a launch');
select tests.as_user(tests.uid('fel'));
select throws_ok($$select news.submit_story('https://example.com/f', 'Launch EN: Fel Co', '')$$,
                 '22023', 'launch', 'not even a fellow');

select tests.as_postgres();
select * from finish();
rollback;
