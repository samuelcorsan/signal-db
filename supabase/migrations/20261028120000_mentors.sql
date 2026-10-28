-- ============================================================================
-- MENTORS
--
-- A fourth member track, for the industry people who mentor Exponential's
-- members. Like the community it is in or out, with no stages:
--
--   mentor   joined | left
--
-- Adding someone as a mentor (the "Mentor invite" action in Signal, from the
-- inbox or a candidate's page):
--   * writes mentor:joined, which gives them their own list in Signal;
--     unlike a program invite it does not add them to the community;
--   * sends the mentor_invite email: the Exponential Forum and the WhatsApp
--     group (the text can be edited from Settings like the others);
--   * adds them to the Exponential Friends list (private.exponential_friends),
--     as an operator, unless their address is already on it;
--   * gives them the MENTOR badge on News, through the news-signal-badges job.
--     It outranks the program badges. Leaving the mentors, or being archived,
--     takes it away, as leaving the community does for the community badge.
-- ============================================================================

BEGIN;
-- ----------------------------------------------------------------------------
-- 1. The track
-- ----------------------------------------------------------------------------

ALTER TABLE public.candidate_track_spells
  DROP CONSTRAINT IF EXISTS candidate_track_spells_track_check;
ALTER TABLE public.candidate_track_spells
  ADD CONSTRAINT candidate_track_spells_track_check
  CHECK (track IN ('community', 'launchpad', 'fellowship', 'mentor'));
ALTER TABLE public.candidate_track_events
  DROP CONSTRAINT IF EXISTS cte_stage_valid_for_track;
ALTER TABLE public.candidate_track_events
  ADD CONSTRAINT cte_stage_valid_for_track CHECK (
    (track = 'community'  AND stage IN ('joined', 'left')) OR
    (track = 'mentor'     AND stage IN ('joined', 'left')) OR
    (track = 'launchpad'  AND stage IN ('invited', 'opted_in', 'interview_invited', 'interviewed',
                                        'startup_evaluation', 'accepted', 'rejected')) OR
    (track = 'fellowship' AND stage IN ('invited', 'interview_invited', 'interviewed',
                                        'startup_evaluation', 'accepted', 'rejected'))
  );
-- Same as 20260926120000_add_member_tracks.sql, except that joining the
-- mentors is a no-op for someone already in, as it is for the community.
CREATE OR REPLACE FUNCTION public.apply_member_actions(
  p_candidate_id uuid,
  p_actions      jsonb,
  p_note         text DEFAULT NULL,
  p_metadata     jsonb DEFAULT '{}'::jsonb,
  p_batch_id     uuid DEFAULT NULL
)
RETURNS SETOF public.candidate_track_events
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public, auth
AS $$
DECLARE
  v_actor  uuid;
  v_batch  uuid := COALESCE(p_batch_id, gen_random_uuid());
  v_action jsonb;
  v_track  text;
  v_stage  text;
  v_spell  uuid;
  v_event  public.candidate_track_events;
BEGIN
  PERFORM public.assert_staff();
  BEGIN v_actor := auth.uid(); EXCEPTION WHEN OTHERS THEN v_actor := NULL; END;

  IF jsonb_typeof(p_actions) <> 'array' OR jsonb_array_length(p_actions) = 0 THEN
    RAISE EXCEPTION 'p_actions must be a non-empty array';
  END IF;

  -- Serialize concurrent actions on the same candidate.
  PERFORM 1 FROM public.candidates WHERE candidate_id = p_candidate_id FOR UPDATE;
  IF NOT FOUND THEN
    RAISE EXCEPTION 'candidate % not found', p_candidate_id;
  END IF;

  -- Inviting to a program implies community membership.
  IF EXISTS (
    SELECT 1 FROM jsonb_array_elements(p_actions) a
    WHERE a->>'track' IN ('launchpad', 'fellowship') AND a->>'stage' = 'invited'
  ) AND NOT EXISTS (
    SELECT 1 FROM jsonb_array_elements(p_actions) a WHERE a->>'track' = 'community'
  ) THEN
    p_actions := jsonb_build_array(jsonb_build_object('track', 'community', 'stage', 'joined'))
                 || p_actions;
  END IF;

  FOR v_action IN SELECT * FROM jsonb_array_elements(p_actions) LOOP
    v_track := v_action->>'track';
    v_stage := v_action->>'stage';

    SELECT id INTO v_spell
    FROM public.candidate_track_spells
    WHERE candidate_id = p_candidate_id AND track = v_track AND closed_at IS NULL;

    IF v_track IN ('community', 'mentor') AND v_stage = 'joined' AND v_spell IS NOT NULL THEN
      CONTINUE;  -- already in
    END IF;

    IF v_spell IS NULL THEN
      IF v_stage IN ('left', 'rejected') THEN
        RAISE EXCEPTION 'candidate % is not in %; cannot mark %', p_candidate_id, v_track, v_stage;
      END IF;
      INSERT INTO public.candidate_track_spells (candidate_id, track)
      VALUES (p_candidate_id, v_track)
      RETURNING id INTO v_spell;
    END IF;

    INSERT INTO public.candidate_track_events
      (spell_id, candidate_id, track, stage, actor_id, batch_id, note, metadata)
    VALUES
      (v_spell, p_candidate_id, v_track, v_stage, v_actor, v_batch, p_note, COALESCE(p_metadata, '{}'::jsonb))
    RETURNING * INTO v_event;
    RETURN NEXT v_event;

    IF v_stage IN ('rejected', 'left') THEN
      UPDATE public.candidate_track_spells
      SET closed_at = v_event.occurred_at,
          close_reason = CASE v_stage WHEN 'rejected' THEN 'rejected' ELSE 'left' END
      WHERE id = v_spell;
    END IF;
  END LOOP;
END;
$$;
-- ----------------------------------------------------------------------------
-- 1b. The inbox decision
--
-- An applicant can be made a mentor straight from the inbox.
-- resolve_inbox_event is the same as 20260926130000_inbox_member_actions.sql,
-- except that it accepts 'mentor'.
-- ----------------------------------------------------------------------------

ALTER TABLE public.inbox_events DROP CONSTRAINT IF EXISTS inbox_events_decision_check;
ALTER TABLE public.inbox_events
  ADD CONSTRAINT inbox_events_decision_check CHECK (decision IS NULL OR decision IN (
    -- member-track decisions
    'archived', 'community', 'launchpad', 'fellowship', 'mentor',
    -- legacy funnel decisions, kept for history
    'community_approved', 'rejected'
  ));
CREATE OR REPLACE FUNCTION public.resolve_inbox_event(
  p_event_id       uuid,
  p_decision       text,
  p_actions        jsonb DEFAULT NULL,
  p_archive_reason text DEFAULT NULL,
  p_note           text DEFAULT NULL
)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public, auth
AS $$
DECLARE
  v_event public.inbox_events;
  v_actor uuid;
  v_batch uuid := gen_random_uuid();
  v_archived boolean;
BEGIN
  PERFORM public.assert_staff();
  BEGIN v_actor := auth.uid(); EXCEPTION WHEN OTHERS THEN v_actor := NULL; END;

  SELECT * INTO v_event FROM public.inbox_events WHERE event_id = p_event_id FOR UPDATE;
  IF NOT FOUND THEN
    RAISE EXCEPTION 'inbox event % not found', p_event_id;
  END IF;
  IF v_event.decision IS NOT NULL THEN
    RAISE EXCEPTION 'inbox event % already decided as %', p_event_id, v_event.decision;
  END IF;
  IF v_event.candidate_id IS NULL THEN
    RAISE EXCEPTION 'inbox event % has no candidate', p_event_id;
  END IF;

  IF p_decision = 'archived' THEN
    PERFORM public.archive_candidate(v_event.candidate_id, p_archive_reason, v_batch);
  ELSIF p_decision IN ('community', 'launchpad', 'fellowship', 'mentor') THEN
    IF p_actions IS NULL OR jsonb_typeof(p_actions) <> 'array' OR jsonb_array_length(p_actions) = 0 THEN
      RAISE EXCEPTION 'decision % needs member actions', p_decision;
    END IF;

    -- A new application from an archived candidate is how they come back.
    SELECT archived_at IS NOT NULL INTO v_archived
    FROM public.candidates WHERE candidate_id = v_event.candidate_id;
    IF v_archived THEN
      PERFORM public.unarchive_candidate(v_event.candidate_id, 'reapplied');
    END IF;

    PERFORM public.apply_member_actions(
      v_event.candidate_id,
      p_actions,
      p_note,
      jsonb_build_object('inbox_event_id', p_event_id),
      v_batch
    );
  ELSE
    RAISE EXCEPTION 'unknown decision %', p_decision;
  END IF;

  UPDATE public.inbox_events
  SET decision          = p_decision,
      decided_by        = v_actor,
      decided_at        = now(),
      decision_note     = p_note,
      decision_batch_id = v_batch,
      status            = 'reviewed',
      reviewed_at       = COALESCE(reviewed_at, now()),
      reviewed_by       = COALESCE(reviewed_by, v_actor)
  WHERE event_id = p_event_id;

  -- The decision is about the person, not the form: close their other
  -- undecided applications with it (e.g. a community and a fellowship form).
  UPDATE public.inbox_events
  SET decision          = p_decision,
      decided_by        = v_actor,
      decided_at        = now(),
      decision_note     = p_note,
      decision_batch_id = v_batch,
      status            = 'reviewed',
      reviewed_at       = COALESCE(reviewed_at, now()),
      reviewed_by       = COALESCE(reviewed_by, v_actor)
  WHERE candidate_id = v_event.candidate_id
    AND event_id <> p_event_id
    AND decision IS NULL
    AND event_type IN ('exponential_application', 'fellowship_application',
                       'community_application', 'manual_addition');

  RETURN jsonb_build_object('batch_id', v_batch, 'decision', p_decision);
END;
$$;
-- ----------------------------------------------------------------------------
-- 2. The email
-- ----------------------------------------------------------------------------

ALTER TABLE public.email_templates
  DROP CONSTRAINT IF EXISTS email_templates_action_key_check;
ALTER TABLE public.email_templates
  ADD CONSTRAINT email_templates_action_key_check CHECK (action_key IS NULL OR action_key IN (
    'archive_generic',              -- archive: generic rejection
    'archive_too_old',              -- archive: too senior / too old for the program
    'archive_no_spanish_ties',      -- archive: no ties to Spain
    'archive_not_technical',        -- archive: not technical enough
    'archive_low_effort',           -- archive: low-effort application
    'community_invite',
    'launchpad_invite',             -- launchpad invite with opt-in link
    'launchpad_invite_interview',   -- launchpad invite + interview scheduling
    'launchpad_opted_in',           -- instructions, sent automatically on opt-in
    'fellowship_invite',            -- fellowship invite + interview scheduling
    'interview_invite',             -- repeat interview invite from the candidate view
    'mentor_invite'                 -- welcome as a mentor: forum + WhatsApp
  ));
INSERT INTO public.email_templates (name, subject, body, action_key)
SELECT
  'Mentor Invite',
  'Welcome to Exponential as a mentor, {first_name}!',
  E'Hi {first_name},\n\nThank you for agreeing to mentor at Exponential. We''re very happy to have you on board.\n\nThe best way to get to know our members and see what they''re building is to join both:\n- The [Exponential Forum](https://news.goexponential.org/), where members share what they''re working on. Sign up with this email address and your profile will carry a Mentor badge.\n- Our [WhatsApp group](https://chat.whatsapp.com/E7HWX6GTKsMHClE4nCjprU), where the community talks day to day.\n\nWe''ll also keep you posted on what''s happening at Exponential.\n\nSee you around,\n\nThe Exponential Team',
  'mentor_invite'
WHERE NOT EXISTS (
  SELECT 1 FROM public.email_templates WHERE action_key = 'mentor_invite'
);
-- ----------------------------------------------------------------------------
-- 3. Exponential Friends
--
-- On mentor:joined, add the person to the friends list at their Signal
-- address. Skipped when they have no address or the address is already on
-- the list (they're already a friend, or rejoined the mentors). Leaving the
-- mentors keeps them on the list.
--
-- Runs as its owner (postgres), the only role that can write `private`;
-- nobody can call it directly.
-- ----------------------------------------------------------------------------

CREATE OR REPLACE FUNCTION private.add_mentor_to_friends()
RETURNS trigger
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = ''
AS $$
DECLARE
  v_email  text;
  v_first  text;
  v_last   text;
  v_friend uuid;
BEGIN
  SELECT lower(btrim(c.email)), c.first_name, c.last_name
    INTO v_email, v_first, v_last
  FROM public.candidates c
  WHERE c.candidate_id = NEW.candidate_id;

  -- Same rule as exponential_friend_emails' check, so the insert can't fail it.
  IF coalesce(v_email, '') NOT LIKE '_%@_%.__%'
     OR EXISTS (SELECT 1 FROM private.exponential_friend_emails WHERE email = v_email) THEN
    RETURN NULL;
  END IF;

  INSERT INTO private.exponential_friends
    (first_name, last_name, category, relationship, source, why_relevant)
  VALUES
    (v_first, v_last, 'operator', 'mentor', 'signal', 'Exponential mentor')
  RETURNING id INTO v_friend;

  INSERT INTO private.exponential_friend_emails (friend_id, email, is_primary)
  VALUES (v_friend, v_email, true);
  RETURN NULL;
END;
$$;
REVOKE ALL ON FUNCTION private.add_mentor_to_friends() FROM PUBLIC, anon, authenticated, service_role;
DROP TRIGGER IF EXISTS trg_cte_mentor_friends ON public.candidate_track_events;
CREATE TRIGGER trg_cte_mentor_friends
  AFTER INSERT ON public.candidate_track_events
  FOR EACH ROW
  WHEN (NEW.track = 'mentor' AND NEW.stage = 'joined')
  EXECUTE FUNCTION private.add_mentor_to_friends();
-- ----------------------------------------------------------------------------
-- 4. The News badge
-- ----------------------------------------------------------------------------

ALTER TABLE news.profiles DROP CONSTRAINT IF EXISTS profiles_badge_check;
ALTER TABLE news.profiles ADD CONSTRAINT profiles_badge_check
  CHECK (badge IN ('mentor', 'fellowship', 'launchpad', 'community'));
ALTER TABLE news_private.badge_rules DROP CONSTRAINT IF EXISTS badge_rules_badge_check;
ALTER TABLE news_private.badge_rules ADD CONSTRAINT badge_rules_badge_check
  CHECK (badge IN ('mentor', 'fellowship', 'launchpad', 'community'));
INSERT INTO news_private.badge_rules (source, key, badge) VALUES
  ('track_stage', 'mentor:joined', 'mentor')
ON CONFLICT DO NOTHING;
-- Same as 20261008120200_news_signal_bridge.sql, except that leaving the
-- mentors takes the mentor badge away, as leaving the community does for the
-- community badge.
CREATE OR REPLACE FUNCTION news_private.sync_signal_members() RETURNS integer
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = ''
AS $$
declare
  changed integer;
begin
  with accepted as (
    select a.candidate_id, r.badge, a.activity_timestamp as at
    from public.candidate_activities a
    join news_private.badge_rules r
      on r.source = 'email_template' and r.key = a.metadata ->> 'email_template'
    where a.activity_type = 'email_sent'
    union all
    select e.candidate_id, r.badge, e.occurred_at
    from public.candidate_track_events e
    join news_private.badge_rules r
      on r.source = 'track_stage' and r.key = e.track || ':' || e.stage
  ), membership_now as (
    -- Latest stage in each in-or-out track; its badge is the track's name.
    select distinct on (e.candidate_id, e.track) e.candidate_id, e.track, e.stage
    from public.candidate_track_events e
    where e.track in ('community', 'mentor')
    order by e.candidate_id, e.track, e.occurred_at desc, e.seq desc
  ), members as (
    select c.candidate_id,
           lower(btrim(c.email)) as email,
           array_agg(distinct x.badge order by x.badge) as badges,
           min(x.at) as accepted_at
    from accepted x
    join public.candidates c on c.candidate_id = x.candidate_id
    left join membership_now l on l.candidate_id = x.candidate_id and l.track = x.badge
    where c.archived_at is null
      and coalesce(btrim(c.email), '') <> ''
      and l.stage is distinct from 'left'
    group by c.candidate_id, c.email
  ), upserted as (
    insert into news_private.signal_members as m (candidate_id, email, badges, accepted_at, synced_at)
    select candidate_id, email, badges, accepted_at, now() from members
    on conflict (candidate_id) do update
      set email = excluded.email, badges = excluded.badges,
          accepted_at = excluded.accepted_at, synced_at = now()
      where (m.email, m.badges, m.accepted_at)
            is distinct from (excluded.email, excluded.badges, excluded.accepted_at)
    returning 1
  ), removed as (
    delete from news_private.signal_members m
    where not exists (select 1 from members x where x.candidate_id = m.candidate_id)
    returning 1
  )
  select (select count(*) from upserted) + (select count(*) from removed) into changed;
  return changed;
end
$$;
-- Mentor outranks the programs. Same functions otherwise.
CREATE OR REPLACE FUNCTION news_private.badge_for(p_id uuid) RETURNS text
LANGUAGE sql STABLE
SET search_path = ''
AS $$
  select case when bool_or('mentor' = any (m.badges)) then 'mentor'
              when bool_or('fellowship' = any (m.badges)) then 'fellowship'
              when bool_or('launchpad' = any (m.badges)) then 'launchpad'
              when bool_or('community' = any (m.badges)) then 'community' end
  from news_private.confirmed_emails(p_id) u
  join news_private.signal_members m on m.email = u.email
$$;
CREATE OR REPLACE FUNCTION news_private.apply_badges(p_id uuid DEFAULT NULL) RETURNS integer
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = ''
AS $$
declare
  changed integer;
begin
  with b as (
    select u.id,
           case when bool_or('mentor' = any (m.badges)) then 'mentor'
                when bool_or('fellowship' = any (m.badges)) then 'fellowship'
                when bool_or('launchpad' = any (m.badges)) then 'launchpad'
                when bool_or('community' = any (m.badges)) then 'community' end as badge
    from news_private.confirmed_emails(p_id) u
    join news_private.signal_members m on m.email = u.email
    group by u.id
  )
  update news.profiles p
     set badge = b.badge
    from news.profiles q
    left join b on b.id = q.id
   where p.id = q.id
     and (p_id is null or p.id = p_id)
     and p.badge is distinct from b.badge;
  get diagnostics changed = row_count;
  return changed;
end
$$;
-- The News admin page counts mentors too. The return type changes, so the
-- function is dropped and created again, as news_owner with the same grants.
drop function news.admin_counts();
create function news.admin_counts()
returns table (members int, mentor int, fellowship int, launchpad int, community int, staff int, moderators int)
language plpgsql
stable
security definer
set search_path = ''
as $$
begin
  perform news_private.admin();
  return query
    select count(*)::int,
           (count(*) filter (where p.badge = 'mentor'))::int,
           (count(*) filter (where p.badge = 'fellowship'))::int,
           (count(*) filter (where p.badge = 'launchpad'))::int,
           (count(*) filter (where p.badge = 'community'))::int,
           (count(*) filter (where p.staff))::int,
           (count(*) filter (where p.auth > 0 and not p.is_admin))::int
      from news.profiles p;
end
$$;
alter function news.admin_counts() owner to news_owner;
revoke all on function news.admin_counts() from public, anon, authenticated, service_role;
grant execute on function news.admin_counts() to authenticated;
COMMIT;
