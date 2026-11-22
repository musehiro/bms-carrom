extends Control

## Main — screen manager: Home, Solo/Online match, Shop, How to Play,
## Aim-Assist, matchmaking. Also routes AdMob rewarded-ad rewards and
## handles the --shot=... screenshot mode used for verification.

var _home: HomeScreen = null
var _mode: ModeChoiceScreen = null
var _match: MatchScreen = null
var _searching: Control = null
var _search_table := 0
var _search_elapsed := 0.0
var _searching_active := false
var _search_widened := false
var _search_bot_button: Button = null
var _search_status: Label = null
var _toast_label: Label = null
var _shot_mode := ""
var _shot_out := ""

func _ready() -> void:
	# Root Control must NOT swallow input: it covers the whole screen and
	# its default mouse_filter (STOP) used to eat every touch before the
	# match screen's _unhandled_input ever saw it (v1: drag did nothing).
	# IGNORE lets unhandled events fall through; Buttons/popups still get
	# their own input as children.
	mouse_filter = Control.MOUSE_FILTER_IGNORE
	Sfx.set_enabled(Save.sound_on)
	Ads.rewarded_earned.connect(_on_rewarded_earned)
	Ads.rewarded_failed.connect(_on_rewarded_failed)
	Net.matched.connect(_on_matched)
	Net.queue_failed.connect(_on_queue_failed)
	Net.connected_to_server.connect(_on_net_connected)
	var args := OS.get_cmdline_user_args()
	for a in args:
		if a.begins_with("--shot="):
			_shot_mode = a.trim_prefix("--shot=")
		elif a.begins_with("--shot-out="):
			_shot_out = a.trim_prefix("--shot-out=")
	if _shot_mode != "":
		_run_shot_mode()
	else:
		_show_home()

func _process(delta: float) -> void:
	if _searching_active:
		_search_elapsed += delta
		if _search_elapsed >= 30.0 and not _search_widened:
			_search_widened = true
			if _search_status:
				_search_status.text = "Searching… %ds\nNo match yet — widened to ±4 levels." % int(_search_elapsed)
		if _search_elapsed >= 12.0 and _search_bot_button:
			# Timeout fallback (v2): never a dead-end popup with only Cancel.
			_search_bot_button.visible = true
		if _search_status and not _search_widened:
			if _search_elapsed >= 12.0:
				_search_status.text = "Searching… %ds\nNo opponent yet — play vs the computer instead." % int(_search_elapsed)
			else:
				_search_status.text = "Searching for an opponent… %ds\nMatched within ±2 levels." % int(_search_elapsed)

# ------------------------------------------------------------------- screens

func _clear() -> void:
	for c in get_children():
		c.queue_free()
	_home = null
	_mode = null
	_match = null
	_searching = null
	_searching_active = false

func _show_home() -> void:
	_clear()
	_home = HomeScreen.new()
	add_child(_home)
	_home.play_solo.connect(_start_solo)
	_home.play_online.connect(_start_matchmaking)
	_home.open_mode_choice.connect(_open_mode_choice)
	_home.open_shop.connect(_open_shop)
	_home.open_howto.connect(_open_howto)
	_home.open_aim_assist.connect(_open_aim_assist)
	_home.watch_ad_coins.connect(_on_watch_ad_coins)
	_home.refresh()
	var comeback := Save.maybe_comeback_coins()
	if comeback > 0:
		_toast("Comeback coins: +%d — never start broke!" % comeback)

func _start_solo(difficulty: int) -> void:
	_clear()
	_match = MatchScreen.new()
	add_child(_match)
	var names := ["Easy Bot", "Medium Bot", "Hard Bot"]
	_match.setup("solo", difficulty, 0, names[difficulty], difficulty + 1, null)
	_match.exit_to_home.connect(_show_home)
	_match.rematch_requested.connect(func() -> void: _start_solo(difficulty))

# ---------------------------------------------------------- mode choice (v3)

func _open_mode_choice() -> void:
	# Full-screen mode screen (like Shop), NOT a popup: the v2 PLAY popup's
	# buttons were dead on Buddhika's phone while the X worked, and the
	# home screen's own buttons work there — this screen is built the same
	# plain way. The difficulty/table popups below are the ones proven to
	# work on his phone (homepage SOLO -> EASY enters a match).
	_clear()
	_mode = ModeChoiceScreen.new()
	add_child(_mode)
	_mode.solo_chosen.connect(_show_solo_difficulty)
	_mode.online_chosen.connect(_show_online_tables)
	_mode.go_back.connect(_show_home)

func _show_solo_difficulty() -> void:
	var pop: Dictionary = UiKit.popup_window("SOLO — vs AI (offline)", Vector2(560, 460))
	add_child(pop["dim"])
	var box: VBoxContainer = pop["box"]
	box.add_child(UiKit.body_label("No internet needed. Win coins: Easy +50, Medium +100, Hard +200.", 20))
	for i in range(3):
		var names := ["EASY", "MEDIUM", "HARD"]
		var descs := ["Relaxed — misses often, never chases the queen.", "A fair fight — sometimes chases the queen.", "Sharp — near-perfect aim, chases the queen."]
		var b := UiKit.gold_button(names[i], 26) if i == 1 else UiKit.dark_button(names[i], 26)
		box.add_child(b)
		var d := UiKit.muted_label(descs[i], 17)
		box.add_child(d)
		var diff := i
		b.pressed.connect(func() -> void:
			pop["dim"].queue_free()
			_start_solo(diff))
	pop["close"].pressed.connect(func() -> void: pop["dim"].queue_free())

func _show_online_tables() -> void:
	var pop: Dictionary = UiKit.popup_window("ONLINE — pick a table", Vector2(560, 500))
	add_child(pop["dim"])
	var box: VBoxContainer = pop["box"]
	box.add_child(UiKit.body_label("Real players worldwide, matched within ±2 levels. Winner takes the pot (both entries).", 20))
	var tables := [["LOW", 100, "Entry 100 • Pot 200"], ["MID", 500, "Entry 500 • Pot 1,000"], ["HIGH", 2000, "Entry 2,000 • Pot 4,000"]]
	for i in range(3):
		var b := UiKit.dark_button("%s — %s" % [tables[i][0], tables[i][2]], 22)
		box.add_child(b)
		var t := i
		b.pressed.connect(func() -> void:
			pop["dim"].queue_free()
			_start_matchmaking(t))
	pop["close"].pressed.connect(func() -> void: pop["dim"].queue_free())

func _open_shop() -> void:
	_clear()
	var shop := ShopScreen.new()
	add_child(shop)
	shop.closed.connect(_show_home)

func _open_howto() -> void:
	if _home:
		var h := HowToScreen.show_on(_home)
		h.closed.connect(func() -> void: _home.refresh())

func _open_aim_assist() -> void:
	var parent: Control = _home if _home else self
	var pop: Dictionary = UiKit.popup_window("AIM-ASSIST — EASY MODE", Vector2(580, 520))
	parent.add_child(pop["dim"])
	var box: VBoxContainer = pop["box"]
	if Save.aim_assist_active():
		var left := Save.aim_assist_remaining_sec()
		box.add_child(UiKit.body_label("ACTIVE — %02d:%02d left.\nExact aim line + pocket glow + 5 extra seconds per shot. Buying or watching again extends it (max 3 hours)." % [left / 60, left % 60], 22))
	else:
		box.add_child(UiKit.body_label("For 1 hour: a longer, exact aim line (with 1 cushion bounce), a glowing pocket when lined up, and +5 s per shot. It never auto-aims — you still take the shot.", 22))
	var buy := UiKit.gold_button("BUY 1 HOUR — ◉ 2,000", 24)
	buy.pressed.connect(func() -> void:
		if Save.spend_coins(AdsConfig.AIM_ASSIST_COINS_PRICE):
			Save.grant_aim_assist(1.0)
			_toast("Aim-Assist active for 1 hour!")
			pop["dim"].queue_free()
			if _home: _home.refresh()
		else:
			_toast("Not enough coins — win matches or watch ads."))
	box.add_child(buy)
	var ads := UiKit.dark_button("WATCH 2 ADS — 1 HOUR  (%d/2 watched)" % Save.aim_assist_ads_progress, 22)
	ads.pressed.connect(func() -> void:
		pop["dim"].queue_free()
		Ads.show_rewarded("aim_assist"))
	box.add_child(ads)
	box.add_child(UiKit.muted_label("Allowed in online matches too — the line is capped at 1 bounce, so it stays fair.", 16))
	pop["close"].pressed.connect(func() -> void: pop["dim"].queue_free())

# -------------------------------------------------------------- matchmaking

func _start_matchmaking(table: int) -> void:
	var entry: int = Save.ONLINE_ENTRY[table]
	if Save.coins < entry:
		var comeback := Save.maybe_comeback_coins()
		if Save.coins < entry:
			_toast("Not enough coins for this table (need %d)." % entry)
			return
		_toast("Comeback coins: +%d" % comeback)
		if _home:
			_home.refresh()
	_search_table = table
	_search_elapsed = 0.0
	_search_widened = false
	_searching_active = true
	_searching = Control.new()
	UiKit.full_rect(_searching)
	var dim := ColorRect.new()
	dim.color = Color(0, 0, 0, 0.75)
	UiKit.full_rect(dim)
	_searching.add_child(dim)
	var pop: Dictionary = UiKit.popup_window("FINDING OPPONENT", Vector2(560, 460))
	_searching.add_child(pop["dim"])
	var box: VBoxContainer = pop["box"]
	_search_status = UiKit.body_label("Searching for an opponent… 0s\nMatched within ±2 levels.", 22)
	box.add_child(_search_status)
	var table_label := UiKit.muted_label("Table: %s — entry ◉ %d, pot ◉ %d" % [["LOW", "MID", "HIGH"][table], entry, entry * 2], 18)
	box.add_child(table_label)
	_search_bot_button = UiKit.dark_button("NO OPPONENT? PLAY vs COMPUTER INSTEAD", 20)
	_search_bot_button.visible = false
	_search_bot_button.pressed.connect(_on_play_bot_from_search)
	box.add_child(_search_bot_button)
	var cancel := UiKit.dark_button("CANCEL", 24)
	cancel.pressed.connect(_cancel_search)
	box.add_child(cancel)
	pop["close"].pressed.connect(_cancel_search)
	if _home:
		_home.add_child(_searching)
	else:
		add_child(_searching)
	if Net.is_connected_to_server():
		Net.queue_up(Save.player_name, Save.level(), table)
	else:
		Net.connect_to_server(Save.online_host, NetClient.DEFAULT_PORT)

func _on_net_connected() -> void:
	if _searching_active:
		Net.queue_up(Save.player_name, Save.level(), _search_table)

func _on_matched(data: Dictionary) -> void:
	if not _searching_active:
		return
	_searching_active = false
	var opp_name := String(data.get("opponent", "Player"))
	var opp_level := int(data.get("opp_level", 1))
	var you_break := bool(data.get("you_break", true))
	_clear()
	_match = MatchScreen.new()
	add_child(_match)
	_match.setup("online", 0, _search_table, opp_name, opp_level, Net, 0 if you_break else 1)
	_match.exit_to_home.connect(_show_home)
	_match.rematch_requested.connect(func() -> void: _start_matchmaking(_search_table))

func _on_play_bot_from_search() -> void:
	# Labelled BOT match — never a fake human (design doc 3.2).
	_searching_active = false
	Net.disconnect_client()
	_clear()
	_match = MatchScreen.new()
	add_child(_match)
	_match.setup("solo", 1, 0, "BOT (Practice)", 1, null)
	_match.exit_to_home.connect(_show_home)
	_match.rematch_requested.connect(func() -> void: _start_solo(1))
	_toast("Practice vs BOT — clearly labelled, no coins at stake.")

func _cancel_search() -> void:
	_searching_active = false
	Net.disconnect_client()
	if _searching:
		_searching.queue_free()
		_searching = null

func _on_queue_failed(message: String) -> void:
	if _searching_active:
		_searching_active = false
		if _searching:
			_searching.queue_free()
			_searching = null
	_toast(message)

# ---------------------------------------------------------------------- ads

func _on_watch_ad_coins() -> void:
	if Save.rewarded_ads_left_today() <= 0:
		_toast("Daily rewarded-ad limit reached (5/day). Come back tomorrow!")
		return
	Ads.show_rewarded("coins")

func _on_rewarded_earned(reason: String, simulated: bool) -> void:
	if reason == "coins":
		Save.record_rewarded_ad_watched()
		Save.add_coins(AdsConfig.REWARDED_COINS)
		_toast("+%d coins!%s" % [AdsConfig.REWARDED_COINS, " (test ad simulated)" if simulated else ""])
	elif reason == "aim_assist":
		Save.record_rewarded_ad_watched()
		Save.aim_assist_ads_progress += 1
		if Save.aim_assist_ads_progress >= AdsConfig.AIM_ASSIST_ADS_NEEDED:
			Save.aim_assist_ads_progress = 0
			Save.grant_aim_assist(1.0)
			_toast("Aim-Assist active for 1 hour!%s" % (" (test ads simulated)" if simulated else ""))
		else:
			_toast("Ad %d of 2 watched — one more for 1 hour of Aim-Assist." % Save.aim_assist_ads_progress)
		Save.save()
	if _home:
		_home.refresh()

func _on_rewarded_failed(reason: String) -> void:
	_toast("Ad didn't load — no reward. Try again later.")

# --------------------------------------------------------------------- toast

func _toast(text: String) -> void:
	if _toast_label:
		_toast_label.queue_free()
	_toast_label = Label.new()
	_toast_label.text = text
	_toast_label.add_theme_font_size_override("font_size", 22)
	_toast_label.add_theme_color_override("font_color", Color(1, 0.9, 0.5))
	_toast_label.add_theme_color_override("font_shadow_color", Color(0, 0, 0, 0.9))
	_toast_label.add_theme_constant_override("shadow_offset_x", 2)
	_toast_label.add_theme_constant_override("shadow_offset_y", 2)
	_toast_label.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	_toast_label.set_anchors_preset(Control.PRESET_CENTER_BOTTOM)
	_toast_label.offset_top = -120
	_toast_label.offset_bottom = -80
	_toast_label.offset_left = -340
	_toast_label.offset_right = 340
	add_child(_toast_label)
	var t := Timer.new()
	t.wait_time = 2.5
	t.one_shot = true
	t.timeout.connect(func() -> void:
		if _toast_label:
			_toast_label.queue_free()
			_toast_label = null)
	add_child(t)
	t.start()

# ------------------------------------------------------------ screenshot mode

func _run_shot_mode() -> void:
	match _shot_mode:
		"home":
			_show_home()
			_capture_after(1.5)
		"shop":
			_open_shop()
			_capture_after(1.5)
		"howto":
			_show_home()
			_open_howto()
			_capture_after(1.5)
		"match":
			_start_solo(1)
			_demo_shot_and_capture()
		"aim":
			# Aim guide preview: local turn, striker placed, aim state
			# forced on so the capture shows the dotted line, the orange
			# arrow and the striker halo.
			_start_solo(1)
			_demo_aim_and_capture()
		"playchoice":
			# v3: PLAY opens the full-screen mode-choice screen (no popup).
			_open_mode_choice()
			_capture_after(1.0)
		"search":
			# Search with the queue-failed handler disconnected so the popup
			# stays up (no server here); jump near the 12 s timeout so the
			# labelled-BOT fallback button is visible in the capture.
			_show_home()
			Net.queue_failed.disconnect(_on_queue_failed)
			_start_matchmaking(0)
			_search_elapsed = 11.5
			_capture_after(1.2)
		_:
			_show_home()
			_capture_after(1.5)

func _capture_after(seconds: float) -> void:
	await get_tree().create_timer(seconds).timeout
	_capture()

func _demo_shot_and_capture() -> void:
	# Wait until it is the local player's turn (the AI may break first),
	# then take a real shot from the bottom baseline so the screenshot
	# shows a game in progress (coins scattered, not the setup).
	var waited := 0.0
	while waited < 9.0:
		await get_tree().create_timer(0.5).timeout
		waited += 0.5
		if _match == null:
			_capture()
			return
		if _match.phase == "place" and int(_match.rules_state["turn"]) == 0:
			break
	if _match and _match.phase == "place":
		_match._striker["pos"] = Vector2(360.0, CarromPhysics.baseline_y(0))
		var dir: Vector2 = (CarromPhysics.BOARD_CENTER - _match._striker["pos"]).normalized()
		_match._shoot(dir, 0.95, false)
		await get_tree().create_timer(2.6).timeout
	_capture()

func _demo_aim_and_capture() -> void:
	# Wait until it is the local player's turn (the AI may break first),
	# then place the striker and force the aim state on for the capture.
	var waited := 0.0
	while waited < 9.0:
		await get_tree().create_timer(0.5).timeout
		waited += 0.5
		if _match == null:
			_capture()
			return
		if _match.phase == "place" and int(_match.rules_state["turn"]) == 0:
			break
	if _match and _match.phase == "place":
		_match._striker["pos"] = Vector2(360.0, CarromPhysics.baseline_y(0))
		var dir: Vector2 = (CarromPhysics.BOARD_CENTER - _match._striker["pos"]).normalized()
		_match.board_view.aim_visible = true
		_match.board_view.aim_from = _match._striker["pos"]
		_match.board_view.aim_dir = dir
		_match.board_view.aim_power = 0.6
		_match.board_view.your_turn = true
		await get_tree().create_timer(0.4).timeout
	_capture()

func _capture() -> void:
	await get_tree().process_frame
	await get_tree().process_frame
	var img := get_viewport().get_texture().get_image()
	var path := _shot_out if _shot_out != "" else "user://shot.png"
	var err := img.save_png(path)
	print("SHOT_SAVED ", path, " err=", err, " size=", img.get_size())
	get_tree().quit()
