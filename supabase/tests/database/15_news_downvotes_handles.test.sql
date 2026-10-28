-- Downvotes from any member, and handles that change once every 30 days.
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
  if p_username is not null then
    perform set_config('request.jwt.claims', jsonb_build_object('sub', v_id, 'role', 'authenticated')::text, true);
    -- News is by invitation (20261028130000_news_invites.sql): let the address in.
    insert into news_private.allowed_emails (email) values (lower(p_email)) on conflict do nothing;
    perform news.claim_profile(p_username);
    perform set_config('request.jwt.claims', '', true);
  end if;
  return v_id;
end $$;

create temp table u as
select name, tests.new_user('d_' || name || '@news.test', 'd_' || name) as id
from unnest(array['writer', 'reader', 'other']) name;
insert into u values ('late', tests.new_user('d_late@news.test', null));
grant select on u to anon, authenticated;
create function tests.uid(p_name text) returns uuid language sql stable as $$
  select id from u where name = p_name
$$;
create function tests.item(p_title text) returns bigint language sql stable security definer as $$
  select id from news.items where title = p_title or text = p_title order by id desc limit 1
$$;
grant execute on function tests.item(text) to anon, authenticated;
create function tests.score(p_title text) returns int language sql stable security definer as $$
  select score from news.items where id = tests.item(p_title)
$$;
grant execute on function tests.score(text) to anon, authenticated;
create function tests.karma(p_name text) returns int language sql stable security definer as $$
  select karma from news.profiles where id = tests.uid(p_name)
$$;
grant execute on function tests.karma(text) to anon, authenticated;

select tests.as_user(tests.uid('writer'));
select news.submit_story('', 'A post to vote on', 'Words.');
select news.post_comment(tests.item('A post to vote on'), 'A comment to vote on');

select plan(24);

-- ----------------------------------------------------------------------------
-- Downvotes
-- ----------------------------------------------------------------------------

select tests.as_user(tests.uid('reader'));
select ok(news.vote_item(tests.item('A post to vote on'), -1), 'a member with no points downvotes a post');
select is(tests.score('A post to vote on'), 0, 'its count goes down');
select is(tests.karma('writer'), 0, 'and so do its author''s points (from the 1 everyone starts with)');
select ok(news.vote_item(tests.item('A comment to vote on'), -1), 'and a comment');
select ok(not news.vote_item(tests.item('A comment to vote on'), -1), 'once');
select ok(news.vote_item(tests.item('A post to vote on'), 1), 'within the hour, a vote changes its mind');
select is(tests.score('A post to vote on'), 2, 'from down to up: two');
select tests.as_postgres();
update news.votes set created_at = now() - interval '2 hours'
 where user_id = tests.uid('reader') and item_id = tests.item('A post to vote on');
select tests.as_user(tests.uid('reader'));
select ok(not news.vote_item(tests.item('A post to vote on'), -1), 'after it, the vote stays');
select tests.as_user(tests.uid('writer'));
select ok(not news.vote_item(tests.item('A post to vote on'), -1), 'nobody downvotes their own post');
select is(tests.score('A post to vote on'), 2, 'which keeps its count');

-- ----------------------------------------------------------------------------
-- Changing one's handle
-- ----------------------------------------------------------------------------

select tests.as_user(tests.uid('writer'));
select lives_ok($$select news.change_username('d_author')$$, 'a member changes their handle');
select is((select username from news.profiles where id = tests.uid('writer')), 'd_author', 'their profile has it');
select is((select count(*)::int from news.items where "by" = tests.uid('writer') and by_name <> 'd_author'), 0,
          'and so does everything they wrote');
select tests.as_anon();
select is(news.username_now('D_Writer'), 'd_author', 'their old handle leads to the new one');
select ok(not news.username_available('d_writer'), 'and nobody can take it');
select tests.as_user(tests.uid('late'));
select throws_ok($$select news.claim_profile('d_writer')$$, '22023', 'taken', 'not when joining');
select tests.as_user(tests.uid('other'));
select throws_ok($$select news.change_username('d_writer')$$, '22023', 'taken', 'nor by changing to it');
select throws_ok($$select news.change_username('d_reader')$$, '22023', 'taken', 'nor anyone''s current one');
select throws_ok($$select news.change_username('no spaces')$$, '22023', 'name', 'a handle keeps its shape');
select tests.as_user(tests.uid('writer'));
select throws_ok($$select news.change_username('d_again')$$, '22023', 'soon', 'one change every 30 days');
select ok(news.username_change_after() > now() + interval '29 days', 'and they can see when the next one is');
select tests.as_postgres();
update news.profiles set username_changed_at = now() - interval '31 days' where id = tests.uid('writer');
select tests.as_user(tests.uid('writer'));
select lives_ok($$select news.change_username('d_writer')$$, 'after them, their old handle is theirs to take back');
select is(news.username_now('d_author'), 'd_writer', 'and the one they left leads back');
select tests.as_anon();
select throws_ok($$select news.change_username('d_visitor')$$, '42501', null, 'a visitor changes nothing');

select tests.as_postgres();
select * from finish();
rollback;
