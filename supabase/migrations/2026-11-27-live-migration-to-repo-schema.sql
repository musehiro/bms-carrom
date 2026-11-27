-- ==========================================================================
-- BMS Carrom — MIGRATE the LIVE project qigrifiqtarjgklfxmfg to the repo schema
-- Repo: branch nana/single-colour-pieces-loading @ 3d7ccbc
--      supabase/schema.sql (v7) + supabase/schema-p2p.sql
-- Run in the Supabase dashboard SQL Editor, top to bottom, in order.
-- LIVE PROJECT ONLY. Never run against hyhlhngybzwnungnshff (dead project).
--
-- What this does: the live tables are a DIFFERENT, older design (1v1 only,
-- classic/blitz/tournament, no groups, no coins/XP, presence keyed by
-- user_id). This adds the repo columns, backfills them from the old data,
-- replaces the old functions + CHECK constraints + RLS policies, and swaps
-- the presence PK from user_id to id.
--
-- Safety: NOTHING is dropped except old function overloads, old CHECK
-- constraints on mode/status, and the presence PK. Old columns are KEPT
-- as harmless extras. Existing rows are preserved and backfilled.
-- Every statement is idempotent or guarded (IF NOT EXISTS / IF EXISTS /
-- COALESCE backfills), so the script can be re-run safely if it stops
-- halfway. If any single statement errors, fix that step before continuing.
--
-- BEFORE running, record row counts to verify afterwards:
--   SELECT 'profiles', count(*) FROM public.profiles
--     UNION ALL SELECT 'invites', count(*) FROM public.invites
--     UNION ALL SELECT 'matchmaking_queue', count(*) FROM public.matchmaking_queue
--     UNION ALL SELECT 'matches', count(*) FROM public.matches
--     UNION ALL SELECT 'presence', count(*) FROM public.presence;
-- ==========================================================================

-- ============================================================== 1. PROFILES
-- Live has: id, username (unique), created_at, match_points.
-- Repo wants: id, gmail, display_name, coins, xp, matches_played,
-- matches_won, online_wins, queens_covered, owned_boards, owned_strikers,
-- equipped_board, equipped_striker, created_at, updated_at, match_points.
-- The app upserts ALL of these on every sign-in (Supabase.profile_row),
-- and reads gmail/display_name/coins/xp back on login — so all must exist.

-- 1a. Add the repo columns. Defaults make this safe on existing rows.
ALTER TABLE public.profiles
  ADD COLUMN IF NOT EXISTS gmail text,
  ADD COLUMN IF NOT EXISTS display_name text,
  ADD COLUMN IF NOT EXISTS coins integer NOT NULL DEFAULT 1000,
  ADD COLUMN IF NOT EXISTS xp integer NOT NULL DEFAULT 0,
  ADD COLUMN IF NOT EXISTS matches_played integer NOT NULL DEFAULT 0,
  ADD COLUMN IF NOT EXISTS matches_won integer NOT NULL DEFAULT 0,
  ADD COLUMN IF NOT EXISTS online_wins integer NOT NULL DEFAULT 0,
  ADD COLUMN IF NOT EXISTS queens_covered integer NOT NULL DEFAULT 0,
  ADD COLUMN IF NOT EXISTS owned_boards jsonb NOT NULL DEFAULT '["classic"]'::jsonb,
  ADD COLUMN IF NOT EXISTS owned_strikers jsonb NOT NULL DEFAULT '["classic"]'::jsonb,
  ADD COLUMN IF NOT EXISTS equipped_board text NOT NULL DEFAULT 'classic',
  ADD COLUMN IF NOT EXISTS equipped_striker text NOT NULL DEFAULT 'classic',
  ADD COLUMN IF NOT EXISTS updated_at timestamptz NOT NULL DEFAULT now();
-- match_points already exists on live (integer NOT NULL DEFAULT 0) — keep it.
-- username stays as a harmless extra (the code never reads/writes it).

-- 1b. Backfill display_name from the old username (every live row has one).
UPDATE public.profiles SET display_name = username WHERE display_name IS NULL;

-- 1c. Backfill gmail from the Auth user record. The dashboard SQL editor
--     runs as postgres, which can read auth.users. Rows whose auth user
--     has no email stay NULL here — the app's next profile upsert fills
--     gmail by itself, so this is best-effort, not blocking.
UPDATE public.profiles p SET gmail = u.email
FROM auth.users u WHERE u.id = p.id AND p.gmail IS NULL AND u.email IS NOT NULL;

-- 1d. Tighten display_name (safe: every live row had username NOT NULL).
ALTER TABLE public.profiles ALTER COLUMN display_name SET NOT NULL;
--     gmail: do NOT set NOT NULL here. Check first:
--       SELECT id FROM public.profiles WHERE gmail IS NULL;
--     If any row is still NULL, leave it — the app upsert always sends
--     gmail, so it self-heals on the next sign-in. Unique index is safe
--     anyway (NULLs never conflict in a unique index).
CREATE UNIQUE INDEX IF NOT EXISTS profiles_gmail_unique_idx ON public.profiles (gmail);

-- 1e. updated_at trigger (from schema.sql v7).
CREATE OR REPLACE FUNCTION public.touch_updated_at()
RETURNS trigger LANGUAGE plpgsql AS $$
BEGIN
  NEW.updated_at = now();
  RETURN NEW;
END;
$$;
DROP TRIGGER IF EXISTS profiles_touch ON public.profiles;
CREATE TRIGGER profiles_touch BEFORE UPDATE ON public.profiles
  FOR EACH ROW EXECUTE FUNCTION public.touch_updated_at();

-- =============================================================== 2. INVITES
-- Live has: id, from_user, to_user, status CHECK(pending/accepted/declined/
-- cancelled), created_at, updated_at, CHECK from_user <> to_user.
-- Repo wants: id, group_id, from_id, to_id, from_name, to_name,
-- mode CHECK(2p/4p), stake, status CHECK(pending/accepted/declined/expired/
-- cancelled), created_at, updated_at.
-- The app sends invite_row() with group_id/from_id/to_id/from_name/to_name/
-- mode/stake/status, lists by to_id + status=pending and from_id +
-- status IN (pending, accepted), lists by group_id, and PATCHes status to
-- accepted/declined/cancelled/expired — so ALL of these must exist, and the
-- status CHECK must allow 'expired'.

-- 2a. Add the repo columns.
ALTER TABLE public.invites
  ADD COLUMN IF NOT EXISTS group_id uuid,
  ADD COLUMN IF NOT EXISTS from_id uuid,
  ADD COLUMN IF NOT EXISTS to_id uuid,
  ADD COLUMN IF NOT EXISTS from_name text,
  ADD COLUMN IF NOT EXISTS to_name text NOT NULL DEFAULT '',
  ADD COLUMN IF NOT EXISTS mode text,
  ADD COLUMN IF NOT EXISTS stake integer NOT NULL DEFAULT 0;

-- 2b. Backfill from the old columns + profiles (profiles migrated in §1).
--     Each old invite becomes its own singleton group (group_id = its id).
UPDATE public.invites
SET group_id = COALESCE(group_id, id),
    from_id = COALESCE(from_id, from_user),
    to_id = COALESCE(to_id, to_user),
    mode = COALESCE(mode, '2p'),
    from_name = COALESCE(from_name,
      (SELECT display_name FROM public.profiles WHERE id = from_user), 'Player'),
    to_name = COALESCE(to_name,
      (SELECT display_name FROM public.profiles WHERE id = to_user), 'Player');

-- 2c. Tighten (safe: the backfill above filled every row).
ALTER TABLE public.invites
  ALTER COLUMN group_id SET NOT NULL,
  ALTER COLUMN from_id SET NOT NULL,
  ALTER COLUMN to_id SET NOT NULL,
  ALTER COLUMN from_name SET NOT NULL,
  ALTER COLUMN mode SET NOT NULL;

-- 2d. Status CHECK must allow 'expired' (the code marks stale invites
--     'expired' — friends.gd L11). Drop ONLY the status check; the
--     from_user <> to_user check is untouched.
DO $$
DECLARE r record;
BEGIN
  FOR r IN SELECT conname FROM pg_constraint
    WHERE conrelid = 'public.invites'::regclass AND contype = 'c'
      AND pg_get_constraintdef(oid) ILIKE '%status%' LOOP
    EXECUTE format('ALTER TABLE public.invites DROP CONSTRAINT %I', r.conname);
  END LOOP;
END $$;
ALTER TABLE public.invites ADD CONSTRAINT invites_status_check
  CHECK (status IN ('pending', 'accepted', 'declined', 'expired', 'cancelled'));

-- 2e. Mode CHECK (repo: 2p/4p). Live has no mode check yet, so the DO
--     block below normally finds nothing — it is here for re-runs.
DO $$
DECLARE r record;
BEGIN
  FOR r IN SELECT conname FROM pg_constraint
    WHERE conrelid = 'public.invites'::regclass AND contype = 'c'
      AND pg_get_constraintdef(oid) ILIKE '%mode%' LOOP
    EXECUTE format('ALTER TABLE public.invites DROP CONSTRAINT %I', r.conname);
  END LOOP;
END $$;
ALTER TABLE public.invites ADD CONSTRAINT invites_mode_check
  CHECK (mode IN ('2p', '4p'));

-- 2f. Indexes + trigger. (FKs on from_id/to_id -> profiles are deliberately
--     NOT added: an old invite could reference an auth user with no profile
--     row, which would fail the constraint. RLS + app logic enforce it.)
CREATE INDEX IF NOT EXISTS invites_to_idx ON public.invites (to_id, status, created_at DESC);
CREATE INDEX IF NOT EXISTS invites_group_idx ON public.invites (group_id, status);
DROP TRIGGER IF EXISTS invites_touch ON public.invites;
CREATE TRIGGER invites_touch BEFORE UPDATE ON public.invites
  FOR EACH ROW EXECUTE FUNCTION public.touch_updated_at();

-- ===================================================== 3. MATCHMAKING QUEUE
-- Live has: id (random uuid PK), user_id NOT NULL FK auth.users,
-- status CHECK(waiting/matched/cancelled), mode CHECK(classic/blitz/
-- tournament), stake, region, rating DEFAULT 1000, created_at, updated_at,
-- unique index one_active_queue_entry_idx (user_id) WHERE status='waiting'.
-- Repo wants: id (uuid PK = the auth user id), display_name, level,
-- "table" (stake band), stake, mode CHECK(2p/4p), created_at.
-- The app upserts {id, display_name, level, "table", stake, mode} with
-- on_conflict=id, deletes by id, and find_match() reads id/display_name/
-- level/"table"/stake/mode. The code NEVER sends user_id — so the live
-- NOT NULL on user_id would reject every queue insert (blocking).

-- 3a. Add the repo columns.
ALTER TABLE public.matchmaking_queue
  ADD COLUMN IF NOT EXISTS display_name text,
  ADD COLUMN IF NOT EXISTS level integer NOT NULL DEFAULT 1,
  ADD COLUMN IF NOT EXISTS "table" integer NOT NULL DEFAULT 0;

-- 3b. Backfill display_name from the owner's profile.
UPDATE public.matchmaking_queue q
SET display_name = COALESCE(q.display_name,
  (SELECT display_name FROM public.profiles WHERE id = q.user_id), 'Player');
ALTER TABLE public.matchmaking_queue ALTER COLUMN display_name SET NOT NULL;

-- 3c. Make user_id nullable (blocking otherwise — see header).
ALTER TABLE public.matchmaking_queue ALTER COLUMN user_id DROP NOT NULL;
--     The unique index on user_id stays: NULLs never conflict in it.

-- 3d. Mode CHECK: map existing rows to '2p' first, then replace the check.
UPDATE public.matchmaking_queue SET mode = '2p' WHERE mode NOT IN ('2p', '4p');
DO $$
DECLARE r record;
BEGIN
  FOR r IN SELECT conname FROM pg_constraint
    WHERE conrelid = 'public.matchmaking_queue'::regclass AND contype = 'c'
      AND pg_get_constraintdef(oid) ILIKE '%mode%' LOOP
    EXECUTE format('ALTER TABLE public.matchmaking_queue DROP CONSTRAINT %I', r.conname);
  END LOOP;
END $$;
ALTER TABLE public.matchmaking_queue ADD CONSTRAINT matchmaking_queue_mode_check
  CHECK (mode IN ('2p', '4p'));
--     status / region / rating stay as harmless extras (defaults cover
--     new rows; the code never reads them).

-- 3e. Lookup index.
CREATE INDEX IF NOT EXISTS matchmaking_queue_lookup_idx
  ON public.matchmaking_queue (mode, "table", created_at);
--     NOTE: do NOT add the repo FK id -> auth.users. Live ids are random
--     uuids, not auth user ids, so the constraint would fail on any
--     existing row. The PK on id already gives on_conflict=id what it needs.

-- ================================================================ 4. MATCHES
-- Live has: id, player1_id NOT NULL, player2_id NOT NULL,
-- mode CHECK(classic/blitz/tournament), stake, status CHECK(pending/active/
-- finished/abandoned), winner_id, invite_a_id, invite_b_id, created_at,
-- updated_at, CHECK player1_id <> player2_id.
-- Repo wants: id, group_id, mode CHECK(2p/4p), "table", player_ids uuid[]
-- NOT NULL, players jsonb NOT NULL, status CHECK(waiting/playing/finished/
-- expired) DEFAULT 'waiting', created_at.
-- The RPCs insert (group_id, mode, "table", player_ids, players, status)
-- and the app polls by player_ids=cs.{id} + status=waiting, and by
-- group_id + status=waiting. The live NOT NULLs on player1_id/player2_id
-- and the old CHECKs would reject every new match insert (blocking).

-- 4a. Add the repo columns.
ALTER TABLE public.matches
  ADD COLUMN IF NOT EXISTS group_id uuid,
  ADD COLUMN IF NOT EXISTS "table" integer NOT NULL DEFAULT 0,
  ADD COLUMN IF NOT EXISTS player_ids uuid[],
  ADD COLUMN IF NOT EXISTS players jsonb;

-- 4b. Backfill player_ids + players from the old 1v1 columns.
UPDATE public.matches m
SET player_ids = ARRAY[m.player1_id, m.player2_id],
    players = jsonb_build_array(
      jsonb_build_object('id', m.player1_id,
        'name', COALESCE((SELECT display_name FROM public.profiles WHERE id = m.player1_id), 'Player'),
        'level', COALESCE((SELECT (xp / 500 + 1) FROM public.profiles WHERE id = m.player1_id), 1),
        'stake', COALESCE(m.stake, 0), 'seat', 0),
      jsonb_build_object('id', m.player2_id,
        'name', COALESCE((SELECT display_name FROM public.profiles WHERE id = m.player2_id), 'Player'),
        'level', COALESCE((SELECT (xp / 500 + 1) FROM public.profiles WHERE id = m.player2_id), 1),
        'stake', COALESCE(m.stake, 0), 'seat', 1))
WHERE m.player_ids IS NULL;

-- 4c. Map old mode/status values to repo values, then replace the checks.
--     (Almost certainly zero or a few test rows; the mapping preserves them.)
UPDATE public.matches SET mode = '2p' WHERE mode NOT IN ('2p', '4p');
UPDATE public.matches SET status = CASE status
  WHEN 'pending' THEN 'waiting' WHEN 'active' THEN 'playing'
  WHEN 'finished' THEN 'finished' WHEN 'abandoned' THEN 'expired'
  ELSE 'waiting' END
WHERE status NOT IN ('waiting', 'playing', 'finished', 'expired');
DO $$
DECLARE r record;
BEGIN
  FOR r IN SELECT conname FROM pg_constraint
    WHERE conrelid = 'public.matches'::regclass AND contype = 'c'
      AND pg_get_constraintdef(oid) ILIKE '%mode%' LOOP
    EXECUTE format('ALTER TABLE public.matches DROP CONSTRAINT %I', r.conname);
  END LOOP;
  FOR r IN SELECT conname FROM pg_constraint
    WHERE conrelid = 'public.matches'::regclass AND contype = 'c'
      AND pg_get_constraintdef(oid) ILIKE '%status%' LOOP
    EXECUTE format('ALTER TABLE public.matches DROP CONSTRAINT %I', r.conname);
  END LOOP;
END $$;
ALTER TABLE public.matches ADD CONSTRAINT matches_mode_check CHECK (mode IN ('2p', '4p'));
ALTER TABLE public.matches ADD CONSTRAINT matches_status_check
  CHECK (status IN ('waiting', 'playing', 'finished', 'expired'));
ALTER TABLE public.matches ALTER COLUMN status SET DEFAULT 'waiting';

-- 4d. player1_id / player2_id are NOT NULL on live, but the RPCs never set
--     them — make them nullable. (The player1_id <> player2_id check still
--     passes for NULLs; winner_id / invite_a_id / invite_b_id stay as
--     harmless extras.)
ALTER TABLE public.matches ALTER COLUMN player1_id DROP NOT NULL;
ALTER TABLE public.matches ALTER COLUMN player2_id DROP NOT NULL;

-- 4e. Tighten the new columns (backfill in 4b filled every row).
ALTER TABLE public.matches ALTER COLUMN player_ids SET NOT NULL;
ALTER TABLE public.matches ALTER COLUMN players SET NOT NULL;

-- 4f. Indexes.
CREATE INDEX IF NOT EXISTS matches_players_idx ON public.matches USING gin (player_ids);
CREATE INDEX IF NOT EXISTS matches_group_idx ON public.matches (group_id);
CREATE INDEX IF NOT EXISTS matches_waiting_idx ON public.matches (status, created_at);

-- =============================================================== 5. PRESENCE
-- Live has: user_id (PK, FK auth.users), status CHECK(online/in_game/
-- offline), current_match_id FK matches, updated_at, index on updated_at DESC.
-- Repo wants: id (uuid PK = the auth user id), display_name, level,
-- status CHECK(online/in_match) DEFAULT 'online', updated_at.
-- The app heartbeats {id, display_name, level, status, updated_at} with
-- on_conflict=id, deletes by id, and lists by updated_at desc. It NEVER
-- sends user_id. A PK on user_id would reject every new heartbeat row
-- (user_id NOT NULL), and on_conflict=id needs a unique constraint on id.
-- So the PK must move from user_id to id — the only structural change in
-- this whole migration.

-- 5a. Add the repo columns.
ALTER TABLE public.presence
  ADD COLUMN IF NOT EXISTS id uuid,
  ADD COLUMN IF NOT EXISTS display_name text,
  ADD COLUMN IF NOT EXISTS level integer NOT NULL DEFAULT 1;

-- 5b. Backfill id + display_name from user_id / profiles.
UPDATE public.presence SET id = user_id WHERE id IS NULL;
UPDATE public.presence p
SET display_name = COALESCE(p.display_name,
  (SELECT display_name FROM public.profiles WHERE id = p.user_id), 'Player');
ALTER TABLE public.presence ALTER COLUMN id SET NOT NULL;
ALTER TABLE public.presence ALTER COLUMN display_name SET NOT NULL;

-- 5c. Swap the primary key from user_id to id. user_id stays as a plain
--     (nullable) FK column — a harmless extra.
DO $$
DECLARE pk_name text;
BEGIN
  SELECT conname INTO pk_name FROM pg_constraint
    WHERE conrelid = 'public.presence'::regclass AND contype = 'p';
  IF pk_name IS NOT NULL THEN
    EXECUTE format('ALTER TABLE public.presence DROP CONSTRAINT %I', pk_name);
  END IF;
END $$;
ALTER TABLE public.presence ADD PRIMARY KEY (id);
ALTER TABLE public.presence ALTER COLUMN user_id DROP NOT NULL;

-- 5d. Status CHECK: live allows online/in_game/offline; code sends
--     online/in_match. WIDEN (do not narrow) so old rows keep their values.
--     The client coerces anything else to "online" anyway (friends.gd).
DO $$
DECLARE r record;
BEGIN
  FOR r IN SELECT conname FROM pg_constraint
    WHERE conrelid = 'public.presence'::regclass AND contype = 'c'
      AND pg_get_constraintdef(oid) ILIKE '%status%' LOOP
    EXECUTE format('ALTER TABLE public.presence DROP CONSTRAINT %I', r.conname);
  END LOOP;
END $$;
ALTER TABLE public.presence ADD CONSTRAINT presence_status_check
  CHECK (status IN ('online', 'in_match', 'offline', 'in_game'));
--     current_match_id stays as a harmless extra.

-- 5e. Index (live already has one on updated_at DESC; this is the repo name).
CREATE INDEX IF NOT EXISTS presence_updated_idx ON public.presence (updated_at DESC);

-- =============================================================== 6. FUNCTIONS
-- 6a. Drop the OLD overloads FIRST. Postgres identifies a function by name
--     + argument types, so CREATE OR REPLACE with a different signature
--     would create a SECOND overload instead of replacing:
--       live: search_players(q text) -> (id, username)
--             create_match_from_invites(p_invite_a uuid, p_invite_b uuid) -> uuid
--             find_match(p_mode text, p_stake integer) -> uuid
--       repo: search_players(q text, exclude_id uuid) -> (id, display_name, level)
--             create_match_from_invites(p_group_id uuid) -> jsonb
--             find_match(p_mode text, p_widen boolean) -> jsonb
DROP FUNCTION IF EXISTS public.search_players(text);
DROP FUNCTION IF EXISTS public.create_match_from_invites(uuid, uuid);
DROP FUNCTION IF EXISTS public.find_match(text, integer);

-- 6b. search_players — verbatim from supabase/schema.sql (v7).
create or replace function public.search_players(q text, exclude_id uuid)
returns table (id uuid, display_name text, level integer)
language sql security definer stable as $$
  select p.id, p.display_name, (p.xp / 500 + 1)::integer as level
  from public.profiles p
  where p.id <> exclude_id
    and p.display_name ilike '%' || q || '%'
  order by p.display_name
  limit 20;
$$;

-- 6c. find_match — verbatim from supabase/schema-p2p.sql.
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
  all_players := array[me];
  for i in 1..need loop
    all_players := array_append(all_players, others[i]);
  end loop;
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

-- 6d. create_match_from_invites — verbatim from supabase/schema-p2p.sql.
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
  for i in 1..array_length(inv_rows, 1) loop
    if inv_rows[i].status <> 'accepted' then
      return jsonb_build_object('ok', false, 'error', 'Not everyone has accepted yet.');
    end if;
  end loop;
  inviter_id := inv_rows[1].from_id;
  inviter_name := inv_rows[1].from_name;
  inviter_stake := inv_rows[1].stake;
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
          0,
          ids, players_json, 'waiting')
  returning id into match_id;
  return jsonb_build_object('ok', true, 'match_id', match_id, 'players', players_json);
end;
$$;

-- ==================================================================== 7. RLS
-- Enable RLS on all five tables (idempotent) and apply the repo policy
-- blocks verbatim (DROP POLICY IF EXISTS + CREATE POLICY — idempotent).
-- NOTE: if the live project already has policies with these names but
-- different definitions, this REPLACES them with the repo versions — that
-- is intended. Policies with other names are left alone; check the
-- dashboard afterwards and remove any stale ones that conflict.
alter table public.profiles enable row level security;
alter table public.invites enable row level security;
alter table public.matchmaking_queue enable row level security;
alter table public.matches enable row level security;
alter table public.presence enable row level security;

drop policy if exists "profiles read for signed-in users" on public.profiles;
create policy "profiles read for signed-in users" on public.profiles
  for select to authenticated using (true);
drop policy if exists "profiles insert own row" on public.profiles;
create policy "profiles insert own row" on public.profiles
  for insert to authenticated with check (auth.uid() = id);
drop policy if exists "profiles update own row" on public.profiles;
create policy "profiles update own row" on public.profiles
  for update to authenticated using (auth.uid() = id) with check (auth.uid() = id);

drop policy if exists "invites read for parties" on public.invites;
create policy "invites read for parties" on public.invites
  for select to authenticated using (auth.uid() = from_id or auth.uid() = to_id);
drop policy if exists "invites insert by sender" on public.invites;
create policy "invites insert by sender" on public.invites
  for insert to authenticated with check (auth.uid() = from_id);
drop policy if exists "invites update by parties" on public.invites;
create policy "invites update by parties" on public.invites
  for update to authenticated using (auth.uid() = from_id or auth.uid() = to_id);

drop policy if exists "queue insert own row" on public.matchmaking_queue;
create policy "queue insert own row" on public.matchmaking_queue
  for insert to authenticated with check (auth.uid() = id);
drop policy if exists "queue delete own row" on public.matchmaking_queue;
create policy "queue delete own row" on public.matchmaking_queue
  for delete to authenticated using (auth.uid() = id);
drop policy if exists "queue read for signed-in users" on public.matchmaking_queue;
create policy "queue read for signed-in users" on public.matchmaking_queue
  for select to authenticated using (true);

drop policy if exists "matches read for players" on public.matches;
create policy "matches read for players" on public.matches
  for select to authenticated using (auth.uid() = ANY(player_ids));

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

-- =============================================================== 8. REALTIME
-- The app subscribes to postgres_changes on invites (to_id/from_id
-- filters) and polls matches/presence. Guarded so re-runs do not error
-- ("table is already member of publication" would otherwise abort).
DO $$
BEGIN
  IF NOT EXISTS (SELECT 1 FROM pg_publication_tables
    WHERE pubname = 'supabase_realtime' AND schemaname = 'public' AND tablename = 'invites') THEN
    EXECUTE 'ALTER PUBLICATION supabase_realtime ADD TABLE public.invites';
  END IF;
  IF NOT EXISTS (SELECT 1 FROM pg_publication_tables
    WHERE pubname = 'supabase_realtime' AND schemaname = 'public' AND tablename = 'matches') THEN
    EXECUTE 'ALTER PUBLICATION supabase_realtime ADD TABLE public.matches';
  END IF;
  IF NOT EXISTS (SELECT 1 FROM pg_publication_tables
    WHERE pubname = 'supabase_realtime' AND schemaname = 'public' AND tablename = 'presence') THEN
    EXECUTE 'ALTER PUBLICATION supabase_realtime ADD TABLE public.presence';
  END IF;
END $$;

-- =========================================================== 9. VERIFICATION
-- Run these AFTER the migration and compare with the pre-run snapshot.
-- 9a. No rows lost:
--   SELECT 'profiles', count(*) FROM public.profiles
--     UNION ALL SELECT 'invites', count(*) FROM public.invites
--     UNION ALL SELECT 'matchmaking_queue', count(*) FROM public.matchmaking_queue
--     UNION ALL SELECT 'matches', count(*) FROM public.matches
--     UNION ALL SELECT 'presence', count(*) FROM public.presence;
-- 9b. No NULLs left in the tightened columns (gmail may still have NULLs —
--     see §1d; everything else must be 0):
--   SELECT 'profiles display_name NULLs', count(*) FROM public.profiles WHERE display_name IS NULL
--     UNION ALL SELECT 'profiles gmail NULLs', count(*) FROM public.profiles WHERE gmail IS NULL
--     UNION ALL SELECT 'invites group_id NULLs', count(*) FROM public.invites WHERE group_id IS NULL
--     UNION ALL SELECT 'invites from_id NULLs', count(*) FROM public.invites WHERE from_id IS NULL
--     UNION ALL SELECT 'queue display_name NULLs', count(*) FROM public.matchmaking_queue WHERE display_name IS NULL
--     UNION ALL SELECT 'matches player_ids NULLs', count(*) FROM public.matches WHERE player_ids IS NULL
--     UNION ALL SELECT 'matches players NULLs', count(*) FROM public.matches WHERE players IS NULL
--     UNION ALL SELECT 'presence id NULLs', count(*) FROM public.presence WHERE id IS NULL;
-- 9c. Functions exist with the NEW signatures only (old overloads gone):
--   SELECT proname, pg_get_function_identity_arguments(oid) FROM pg_proc
--     WHERE pronamespace = 'public'::regnamespace
--     AND proname IN ('search_players', 'find_match', 'create_match_from_invites');
--   Expect: search_players(text, uuid), find_match(text, boolean),
--           create_match_from_invites(uuid). NOTHING else with those names.
-- 9d. Test the search RPC (security definer — runs from the editor):
--   SELECT * FROM public.search_players('a', '00000000-0000-0000-0000-000000000000');
--   Expect: the registered players whose display_name contains 'a'.
-- 9e. Test find_match's "not in queue" path (proves the body works):
--   SELECT public.find_match('2p', false);
--   Expect: {"matched": false, "error": "You are not in the queue."}
-- 9f. Live two-phone test (the real proof — dashboard runs as postgres and
--     bypasses RLS, so it cannot test the heartbeat): sign in on both
--     phones with different Gmails, open the Online Lobby on both — each
--     phone must see the other. Then name-search the other player, send an
--     invite, accept, and confirm the match forms. If a phone still does
--     not appear, pull its log: the heartbeat prints
--     "Presence heartbeat failed (...)" with the exact error.
