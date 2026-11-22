extends Node

## Input-path test: drives the REAL Main scene and feeds synthetic touch
## events through Input.parse_input_event (the same path a phone uses).
## Verifies:
##   A: real touch-drag slides the striker along the baseline
##   B: direct _unhandled_input call slides (control — proves handler logic)
##   C: real pull-back aim + release fires a shot
##   D: PLAY opens a mode choice (never straight into matchmaking)
##   E: online search offers a labelled-BOT fallback after ~12 s
## Run headless: godot --headless --path . res://tests/input_test.tscn
## Exit 0 = all pass, 1 = any fail.

var _passed := 0
var _failed := 0
var _main = null
var _match = null
var _wait := 0.0
var _done := false
var _input_scale := 1.0

func _ready() -> void:
	# Headless runs with a 64x64 dummy window while the logical viewport is
	# 1280 wide: the engine scales parsed input positions by visible/window
	# (20x here). Real phones have scale 1. Divide event positions by the
	# factor so synthetic touches land on the intended logical point.
	_input_scale = get_viewport().get_visible_rect().size.x / maxf(1.0, float(get_viewport().size.x))
	print("INFO: input scale factor=", _input_scale)
	var main_scene: PackedScene = load("res://scenes/main.tscn")
	_main = main_scene.instantiate()
	add_child(_main)
	_run()

func _process(delta: float) -> void:
	if _done:
		return
	_wait += delta
	if _wait > 60.0:
		print("[InputTest] TIMEOUT")
		_done = true
		get_tree().quit(1)

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

func _touch_press(pos: Vector2) -> InputEventScreenTouch:
	var e := InputEventScreenTouch.new()
	e.position = pos
	e.pressed = true
	e.index = 0
	return e

func _touch_release(pos: Vector2) -> InputEventScreenTouch:
	var e := InputEventScreenTouch.new()
	e.position = pos
	e.pressed = false
	e.index = 0
	return e

func _touch_drag(pos: Vector2) -> InputEventScreenDrag:
	var e := InputEventScreenDrag.new()
	e.position = pos
	e.relative = Vector2.ZERO
	e.index = 0
	return e

# Event positions go through the engine's stretch transform: send the
# logical point divided by the input scale so it lands on the right spot.
func _ev(pos: Vector2) -> Vector2:
	return pos / _input_scale

func _find_button(root: Node, prefix: String) -> Button:
	for n in root.get_children():
		if n is Button and String((n as Button).text).begins_with(prefix):
			return n
		var found := _find_button(n, prefix)
		if found:
			return found
	return null

func _popup_has_buttons(root: Node, wanted: Array) -> bool:
	var found := {}
	for n in root.get_children():
		if n is Button:
			for w in wanted:
				if String((n as Button).text).begins_with(w):
					found[w] = true
		for w in wanted:
			if _popup_has_buttons(n, [w]):
				found[w] = true
	for w in wanted:
		if not found.has(w):
			return false
	return true

func _run() -> void:
	await _frames(5)
	# --- start a solo match, force the local turn ---
	_main._start_solo(1)
	await _frames(5)
	_match = _main._match
	_check("match started", _match != null)
	if _match == null:
		_finish()
		return
	_match.rules_state["turn"] = 0
	_match.phase = "place"
	_match._place_striker_for_turn()
	await _frames(2)
	var start: Vector2 = _match._striker["pos"]
	print("INFO: striker start ", start)
	# --- A: real-pipeline slide ---
	Input.parse_input_event(_touch_press(_ev(start)))
	await _frames(2)
	for x in [start.x + 25.0, start.x + 60.0, start.x + 100.0]:
		Input.parse_input_event(_touch_drag(_ev(Vector2(x, start.y))))
		await _frames(2)
	Input.parse_input_event(_touch_release(_ev(Vector2(start.x + 100.0, start.y))))
	await _frames(2)
	var after_slide: Vector2 = _match._striker["pos"]
	print("INFO: striker after real-pipeline slide ", after_slide)
	_check("A: real touch-drag slides striker", absf(after_slide.x - (start.x + 100.0)) < 5.0, str(after_slide))
	# --- B: direct-call slide (control — handler logic in isolation) ---
	_match._striker["pos"] = Vector2(360.0, 795.0)
	_match._dragging = false
	_match._unhandled_input(_touch_press(Vector2(360.0, 795.0)))
	_match._unhandled_input(_touch_drag(Vector2(420.0, 795.0)))
	_match._unhandled_input(_touch_release(Vector2(420.0, 795.0)))
	var after_direct: Vector2 = _match._striker["pos"]
	print("INFO: striker after direct-call slide ", after_direct)
	_check("B: direct _unhandled_input slides striker", absf(after_direct.x - 420.0) < 5.0, str(after_direct))
	# --- C: real-pipeline pull-back aim + release shoots ---
	_match._striker["pos"] = Vector2(360.0, 795.0)
	_match._dragging = false
	_match.phase = "place"
	_match.rules_state["turn"] = 0
	Input.parse_input_event(_touch_press(_ev(Vector2(360.0, 795.0))))
	await _frames(2)
	for y in [830.0, 870.0, 920.0]:
		Input.parse_input_event(_touch_drag(_ev(Vector2(360.0, y))))
		await _frames(2)
	Input.parse_input_event(_touch_release(_ev(Vector2(360.0, 920.0))))
	await _frames(3)
	var shot_fired: bool = _match.phase == "shooting" or (_match._striker["vel"] as Vector2).length() > 1.0
	print("INFO: phase after aim+release ", _match.phase, " vel ", (_match._striker["vel"] as Vector2))
	_check("C: real pull-back aim + release fires a shot", shot_fired, "phase=" + str(_match.phase))
	# --- D: PLAY opens a mode choice, never straight into matchmaking ---
	_main._show_home()
	await _frames(5)
	var home = _main._home
	var play_btn := _find_button(home, "▶")
	_check("D: PLAY button exists", play_btn != null)
	if play_btn != null:
		play_btn.pressed.emit()
		# Synchronous check: matchmaking must NOT have started at all.
		var no_mm: bool = not _main._searching_active and _main._searching == null
		_check("D: PLAY does not start matchmaking", no_mm)
		await _frames(3)
		# v3: PLAY opens the full-screen mode-choice screen (a child of
		# Main, not a popup on home) — it must offer SOLO and ONLINE.
		# NOTE: home is freed by _open_mode_choice, so do NOT touch it
		# after the emit (accessing it segfaults the test runner).
		var mode_ok := _main._mode != null and _find_button(_main._mode, "SOLO —") != null and _find_button(_main._mode, "ONLINE —") != null
		print("INFO: after PLAY pressed: searching_active=", _main._searching_active, " mode screen=", mode_ok)
		_check("D: PLAY opens mode-choice screen", mode_ok)
	# --- E: online search offers a labelled-BOT fallback after ~12 s ---
	# Isolate the timer from the Net failure path: disconnect the queue-failed
	# handler so the search popup stays up (on a real phone the connection
	# attempt hangs; in headless it fails fast and would tear the popup down).
	Net.queue_failed.disconnect(_main._on_queue_failed)
	_main._start_matchmaking(0)
	await _frames(5)
	_check("E: search popup stays up", _main._searching != null)
	if _main._searching != null:
		_main._search_elapsed = 11.9
		await _frames(30)
		var bot_visible: bool = _main._search_bot_button != null and is_instance_valid(_main._search_bot_button) and _main._search_bot_button.visible
		print("INFO: bot fallback visible after 12 s: ", bot_visible)
		_check("E: search offers labelled-BOT fallback after 12 s", bot_visible)
	_finish()

func _finish() -> void:
	_done = true
	print("=== input test: %d passed, %d failed ===" % [_passed, _failed])
	get_tree().quit(0 if _failed == 0 else 1)
