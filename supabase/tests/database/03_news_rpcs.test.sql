-- The News RPCs apply news.arcs rules, whoever calls them.
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

select plan(69);

-- Fresh users, so nothing done in the app beforehand changes the numbers.
create temp table u as
select name, tests.new_user('t_' || name || '@news.test', 't_' || name) as id
from unnest(array['alice', 'bob', 'grace', 'admin']) name;
grant select on u to anon, authenticated;
update news.profiles set is_admin = true where username = 't_admin';
create function tests.uid(p_name text) returns uuid language sql stable as $$
  select id from u where name = p_name
$$;

-- ----------------------------------------------------------------------------
-- Stored HTML is limited to Arc's markup; urls to http(s).
-- ----------------------------------------------------------------------------

select tests.as_user(tests.uid('alice'));
select throws_ok($$select news.submit_story('', 'XSS 1', '<script>alert(1)</script>')$$, '23514', null,
                 'rejects <script> in text');
select throws_ok($$select news.submit_story('', 'XSS 2', '<a href="javascript:alert(1)" rel="nofollow">x</a>')$$,
                 '23514', null, 'rejects javascript: links in text');
select throws_ok($$select news.submit_story('', 'XSS 3', '<img src=x onerror=alert(1)>')$$, '23514', null,
                 'rejects <img onerror> in text');
select throws_ok($$select news.submit_story('', 'XSS 4', '<a href="https://x.com" onmouseover="alert(1)" rel="nofollow">x</a>')$$,
                 '23514', null, 'rejects extra attributes on links');
select throws_ok($$select news.submit_story('javascript:alert(1)', 'XSS 5', '')$$, '22023', 'retry',
                 'rejects javascript: story urls');
select throws_ok($$select news.submit_story('https://x.com/"><script>', 'XSS 6', '')$$, '22023', 'retry',
                 'rejects quotes and brackets in story urls');
select throws_ok($$select news.submit_story('', 'Title <b>', 'x')$$, '23514', null, 'rejects tags in titles');
select throws_ok($$select news.submit_story('', repeat('a', 81), 'x')$$, '22023', 'toolong', 'rejects long titles');
select throws_ok($$select news.submit_story('', 'Nothing', '')$$, '22023', 'bothblank', 'needs a url or text');
select lives_ok($$select news.submit_story('', 'Arc markup',
  'Hello<p><i>world</i> <a href="https://example.com/x?a=1&amp;b=2" rel="nofollow">https://example.com/x</a><p><pre><code>  x &#60; y</code></pre>')$$,
  'accepts Arc markup');
select lives_ok($$select news.post_comment(tests.item('Arc markup'),
  'Same<p><img class="gif" src="https://static.klipy.com/ii/935d7ab9d8c6202580a668421940ec81/14/af/SE72470w.webp" alt="GIF" loading="lazy">')$$,
  'accepts a GIF from KLIPY');
select throws_ok($$select news.post_comment(tests.item('Arc markup'),
  '<img class="gif" src="https://example.com/x.gif" alt="GIF" loading="lazy">')$$, '23514', null,
  'rejects images from anywhere else');
select throws_ok($$select news.post_comment(tests.item('Arc markup'),
  '<img class="gif" src="https://static.klipy.com.evil.example/x.gif" alt="GIF" loading="lazy">')$$, '23514', null,
  'rejects hosts that only start like KLIPY''s');
select throws_ok($$select news.post_comment(tests.item('Arc markup'),
  '<img class="gif" src="http://static.klipy.com/x.gif" alt="GIF" loading="lazy">')$$, '23514', null,
  'rejects KLIPY images over http');
select throws_ok($$select news.post_comment(tests.item('Arc markup'),
  '<img class="gif" src="https://static.klipy.com/x.gif" alt="GIF" loading="lazy" onload="alert(1)">')$$, '23514', null,
  'rejects extra attributes on images');
select lives_ok($$select news.submit_story('https://www.bbc.co.uk/news', 'BBC', '')$$, 'accepts a link');
select is((select site from news.items where id = tests.item('BBC')), 'bbc.co.uk',
          'the site is computed by the database');
select is(news.sitename('https://news.ycombinator.com/item?id=1'), 'ycombinator.com', 'sitename matches news.arc');
select is((select score from news.items where id = tests.item('BBC')), 1, 'a new story starts with its author''s vote');
select is((select count(*) from news.votes where item_id = tests.item('BBC')), 1::bigint, 'the self-vote is recorded');

-- ----------------------------------------------------------------------------
-- Votes
-- ----------------------------------------------------------------------------

select tests.as_user(tests.uid('bob'));
select ok(news.vote_item(tests.item('BBC'), 1), 'bob upvotes alice''s story');
select ok(not news.vote_item(tests.item('BBC'), 1), 'bob cannot vote twice');
select is((select score from news.items where id = tests.item('BBC')), 2, 'the score went up once');
select is((select karma from news.profiles where username = 't_alice'), 2, 'alice''s karma went up');

select ok(news.post_comment(tests.item('BBC'), 'Bob says hi') > 0, 'bob comments');
select tests.as_user(tests.uid('grace'));
select ok(news.post_comment((select id from news.items where text = 'Bob says hi'), 'Grace replies') > 0,
          'grace replies to bob');
select tests.as_user(tests.uid('alice'));
select ok(news.post_comment(tests.item('BBC'), 'Downvote me') > 0, 'alice comments');
select tests.as_user(tests.uid('bob'));
select ok(news.vote_item((select id from news.items where text = 'Downvote me'), -1),
          'bob downvotes a comment, with 1 karma');
select is((select karma from news.profiles where username = 't_alice'), 1, 'the downvote cost alice karma');
select ok(not news.vote_item((select id from news.items where text = 'Downvote me'), -1), 'bob cannot downvote twice');
select ok(news.vote_item(tests.item('Arc markup'), -1) and news.unvote_item(tests.item('Arc markup')),
          'stories can be downvoted too');
select ok(news.vote_item((select id from news.items where text = 'Grace replies'), -1)
          and news.unvote_item((select id from news.items where text = 'Grace replies')),
          'and so can a reply to him');

select ok(news.unvote_item((select id from news.items where text = 'Downvote me')), 'bob takes it back');
select is((select score from news.items where text = 'Downvote me'), 1, 'the score is restored');
select is((select karma from news.profiles where username = 't_alice'), 2, 'alice''s karma is restored');
select tests.as_user(tests.uid('alice'));
select ok(not news.unvote_item(tests.item('BBC')), 'alice cannot take back her own submission vote');

-- ----------------------------------------------------------------------------
-- Flags
-- ----------------------------------------------------------------------------

select tests.as_user(tests.uid('grace'));   -- karma 1
select ok(news.toggle_flag(tests.item('BBC')), 'any member reports, for a moderator to review (11_news_report_review)');
select news.toggle_flag(tests.item('BBC'));  -- and takes it back
select ok(news.submit_story('', 'Flag me', 'spam') > 0, 'grace posts spam');

select tests.as_postgres();
create temp table flaggers as
select tests.new_user('flagger' || g || '@news.test', 't_flagger' || g) as id from generate_series(1, 8) g;
update news.profiles set karma = 50 where username like 't_flagger%';
do $$
declare
  f uuid;
begin
  for f in select id from flaggers limit 7 loop
    perform set_config('request.jwt.claims', jsonb_build_object('sub', f, 'role', 'authenticated')::text, true);
    perform news.toggle_flag(tests.item('Flag me'));
  end loop;
  perform set_config('request.jwt.claims', '', true);
end $$;
select ok(not (select dead from news.items where id = tests.item('Flag me')), 'seven flags do not kill');
do $$
begin
  perform set_config('request.jwt.claims', jsonb_build_object(
    'sub', (select id from flaggers offset 7 limit 1), 'role', 'authenticated')::text, true);
  perform news.toggle_flag(tests.item('Flag me'));
  perform set_config('request.jwt.claims', '', true);
end $$;
select ok((select dead from news.items where id = tests.item('Flag me')), 'the eighth flag kills');

-- ----------------------------------------------------------------------------
-- Editing: fields the caller may not change are ignored.
-- ----------------------------------------------------------------------------

select tests.as_user(tests.uid('alice'));
select lives_ok($$select news.edit_item(tests.item('BBC'), '{"title": "BBC News", "score": 100, "deleted": true, "url": "https://evil.example.com/"}')$$,
                'alice edits her story');
select is((select title from news.items where id = tests.item('BBC News')), 'BBC News', 'the title changed');
select is((select score from news.items where id = tests.item('BBC News')), 2, 'the score did not');
select ok(not (select deleted from news.items where id = tests.item('BBC News')), 'deleted did not');
select is((select url from news.items where id = tests.item('BBC News')), 'https://www.bbc.co.uk/news',
          'the url did not (editors only)');
select throws_ok($$select news.edit_item(tests.item('BBC News'), '{"text": "<script>x</script>"}')$$, '23514', null,
                 'edits are checked for markup too');

select tests.as_user(tests.uid('admin'));
select lives_ok($$select news.edit_item(tests.item('BBC News'), '{"score": 50}')$$, 'the admin edits the score');
select is((select score from news.items where id = tests.item('BBC News')), 50, 'the admin set the score');
select ok((select 'locked' = any (keys) from news.items where id = tests.item('BBC News')),
          'an admin edit locks the item');
select tests.as_user(tests.uid('alice'));
select news.edit_item(tests.item('BBC News'), '{"title": "Changed after lock"}');
select is((select count(*) from news.items where title = 'Changed after lock'), 0::bigint,
          'alice cannot edit a locked item');

-- ----------------------------------------------------------------------------
-- Deleting hides the words from everyone but admins; undeleting restores them.
-- ----------------------------------------------------------------------------

select tests.as_postgres();
create temp table arc as select tests.item('Arc markup') as id;
grant select on arc to anon, authenticated;
select tests.as_user(tests.uid('alice'));
select ok(news.delete_item((select id from arc), true), 'alice deletes her story');
select tests.as_anon();
select results_eq($$select title, url, text, deleted from news.items where id = (select id from arc)$$,
                  $$values ('', '', '', true)$$, 'anon sees a deleted story with no words');
select tests.as_user(tests.uid('alice'));
select is_empty($$select * from news.deleted_items(array[(select id from arc)])$$,
                'alice cannot read deleted content');
select ok(not news.delete_item((select id from arc), false), 'alice cannot undelete');
select tests.as_user(tests.uid('admin'));
select results_eq($$select title from news.deleted_items(array[(select id from arc)])$$,
                  array['Arc markup'], 'an admin reads deleted content');
select ok(news.delete_item((select id from arc), false), 'the admin undeletes');
select ok((select text like 'Hello<p><i>world</i>%' from news.items where id = (select id from arc)),
          'undeleting restores the words');

-- ----------------------------------------------------------------------------
-- Profiles
-- ----------------------------------------------------------------------------

select tests.as_user(tests.uid('alice'));
select news.update_profile(tests.uid('alice'),
  '{"about": "Hi there", "showdead": true, "karma": 9999, "is_admin": true, "badge": "fellowship", "auth": 5}');
select tests.as_postgres();
select results_eq($$select about, showdead, karma, is_admin, badge, auth from news.profiles where username = 't_alice'$$,
                  $$values ('Hi there', true, 2, false, null::text, 0)$$,
                  'alice changes her about and settings, not her karma, role or badge');
select tests.as_user(tests.uid('bob'));
select news.update_profile(tests.uid('alice'), '{"about": "hacked"}');
select is((select about from news.profiles where username = 't_alice'), 'Hi there', 'bob cannot change alice''s profile');
select tests.as_user(tests.uid('admin'));
select news.update_profile(tests.uid('alice'), '{"karma": 77}');
select is((select karma from news.profiles where username = 't_alice'), 77, 'an admin sets karma');
select tests.as_user(tests.uid('alice'));
select throws_ok($$select news.update_profile(tests.uid('alice'), '{"about": "<script>x</script>"}')$$,
                 '23514', null, 'about is checked for markup');
select is((select ignored from news.profile_private()), false, 'profile_private hides ignored from its owner');

-- ----------------------------------------------------------------------------
-- Claiming a username
-- ----------------------------------------------------------------------------

select tests.as_postgres();
create temp table newbie as select tests.new_user('newbie@news.test') as id;
insert into news_private.allowed_emails (email) values ('newbie@news.test');
grant select on newbie to authenticated;
select tests.as_user((select id from newbie));
select throws_ok($$select news.claim_profile('x')$$, '22023', 'name', 'usernames need two characters');
select throws_ok($$select news.claim_profile('bad name!')$$, '22023', 'name', 'usernames are letters, digits, - and _');
select throws_ok($$select news.claim_profile('T_ALICE')$$, '22023', 'taken', 'usernames are unique, ignoring case');
select lives_ok($$select news.claim_profile('t_newbie')$$, 'a free username is claimed');
select news.claim_profile('t_other');
select is((select username from news.profiles where id = (select id from newbie)), 't_newbie',
          'claiming again changes nothing');

-- ----------------------------------------------------------------------------
-- Leaders
-- ----------------------------------------------------------------------------

select tests.as_postgres();
update news.profiles set karma = 200000 where username = 't_admin';
update news.profiles set karma = 100000 where username = 't_alice';
select tests.as_anon();
select is((select username from news.leaders() limit 1), 't_alice', 'the top karma leads');
select ok(not exists (select 1 from news.leaders() where username = 't_admin'), 'admins are not leaders');

select tests.as_postgres();
select * from finish();
rollback;
