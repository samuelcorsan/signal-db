-- Exponential News must not be able to reach Signal data, by any route.
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

select plan(25);

-- ----------------------------------------------------------------------------
-- (a) news_owner, which runs every News RPC, cannot touch Signal.
-- ----------------------------------------------------------------------------

select is_empty($$
  select n.nspname || '.' || c.relname
  from pg_class c join pg_namespace n on n.oid = c.relnamespace
  where n.nspname in ('public', 'private') and c.relkind in ('r', 'p', 'v', 'm', 'f')
    and (has_table_privilege('news_owner', c.oid, 'SELECT,INSERT,UPDATE,DELETE,TRUNCATE,REFERENCES,TRIGGER')
         or has_any_column_privilege('news_owner', c.oid, 'SELECT,INSERT,UPDATE,REFERENCES'))
$$, 'news_owner has no privilege on any Signal table or view');

select is_empty($$
  select n.nspname || '.' || c.relname
  from pg_class c join pg_namespace n on n.oid = c.relnamespace
  where n.nspname in ('public', 'private') and c.relkind = 'S'
    and case when c.relkind = 'S' then has_sequence_privilege('news_owner', c.oid, 'USAGE,SELECT,UPDATE') end
$$, 'news_owner has no privilege on any Signal sequence');

select ok(not has_schema_privilege('news_owner', 'private', 'USAGE'), 'news_owner cannot use schema private');
select ok(not has_schema_privilege('news_owner', 'auth', 'USAGE'), 'news_owner cannot use schema auth');

-- Signal RPCs closed to anon are closed to news_owner too.
select is_empty($$
  select p.oid::regprocedure::text
  from pg_proc p join pg_namespace n on n.oid = p.pronamespace
  where n.nspname = 'public' and p.prosecdef
    and has_function_privilege('news_owner', p.oid, 'EXECUTE')
    and not has_function_privilege('anon', p.oid, 'EXECUTE')
$$, 'news_owner cannot run any Signal SECURITY DEFINER function anon cannot');

-- ----------------------------------------------------------------------------
-- (b) news_bridge reads exactly the columns it needs, and writes nothing.
-- ----------------------------------------------------------------------------

select is(
  array(
    select (c.relname::text || '.' || a.attname::text) collate "default"
    from pg_class c join pg_namespace n on n.oid = c.relnamespace
    join pg_attribute a on a.attrelid = c.oid and a.attnum > 0 and not a.attisdropped
    where n.nspname in ('public', 'private') and c.relkind in ('r', 'p', 'v', 'm', 'f')
      and has_column_privilege('news_bridge', c.oid, a.attnum, 'SELECT')
    order by c.relname::text collate "C", a.attname::text collate "C"),
  array[
    'candidate_activities.activity_timestamp', 'candidate_activities.activity_type',
    'candidate_activities.candidate_id', 'candidate_activities.metadata',
    'candidate_track_events.candidate_id', 'candidate_track_events.occurred_at',
    'candidate_track_events.seq', 'candidate_track_events.stage', 'candidate_track_events.track',
    'candidates.archived_at', 'candidates.candidate_id', 'candidates.email'],
  'news_bridge can read exactly the acceptance columns of three Signal tables');

select is_empty($$
  select n.nspname || '.' || c.relname
  from pg_class c join pg_namespace n on n.oid = c.relnamespace
  where n.nspname in ('public', 'private', 'auth')
    and (has_table_privilege('news_bridge', c.oid, 'INSERT,UPDATE,DELETE,TRUNCATE,REFERENCES,TRIGGER')
         or has_any_column_privilege('news_bridge', c.oid, 'INSERT,UPDATE,REFERENCES'))
$$, 'news_bridge cannot write anything in Signal or auth');

insert into public.candidate_activities (candidate_id, activity_type, metadata)
values ('10000000-0000-4000-a000-000000000001', 'source_update', '{"source_url": "https://example.com"}');

select is(tests.count_as('news_bridge', $$select count(candidate_id) from public.candidate_activities
                                         where activity_type <> 'email_sent'$$),
          0::bigint, 'news_bridge sees only email_sent activities');
select is(tests.count_as('news_bridge', 'select count(candidate_id) from public.candidate_activities'),
          (select count(*) from public.candidate_activities where activity_type = 'email_sent'),
          'news_bridge sees every email_sent activity');
select is(tests.sqlstate_as('news_bridge', 'select phone from public.candidates'), '42501',
          'news_bridge cannot read candidates.phone');
select is(tests.sqlstate_as('news_bridge', 'select first_name from public.candidates'), '42501',
          'news_bridge cannot read candidate names');
select is(tests.sqlstate_as('news_bridge', 'select content from public.candidate_notes'), '42501',
          'news_bridge cannot read notes');
select is(tests.sqlstate_as('news_bridge', $$update public.candidates set email = 'x@example.com'$$), '42501',
          'news_bridge cannot update candidates');

-- ----------------------------------------------------------------------------
-- (c) Signed-in News users and anonymous visitors see no Signal data.
-- Every staff-gated relation, every security_invoker view, every RLS table
-- without policies in public, and everything in private.
-- ----------------------------------------------------------------------------

create temp table gated as
select c.oid::regclass as rel
from pg_class c join pg_namespace n on n.oid = c.relnamespace
where (n.nspname = 'public' and c.relkind in ('r', 'p')
       and exists (select 1 from pg_policies p
                   where p.schemaname = 'public' and p.tablename = c.relname
                     and (p.qual like '%is_staff%' or p.with_check like '%is_staff%')))
   or (n.nspname = 'public' and c.relkind = 'v'
       and array_to_string(c.reloptions, ',') ~ 'security_invoker=(on|true)')
   or (n.nspname = 'public' and c.relkind = 'r' and c.relrowsecurity
       and not exists (select 1 from pg_policy p where p.polrelid = c.oid))
   or (n.nspname = 'private' and c.relkind in ('r', 'v'));

create temp table gate_results (rel text, who text, n bigint, denied boolean);

do $$
declare
  r   record;
  who text;
  cnt bigint;
begin
  for r in select rel from gated loop
    foreach who in array array['anon', 'alice', 'staff'] loop
      begin
        if who = 'anon' then
          perform set_config('request.jwt.claims', '{"role": "anon"}', true);
          execute 'set local role anon';
        else
          perform set_config('request.jwt.claims', jsonb_build_object(
            'role', 'authenticated',
            'sub', case who when 'alice' then '20000000-0000-4000-a000-000000000002'
                            else '00000000-0000-4000-a000-000000000001' end)::text, true);
          execute 'set local role authenticated';
        end if;
        execute format('select count(*) from %s', r.rel) into cnt;
        execute 'reset role';
        insert into gate_results values (r.rel::text, who, cnt, false);
      exception when insufficient_privilege then
        insert into gate_results values (r.rel::text, who, null, true);
      end;
    end loop;
  end loop;
  perform set_config('request.jwt.claims', '', true);
end
$$;

select ok((select count(*) from gated) >= 40,
          format('checked %s Signal relations', (select count(*) from gated)));
select is_empty($$select rel, who, n from gate_results where who in ('anon', 'alice') and not denied and n > 0$$,
                'anon and a signed-in News user see no rows in any Signal relation');
-- The method works: staff do see rows.
select is((select n from gate_results where who = 'staff' and rel = 'candidates'),
          (select count(*) from public.candidates), 'staff see every candidate through the same check');
select ok((select n from gate_results where who = 'staff' and rel = 'candidate_notes') > 0,
          'staff see the private note through the same check');
select ok((select n from gate_results where who = 'staff' and rel = 'candidate_member_state') > 0,
          'staff see the member-state view through the same check');

-- ----------------------------------------------------------------------------
-- (d) news_private is closed to every API role.
-- ----------------------------------------------------------------------------

select ok(not has_schema_privilege('anon', 'news_private', 'USAGE')
          and not has_schema_privilege('authenticated', 'news_private', 'USAGE')
          and not has_schema_privilege('service_role', 'news_private', 'USAGE'),
          'no API role can use schema news_private');

select is_empty($$
  select p.oid::regprocedure::text, r
  from pg_proc p join pg_namespace n on n.oid = p.pronamespace,
       unnest(array['anon', 'authenticated', 'service_role']) r
  where n.nspname = 'news_private' and has_function_privilege(r, p.oid, 'EXECUTE')
$$, 'no API role can execute a news_private function');

select tests.as_user('20000000-0000-4000-a000-000000000002');
select throws_ok('select news_private.sync_signal_members()', '42501', null,
                 'a signed-in user cannot run the bridge');

-- ----------------------------------------------------------------------------
-- (e) Signal's staff RPCs refuse News users.
-- ----------------------------------------------------------------------------

select throws_ok($$select public.apply_member_actions('10000000-0000-4000-a000-000000000003',
                   '[{"track": "community", "stage": "left"}]')$$, '42501', null,
                 'apply_member_actions refuses a News user');
select throws_ok($$select public.archive_candidate('10000000-0000-4000-a000-000000000003')$$, '42501', null,
                 'archive_candidate refuses a News user');
select throws_ok($$select public.delete_candidate('10000000-0000-4000-a000-000000000003')$$, '42501', null,
                 'delete_candidate refuses a News user');
select tests.as_postgres();

-- ----------------------------------------------------------------------------
-- (f) Signal's secret key (service_role) has no access to News tables.
-- ----------------------------------------------------------------------------

select is_empty($$
  select n.nspname || '.' || c.relname
  from pg_class c join pg_namespace n on n.oid = c.relnamespace
  where n.nspname in ('news', 'news_private') and c.relkind in ('r', 'p', 'v', 'm', 'S')
    and (has_table_privilege('service_role', c.oid, 'SELECT,INSERT,UPDATE,DELETE,TRUNCATE,REFERENCES,TRIGGER')
         or has_any_column_privilege('service_role', c.oid, 'SELECT,INSERT,UPDATE,REFERENCES'))
$$, 'service_role has no grants on News tables');

select * from finish();
rollback;
