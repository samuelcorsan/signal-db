-- Signal acceptances become News badges, and only those.
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

select plan(16);

-- Candidates from supabase/seeds/10_signal_synthetic.sql:
-- ada ...01 fellowship, grace ...02 launchpad, alan ...03 community (email),
-- katherine ...04 community (track only), dennis ...05 launchpad invite only,
-- linus ...06 archived, margaret ...07 rejected + archived, barbara ...08 left.

create temp table expected_members (email text, badges text[]);
insert into expected_members values
  ('ada@example.com', '{community,fellowship}'), ('alan@example.com', '{community}'),
  ('dennis@example.com', '{community}'), ('grace@example.com', '{community,launchpad}'),
  ('katherine@example.com', '{community}');

select results_eq('select email, badges from news_private.signal_members order by email',
                  'select email, badges from expected_members order by email',
                  'accepted, unarchived candidates and their programs');
select is_empty($$select 1 from news_private.signal_members
                  where email in ('linus@example.com', 'margaret@example.com', 'barbara@example.com')$$,
                'archived, rejected and departed candidates are left out');
select is(news_private.sync_signal_members(), 0, 'a second sync changes nothing');

-- Emails only.
delete from news_private.badge_rules where source = 'track_stage';
select news_private.sync_signal_members();
select results_eq('select email, badges from news_private.signal_members order by email',
                  $$values ('alan@example.com', '{community}'::text[]), ('grace@example.com', '{launchpad}'::text[])$$,
                  'without track rules only acceptance emails count');
insert into news_private.badge_rules (source, key, badge) values
  ('track_stage', 'community:joined', 'community'), ('track_stage', 'launchpad:opted_in', 'launchpad'),
  ('track_stage', 'launchpad:accepted', 'launchpad'), ('track_stage', 'fellowship:accepted', 'fellowship');
select news_private.sync_signal_members();

-- A new acceptance email reaches News on the next sync.
insert into public.candidates (candidate_id, first_name, last_name, email)
values ('10000000-0000-4000-a000-000000000009', 'Zoe', 'Example', ' Zoe@Example.com ');
insert into public.candidate_activities (candidate_id, activity_type, metadata)
values ('10000000-0000-4000-a000-000000000009', 'email_sent', '{"email_template": "community_invite"}');
select is(news_private.sync_signal_members(), 1, 'one member added');
select is((select badges from news_private.signal_members where email = 'zoe@example.com'),
          '{community}'::text[], 'a community_invite email makes a member (email normalized)');

-- A reserved account: Ada logs in for the first time.
-- Mixed case, as people type it; Signal stores ada@example.com.
create temp table ada as select tests.new_user('ADA@Example.com') as id;
grant select on ada to authenticated;
select tests.as_user((select id from ada));
select is(news.badge_preview(), 'fellowship', 'the welcome page knows Ada is a fellow before she picks a name');
select news.claim_profile('t_ada');
select is((select badge from news.profiles where username = 't_ada'), 'fellowship', 'Ada''s new profile carries the badge');
select tests.as_postgres();

-- An unconfirmed email gets nothing.
create temp table kath as select tests.new_user('KATHERINE@example.com', p_confirmed => false) as id;
grant select on kath to authenticated;
-- Nor is she let in by it: she joins with an invitation.
insert into news_private.invites (code, inviter)
select 'KATHKATH', id from news.profiles where username = 't_ada';
select tests.as_user((select id from kath));
select is(news.badge_preview(), null, 'no badge preview for an unconfirmed email');
select news.claim_profile('t_kath', 'kath-kath');
select tests.as_postgres();
select news_private.apply_badges();
select is((select badge from news.profiles where username = 't_kath'), null,
          'an unconfirmed email never gets the badge');

-- Archiving takes the badge away.
create temp table alan as select tests.new_user('ALAN@example.com', 't_alan') as id;
select is((select badge from news.profiles where username = 't_alan'), 'community', 'Alan claims with his badge');
select public.archive_candidate('10000000-0000-4000-a000-000000000003', 'test');
select news_private.sync_signal_members();
select ok(not exists (select 1 from news_private.signal_members where email = 'alan@example.com'),
          'an archived candidate leaves signal_members');
select ok(news_private.apply_badges() >= 1, 'apply_badges reports the change');
select is((select badge from news.profiles where username = 't_alan'), null, 'Alan''s badge is gone');

-- Grace keeps the highest badge she has.
select is((select badge from news.profiles where username = 'grace'), 'launchpad',
          'launchpad outranks community');

-- The scheduled job runs every step: members, badges, staff.
select is((select command from cron.job where jobname = 'news-signal-badges'),
          'select news_private.sync_signal_members(); select news_private.apply_badges(); select news_private.apply_staff();',
          'the bridge runs every minute');

select * from finish();
rollback;
