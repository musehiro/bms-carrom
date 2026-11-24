-- BMS Carrom v11 — P2P online play: matchmaking queue + matches + presence
-- Run this in the Supabase dashboard SQL editor (see docs/supabase-setup.md).
-- DO NOT run against the live project from an agent task — a human runs it
-- in the dashboard and confirms each statement. No keys in this file.
--
-- What this adds on top of supabase/schema.sql (v7 profiles + invites):
--   matchmaking_queue : one row per searching player (random matchmaking)
--   matches           : one row per formed match — the "room" (random or invite)
--   presence          : one row per online player (lobby live-player list, §11)
--   find_match() / create_match_from_invites() : security-definer RPCs that
--     pair players ATOMICALLY (client-side matching would race and
--     double-book the same opponent). Stakes are validated against
--     profiles.coins inside the RPCs — a modified client cannot invent coins.
--   profiles.match_points : lifetime per-coin match points (v11 plan §4).
--
-- Privacy (same rule as v7): the queue/matches/presence rows contain
-- display name + level + stake band ONLY. Gmail is never in these tables
-- and is never shown to other players.

-- ------------------------------------------------------- matchmaking_queue
create table if not exists public.matchmaking_queue (
  id uuid primary key references auth.users (id) on delete cascade,
  display_name text not null,
  level integer not null default 1,
  "table" integer not null default 0,   -- stake band (Stakes.band_for_stake)
  stake integer not null default 0,      -- the player's own virtual-coin stake
  mode text not null check (mode in ('2p', '4p')),
  created_at timestamptz not null default now()
);
create index if not exists matchmaking_queue_lookup_idx
  on public.matchmaking_queue (mode, "table", created_at);

-- ----------------------------------------------------------------- matches
create table if not exists public.matches (
  id uuid primary key default gen_random_uuid(),
  group_id uuid,                          -- set for invite matches (the invites group_id); null for random
  mode text not null check (mode in ('2p', '4p')),
  "table" integer not null default 0,
  player_ids uuid[] not null,             -- for RLS: auth.uid() = ANY(player_ids)
  players jsonb not null,                 -- [{id, name, level, stake, seat}]
  status text not null default 'waiting'  -- waiting -> playing -> finished | expired
    check (status in ('waiting', 'playing', 'finished', 'expired')),
  created_at timestamptz not null default now()
);
create index if not exists matches_players_idx on public.matches using gin (player_ids);
create index if not exists matches_group_idx on public.matches (group_id);
create index if not exists matches_waiting_idx on public.matches (status, created_at);

-- ---------------------------------------------------------------- presence
-- §11 online lobby: one row per online player, heartbeat ~30 s.
-- Rows older than ~90 s are treated as offline (client-side filter).
-- status: 'online' | 'in_match'. Name + level + status ONLY — never
-- Gmail, never coins.
create table if not exists public.presence (
  id uuid primary key references auth.users (id) on delete cascade,
  display_name text not null,
  level integer not null default 1,
  status text not null default 'online' check (status in ('online', 'in_match')),
  updated_at timestamptz not null default now()
);
create index if not exists presence_updated_idx on public.presence (updated_at desc);

-- ------------------------------------------------- match_points on profiles
-- v11 plan §4: lifetime per-coin match points, synced to the cloud so a
-- reinstall keeps them (local Save.match_points is the source of truth
-- until the client upsert includes this column — see docs/p2p-online.md).
alter table public.profiles
  add column if not exists match_points integer not null default 0;

-- ---------------------------------------------------------------------- RLS
alter table public.matchmaking_queue enable row level security;
alter table public.matches enable row level security;
alter table public.presence enable row level security;

-- Queue: a player may INSERT/DELETE only their own row; SELECT is open
-- to authenticated users (rows hold name + level + stake band only).
drop policy if exists "queue insert own row" on public.matchmaking_queue;
create policy "queue insert own row" on public.matchmaking_queue
  for insert to authenticated with check (auth.uid() = id);
drop policy if exists "queue delete own row" on public.matchmaking_queue;
create policy "queue delete own row" on public.matchmaking_queue
  for delete to authenticated using (auth.uid() = id);
drop policy if exists "queue read for signed-in users" on public.matchmaking_queue;
create policy "queue read for signed-in users" on public.matchmaking_queue
  for select to authenticated using (true);

-- Matches: SELECT only when I am one of the players. INSERT/UPDATE only
-- via the security-definer RPCs below — there is deliberately NO
-- insert/update policy for `authenticated`, so direct writes fail.
drop policy if exists "matches read for players" on public.matches;
create policy "matches read for players" on public.matches
  for select to authenticated using (auth.uid() = ANY(player_ids));

-- Presence: anyone signed in can read the lobby list; only the owner
-- can insert/update their own row (the heartbeat upsert).
drop policy if exists "presence read for signed-in users" on public.presence;
create policy "presence read for signed-in users" on public.presence
  for select to authenticated using (true);
drop policy if exists "presence upsert own row" on public.presence;
create policy "presence upsert own row" on public.presence
  for insert to authenticated with check (auth.uid() = id);
drop policy if exists "presence update own row" on public.presence;
create policy "presence update own row" on public.presence
  for update to authenticated using (auth.uid() = id) with check (auth.uid() = id);
drop policy if exists "presence delete own row" on public.presence;
create policy "presence delete own row" on public.presence
  for delete to authenticated using (auth.uid() = id);

-- ---------------------------------------------------------------- find_match
-- Atomic random pairing. The caller MUST have queued first (their own
-- queue row must exist). 2p: pair with the oldest other row on the same
-- mode + table within ±2 levels (±4 when p_widen). 4p: collect 3 others
-- (4 total) on the same band within the window of the caller's level.
-- Stakes are validated against profiles.coins; a row whose stake is
-- above its owner's balance is deleted and the call returns unmatched.
create or replace function public.find_match(p_mode text, p_widen boolean default false)
returns jsonb
language plpgsql security definer as $$
declare
  me public.matchmaking_queue%rowtype;
  window_size int := case when p_widen then 4 else 2 end;
  need int := case when p_mode = '4p' then 3 else 1 end;
  others public.matchmaking_queue[];
  opp public.matchmaking_queue%rowtype;
  all_players public.matchmaking_queue[];
  coins_ok boolean := true;
  bad_id uuid;
  prof public.profiles%rowtype;
  match_id uuid;
  players_json jsonb := '[]'::jsonb;
  i int;
begin
  select * into me from public.matchmaking_queue where id = auth.uid();
  if not found then
    return jsonb_build_object('matched', false, 'error', 'You are not in the queue.');
  end if;

  -- Oldest other rows on the same mode + band within the level window.
  select array_agg(q order by q.created_at)
    into others
    from public.matchmaking_queue q
    where q.mode = p_mode
      and q."table" = me."table"
      and q.id <> me.id
      and abs(q.level - me.level) <= window_size;

  if others is null or array_length(others, 1) is null or array_length(others, 1) < need then
    return jsonb_build_object('matched', false);
  end if;

  -- The pairing set: me first (seat 0), then the oldest others in
  -- queue order (seats 1..). Queue order = array order from above.
  all_players := array[me];
  for i in 1..need loop
    all_players := array_append(all_players, others[i]);
  end loop;

  -- Validate every stake against the owner's real coin balance.
  for i in 1..array_length(all_players, 1) loop
    select * into prof from public.profiles where id = all_players[i].id;
    if not found or all_players[i].stake < 0 or all_players[i].stake > coalesce(prof.coins, 0) then
      coins_ok := false;
      bad_id := all_players[i].id;
      exit;
    end if;
  end loop;
  if not coins_ok then
    delete from public.matchmaking_queue where id = bad_id;
    return jsonb_build_object('matched', false, 'error', 'A player staked more coins than they own.');
  end if;

  -- Build the players array (seat order = queue order).
  for i in 1..array_length(all_players, 1) loop
    players_json := players_json || jsonb_build_object(
      'id', all_players[i].id,
      'name', all_players[i].display_name,
      'level', all_players[i].level,
      'stake', all_players[i].stake,
      'seat', i - 1);
  end loop;

  insert into public.matches (group_id, mode, "table", player_ids, players, status)
  values (null, p_mode, me."table",
          (select array_agg(p.id) from unnest(all_players) as p),
          players_json, 'waiting')
  returning id into match_id;

  delete from public.matchmaking_queue
    where id = any (select array_agg(p.id) from unnest(all_players) as p);

  return jsonb_build_object('matched', true, 'match_id', match_id, 'players', players_json);
end;
$$;

-- ------------------------------------------------- create_match_from_invites
-- Friend invites: build the matches row from an invites group once every
-- row is accepted. Idempotent — if a matches row already exists for this
-- group_id, it is returned instead of creating a second one (both sides
-- call this). Inviter = seat 0, invitees in invite order (same order as
-- Friends.group_players). Stakes validated against profiles.coins.
create or replace function public.create_match_from_invites(p_group_id uuid)
returns jsonb
language plpgsql security definer as $$
declare
  existing public.matches%rowtype;
  inv_rows public.invites[];
  inv public.invites%rowtype;
  inviter_id uuid;
  inviter_name text;
  inviter_level int;
  inviter_stake int;
  players_json jsonb := '[]'::jsonb;
  ids uuid[] := '{}';
  prof public.profiles%rowtype;
  match_id uuid;
  seat int := 0;
  i int;
begin
  select * into existing from public.matches where group_id = p_group_id limit 1;
  if found then
    return jsonb_build_object('ok', true, 'match_id', existing.id, 'players', existing.players);
  end if;

  select array_agg(r order by r.created_at)
    into inv_rows
    from public.invites r
    where r.group_id = p_group_id;

  if inv_rows is null or array_length(inv_rows, 1) is null then
    return jsonb_build_object('ok', false, 'error', 'No invites in this group.');
  end if;

  -- Every row must be accepted before the match can form.
  for i in 1..array_length(inv_rows, 1) loop
    if inv_rows[i].status <> 'accepted' then
      return jsonb_build_object('ok', false, 'error', 'Not everyone has accepted yet.');
    end if;
  end loop;

  inviter_id := inv_rows[1].from_id;
  inviter_name := inv_rows[1].from_name;
  inviter_stake := inv_rows[1].stake;

  -- Inviter's level comes from their profile (the invite row has no level).
  select * into prof from public.profiles where id = inviter_id;
  inviter_level := case when found then (prof.xp / 500 + 1) else 1 end;
  if not found or inviter_stake < 0 or inviter_stake > coalesce(prof.coins, 0) then
    return jsonb_build_object('ok', false, 'error', 'The inviter staked more coins than they own.');
  end if;

  players_json := players_json || jsonb_build_object(
    'id', inviter_id, 'name', inviter_name,
    'level', inviter_level, 'stake', inviter_stake, 'seat', 0);
  ids := array_append(ids, inviter_id);
  seat := 1;

  for i in 1..array_length(inv_rows, 1) loop
    inv := inv_rows[i];
    select * into prof from public.profiles where id = inv.to_id;
    if not found or inv.stake < 0 or inv.stake > coalesce(prof.coins, 0) then
      return jsonb_build_object('ok', false, 'error', 'A player staked more coins than they own.');
    end if;
    players_json := players_json || jsonb_build_object(
      'id', inv.to_id, 'name', inv.to_name,
      'level', (prof.xp / 500 + 1), 'stake', inv.stake, 'seat', seat);
    ids := array_append(ids, inv.to_id);
    seat := seat + 1;
  end loop;

  insert into public.matches (group_id, mode, "table", player_ids, players, status)
  values (p_group_id,
          inv_rows[1].mode,
          0, -- invite matches are not stake-banded; the band is 0
          ids, players_json, 'waiting')
  returning id into match_id;

  return jsonb_build_object('ok', true, 'match_id', match_id, 'players', players_json);
end;
$$;

-- ----------------------------------------------------------------- Realtime
-- Publication for `matches` (for later use — a postgres_changes
-- subscription is NOT the v11 signalling path; signalling rides
-- Broadcast, and match discovery polls PostgREST, per the plan).
-- Note: postgres_changes filters are per-column equality and
-- player_ids is an array, so there is no clean per-player filter —
-- that is why v11 polls instead of subscribing.
alter publication supabase_realtime add table public.matches;
alter publication supabase_realtime add table public.presence;
