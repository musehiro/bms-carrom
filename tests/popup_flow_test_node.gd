extends Node

## Popup-flow test: drives the REAL Main scene and taps through the whole
## PLAY flow with REAL touch events (Input.parse_input_event, the same path
## a phone uses). v3 flow: PLAY opens the FULL-SCREEN mode-choice screen
## (the v2 popup's SOLO/ONLINE buttons were dead on Buddhika's phone);
## difficulty/table popups still open on Main, proven to work on his phone.
## Verifies:
##   F1: real tap on PLAY opens the mode-choice screen (SOLO + ONLINE)
##   F1b: real tap on BACK returns to the home screen
##   F2: real tap on SOLO opens the difficulty popup (EASY + MEDIUM)
##   F3: real tap on EASY starts a solo match
##   F4: real tap on ONLINE opens the stake picker; quick 100 + FIND
##      OPPONENT starts the search popup (with the 12 s BOT fallback
##      visible after fast-forward)
## Diagnostics: prints button rects, mouse_filters, the control under the
## touch point (gui_get_hovered_control), and the popup subtree.
## Run headless: godot --headless --path . res://tests/popup_flow_test.tscn
## Exit 0 = all pass, 1 = any fail.

var _passed := 0
var _failed := 0
var _main = null
var _done := false
var _wait := 0.0
var _input_scale := 1.0

func _ready() -> void:
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
	if _wait > 90.0:
		print("[PopupFlowTest] TIMEOUT")
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

func _ev(pos: Vector2) -> Vector2:
	return pos / _input_scale

func _tap(pos: Vector2) -> void:
	var p := InputEventScreenTouch.new()
	p.position = _ev(pos)
	p.pressed = true
	p.index = 0
	Input.parse_input_event(p)
	await _frames(2)
	var r := InputEventScreenTouch.new()
	r.position = _ev(pos)
	r.pressed = false
	r.index = 0
	Input.parse_input_event(r)
	await _frames(3)

func _find_button(root: Node, prefix: String) -> Button:
	for n in root.get_children():
		if n is Button and String((n as Button).text).begins_with(prefix):
			return n
		var found := _find_button(n, prefix)
		if found:
			return found
	return null

func _find_all_buttons(root: Node, prefix: String, out: Array) -> void:
	for n in root.get_children():
		if n is Button and String((n as Button).text).begins_with(prefix):
			out.append(n)
		_find_all_buttons(n, prefix, out)

func _hover_at(pos: Vector2) -> void:
	var m := InputEventMouseMotion.new()
	m.position = _ev(pos)
	Input.parse_input_event(m)
	await _frames(2)
	var h := get_viewport().gui_get_hovered_control()
	if h:
		print("INFO: hover at ", pos, " -> ", h, " class=", h.get_class(), " rect=", (h as Control).get_global_rect(), " mouse_filter=", (h as Control).mouse_filter)
	else:
		print("INFO: hover at ", pos, " -> null")

func _dump(node: Node, indent: String) -> void:
	if node is Control:
		var c := node as Control
		print(indent, c.name, " [", c.get_class(), "] rect=", c.get_global_rect(), " mf=", c.mouse_filter, " vis=", c.visible)
	else:
		print(indent, node.name, " [", node.get_class(), "]")
	for ch in node.get_children():
		_dump(ch, indent + "  ")

func _center(b: Button) -> Vector2:
	return (b as Control).get_global_rect().get_center()

func _run() -> void:
	await _frames(5)
	var home = _main._home
	_check("home shown", home != null)
	if home == null:
		_finish()
		return
	# --- F1: real tap on PLAY opens the mode-choice screen ---
	var play_btn := _find_button(home, "▶")
	_check("F1: PLAY button exists", play_btn != null)
	if play_btn == null:
		_finish()
		return
	print("INFO: PLAY rect=", play_btn.get_global_rect())
	await _tap(_center(play_btn))
	var solo_btn := _find_button(_main, "SOLO —")
	var online_btn := _find_button(_main, "ONLINE —")
	print("INFO: after PLAY tap: solo=", solo_btn, " online=", online_btn, " mode_screen=", _main._mode, " searching_active=", _main._searching_active)
	_check("F1: PLAY opens mode screen with SOLO", solo_btn != null)
	_check("F1: PLAY opens mode screen with ONLINE", online_btn != null)
	if solo_btn == null:
		print("INFO: main subtree after PLAY tap:")
		_dump(_main, "")
		_finish()
		return
	print("INFO: SOLO rect=", solo_btn.get_global_rect(), " mf=", solo_btn.mouse_filter)
	print("INFO: ONLINE rect=", online_btn.get_global_rect(), " mf=", online_btn.mouse_filter)
	print("INFO: mode screen subtree:")
	_dump(solo_btn.get_parent().get_parent(), "")
	# What control does the viewport think is under the SOLO button?
	await _hover_at(_center(solo_btn))
	# --- F1b: real tap on BACK returns to the home screen ---
	var back_btn := _find_button(_main, "←")
	_check("F1b: mode screen has BACK", back_btn != null)
	if back_btn != null:
		await _tap(_center(back_btn))
		_check("F1b: BACK returns to home", _main._home != null and _main._mode == null)
		home = _main._home
		await _frames(3)
		play_btn = _find_button(home, "▶")
		await _tap(_center(play_btn))
		solo_btn = _find_button(_main, "SOLO —")
		online_btn = _find_button(_main, "ONLINE —")
		_check("F1b: PLAY again reopens mode screen", solo_btn != null and online_btn != null)
		if solo_btn == null:
			_finish()
			return
	# --- F2: real tap on SOLO opens the difficulty popup ---
	await _tap(_center(solo_btn))
	var easy_btn := _find_button(_main, "EASY")
	var med_btn := _find_button(_main, "MEDIUM")
	print("INFO: after SOLO tap: easy=", easy_btn, " medium=", med_btn, " mode screen still there=", _main._mode != null)
	_check("F2: SOLO opens difficulty popup (EASY)", easy_btn != null)
	_check("F2: SOLO opens difficulty popup (MEDIUM)", med_btn != null)
	if easy_btn == null:
		print("INFO: main subtree after SOLO tap:")
		_dump(_main, "")
		_finish()
		return
	# --- F3: real tap on EASY starts a solo match ---
	print("INFO: EASY rect=", easy_btn.get_global_rect())
	await _hover_at(_center(easy_btn))
	await _tap(_center(easy_btn))
	print("INFO: after EASY tap: match=", _main._match)
	_check("F3: EASY starts a solo match", _main._match != null)
	# --- F4: ONLINE path — stake picker, then search popup ---
	_main._show_home()
	await _frames(5)
	home = _main._home
	play_btn = _find_button(home, "▶")
	await _tap(_center(play_btn))
	online_btn = _find_button(_main, "ONLINE —")
	_check("F4: PLAY mode screen ONLINE exists", online_btn != null)
	if online_btn == null:
		_finish()
		return
	await _tap(_center(online_btn))
	var quick100 := _find_button(_main, "100")
	print("INFO: after ONLINE tap: quick100=", quick100)
	_check("F4: ONLINE opens stake picker (100)", quick100 != null)
	if quick100 != null:
		Net.queue_failed.disconnect(_main._on_queue_failed)
		await _tap(_center(quick100))
		var find_btn := _find_button(_main, "FIND OPPONENT")
		_check("F4: stake picker has FIND OPPONENT", find_btn != null)
		if find_btn == null:
			_finish()
			return
		await _tap(_center(find_btn))
		print("INFO: after FIND OPPONENT tap: searching=", _main._searching, " active=", _main._searching_active, " stake=", _main._search_stake)
		_check("F4: FIND OPPONENT starts the search popup", _main._searching != null and _main._searching_active)
		_check("F4: search stake is 100", _main._search_stake == 100)
		if _main._searching != null:
			_main._search_elapsed = 11.9
			await _frames(30)
			var bot_visible: bool = _main._search_bot_button != null and is_instance_valid(_main._search_bot_button) and _main._search_bot_button.visible
			print("INFO: bot fallback visible after 12 s: ", bot_visible)
			_check("F4: search offers BOT fallback after 12 s", bot_visible)
			# Tap the BOT fallback -> practice match starts.
			if bot_visible:
				var bot_btn: Button = _main._search_bot_button
				await _tap(_center(bot_btn))
				print("INFO: after BOT tap: match=", _main._match)
				_check("F4: BOT fallback starts a practice match", _main._match != null)
	_finish()

func _finish() -> void:
	_done = true
	print("=== popup flow test: %d passed, %d failed ===" % [_passed, _failed])
	get_tree().quit(0 if _failed == 0 else 1)
