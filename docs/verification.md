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

## v8 verification (2026-11-22)

World Tour — advanced computer opponents with names, countries,
cartoon avatars and skill levels; stakes like a real match; solo
stays free with a watch-an-ad-to-earn offer. Two real bugs found
and fixed during verification (below).

### 1. What changed
- **World Tour roster** (`scripts/world_tour.gd`, `scripts/tour_roster.gd`):
  5 bots — Arjun Mehta (India, ADVANCED, Lv 12), Kasun Perera
  (Sri Lanka, ADVANCED, Lv 14), Sarah Collins (England, EXPERT,
  Lv 18), David Chen (USA, EXPERT, Lv 21), Emma Wilson (Canada,
  MASTER, Lv 26). Each card shows a cartoon avatar (coloured face,
  eyes, smile — no photos), country • skill • level, a blurb, and a
  BOT tag. Honest labelling is the hard rule: the roster says
  "Advanced COMPUTER opponents from around the world. Every opponent
  is a BOT — clearly marked. No real players here." No "searching for
  a real player", no fake-human wording anywhere (checked by test).
- **Advanced AI** (`scripts/ai.gd`): difficulties 3/4/5 above Hard —
  aim error 0.15°/0.10°/0.05°, power error 0.02/0.015/0.01, never
  miss outright, always chase the queen. Game sense: queen-cover
  urgency (+200 own-coin bonus while the queen is pending for the
  AI), defensive play when ahead by 2+ (no queen chase, cut-angle
  penalty), striker safety (150 penalty when the striker's estimated
  rest spot lands within 70 px of a pocket), one-cushion bank shots
  (mirror geometry, pocket + path checks).
- **Tour economy** (`scripts/match.gd`): stakes lock at match start
  (see bug 1); pot = both stakes, winner takes it all, draw refunds;
  premium win screen with COLLECT (pot big) + WATCH 2 ADS → DOUBLE
  (pot x2, each doubling ad also pays the ad ladder); tour_wins
  counted; no daily cap (the hard bots limit farming). Losing costs
  the stake; the loss screen names the bot.
- **Solo** (`scripts/match.gd`): free, no coins — win pays zero;
  the win screen offers WATCH 1 AD → EARN the ladder amount
  (one ad, same as FREE COINS); solo_wins counted.
- **Backend config**: v8 ships with the LIVE Supabase URL + anon key
  in backend_config.json (parent verified the key live — auth health
  endpoint returns HTTP 200). No service_role key anywhere.
- Home footer now reads "BMS Carrom v8.0 • Account required •
  Free to play".

### 2. Tests — 404 checks green (all suites re-run)
- Logic (test_runner.gd): 150/150 — incl. 46 new v8 checks
  (roster 10: 5 bots + honest-labelling UI check; tour stakes 9:
  mirror + pot 2x + payout win/loss/draw; advanced AI 8: ERRORS
  table ordering + Master accuracy < 0.005 rad mean error;
  queen-cover 4 incl. bank cover; defensive play 4; bank-shot
  geometry 6 incl. fence integration; striker-safety 5).
- Win-double scene (win_double_test.tscn): 46/46 — incl. 26 new
  v8 checks (real tour match: stake locked at start, pot held 200,
  COLLECT ◉ 200, DOUBLE TO ◉ 400, doubled pot + ladder credited,
  tour_wins++; tour loss: stake lost, loss screen names the bot;
  solo win: zero coins, WATCH 1 AD → ladder paid, earn button
  disables). The ad ladder is reset at the start of the run so the
  ladder math is deterministic across repeated runs.
- Server 38/38, LAN 16/16, aim 19/19, stakes 32/32, accounts 32/32,
  Supabase mock 28/28, input 9/9, popup flow 18/18, popup double
  5/5, auth flow 11/11, ads simulated pass (no regressions).

### 3. Screenshots — checked by eye (xvfb, software GL)
In `verification/v8/` (720x1280 + 720x1640 each):
- `shot-tour-*` — World Tour roster: all 5 bots with BOT tags,
  countries, skills, levels, blurbs, cartoon avatars; honest
  subtitle; "Stakes like a real match: winner takes the pot."
- `shot-tourmatch-*` — tour match in progress: "Arjun Mehta (BOT)
  Lv 12" top panel, board mid-game, player panel below.
- `shot-tourwin-*` — ★ WINNER ★, "Your stake ◉ 100 + Opponent
  stake ◉ 100", "World Tour — you beat Arjun Mehta (BOT)",
  COLLECT ◉ 200, WATCH 2 ADS → DOUBLE TO ◉ 400, XP +150.
- `shot-solowin-*` — ★ WINNER ★, "Practice win — no coins
  earned.", WATCH 1 AD → EARN ◉ 150, "★ PRACTICE WIN ★ TAP TO
  CONTINUE", XP +150 (LEVEL UP in one capture).

### 4. Bugs found and fixed during verification
1. **Stakes were never deducted — every staked match was free**
   (CRITICAL, economy): `_ready()` runs at add_child, which main.gd
   calls BEFORE setup(), so in _ready mode was still "" and the
   stake 0 — the deduction never fired. A player could stake 100,
   win, and collect the full 200 pot without ever paying in, in
   tour AND online matches (v6/v7 too). The v7 win-double test never
   caught it because it forged the online state after the match was
   created. Fixed: the deduction moved into a `_lock_entry_stake()`
   called at the end of setup() and setup_4p() (entry_paid guards
   double-deduction; cancelling a search still costs nothing).
   Caught by the new tour test ("stake locked at match start").
2. **Opponent panel showed "Computer Lv 1" at match start**
   (cosmetic): _ready() built the HUD with the default opponent
   name before setup() set the real one ("Arjun Mehta (BOT)" /
   "Medium Bot"); the name only refreshed after the first shot.
   Fixed: setup()/setup_4p() now call _update_hud() after setting
   the fields. Verified in the re-taken win screenshots.
3. **Test fence blocked the bank legs too** — the first bank-test
   fence (y=405, target y=430) sat on the bounce→target leg, so no
   bank existed. Fixed: target moved to (300,550), fence widened
   (x=190..505) — direct paths blocked, left-wall bank open.
4. **Test detail string had 1 placeholder for 2 args** — "not all
   arguments converted" error in the tour-loss check. Fixed the
   format string.
5. **Roster UI check found no labels** — in -s mode the tree never
   iterates, so _ready never fired after add_child before quit().
   Fixed: the test builds the screen by calling _ready() directly.

### 5. Still honest (v8)
- Live two-device play and live Gmail login on real phones can only
  be confirmed by Buddhika playing. Verified instead: 404 checks
  green across 12 suites + 8 screenshots checked by eye.
- No hosted internet game server yet — AWS signup is blocked at the
  billing (card) step; Buddhika's decision on the card is pending.
  Worldwide online still needs a server; NEARBY same-Wi-Fi play
  works today, and World Tour needs no server at all.
- No real-money code anywhere; stakes are virtual coins only.
- Minor cosmetic nit (not fixed): the BOT tag on roster cards sits
  flush against the card's right edge — readable, just tight.

## v9 verification (2026-11-22) — register-screen fixes

User tested v8 on his real phone (2026-11-22 23:08): Google sign-in does
nothing, register won't let him in, the register screen's bottom half is
empty, and ads fire before he can even play. Diagnosed first, then fixed.

### 0. Diagnosis (root causes, verified before fixing)

**Complaint 1 — Google button does nothing (three stacked causes):**
- (a) `Accounts.begin_google_sign_in()` returns `false` immediately when
  `Supabase.google_client_id == ""` — and v8 shipped `backend_config.json`
  with `"google_client_id": ""`. The tap never even opened the browser; the
  only feedback was a small error label ("Google sign-in is not set up
  yet…"), which reads as "nothing happens".
- (b) The Supabase Google provider was DISABLED. Verified live 23:12:
  `GET /auth/v1/authorize?provider=google` → HTTP 400
  `{"error_code":"validation_failed","msg":"Unsupported provider:
  provider is not enabled"}`. Even without the gate, the flow would have
  failed at Supabase. (Provider enabled by the parent 23:17 — Web
  application OAuth client "BMS Carrom Supabase", redirect
  `https://hyhlhngybzwnungnshff.supabase.co/auth/v1/callback`; re-verified
  live: the same authorize call now returns HTTP 302 to
  accounts.google.com. CAVEAT: the Google consent screen is in Testing
  mode, so ONLY bmsirimanna@gmail.com (added test user) can sign in with
  Google until it is published to Production — that needs a homepage URL
  + privacy-policy URL, a later step.)
- (c) The PKCE loopback mechanism itself is fragile on Android: the game
  listens on 127.0.0.1:8765, but the tap opens the system browser, the
  game is backgrounded (Godot's main loop pauses), and the TCPServer
  cannot accept the redirect — Chrome would show connection refused.
  Verified by code inspection + engine evidence: vanilla Godot 4.3 does
  NOT surface Android deep-link URIs to GDScript (the engine's
  GodotActivity only forwards intents to fragments/plugins; third-party
  SDK docs confirm deep links need a custom GodotApp.java override).
  Fix: custom URL scheme `com.musehiro.carrom://auth-callback` + intent
  filter in AndroidManifest.xml + a GodotApp.java override (onCreate /
  onNewIntent) that writes the incoming URI to `user://auth_callback.txt`,
  which Accounts polls while a Google sign-in is pending; the loopback
  listener stays as a secondary path; the PKCE verifier is persisted in
  Save so a cold start can still complete the exchange; the
  `google_client_id` gate is removed (the flow needs no client-side
  client ID — Supabase holds the OAuth client server-side); a manual
  paste-code fallback + a visible error cover the failure case.

**Complaint 2 — OTP / register "won't let me in":**
- The OTP request path is NOT broken server-side. Verified live against
  the real project: POST /auth/v1/otp with a valid Gmail-format address
  → HTTP 200 `{}` (one probe Auth user created for the nonexistent
  `bms-carrom-otp-probe-20261122@gmail.com` — no profile, no real person
  emailed); POST /auth/v1/verify with a wrong code → HTTP 403
  `otp_expired` ("Token has expired or is invalid"); invalid email →
  HTTP 400 `validation_failed`. So the likely user experience was: he
  tried Google first (dead button, cause 1a), concluded registration is
  broken, and never completed the Gmail + code path — and if the code
  email is slow or lands in Spam, the screen had NO resend button, so a
  player whose code never arrives is stuck with no recovery.
  Fix: RESEND CODE button (60 s cooldown), "check your Spam folder"
  hint, exact errors surfaced; the verified request path is unchanged.
  Live receipt of a real code email can only be confirmed by the user.

**Complaint 3 — big empty space at the bottom of the register screen:**
- Layout math: the v7 screen's content is ~1040 px tall on a 1640 px
  screen (~600 px dead space; ~240 px on 1280 px). The VBox has no
  expanding filler, so the footer floats mid-screen. Fix: full redesign
  (below) with an expanding spacer + a benefits panel pinned to the
  bottom, so the screen is full on 720x1280 AND 720x1640.

**Complaint 4 — ads fire as soon as you do anything:**
- Code inspection: NO ad call exists on the register screen or at
  launch. The earliest ads are (a) the home banner, shown immediately
  on the home screen after login, before any match is played; (b) the
  interstitial after every 3rd completed match — but
  `interstitial_counter` persists across versions, so a player who
  already played in v7/v8 can see a full-screen interstitial after
  their very first v9 match; (c) the interstitial is preloaded at app
  start, so it fires instantly when triggered. Fix: hard gates in Ads
  (no account → no banner / interstitial / rewarded; interstitial also
  requires counter ≥ 3); preload deferred until after login; the
  interstitial counter resets to 0 on first v9 launch
  (`ads_policy_version` migration); banner stays home-only after login.

### 1. Design references (register-screen redesign)

Looked at how the top games do login (web search, 2026-11-22):
- Carrom Pool: dark reddish-brown, logo top-centre with carrom pieces,
  "Login to get bonus gems and coins — Save your stats!", big coloured
  buttons (blue Facebook, orange Guest, green Google Play), Play Offline
  top-right, fine print at the bottom.
- 8 Ball Pool: sunset city skyline with palm trees, pool table + balls
  + gift box + cash, "Play with your friends! Claim FREE gifts &
  rewards!", Facebook / Miniclip / Google Play / Guest, Practice Offline
  top-right.
- Ludo King: Google sign-in via accounts.google.com (standard OAuth
  account chooser — tap the Google button → the account picker shows
  the player's Gmail accounts → tap one → signed in).
BMS Carrom does NOT copy any of these. Its own look: deep emerald felt
(carrom-table felt) gradient, darker at the edges, soft gold glow
behind a large board-only logo (logo rule: the board stays text-free),
gold accents, cream text — the gold-on-dark family of the rest of the
game, but fresh. Google button stays in Google's own style (white,
Google "G" in its four colours, "Continue with Google").

### 2. Fixes (what changed)

**Google sign-in (`scripts/accounts.gd`, `scripts/supabase.gd`,
`android/build/AndroidManifest.xml`,
`android/build/src/com/godot/game/GodotApp.java`):**
- The `google_client_id == ""` gate is GONE — the OAuth client lives
  server-side in Supabase; the game never needed a client-side client
  ID. (The shipped `backend_config.json` still has
  `"google_client_id": ""` — harmless, unused.)
- The browser now returns via the custom-scheme deep link
  `com.musehiro.carrom://auth-callback` (primary): intent filter in
  the manifest + `GodotApp.onCreate`/`onNewIntent` writes the incoming
  URI to `user://auth_callback.txt`, which Accounts polls (every
  0.5 s) while a sign-in is pending. The 127.0.0.1 loopback listener
  stays as a secondary path. A manual paste-code fallback row
  ("Paste the code or the link here" + USE CODE) covers the case
  where the automatic return fails.
- The PKCE verifier + deadline are persisted in Save, so a cold start
  (app killed while the browser was open) can still complete the
  exchange; Accounts resumes the pending sign-in on startup.
- A stale callback file from an abandoned sign-in is dropped when a
  new sign-in starts, so the poll can only pick up the current code.
- The Google account's display name (`user_metadata.full_name`) is
  used when the player has no name of their own yet (fresh install:
  the default "Player").
- Every failure shows an error — timeout (5 min), no code, exchange
  failure, browser that cannot open — never silently nothing.
- Live check after the provider was enabled (2026-11-22 23:17):
  `GET /auth/v1/authorize?provider=google&redirect_to=com.musehiro.carrom%3A%2F%2Fauth-callback…`
  → HTTP 302 to accounts.google.com (and the loopback redirect
  variant too). Testing-mode caveat: only bmsirimanna@gmail.com can
  use Google sign-in until the consent screen is published.

**OTP / register (`scripts/auth_screen.gd`):** the verified-live
request path is unchanged; added a RESEND CODE button (60 s
cooldown, countdown on the button) and a "check your Spam folder
too" hint, and errors are surfaced exactly. Live receipt of a real
code email can only be confirmed by the user.

**Register screen redesign (`scripts/auth_screen.gd`):** deep
emerald felt gradient (GradientTexture2D) fading to near-black
green, soft gold radial glow behind a larger board-only logo, gold
title, cream text; Google button FIRST — white, drawn four-colour
"G", "Continue with Google"; divider "or continue with Gmail";
tabs + fields + action as before; an expanding spacer + a benefits
panel pinned to the bottom (1,000 starting coins saved forever /
level, XP and stats never lost / boards & strikers always yours /
"Free to play • No ads until you play") + "BMS Carrom v9.0" footer.
Empty message labels now take no space (they hid ~46 px on 1280 px
screens). The whole screen scrolls only when the code row is open
on a short screen. Home footer bumped to v9.0 (`scripts/home.gd`).

**Ads (`scripts/ads.gd`, `scripts/main.gd`, `scripts/save_data.gd`):**
- Hard gate in Ads: no account → no banner, no interstitial, no
  rewarded (rewarded emits `rewarded_failed` so callers show
  feedback). Interstitial also requires counter ≥ 3.
- Interstitial preload moved out of `Ads._ready()` into `warm_up()`,
  called from `main._show_home()` — no ad activity before login.
- `ads_policy_version` migration (v9): a save with policy < 9 resets
  `interstitial_counter` to 0 on first v9 launch, so a returning
  player gets three full v9 matches before the first interstitial.

### 3. Tests

- Import: `godot --headless --import --path .` — 0 script errors.
- Logic runner: `godot --headless --path . -s tests/test_runner.gd`
  — **163 passed, 0 failed** (was 150; +13 v9 checks: deep-link /
  loopback callback parsing, authorize URL with the custom-scheme
  redirect, loopback request parsing, ads-policy migration).
- Ads gate scene: `res://tests/ads_test.tscn` — **9 passed, 0
  failed** (rewarded/interstitial/banner blocked before
  registration; rewarded earns after; interstitial blocked at
  counter 1 and 2, allowed at 3; old save migrates counter 0 +
  policy 9).
- Auth flow scene: `res://tests/auth_flow_test.tscn` (xvfb) —
  **23 passed, 0 failed** (was 11; +12 v9 checks: Google button
  text + white style, Google tap with no backend shows an error,
  benefits panel + "No ads until you play" present, footer v9.0 at
  the bottom of the screen, paste-code row hidden → visible while
  pending → hidden again, RESEND CODE exists but hidden until a code
  is sent).
- Supabase mock: `res://tests/supabase_mock_test.tscn` —
  **38 passed, 0 failed** (was 28; +10 v9 Google checks: loopback,
  deep-link file, pasted URL, pasted bare code, paste refused when
  nothing is pending — all with `google_client_id` unset, proving
  the gate is gone). Note: the mock test now resets the profile to a
  known fresh state at the start — the sandbox save had drifted to
  900 coins / 14 matches from earlier staked-match test runs, which
  made the "starting coins 1000" assertions fail before any v9 code
  ran. That was a test-hermeticity fix, not a game fix.
- Server 38/38, LAN 16/16, stakes 32/32, aim 19/19, accounts 32/32,
  input 9/9, popup flow 18/18, popup double 5/5, win-double 46/46 —
  no regressions.
- `net_test.tscn` (live two-client match against a server) still
  cannot run in this sandbox: UDP sockets are blocked here
  (Python UDP loopback test fails with `PermissionError: [Errno 1]
  Operation not permitted`), so the clients cannot reach even a
  locally running server. Pre-existing environment limit, not a v9
  change — no networking code was touched. The server logic itself
  is covered by server_test 38/38.

### 4. Screenshots — checked by eye (xvfb, software GL)

In `verification/v9/`:
- `shot-login-720x1280.png` + `shot-login-720x1640.png` — the new
  register screen, looked at personally: emerald felt background,
  board with a soft gold glow, gold "WELCOME TO CARROM", the white
  "Continue with Google" button with a correct four-colour "G",
  divider, REGISTER / SIGN IN tabs, name + Gmail fields, gold
  "REGISTER & PLAY", benefits panel with all three rows + "Free to
  play • No ads until you play", footer "BMS Carrom v9.0 • Account
  required • Free to play" fully visible at the bottom on BOTH
  sizes — no dead space, nothing cut off. (First capture: the 1280
  px shot cut the footer off by ~50 px — the screen scrolled. Fixed
  by hiding empty message labels + a tighter glow + wider
  separation on tall screens; re-captured and verified.)

### 5. Bugs found and fixed during verification

1. **Register screen overflowed on 720x1280** — the first v9
   capture showed the benefits panel's last line half-cut and the
   footer below the fold (content ~50 px taller than the screen).
   The auth-flow test's "footer at the bottom" check passed anyway
   because it only asserted the footer reaches the bottom, not that
   it fits. Fixed: empty message labels take no space, glow padding
   100 → 80, separation cap 26 → 32 on tall screens. Re-captured
   both sizes — both fit.
2. **`minf()` with 3 arguments** — auth_screen used
   `minf(a, b, c)`; GDScript's minf takes 2. Parse error caught by
   the import check; fixed with nested minf.
3. **Mock test depended on a clean sandbox save** — the "starting
   coins 1000" assertions failed because the sandbox save had
   drifted (900 coins / 14 matches from earlier staked-match runs).
   Fixed: the mock test now resets the profile to a known fresh
   state at the start (file still backed up + restored).
4. **Auth-flow test depended on the live backend_config** — with
   the config now filled, the test's "local-only" intent was only
   preserved by the headless TLS failure. Fixed: the test forces
   `Supabase.set_config("", "", "")` before creating Main.

### 6. NOT verified (needs Buddhika / a real device)

- Live Google tap on his phone (account picker → tap account →
  registered). Only bmsirimanna@gmail.com can use Google sign-in while
  the consent screen is in Testing mode.
- Live receipt of a real OTP code email (request path verified live:
  HTTP 200; delivery to a real inbox + the code working end to end
  needs his test).
- Live two-device play / live Gmail login restore on real phones (as
  before).
