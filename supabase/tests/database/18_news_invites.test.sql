-- Joining News by invitation: one link per member that lets five people in,
-- five more a day after the fifth, ten in all; Exponential's own and the
-- addresses admins allow need none.
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

-- An auth user with a confirmed email and no News profile.
create function tests.new_user(p_email text) returns uuid language plpgsql as $$
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
  return v_id;
end $$;

create temp table u as
select name, tests.new_user('i_' || name || '@news.test') as id
from unnest(array['host', 'admin', 'stranger', 'member', 'friend', 'hidden', 'staffer', 'late']) name;
grant select on u to anon, authenticated;
create function tests.uid(p_name text) returns uuid language sql stable as $$
  select id from u where name = p_name
$$;

-- Codes made in the test, to use them as someone else.
create temp table codes (name text primary key, code text);
grant select on codes to anon, authenticated;
grant insert, update on codes to authenticated;

-- A newcomer, joining with a code; returns the error it got, or 'ok'.
create function tests.join(p_name text, p_code text) returns text language plpgsql as $$
declare
  v_id uuid := tests.new_user(p_name || '@guests.test');
begin
  perform set_config('request.jwt.claims', jsonb_build_object('sub', v_id, 'role', 'authenticated')::text, true);
  begin
    perform news.claim_profile(p_name, p_code);
    return 'ok';
  exception when others then
    return sqlerrm;
  end;
end $$;

-- The host and the admin are let in by address; the hidden one too.
insert into news_private.allowed_emails (email) values ('i_host@news.test'), ('i_admin@news.test'), ('i_hidden@news.test');
insert into news_private.signal_members (candidate_id, email, badges, accepted_at)
values (gen_random_uuid(), 'i_member@news.test', '{community}', now());
insert into public.staff (user_id, email) select id, 'i_staffer@news.test' from u where name = 'staffer';

select plan(56);

-- ----------------------------------------------------------------------------
-- Who needs a code
-- ----------------------------------------------------------------------------

select tests.as_user(tests.uid('stranger'));
select is(news.needs_invite(), true, 'someone nobody let in needs a code');
select throws_ok($$select news.claim_profile('i_stranger')$$, '22023', 'invite', 'and can''t join without one');
select throws_ok($$select news.claim_profile('i_stranger', 'ABCD-EFGH')$$, '22023', 'invite', 'nor with one nobody made');
select throws_ok($$select news.claim_profile('x', 'ABCD-EFGH')$$, '22023', 'name', 'a bad username is said first');

select tests.as_user(tests.uid('host'));
select is(news.needs_invite(), false, 'an address an admin allowed needs none');
select lives_ok($$select news.claim_profile('i_host')$$, 'and joins');
select tests.as_user(tests.uid('member'));
select is(news.needs_invite(), false, 'nor does someone Signal accepted');
select lives_ok($$select news.claim_profile('i_member')$$, 'who joins with their badge');
select tests.as_user(tests.uid('staffer'));
select is(news.needs_invite(), false, 'nor staff');
select lives_ok($$select news.claim_profile('i_staffer')$$, 'who join as staff');
select tests.as_user(tests.uid('admin'));
select news.claim_profile('i_admin');
select tests.as_user(tests.uid('hidden'));
select news.claim_profile('i_hidden');
select tests.as_postgres();
update news.profiles set is_admin = true where id = tests.uid('admin');
update news.profiles set ignored = true where id = tests.uid('hidden');

-- ----------------------------------------------------------------------------
-- One link, five people, then five more a day later, then none
-- ----------------------------------------------------------------------------

select tests.as_user(tests.uid('host'));
select results_eq($$select code, used, allowed, more_at, more_later from news.invite_status()$$,
                  $$values (null::text, 0, 5, null::timestamptz, true)$$, 'a member starts with room for five, more to come, and no code yet');
insert into codes select 'host', news.make_invite();
select matches((select code from codes where name = 'host'), '^[A-HJ-NP-Z2-9]{8}$', 'a code is eight clear characters');
select is(news.make_invite(), (select code from codes where name = 'host'), 'asking again gives the same code');
select is((select code from news.invite_status()), (select code from codes where name = 'host'), 'and it is their invitation''s');

select tests.as_anon();
select is(news.invite_from((select lower(substr(code, 1, 4) || '-' || substr(code, 5)) from codes where name = 'host')),
          'i_host', 'a code says whose it is, however it''s typed');

select tests.as_postgres();
select is(tests.join('g_one', (select lower(code) from codes where name = 'host')), 'ok', 'a newcomer joins with it');
select is((select count(*)::int from news.profiles where username = 'g_one'), 1, 'with a profile');
select is(tests.join('g_two', (select code from codes where name = 'host')), 'ok', 'the same code lets a second in');
select is(tests.join('g_three', (select code from codes where name = 'host')), 'ok', 'a third');
select is(tests.join('g_four', (select code from codes where name = 'host')), 'ok', 'a fourth');
select is(tests.join('g_five', (select code from codes where name = 'host')), 'ok', 'and a fifth');
select is(tests.join('g_six', (select code from codes where name = 'host')), 'full', 'a sixth finds it full');
select is((select count(*)::int from news.profiles where username = 'g_six'), 0, 'and has no profile');

select tests.as_user(tests.uid('host'));
select results_eq($$select used, allowed from news.invite_status()$$, $$values (5, 5)$$, 'five in, five allowed');
select ok((select more_at between now() + interval '23 hours' and now() + interval '1 day 1 minute' from news.invite_status()),
          'five more open a day after the fifth joined');
select is((select count(*)::int from news.my_invitees()), 5, 'the host sees who joined');
select is((select username from news.my_invitees() limit 1), 'g_five', 'newest first');
select tests.as_anon();
select is(news.invite_from((select code from codes where name = 'host')), null, 'a full invitation is from nobody, for now');

select tests.as_postgres();
update news_private.invite_uses set used_at = used_at - interval '1 day 1 minute' where inviter = tests.uid('host');
select tests.as_user(tests.uid('host'));
select results_eq($$select used, allowed, more_at, more_later from news.invite_status()$$,
                  $$values (5, 10, null::timestamptz, false)$$, 'a day later, room for five more, and no more to come');
select tests.as_postgres();
select is((select count(*)::int from generate_series(6, 9) n
            where tests.join('g_' || n, (select code from codes where name = 'host')) = 'ok'), 4, 'four more join');
select is(tests.join('g_ten', (select code from codes where name = 'host')), 'ok', 'and the tenth');
select is(tests.join('g_eleven', (select code from codes where name = 'host')), 'full', 'and ten is all');

-- ----------------------------------------------------------------------------
-- Changing the code
-- ----------------------------------------------------------------------------

select tests.as_user(tests.uid('admin'));
insert into codes select 'admin_old', news.make_invite();
insert into codes select 'admin', news.make_invite(true);
select isnt((select code from codes where name = 'admin'), (select code from codes where name = 'admin_old'), 'changing gives a new code');
select is((select code from news.invite_status()), (select code from codes where name = 'admin'), 'which is now the invitation''s');
select tests.as_postgres();
select is(tests.join('g_old', (select code from codes where name = 'admin_old')), 'invite', 'the old one lets nobody in');
select is(tests.join('g_new', (select code from codes where name = 'admin')), 'ok', 'the new one does');

-- ----------------------------------------------------------------------------
-- No limit, and none at all
-- ----------------------------------------------------------------------------

select tests.as_user(tests.uid('admin'));
select is((select allowed from news.invite_status()), null, 'admins have no limit');
select tests.as_user(tests.uid('staffer'));
select is((select allowed from news.invite_status()), null, 'nor do staff');
select tests.as_user(tests.uid('hidden'));
select throws_ok($$select news.make_invite()$$, '42501', 'invite', 'someone hidden by moderation makes no invitation');

-- ----------------------------------------------------------------------------
-- The leaderboard
-- ----------------------------------------------------------------------------

select tests.as_anon();
select results_eq($$select username, invited from news.invite_leaders() where username like 'i\_%'$$,
                  $$values ('i_host'::text, 10), ('i_admin'::text, 1)$$, 'who brought the most people, for anyone to read');

-- ----------------------------------------------------------------------------
-- The admins' override
-- ----------------------------------------------------------------------------

select tests.as_user(tests.uid('host'));
select throws_ok($$select news.admin_allow_email('x@news.test')$$, '42501', 'admin', 'members can''t let anyone in');
select throws_ok($$select * from news.admin_allowed_emails()$$, '42501', 'admin', 'nor see who is');

select tests.as_user(tests.uid('admin'));
select throws_ok($$select news.admin_allow_email('not an email')$$, '22023', 'email', 'an address must look like one');
select lives_ok($$select news.admin_allow_email(' I_Late@News.Test ', 'Speaker at Demo Day')$$, 'an admin lets an address in');
select results_eq($$select email, note, added_by, joined from news.admin_allowed_emails() where email = 'i_late@news.test'$$,
                  $$values ('i_late@news.test'::text, 'Speaker at Demo Day'::text, 'i_admin'::text, null::text)$$,
                  'and sees it, with who added it');
select is((select joined from news.admin_allowed_emails() where email = 'i_host@news.test'), 'i_host',
          'an address someone joined with says who');
select tests.as_user(tests.uid('late'));
select is(news.needs_invite(), false, 'the allowed address needs no code');
select tests.as_user(tests.uid('admin'));
select news.admin_disallow_email('i_late@news.test');
select tests.as_user(tests.uid('late'));
select is(news.needs_invite(), true, 'until an admin takes it off the list');

-- ----------------------------------------------------------------------------
-- Extra places, from an admin
-- ----------------------------------------------------------------------------

select tests.as_user(tests.uid('host'));
select throws_ok($$select news.admin_set_invite_extra(news.uid(), 50)$$, '42501', 'admin', 'members give themselves no places');
select tests.as_user(tests.uid('admin'));
select throws_ok(format('select news.admin_set_invite_extra(%L, -1)', tests.uid('host')), '22023', 'extra', 'places are counted from zero');
select lives_ok(format('select news.admin_set_invite_extra(%L, 2)', tests.uid('host')), 'an admin gives the host two more');
select results_eq(format('select used, allowed, extra from news.admin_invite_of(%L)', tests.uid('host')),
                  $$values (10, 12, 2)$$, 'and sees them on top of the ten');
select tests.as_postgres();
select is(tests.join('g_extra', (select code from codes where name = 'host')), 'ok', 'which let someone in at once');
select tests.as_user(tests.uid('admin'));
select news.admin_set_invite_extra(tests.uid('host'), 0);
select is((select allowed from news.admin_invite_of(tests.uid('host'))), 10, 'zero takes them away');

-- ----------------------------------------------------------------------------
-- What the API roles reach
-- ----------------------------------------------------------------------------

select tests.as_postgres();
select ok(not has_table_privilege('authenticated', 'news_private.invites', 'SELECT')
          and not has_table_privilege('authenticated', 'news_private.invite_uses', 'SELECT')
          and not has_table_privilege('anon', 'news_private.allowed_emails', 'SELECT'),
          'nobody reads the codes, who used them or the allowed addresses directly');
select ok(not has_function_privilege('anon', 'news.make_invite(boolean)', 'EXECUTE')
          and not has_function_privilege('anon', 'news.claim_profile(text, text)', 'EXECUTE')
          and not has_function_privilege('anon', 'news.admin_allow_email(text, text)', 'EXECUTE'),
          'visitors make no codes and join nothing');

select * from finish();
rollback;
