class_name WorldTour
extends RefCounted

## World Tour (v8): advanced computer opponents from around the world.
##
## HONEST LABELLING IS A HARD RULE: these are COMPUTER opponents. The
## mode screen and every opponent card say BOT / Computer, and the mode
## never claims to search for a real player. Names + countries + cartoon
## avatars are fine; hiding that it is a bot is not (design doc §3.2:
## "never a fake human" — a Play Store requirement too).
##
## Economy (Buddhika 2026-11-22): stakes work EXACTLY like a human
## match — the player chooses any stake up to their balance, the bot
## mirrors it (mirror_stake), the winner takes the whole pot, a draw
## refunds both stakes. Ads double the winnings the same way as the
## online win screen (watch 2 ads -> double the pot). NO daily cap on
## bot-match winnings: the difficulty itself limits farming — these
## bots play hard, and losing costs the stake.
##
## Skill maps straight onto the AI difficulty (CarromAI ERRORS):
## 3 Advanced, 4 Expert, 5 Master — all above Hard (2).

const BOTS := [
	{"id": "arjun", "name": "Arjun Mehta", "country": "India", "skill": 3, "level": 12,
		"color": Color(0.85, 0.45, 0.15),
		"blurb": "Patient positional play — rarely misses an open coin."},
	{"id": "kasun", "name": "Kasun Perera", "country": "Sri Lanka", "skill": 3, "level": 14,
		"color": Color(0.85, 0.65, 0.15),
		"blurb": "Bank-shot artist — finds angles nobody else sees."},
	{"id": "sarah", "name": "Sarah Collins", "country": "England", "skill": 4, "level": 18,
		"color": Color(0.25, 0.45, 0.85),
		"blurb": "Queen specialist — covers her almost every time."},
	{"id": "david", "name": "David Chen", "country": "USA", "skill": 4, "level": 21,
		"color": Color(0.15, 0.65, 0.35),
		"blurb": "Aggressive breaker — punishes every loose coin."},
	{"id": "emma", "name": "Emma Wilson", "country": "Canada", "skill": 5, "level": 26,
		"color": Color(0.65, 0.30, 0.75),
		"blurb": "The champion — near-perfect aim, ice-cold defence."},
]

const SKILL_NAMES := {3: "ADVANCED", 4: "EXPERT", 5: "MASTER"}

## The bot mirrors the player's stake, so the pot is always 2x the
## stake and the payout is the same Stakes math as a human match.
static func mirror_stake(your_stake: int) -> int:
	return maxi(0, your_stake)

static func bot_by_id(bot_id: String) -> Dictionary:
	for b in BOTS:
		if String(b.get("id", "")) == bot_id:
			return b
	return {}

static func skill_name(skill: int) -> String:
	return String(SKILL_NAMES.get(int(skill), "ADVANCED"))

## Pick a random World Tour bot, weighted toward the player's level
## (v10 — no bot list any more: tap WORLD TOUR -> loading -> board).
## Weight falls with the level gap, so a Rookie usually meets Arjun or
## Kasun and rarely Emma; every bot stays reachable. Pure apart from
## the RNG — unit-tested with a seeded RandomNumberGenerator.
static func random_bot_near_level(player_level: int, rng: RandomNumberGenerator = null) -> Dictionary:
	var r := rng if rng != null else RandomNumberGenerator.new()
	if rng == null:
		r.randomize()
	var total := 0.0
	var weights: Array = []
	for b in BOTS:
		var gap := absi(int(b.get("level", 1)) - player_level)
		var w := 1.0 / (1.0 + float(gap) * 0.35)
		weights.append(w)
		total += w
	var roll := r.randf() * total
	for i in range(BOTS.size()):
		roll -= float(weights[i])
		if roll <= 0.0:
			return BOTS[i]
	return BOTS[BOTS.size() - 1]
