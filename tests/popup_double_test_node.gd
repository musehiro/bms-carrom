extends Node

## Double-event test: reproduces the ANDROID input path, where every touch
## also generates an emulated mouse event (emulate_mouse_from_touch=true,
## the default). The tap sequence Android produces is:
##   touch press -> mouse press -> touch release -> mouse release
## If the PLAY flow buttons only fail under this sequence, the emulated
## mouse event is interfering with the Button press state.
## v3 flow: PLAY -> full-screen mode screen -> SOLO -> difficulty popup
## -> EASY -> match. v10 flow: PLAY -> mode screen -> SOLO -> loading
## screen -> match (the difficulty popup is deleted; SOLO goes direct).
## v11 flow: PLAY -> three-button menu -> PLAY WITH A BOT -> loading
## screen -> match (same direct solo flow; the old SOLO / ONLINE
## tiles are gone, the buttons are BotButton / WorldButton /
## FriendsButton on the new PlayMenuScreen).
## (The v2 popup is gone; the mode screen is a plain full-screen layout
## like the home screen.)
## Run: xvfb-run -a -s "-screen 0 720x1640x24" godot --resolution 720x1640
##      --path . res://tests/popup_double_test.tscn
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
	# v7: registration is mandatory — seed a test account so Main
	# reaches the home screen instead of the auth screen.
	Save.account_gmail = "test.player@gmail.com"
	Save.account_id = "test-account-id"
	Save.account_verified = true
	Save.player_name = "Test Player"
	Save.save()
	var main_scene: PackedScene = load("res://scenes/main.tscn")
	_main = main_scene.instantiate()
	add_child(_main)
	_run()

func _process(delta: float) -> void:
	if _done:
		return
	_wait += delta
	if _wait > 60.0:
		print("[PopupDoubleTest] TIMEOUT")
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

# Android tap: touch press, emulated mouse press, touch release, emulated
# mouse release — in that exact order, like Main::process_input does.
func _tap_android(pos: Vector2) -> void:
	var p := _ev(pos)
	var t1 := InputEventScreenTouch.new()
	t1.position = p
	t1.pressed = true
	t1.index = 0
	Input.parse_input_event(t1)
	await _frames(1)
	var m1 := InputEventMouseButton.new()
	m1.position = p
	m1.pressed = true
	m1.button_index = MOUSE_BUTTON_LEFT
	Input.parse_input_event(m1)
	await _frames(1)
	var t2 := InputEventScreenTouch.new()
	t2.position = p
	t2.pressed = false
	t2.index = 0
	Input.parse_input_event(t2)
	await _frames(1)
	var m2 := InputEventMouseButton.new()
	m2.position = p
	m2.pressed = false
	m2.button_index = MOUSE_BUTTON_LEFT
	Input.parse_input_event(m2)
	await _frames(3)

func _find_button(root: Node, prefix: String) -> Button:
	for n in root.get_children():
		if n is Button and String((n as Button).text).begins_with(prefix):
			return n
		var found := _find_button(n, prefix)
		if found:
			return found
	return null

func _center(b: Button) -> Vector2:
	return (b as Control).get_global_rect().get_center()

func _run() -> void:
	await _frames(5)
	var home = _main._home
	_check("home shown", home != null)
	if home == null:
		_finish()
		return
	var play_btn := _find_button(home, "▶")
	_check("PLAY button exists", play_btn != null)
	if play_btn == null:
		_finish()
		return
	# Android-style tap on PLAY.
	await _tap_android(_center(play_btn))
	var bot_btn: Button = _main._mode.bot_button if _main._mode != null else null
	var two_btn: Button = _main._mode.two_players_button if _main._mode != null else null
	print("INFO: after PLAY android-tap: bot=", bot_btn, " two_players=", two_btn)
	_check("PLAY opens the menu (android tap)", bot_btn != null and two_btn != null)
	if bot_btn == null:
		_finish()
		return
	# Android-style tap on PLAY WITH A BOT (v10: direct play — loading, then board).
	await _tap_android(_center(bot_btn))
	var easy_btn := _find_button(_main, "EASY")
	print("INFO: after BOT android-tap: loading=", _main._loading, " easy=", easy_btn, " mode screen valid=", is_instance_valid(bot_btn))
	_check("PLAY WITH A BOT shows the loading screen (android tap)", _main._loading != null and is_instance_valid(_main._loading))
	_check("PLAY WITH A BOT has no difficulty popup (android tap)", easy_btn == null)
	if _main._loading == null:
		_finish()
		return
	# The loading screen hands over to the board after ~1.2 s.
	for i in range(40):
		await _frames(3)
		if _main._match != null:
			break
	print("INFO: after loading (android tap): match=", _main._match)
	_check("loading starts a match (android tap)", _main._match != null)
	_finish()

func _finish() -> void:
	_done = true
	print("=== popup double-event test: %d passed, %d failed ===" % [_passed, _failed])
	get_tree().quit(0 if _failed == 0 else 1)
