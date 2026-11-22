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
