-- ==========================================================================
-- BMS Carrom — cleanup_stale_matchmaking(): expire stale matchmaking state
-- Date: 2026-11-28 (scale-hardening round, worker 5).
-- Live project ONLY: qigrifiqtarjgklfxmfg. Never run against
-- hyhlhngybzwnungnshff (dead project).
-- UNRUN — reviewed by diff/mock only (see Verification at the bottom);
-- no live run, no real-Postgres EXPLAIN yet.
--
-- WHY: three leaks found by code-reading this round, none of which any
-- live mechanism closes today:
--   * Invites never answered stay 'pending' forever server-side
--     (expiry is client-side only).
--   * Abandoned searches leave ghost queue rows (find_match has no
--     age filter, so a stale row can still be paired).
--   * A force-closed mid-match leaves the matches row 'waiting'
--     forever: nothing transitions matches, expire_match is
--     RLS-blocked for direct UPDATE, and the supabase.gd comment
--     claiming "rows older than 10 min are cleaned by the next
--     search" has NO implementation anywhere.
--
-- WHAT IT DOES (one SECURITY DEFINER call, no arguments):
--   1. DELETEs matchmaking_queue rows older than 10 minutes.
--   2. Marks matches 'waiting' older than 10 minutes as 'expired'.
--      Rows are NOT deleted — match history is kept. 'expired' is
--      outside the partial unique index matches_one_live_per_group's
--      live-status predicate (waiting/ready/playing), so an expired
--      row can never block a future match for the same group.
--   3. Marks invites 'pending' older than 24 hours as 'expired'.
-- Returns jsonb:
--   {"ok": true, "expired_matches": N, "deleted_queue_rows": N,
--    "expired_invites": N}
--
-- WHAT IT DELIBERATELY DOES NOT TOUCH:
--   * matches in 'ready' or 'playing' — those are live games in
--     progress, not stale searches; a long game is not a leak.
--   * matches in 'finished' — already terminal.
--   * invites in 'accepted'/'declined'/'cancelled' — already decided;
--     only unanswered 'pending' invites expire (24 h gives the
--     invitee a full day, matching the client-side invite lifetime).
--
-- THRESHOLDS: 10 minutes matches the client's own stale assumptions
-- (the supabase.gd comment's "older than 10 min" and the queue
-- heartbeat cadence); 24 hours for invites matches the client-side
-- invite expiry. Both are single literals below — tune in one place.
--
-- CALLER: the client (signed in) calls it as a periodic cleanup RPC;
-- GRANT EXECUTE TO authenticated is therefore required. It is safe
-- for any signed-in user to call: it touches only rows past the
-- thresholds, never rows belonging to a live game, and it takes no
-- arguments, so there is nothing to inject. RLS does not apply
-- inside a SECURITY DEFINER function.
--
-- IDEMPOTENCY: re-running it immediately after a run returns all
-- three counts as 0 (the stale rows are already gone/expired).
-- ==========================================================================

create or replace function public.cleanup_stale_matchmaking()
returns jsonb
language plpgsql security definer as $$
declare
  v_expired_matches int;
  v_deleted_queue_rows int;
  v_expired_invites int;
begin
  -- 1. Ghost queue rows: abandoned searches (no age filter in find_match).
  delete from public.matchmaking_queue
    where created_at < now() - interval '10 minutes';
  get diagnostics v_deleted_queue_rows = row_count;

  -- 2. Wedged 'waiting' matches: never started (force-close mid-match).
  -- 'expired' is outside the matches_one_live_per_group predicate, so
  -- this can never block a future match for the same group.
  update public.matches
     set status = 'expired'
   where status = 'waiting'
     and created_at < now() - interval '10 minutes';
  get diagnostics v_expired_matches = row_count;

  -- 3. Unanswered invites: 'pending' forever server-side until now.
  update public.invites
     set status = 'expired'
   where status = 'pending'
     and created_at < now() - interval '24 hours';
  get diagnostics v_expired_invites = row_count;

  return jsonb_build_object(
    'ok', true,
    'expired_matches', v_expired_matches,
    'deleted_queue_rows', v_deleted_queue_rows,
    'expired_invites', v_expired_invites);
end;
$$;

-- The client is signed in when it calls this (periodic cleanup tick).
GRANT EXECUTE ON FUNCTION public.cleanup_stale_matchmaking() TO authenticated;

-- PostgREST caches function signatures: reload after any function change.
NOTIFY pgrst, 'reload schema';

-- ==========================================================================
-- VERIFICATION (run after applying, in the same SQL editor session):
--   1. Function + grant exist:
--      SELECT pg_get_functiondef(oid) FROM pg_proc
--      WHERE proname = 'cleanup_stale_matchmaking';
--      SELECT grantee FROM information_schema.routine_privileges
--      WHERE routine_name = 'cleanup_stale_matchmaking';
--      -- must list authenticated.
--   2. Dry-run counts before calling (replace the thresholds with the
--      same literals to see what a call would do):
--      SELECT (SELECT count(*) FROM public.matchmaking_queue
--               WHERE created_at < now() - interval '10 minutes')
--             AS queue_rows_to_delete,
--             (SELECT count(*) FROM public.matches
--               WHERE status = 'waiting'
--               AND created_at < now() - interval '10 minutes')
--             AS matches_to_expire,
--             (SELECT count(*) FROM public.invites
--               WHERE status = 'pending'
--               AND created_at < now() - interval '24 hours')
--             AS invites_to_expire;
--   3. Call it and check the returned counts match the dry run, then
--      call it again immediately: all three counts must be 0.
--      SELECT public.cleanup_stale_matchmaking();
--   4. No live game harmed: no row with status 'playing' or 'ready'
--      may change status, and no match row may be deleted:
--      SELECT count(*) FROM public.matches WHERE status = 'expired'
--        AND created_at >= now() - interval '10 minutes';
--      -- must be 0 (only rows older than 10 min expire).
-- ==========================================================================
