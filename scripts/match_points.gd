class_name MatchPoints
extends RefCounted

## Match points — ලකුණු (v11 plan §4, Buddhika 2026-11-23 08:33):
## points are earned PER COIN pocketed — the more coins you pocket,
## the more points you get. Each player's points reflect THEIR OWN
## pocketed coins (not a flat amount for everyone, and not the team's
## total in doubles — MatchScreen tracks the local player's own coins
## via the shot events, see _my_coins_pocketed).
##
##   White/black coin pocketed: 10 pts each
##   Red queen, when COVERED:   +25 bonus pts (only when covered —
##     pocketing the red without covering it returns her to the board
##     and earns NO bonus, per the ICF cover rule the game enforces)
##   Win bonus:                  +50 pts
##
## So a 9-coin win with a covered queen earns 9*10 + 25 + 50 = 165.
## A loss still keeps the per-coin points (you earned them by
## pocketing); only the win bonus is win-only. A draw keeps the
## per-coin + queen points, no win bonus.
##
## Online matches only (solo/tour pay no points, like coins).
## Points feed the XP/level system: MatchScreen adds the points
## earned to the XP of an online match (see _show_result).
## Lifetime total in Save.match_points, shown live during the match
## (running score beside the board score) and on the win screen next
## to the coins won.
##
## This REPLACES the v11 flat formula (win +3 / draw +1 / loss +0)
## from the matchmaking worker — that was a placeholder; the plan's
## per-coin formula is the real design. Tiers are retuned for the
## new scale (one good win is ~100-165 pts, so the old 10/25/50/100
## thresholds would all be passed in a single match).
## Pure logic, no Save access — unit-tested in tests/p2p_test.gd
## and tests/matchmaking_test.gd.

const COIN_POINTS := 10
const QUEEN_BONUS := 25
const WIN_BONUS := 50

## Tier names for the points total (display only — no rewards gated
## on tiers in v11; tiers give the number something to climb toward).
## Deliberately different words from the level ranks (Rookie…Diamond)
## so the two ladders are never confused.
const TIERS := [
	{"min": 0, "name": "Contender"},
	{"min": 100, "name": "Challenger"},
	{"min": 250, "name": "Champion"},
	{"min": 500, "name": "Master"},
	{"min": 1000, "name": "Grand Master"},
]

## Points for one match from what the player actually did:
## `coins_pocketed` = the player's OWN white/black coins pocketed
## (after foul returns/dues — the net count), `queen_covered` =
## true only when THEY covered the queen, `won` = match won.
static func points_for_coins(coins_pocketed: int, queen_covered: bool, won: bool) -> int:
	var pts := maxi(0, coins_pocketed) * COIN_POINTS
	if queen_covered:
		pts += QUEEN_BONUS
	if won:
		pts += WIN_BONUS
	return pts

## Legacy flat outcome (win/draw/loss only) — kept for callers that
## have no per-coin counts (the lobby's "win this match for…" line).
## A win is worth the WIN_BONUS on top of whatever coins are pocketed.
static func points_for(outcome: String) -> int:
	match outcome:
		"win":
			return WIN_BONUS
		_:
			return 0

## Outcome word from a finished match's booleans (mirrors the
## MatchScreen._show_result computation: won / is_draw).
static func outcome_for(won: bool, is_draw: bool) -> String:
	if is_draw:
		return "draw"
	if won:
		return "win"
	return "loss"

## New lifetime total after one match: total + points earned.
## Pure — the caller (MatchScreen) owns writing it to Save.
static func apply(total: int, earned: int) -> int:
	return maxi(0, total) + maxi(0, earned)

## Display tier for a lifetime total.
static func tier_name(total: int) -> String:
	var name := String(TIERS[0]["name"])
	for t in TIERS:
		if total >= int(t["min"]):
			name = String(t["name"])
	return name

## One-line result-screen text, e.g. "Match points: +115  •  Total 340 (Champion)".
static func result_line(earned: int, total: int) -> String:
	return "Match points: +%d  •  Total %d (%s)" % [earned, total, tier_name(total)]

## Live HUD line, e.g. "Points: 70  •  Queen +25 if covered".
## `queen_pending` = the player pocketed the queen and must still
## cover her — the +25 is shown as "to come", never counted early.
static func live_line(coins_pocketed: int, queen_covered: bool, queen_pending: bool) -> String:
	var pts := maxi(0, coins_pocketed) * COIN_POINTS
	if queen_covered:
		pts += QUEEN_BONUS
	var line := "Points: %d" % pts
	if queen_pending and not queen_covered:
		line += "  •  Cover the queen for +25"
	return line
