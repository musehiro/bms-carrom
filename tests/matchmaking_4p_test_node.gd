extends Node

## v11 4-player MatchScreen setup-contract test (F2: setup BEFORE
## add_child), plus the lobby -> match handoff shape.
## MUST run as a scene, not with -s: MatchScreen names the Save
## autoload, which a -s SceneTree script cannot compile (same split
## as tests/multiplayer_fix_test_node.gd).
## Run headless: godot --headless --path . res://tests/matchmaking_4p_test.tscn
## Exit 0 = all pass, 1 = any fail.

var _passed := 0
var _failed := 0
var _done := false
var _wait := 0.0

func _ready() -> void:
	Save.account_id = "test-account-id"
	Save.player_name = "Test Player"
	Save.coins = 10000
	_run()

func _process(delta: float) -> void:
	if _done:
		return
	_wait += delta
	if _wait > 30.0:
		print("[Matchmaking4pTest] TIMEOUT")
		_finish()

func _frames(n: int) -> void:
	for i in range(n):
		await get_tree().process_frame

func _check(test_name: String, cond: bool, detail: String = "") -> void:
	if cond:
		_passed += 1
		print("PASS: ", test_name)
	else:
		_failed += 1
		print("FAIL: ", test_name, (" — " + detail if detail != "" else ""))

func _roster() -> Array:
	return [
		{"name": "Alice", "level": 5, "stake": 100, "seat": 0},
		{"name": "Bob", "level": 6, "stake": 100, "seat": 1},
		{"name": "Carol", "level": 5, "stake": 100, "seat": 2},
		{"name": "Dave", "level": 7, "stake": 100, "seat": 3},
	]

func _run() -> void:
	# --- F2 contract: setup_4p BEFORE add_child (the order Main's
	# _start_match_from_lobby uses for every online 4p match).
	var m := MatchScreen.new()
	m.setup_4p(_roster(), 1, 3, null)
	add_child(m)
	await _frames(2)
	_check("4p contract: rules state has 4 players", int(m.rules_state.get("players", 0)) == 4, "players=%s" % str(m.rules_state.get("players", "?")))
	_check("4p contract: turn is the breaker seat (3)", int(m.rules_state.get("turn", -1)) == 3 and int(m.rules_state.get("breaker", -1)) == 3, "turn=%s breaker=%s" % [str(m.rules_state.get("turn", "?")), str(m.rules_state.get("breaker", "?"))])
	_check("4p contract: OppRow1 exists", m._opp_panel.get_node_or_null("OppBox/OppRow1") != null)
	_check("4p contract: OppRow2 exists", m._opp_panel.get_node_or_null("OppBox/OppRow2") != null)
	_check("4p contract: local seat is 1", m.local_seat == 1)
	_check("4p contract: player_count is 4", m.player_count == 4)
	_check("4p contract: 4p panel is the tall variant", m._opp_panel.offset_bottom == 168, "offset_bottom=%s" % str(m._opp_panel.offset_bottom))
	# --- §4 HUD: every player's name + level on their side (4p).
	# Local seat is 1 (Bob); teams are seats 0,2 vs 1,3, so my team is
	# 1+3: the other three are Alice seat 0 (OPP), Carol seat 2 (OPP),
	# Dave seat 3 (PARTNER) — seat order in the rows.
	var top_name: Label = m._opp_panel.get_node("OppBox/OppTop/OppName")
	var top_lv: Label = m._opp_panel.get_node("OppBox/OppTop/OppLevel")
	_check("4p HUD: top row names Alice (OPP)", String(top_name.text).contains("Alice") and String(top_name.text).contains("OPP"), top_name.text)
	_check("4p HUD: top row shows Alice Lv 5", String(top_lv.text) == "Lv 5", top_lv.text)
	var row1_name: Label = m._opp_panel.get_node("OppBox/OppRow1/OppName1")
	var row1_lv: Label = m._opp_panel.get_node("OppBox/OppRow1/OppLevel1")
	_check("4p HUD: row 1 names Carol (OPP)", String(row1_name.text).contains("Carol") and String(row1_name.text).contains("OPP"), row1_name.text)
	_check("4p HUD: row 1 shows Carol Lv 5", String(row1_lv.text) == "Lv 5", row1_lv.text)
	var row2_name: Label = m._opp_panel.get_node("OppBox/OppRow2/OppName2")
	var row2_lv: Label = m._opp_panel.get_node("OppBox/OppRow2/OppLevel2")
	_check("4p HUD: row 2 names Dave (PARTNER)", String(row2_name.text).contains("Dave") and String(row2_name.text).contains("PARTNER"), row2_name.text)
	_check("4p HUD: row 2 shows Dave Lv 7", String(row2_lv.text) == "Lv 7", row2_lv.text)
	# --- §4 live match points: the PointsLine is visible in an online
	# match and starts at 0 (10 pts per own coin, +25 covered queen).
	_check("4p points: live line visible in online mode", m._points_label != null and m._points_label.visible)
	_check("4p points: live line starts at Points: 0", m._points_label != null and String(m._points_label.text) == "Points: 0", "" if m._points_label == null else m._points_label.text)
	m.queue_free()

	# --- §4 HUD (2p): opponent name + level on their side.
	var m2 := MatchScreen.new()
	m2.setup("online", 0, 0, "Zara", 9, null, 0, 100, 100)
	add_child(m2)
	await _frames(2)
	var opp_name: Label = m2._opp_panel.get_node("OppBox/OppTop/OppName")
	var opp_lv: Label = m2._opp_panel.get_node("OppBox/OppTop/OppLevel")
	_check("2p HUD: opponent name shown", String(opp_name.text) == "Zara", opp_name.text)
	_check("2p HUD: opponent level shown", String(opp_lv.text) == "Lv 9", opp_lv.text)
	_check("2p points: live line visible in online mode", m2._points_label != null and m2._points_label.visible)
	_check("2p points: live line starts at Points: 0", m2._points_label != null and String(m2._points_label.text) == "Points: 0", "" if m2._points_label == null else m2._points_label.text)
	m2.queue_free()

	# --- The lobby that feeds this match: same roster, same seats.
	var lobby: OnlineLobby = OnlineLobby.from_matched(
		{"mode": "4p", "players": _roster(), "your_seat": 1, "breaker_seat": 3},
		"Bob", 6, 100)
	_check("4p contract: lobby roster matches the match roster", lobby.players.size() == 4 and lobby.your_seat == 1 and lobby.breaker_seat == 3)
	for seat in [0, 1, 2, 3]:
		lobby.mark_ready(seat)
	_check("4p contract: all-ready lobby can start the match above", lobby.all_ready() and lobby.begin_start())

	m.queue_free()
	_finish()

func _finish() -> void:
	if _done:
		return
	_done = true
	print("=== %d passed, %d failed ===" % [_passed, _failed])
	get_tree().quit(0 if _failed == 0 else 1)
