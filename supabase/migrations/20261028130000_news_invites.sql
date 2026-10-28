-- ============================================================================
-- Exponential News: joining by invitation.
--
-- News stops being open to anyone with an email. A profile (news.claim_profile)
-- is created only for someone who is let in:
--
--   * Exponential's own: Signal's staff, and anyone Signal accepted (the people
--     with a badge waiting; mentors are told to sign up with their email);
--   * an address an admin let in by hand (news_private.allowed_emails), the
--     override for whoever has neither;
--   * anyone else with an invitation: the link of a member who still has room.
--
-- Every member has one invitation, a code in a link, that lets in five
-- people. A day after the fifth joins, it lets in five more: ten in total,
-- unless an admin gives someone extra places (news.admin_set_invite_extra),
-- which count at once. Staff and admins have no limit. A member can change
-- their code (one that leaked): the old one stops working, and whoever
-- already joined still counts. Who joined with whose invitation stays, and
-- is the invitations leaderboard.
-- ============================================================================

begin;

-- ----------------------------------------------------------------------------
-- Tables
-- ----------------------------------------------------------------------------

-- Each member's code, one at a time: eight characters from an alphabet
-- without look-alikes (no O or 0, no I or 1), shown as XXXX-XXXX.
create table news_private.invites (
  code        text primary key check (code ~ '^[A-HJ-NP-Z2-9]{8}$'),
  inviter     uuid not null unique references news.profiles (id) on delete cascade,
  created_at  timestamptz not null default now()
);
comment on table news_private.invites is
  'Each member''s invitation code (news.make_invite), which lets people in through news.claim_profile.';

-- Who joined with whose invitation. A deleted newcomer leaves used_by null
-- and the place still taken.
create table news_private.invite_uses (
  id        bigint generated always as identity primary key,
  inviter   uuid not null references news.profiles (id) on delete cascade,
  used_by   uuid unique references news.profiles (id) on delete set null,
  used_at   timestamptz not null default now()
);
create index invite_uses_inviter on news_private.invite_uses (inviter, used_at);
comment on table news_private.invite_uses is
  'Every account made with an invitation: whose it was, and when.';

-- Places an admin gave someone on top of the ten.
create table news_private.invite_extra (
  profile_id  uuid primary key references news.profiles (id) on delete cascade,
  extra       int not null check (extra between 1 and 1000),
  set_by      uuid references news.profiles (id) on delete set null,
  set_at      timestamptz not null default now()
);
comment on table news_private.invite_extra is
  'Invitation places an admin added to a member''s, on top of the ten (news.admin_set_invite_extra).';

-- Addresses an admin let in without an invitation.
create table news_private.allowed_emails (
  email     text primary key check (email = lower(btrim(email)) and email ~ '^[^\s@]+@[^\s@]+\.[^\s@]+$'),
  note      text not null default '' check (char_length(note) <= 140),
  added_by  uuid references news.profiles (id) on delete set null,
  added_at  timestamptz not null default now()
);
comment on table news_private.allowed_emails is
  'Emails that may join News without an invitation: the admins'' override (news.admin_allow_email).';

alter table news_private.invites owner to news_owner;
alter table news_private.invite_uses owner to news_owner;
alter table news_private.allowed_emails owner to news_owner;
alter table news_private.invite_extra owner to news_owner;
alter table news_private.invite_extra enable row level security;
alter table news_private.invites enable row level security;
alter table news_private.invite_uses enable row level security;
alter table news_private.allowed_emails enable row level security;
revoke all on news_private.invites, news_private.invite_uses, news_private.allowed_emails, news_private.invite_extra
from public, anon, authenticated;

-- ----------------------------------------------------------------------------
-- Helpers
-- ----------------------------------------------------------------------------

-- What someone typed or pasted, as it is stored: "abcd-2345" is ABCD2345.
create function news_private.invite_code(p_code text) returns text
language sql immutable
set search_path = ''
as $$
  select upper(regexp_replace(coalesce(p_code, ''), '[^A-Za-z0-9]', '', 'g'))
$$;
alter function news_private.invite_code(text) owner to news_owner;

-- Eight random characters. The bytes come from gen_random_uuid() (a strong
-- random source), skipping the ones a v4 uuid fixes; 32 letters divide 256,
-- so each is equally likely.
create function news_private.new_invite_code() returns text
language sql volatile
set search_path = ''
as $$
  select string_agg(substr('ABCDEFGHJKLMNPQRSTUVWXYZ23456789', get_byte(b, i) % 32 + 1, 1), '' order by i)
    from (select uuid_send(gen_random_uuid()) as b) r,
         unnest(array[0, 1, 2, 3, 4, 5, 10, 11]) as i
$$;
alter function news_private.new_invite_code() owner to news_owner;

-- Let in without an invitation: staff, someone Signal accepted, or an
-- address an admin allowed. Only a confirmed email counts.
create function news_private.admitted(p_id uuid) returns boolean
language sql stable
set search_path = ''
as $$
  select p_id in (select news_private.signal_staff())
      or news_private.badge_for(p_id) is not null
      or exists (select 1 from news_private.confirmed_emails(p_id) u
                   join news_private.allowed_emails a on a.email = u.email)
$$;
alter function news_private.admitted(uuid) owner to news_owner;

-- How many people someone's invitation let in, how many it may (null: no
-- limit; 0 for someone hidden by moderation), when the second five open,
-- while they're on their way, and the extra places an admin gave.
create function news_private.invite_allowance(p_id uuid)
returns table (used int, allowed int, more_at timestamptz, extra int)
language sql stable
set search_path = ''
as $$
  with mine as (
    select u.used_at, row_number() over (order by u.used_at, u.id) as n
      from news_private.invite_uses u where u.inviter = p_id
  ), fifth as (
    select (select m.used_at from mine m where m.n = 5) as at
  )
  select (select count(*) from mine)::int,
         case when p.ignored then 0
              when p.staff or p.is_admin then null
              when f.at <= now() - interval '1 day' then 10 + coalesce(x.extra, 0)
              else 5 + coalesce(x.extra, 0) end,
         case when not (p.ignored or p.staff or p.is_admin) and f.at > now() - interval '1 day'
              then f.at + interval '1 day' end,
         coalesce(x.extra, 0)
    from news.profiles p
    cross join fifth f
    left join news_private.invite_extra x on x.profile_id = p.id
   where p.id = p_id
$$;
alter function news_private.invite_allowance(uuid) owner to news_owner;

-- Whose a code is, and whether it has room for one more.
create function news_private.invite_open(p_code text)
returns table (inviter uuid, username text, open boolean)
language sql stable
set search_path = ''
as $$
  select i.inviter, p.username, (a.allowed is null or a.used < a.allowed)
    from news_private.invites i
    join news.profiles p on p.id = i.inviter
    cross join lateral news_private.invite_allowance(i.inviter) a
   where i.code = news_private.invite_code(p_code)
$$;
alter function news_private.invite_open(text) owner to news_owner;

-- ----------------------------------------------------------------------------
-- A member's invitation
-- ----------------------------------------------------------------------------

-- The signed-in member's invitation: its code (null until they make one),
-- how many it let in, how many it may, when more open, and whether more
-- are still to come (the second five, not yet open).
create function news.invite_status()
returns table (code text, used int, allowed int, more_at timestamptz, more_later boolean)
language sql stable
security definer
set search_path = ''
as $$
  select (select i.code from news_private.invites i where i.inviter = news.uid()), a.used, a.allowed, a.more_at,
         coalesce(a.allowed - a.extra = 5, false)
    from news_private.invite_allowance(news.uid()) a
$$;

-- Who joined with it, newest first.
create function news.my_invitees()
returns table (username text, github text, photo text, used_at timestamptz)
language sql stable
security definer
set search_path = ''
as $$
  select p.username, p.github, p.photo, u.used_at
    from news_private.invite_uses u
    left join news.profiles p on p.id = u.used_by
   where u.inviter = news.uid()
   order by u.used_at desc, u.id desc
$$;

-- The member's code: the one they have, or a new one. p_new changes it
-- (one that leaked): the old one stops letting anyone in. Members hidden by
-- moderation have none.
create function news.make_invite(p_new boolean default false) returns text
language plpgsql
security definer
set search_path = ''
as $$
declare
  me news.profiles := news_private.me();
  c text;
begin
  if me.ignored then
    raise exception 'invite' using errcode = '42501';
  end if;
  -- One at a time per member, so two presses make one code.
  perform 1 from news.profiles where id = me.id for update;
  select i.code into c from news_private.invites i where i.inviter = me.id;
  if c is not null and not p_new then
    return c;
  end if;
  loop
    c := news_private.new_invite_code();
    begin
      insert into news_private.invites (code, inviter) values (c, me.id)
      on conflict (inviter) do update set code = excluded.code, created_at = now();
      return c;
    exception when unique_violation then
      -- Another member's code is this one already: draw again.
    end;
  end loop;
end
$$;

-- Who a code is from, while it can still let someone in: what the join
-- page says. Anyone may ask; a code is 40 random bits, so asking doesn't
-- find them.
create function news.invite_from(p_code text) returns text
language sql stable
security definer
set search_path = ''
as $$
  select o.username from news_private.invite_open(p_code) o where o.open
$$;

-- Whether the signed-in user, who has no profile yet, needs a code to join.
create function news.needs_invite() returns boolean
language sql stable
security definer
set search_path = ''
as $$
  select not news_private.admitted(news.uid())
$$;

-- ----------------------------------------------------------------------------
-- Joining
-- ----------------------------------------------------------------------------

-- As in 20261016180000_news_downvotes_handles.sql, except that whoever isn't
-- let in by news_private.admitted() must bring the code of an invitation
-- with room left ('invite' if there is no such code, 'full' if it has
-- none), and takes a place on it.
drop function news.claim_profile(text);
create function news.claim_profile(p_username text, p_invite text default null) returns void
language plpgsql
security definer
set search_path = ''
as $$
declare
  uid uuid := news.uid();
  host uuid;
  room boolean;
begin
  if uid is null then
    raise exception 'login' using errcode = '42501';
  end if;
  if exists (select 1 from news.profiles where id = uid) then
    return;
  end if;
  if p_username is null or p_username !~ '^[A-Za-z0-9_][A-Za-z0-9_-]{1,14}$' then
    raise exception 'name' using errcode = '22023';
  end if;
  if exists (select 1 from news.past_usernames where username = lower(p_username)) then
    raise exception 'taken' using errcode = '22023';
  end if;
  if not news_private.admitted(uid) then
    select i.inviter into host from news_private.invites i where i.code = news_private.invite_code(p_invite);
    if host is null then
      raise exception 'invite' using errcode = '22023';
    end if;
    -- One newcomer at a time per invitation, so the last place goes once.
    perform 1 from news.profiles where id = host for update;
    select o.open into room from news_private.invite_open(p_invite) o;
    if not coalesce(room, false) then
      raise exception 'full' using errcode = '22023';
    end if;
  end if;
  begin
    insert into news.profiles (id, username) values (uid, p_username);
  exception when unique_violation then
    raise exception 'taken' using errcode = '22023';
  end;
  if host is not null then
    insert into news_private.invite_uses (inviter, used_by) values (host, uid);
  end if;
  perform news_private.apply_badges(uid);
  perform news_private.apply_staff(uid);
end
$$;

-- ----------------------------------------------------------------------------
-- The leaderboard
-- ----------------------------------------------------------------------------

-- Who brought the most people, with what anyone may read of them. Ties go
-- to whoever got there first.
create function news.invite_leaders(p_limit int default 30)
returns table (username text, badge text, staff boolean, github text, photo text, created_at timestamptz, invited int)
language sql stable
security definer
set search_path = ''
as $$
  select p.username, p.badge, p.staff, p.github, p.photo, p.created_at, count(*)::int
    from news_private.invite_uses u join news.profiles p on p.id = u.inviter
   group by p.id
   order by count(*) desc, max(u.used_at), p.username
   limit least(greatest(coalesce(p_limit, 30), 1), 100)
$$;

-- ----------------------------------------------------------------------------
-- The override: addresses admins let in
-- ----------------------------------------------------------------------------

create function news.admin_allow_email(p_email text, p_note text default '') returns void
language plpgsql
security definer
set search_path = ''
as $$
declare
  me news.profiles := news_private.admin();
  e text := lower(btrim(coalesce(p_email, '')));
begin
  if e !~ '^[^\s@]+@[^\s@]+\.[^\s@]+$' then
    raise exception 'email' using errcode = '22023';
  end if;
  p_note := btrim(coalesce(p_note, ''));
  if char_length(p_note) > 140 or p_note ~ '[<>]' then
    raise exception 'note' using errcode = '22023';
  end if;
  insert into news_private.allowed_emails (email, note, added_by) values (e, p_note, me.id)
  on conflict (email) do update set note = excluded.note;
end
$$;

-- Letting an address out again doesn't touch an account already made with it.
create function news.admin_disallow_email(p_email text) returns void
language plpgsql
security definer
set search_path = ''
as $$
begin
  perform news_private.admin();
  delete from news_private.allowed_emails where email = lower(btrim(coalesce(p_email, '')));
end
$$;

-- The allowed addresses, newest first: who added each, and the username of
-- whoever has joined with it.
create function news.admin_allowed_emails()
returns table (email text, note text, added_by text, added_at timestamptz, joined text)
language plpgsql
stable
security definer
set search_path = ''
as $$
#variable_conflict use_column
begin
  perform news_private.admin();
  return query
    with joined as (
      select u.email, min(p.username) as username
        from news_private.confirmed_emails() u join news.profiles p on p.id = u.id
       group by u.email
    )
    select a.email, a.note, b.username, a.added_at, j.username
      from news_private.allowed_emails a
      left join news.profiles b on b.id = a.added_by
      left join joined j on j.email = a.email
     order by a.added_at desc, a.email;
end
$$;

-- Extra places for one member, on top of the ten; 0 takes them away.
create function news.admin_set_invite_extra(p_id uuid, p_extra int) returns void
language plpgsql
security definer
set search_path = ''
as $$
declare
  me news.profiles := news_private.admin();
begin
  if p_extra is null or p_extra < 0 or p_extra > 1000 then
    raise exception 'extra' using errcode = '22023';
  end if;
  if not exists (select 1 from news.profiles where id = p_id) then
    raise exception 'profile' using errcode = '22023';
  end if;
  if p_extra = 0 then
    delete from news_private.invite_extra where profile_id = p_id;
  else
    insert into news_private.invite_extra (profile_id, extra, set_by) values (p_id, p_extra, me.id)
    on conflict (profile_id) do update set extra = excluded.extra, set_by = excluded.set_by, set_at = now();
  end if;
end
$$;

-- One member's invitation, for an admin on their profile.
create function news.admin_invite_of(p_id uuid)
returns table (used int, allowed int, more_at timestamptz, extra int)
language plpgsql
stable
security definer
set search_path = ''
as $$
begin
  perform news_private.admin();
  return query select * from news_private.invite_allowance(p_id);
end
$$;

-- How invitations are going: members with a code, people who joined with
-- one, and addresses let in by hand.
create function news.admin_invite_counts()
returns table (made int, used int, allowed int)
language plpgsql
stable
security definer
set search_path = ''
as $$
begin
  perform news_private.admin();
  return query
    select (select count(*) from news_private.invites)::int,
           (select count(*) from news_private.invite_uses)::int,
           (select count(*) from news_private.allowed_emails)::int;
end
$$;

-- ----------------------------------------------------------------------------
-- Owners and grants
-- ----------------------------------------------------------------------------

alter function news.invite_status() owner to news_owner;
alter function news.my_invitees() owner to news_owner;
alter function news.make_invite(boolean) owner to news_owner;
alter function news.invite_from(text) owner to news_owner;
alter function news.needs_invite() owner to news_owner;
alter function news.claim_profile(text, text) owner to news_owner;
alter function news.invite_leaders(int) owner to news_owner;
alter function news.admin_allow_email(text, text) owner to news_owner;
alter function news.admin_disallow_email(text) owner to news_owner;
alter function news.admin_allowed_emails() owner to news_owner;
alter function news.admin_invite_counts() owner to news_owner;
alter function news.admin_set_invite_extra(uuid, int) owner to news_owner;
alter function news.admin_invite_of(uuid) owner to news_owner;

revoke all on function
  news_private.invite_code(text), news_private.new_invite_code(), news_private.admitted(uuid),
  news_private.invite_allowance(uuid), news_private.invite_open(text),
  news.invite_status(), news.my_invitees(), news.make_invite(boolean),
  news.invite_from(text), news.needs_invite(), news.claim_profile(text, text), news.invite_leaders(int),
  news.admin_allow_email(text, text), news.admin_disallow_email(text), news.admin_allowed_emails(),
  news.admin_invite_counts(), news.admin_set_invite_extra(uuid, int), news.admin_invite_of(uuid)
from public, anon, authenticated, service_role;

grant execute on function news.invite_from(text), news.invite_leaders(int) to anon, authenticated;
grant execute on function
  news.invite_status(), news.my_invitees(), news.make_invite(boolean),
  news.needs_invite(), news.claim_profile(text, text),
  news.admin_allow_email(text, text), news.admin_disallow_email(text), news.admin_allowed_emails(),
  news.admin_invite_counts(), news.admin_set_invite_extra(uuid, int), news.admin_invite_of(uuid)
to authenticated;

commit;
