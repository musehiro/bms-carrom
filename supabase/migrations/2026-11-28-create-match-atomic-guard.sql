-- ======================================================================
-- BMS Carrom — atomic guard for create_match_from_invites
-- Date: 2026-11-28 (round 4 — stuck-popup incident)
-- RUN ON: live Supabase project qigrifiqtarjgklfxmfg ONLY, via the
-- SQL editor. NEVER on the old project hyhlhngybzwnungnshff.
-- DO NOT RUN until the parent reviews this file.
--
-- WHY: on 2026-11-28 05:18:47 two concurrent calls to
-- create_match_from_invites for the same group (7710c914) both passed
-- the function's "existing match" check and both inserted, creating
-- TWO duplicate matches (fcc090ee + 3ebc32e4) 0.1 s apart. The
-- function does check-then-insert with no lock, so concurrent calls
-- race. The client now single-flights the RPC (round 4), but the
-- server must also be safe: two phones can still call it at the
-- same moment (both sides call it on accept).
--
-- FIX (two layers):
--   1. pg_advisory_xact_lock per group — serializes concurrent calls
--      for the SAME group. The second call waits, then re-runs the
--      existing-match check and returns the first call's match.
--      Different groups are unaffected (different lock keys).
--   2. Partial UNIQUE index on matches(group_id) for live statuses —
--      a backstop: even if the lock is bypassed, a second live match
--      for the same group cannot be inserted (it errors instead).
--      The index FAILS to create if duplicate live matches already
--      exist for a group — clean those up first (as of 2026-11-28
--      05:27 the live waiting count was 0).
--
-- The function body below is VERBATIM from
-- supabase/migrations/2026-11-27-live-migration-to-repo-schema.sql
-- lines 447-525 (which is verbatim from supabase/schema-p2p.sql) —
-- the ONLY change is the advisory-lock line at the top of the body.
-- ======================================================================

-- Layer 1: advisory lock inside the function.
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
  -- ROUND 4: serialize concurrent calls for THIS group. Two calls
  -- for the same group run one after the other; the second re-checks
  -- `existing` below and returns the first call's match instead of
  -- inserting a duplicate. Lock key: fixed namespace 727271 (the
  -- Carrom project tag) + a hash of the group id, so different
  -- groups never block each other. The lock is released at
  -- transaction end (xact lock) — no manual unlock needed.
  PERFORM pg_advisory_xact_lock(727271, hashtext(p_group_id::text));

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

-- Layer 2: backstop — at most ONE live match per group. Fails to
-- create if duplicate live matches already exist for a group; clean
-- them up first (delete the extras, keep the newest).
CREATE UNIQUE INDEX IF NOT EXISTS matches_one_live_per_group
  ON public.matches (group_id)
  WHERE status IN ('waiting', 'ready', 'playing');

-- ======================================================================
-- NOTE (open item, NOT changed here): the existing-match check above
-- has NO status filter — `where group_id = p_group_id limit 1`
-- returns even an EXPIRED match, which the client would then try to
-- join. Adding `AND status IN ('waiting','ready','playing')` would
-- let a fresh match form after an old one expired, but it CHANGES
-- the function's behaviour, so it is left for a separate decision.
-- The advisory lock alone fixes the duplicate-creation race.
--
-- VERIFICATION (run after applying, in the same SQL editor session):
--   1. Function carries the lock:
--      SELECT pg_get_functiondef(oid) FROM pg_proc
--      WHERE proname = 'create_match_from_invites';
--      -- the output must contain "pg_advisory_xact_lock(727271".
--   2. Index exists:
--      SELECT indexname FROM pg_indexes
--      WHERE tablename = 'matches' AND indexname = 'matches_one_live_per_group';
--   3. No duplicate live matches remain:
--      SELECT group_id, count(*) FROM public.matches
--      WHERE status IN ('waiting','ready','playing')
--      GROUP BY group_id HAVING count(*) > 1;
--      -- must return zero rows.
-- ======================================================================
