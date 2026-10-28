-- Images members upload: into their own folder only, a photo from it, and a
-- post that shows one News serves (and nothing else's).
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

-- An auth user, with a News profile unless p_username is null.
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
select name, tests.new_user('i_' || name || '@news.test', case when name = 'outsider' then null else 'i_' || name end) as id
from unnest(array['alice', 'bob', 'admin', 'outsider']) name;
grant select on u to anon, authenticated;
update news.profiles set is_admin = true where username = 'i_admin';
create function tests.uid(p_name text) returns uuid language sql stable as $$
  select id from u where name = p_name
$$;
create function tests.upload_as(p_name text, p_folder text) returns void language plpgsql as $$
begin
  perform tests.as_user(tests.uid(p_name));
  insert into storage.objects (bucket_id, name) values ('news-images', p_folder || '/abcdefgh12.png');
end $$;

select plan(17);

-- ----------------------------------------------------------------------------
-- The bucket, and uploading
-- ----------------------------------------------------------------------------

select is((select row(public, file_size_limit, allowed_mime_types)::text from storage.buckets where id = 'news-images'),
          row(true, 4194304::bigint, array['image/png', 'image/jpeg', 'image/webp', 'image/gif'])::text,
          'news-images is public to read, 4 MB at most, four kinds of image');
select lives_ok(format($$select tests.upload_as('alice', %L)$$, tests.uid('alice')), 'a member uploads into her folder');
select throws_ok(format($$select tests.upload_as('alice', %L)$$, tests.uid('bob')), '42501', null,
                 'not into anyone else''s');
select throws_ok(format($$select tests.upload_as('outsider', %L)$$, tests.uid('outsider')), '42501', null,
                 'an account with no News profile uploads nothing');
select tests.as_anon();
select throws_ok($$insert into storage.objects (bucket_id, name) values ('news-images', 'x/abcdefgh12.png')$$, '42501', null,
                 'nor does a visitor');

-- ----------------------------------------------------------------------------
-- A photo of one's own
-- ----------------------------------------------------------------------------

select tests.as_user(tests.uid('alice'));
select lives_ok(format($$select news.update_profile(%L, jsonb_build_object('photo', 'media/' || %L || '/abcdefgh12.png'))$$,
                       tests.uid('alice'), tests.uid('alice')), 'a member sets her photo from her folder');
select is((select photo from news.profile_private()), 'media/' || tests.uid('alice') || '/abcdefgh12.png',
          'and reads it back');
select throws_ok(format($$select news.update_profile(%L, jsonb_build_object('photo', 'media/' || %L || '/abcdefgh12.png'))$$,
                        tests.uid('alice'), tests.uid('bob')), '23514', null, 'not from someone else''s');
select throws_ok(format($$select news.update_profile(%L, '{"photo": "https://elsewhere.example/a.png"}')$$, tests.uid('alice')),
                 '23514', null, 'nor from another site');
select tests.as_user(tests.uid('bob'));
select news.update_profile(tests.uid('alice'), '{"photo": ""}');
select tests.as_anon();
select isnt((select photo from news.profiles where id = tests.uid('alice')), '',
            'nobody else takes it down, and anyone can see it');
select tests.as_user(tests.uid('admin'));
select news.update_profile(tests.uid('alice'), '{"photo": ""}');
select is((select photo from news.profiles where id = tests.uid('alice')), '', 'an admin can');

-- ----------------------------------------------------------------------------
-- Images in a post: News' own, only in posts
-- ----------------------------------------------------------------------------

select tests.as_user(tests.uid('alice'));
select lives_ok(format($$select news.submit_story('', 'With an image', %L)$$,
                       '<p>Look:</p><p><img src="media/' || tests.uid('alice') || '/abcdefgh12.png" alt="a chart" loading="lazy"></p>'),
                'a post shows an image News serves');
select lives_ok(format($$select news.submit_story('', 'Linking one', %L)$$,
                       '<p><a href="media/' || tests.uid('alice') || '/abcdefgh12.png" rel="nofollow">the chart</a></p>'),
                'and links to one');
select throws_ok($$select news.submit_story('', 'Elsewhere', '<p><img src="https://elsewhere.example/a.png" alt="" loading="lazy"></p>')$$,
                 '23514', null, 'not an image from elsewhere');
select throws_ok(format($$select news.submit_story('', 'Handler', %L)$$,
                        '<img src="media/' || tests.uid('alice') || '/abcdefgh12.png" alt="" loading="lazy" onerror="x">'),
                 '23514', null, 'nor one with anything else on it');
select throws_ok(format($$select news.submit_story('', 'Script', %L)$$,
                        '<img src="media/' || tests.uid('alice') || '/abcdefgh12.png" alt="x" onload="alert(1)" loading="lazy">'),
                 '23514', null, 'in any order');
select throws_ok(format($$select news.post_comment((select id from news.items where title = 'With an image'), %L)$$,
                        '<img src="media/' || tests.uid('alice') || '/abcdefgh12.png" alt="" loading="lazy">'),
                 '23514', null, 'a comment holds no image but a GIF, as before');

select tests.as_postgres();
select * from finish();
rollback;
