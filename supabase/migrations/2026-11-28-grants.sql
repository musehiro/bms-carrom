-- ==========================================================================
-- BMS Carrom — grants + missing queue UPDATE policy + DROP NOT NULL fixes
-- Live project ONLY: qigrifiqtarjgklfxmfg. Never run against
-- hyhlhngybzwnungnshff (dead project).
-- Run FIRST, before supabase/migrations/2026-11-28-find-match-fix.sql,
-- then run the test script (paste into the SQL Editor — see the fix report).
--
-- §1. DROP NOT NULL on live-only columns the app never sends. Same pattern
--     as the 2026-11-27 migration §3c, which already dropped NOT NULL on
--     matchmaking_queue.user_id for exactly this reason (the code never
--     sends user_id, so the constraint rejected every queue insert).
--     None of these three drops exists in any repo migration (checked:
--     the 2026-11-27 migration and supabase/schema.sql + schema-p2p.sql
--     contain no DROP NOT NULL on profiles.username or invites.from_user /
--     invites.to_user — the repo schema does not even have those columns;
--     they are live-only leftovers). Each statement is a no-op if the
--     column is already nullable, so the file is safe to re-run.
--       profiles.username : the app upserts profile_row() with gmail /
--         display_name / coins / xp / ... and never sends username, so a
--         new profile insert fails the live NOT NULL on username.
--       invites.from_user / to_user : the app sends invite_row() with
--         from_id / to_id and never sends from_user / to_user, so a new
--         invite insert fails the live NOT NULL on both old columns.
-- §2. The missing matchmaking_queue UPDATE policy. The queue has insert /
--     delete / select policies but NO update policy, and a PostgREST
--     upsert (POST ...?on_conflict=id) runs INSERT ... ON CONFLICT DO
--     UPDATE — the UPDATE leg has no policy, so every re-upsert of an
--     existing row 403s. The API log shows 15/15 queue upserts 403ing
--     while both rows exist (their FIRST inserts succeeded; every
--     heartbeat re-upsert after that 403s). Presence already has its own
--     UPDATE policy ("presence update own row") — the queue was the only
--     upserted table missing one. Consequence beyond the 403s: queue rows
--     go stale (level / stake / mode never refresh after the first insert).
-- §3. Grants, exactly as specified. NOTE on scope: grants and RLS are two
--     independent gates — a grant alone does not open a write, the policy
--     must also allow it. matches deliberately has NO insert/update
--     policy for authenticated (writes go only via the security-definer
--     RPCs), so granting UPDATE/DELETE on matches changes nothing there
--     until a policy is added; the grant is included because it was
--     specified and because PostgREST needs the table privilege for the
--     operations the policies DO allow.
-- ==========================================================================

-- ------------------------------------------------------- §1. DROP NOT NULLs
-- Live-only columns; the app never sends them (see header). Do NOT add a
-- DROP NOT NULL for matchmaking_queue.user_id here — the 2026-11-27
-- migration already did it (§3c, line 191).
ALTER TABLE public.profiles ALTER COLUMN username DROP NOT NULL;
ALTER TABLE public.invites ALTER COLUMN from_user DROP NOT NULL;
ALTER TABLE public.invites ALTER COLUMN to_user DROP NOT NULL;

-- ------------------------------------------- §2. Queue UPDATE policy (new)
-- Matches the sibling queue policies ("queue insert own row" /
-- "queue delete own row"): owner-only, keyed on id = auth.uid().
DROP POLICY IF EXISTS "queue update own row" ON public.matchmaking_queue;
CREATE POLICY "queue update own row" ON public.matchmaking_queue
  FOR UPDATE TO authenticated USING (auth.uid() = id) WITH CHECK (auth.uid() = id);

-- ------------------------------------------------------------------ §3. Grants
GRANT USAGE ON SCHEMA public TO anon, authenticated;
GRANT SELECT, INSERT, UPDATE, DELETE on profiles, presence, matchmaking_queue, invites, matches TO authenticated;

-- Reload PostgREST's schema cache LAST, so it picks up the new policy and
-- the grants as well (a stale cache is what produced the 42883
-- undefined_function 404s on find_match).
NOTIFY pgrst, 'reload schema';
