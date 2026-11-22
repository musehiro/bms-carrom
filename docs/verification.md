# BMS Carrom v1 — Verification Log

Date: 2026-11-21. All checks run on this machine (Linux VM, Godot 4.3
stable, `~/tools/godot/Godot_v4.3-stable_linux.x86_64`).

## 1. Headless import — PASS

`godot --headless --import --path .` — 0 script errors.
`godot --headless --import --path server` — 0 script errors.

## 2. Logic tests — 64/64 PASS (3 runs)

`godot --headless --path . -s tests/test_runner.gd` — exit 0, three
consecutive runs, no failures. Covers:

- Setup: 9 white + 9 black + 1 queen + 1 striker, queen on centre, all
  coins inside the outer circle.
- Physics: shot moves + stops, pocket capture, cushion bounce, striker→
  coin momentum transfer, **no pocket magnet** (a still coin near a
  pocket is not sucked in).
- Rules: keep-turn on own pocket, queen-before-first-coin returns,
  queen pending → cover on next shot, missed cover → queen returns,
  last coin with queen on board loses, last coin with queen covered
  wins, striker foul alone (lose turn + due), striker + own coins
  (coins return, keep turn), pocketing opponent's last coin loses,
  due owed then paid from the first pocketed coin.
- AI: break shot near full power, mid-game shot valid, Easy has real
  aim spread.
- Shop: best striker ≤ +15% force/aim vs default, 6 boards, 7 strikers.
- Ray-circle aim math, full break simulation settles + resolves.
- **Full AI-vs-AI match (Hard): finishes in 36–43 shots** with queen
  returns and fouls occurring naturally; winner determined by the rules.

## 3. Server matchmaking logic — 7/7 PASS

`godot --headless --path . -s tests/server_test.gd` — exit 0. Drives the
real `server/net_server.gd` queue + `_try_match`: ±2 levels match, 9
levels apart do not, ±4 after 30 s wait, different tables never match,
disconnect removes the queue entry.

## 4. Ads fallback — PASS

`godot --headless --path . res://tests/ads_test.tscn` — exit 0. On a
non-Android build the native AdMob singleton does not exist, so
`Ads.show_rewarded("coins")` takes the clearly-labelled simulated path
and emits `rewarded_earned(reason=coins, simulated=true)` after 1.2 s.
On Android the real Poing plugin loads/shows real test ads (test IDs
only — see `scripts/ads_config.gd`).

## 5. Online — PARTIAL (honest status)

- Server starts headless and binds UDP 8910 (confirmed with `ss`).
- Matchmaking *logic* verified (see §3).
- **Live two-client handshake could NOT be verified here**: this VM
  blocks loopback UDP sends (`PermissionError: Operation not permitted`
  on a plain Python UDP sendto between two local processes), so ENet
  clients get `connection_failed` even though the server socket is
  listening. This is a sandbox restriction, not a code failure — but it
  means the ENet handshake is unproven until it runs on a real machine
  or a hosted server. Do NOT claim worldwide online works until two
  real devices match through a hosted server (see
  `docs/online-server.md`).

## 6. Screenshots — checked by eye (xvfb, software GL)

`verification/` — home, match in progress, shop, How to Play at
720×1280, plus home + match at 720×1640. All reviewed:

- Home: gold PLAY, Solo/Online, Shop/How to Play/Aim-Assist, daily
  bonus (+200 day 1), coins, level — clean.
- Match: board, pockets, markings, coins, HUD panels, turn label,
  timer bar — clean. No false "Break missed" after the fix (see §7).
- Shop: all 6 boards listed with prices/level locks — clean.
- How to Play: centred square window, red X, scrollable rules — clean.
- 720×1640: layout holds (content top-anchored, clean empty space
  below on the taller screen).

## 7. Bugs found and fixed during verification

1. **Shop empty / popups off-screen** — `set_anchors_preset(FULL_RECT)`
   preserved the zero size for runtime-created screens (offsets ended
   up `0,0,-720,-1280`). Fixed with an explicit `UiKit.full_rect()`
   (direct anchor/offset properties) plus explicit centring for popups.
2. **False "Break missed"** — the break-contact check used mutable
   piece Dictionaries as Dictionary keys; their hash changes as physics
   mutates them, so the lookup always missed. Fixed with index keys.
3. **Daily bonus showed +150 on day 1** — streak started at 0.
   Fixed: day 1 is +200.
4. **Test bug** — shop stat-cap check failed on float precision
   (100×1.15 = 114.999…). Fixed with an epsilon.

## 8. NOT verified (needs Buddhika / a real device)

- Real on-device play (touch aiming, feel, performance on a phone).
- Real AdMob test ads on Android (test IDs are wired in; only the
  simulated path has run).
- Online matchmaking over the internet (needs a hosted server + two
  devices).
- The APK itself — CI cannot run until the workflow file is added via
  the GitHub web UI (see the ship report). No APK exists yet.

---

# BMS Carrom v2 — Verification Log

Date: 2026-11-22. Fixes Buddhika's v1 playtest (two phone screenshots):
PLAY dead-ended in "FINDING OPPONENT" (only CANCEL); touch-drag did not
move the striker or aim at all; graphics too flat/dark.

## 1. Root cause of the aiming bug (diagnosed, not guessed)

`Main` is a full-screen `Control` with the default `mouse_filter = STOP`.
In Godot 4 a STOP control covering a point consumes the event, so
`MatchScreen._unhandled_input` never fired for any touch — the exact
same class as Shadow Assassin v2's full-screen ColorRect bug. Proven by
`tests/input_test.tscn`: before the fix, a real touch-drag via
`Input.parse_input_event` left the striker unmoved (FAIL) while a direct
`_unhandled_input` call with the same events slid it fine (PASS) — the
handler logic was correct, delivery was broken. Also found while testing:
headless runs with a 64×64 dummy window, so the engine scales parsed
input positions by visible/window (20× here); the test divides event
positions by that factor (real phones: scale 1).

## 2. Input test — 9/9 PASS (`tests/input_test.tscn`)

`godot --headless --path . res://tests/input_test.tscn` — exit 0.
Drives the REAL Main scene and feeds synthetic touch events through
`Input.parse_input_event` (the phone's path):
- A: real touch-drag slides the striker along the baseline.
- B: direct `_unhandled_input` call slides (control).
- C: real pull-back aim + release fires a shot (phase "shooting").
- D: PLAY opens a mode-choice popup (SOLO / ONLINE), never matchmaking.
- E: online search offers the labelled-BOT fallback after 12 s.

## 3. Logic tests — 64/64 PASS (no regressions)

`godot --headless --path . -s tests/test_runner.gd` — exit 0.
Headless import: 0 script errors (only the pre-existing warning about
the `server/` sub-project).

## 4. Screenshots — checked by eye (xvfb, software GL)

`verification/` — home + match at 720×1280 and 720×1640, plus
`playchoice-720x1640.png` (PLAY mode-choice popup) and
`search-720x1640.png` (search at 12 s with the BOT fallback button).
- Home: warmer background, big glossy board preview, gold title +
  divider, PLAY + SOLO/ONLINE + SHOP/HOW TO PLAY/AIM-ASSIST, daily
  bonus, "BMS Carrom v2.0".
- Match: richer wood (plank tones, centre glow, sheen), deeper pockets
  with rim light, glossier coins, warm backdrop filling the tall screen.
- PLAY popup: SOLO (gold) + ONLINE buttons, red X — clean.
- Search at 12 s: "No opponent yet — play vs the computer instead."
  + "NO OPPONENT? PLAY vs COMPUTER INSTEAD" + CANCEL — clean.

## 5. Bugs found and fixed during verification

1. **Aiming dead (v1 playtest)** — root cause above. Fixed: `Main`
   `mouse_filter = IGNORE` (`scripts/main.gd`); every non-interactive
   HUD piece in `scripts/match.gd` set to IGNORE (panels, labels,
   timer/power bars, dots); pause Button stays interactive. Also a
   forgiving grab: touching the baseline band starts a slide.
2. **PLAY dead-end (v1 playtest)** — PLAY jumped straight into online
   matchmaking (host is 127.0.0.1, no server), popup with only CANCEL.
   Fixed: PLAY opens a mode-choice popup (SOLO / ONLINE); the search
   reveals "PLAY vs COMPUTER INSTEAD" after 12 s (was 60 s) and the
   status text says so.
3. **Home mini board painted over the title** — the new full-screen
   backdrop rect in `BoardView._draw` is drawn after the title in tree
   order and, scaled 0.55, covered it. Fixed: `draw_backdrop` flag
   (default true for the match, false for the home mini).
4. **Test-harness input scaling** — headless 64×64 dummy window scales
   parsed input 20× (see §1). Fixed in the test, not the game.

## 6. Still honest (unchanged from v1)

- Online matchmaking over the internet needs a hosted server + two real
  devices to verify live. The 12 s fallback means the game is never
  stuck, but worldwide online is NOT claimed working.
- Real on-device touch feel can only be confirmed by Buddhika playing
  the APK on his phone.

## v6 verification (2026-11-22, commit 90c2572e)

### Test suites (all green, 197 checks)
- Logic (rules/physics/AI/stakes/economy, incl. 4p rules + 4p stakes):
  87/87 — `godot --headless --path . -s tests/test_runner.gd`
- Server (2p + 4p matchmaking, rooms, dissolve, payloads): 23/23 —
  `tests/server_test.gd`. NOTE: the old test referenced `server._matches`,
  which the v6 rewrite replaced with `_rooms`/`_peer_room`; the stale
  reference aborted `_initialize` before `quit()`, so the run hung with
  no output (piped through `tail`). Fixed by rewriting the test for
  rooms. The rpc_id errors in the log are the fake-peer calls in the
  harness — harmless.
- LAN host mode (beacon round-trip, parse rejections, host state
  machine): 16/16 — `tests/lan_test.gd`
- Aim prediction: 19/19 — `tests/aim_predict_test.gd`
- Win screen + doubling (full path: pot held → 2 ads → doubled pot +
  ladder → collect → exit credits base pot): 20/20 —
  `tests/win_double_test.tscn` (xvfb)
- Input: 9/9 — `tests/input_test.tscn`
- Popup flow (incl. new 2P/4P choice step): 18/18 —
  `tests/popup_flow_test.tscn`
- Double-tap (android event sequence): 5/5 —
  `tests/popup_double_test.tscn`
- Ads (simulated rewarded): pass — `tests/ads_test.tscn`

### Screenshots (looked at, in verification/v6/)
- `shot-nearby-720x1280.png` + `shot-nearby-720x1640.png` — NEARBY screen,
  clean after the autowrap fix below.
- `shot-lanhost-720x1280.png` — HOSTING ON WI-FI popup (stake 100,
  "Hosting on Wi-Fi… 1s"), home dimmed behind it.
- `shot-search4p-720x1280.png` — 4p search: "No players yet — play vs
  the computer instead." + "winning TEAM splits the pot (all four
  stakes)".
- `shot-win-720x1280.png` + `shot-win-720x1640.png` — premium win
  screen: ★ WINNER ★, gold COLLECT ◉ 200 big, purple
  "WATCH 2 ADS / DOUBLE TO ◉ 400", ladder note, XP/level/score line,
  FIND REMATCH + HOME.
- `shot-home-720x1280.png` — home unchanged from v5, clean.

### Bugs found and fixed during v6 verification
1. **NEARBY screen blown out past the right edge** — the long server-note
   label had no autowrap, so its minimum width (~1159 px) forced the
   whole VBox to 1159 wide (measured via a debug tree dump: VBox
   size=(1159, 1140), min=(1159, 711)). Fixed: `autowrap_mode =
   TextServer.AUTOWRAP_WORD_SMART` on the server note + the subtitle in
   `scripts/nearby.gd`. Re-shot: clean.
2. **Stale global class cache** — `main.gd` failed to parse
   ("Could not find type NearbyScreen") because the editor's
   `global_script_class_cache.cfg` predated `scripts/nearby.gd` and
   headless runs never refresh it. Fixed: one
   `godot --headless --editor --quit` import; the cache now lists
   NearbyScreen. (Side effect: the editor re-downloaded the AdMob iOS
   plugin into `addons/admob/downloads/` — local-only, NOT pushed.)
3. **Flow test F4 vs the new 2P/4P choice** — the test expected the stake
   picker to go straight to the search popup; v6 inserts the 2P/4P
   choice. Fixed the test to tap "2 PLAYERS" first (18/18).
4. **4p search status text at 12 s** — `_process` overwrote the 4p
   wording with the generic 2p text. Fixed: status text is now
   mode-aware (`_search_players`).

### Still honest (v6)
- No hosted internet server exists yet — Oracle needs an account + a
  card for verification (Buddhika enters it in the browser; see
  `verification/v6/oracle-signup-handoff.md` and
  `server/deploy-oracle.sh`). Worldwide online is NOT claimed working.
- Live two-phone LAN matching + live 4-player matching can only be
  confirmed by Buddhika on real phones (UDP is blocked in this sandbox,
  so no live handshake is testable here).
- Real on-device touch feel (incl. side-seat slide/aim for 4p) can only
  be confirmed by him playing the APK.
- No real-money code anywhere; stakes are virtual coins only.

## v7 verification (2026-11-22)

Mandatory registration (Buddhika 2026-11-22 13:34 — NO guest mode),
Gmail login + profile restore, friend search + invite box, 2-player
and 4-player invites, Supabase free backend (card-free).

### 1. What changed
- **Auth first**: the game opens on the register/login screen
  (`scripts/auth_screen.gd`) — display name + Gmail, REGISTER &
  PLAY / SIGN IN tabs, SIGN IN WITH GOOGLE. No guest mode anywhere:
  no "Play as guest" button, no playing before login (auth-flow test
  A1/A2). The logo is just the carrom board (BoardView, no text).
- **OTP is the account**: registration creates the local account;
  a 6-digit code sent to the Gmail verifies it, and that OTP sign-in
  IS the account — the Supabase Auth user id for the Gmail becomes
  the profile id, so exactly one account per Gmail and reinstall +
  same-Gmail sign-in restores coins, level, XP, stats and shop
  ownership (last-write-wins if the local copy is newer). A
  "VERIFY GMAIL" banner stays on home until the Gmail is proven, so
  an unverified account is never silently unprotected.
- **Google one-tap**: PKCE loopback (`http://127.0.0.1:8765/callback`,
  no plugin, no deep-link intent). Falls back to Gmail + code when
  the Google provider is not set up yet.
- **Friends + invites** (`scripts/friends.gd`): search by display
  name only (RPC returns id + name + level, never Gmail/coins);
  invite box as a side panel on home (✉ button with pending count):
  incoming invites with ACCEPT / DECLINE, sent invites (waiting),
  FRIENDS search + INVITE (2p) and 4P multi-select + SEND 4-PLAYER
  INVITE (up to 3 friends). Accept -> choose YOUR OWN stake ->
  join the game server's invite room (group_id); the server starts
  the match when everyone has joined (inviter seat 0, invitees
  1.. in join order), 3-minute room timeout, stakes lock only at
  match start. Invites expire after 24 h; Realtime delivers them
  live, with a 10 s poll as backstop.
- **Backend** (`scripts/supabase.gd`, `supabase/schema.sql`,
  `docs/supabase-setup.md`): Supabase free, card-free. The v7 APK
  ships with an empty `backend_config.json` — the game runs
  local-only (registration works, invites show "not connected yet")
  until the parent creates the project in the browser (exact steps
  in the setup doc, no card at any step) and fills in the URL + anon
  key; a config-only update then activates cloud accounts/invites.
  No service_role key anywhere; RLS enforces own-rows-only.
- **Design correction found in testing**: anonymous-first sign-in
  was WRONG — the anonymous user id differs from the email user's
  id, so the profile would land under the wrong id and restore
  would break. Registration now does NOT sign in anonymously; the
  OTP-verified Gmail is the account from the start.

### 2. Tests — 333 checks green (all suites re-run)
- Logic (test_runner.gd): 104/104 — incl. 16 new v7 checks
  (PKCE RFC 7636 vector, Realtime message parsing, profile/invite
  row builders, invite_join message).
- Server (server_test.gd): 38/38 — incl. 15 new invite-room checks
  (2p join -> room, inviter seat 0, duplicate join ignored,
  wrong-table refused, 4p room of 4, leaver dissolves the group,
  ready/order/infos helpers).
- LAN 16/16, aim 19/19, stakes 32/32 (no regressions).
- Accounts scene (accounts_test.tscn): 32/32 — name/Gmail
  validation, last-write-wins resolve, uuid shape, group state
  machine, invite expiry.
- Supabase mock scene (supabase_mock_test.tscn): 28/28 — the REAL
  client + Accounts + Friends against a local Python mock of
  GoTrue/PostgREST/Realtime: anonymous signup, register, OTP
  send/wrong/right, cloud profile create + restore, search
  (no Gmail in results), 2p invite send/accept, 4p group
  waiting -> ready, Realtime invite arriving live in the box,
  Google loopback exchange (code TESTCODE -> Gmail linked).
- Win-double 20/20, input 9/9, popup flow 18/18, popup double
  5/5, ads simulated pass (no regressions).
- Auth-flow scene (auth_flow_test.tscn): 11/11 — auth screen
  first, no guest button, register -> home, invite box opens with
  ACCEPT/DECLINE, ACCEPT -> stake picker, 4P select -> SEND
  4-PLAYER INVITE appears.

### 3. Screenshots — checked by eye (xvfb, software GL)
In `verification/v7/` (720x1280 + 720x1640 each):
- `shot-login-*` — register/login screen: board-only logo, tabs,
  name + Gmail fields, REGISTER & PLAY, SIGN IN WITH GOOGLE,
  "BMS Carrom v7.0 • Account required • Free to play". No guest path.
- `shot-invitebox-*` — home with the invite box open: 2p + 4p
  incoming invites (ACCEPT/DECLINE), waiting sent invite, FRIENDS
  search with results (4P + INVITE).
- `shot-invite-*` — accepting an invite: the stake picker on top
  ("Accepting Nimal's invite — choose YOUR stake").
- `shot-invite4p-*` — two friends selected (4P ✓), SEND 4-PLAYER
  INVITE (2) + the wrapped note naming them.

### 4. Bugs found and fixed during verification
1. **Class hides an autoload singleton** — `class_name Accounts` /
   `class_name Friends` collided with the autoloads of the same
   name. Fixed: no class_name on autoload scripts (SupabaseClient
   keeps its distinct class name); tests load the scripts by path.
2. **-s test runner cannot compile autoload-referencing scripts**
   — `Save`/`Supabase` are not registered identifiers under `-s`,
   so accounts.gd/friends.gd failed to load there. Fixed: the
   accounts/friends pure tests moved to a scene test
   (accounts_test.tscn) where autoloads exist.
3. **Null profile row crashed verify** — `get_profile_by_*` returned
   `data: null` when no row existed; typed Dictionary assignment
   rejected it. Fixed: return `{}` for "not found" (callers test
   `is_empty()`).
4. **Realtime used wss against the plain-http mock** — TLS handshake
   error. Fixed: ws:// for http base URLs, wss:// for https.
5. **Test signal helper never fired** — a lambda capturing a local
   bool captures it by value. Fixed: member-var flag.
6. **Invite box panel never visually closed** — the close branch
   freed only the dim, not the panel; the panel stayed on screen
   (caught by the auth-flow test). Fixed: queue_free the panel too.
7. **Invite box overflowed right (4p)** — a long non-wrapping
   muted_label widened the ScrollContainer child past the panel,
   and the long SEND button text did the same. Fixed: horizontal
   scroll disabled, autowrapping note, shorter button text,
   fixed-width SEARCH/4P buttons.
8. **`LineEdit.keyboard_type` int assignment rejected at runtime**
   — removed the three keyboard-type hints (cosmetic only).

### 5. Still honest (v7)
- The Supabase project does NOT exist yet — the parent must create
  it in the browser (docs/supabase-setup.md, no card). Until then
  the shipped APK registers locally and invites show "not connected
  yet"; cloud restore/invites activate with a config-only update.
- Live Gmail login on real phones, live two-device invite/match
  flow, and live Google one-tap can only be confirmed by Buddhika
  playing (sandbox cannot do live Google Sign-In or two-phone
  handshakes). Verified instead: the full flow against the local
  mock (28 checks) + the real server's invite rooms (15 checks).
- No hosted internet game server yet (AWS signup in progress by
  Buddhika; Oracle refused on the card step) — invite matches need
  the game server; until it is up, accepting an invite says so and
  NEARBY is the way to play together.
- No real-money code anywhere; stakes are virtual coins only.
