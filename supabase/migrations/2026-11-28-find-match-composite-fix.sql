-- ==========================================================================
-- BMS Carrom — find_match: composite-field ORDER BY fix (42P01)
-- Date: 2026-11-28.
-- Live project ONLY: qigrifiqtarjgklfxmfg. Never run against
-- hyhlhngybzwnungnshff (dead project).
--
-- ONE-LINE FIX vs supabase/migrations/2026-11-28-find-match-lock.sql
-- as committed in the scale-hardening round:
--   was:    select array_agg(s.q order by s.q.created_at)
--   now:    select array_agg(s.q order by (s.q).created_at)
--
-- WHY: Postgres parses the unparenthesised three-part name
-- s.q.created_at as schema.table.column, so the aggregate's ORDER BY
-- raised 42P01 ("missing FROM-clause entry for table q") on EVERY
-- find_match call — random pairing never worked once the lock version
-- went live. Parenthesised composite-field access (s.q).created_at
-- is the correct syntax. The 17:00 two-phone test proved it at
-- runtime (31 find_match calls, all 404, zero 200s).
--
-- LIVE VERIFICATION (applied 2026-11-28 17:22, browser task, live ONLY):
--   * pg_get_functiondef contains "(s.q).created_at" plus both lock
--     clauses ("for update" and "for update skip locked").
--   * find_match smoke test returns {"matched": false, "error":
--     "You are not in the queue."} JSON instead of 42P01.
--   * Stale waiting match left over from the broken period deleted;
--     waiting matches back to 0.
--
-- This file records the corrected full CREATE OR REPLACE body
-- (identical to the fixed lock file) so the fix is reviewable and
-- re-runnable on its own. The lock file itself carries the same
-- one-line fix.
-- ==========================================================================

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
  select array_agg(s.q order by (s.q).created_at)
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
