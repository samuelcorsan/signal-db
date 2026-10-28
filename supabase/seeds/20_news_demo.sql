-- LOCAL ONLY. Demo News accounts and posts, written through the same RPCs the
-- site calls (with a JWT set by hand), so the seed exercises their checks.
--
--   admin@news.test   / news-admin-pw   admin
--   alice@news.test   / news-alice-pw
--   bob@news.test     / news-bob-pw
--   grace@example.com / news-grace-pw   Signal's Grace: gets the launchpad badge
--
-- News is by invitation: admin and alice are on the admins' list of allowed
-- emails, grace is let in by her badge, and bob joins with a code from alice.
-- Anyone else who logs in locally needs a code from one of them (/invites).
--
-- ada@example.com (Signal's Ada, an accepted fellow) has no account yet: log
-- in as her with "email me a login link" and read the link in Mailpit
-- (http://127.0.0.1:54324) to see a reserved account being claimed.

with u (id, email, password, username) as (values
  ('20000000-0000-4000-a000-000000000001'::uuid, 'admin@news.test',   'news-admin-pw', 'admin'),
  ('20000000-0000-4000-a000-000000000002'::uuid, 'alice@news.test',   'news-alice-pw', 'alice'),
  ('20000000-0000-4000-a000-000000000003'::uuid, 'bob@news.test',     'news-bob-pw',   'bob'),
  ('20000000-0000-4000-a000-000000000004'::uuid, 'grace@example.com', 'news-grace-pw', 'grace')
), users as (
  insert into auth.users (
    instance_id, id, aud, role, email, encrypted_password, email_confirmed_at,
    raw_app_meta_data, raw_user_meta_data, created_at, updated_at,
    confirmation_token, recovery_token, email_change_token_new, email_change,
    email_change_token_current, phone_change, phone_change_token, reauthentication_token)
  select '00000000-0000-0000-0000-000000000000', id, 'authenticated', 'authenticated', email,
         -- Confirmed a day ago: a link that confirms an address replaces any
         -- earlier password (app/auth/confirm), and these keep theirs.
         extensions.crypt(password, extensions.gen_salt('bf')), now() - interval '1 day',
         '{"provider": "email", "providers": ["email"]}',
         jsonb_build_object('signup_app', 'news', 'username', username), now(), now(),
         '', '', '', '', '', '', '', ''
  from u
  returning id, email
)
insert into auth.identities (provider_id, user_id, identity_data, provider, last_sign_in_at, created_at, updated_at)
select id::text, id, jsonb_build_object('sub', id::text, 'email', email, 'email_verified', true),
       'email', now(), now(), now()
from users;

do $$
declare
  admin uuid := '20000000-0000-4000-a000-000000000001';
  alice uuid := '20000000-0000-4000-a000-000000000002';
  bob   uuid := '20000000-0000-4000-a000-000000000003';
  grace uuid := '20000000-0000-4000-a000-000000000004';
  rls   bigint;
  code  text;
begin
  insert into news_private.allowed_emails (email, note) values
    ('admin@news.test', 'Demo admin'), ('alice@news.test', 'Demo member');
  -- Signal's seed is in: recognise its accepted members now, not in a minute.
  perform news_private.sync_signal_members();

  perform set_config('request.jwt.claims', jsonb_build_object('sub', admin, 'role', 'authenticated')::text, true);
  perform news.claim_profile('admin');
  perform news.submit_story('', 'Welcome to Exponential News',
    'News for the brightest builders in Spain.<p>Accepted Exponential members carry a badge next to their name.');

  perform set_config('request.jwt.claims', jsonb_build_object('sub', alice, 'role', 'authenticated')::text, true);
  perform news.claim_profile('alice');
  code := news.make_invite();
  rls := news.submit_story('https://www.postgresql.org/docs/current/ddl-rowsecurity.html',
                           'Row Security Policies', '');
  perform news.submit_story('https://supabase.com/docs/guides/database/postgres/row-level-security',
                            'Row Level Security in Supabase', '');

  perform set_config('request.jwt.claims', jsonb_build_object('sub', grace, 'role', 'authenticated')::text, true);
  perform news.claim_profile('grace');
  perform news.submit_story('', 'Ask EN: What are you building this week?', 'Launchpad cohort here. Share yours.');

  perform set_config('request.jwt.claims', jsonb_build_object('sub', bob, 'role', 'authenticated')::text, true);
  perform news.claim_profile('bob', code);
  perform news.post_comment(rls, 'Policies are ORed together unless they are restrictive.');
  perform news.vote_item(rls, 1);
  perform news.vote_item((select id from news.items where title = 'Welcome to Exponential News'), 1);

  perform set_config('request.jwt.claims', jsonb_build_object('sub', grace, 'role', 'authenticated')::text, true);
  perform news.post_comment((select id from news.items where text like 'Policies are ORed%'),
                            'And a table owner bypasses them unless you <i>force</i> it.');
  perform news.vote_item(rls, 1);

  perform set_config('request.jwt.claims', '', true);
end
$$;

update news.profiles set is_admin = true where username = 'admin';

select news_private.sync_signal_members();
select news_private.apply_badges();
