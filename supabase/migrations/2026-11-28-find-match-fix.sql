-- ==========================================================================
-- BMS Carrom — find_match: add p_strict ONLY (SAME 2 PLAYER button)
-- Live project ONLY: qigrifiqtarjgklfxmfg. Never run against
-- hyhlhngybzwnungnshff (dead project).
-- Run AFTER supabase/migrations/2026-11-28-grants.sql.
--
-- CORRECTION 2026-11-28 02:29 — the live test (RUN 4) proved the function
-- body has a REAL bug I missed on the first read: the final cleanup
--   delete ... where id = any (select array_agg(p.id) from unnest(...) as p)
-- compares uuid = uuid[] (42883) and aborts the whole call — the match
-- insert rolls back. It only fires when a match is actually found, which
-- is why find_match NEVER created a match. Fixed below to
--   where id = any (select p.id from unnest(all_players) as p).
-- The INSERT's (select array_agg(...)) is a scalar subquery and is fine.
-- So this file now changes TWO things vs the old live body: p_strict
-- (additive) + the DELETE fix. Everything else is byte-identical in logic.
--
-- CORRECTION 2026-11-28 01:51 — the live function logic was traced
-- call-by-call against the queue state and is CORRECT. Do NOT rewrite it:
--   * 14-call burst 18:41:05-18:41:21 UTC (Bm): matched:false was CORRECT,
--     Gayan was not queued until 19:57:14, so there was no opponent.
--   * 18:56:43 200 matched:false (Gayan): he was NOT in the queue yet.
--   * 19:57:16 404 (Gayan, 2s after joining): BOTH players were queued —
--     this was the one call that should have matched, and it died on the
--     transient PostgREST 42883 undefined_function (schema-cache staleness).
--     No find_match call was ever made after that — both phones had stopped
--     polling (WAITING popup closed). The client polling lifecycle is the
--     main bug; the fix is client-side retry, not a function rewrite.
-- The ONLY change in this file vs the live body is the additive p_strict
-- parameter (window 0 when strict). The `me` lookup, opponents query,
-- coin check, match insert (status 'waiting'), queue-row deletion and
-- return shape are byte-identical in logic to the live body.
--
-- WHY THE OLD OVERLOAD IS DROPPED FIRST: PostgreSQL resolves a 2-arg call
-- to the exact 2-arg overload, so creating a 3-arg overload alongside it
-- would leave every existing client call hitting the OLD body. The live
-- function is find_match(text, boolean) — exactly ONE overload (the old
-- (text, integer) overload is gone). After the drop, 2-arg calls resolve
-- to this 3-arg function via its defaults, so existing clients keep
-- working unchanged (call_find_match(mode, widen) in scripts/supabase.gd
-- needs no change; strict calls pass p_strict=true).
--
-- OPTIONAL HARDENING — NOT included here (pending client cancel-path
-- check): status = 'waiting' filters on the me + opponents lookups.
-- Include them only if the client cancel path is consistent with it
-- (cancel DELETES the row -> filter harmless; cancel SETS a status ->
-- filter matters). Do not change matching behaviour beyond p_strict.
-- ==========================================================================

-- ---------------------------------------------------------------- §1. Drop
-- the old 2-arg overload so 2-arg calls reach the new body (see header).
DROP FUNCTION IF EXISTS public.find_match(text, boolean);

-- ------------------------------------------------------- §2. find_match v2
-- Signature: find_match(p_mode text, p_widen boolean default false,
--                      p_strict boolean default false) -> jsonb
-- Body identical to the live function except the window line (p_strict).
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
    where id = any (select p.id from unnest(all_players) as p);
  return jsonb_build_object('matched', true, 'match_id', match_id, 'players', players_json);
end;
$$;

-- PostgREST caches function signatures: after any function change the
-- cache must reload, or calls keep 404ing with 42883 undefined_function
-- (the API log shows the SAME 31-byte body getting 200 once and 404
-- twice — schema-cache staleness; EXECUTE grant is confirmed, so the
-- 404s are NOT a permission problem).
NOTIFY pgrst, 'reload schema';
