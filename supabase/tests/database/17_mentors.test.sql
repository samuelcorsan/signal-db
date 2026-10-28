-- Mentors: the track, the Friends list, the News badge.
begin;
create extension if not exists pgtap with schema extensions;

select plan(16);

-- Candidates from supabase/seeds/10_signal_synthetic.sql: ada ...01 is a
-- fellow, alan ...03 is in the community.
insert into public.candidates (candidate_id, first_name, last_name, email) values
  ('10000000-0000-4000-a000-000000000021', 'Mia', 'Mentor', ' Mia@Example.com '),
  ('10000000-0000-4000-a000-000000000022', 'Nil', 'Mentor', null),
  ('10000000-0000-4000-a000-000000000023', 'Old', 'Friend', 'old.friend@example.com');

-- The track
select apply_member_actions('10000000-0000-4000-a000-000000000021', '[{"track": "mentor", "stage": "joined"}]');
select is((select count(*) from candidate_open_tracks where candidate_id = '10000000-0000-4000-a000-000000000021' and track = 'mentor'),
          1::bigint, 'joining opens a mentor spell');
select is((select count(*) from candidate_open_tracks where candidate_id = '10000000-0000-4000-a000-000000000021' and track = 'community'),
          0::bigint, 'mentors are not added to the community');
select is((select count(*) from apply_member_actions('10000000-0000-4000-a000-000000000021', '[{"track": "mentor", "stage": "joined"}]')),
          0::bigint, 'joining again is a no-op');
select throws_ok($$select apply_member_actions('10000000-0000-4000-a000-000000000021', '[{"track": "mentor", "stage": "invited"}]')$$,
                 '23514', null, 'mentor has no stages besides joined and left');

-- Exponential Friends
select results_eq($$select f.first_name, f.category, f.relationship, f.source, e.email, e.is_primary
                    from private.exponential_friends f join private.exponential_friend_emails e on e.friend_id = f.id
                    where e.email = 'mia@example.com'$$,
                  $$values ('Mia'::text, 'operator'::text, 'mentor'::text, 'signal'::text, 'mia@example.com'::text, true)$$,
                  'a new mentor is on the Friends list as an operator, at their normalized address');
select is((select count(*) from private.exponential_friend_emails where email = 'mia@example.com'),
          1::bigint, 'and only once');

select lives_ok($$select apply_member_actions('10000000-0000-4000-a000-000000000022', '[{"track": "mentor", "stage": "joined"}]')$$,
                'a mentor without an email can still be added');
select is((select count(*) from private.exponential_friends where first_name = 'Nil'),
          0::bigint, 'but is not put on the Friends list');

with f as (insert into private.exponential_friends (first_name, category) values ('Old', 'investor') returning id)
insert into private.exponential_friend_emails (friend_id, email, is_primary) select id, 'old.friend@example.com', true from f;
select apply_member_actions('10000000-0000-4000-a000-000000000023', '[{"track": "mentor", "stage": "joined"}]');
select results_eq($$select f.category from private.exponential_friends f
                    join private.exponential_friend_emails e on e.friend_id = f.id where e.email = 'old.friend@example.com'$$,
                  $$values ('investor'::text)$$,
                  'someone already on the Friends list is left as they are');

-- The inbox
insert into public.inbox_events (event_id, event_type, candidate_id)
values ('20000000-0000-4000-a000-000000000021', 'exponential_application', '10000000-0000-4000-a000-000000000023');
select is(resolve_inbox_event('20000000-0000-4000-a000-000000000021', 'mentor',
                              '[{"track": "mentor", "stage": "joined"}]') ->> 'decision',
          'mentor', 'an application can be decided as mentor');
select is((select decision from public.inbox_events where event_id = '20000000-0000-4000-a000-000000000021'),
          'mentor', 'and the decision is recorded');

-- The email
select is((select count(*) from public.email_templates where action_key = 'mentor_invite'),
          1::bigint, 'the mentor_invite template exists');

-- The News badge
select news_private.sync_signal_members();
select is((select badges from news_private.signal_members where email = 'mia@example.com'),
          '{mentor}'::text[], 'a mentor gets the mentor badge');

select apply_member_actions('10000000-0000-4000-a000-000000000001', '[{"track": "mentor", "stage": "joined"}]');
select news_private.sync_signal_members();
select is((select badges from news_private.signal_members where email = 'ada@example.com'),
          '{community,fellowship,mentor}'::text[], 'a fellow who mentors has both');

select apply_member_actions('10000000-0000-4000-a000-000000000021', '[{"track": "mentor", "stage": "left"}]');
select news_private.sync_signal_members();
select is_empty($$select 1 from news_private.signal_members where email = 'mia@example.com'$$,
                'leaving the mentors takes the badge away');

select ok(pg_get_function_result('news.admin_counts()'::regprocedure) like '%mentor integer%',
          'the News admin counts mentors');

select * from finish();
rollback;
