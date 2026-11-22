class_name HomeScreen
extends Control

## Homepage (design doc 8): top bar (avatar + level, coins, sound), hero with
## a live mini board, big PLAY, SOLO / ONLINE, SHOP / HOW TO PLAY /
## AIM-ASSIST row, daily reward + level bar + version at the bottom.

signal play_solo(difficulty: int)
signal play_online(table: int)
signal open_shop
signal open_howto
signal open_aim_assist
signal watch_ad_coins

var _coins_label: Label
var _level_label: Label
var _xp_bar: ProgressBar
var _daily_button: Button
var _sound_button: Button
var _assist_button: Button

func _ready() -> void:
	UiKit.full_rect(self)
	var bg := ColorRect.new()
	bg.color = Color(0.15, 0.11, 0.07)
	bg.mouse_filter = Control.MOUSE_FILTER_IGNORE
	UiKit.full_rect(bg)
	add_child(bg)
	var root := VBoxContainer.new()
	UiKit.full_rect(root)
	root.offset_left = 20
	root.offset_right = -20
	root.offset_top = 14
	root.offset_bottom = -14
	root.add_theme_constant_override("separation", 12)
	add_child(root)
	# ---- Top bar ----
	var top := HBoxContainer.new()
	top.add_theme_constant_override("separation", 10)
	root.add_child(top)
	var avatar := PanelContainer.new()
	avatar.add_theme_stylebox_override("panel", UiKit.panel_style(Color(0.83, 0.69, 0.22), Color(0.83, 0.69, 0.22), 28, 2))
	var av_label := Label.new()
	av_label.text = Save.player_name.substr(0, 1).to_upper()
	av_label.add_theme_font_size_override("font_size", 28)
	av_label.add_theme_color_override("font_color", UiKit.DARK_TEXT)
	av_label.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	avatar.add_child(av_label)
	avatar.custom_minimum_size = Vector2(56, 56)
	top.add_child(avatar)
	var id_box := VBoxContainer.new()
	id_box.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	var name_label := Label.new()
	name_label.text = Save.player_name
	name_label.add_theme_font_size_override("font_size", 24)
	name_label.add_theme_color_override("font_color", UiKit.TEXT)
	id_box.add_child(name_label)
	_level_label = Label.new()
	_level_label.add_theme_font_size_override("font_size", 18)
	_level_label.add_theme_color_override("font_color", UiKit.GOLD_LIGHT)
	id_box.add_child(_level_label)
	top.add_child(id_box)
	_coins_label = Label.new()
	_coins_label.add_theme_font_size_override("font_size", 24)
	_coins_label.add_theme_color_override("font_color", UiKit.GOLD_LIGHT)
	top.add_child(_coins_label)
	var coins_btn := UiKit.dark_button("◉", 24)
	coins_btn.custom_minimum_size = Vector2(52, 52)
	coins_btn.pressed.connect(func() -> void: open_shop.emit())
	top.add_child(coins_btn)
	_sound_button = UiKit.dark_button("♪", 24)
	_sound_button.custom_minimum_size = Vector2(52, 52)
	_sound_button.pressed.connect(_on_sound_pressed)
	top.add_child(_sound_button)
	# ---- Hero: title + mini board ----
	var hero := VBoxContainer.new()
	hero.add_theme_constant_override("separation", 0)
	root.add_child(hero)
	var title := UiKit.title_label("BMS CARROM", 56)
	hero.add_child(title)
	var sub := UiKit.muted_label("Real carrom • Online & offline • Fewer ads", 18)
	hero.add_child(sub)
	var divider := ColorRect.new()
	divider.color = Color(0.83, 0.69, 0.22, 0.55)
	divider.custom_minimum_size = Vector2(0, 3)
	divider.mouse_filter = Control.MOUSE_FILTER_IGNORE
	hero.add_child(divider)
	var board_holder := Control.new()
	board_holder.custom_minimum_size = Vector2(680, 380)
	board_holder.mouse_filter = Control.MOUSE_FILTER_IGNORE
	hero.add_child(board_holder)
	var mini := BoardView.new()
	mini.board_id = Save.equipped_board
	mini.striker_id = Save.equipped_striker
	mini.draw_backdrop = false
	mini.pieces = CarromPhysics.setup_pieces()
	mini.position = Vector2(142, -135)
	mini.scale = Vector2(0.55, 0.55)
	board_holder.add_child(mini)
	# ---- Big PLAY ----
	var play := UiKit.gold_button("▶  PLAY", 40)
	play.custom_minimum_size = Vector2(0, 84)
	play.pressed.connect(_on_play_pressed)
	root.add_child(play)
	var play_hint := UiKit.muted_label("One tap — choose Solo (offline) or Online", 16)
	root.add_child(play_hint)
	# ---- SOLO / ONLINE ----
	var modes := HBoxContainer.new()
	modes.add_theme_constant_override("separation", 12)
	root.add_child(modes)
	var solo := UiKit.dark_button("SOLO\nvs AI — offline", 24)
	solo.custom_minimum_size = Vector2(0, 92)
	solo.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	solo.pressed.connect(_on_solo_pressed)
	modes.add_child(solo)
	var online := UiKit.dark_button("ONLINE\nvs real players", 24)
	online.custom_minimum_size = Vector2(0, 92)
	online.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	online.pressed.connect(_on_online_pressed)
	modes.add_child(online)
	# ---- Row of 3 ----
	var row := HBoxContainer.new()
	row.add_theme_constant_override("separation", 12)
	root.add_child(row)
	var shop := UiKit.dark_button("SHOP", 22)
	shop.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	shop.pressed.connect(func() -> void: open_shop.emit())
	row.add_child(shop)
	var howto := UiKit.dark_button("HOW TO PLAY", 22)
	howto.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	howto.pressed.connect(func() -> void: open_howto.emit())
	row.add_child(howto)
	_assist_button = UiKit.dark_button("AIM-ASSIST", 22)
	_assist_button.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	_assist_button.pressed.connect(func() -> void: open_aim_assist.emit())
	row.add_child(_assist_button)
	# ---- Bottom strip ----
	var bottom := VBoxContainer.new()
	bottom.add_theme_constant_override("separation", 6)
	root.add_child(bottom)
	_daily_button = UiKit.gold_button("CLAIM DAILY BONUS", 22)
	_daily_button.pressed.connect(_on_daily_pressed)
	bottom.add_child(_daily_button)
	var free_coins := UiKit.dark_button("FREE COINS +150  (watch a short ad)", 20)
	free_coins.pressed.connect(func() -> void: watch_ad_coins.emit())
	bottom.add_child(free_coins)
	_xp_bar = ProgressBar.new()
	_xp_bar.min_value = 0
	_xp_bar.max_value = Save.XP_PER_LEVEL
	_xp_bar.show_percentage = false
	_xp_bar.custom_minimum_size = Vector2(0, 14)
	var bg_style := StyleBoxFlat.new()
	bg_style.bg_color = Color(0, 0, 0, 0.5)
	bg_style.set_corner_radius_all(7)
	_xp_bar.add_theme_stylebox_override("background", bg_style)
	var fill := StyleBoxFlat.new()
	fill.bg_color = UiKit.GOLD
	fill.set_corner_radius_all(7)
	_xp_bar.add_theme_stylebox_override("fill", fill)
	bottom.add_child(_xp_bar)
	var ver := UiKit.muted_label("BMS Carrom v2.0  •  Free to play  •  No account needed", 15)
	bottom.add_child(ver)
	refresh()

func refresh() -> void:
	_coins_label.text = "◉ %s" % _fmt(Save.coins)
	_level_label.text = "Lv %d · %s" % [Save.level(), Save.rank_name()]
	_xp_bar.value = Save.xp_into_level()
	_xp_bar.max_value = Save.XP_PER_LEVEL
	_sound_button.text = "♪" if Save.sound_on else "∅"
	if Save.can_claim_daily():
		_daily_button.visible = true
		_daily_button.text = "CLAIM DAILY BONUS  (+%d coins)" % Save.daily_bonus_amount()
	else:
		_daily_button.visible = false
	if Save.aim_assist_active():
		var left := Save.aim_assist_remaining_sec()
		_assist_button.text = "AIM-ASSIST %02d:%02d" % [left / 60, left % 60]
	else:
		_assist_button.text = "AIM-ASSIST"

func _fmt(n: int) -> String:
	var s := str(n)
	var out := ""
	while s.length() > 3:
		out = "," + s.substr(s.length() - 3, 3) + out
		s = s.substr(0, s.length() - 3)
	return s + out

func _on_sound_pressed() -> void:
	Save.sound_on = not Save.sound_on
	Sfx.set_enabled(Save.sound_on)
	Save.save()
	refresh()

func _on_daily_pressed() -> void:
	var amount := Save.claim_daily()
	if amount > 0:
		_daily_button.text = "CLAIMED +%d COINS!" % amount
		Sfx.win()
	refresh()

func _on_play_pressed() -> void:
	# v2: PLAY opens a clear mode choice — it used to jump straight into
	# online matchmaking, which dead-ended (no server, no players).
	var pop: Dictionary = UiKit.popup_window("PLAY — choose a mode", Vector2(560, 440))
	add_child(pop["dim"])
	var box: VBoxContainer = pop["box"]
	box.add_child(UiKit.body_label("Solo is offline vs the computer. Online is a real player, anywhere in the world.", 20))
	var solo := UiKit.gold_button("SOLO — vs AI (offline)", 26)
	var online := UiKit.dark_button("ONLINE — vs real players", 26)
	box.add_child(solo)
	box.add_child(online)
	solo.pressed.connect(func() -> void:
		pop["dim"].queue_free()
		_on_solo_pressed())
	online.pressed.connect(func() -> void:
		pop["dim"].queue_free()
		_on_online_pressed())
	pop["close"].pressed.connect(func() -> void: pop["dim"].queue_free())

func _on_solo_pressed() -> void:
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
			play_solo.emit(diff))
	pop["close"].pressed.connect(func() -> void: pop["dim"].queue_free())

func _on_online_pressed() -> void:
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
			play_online.emit(t))
	pop["close"].pressed.connect(func() -> void: pop["dim"].queue_free())
