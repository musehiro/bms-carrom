# BMS Carrom

Play real carrom online or offline. Real physics, fair matches, fewer ads.

- **Solo (offline)** vs AI — Easy / Medium / Hard, error-based AI.
- **Online** — random matchmaking worldwide, similar level (±2, widening
  after 30 s), winner takes the pot. Needs the server in `server/`
  (see `docs/online-server.md`).
- **Coins economy** — win matches to earn coins; coins buy 6 boards and
  7 strikers (small capped stat differences, cosmetic-first).
- **Levels & ranks** — 500 XP per level, Rookie → Diamond.
- **Aim guide** — Full / Basic / Off, plus the Aim-Assist power-up
  (1 hour for 2,000 coins or 2 rewarded ads).
- **Ads** — AdMob TEST IDs only. Interstitial only after every 3rd
  match, never mid-game. Rewarded ads are opt-in (+150 coins, max 5/day).

## Build

Godot 4.3, Android export. The GitHub workflow
(`.github/workflows/android.yml`) builds the debug APK on push to main
and publishes it to the `latest` release. The workflow file itself must
be added via the GitHub web UI (the API 403s workflow files).

## Test

```bash
# Logic tests (physics, rules, AI, economy) — headless
~/tools/godot/Godot_v4.3-stable_linux.x86_64 --headless --path . -s tests/test_runner.gd

# Import check
~/tools/godot/Godot_v4.3-stable_linux.x86_64 --headless --import --path .
```

## Design

`docs/carrom-research-design.md` — the research + design doc this build
follows (ICF rules, Carrom Pool reference look, economy, ad policy).

## Status (v1)

- Solo game, rules, AI, shop, levels, aim guide, aim-assist, ads
  (test IDs) — built and tested locally.
- Online client + server — built; matchmaking verified on localhost
  only. Internet play needs a hosted server (see `docs/online-server.md`).
