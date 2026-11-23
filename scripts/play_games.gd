extends Node

## Play Games Services — autoload wrapper around the
## godot-sdk-integrations/godot-play-game-services v3.4.0 plugin
## (Godot 4.3+, play-services-games-v2 21.0.0).
##
## What it does: optional, non-blocking Play Games sign-in, one
## leaderboard ("Top Carrom Scores") and the 10-achievement starter set
## from the spec (see the ID table below). The game plays FULLY without
## it: offline, unsigned-in, sign-in failed, or plugin missing — every
## public method no-ops safely in those cases and match flow never waits
## on Play Games. Per the spec, nothing is queued: a match finished
## while signed out is simply not submitted that match.
##
## WHERE THE REAL IDS GO (the only place this is documented in code):
## - Play Games application ID (numeric Project ID): the Android export
##   preset option `godot_play_game_services/game_id` in
##   export_presets.cfg. It currently holds a clearly-marked placeholder
##   (see the comment there) — paste the real ID from Play Console >
##   Play Games Services > Configuration once that step is done.
## - Leaderboard + achievement IDs (`CgkI...` strings from Console):
##   paste them into `leaderboard_id` / `achievement_ids` below.
## The application ID, leaderboard IDs and achievement IDs are public
## configuration, not credentials. Never put keystore passwords, OAuth
## client secrets, or key files here.
##
## Match score (leaderboard + Century Maker): the game's own board score
## tops out at 12 (1 per opponent coin left + 3 for a covered queen), so
## it cannot carry the spec's "100+ points in a single match"
## achievement. Match points are therefore defined here as
## 10 per coin pocketed + 30 for covering the queen + 25 for winning
## (max 145). See compute_match_score().

const PLUGIN_VERSION := "3.4.0"

## Leaderboard ID from Console (A7: "Top Carrom Scores", numeric,
## larger-is-better). Empty = not configured yet: submits are skipped.
var leaderboard_id: String = ""

## Achievement IDs from Console (A8). Keys are the spec's proposal
## numbers 1-10. Empty string = not configured yet: that achievement's
## calls are skipped. Paste each real `CgkI...` ID as Console creates it.
var achievement_ids: Dictionary = {
	"first_flick": "", # 1 First Flick — finish your first match (5 pts)
	"first_win": "", # 2 First Win — win your first match (5 pts)
	"pocket_the_queen": "", # 3 Pocket the Queen — pocket the queen (10 pts)
	"clean_sweep": "", # 4 Clean Sweep — pocket all your coins in one match (15 pts)
	"hat_trick": "", # 5 Hat-Trick — win 3 matches in a row (15 pts)
	"century_maker": "", # 6 Century Maker — score 100+ match points in one match (20 pts)
	"sharpshooter": "", # 7 Sharpshooter — pocket 50 coins in total, incremental (25 pts)
	"regular_player": "", # 8 Regular Player — win 10 matches in total, incremental (25 pts)
	"carrom_champion": "", # 9 Carrom Champion — win 50 matches in total, incremental (50 pts)
	"board_master": "", # 10 Board Master — win 100 matches in total, incremental (100 pts)
}

## Incremental step targets (spec A8a) — the service auto-unlocks at
## the target; the game only increments by the match delta.
const INCREMENTAL_STEPS := {
	"sharpshooter": 50,
	"regular_player": 10,
	"carrom_champion": 50,
	"board_master": 100,
}

signal sign_in_changed(signed_in: bool)

var _signed_in := false
var _auth_check_done := false
var _plugin_live := false
var _mock_mode := false
var _pending_ui := "" # "leaderboard" | "achievements" — opened after sign-in
var _sign_in_client = null
var _achievements_client = null
var _leaderboards_client = null
## Last match's executed actions (debug aid only).
var debug_last_actions: Array = []

func _ready() -> void:
	# The native plugin only exists inside a real Android export.
	# Everywhere else (editor, desktop, headless tests) this stays
	# unavailable and every call below no-ops.
	if not OS.has_feature("android"):
		print("[PlayGames] Non-Android build: Play Games Services unavailable, game plays without it.")
		return
	if not Engine.has_singleton("GodotPlayGameServices"):
		printerr("[PlayGames] Plugin singleton missing — Play Games Services unavailable.")
		return
	var err: int = GodotPlayGameServices.initialize()
	if err != GodotPlayGameServices.PlayGamesPluginError.OK:
		printerr("[PlayGames] Plugin failed to initialise — game plays without it.")
		return
	_plugin_live = true
	_sign_in_client = PlayGamesSignInClient.new()
	_achievements_client = PlayGamesAchievementsClient.new()
	_leaderboards_client = PlayGamesLeaderboardsClient.new()
	add_child(_sign_in_client)
	add_child(_achievements_client)
	add_child(_leaderboards_client)
	_sign_in_client.user_authenticated.connect(_on_authenticated)
	# One silent sign-in check at startup (PGS v2: reports whether the
	# player is already signed in; no popup loop — never retried here).
	_auth_check_done = true
	_sign_in_client.is_authenticated()

func is_available() -> bool:
	return _plugin_live or _mock_mode

func is_signed_in() -> bool:
	return _signed_in

func is_configured() -> bool:
	return leaderboard_id != ""

func _on_authenticated(is_auth: bool) -> void:
	_signed_in = is_auth
	sign_in_changed.emit(is_auth)
	if is_auth and _pending_ui != "":
		var ui := _pending_ui
		_pending_ui = ""
		if ui == "leaderboard":
			show_leaderboard()
		elif ui == "achievements":
			show_achievements()

## Manual sign-in (home-screen buttons call this when needed). Shows
## the native Play Games sign-in popup once; never called in a loop.
func sign_in() -> void:
	if not is_available() or _signed_in:
		return
	if _sign_in_client != null:
		_sign_in_client.sign_in()

## Open the native leaderboard UI. If signed out, requests sign-in
## once and opens it when sign-in succeeds.
func show_leaderboard() -> void:
	if not is_available():
		return
	if not _signed_in:
		_pending_ui = "leaderboard"
		sign_in()
		return
	if _leaderboards_client == null:
		return
	if leaderboard_id != "":
		_leaderboards_client.show_leaderboard(leaderboard_id)
	else:
		_leaderboards_client.show_all_leaderboards()

## Open the native achievements UI (same sign-in behaviour as above).
func show_achievements() -> void:
	if not is_available():
		return
	if not _signed_in:
		_pending_ui = "achievements"
		sign_in()
		return
	if _achievements_client != null:
		_achievements_client.show_achievements()

## --- Match scoring ---------------------------------------------------

## Match points: 10 per coin pocketed + 30 for a covered queen + 25
## for winning. Pure — unit-tested. Max 145 (9 coins + queen + win);
## 100+ is the Century Maker bar.
static func compute_match_score(coins_pocketed: int, queen_covered: bool, won: bool) -> int:
	return maxi(coins_pocketed, 0) * 10 + (30 if queen_covered else 0) + (25 if won else 0)

## Pure decision logic: which Play Games actions a finished match
## earns. `result` keys: won, matches_played, matches_won, win_streak,
## coins_pocketed, queen_covered, clean_sweep, total_coins_pocketed,
## score. Returns [{"type": "unlock"/"increment"/"submit_score",
## "key": ..., "amount": n, "score": n}]. One-time unlocks use >= so a
## match finished while signed out can still earn them on the next
## qualifying match (unlocks are idempotent server-side); incremental
## achievements only ever move by the match delta.
static func match_actions(result: Dictionary) -> Array:
	var actions: Array = []
	var won := bool(result.get("won", false))
	var matches_played := int(result.get("matches_played", 0))
	var matches_won := int(result.get("matches_won", 0))
	var win_streak := int(result.get("win_streak", 0))
	var coins := int(result.get("coins_pocketed", 0))
	var queen := bool(result.get("queen_covered", false))
	var sweep := bool(result.get("clean_sweep", false))
	var score := int(result.get("score", 0))
	if matches_played >= 1:
		actions.append({"type": "unlock", "key": "first_flick"})
	if won and matches_won >= 1:
		actions.append({"type": "unlock", "key": "first_win"})
	if queen:
		actions.append({"type": "unlock", "key": "pocket_the_queen"})
	if sweep:
		actions.append({"type": "unlock", "key": "clean_sweep"})
	if won and win_streak >= 3:
		actions.append({"type": "unlock", "key": "hat_trick"})
	if score >= 100:
		actions.append({"type": "unlock", "key": "century_maker"})
	if coins > 0:
		actions.append({"type": "increment", "key": "sharpshooter", "amount": coins})
	if won:
		actions.append({"type": "increment", "key": "regular_player", "amount": 1})
		actions.append({"type": "increment", "key": "carrom_champion", "amount": 1})
		actions.append({"type": "increment", "key": "board_master", "amount": 1})
	if score > 0:
		actions.append({"type": "submit_score", "score": score})
	return actions

## Report a finished match (called once from MatchScreen._show_result,
## AFTER Save has recorded the match). Fire-and-forget: signed out,
## offline, unconfigured or plugin missing all no-op silently.
func report_match_result(result: Dictionary) -> void:
	debug_last_actions = match_actions(result)
	if not _signed_in:
		return
	for action in debug_last_actions:
		_execute_action(action)

## The queen was just covered by the local player (called from
## MatchScreen._apply_events). Unlocks immediately so the native
## toast appears during the match; the match-end report repeats it
## harmlessly (unlocks are idempotent).
func report_queen_covered() -> void:
	if not _signed_in:
		return
	_execute_action({"type": "unlock", "key": "pocket_the_queen"})

func _execute_action(action: Dictionary) -> void:
	match String(action.get("type", "")):
		"unlock":
			var key := String(action.get("key", ""))
			var id := String(achievement_ids.get(key, ""))
			if id != "" and _achievements_client != null:
				_achievements_client.unlock_achievement(id)
		"increment":
			var ikey := String(action.get("key", ""))
			var iid := String(achievement_ids.get(ikey, ""))
			var amount := int(action.get("amount", 0))
			if iid != "" and amount > 0 and _achievements_client != null:
				_achievements_client.increment_achievement(iid, amount)
		"submit_score":
			var score := int(action.get("score", 0))
			if leaderboard_id != "" and score > 0 and _leaderboards_client != null:
				_leaderboards_client.submit_score(leaderboard_id, score)

## --- Test hooks ------------------------------------------------------
## Headless tests inject mock clients (same method names, recording
## calls) and drive signed-in state directly — no Android needed.

func configure_ids(p_leaderboard_id: String, p_achievement_ids: Dictionary) -> void:
	leaderboard_id = p_leaderboard_id
	for key in p_achievement_ids:
		if achievement_ids.has(key):
			achievement_ids[key] = String(p_achievement_ids[key])

func set_test_clients(p_sign_in_client, p_achievements_client, p_leaderboards_client) -> void:
	_mock_mode = true
	_sign_in_client = p_sign_in_client
	_achievements_client = p_achievements_client
	_leaderboards_client = p_leaderboards_client

func set_test_signed_in(value: bool) -> void:
	_signed_in = value
