-- ==========================================================================
-- BMS Carrom — find_match: concurrency protection (FOR UPDATE SKIP LOCKED)
-- Date: 2026-11-28 (scale-hardening round, worker 5).
-- Live project ONLY: qigrifiqtarjgklfxmfg. Never run against
-- hyhlhngybzwnungnshff (dead project).
-- Run AFTER supabase/migrations/2026-11-28-find-match-fix.sql.
-- UNRUN — reviewed by diff only (see Verification at the bottom); no
-- live run, no real-Postgres EXPLAIN yet.
--
-- WHY: find_match is check-then-insert with NO lock. Two phones calling
-- it at the same moment both read the same oldest opponents and both
-- INSERT a match for the same players. The round-4 atomic guard covers
-- ONLY create_match_from_invites (group_id); random matches have
-- group_id = NULL, so the partial unique index cannot catch them.
-- Measured on the mock this round: duplicate rate 0% at 100 players,
-- ~4% of matches at 1000 players.
--
-- FIX — row locks, no advisory lock (two reasons):
--   * Granularity: an advisory lock per (mode, table) would serialize
--     EVERY find_match call in a band, including calls that pair
--     disjoint players. Row locks let disjoint pairings proceed in
--     parallel; only calls contending for the SAME players interact.
--   * Scope: the lock lives exactly on the rows the transaction
--     consumes, so it cannot leak across bands or be forgotten on a
--     code path that returns early (the lock dies with the txn).
--   1. `me` row: plain FOR UPDATE (BLOCKING, not SKIP LOCKED).
--      The caller's own row must be locked, otherwise a second call
--      can still use that player as ITS opponent while the first call
--      is using them as `me` — the opponent lock alone does not stop
--      that. Blocking (not skipping) is deliberate: if `me` is locked
--      by a concurrent call, this call WAITS for that transaction;
--      when it commits, the row is either gone (matched — this call
--      then returns the existing 'You are not in the queue.' error and
--      the client self-heals by re-inserting, scripts/net_client.gd)
--      or still there (no match — this call proceeds normally).
--      SKIP LOCKED on `me` would be wrong: it would return
--      matched:false with the caller's row still queued but
--      un-paired, and the client would keep polling a row that may
--      already have been consumed.
--   2. Opponents: FOR UPDATE SKIP LOCKED, ORDER BY created_at,
--      LIMIT need. Only the `need` rows this call will actually pair
--      are locked — the old full-partition array_agg is gone (it
--      scanned and materialised every candidate in the band on every
--      call). A concurrent call skips rows this call locked and takes
--      the next-oldest unlocked opponents instead, so two calls never
--      insert the same players.
--
-- DEADLOCK: impossible here. The only blocking lock is the `me` lock,
-- and a transaction never blocks while holding an opponent lock:
-- opponent locks are SKIP LOCKED (never wait), and the `me` lock is
-- taken BEFORE any opponent lock. A call blocked on a `me` row waits
-- on a transaction that never waits on it.
--
-- SEMANTIC CHANGES vs supabase/migrations/2026-11-28-find-match-fix.sql
-- (the ONLY changes in this file — everything else is verbatim):
--   * `me` lookup gains FOR UPDATE (see 1 above). Same row, same
--     not-found behaviour, plus a brief wait under contention.
--   * Opponents query is the same predicate, but now a locked
--     subquery: ORDER BY created_at LIMIT need FOR UPDATE SKIP LOCKED,
--     aggregated afterwards. Same FIFO-oldest-first pairing order;
--     same level window (abs() kept as-is — the BETWEEN rewrite from
--     the scale-indexes note is deliberately NOT done here, so the
--     pairing index still applies and the diff stays minimal).
--   * Under perfect simultaneity with exactly 2 queued players, the
--     loser of the `me` race may get 'You are not in the queue.'
--     instead of a match (its row was consumed by the winner); the
--     client re-inserts and retries on the next 2 s tick. With 3+
--     queued players the loser pairs with the next-oldest instead.
--   * Ghost queue rows (abandoned searches) are NOT filtered here;
--     they are removed by cleanup_stale_matchmaking() in
--     supabase/migrations/2026-11-28-matchmaking-cleanup.sql.
--
-- VERIFICATION (worker 5, mock only — no live run):
--   * The function body below was diffed against the find-match-fix
--     body: only the two hunks above differ (me FOR UPDATE; locked
--     opponent subquery). See the round report for the diff.
--   * The mock (tests/mock_supabase.py) now holds its lock across
--     read+insert to mirror these semantics; 600 simultaneous
--     find_match calls produced 300 matches, 0 duplicates, 0
--     double-booked players (tests/scale_sql_verify.py).
-- ==========================================================================

-- Same signature as the find-match-fix version, so CREATE OR REPLACE
-- suffices (no DROP needed — there is exactly one overload).
create or replace function public.find_match(p_mode text, p_widen boolean default false, p_strict boolean default false)
returns jsonb
language plpgsql security definer as $$
declare
  me public.matchmaking_queue%rowtype;
  window_size int := case when p_strict then 0 when p_widen then 4 else 2 end;
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
  -- SCALE FIX 1: lock the caller's own queue row (blocking). See header.
  select * into me from public.matchmaking_queue where id = auth.uid() for update;
  if not found then
    return jsonb_build_object('matched', false, 'error', 'You are not in the queue.');
  end if;
  -- SCALE FIX 2: lock only the `need` oldest unlocked opponents.
  -- Same predicate and FIFO order as before; the full-partition
  -- array_agg is replaced by a LIMITed locked subquery, so a
  -- concurrent call skips these rows instead of pairing them twice.
  select array_agg(s.q order by s.q.created_at)
    into others
    from (select q
            from public.matchmaking_queue q
           where q.mode = p_mode
             and q."table" = me."table"
             and q.id <> me.id
             and abs(q.level - me.level) <= window_size
           order by q.created_at
           limit need
             for update skip locked) s;
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
    where id = any (select p.id from unnest(all_players) as p);
  return jsonb_build_object('matched', true, 'match_id', match_id, 'players', players_json);
end;
$$;

-- PostgREST caches function signatures: reload after any function change
-- (see the find-match-fix file — a stale cache 404s with 42883).
NOTIFY pgrst, 'reload schema';

-- ==========================================================================
-- VERIFICATION (run after applying, in the same SQL editor session):
--   1. Function carries both lock clauses:
--      SELECT pg_get_functiondef(oid) FROM pg_proc
--      WHERE proname = 'find_match';
--      -- the output must contain "for update" (me lookup) and
--      -- "for update skip locked" (opponents subquery).
--   2. No duplicate random matches under concurrency: with two phones
--      queued, fire find_match from both at the same instant; exactly
--      ONE matches row may exist for the pair (the loser gets
--      'You are not in the queue.' and re-queues via the client
--      self-heal path).
-- ==========================================================================
