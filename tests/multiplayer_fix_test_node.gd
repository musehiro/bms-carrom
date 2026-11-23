extends Node

## Multiplayer-fix test (F2/F3/L7/L11): drives the REAL MatchScreen
## headless and checks the setup/_ready ordering fix, the
## server-assigned breaker, the 4p remote-shot fallback baseline, and
## the invite group-state rules for expired/cancelled rows.
## Run headless: godot --headless --path . res://tests/multiplayer_fix_test.tscn
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
		print("[MultiplayerFixTest] TIMEOUT")
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
	# --- F2 layer 1 + F3: setup_4p BEFORE add_child (the fixed order).
	var m1 := MatchScreen.new()
	m1.setup_4p(_roster(), 1, 3, null)
	add_child(m1)
	await _frames(2)
	_check("f2: setup-before-add_child keeps 4-player rules state", int(m1.rules_state.get("players", 0)) == 4, "players=%s" % str(m1.rules_state.get("players", "?")))
	_check("f3: server breaker seat 3 is the turn", int(m1.rules_state.get("turn", -1)) == 3 and int(m1.rules_state.get("breaker", -1)) == 3, "turn=%s breaker=%s" % [str(m1.rules_state.get("turn", "?")), str(m1.rules_state.get("breaker", "?"))])
	_check("f2: OppRow1 exists after setup-before-add_child", _opp_row(m1, 1) != null)
	_check("f2: OppRow2 exists after setup-before-add_child", _opp_row(m1, 2) != null)
	_check("f2: 4p panel is the tall variant", m1._opp_panel.offset_bottom == 168, "offset_bottom=%s" % str(m1._opp_panel.offset_bottom))

	# --- F2 layer 2: add_child FIRST (old order), setup_4p after.
	var m2 := MatchScreen.new()
	add_child(m2)
	await _frames(2)
	_check("f2 layer2 precondition: defaults are 2-player before setup", int(m2.rules_state.get("players", 0)) == 2)
	m2.setup_4p(_roster(), 2, 0, null)
	await _frames(2)
	_check("f2 layer2: rules state re-derived to 4 players", int(m2.rules_state.get("players", 0)) == 4, "players=%s" % str(m2.rules_state.get("players", "?")))
	_check("f2 layer2: breaker re-derived to seat 0", int(m2.rules_state.get("turn", -1)) == 0 and int(m2.rules_state.get("breaker", -1)) == 0)
	_check("f2 layer2: OppRow1 created by _update_hud", _opp_row(m2, 1) != null)
	_check("f2 layer2: OppRow2 created by _update_hud", _opp_row(m2, 2) != null)

	# --- F3 2p: setup("online", ..., breaker 1) before add_child.
	var m3 := MatchScreen.new()
	m3.setup("online", 0, 0, "Opp", 5, null, 1, 100, 100)
	add_child(m3)
	await _frames(2)
	_check("f3 2p: server breaker (seat 1) is the turn, not a local roll", int(m3.rules_state.get("turn", -1)) == 1 and int(m3.rules_state.get("breaker", -1)) == 1)

	# --- L7: remote shot without "sy" uses the message seat's baseline.
	# m1: local seat 1, phase "place". Seat 2 shoots (left baseline).
	m1.rules_state["turn"] = 2
	m1._on_remote_shot({"sx": 200.0, "seat": 2, "dx": 0.0, "dy": 1.0, "power": 0.5})
	_check("l7: seat-2 remote shot lands on the left baseline", m1._striker["pos"] == CarromPhysics.baseline_pos(2), "pos=%s expected=%s" % [str(m1._striker["pos"]), str(CarromPhysics.baseline_pos(2))])
	# No seat in the message: falls back to the other 2p seat (0 here).
	m1.phase = "place"
	m1.rules_state["turn"] = 0
	m1._on_remote_shot({"sx": 200.0, "dx": 0.0, "dy": 1.0, "power": 0.5})
	_check("l7: missing seat falls back to baseline_pos(1 - local_seat)", m1._striker["pos"] == CarromPhysics.baseline_pos(0), "pos=%s" % str(m1._striker["pos"]))

	# --- L11: expired / cancelled rows fail a group (like declined).
	_check("l11: expired row fails the group", Friends.group_state([{"status": "accepted"}, {"status": "expired"}]) == "failed")
	_check("l11: cancelled row fails the group", Friends.group_state([{"status": "accepted"}, {"status": "cancelled"}]) == "failed")
	_check("l11: declined still fails the group", Friends.group_state([{"status": "declined"}]) == "failed")
	_check("l11: all accepted is still ready", Friends.group_state([{"status": "accepted"}, {"status": "accepted"}]) == "ready")
	_check("l11: pending + accepted is still waiting", Friends.group_state([{"status": "accepted"}, {"status": "pending"}]) == "waiting")

	m1.queue_free()
	m2.queue_free()
	m3.queue_free()
	_finish()

## The OppRow nodes live under _opp_panel/OppBox (CanvasLayer HUD).
func _opp_row(m: MatchScreen, k: int) -> Node:
	return m._opp_panel.get_node_or_null("OppBox/OppRow%d" % k)

func _finish() -> void:
	if _done:
		return
	_done = true
	print("=== %d passed, %d failed ===" % [_passed, _failed])
	get_tree().quit(0 if _failed == 0 else 1)
