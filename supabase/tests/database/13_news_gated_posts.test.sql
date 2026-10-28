-- Posts for members with a badge: who reads them, who gates them, and that
-- a gated conversation is gated all the way down.
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
select name, tests.new_user('g_' || name || '@news.test', 'g_' || name) as id
from unnest(array['staff', 'fel', 'plain', 'author']) name;
grant select on u to anon, authenticated;
update news.profiles set is_admin = true, staff = true where username = 'g_staff';
update news.profiles set badge = 'fellowship' where username = 'g_fel';
create function tests.uid(p_name text) returns uuid language sql stable as $$
  select id from u where name = p_name
$$;
-- How many of the stories called p_title the current reader can see.
create function tests.sees(p_title text) returns bigint language sql stable as $$
  select count(*) from news.items where title = p_title
$$;
create function tests.sees_text(p_text text) returns bigint language sql stable as $$
  select count(*) from news.items where text = p_text
$$;
create function tests.item(p_title text) returns bigint language sql stable security definer as $$
  select id from news.items where title = p_title order by id desc limit 1
$$;
grant execute on function tests.item(text) to anon, authenticated;

select plan(19);

-- ----------------------------------------------------------------------------
-- Gating one's own post
-- ----------------------------------------------------------------------------

select tests.as_user(tests.uid('staff'));
select lives_ok($$select news.submit_story('', 'For members', 'Words.', true, false, true)$$, 'staff gate what they post');
select is(tests.sees('For members'), 1::bigint, 'staff read it');
select tests.as_user(tests.uid('fel'));
select is(tests.sees('For members'), 1::bigint, 'a member with a badge reads it');
select tests.as_user(tests.uid('plain'));
select is(tests.sees('For members'), 0::bigint, 'a member without one doesn''t see it');
select tests.as_anon();
select is(tests.sees('For members'), 0::bigint, 'nor does a visitor');
select tests.as_user(tests.uid('plain'));
select throws_ok($$select news.submit_story('', 'Mine, gated', 'Words.', true, false, true)$$, '42501', 'gate',
                 'only staff gate a post');

-- ----------------------------------------------------------------------------
-- Its conversation
-- ----------------------------------------------------------------------------

select tests.as_user(tests.uid('fel'));
select news.post_comment(tests.item('For members'), 'A member''s reply.');
select is((select gated from news.items where text = 'A member''s reply.'), true, 'a comment there is gated with it');
select tests.as_user(tests.uid('plain'));
select is(tests.sees_text('A member''s reply.'), 0::bigint, 'and hidden with it');
select throws_ok($$select news.post_comment(tests.item('For members'), 'Can I?')$$, '22023', 'noitem',
                 'who can''t read it can''t comment on it');

-- ----------------------------------------------------------------------------
-- Gating someone else's post, and opening it again
-- ----------------------------------------------------------------------------

select tests.as_user(tests.uid('author'));
select news.submit_story('', 'An author''s post', 'Words.');
select news.post_comment(tests.item('An author''s post'), 'An early reply.');
select tests.as_user(tests.uid('plain'));
select throws_ok($$select news.set_gate(tests.item('An author''s post'), true)$$, '42501', null, 'only staff gate someone''s post');
select tests.as_user(tests.uid('staff'));
select lives_ok($$select news.set_gate(tests.item('An author''s post'), true)$$, 'staff gate anyone''s');
select tests.as_user(tests.uid('plain'));
select is(tests.sees('An author''s post') + tests.sees_text('An early reply.'), 0::bigint,
          'and it goes, with the replies already there');
select tests.as_user(tests.uid('author'));
select is(tests.sees('An author''s post'), 1::bigint, 'its author still reads it');
select tests.as_anon();
select is(news.gated_item(tests.item('An author''s post')), true, 'a link to it can say it''s for members');
select is(news.gated_item(tests.item('For members') + 100000), false, 'and nothing about what isn''t there');
select tests.as_user(tests.uid('plain'));
select is((select count(*) from news.points_curve(tests.item('An author''s post'))), 0::bigint,
          'nor its points over time');
select tests.as_user(tests.uid('staff'));
select news.set_gate(tests.item('An author''s post'), false);
select tests.as_user(tests.uid('plain'));
select is(tests.sees('An author''s post') + tests.sees_text('An early reply.'), 2::bigint, 'opened, everyone reads it again');
select is(news.gated_item(tests.item('An author''s post')), false, 'and its link opens');
select tests.as_user(tests.uid('fel'));
select ok((select count(*) from news.points_curve(tests.item('For members'))) > 0, 'a member with a badge sees a gated post''s curve');

select tests.as_postgres();
select * from finish();
rollback;
