-- What /admin reads (admins only) and the announcement it sets.
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

create temp table u as
select name, tests.new_user('a_' || name || '@news.test', 'a_' || name) as id
from unnest(array['admin', 'mod', 'fel', 'plain']) name;
grant select on u to anon, authenticated;
update news.profiles set is_admin = true where username = 'a_admin';
update news.profiles set auth = 1 where username = 'a_mod';
update news.profiles set badge = 'fellowship' where username = 'a_fel';
create function tests.uid(p_name text) returns uuid language sql stable as $$
  select id from u where name = p_name
$$;

-- Some activity this week, and a decision of each kind.
select tests.as_user(tests.uid('fel'));
select news.submit_story('https://fel.example', 'Show EN: Fel Co', '', true, true);
select tests.as_user(tests.uid('plain'));
select news.submit_story('', 'A question', 'Words.');
select news.post_comment((select id from news.items where title = 'A question'), 'An answer.');
select news.toggle_flag((select id from news.items where title = 'Show EN: Fel Co'));
select tests.as_user(tests.uid('admin'));
select news.decide_launch((select id from news.items where title = 'Show EN: Fel Co'), true);
select tests.as_user(tests.uid('mod'));
select news.review_reports((select id from news.items where title = 'Launch EN: Fel Co'), false);

select plan(15);

-- ----------------------------------------------------------------------------
-- Admins only
-- ----------------------------------------------------------------------------

select tests.as_user(tests.uid('mod'));
select throws_ok($$select * from news.admin_pulse()$$, '42501', null, 'a moderator reads none of it');
select throws_ok($$select * from news.admin_people()$$, '42501', null, 'not who has powers');
select tests.as_anon();
select throws_ok($$select * from news.admin_counts()$$, '42501', null, 'nor does a visitor');

-- ----------------------------------------------------------------------------
-- What admins read
-- ----------------------------------------------------------------------------

select tests.as_user(tests.uid('admin'));
select is((select count(*) from news.admin_pulse()), 12::bigint, 'twelve weeks, by default');
select ok((select posts >= 2 and comments >= 1 and members >= 4 and active >= 2
             from news.admin_pulse() order by week desc limit 1),
          'this week: the posts, the comment, who joined and who did something');
select is((select week from news.admin_pulse() order by week desc limit 1), date_trunc('week', now())::date,
          'weeks start on Monday');
select ok((select fellowship >= 1 and moderators >= 1 and members >= 4 from news.admin_counts()),
          'how many, by program, and the moderators');
select is((select array_agg(username order by username) from news.admin_people() where username like 'a\_%'),
          array['a_admin', 'a_mod'], 'who has powers');
select is((select array_agg(kind || ': ' || outcome || ' by ' || decided_by order by kind) from news.admin_decisions()
            where decided_by like 'a\_%'),
          array['launch: launched by a_admin', 'report: kept by a_mod'], 'what moderators decided');

-- ----------------------------------------------------------------------------
-- The announcement
-- ----------------------------------------------------------------------------

select news.set_setting('banner_text', 'Demo Day is on Friday at 18:00, in Madrid');
select news.set_setting('banner_link', 'item?id=1');
select tests.as_anon();
select is((select value from news.settings where key = 'banner_text'), 'Demo Day is on Friday at 18:00, in Madrid',
          'everyone reads the announcement, in its own case');
select tests.as_user(tests.uid('admin'));
select throws_ok($$select news.set_setting('banner_link', 'javascript:alert(1)')$$, '22023', 'value', 'its link is a page of News''');
select lives_ok($$select news.set_setting('banner_link', 'https://www.goexponential.org/demo-day')$$, 'or a full https address');
select throws_ok($$select news.set_setting('banner_text', 'Click <here>')$$, '22023', 'value', 'and it holds no tags');
select news.set_setting('bar_color', 'FF6600');
select is((select value from news.settings where key = 'bar_color'), 'ff6600', 'a colour still reads in lower case');
select tests.as_user(tests.uid('plain'));
select throws_ok($$select news.set_setting('banner_text', 'Mine')$$, '42501', null, 'only admins set it');

select tests.as_postgres();
select * from finish();
rollback;
