# BMS Carrom — Online play over P2P / WebRTC (v11)

v11 replaces the relay server for internet play. Online matches now run
**peer-to-peer over WebRTC**: the two (or four) phones connect directly
to each other. Supabase does only the parts a server used to do —
matchmaking, invites, and signalling — and the game traffic never goes
through any BMS server. **No server to host, no server cost.**

The old ENet relay in `server/` is **frozen, not deleted** (see
`docs/online-server.md`). It stays behind a transport switch for one
version as the rollback path.

## How a match starts

1. **Queue (random opponent).** The player picks 2 PLAYERS or
   4 PLAYERS and a stake. The client inserts one row into
   `matchmaking_queue` (id, display name, level, table band, stake,
   mode) and polls the `find_match` RPC every 2 s. The RPC pairs
   players on the **same table band** whose levels are within **±2**
   (widening to **±4** after 30 s), checks every player's stake
   against their `profiles.coins` (a row that staked more than it owns
   is deleted and the match fails), and writes one row into `matches`.
   The other side sees the same row by polling
   `matches?player_ids=cs.{my-id}&status=eq.waiting`.
2. **Invite (friends / lobby).** Accepting a group invite polls the
   `create_match_from_invites` RPC, which only creates the match once
   **every** invite in the group is `accepted`. The inviter is seat 0;
   the RPC is idempotent (calling it twice returns the same match).
3. **Signalling.** Both sides join the Supabase Realtime Broadcast
   channel `carrom-match-<match_id>` on the **one existing WebSocket**
   (the same socket that already carries `invites` postgres_changes).
   Signalling messages are plain JSON: `offer` / `answer` / `ice` /
   `bye`, each with `from` (the sender's seat) and `sdp` / `ice`
   payload. The lower seat offers to the higher seat(s); the answer is
   auto-created by `set_remote_description("offer", …)` — there is no
   `create_answer()` call in Godot 4.3.
4. **Transport.** Each side creates a `WebRTCMultiplayerPeer` mesh
   (`create_mesh(seat + 1)` — peer ids are seat+1, so seat 0 is peer 1).
   Once every peer is connected, the match starts. `_send()` sends via
   `rpc_id(opponent)` for 2p and loops over the other peers for 4p.
   A WebRTC disconnect mid-match raises `opponent_left`, same as the
   old relay path.

## Who breaks

Deterministic from the match id — no extra RPC, no host message:

```
breaker_seat = md5(match_id)[0] % player_count
```

Both sides already have the match id from the `matches` row, so both
derive the same breaker. Implemented in `scripts/p2p_signalling.gd`
(`breaker_seat_for_match`), with `NetClient.breaker_seat_for_match`
delegating to it. Tested: both 2p seats appear across 200 match ids,
all 4 seats across 400 ids (`tests/p2p_test.gd`).

## ICE / NAT traversal

`backend_config.json` → `turn_servers` (also in
`backend_config.example.json`). Defaults are the plan's free ones:

- Google STUN `stun.l.google.com:19302` (no credentials).
- OpenRelay demo TURN `turn:openrelay.metered.ca:80` /
  `turn:openrelay.metered.ca:443` (public demo credentials
  `openrelayproject` / `openrelayproject`).

STUN alone connects most home NATs. Symmetric NATs need a TURN relay;
the demo TURN is a **demo** — it works for testing and early play, but
a production TURN (own coturn, or a paid OpenRelay plan) is a
later decision, not a v11 blocker. If `turn_servers` is missing or
malformed, the client falls back to the defaults above; the game never
crashes for a bad ICE config.

## Match points (plan §4)

- **10 pts** per own coin pocketed (doubles: only your own coins count
  — your partner's coins never add to your points).
- **+25 pts** red-queen bonus, **only when the queen is covered**.
- **+50 pts** win bonus (loss/draw keep coin + queen points).
- Points feed XP/level 1:1 for online matches (solo/tournament pay
  none). Live "Points: N" line in the match HUD; the win screen shows
  points next to coins won. Tiers (retuned for the new scale):
  Contender 0, Challenger 100, Champion 250, Master 500,
  Grand Master 1000. See `scripts/match_points.gd`.

## Online lobby (§11)

ONLINE opens the lobby (`scripts/online_lobby.gd`): a radar sweep
animation, a live player list (display name + level + status
**Online / In a match** only — never Gmail, never coins), per-row
INVITE (2p, one tap) and a 4P toggle (pick up to 3, send disabled at
exactly 2 picks — 3-player matches do not exist), and the big
**2 PLAYERS — RANDOM OPPONENT** / **4 PLAYERS — RANDOM DOUBLES**
buttons. The list auto-refreshes every 10 s. Presence is a heartbeat
every 30 s into the `presence` table; a row older than 90 s counts as
offline (`scripts/friends.gd`: `PRESENCE_HEARTBEAT_SECONDS` /
`PRESENCE_OFFLINE_SECONDS`).

An incoming invite also shows an **instant banner at the top** of the
home screen: "You have an invite — play together with \<name\>",
ACCEPT joins directly, LATER dismisses it. The invite box stays as the
fallback.

## 3-player guard

Matches are **2 players or 4 players (doubles) only** — no 3-player
mode exists anywhere. `Friends.validate_group_targets` rejects exactly
2 targets at send time; the invite UI disables the 4-player send at
exactly 2 picks; `main.gd` re-checks before the stake picker.
Proven by `tests/p2p_test.gd` ("3p guard" checks).

## Files

| File | Role |
|---|---|
| `scripts/p2p_signalling.gd` | Pure signalling shapes, breaker derivation, ICE config |
| `scripts/net_client.gd` | Transport switch (P2P default / LEGACY_ENET), WebRTC mesh, `_send` |
| `scripts/supabase.gd` | Broadcast join/send on the one socket, queue/match/presence helpers |
| `scripts/online_lobby.gd` | §11 lobby (radar, live list, invites, random buttons) |
| `scripts/match_points.gd` | Per-coin points formula + tiers |
| `scripts/friends.gd` | 3-player guard, presence heartbeat, online-player filter |
| `supabase/schema-p2p.sql` | Queue + matches + presence tables, RLS, `find_match`, `create_match_from_invites`, Realtime publication |
| `tests/p2p_test.gd` | 69 headless checks (signalling, breaker, ICE, points, transport, broadcast, presence) |
| `tests/mock_supabase.py` | Mock gains queue/match RPCs, presence, and a fake Broadcast channel |
| `addons/webrtc_native/` | webrtc-native 1.2.2 GDExtension (Linux .so only in-repo; Android is a CI fetch — see below) |

## Setup (parent / dashboard steps — NOT done in the repo)

1. **Run the schema.** Supabase dashboard → SQL Editor → run
   `supabase/schema-p2p.sql` (see `docs/supabase-setup.md` §2b).
   It creates `matchmaking_queue`, `matches`, `presence`, the two
   RPCs, RLS, and adds `matches` + `presence` to the Realtime
   publication. `profiles.match_points` is added too.
2. **CI: fetch the Android webrtc-native build.** The release
   (webrtc-native 1.2.2) ships `libwebrtc_native.android.arm64.so`
   (and arm32 is **not** in the release — there is no armeabi-v7a
   build, so ONLINE must degrade gracefully on arm32 devices; the
   startup guard below covers it). The CI workflow
   (`.github/workflows/android.yml`) needs a step that downloads the
   release zip, verifies its checksum, and places the Android `.so`
   under `addons/webrtc_native/lib/`. Workflow files change only via
   the GitHub web UI — this is a parent action, not a repo edit.
3. **Live proof (T1/T2).** The sandbox cannot prove a WebRTC data
   channel (UDP is blocked). Two-real-phones test is still needed:
   T1 two phones on the same Wi-Fi (LAN-like path), T2 two phones on
   different networks (real STUN/TURN traversal).

## Startup guard / degradation

`NetClient.webrtc_available()` checks
`ClassDB.class_exists("WebRTCPeerConnection")`. If the plugin is
missing (e.g. arm32 build, or the addon not installed), ONLINE
degrades gracefully — it never crashes. `use_legacy_enet()` switches
the transport back to the frozen ENet relay for one version.

## Troubleshooting

| Symptom | Likely cause / fix |
|---|---|
| Search spins past 20 s, then "could not connect" | No peer found or NAT blocked: check `find_match` paired you (matches row exists), then ICE — try the other network; TURN may be needed (see ICE above). |
| Match found but peers never connect | Signalling didn't arrive: check the Broadcast channel joined (one socket, topic `realtime:carrom-match-<id>`); a stale `matches` row from a crashed search can also linger — it expires by `status` (`expire_match` is best-effort; RLS has no update policy for authenticated, so periodic cleanup is the real mechanism). |
| "3-player matches are not supported" | You picked exactly 2 friends for a group invite — pick 1 (2p) or 3 (4p). |
| Presence list empty | The other player hasn't been in the lobby in the last 90 s, or isn't signed in (refresh skips the fetch when signed out). |
| Points don't move | Points count only YOUR pocketed coins (doubles partner excluded) and only in online matches. |
| `net_test` fails headless | Expected — it needs a live matchmaking server (frozen ENet path). Not a v11 regression. |

## What v11 does NOT do (still open)

- Server-side coin ledger (stakes are validated at matchmaking, but
  the pot payout is still client-side — see plan §4).
- Match-points sync to Supabase (`profiles.match_points` column
  exists in the schema; the client does not write it yet).
- Production TURN (demo TURN only — see ICE above).
- Oracle host env vars for F13 Phase 2 (the frozen server's deploy
  path, kept for the rollback only).
