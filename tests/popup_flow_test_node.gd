extends Node

## Popup-flow test: drives the REAL Main scene and taps through the whole
## PLAY flow with REAL touch events (Input.parse_input_event, the same path
## a phone uses). v3 flow: PLAY opens the FULL-SCREEN mode-choice screen
## (the v2 popup's SOLO/ONLINE buttons were dead on Buddhika's phone);
## difficulty/table popups still open on Main, proven to work on his phone.
## v10 flow: SOLO goes DIRECT to the board (short loading screen, random
## bot) — the difficulty popup (EASY/MEDIUM/HARD) is DELETED, and the
## World Tour roster is DELETED too (no choosing which bot, anywhere).
## v11 flow: PLAY opens the THREE-BIG-BUTTON menu — PLAY WITH A BOT
## (solo vs AI, same direct flow as v10 SOLO), PLAY WITH THE WORLD
## (random matchmaking, same stake picker + 2P/4P choice as v10
## ONLINE), PLAY WITH FRIENDS (invite box). The old SOLO / ONLINE
## tiles are gone; the checks below follow the new buttons.
## Verifies:
##   F1: real tap on PLAY opens the Play menu (BOT + WORLD + FRIENDS)
##   F1b: real tap on BACK returns to the home screen
##   F2: real tap on PLAY WITH A BOT shows the loading screen (no difficulty popup)
##   F3: after the loading screen a solo match starts vs a random bot
##   F4: real tap on PLAY WITH THE WORLD opens the stake picker; quick 100 + FIND
##      OPPONENT starts the search popup (with the 12 s BOT fallback
##      visible after fast-forward)
##   L3: the home ONLINE tile also opens the stake picker and the
##      2P/4P choice — before the fix it jumped straight to 2-player
##      matchmaking with no player-count choice.
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
	# v7: registration is mandatory — Main opens the auth screen without
	# an account. Seed a test account so the test reaches the home screen.
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
	# --- F1: real tap on PLAY opens the three-button Play menu ---
	var play_btn := _find_button(home, "▶")
	_check("F1: PLAY button exists", play_btn != null)
	if play_btn == null:
		_finish()
		return
	print("INFO: PLAY rect=", play_btn.get_global_rect())
	await _tap(_center(play_btn))
	# v11: the menu names its three big buttons (BotButton / WorldButton
	# / FriendsButton) — use them directly instead of label prefixes.
	var bot_btn: Button = _main._mode.bot_button if _main._mode != null else null
	var world_btn: Button = _main._mode.world_button if _main._mode != null else null
	var friends_btn: Button = _main._mode.friends_button if _main._mode != null else null
	print("INFO: after PLAY tap: bot=", bot_btn, " world=", world_btn, " friends=", friends_btn, " mode_screen=", _main._mode, " searching_active=", _main._searching_active)
	_check("F1: PLAY opens the menu with PLAY WITH A BOT", bot_btn != null)
	_check("F1: PLAY opens the menu with PLAY WITH THE WORLD", world_btn != null)
	_check("F1: PLAY opens the menu with PLAY WITH FRIENDS", friends_btn != null)
	if bot_btn == null:
		print("INFO: main subtree after PLAY tap:")
		_dump(_main, "")
		_finish()
		return
	print("INFO: BOT rect=", bot_btn.get_global_rect(), " mf=", bot_btn.mouse_filter)
	print("INFO: WORLD rect=", world_btn.get_global_rect(), " mf=", world_btn.mouse_filter)
	print("INFO: mode screen subtree:")
	_dump(bot_btn.get_parent().get_parent(), "")
	# What control does the viewport think is under the BOT button?
	await _hover_at(_center(bot_btn))
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
		bot_btn = _main._mode.bot_button if _main._mode != null else null
		world_btn = _main._mode.world_button if _main._mode != null else null
		_check("F1b: PLAY again reopens the menu", bot_btn != null and world_btn != null)
		if bot_btn == null:
			_finish()
			return
	# --- F2 (v10, v11): real tap on PLAY WITH A BOT shows the loading
	# screen — NO difficulty popup, no bot choice. Straight to the board. ---
	await _tap(_center(bot_btn))
	var easy_btn := _find_button(_main, "EASY")
	var med_btn := _find_button(_main, "MEDIUM")
	print("INFO: after BOT tap: loading=", _main._loading, " easy=", easy_btn, " medium=", med_btn, " mode screen still there=", _main._mode != null)
	_check("F2: PLAY WITH A BOT shows the loading screen", _main._loading != null and is_instance_valid(_main._loading) and _main._loading.visible)
	_check("F2: no difficulty popup (EASY gone)", easy_btn == null)
	_check("F2: no difficulty popup (MEDIUM gone)", med_btn == null)
	if _main._loading == null:
		print("INFO: main subtree after SOLO tap:")
		_dump(_main, "")
		_finish()
		return
	# --- F3 (v10): after the loading screen a solo match starts ---
	for i in range(40):
		await _frames(3)
		if _main._match != null:
			break
	print("INFO: after loading: match=", _main._match)
	_check("F3: loading finishes and a solo match starts", _main._match != null)
	if _main._match != null:
		_check("F3: solo match is free (no stake)", _main._match.your_stake == 0 and _main._match.mode == "solo")
	# --- F4: PLAY WITH THE WORLD path — stake picker, then search popup ---
	_main._show_home()
	await _frames(5)
	home = _main._home
	play_btn = _find_button(home, "▶")
	await _tap(_center(play_btn))
	world_btn = _main._mode.world_button if _main._mode != null else null
	_check("F4: PLAY menu PLAY WITH THE WORLD exists", world_btn != null)
	if world_btn == null:
		_finish()
		return
	await _tap(_center(world_btn))
	var quick100 := _find_button(_main, "100")
	print("INFO: after WORLD tap: quick100=", quick100)
	_check("F4: PLAY WITH THE WORLD opens stake picker (100)", quick100 != null)
	if quick100 != null:
		Net.queue_failed.disconnect(_main._on_queue_failed)
		await _tap(_center(quick100))
		var find_btn := _find_button(_main, "FIND OPPONENT")
		_check("F4: stake picker has FIND OPPONENT", find_btn != null)
		if find_btn == null:
			_finish()
			return
		await _tap(_center(find_btn))
		# v6: after the stake comes the 2P/4P choice — tap 2 PLAYERS.
		var two_btn := _find_button(_main, "2 PLAYERS")
		print("INFO: after FIND OPPONENT tap: 2p choice=", two_btn)
		_check("F4: stake confirm opens the 2P/4P choice", two_btn != null)
		if two_btn == null:
			_finish()
			return
		await _tap(_center(two_btn))
		print("INFO: after 2 PLAYERS tap: searching=", _main._searching, " active=", _main._searching_active, " stake=", _main._search_stake)
		_check("F4: 2 PLAYERS starts the search popup", _main._searching != null and _main._searching_active)
		_check("F4: search stake is 100", _main._search_stake == 100)
		if _main._searching != null:
			_main._search_elapsed = 11.9
			await _frames(30)
			var bot_visible: bool = _main._search_bot_button != null and is_instance_valid(_main._search_bot_button) and _main._search_bot_button.visible
			print("INFO: bot fallback visible after 12 s: ", bot_visible)
			_check("F4: search offers BOT fallback after 12 s", bot_visible)
			# Tap the BOT fallback -> practice match starts.
			if bot_visible:
				var search_bot_btn: Button = _main._search_bot_button
				await _tap(_center(search_bot_btn))
				print("INFO: after BOT tap: match=", _main._match)
				_check("F4: BOT fallback starts a practice match", _main._match != null)
	# --- L3: home ONLINE tile — stake picker, then the 2P/4P choice
	# (same as PLAY → ONLINE; before the fix it went straight to
	# 2-player matchmaking) ---
	_main._show_home()
	await _frames(5)
	home = _main._home
	var online_tile := _find_button(home, "ONLINE")
	_check("L3: home ONLINE tile exists", online_tile != null)
	if online_tile != null:
		await _tap(_center(online_tile))
		var quick100b := _find_button(_main, "100")
		_check("L3: home ONLINE opens the stake picker (100)", quick100b != null)
		if quick100b != null:
			await _tap(_center(quick100b))
			var find_btn2 := _find_button(_main, "FIND OPPONENT")
			_check("L3: home stake picker has FIND OPPONENT", find_btn2 != null)
			if find_btn2 != null:
				await _tap(_center(find_btn2))
				var two_btn2 := _find_button(_main, "2 PLAYERS")
				var four_btn2 := _find_button(_main, "4 PLAYERS")
				_check("L3: home ONLINE offers the 2P/4P choice", two_btn2 != null and four_btn2 != null)
				if two_btn2 != null:
					await _tap(_center(two_btn2))
					_check("L3: 2 PLAYERS from home starts the search popup", _main._searching != null and _main._searching_active)
					_check("L3: search stake is 100", _main._search_stake == 100)
	_finish()

func _finish() -> void:
	_done = true
	print("=== popup flow test: %d passed, %d failed ===" % [_passed, _failed])
	get_tree().quit(0 if _failed == 0 else 1)
