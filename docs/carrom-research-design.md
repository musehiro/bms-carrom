# BMS Carrom — Research & Design Document

**Phase 1 only: research + design. No code in this phase.**
**Game:** BMS Carrom (working title — Buddhika can rename)
**Owner:** Buddhika ("BMS buddhika" is a brand only; the game is by an individual, never a company)
**Date:** 2026-11-21
**Status:** Research complete. This doc is the single source of truth for the build agent — build the game from this doc alone.
**Budget rule (standing):** FREE ONLY — no paid subscriptions, no paid assets, no paid services ever.

---

# PART A — RESEARCH

## 1. Carrom rules (standard / ICF Laws)

**Sources used (checked 2026-11-21):**
- International Carrom Federation (ICF) "Laws of Carrom", via Tyche Labs summary — https://www.tychelabs.net/guides/how-to-play-carrom (cites the ICF Laws PDF hosted by the German Carrom Federation and carrom.co.uk)
- Carrom Live, "Laws of carrom" — https://www.carromlive.com/resources/laws-of-carrom
- PlayCarrom, "Official Carrom Board Game Rules" — https://playcarrom.com/pages/how-to-play

### 1.1 The board (ICF standard dimensions — use these proportions in-game)

| Item | Standard size |
|---|---|
| Playing surface | 73.5–74 cm square, smooth plywood ≥ 8 mm thick |
| Frame | Hardwood (rosewood or similar), 1.9–2.54 cm high, 6.35–7.6 cm wide |
| Corner pockets | 4, one per corner, 4.45 cm diameter, rounded inward, net behind |
| Base lines | Two parallel lines on each of the 4 sides, 47 cm long; outer line 10.15 cm from the frame; each pair closed at both ends by a red **base circle** |
| Diagonal arrows | One from each base-circle area pointing toward the nearest pocket, ≤ 26.7 cm long |
| Centre circle | Red, 3.18 cm diameter — where the queen starts |
| Outer circle | 17 cm diameter — all 19 coins are set up inside it |
| Board markings | Centre circle, outer circle, 4 base-line pairs, 4 base circles per side (8 total), 4 diagonal arrows |

### 1.2 Pieces

- **9 white coins + 9 black coins** (carrommen): smooth wooden discs, 3.02–3.18 cm diameter, 0.7–0.9 cm thick, 5.25–5.5 g each.
- **1 red queen:** same size, slightly heavier.
- **1 striker:** larger/heavier disc, up to 4.13 cm diameter, up to 15 g.
- **Powder:** fine powder (boric acid) dusted on the surface so pieces glide — in-game this is just the low-friction physics feel; do NOT make the board sticky.

### 1.3 Setup (exact)

1. Queen on the centre circle.
2. Six coins ringed tightly around her, alternating white/black, all touching.
3. A white coin directly behind each of the three inner white coins, so the whites form a **"Y" shape** pointing toward the breaker.
4. Fill the rest of the outer ring alternating white/black. All 19 pieces touching, inside the outer circle.
5. Toss: winner chooses side or break. **Whoever breaks plays white** for that board; break alternates board to board.

### 1.4 Striking / turns

- Striker is placed on the player's own baseline; it must touch **both** base lines. If placed on a base circle it must cover the circle completely and must not touch the arrow.
- Flick with a finger — struck, not pushed. (Mobile equivalent: drag back and release; see §6.)
- **The break:** the striker must touch at least one coin. Three attempts allowed; if all three miss, the opponent breaks and plays black.
- **Pocket one of your own coins → you shoot again.** Pocket nothing → turn passes.
- Pocketing an **opponent's coin is NOT a foul** — it stays pocketed (helps them) and your turn ends.
- In doubles (4 players, partners opposite, turns pass right) — **not needed for v1** (1v1 only).

### 1.5 The queen — the most important rule; get this exactly right

- The queen can be pocketed **only after you have pocketed at least one of your own coins**. Pocket her earlier → she returns to the centre circle and your turn ends.
- **Covering:** after pocketing the queen you must pocket one of your own coins **on the same stroke or the very next stroke**. If you do, the queen is yours. If you don't, she goes back to the centre circle.
- **The queen must be pocketed and covered BEFORE your last coin.** Pocketing your last coin while the queen is still on the board **loses you the board** and your opponent scores 3.
- Queen is worth **3 points** to the winner of the board, but only if they covered it. The loser never gets queen points, even if they covered it.
- Once a player reaches 22 points, the queen scores nothing more for them.

### 1.6 Fouls and penalties (ICF "dues")

A **due** = one of your pocketed coins comes back out; the opponent places it anywhere inside the outer circle.

| What happened | Penalty (ICF) |
|---|---|
| Striker pocketed on its own | Lose your turn, owe one coin |
| Striker pocketed WITH one or more of your coins | Those coins + one more come back, but you **keep** your turn |
| Striker pocketed with the queen | Queen back to centre, owe one coin, but you **keep** your turn |
| Any other foul during your turn (touching pieces, pushing, crossing arrow line) | Owe one coin, lose your turn; coins pocketed on that stroke also come back |
| A due owed before you have pocketed anything | It stays owed; comes out as soon as you pocket a coin |
| Pocketing your opponent's **last** coin | You **lose the board** |

Simplified version for casual mobile play (what most apps do, and what we do in v1 — see §6.1): striker pocketed = lose turn + one of your pocketed coins returns to the centre. If you have pocketed nothing yet, the due is recorded and taken from your first pocketed coin.

### 1.7 Scoring / winning

- First player to pocket all nine of their coins **wins the board**.
- Board score: **1 point per opponent coin still on the board + 3 for a covered queen**. A board is worth at most 12 points.
- A **game** = first to **25 points** or **8 boards**, whichever comes first. A **match** = best of three games.
- **For BMS Carrom v1:** a match = ONE board, winner takes all (fast mobile sessions, 3–4 minutes). Do NOT implement the 25-point / multi-board scoring in v1 — keep it as a later "Tournament" mode idea. Single-board winner = first to clear all 9 coins (with queen covered before the last coin).

### 1.8 Common variants (for later modes, NOT v1)

- **Freestyle:** any coin of either colour can be pocketed; points per coin (e.g. white 20, black 10, queen 50 in some apps); first to a target score wins. No colour ownership, no queen cover.
- **Disc Pool:** like pool with discs — pocket all your discs, no queen at all.
- **Doubles:** 2v2, partners opposite, turns pass right.
- **House rules seen in the wild:** queen any time (before first coin); simpler fouls (only striker-pocket = foul); family points scoring (black 10 / white 20).

---

## 2. Popular carrom games — what they have

### 2.1 Carrom Pool: Disc Game — Miniclip (the market leader; THE reference)

- **Scale:** 100M+ downloads, **4.5★, ~7.7M reviews** on Google Play. Released 26 Mar 2019. The game to beat.
- **Modes:** 3 modes — **Carrom** (classic rules, queen + cover), **Freestyle** (any coin, points scoring), **Disc Pool** (no queen, pocket all your discs). 1v1 online is the core; friend challenges; private rooms (2-player and 4-player); practice/offline play.
- **Matchmaking:** random opponents worldwide; **arenas** (tables) tiered by entry fee — you pay coins to enter, winner takes the pot. Arenas are themed as world cities (Mumbai, Cairo, etc.); you climb to higher arenas as you win. Matching is by arena/level — higher tables = tougher opponents and bigger pots.
- **Coins & economy:** TWO currencies.
  - **Coins** (everyday): entry fee for every online match; winner takes the pot. Earned by winning matches and from victory chests. Also buyable in the shop.
  - **Gems** (premium): speed up chest opening, buy shop items/chests.
  - **Chests:** Bronze / Silver / Gold from wins; Pro / Master / Supreme from the shop. Chests contain striker/puck **cards**. Duplicate cards upgrade the striker you own.
  - Real-money shop prices (App Store, USD): Bunch of Coins $1.99, Bunch of Gems $1.99, Golden Shot $1.99, Golden Lucky Box $2.99, Premium Pass $4.99, Premium+ Pass $9.99.
  - **Daily Golden Shot** minigame: land a puck in the bullseye for gems/chests.
  - Economy sting: losing a high-entry match hurts; one review notes a Mumbai-arena entry fee of 55,000 coins for a 100,000-coin pot.
- **Levels/ranks:** arena progression + player rank (e.g. "Super Star", total winnings shown on profile, e.g. 61.2M). Collection Power level (up to 25) from striker collection.
- **Customisation:** **Strikers** (each with 3 stats — see below) and **pucks/coins** in many designs; visual **trails** behind the striker. Rarities: Epic / Legendary / Mythic (e.g. "Controller" Legendary, "Astro" Mythic, "Seam" Legendary). Upgrading a striker to max can cost **millions of coins** (one screen recording: upgrade cost 3,308,700 coins; level 0→6 upgrades each cost 2.4M+). This is the long grind that keeps players.
- **Striker stats (Miniclip's own system — copy this):**
  | Stat | What it controls |
  |---|---|
  | **Force** | How hard the striker hits |
  | **Aim** | How long your aiming guideline is |
  | **Time** | How many seconds you have to take your shot |
  Upgrades raise all three. Higher Aim = longer guideline — this is the legal version of an "aim hack".
- **Aim guide:** drag back from the striker; a guideline shows the projected path of the striker AND where the hit coin will go after impact. Length of the line scales with the striker's Aim stat.
- **Ads:** heavy — see §4. Rewarded ads exist (extra coins/chests); interstitials after matches.
- **LOOK (describe to copy the feel):** top-down view of a polished wooden board on a dark, moody background; the board is a rich warm wood with clean white/black/red markings; coins are glossy, chunky discs with a slight 3D bevel and soft shadows; the striker is large and glossy. UI is dark navy/black with gold and white accents, rounded buttons, big coin/gem counters at the top. Arenas are presented as glossy "city" cards. Animations are smooth and springy; pocketing a coin has a satisfying sink + particle puff. **This is the best-looking carrom game overall** — polished, premium, instantly readable. Copy: the warm wood + dark background contrast, the glossy chunky coins, the clean gold-on-dark UI, the springy pocket animation.

### 2.2 Carrom King™ — Gametion (makers of Ludo King)

- **Scale:** **50M+ installs, 4.0★, ~231K ratings** (Google Play). v6.1.0.143, Sep 2026, ~81 MB.
- **Modes:** **Freestyle** & **Black & White** (classic). Online multiplayer worldwide, **pass-and-play** local mode, **vs Computer (AI)** offline, **Trick Shots** — a time-bound mode with many levels to perfect tricky shots.
- **Matchmaking:** online lobbies — "progress through multiple lobbies all the way to the top". Private rooms via room code; Facebook friends challenges; rematch button; game-resume if disconnected; view opponent statistics.
- **Coins & economy:** coins + **chests** (unlock/buy a chest box, 80+ collectibles). "Cover Queen to unlock the brand new chest and get rewards." In-app purchases yes.
- **Customisation:** strikers with different hitting & aiming powers (named: Hurricane, Blue Star, Mandala, Chakri, Lotus, Cyclone, Thunder…). Pucks in colourful designs (Panda, Shield, Smile, Sunshine, Hearts, Alloys, Lantern…). Attractive **frames** (board borders) as collectibles.
- **Power-ups (its signature — copy the idea, not the exact names):**
  - **God Finger** — extra hitting power to the striker
  - **Powder** — improves puck speed by smoothing the board
  - **Assistance** — helps you play better shots (aim help)
- **Social:** emojis + messages to opponents, voice mode (one reviewer praises the voice option for talking to people worldwide).
- **LOOK:** brighter and more colourful than Carrom Pool — playful, saturated colours, cartoon-ish pucks with faces/patterns, chunky friendly UI. Feels like Ludo King's sibling: family-friendly, loud, fun. Less premium than Carrom Pool, more cheerful.

### 2.3 Carrom Clash (several apps share the name; the notable one is the web game by Tanvir Mahin + the App Entrepreneurship mobile game)

- **Web version (carromclash.tanvirmahin.com):** 2–4 players, **Ranked Quick Match** (Bronze → Diamond ranks, equal strikers in ranked), friends & 4-letter room codes, 4 modes — **Freestyle, Classic (1v1 or 2v2), 3-min Blitz, power-up Chaos**. Bots: Easy / Normal / Hard. **Daily Challenge** trick-shot puzzle (same for everyone, 3 shots, 1 try, daily leaderboard). 7 strikers with Power + Aim stats, upgradeable to level 5. **XP levels: every level-up pays 100 gold; board themes unlock as you climb (up to "Midnight")**. Shot replays in slow motion, shareable as a link. Scoring in Freestyle: white 20 / black 10 / queen 50.
- **Power-ups (Chaos mode):** Fireball (150% power heavy striker), Bomb (explodes on first impact), Magnet (pockets suck in nearby coins), Trident (striker splits into three), Titan (huge heavy striker). Orbs appear on the board; hit one to collect; hold up to 3.
- **Mobile version (App Entrepreneurship):** Classic / Disc Pool / Freestyle; AI Easy/Medium/Hard; pass-and-play; arenas themed by world cities (Mumbai, Dubai, Tokyo, Paris, New York); level-up system, daily rewards, streak bonuses, stats/win-rate tracking. (Note: one "Carrom Clash" Android app was removed from Google Play in April 2026 after only 23 days / 220 installs — the name is crowded and the small clones die fast. The web version above is the interesting one.)
- **LOOK (web version):** clean, modern, flat-design UI; soft smooth graphics praised in reviews ("soft and smooth graphics… super comfortable to play"). Physics praised as relatively better than most rivals.

### 2.4 Carrom League: Friends Online — BlueFutureGames / Blue Engine Games

- **Scale:** **10M+ installs, 4.5★, ~30.6K ratings** (Google Play), ~62 MB. Also a separate iOS "Carrom League: Online Game" (TIANQIN, 4.72★, 304 MB, 3D).
- **Modes:** Classic carrom, Freestyle, Disc Pool; 2–4 player (2v2 team battles); online ranked; **League Mode** (create/join a league, team up, final awards); **VIP Room** (invite Facebook/Messenger friends); custom rooms & private matches; offline vs AI; quick matches; **tournament phases** — 6 phases, win one phase to get your entry fee back, win the final phase to share 25% of the prize pool.
- **Matchmaking:** real-time worldwide; ranked competitive mode; global leaderboards; "watch live" streams of pro players.
- **Coins & economy:** win matches → coins → unlock boards and pieces. Customisable entry coins / rounds / piece count in private rooms.
- **Customisation:** boards and pieces with distinct designs/skins; avatars (e.g. "Rookie Challenger").
- **Power-ups / items:** Striker Boost, **Aim Assist Guide** (precision line tool), Spin Modifier, Defense Shield, Lucky Powder (reward multiplier).
- **Complaints (from its own Play reviews):** "Too many ads… we need to pay gems to play with our friends which is a huge downfall" (charging premium currency to play with friends is hated — do NOT copy this). Bots suspected in regular play ("some are bots and others are real people… weird").
- **LOOK:** vibrant graphics, bright colours, friendly UI; the 3D iOS version leans into glossy 3D physics.

### 2.5 Other carrom games worth knowing

- **Carrom Disc Pool** — this is literally Carrom Pool's Disc Pool mode listed as its own Play listing (Miniclip); same game, same 4.4★ / ~8M reviews footprint.
- **Carrom King Classic (Quantam Core)** — small Indian-made clone; Player vs Computer, Player vs Player custom matches, International Lobby, trick shots, daily rewards (+500 points), leaderboard. Shows the genre is crowded with small clones.
- **Carrom board games round-ups** (ubuntupit etc.) list 10+ similar apps — the genre is commoditised. Differentiation must come from fairness, fewer ads, and a better look, not from new rules.

---

## 3. What players want — praised vs complained (Google Play reviews, GameBrain, forums)

### 3.1 Top praised features (COPY these)

1. **Smooth controls + realistic physics** — the #1 praise everywhere. "Smooth controls and realistic physics" is Miniclip's own tagline and the thing reviewers quote back. Coins must glide, cushions must rebound believably, the striker must feel weighty.
2. **Simple to learn, hard to master** — drag-back-to-aim is instantly understood; bank shots and queen strategy give depth.
3. **Quick 1v1 matches** — 3–4 minute matches, pick-up-and-play.
4. **Real opponents worldwide** — playing real people (not bots) is valued; ranks, leaderboards and win streaks matter.
5. **Good graphics / premium look** — Carrom Pool's glossy board and chunky coins get 185+ positive graphics mentions on GameBrain.
6. **Collecting strikers/pucks** — the collection + upgrade grind (cards, chests, rarities) is a strong retention hook.
7. **Playing with friends** — private rooms, rematch button, emojis/chat.
8. **Daily rewards / Golden Shot** — a small daily reason to open the app.

### 3.2 Top complaints (AVOID these — this is our competitive edge)

1. **TOO MANY ADS — by far the #1 complaint.** GameBrain: monetisation has **3.5K negative mentions, 99% negative**. Reviews: "ad after every match", "ad is about a minute long", "ads pop up in the middle of gameplay", "every 2 minutes another ad", "you spend more time watching ads than playing", "forced to watch the full 30–60 seconds", "ads redirect to sites even when I tap the X", "inappropriate ads for younger audiences". **Our rule: interstitials ONLY between matches, max 1 per match, never mid-game, never longer than skippable-after-5s, and never more often than every 3rd match if the player just watched one.** This alone is a selling point: put "fewer ads than other carrom games" in the store copy.
2. **Bots disguised as real players** — "bots which auto-win", "opponents with no rank who pot every coin in one row", "50% chance of running into hackers in higher-bet matches". Players HATE feeling tricked. **Our rule: online opponents are real players only; if we ever use a bot to fill a match, label it clearly "BOT" and make it beatable. Never fake a human.**
3. **Aim hacks / auto-play cheats** — "many players are using auto play / aim hacks and pot every coin perfectly". **Our rule: server-side shot validation where possible; in v1 (likely peer/local), keep aim assist as an official, visible, limited feature (see §6.4) so nobody needs a hack — and cap the guideline length so no one can have a perfect line.**
4. **Unfair matchmaking vs much higher-level opponents** — "unfair matchmaking against higher-level opponents". **Our rule: match within ±2 levels, widen only after 30 s of searching.**
5. **Pay-to-win** — striker stats that cost millions of coins; trick-shot mode where you can pay for tries on a leaderboard mode. **Our rule: striker stat differences are SMALL (max +15% force/aim/time between worst and best) and cosmetic-first; ranked matches use EQUAL strikers (like Carrom Clash ranked). Never sell leaderboard advantage.**
6. **Lag, glitches, disconnects with no resume** — "minor glitch with graphics causes missed hits", connection problems. **Our rule: game-resume on reconnect (copy Carrom King), offline solo always works.**
7. **Physics that feels wrong** — "physics is dumb… a whirlpool pulls the pucks & striker when near the pot" (pocket magnetism too strong). **Our rule: pockets attract only within a small radius; no magnet pull from across the board.**
8. **Paying premium currency to play with friends** — Carrom League complaint. **Our rule: private/friend matches are always FREE.**
9. **No enforcement against idle/dishonest players** — "no enforcement of rules against dishonourable/idle players". **Our rule: 20-second shot timer; 2 consecutive time-outs = forfeit. Report button.**
10. **Cluttered UI / upsell pop-ups** — "pop-ups asking you to purchase unnecessary packs", "scroll down every time to your favourite destination". **Our rule: one home screen, PLAY is the biggest button, no pop-up on launch.**

---

## 4. Ads in carrom games — how they actually work

**Rewarded ads (player chooses to watch):**
- Watch a 15–30 s video → get coins, gems, a chest, a free Golden Shot try, or an extra life/try in a mode.
- In Carrom Pool: rewarded ads give coins/chests and speed up chest timers.
- Players accept rewarded ads — they are opt-in and give something clear. This is the GOOD ad format.

**Interstitial ads (forced):**
- Shown **after every match** in Carrom Pool (the single biggest complaint). Often 30–60 s, sometimes unskippable, sometimes chained ("after saying ad break, no one plays it, it's a full ad" — i.e. an ad after the ad).
- Also appear on returning to the home screen / between menu screens in the worst offenders ("every 2 minutes another ad").
- **Our policy (design decision, §7):** interstitial ONLY on the match-result screen, only after every **3rd** match (not every match), skippable after 5 s, never chained, never mid-match, never on launch. Rewarded ads are unlimited opt-in (coins, aim-assist, chest speed-up).

**AdMob (for the build):** use AdMob test IDs during development; real AdMob unit IDs only when Buddhika/Nana supply them (Nana holds the AdMob account — same arrangement as Shadow Assassin). Interstitial + Rewarded units only; NO banner ads inside the game screen (banners during play are hated and distract from aiming).

---

## 5. Look — which game looks best and why

**Winner: Carrom Pool (Miniclip).** It is the most premium-looking: warm polished wood, dark moody surround, glossy chunky coins with soft shadows, gold-on-dark UI, springy animations. It looks like a real expensive board photographed beautifully, not a cartoon.
**Runner-up: Carrom Clash (web).** Cleanest, most comfortable — soft, smooth, uncluttered.
**Carrom King** is the most cheerful/colourful but looks the least premium (cartoon pucks with faces).

**What to copy for BMS Carrom:** Carrom Pool's premium feel (warm wood + dark background + gold UI) with Carrom Clash's uncluttered layout. Avoid Carrom King's cartoon look — Buddhika's audience likes realistic, premium visuals (same taste as his Transform Decor / Floral pages: realistic, not cartoony).

---

# PART B — DESIGN: BMS CARROM

## 6. Game design

### 6.1 Rules to implement (v1)

- **Standard ICF rules, single board per match** (see §1). 1v1 only in v1 (no doubles, no 4-player).
- Setup exactly as §1.3 (queen centre, alternating ring, white "Y" toward the breaker). Breaker = random in Solo, winner of a coin toss animation in Online (simpler: random). Breaker plays **white**.
- Colours: **first coin you pocket decides your colour** in casual display, BUT the standard rule is breaker = white. Implement standard: breaker is white, opponent black. (Carrom Pool uses first-pocketed colour; we use standard — simpler to explain and correct.)
- Queen: can be pocketed only after you have pocketed ≥1 of your own coins; must be covered on the same or next stroke or she returns to centre; **must be covered before your last coin — pocketing your last coin with the queen still on the board LOSES the board**.
- Fouls (simplified ICF, §1.6): striker pocketed = lose turn + one pocketed coin returns to the centre (due; if none pocketed yet, the due is owed from your next pocketed coin). Pocketing opponent's coin = not a foul, stays pocketed, turn ends. Pocketing opponent's last coin = you lose the board.
- Turn timer: **20 seconds per shot** (generous; Carrom Pool's Time stat idea). 2 consecutive time-outs = forfeit (online) / AI takes the turn (solo, never — AI just plays).
- Winner: first to clear all 9 of their coins (queen covered first). Match = one board, ~3–4 minutes.
- **Modes in v1:** Classic Carrom only. Freestyle and Disc Pool are Phase-2 modes — design the code so a mode flag can switch the ruleset later, but ship Classic only.

### 6.2 Game modes

| Mode | How it works |
|---|---|
| **SOLO (offline vs AI)** | No internet needed. 3 difficulties: **Easy** (aim error ~2°, power error ~16%, misses ~1 in 5, never chases queen — copied from Carrom Clash's bot design, which is honest and works), **Medium** (small error, sometimes chases queen), **Hard** (near-zero error, chases queen, plays cut + bank shots). AI difficulty is implemented as *error on top of a perfect shot*, not as different strategies — this is the standard, fair way to do it. |
| **ONLINE (random matchmaking, worldwide)** | One tap → matchmaking screen → matched with a real player of similar level (see §6.5). Location doesn't matter. Entry fee in coins (see §6.3); winner takes the pot. Rematch button after a match. Report + block for idle/cheating opponents. **If no opponent is found in 30 s, widen the level range; if still none after 60 s, offer a clearly-labelled BOT match ("Practice vs BOT") — never a fake human.** |
| **Practice (no coins)** | Free-play vs Easy AI with unlimited undo? No — keep simple: Practice = Solo Easy with no coin reward and no XP. Helps new players learn without risk. (Phase 1.5 — can be folded into Solo.) |
| **Later (NOT v1):** Freestyle, Disc Pool, private rooms with friends, 2v2, tournaments, leagues. Do not build these in v1. |

### 6.3 Economy — coins

**One currency only in v1: Coins.** (No gems in v1 — Carrom Pool's two-currency system is a monetisation maze; one currency is friendlier and simpler. Gems can come later if Buddhika wants a premium shop.)

| Action | Coins |
|---|---|
| New player starting balance | **1,000 coins** (enough for 10 low-table matches — never start a player broke) |
| Solo win (Easy / Medium / Hard) | +50 / +100 / +200 |
| Solo loss | +10 (consolation, so losing never feels like zero) |
| Online win — low table (entry 100) | pot **200** (both entries) → net +100 |
| Online win — mid table (entry 500) | pot **1,000** → net +500 |
| Online win — high table (entry 2,000) | pot **4,000** → net +2,000 |
| Online loss | lose entry fee only (no extra penalty) |
| Daily login bonus | +200 (day 1), growing +50/day up to +500 at day 7 streak, then resets |
| Rewarded ad (opt-in) | +150 coins (max 5/day — prevents ad farming) |
| Queen covered in a match | +50 bonus ("Queen bonus") |

**Anti-broke rule (copy this from good games, avoid Carrom Pool's sting):** if a player's balance falls below the lowest entry fee (100), they get a **free top-up of 500 coins once per day** ("Comeback coins") so they can always play. A player who can never afford a match quits — never let that happen.

### 6.4 Boards & strikers (customisation + shop)

**Boards (visual skins — cosmetic only, no gameplay effect):**

| Board | Unlock | Price |
|---|---|---|
| Classic Wood (default) | owned from start | — |
| Royal Mahogany (dark red-brown wood, gold lines) | Level 3 | 1,500 |
| Midnight Blue (deep navy board, silver lines) | Level 5 | 3,000 |
| Emerald Club (dark green felt-style, gold lines) | Level 8 | 6,000 |
| Golden Palace (black + gold luxury) | Level 12 | 15,000 |
| BMS Signature (black + gold, big gold BMS logo in centre) | Level 15 | 25,000 |

**Strikers (small stat differences + look):** stats Force / Aim / Time (copied from Carrom Pool — players already understand these three words). **Stat differences are SMALL and capped:** the best striker is at most +15% better than the default on any stat, and **ranked/online matches cap the Aim guideline** so a paid striker never gives a perfect line. Cosmetics first, stats second.

| Striker | Force | Aim (guideline length) | Time | Price |
|---|---|---|---|---|
| Classic White (default) | 100 | 100 (medium line) | 20 s | — |
| Ivory Pearl | 102 | 105 | 20 s | 800 |
| Crimson King | 108 | 100 | 20 s | 2,000 |
| Golden Striker | 105 | 110 | 22 s | 5,000 |
| Shadow Black | 110 | 105 | 20 s | 8,000 |
| BMS Gold (gold striker, BMS engraved) | 112 | 112 | 24 s | 20,000 |
| Diamond Elite | 115 | 115 | 25 s | 50,000 |

**Coins (pucks) designs:** plain white/black/red default; unlockable colour themes (e.g. neon, gold coins) for 1,000–5,000 — cosmetic only.

**How items are earned:** buy with coins in the Shop; NO real-money purchases in v1 (Buddhika: FREE ONLY — the shop is coins-only; real-money IAP is a later decision for him, not the build agent's).

### 6.5 Levels & matchmaking

- **XP:** +100 XP per match played, +50 bonus for a win, +25 for covering the queen. Level = every 500 XP (Level 1 → 2 needs 500 XP, then 500 each — flat, simple, no escalating curve in v1).
- **Level-up reward:** +500 coins and a level-up popup. Every 5th level also unlocks a board/striker in the shop (see §6.4).
- **Matchmaking:** match within **±2 levels**. If no match in 30 s, widen to ±4; after 60 s, offer a labelled BOT match. Show the opponent's level + win rate on the VS screen (copy Carrom King — players like seeing it).
- **Ranks (display only, derived from level):** L1–4 Rookie, L5–9 Bronze, L10–14 Silver, L15–19 Gold, L20–29 Platinum, L30+ Diamond. Show rank badge on profile and VS screen.

### 6.6 Aim guide

- **How it works:** touch and drag the striker to slide it along your baseline. Then drag **backwards** from the striker (pull-back): a **guideline** appears showing the striker's path, and a short second line showing where the first coin hit will go (deflection preview). Pull further = more power (power meter fills beside the striker). Release to shoot.
- **Adjustable:** Settings → Aim Guide: **Full** (striker path + coin deflection + pocket highlight when lined up), **Basic** (striker path only), **Off** (no lines — for experts; +50 bonus coins per win with guide Off, to reward skill). Also a guideline **length** slider? No — length is the striker's Aim stat (§6.4); keep settings to the 3 modes above. Simple.
- **Aim-assist power-up ("Easy Mode") — the requested feature:**
  - What it does for ~1 hour: guideline becomes **longer and exact** (shows the full path including 1 cushion bounce + the coin's path into the pocket), plus a subtle **pocket glow** when a shot is lined up, plus +5 s shot time. It does NOT auto-aim or play the shot — the player still aims and sets power. (This keeps it fair and cheat-proof: it's an official, visible feature, not a hidden hack.)
  - How to get it: **(a)** spend **2,000 coins** for 1 hour, or **(b)** watch **2 rewarded ads** for 1 hour. Countdown timer shown in the corner while active. One active period at a time; buying/watching again while active extends it (max 3 hours banked).
  - **Online fairness rule:** aim-assist is **allowed** in online matches (it's a paid/opt-in feature both players can use) BUT the guideline shown to the opponent is never revealed, and the exact-line is capped so it never shows more than 1 bounce. This mirrors Carrom Pool's "Aim stat = longer guideline" design — the community already accepts it.
  - In Solo it works the same way (great for learning).

### 6.7 Physics (the thing players judge first)

- Top-down 2D physics (Godot physics engine, like Shadow Assassin's stack — same engine, same workflow for the build agent).
- Striker heavier than coins (striker mass ~1.5× a coin — "barges rather than deflects").
- Cushion restitution ~0.85 (cushions return 85% of speed); coin-coin restitution ~0.92; light board friction so a full-power break rattles for several seconds before settling.
- **Pocket capture radius SMALL:** a coin is pocketed only when its centre is within ~1 coin-radius of the pocket centre. NO magnet pull from across the board (this exact flaw is called out in Carrom Pool reviews).
- Shot must settle fully before the next turn; show a subtle "settling…" state, not a frozen board.
- Sound: wooden *click* on striker-coin impact (pitch varies with force), soft *thock* on cushion, satisfying *sink* + chime on pocket, foul buzz on striker pocketed. Mute toggle on home screen.

### 6.8 Ads (policy — the competitive advantage)

- **Interstitial:** ONLY on the match-result screen, only after every **3rd** match, skippable after 5 s, never chained, never mid-match, never on launch, never in Solo Practice. State this in the store listing ("Fewer ads than other carrom games — no ads during play, ever").
- **Rewarded (opt-in only):** +150 coins (max 5/day); 2 ads = 1 hour aim-assist; speed up nothing else in v1 (no chest timers in v1).
- **No banner ads** anywhere.
- AdMob: test IDs in development; real IDs only when Buddhika/Nana supply them. Nana holds the AdMob account.

---

## 7. The look — art direction (concrete, buildable)

**Reference: Carrom Pool's premium feel + Carrom Clash's uncluttered layout. Realistic, not cartoony.**

- **Board:** warm polished wood. Default "Classic Wood": honey-teak playing surface with visible subtle wood grain, darker rosewood frame, crisp white base lines, red base circles and centre circle, thin gold trim on the frame edge. Pockets: dark recessed circles with a soft inner shadow (they must read as HOLES, not flat circles).
- **Coins:** glossy chunky discs with a bevelled edge and soft drop shadow; white coins warm ivory (not pure white), black coins deep charcoal with a slight sheen, queen rich glossy red. The striker is larger, ivory with a gold ring.
- **Background (outside the board):** very dark warm charcoal (#1A1512-ish) with a soft radial glow behind the board; no busy pattern. The board is the hero.
- **UI colours:** dark navy-charcoal panels (#14181F), **gold (#D4AF37 / #E8C766)** for primary buttons, coins and highlights, white text, muted grey secondary text. Gold = BMS brand colour throughout.
- **Fonts:** a bold rounded sans for headings/buttons (like Montserrat Bold / Poppins Bold — free Google Fonts), regular weight for body. Numbers (coins, level) in the bold face, tabular.
- **Buttons:** big rounded rectangles, gold fill + dark text for primary (PLAY), dark fill + gold outline for secondary. Minimum touch target 48 dp.
- **Branding:** **big gold "BMS" splash at launch** (gold BMS letters on black, 1.2 s, then home). **No Godot logo anywhere** (same rule as Shadow Assassin). Small gold "BMS" watermark engraved on the BMS Signature board and the BMS Gold striker only — nowhere else; keep the board clean.
- **Animations:** coins slide with a tiny scale "settle" bounce on stop; pocketing = coin shrinks into the pocket with a gold particle puff + chime; turn change = a soft gold arrow/indicator slides to the active player's side; win = gold confetti burst + "YOU WIN" panel. Keep animations under 300 ms — never make the player wait.
- **Layout rule:** board is the largest element, centred, square; controls (power meter, aim toggle) sit at the bottom in the thumb zone; opponent info top, your info bottom. Never cover the board with pop-ups mid-match.

## 8. Homepage layout (exact)

Top-to-bottom, portrait phone:

1. **Top bar:** left — circular avatar + player name + level badge (e.g. "Lv 7 · Silver"); right — **coins balance** (gold coin icon + number, tappable → Shop) and **sound toggle** (speaker icon).
2. **Hero:** the board (small decorative preview) OR the BMS logo mark — keep it simple: a gold "BMS CARROM" title, with a small carrom board illustration behind it.
3. **Big PLAY button** — full-width, gold, the largest element on the screen. Tapping it goes straight to **Online Quick Match** (the default — most players want one tap to a match).
4. **Two mode buttons below PLAY, side by side, equal size:**
   - **SOLO** (vs AI — offline) → difficulty picker (Easy / Medium / Hard)
   - **ONLINE** (vs real players worldwide) → table picker (Low 100 / Mid 500 / High 2,000 entry)
5. **Row of 3 small buttons:** **SHOP** (boards, strikers, coins) · **HOW TO PLAY** (rules + a 30-second interactive tutorial: place striker, aim, shoot, pocket queen) · **AIM-ASSIST** (shows active timer or the 2,000-coins / 2-ads offer).
6. **Bottom strip:** daily reward claim (if unclaimed, gold pulsing dot) · level progress bar (XP to next level) · version number (small, grey).
7. **No pop-up on launch.** No "rate us" prompt before the player has played 5 matches.

**In-match HUD:** top — opponent avatar/name/level + coins pocketed count (9 dots that fill as they pocket); bottom — your avatar/name/level + your pocketed dots; right edge — power meter (vertical) while aiming; top-right — pause (forfeit in online = loss) + mute. Turn indicator: gold glow around the active player's panel.

---

## 9. Store-listing copy draft (English)

**Title:** BMS Carrom — Carrom Board Game

**Short description (80 chars):**
Play real carrom online or offline. Real physics, fair matches, fewer ads.

**About (full description):**
> Play the classic carrom board game — online against real players around the world, or offline against the computer. No internet? No problem: Solo mode works fully offline.
>
> Flick the striker, pocket all your coins, cover the red queen, and win the board. Real carrom rules, real physics, real opponents.
>
> **Why BMS Carrom?**
> 🎯 **Real carrom rules** — queen, cover rule, fouls, just like the wooden board at home.
> 🌍 **Online multiplayer** — one tap finds a real opponent at your level, anywhere in the world.
> 🤖 **Solo vs AI** — Easy, Medium and Hard computer opponents. Practice offline, free.
> 🎯 **Aim guide** — see your shot before you take it. Adjustable: Full, Basic or Off.
> ✨ **Aim-Assist Easy Mode** — a longer, exact guide line for an hour. Buy it with coins or unlock it by watching 2 short ads.
> 🪙 **Win coins, unlock boards & strikers** — Royal Mahogany, Midnight Blue, Golden Palace and the BMS Signature board. New striker? Better force, aim and time.
> 📺 **Fewer ads than other carrom games** — no ads during play, ever. Ever. Only one short ad after every third match.
> 🏆 **Levels & ranks** — win matches, level up from Rookie to Diamond, and climb the leaderboard.
>
> Free to play. No account needed to start — pick a nickname and play.
>
> Made with ❤ by BMS.

**Tags / keywords:** carrom, carrom board, carrom pool, carrom king, board game, multiplayer, offline games, pool, disc pool, 2 player games.

**Content rating note:** Everyone / PEGI 3 equivalent; no chat with strangers in v1 (emojis only) — keeps it family-safe.

---

## 10. Build notes for the build agent (Phase 2)

- **Engine:** Godot (same as Shadow Assassin — same workflow, same GitHub repo pattern, same free-only rule). Portrait, 9:16, target 720×1280 base resolution, scales up.
- **Physics:** Godot 2D physics (RigidBody2D for striker/coins, or a custom deterministic circle-collision solver — prefer custom solver for exact, cheat-proof, replayable physics; it is a small, well-understood problem: circles + walls + pockets).
- **Architecture:** one scene per screen (Splash, Home, SoloSetup, OnlineMatchmaking, Match, Result, Shop, HowToPlay, Settings). Match scene owns: board rendering, physics, rules engine (queen/foul state machine), turn timer, AI (error-based, §6.2), aim guide renderer, HUD.
- **Rules engine MUST be a pure state machine** (setup → aiming → shooting → settling → resolve pockets → next turn / board end), unit-testable without the UI. Queen state: `on_board | pocketed_uncovered (must cover next shot) | covered | returned`. Due state: `none | owed (count)`.
- **Online (v1 scope decision — FLAG FOR BUDDHIKA):** real worldwide online multiplayer needs a server (matchmaking, relay, anti-cheat). Options: (a) Godot + a small authoritative server (e.g. Nakama — free/open-source, self-hostable); (b) peer-to-peer with a lobby service. **Recommendation: build Solo + full local game first, ship that; add Online in Phase 2 with Nakama.** If Buddhika wants Online in v1, the build agent must say so and cost it (server hosting is NOT free — flag it, do not silently pick a paid host). **Do not fake online with bots labelled as humans — ever.**
- **AI:** error-based (§6.2). AI picks the best shot by simulation (try candidate target coin + pocket pairs, pick the highest-probability one), then adds Gaussian aim/power error per difficulty.
- **Persistence:** local save (coins, XP, level, owned items, settings, daily streak) in Godot user:// ; cloud save later.
- **Ads:** AdMob plugin, test IDs in dev. Interstitial + Rewarded only.
- **No Godot splash/logo. Big gold BMS splash instead (§7).**
- **Do NOT touch:** the Nana shared file (Muse-Hiro-messages.txt), Bus Sort Escape, the Shadow Assassin repo, or any Play Console work. This game lives in its own repo/folder under `game-carrom/` when the build starts.

---

## 11. Sources

1. ICF Laws of Carrom, via Tyche Labs — https://www.tychelabs.net/guides/how-to-play-carrom
2. Carrom Live, Laws of carrom — https://www.carromlive.com/resources/laws-of-carrom
3. PlayCarrom, Official rules — https://playcarrom.com/pages/how-to-play
4. Carrom Pool guide (Setlifestyle) — https://setlifestyle.in/game/carrom-pool-disc-game
5. Carrom Pool beginner guide — https://carrompoolin.com/blog/how-to-play-carrom-pool
6. Carrom Pool economy/striker prices (PlatinAPK, from App Store listings) — https://platinapk.com/carrom-pool-mod-apk/
7. Carrom Pool Google Play reviews (4.5★, 7.68M reviews) — https://play.google.com/store/apps/details?id=com.miniclip.carrom
8. Carrom Pool review analysis (GameBrain) — https://gamebrain.co/game/carrom-pool-disc-game
9. Carrom King Google Play — https://play.google.com/store/apps/details?id=com.git.carromking
10. Carrom King review — https://www.gameshori.online/games/d/com-git-carromking.html
11. Carrom Clash (web) — https://carromclash.tanvirmahin.com/
12. Carrom Clash (web game) — https://www.arthis.space/games/carrom-clash
13. Carrom League Google Play — https://play.google.com/store/apps/details?id=com.carrom.board.friends.freeonline.live
14. Carrom League review — https://www.gameshori.online/games/d/com-carrom-board-friends-freeonline-live.html
15. Best carrom games round-up — https://www.ubuntupit.com/best-carrom-board-games-you-can-enjoy-with-your-friends/

*All sources accessed 2026-11-21. Prices/ratings are as listed on that date and will drift — the build agent should re-check the Play listings before finalising economy numbers.*
