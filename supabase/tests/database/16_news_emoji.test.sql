-- Emoji of News' own, added by members with a badge and staff, and a status
-- with its words.
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
select name, tests.new_user('e_' || name || '@news.test', 'e_' || name) as id
from unnest(array['fellow', 'other', 'plain', 'admin']) name;
grant select on u to anon, authenticated;
create function tests.uid(p_name text) returns uuid language sql stable as $$
  select id from u where name = p_name
$$;
create function tests.pic(p_name text, p_file text) returns text language sql stable as $$
  select 'media/' || tests.uid(p_name)::text || '/' || p_file
$$;
grant execute on function tests.uid(text), tests.pic(text, text) to anon, authenticated;

update news.profiles set badge = 'fellowship' where id = tests.uid('fellow');
update news.profiles set badge = 'community' where id = tests.uid('other');
update news.profiles set is_admin = true where id = tests.uid('admin');

select plan(27);

-- Adding
select tests.as_user(tests.uid('plain'));
select throws_ok($$select news.add_emoji('party', tests.pic('plain', 'abcdef0123.png'))$$, '42501', 'nobadge',
                 'a member without a badge adds no emoji');

select tests.as_user(tests.uid('fellow'));
select lives_ok($$select news.add_emoji('party', tests.pic('fellow', 'abcdef0123.png'))$$,
                'a member with a badge adds one');
select throws_ok($$select news.add_emoji('Party Time', tests.pic('fellow', 'abcdef0124.png'))$$, '22023', 'badname',
                 'a name is lower case letters, digits, - and _');
select throws_ok($$select news.add_emoji('x', tests.pic('fellow', 'abcdef0124.png'))$$, '22023', 'badname',
                 'a name is two characters at least');
select throws_ok($$select news.add_emoji('stolen', tests.pic('other', 'abcdef0124.png'))$$, '22023', 'badpath',
                 'the image is in the adder''s own folder');
select throws_ok($$insert into news.emoji (name, path, "by") values ('direct', tests.pic('fellow', 'abcdef0125.png'), tests.uid('fellow'))$$,
                 '42501', null, 'emoji are only added through add_emoji');

select tests.as_user(tests.uid('other'));
select throws_ok($$select news.add_emoji('party', tests.pic('other', 'abcdef0126.png'))$$, '23505', 'taken',
                 'a name is one emoji''s');
select lives_ok($$select news.add_emoji('ship-it', tests.pic('other', 'abcdef0127.gif'))$$,
                'another member with a badge adds theirs');

select tests.as_user(tests.uid('admin'));
select lives_ok($$select news.add_emoji('staff_only', tests.pic('admin', 'abcdef0128.webp'))$$, 'staff add one too');

-- Reading
select tests.as_anon();
select is((select count(*)::int from news.emoji), 3, 'anyone reads them');
select is((select "by" from news.emoji where name = 'party'), tests.uid('fellow'), 'and who added each');

-- Taking away
select tests.as_user(tests.uid('other'));
select throws_ok($$select news.remove_emoji('party')$$, '22023', 'noemoji', 'nobody takes away someone else''s');
select lives_ok($$select news.remove_emoji('ship-it')$$, 'whoever added one takes it away');
select tests.as_user(tests.uid('admin'));
select lives_ok($$select news.remove_emoji('party')$$, 'an admin takes away anyone''s');
select is((select array_agg(name)::text from news.emoji), '{staff_only}', 'what''s left');

-- A status
select tests.as_user(tests.uid('plain'));
select lives_ok($$select news.update_profile(tests.uid('plain'), '{"status": "🚀"}')$$, 'anyone wears a status');
select throws_ok($$select news.update_profile(tests.uid('plain'), '{"status": "<b>"}')$$, '23514', null,
                 'a status holds no markup');
select lives_ok($$select news.update_profile(tests.uid('plain'), '{"status_text": "De vacaciones <hasta el lunes>"}')$$,
                'a status says something, as plain text');
select throws_ok($$select news.update_profile(tests.uid('plain'), jsonb_build_object('status_text', repeat('a', 101)))$$,
                 '23514', null, 'in 100 characters at most');
select tests.as_anon();
select is((select status from news.profiles where id = tests.uid('plain')), '🚀', 'and everyone reads it');
select is((select status_text from news.profiles where id = tests.uid('plain')), 'De vacaciones <hasta el lunes>',
          'its words too');

-- Set in one go, and cleared
select tests.as_user(tests.uid('other'));
select lives_ok($$select news.set_status('📅', 'En una reunión', now() + interval '1 hour')$$, 'a status is set in one go');
select is((select status || ' ' || status_text || ' ' || (status_until > now())::text from news.profiles where id = tests.uid('other')),
          '📅 En una reunión true', 'with when it goes');
select throws_ok($$select news.set_status('📅', 'Ayer', now() - interval '1 hour')$$, '22023', 'past', 'never to go in the past');
select lives_ok($$select news.set_status('', 'Lo que sea', now() + interval '1 hour')$$, 'clearing the emoji');
select is((select status || '|' || status_text || '|' || coalesce(status_until::text, 'none') from news.profiles where id = tests.uid('other')),
          '||none', 'clears all three');
select tests.as_anon();
select throws_ok($$select news.set_status('📅', '', null)$$, '42501', null, 'a visitor sets no status');

select tests.as_postgres();
select * from finish();
rollback;
