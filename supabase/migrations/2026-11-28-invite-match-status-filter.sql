-- ======================================================================
-- BMS Carrom — create_match_from_invites: existing-match check must
-- ignore dead matches (status filter)
-- Date: 2026-11-28 (scale-hardening round, worker 5).
-- RUN ON: live Supabase project qigrifiqtarjgklfxmfg ONLY, via the
-- SQL editor. NEVER on the old project hyhlhngybzwnungnshff.
-- DO NOT RUN until the parent reviews this file.
-- UNRUN — reviewed by diff only (see Verification at the bottom); no
-- live run, no real-Postgres EXPLAIN yet.
--
-- WHY: the atomic-guard version of this function (applied live
-- 2026-11-28 06:03) checks for an existing match with
--   where group_id = p_group_id limit 1
-- with NO status filter. If that match is EXPIRED (e.g. the
-- cleanup RPC expired it after the group went stale, or a previous
-- match finished), the function returns the dead match and the
-- client tries to join a match it can never join — the invite group
-- is wedged forever: every later call returns the same dead row and
-- no fresh match is ever created. The guard migration file itself
-- flags this as an open item.
--
-- FIX: restrict the existing-match check to live statuses —
--   AND status IN ('waiting', 'ready', 'playing')
-- the same triple the partial unique index
-- matches_one_live_per_group uses and the client polls with
-- (scripts/supabase.gd poll_matches_for_me / poll_matches_for_group,
-- scripts/match_state.gd joinable check). A dead match is now
-- invisible to the check, so the function proceeds and inserts a
-- FRESH match for the group. The advisory lock and the unique index
-- still serialize concurrent calls, so the fresh insert cannot
-- duplicate: at most one live match per group ever exists, which
-- also makes the LIMIT 1 deterministic in practice.
--
-- THE ONLY CHANGE vs
-- supabase/migrations/2026-11-28-create-match-atomic-guard.sql is
-- this status filter on the existing-match check. The advisory-lock
-- line, every validation, the INSERT, and the unique index are
-- unchanged (verified by diff — see the round report).
--
-- NOTE on 'ready': the live matches CHECK constraint
-- (2026-11-27 migration §4c) lists ('waiting','playing','finished',
-- 'expired') and does not name 'ready', but the client and the
-- guard index both treat 'ready' as live, so the filter uses the
-- same triple as the guard index rather than inventing a new list.
-- ======================================================================

-- Advisory lock + status-filtered existing-match check. Same signature
-- as the guard version, so CREATE OR REPLACE suffices.
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

  -- SCALE FIX: only a LIVE match counts as existing. A match in
  -- 'expired' (or 'finished') must not be returned — the client
  -- cannot join it, and returning it would wedge the group forever.
  select * into existing from public.matches where group_id = p_group_id and status in ('waiting','ready','playing') limit 1;
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

-- Backstop (unchanged from the guard file; IF NOT EXISTS so re-runs
-- are safe): at most ONE live match per group.
CREATE UNIQUE INDEX IF NOT EXISTS matches_one_live_per_group
  ON public.matches (group_id)
  WHERE status IN ('waiting', 'ready', 'playing');

-- PostgREST caches function signatures: reload after any function change.
NOTIFY pgrst, 'reload schema';

-- ======================================================================
-- VERIFICATION (run after applying, in the same SQL editor session):
--   1. Function carries the lock AND the status filter:
--      SELECT pg_get_functiondef(oid) FROM pg_proc
--      WHERE proname = 'create_match_from_invites';
--      -- the output must contain "pg_advisory_xact_lock(727271" and
--      -- "status in ('waiting','ready','playing')".
--   2. Index still exists (see the guard file's checks).
--   3. Invite-after-expiry: create a group, accept all invites, call
--      the RPC (match M1), expire M1 (UPDATE matches SET status =
--      'expired' WHERE id = M1 — or wait for cleanup_stale_matchmaking
--      to expire it), call the RPC again: it must return a FRESH
--      match M2 <> M1 with ok = true, and M1 must stay 'expired'.
-- ======================================================================
