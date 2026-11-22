extends Node

## Double-event test: reproduces the ANDROID input path, where every touch
## also generates an emulated mouse event (emulate_mouse_from_touch=true,
## the default). The tap sequence Android produces is:
##   touch press -> mouse press -> touch release -> mouse release
## If the PLAY flow buttons only fail under this sequence, the emulated
## mouse event is interfering with the Button press state.
## v3 flow: PLAY -> full-screen mode screen -> SOLO -> difficulty popup
## -> EASY -> match. (The v2 popup is gone; the mode screen is a plain
## full-screen layout like the home screen.)
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
	var solo_btn := _find_button(_main, "SOLO —")
	var online_btn := _find_button(_main, "ONLINE —")
	print("INFO: after PLAY android-tap: solo=", solo_btn, " online=", online_btn)
	_check("PLAY opens mode screen (android tap)", solo_btn != null and online_btn != null)
	if solo_btn == null:
		_finish()
		return
	# Android-style tap on SOLO.
	await _tap_android(_center(solo_btn))
	var easy_btn := _find_button(_main, "EASY")
	print("INFO: after SOLO android-tap: easy=", easy_btn, " mode screen valid=", is_instance_valid(solo_btn))
	_check("SOLO opens difficulty popup (android tap)", easy_btn != null)
	if easy_btn == null:
		_finish()
		return
	# Android-style tap on EASY.
	await _tap_android(_center(easy_btn))
	print("INFO: after EASY android-tap: match=", _main._match)
	_check("EASY starts a match (android tap)", _main._match != null)
	_finish()

func _finish() -> void:
	_done = true
	print("=== popup double-event test: %d passed, %d failed ===" % [_passed, _failed])
	get_tree().quit(0 if _failed == 0 else 1)
