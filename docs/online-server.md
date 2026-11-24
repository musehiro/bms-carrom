# BMS Carrom — Online Server

> **FROZEN in v11 — do not extend, do not delete.** Internet play moved
> to peer-to-peer WebRTC (see `docs/p2p-online.md`); this server is kept
> only as the one-version rollback behind the transport switch in
> `scripts/net_client.gd` (`use_legacy_enet()` / `TRANSPORT_LEGACY_ENET`).
> No new features go here. The Oracle host env vars for F13 Phase 2 are
> still open for this path, but only as rollback support.

Real online multiplayer needs a server: it matches players of similar
level, then relays their shots. The server is deliberately tiny — it does
**not** simulate physics (both clients simulate the same shot inputs and
resync with a full state snapshot after every shot). That keeps hosting
cheap and the server easy to run anywhere.

## What the server is

- `server/` in this repo — a small headless Godot 4.3 project.
- `server/net_server.gd` — matchmaking queues + relay (autoload `Net`).
- `server/server_main.gd` + `server/server.tscn` — keeps the tree alive.
- Default port **8910**, ENet (UDP). One process serves all matches.

## How matchmaking works

### 2-player (singles)
1. Client sends `{"type":"queue","name","level","table","stake","mode":"2p"}` —
   `table` is only the matchmaking **band** (from the stake: <250 → 0,
   <1000 → 1, else 2); `stake` is the player's own virtual-coin stake
   (0 = friendly match).
2. Server pairs two players on the **same band** whose levels are within
   **±2**. If either player has waited **30 s**, the window widens to **±4**.
3. Both get `{"type":"matched","opponent","opp_level","you_break","opp_stake"}`.
   One of them breaks (random). Each side learns the opponent's stake, so
   both clients can show the pot (your stake + opponent's stake) and pay
   it out: winner takes the whole pot, a draw refunds both stakes.
4. During the match the server only relays `shot`, `state` and `forfeit`
   messages between the pair. If a player disconnects, the other gets
   `opponent_left` (and wins).
5. If no opponent is found in 12 s, the client offers a clearly-labelled
   **BOT practice match** — never a fake human. The practice match is free
   and pays zero coins (solo pays nothing in v5).

### 4-player (doubles, v6)
- A **separate queue** (`"mode":"4p"`). One player per side; opposite
  sides are partners (seats 0,2 vs 1,3). Turn order rotates seat 0→1→2→3.
- The server collects 4 players on the same band whose levels are all
  within the window (±2, ±4 after 30 s) of the first player's level.
- Each client gets the full seat-ordered roster
  (`{"type":"matched","mode":"4p","players":[{name,level,stake,seat}…],
  "your_seat","breaker_seat","you_break"}`) — so every phone can show
  the teams, the pot and whose turn it is.
- Staking: each of the four stakes their own amount; the pot is all four
  stakes. The winning **team** splits the pot equally between the two
  partners (an odd leftover coin goes to the team's first seat). A draw
  refunds every player's own stake.
- If a player leaves mid-match, the rest get `opponent_left` with the
  leaver's seat, so clients can work out which team forfeited (partner
  left = your team loses; opponent left = your team wins).
- LAN (below) is 2-player only in v6; 4-player needs the internet server.

### Random matchmaking + lobby + match points (v11)
- **Random matchmaking:** ONLINE → choose a game (2p singles or 4p
  doubles) → tap to play with a random person. The client entry is
  `NetClient.queue_random(...)` (alias of `queue_up`, same
  `{"type":"queue",...}` message); Main's stable entry is
  `Main.start_random_match(stake, players)`. The server pairs players
  on the same stake band within ±2 levels (±4 after 30 s) — nobody
  picks a name or an opponent. A search can be cancelled without
  dropping the connection (`{"type":"leave_queue"}`).
- **Lobby:** when the server sends `matched`, the game does NOT jump
  straight into the match — it opens the MATCH LOBBY (roster with
  names, levels, teams in 4p, and each player's READY state). Each
  player taps I'M READY, which sends `{"type":"lobby_ready","seat":n}`
  through the existing ENet relay (the server relays it to the room
  exactly like a shot/state message — no WebRTC, no Supabase
  signalling; the room already exists by then). The match starts
  when everybody is ready, or automatically after 30 s (silent
  players count as ready, so a lobby can never stall). Leaving the
  lobby sends `{"type":"lobby_leave"}` — the server dissolves the
  room and the rest get `opponent_left` and go home.
- **Match points:** online matches only (solo/tour pay none). Win
  +3, draw +1, loss +0; in doubles the whole winning team earns the
  points. The lifetime total lives in the local save
  (`Save.match_points`, shown on the result screen and in the lobby
  with its tier: Contender <10, Challenger <25, Champion <50,
  Master <100, Grand Master 100+). It is NOT synced to Supabase yet
  — the `profiles` table has no `match_points` column, so cloud sync
  needs a Supabase migration first.

### Win screen + doubling (v6)
- An online win does NOT credit the pot immediately: the premium win
  screen holds it until the player taps COLLECT (base pot) or watches
  2 rewarded ads to DOUBLE it. Closing the screen without collecting
  credits the base pot — coins are never lost.
- Each of the 2 doubling ads ALSO pays the ad ladder (and advances it);
  the doubling is on top of the ladder coins. The ladder's daily cap
  (2,500) applies to ladder coins only, never to a doubled pot.

## Scale — honest numbers (v6, for 100K–200K players)

The server is built to scale in the right shape: one matchmaking queue
per mode + independent game rooms. Matching runs ONLY when the queue
changes (a player queues or leaves) plus once a second for the 30 s
widening — never every frame — so a big queue stays cheap. Each match is
just 2–4 peers relaying small JSON messages a few times per minute.

- **What one free server can actually hold:** a single Oracle Always
  Free VM (Ampere A1, 1 OCPU / 6 GB) realistically holds **~1,000–2,000
  concurrent players / 500–1,000 simultaneous matches** (ENet cap is
  1,024 peers per process; the real limit is CPU + bandwidth, and a
  match's traffic is tiny). That is plenty for launch.
- **What it can NOT hold:** 100K–200K players *simultaneously* on one
  free VM. 100K–200K *registered/total* players is fine on one server —
  only the concurrent count matters, and early on only a fraction are
  online at once.
- **When it outgrows one VM:** run one server process per region and let
  the client pick the nearest (the protocol is identical), then add more
  VMs behind a simple list. That step is paid hosting — funded by the ad
  revenue the game earns by then, not by the player.

## No internet server yet — use NEARBY (LAN) for now (v6)

Two real phones **can** play each other today without any server: on the
same Wi-Fi, one phone taps PLAY → NEARBY → HOST A MATCH, the other taps
NEARBY → JOIN A MATCH. The host phone runs the server in-process and
advertises itself with a UDP broadcast on port 8911; the joiner connects
directly to it (manual IP entry is offered too, in case the router
blocks broadcasts). Same stakes, same pot rules, no BOT fallback while
hosting. LAN is 2-player only in v6.

## Host it for real players (free tiers)

The server is a plain Linux binary: `godot --headless` + the `server/`
folder. It uses almost no CPU/RAM (no physics, no rendering).

### Option A — Oracle Cloud Always Free (recommended)
1. Create a free Oracle Cloud account, launch an **Always Free** VM
   (Ampere A1, Ubuntu 22.04). **Oracle requires a credit/debit card for
   identity verification when creating the account** (a temporary
   authorization hold, not a charge — but the card is mandatory, and
   prepaid/virtual/single-use cards are refused). The card must be
   entered by the account owner in the browser; the agent cannot do it.
2. Copy the `server/` folder to the VM and install Godot 4.3 headless:
   `wget https://github.com/godotengine/godot/releases/download/4.3-stable/Godot_v4.3-stable_linux.x86_64.zip`
   then `unzip` it and use the binary.
3. Open UDP port **8910** in the VM firewall *and* in the Oracle
   security list (Ingress rule, UDP, port 8910, source 0.0.0.0/0).
   Prefer the **Singapore** home region (closest to Sri Lanka + South
   Asia); Mumbai is the fallback.
4. Run it persistently, e.g. with systemd (see
   `server/deploy-oracle.sh` for a ready-made setup script):
   ```
   [Unit]
   Description=BMS Carrom server
   After=network.target
   [Service]
   ExecStart=/home/ubuntu/godot --headless --path /home/ubuntu/bms-carrom-server -- --port 8910
   Restart=always
   [Install]
   WantedBy=multi-user.target
   ```
5. Note the VM's public IP and type it into the game's NEARBY screen
   (INTERNET SERVER field → SAVE); ONLINE will use it from then on.

### Option B — Fly.io (NOT free for new accounts any more)
Fly.io removed its free tier for new orgs in Oct 2024 (trial $1/7 days,
then a card is required; the smallest always-on machine is ~$2.19/mo
plus ~$2/mo for the dedicated IPv4 that UDP needs). Not a free option —
listed here only so nobody wastes time on it.

### Option C — any cheap VPS / home PC
Any Linux machine with a public IP (or port-forwarded UDP 8910) works:
a Raspberry Pi, an old PC, or the cheapest VPS. Same command as above.
(Render/Railway/Heroku and Cloudflare Tunnel are HTTP/TCP only and
cannot carry the server's raw UDP. ngrok's free tier is HTTP/TCP only.)

### Why there is no hosted server yet
No free hosting exists that needs neither an account nor a card: every
free cloud tier requires an account, and Oracle (the recommended one)
also requires a card for verification. The sandbox VM this agent runs
in cannot host it either — it has no public IP and no inbound traffic,
and all UDP is blocked there. So the account + card step belongs to
Buddhika, in the browser.

## Point the game at the server

In the game, the server address is stored in the local save
(`Save.online_host`, default `127.0.0.1`). For a hosted server, type the
server's public IP or hostname into the NEARBY screen's INTERNET SERVER
field and tap SAVE — ONLINE will use it from then on. No new build is
needed to change the address.

## Run it locally (testing)

```bash
# From the repo root. Needs the Godot 4.3 binary.
godot --headless --path server -- --port 8910
```

Then set the server address in the game to `127.0.0.1` (the default) and
play Online — two game instances on the same machine will match each other.

## Status

- ✅ Server builds and runs headless; 2p + 4p matchmaking verified with
  unit tests (23 server checks) and LAN host-mode tests (16 checks).
  See `docs/verification.md`.
- ✅ LAN (same-Wi-Fi) play works in v6 — two phones on one Wi-Fi can
  match today, no server needed.
- ⚠️ **Not yet verified over the internet** — that needs a hosted server
  (Option A above: Oracle account + card entry by Buddhika in the
  browser) plus two real devices. Do not claim worldwide online works
  until that test passes.
