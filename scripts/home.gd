class_name HomeScreen
extends Control

## Homepage (v5, design doc 8): top bar (avatar + level, coins, sound),
## OUT OF COINS banner (only at zero coins), hero with a LARGE labelled
## board (the homepage logo — board only, no title text — now teaching
## the parts: Striker, White coin, Black coin, Queen, Pocket, Base line,
## Centre circle, Diagonal), big PLAY, SOLO / ONLINE, SHOP / HOW TO PLAY /
## AIM-ASSIST row, ad-ladder strip, daily bonus + free coins, level bar,
## version, and a banner-ad slot at the very bottom.

signal play_solo(difficulty: int)
signal play_online(stake: int)
signal open_mode_choice
signal open_shop
signal open_howto
signal open_aim_assist
signal watch_ad_coins
signal watch_ad_daily

var _coins_label: Label
var _level_label: Label
var _xp_bar: ProgressBar
var _daily_button: Button
var _sound_button: Button
var _assist_button: Button
var _free_coins_button: Button
var _out_box: PanelContainer
var _ladder_box: VBoxContainer

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
	root.add_theme_constant_override("separation", 8)
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
	# ---- OUT OF COINS banner (only at zero — points at the ad ladder) ----
	_out_box = PanelContainer.new()
	_out_box.add_theme_stylebox_override("panel", UiKit.panel_style(Color(0.25, 0.08, 0.08, 0.97), Color(0.95, 0.35, 0.25), 16, 2))
	root.add_child(_out_box)
	var out_v := VBoxContainer.new()
	out_v.add_theme_constant_override("separation", 4)
	_out_box.add_child(out_v)
	var out_title := UiKit.body_label("OUT OF COINS!", 24)
	out_title.add_theme_color_override("font_color", Color(1.0, 0.55, 0.45))
	out_title.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	out_v.add_child(out_title)
	var out_body := UiKit.body_label("Watch an ad to earn coins and play again.", 18)
	out_body.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	out_v.add_child(out_body)
	var out_ad := UiKit.gold_button("WATCH AD — EARN COINS", 22)
	out_ad.pressed.connect(func() -> void: watch_ad_coins.emit())
	out_v.add_child(out_ad)
	# ---- Hero: large labelled board ----
	var hero := VBoxContainer.new()
	hero.add_theme_constant_override("separation", 0)
	# The hero takes the leftover height so the board centres in the
	# slack on tall screens (720x1640) instead of leaving empty space
	# below the banner slot.
	hero.size_flags_vertical = Control.SIZE_EXPAND_FILL
	root.add_child(hero)
	var sub := UiKit.muted_label("Real carrom • Online & offline • Fewer ads", 18)
	hero.add_child(sub)
	var divider := ColorRect.new()
	divider.color = Color(0.83, 0.69, 0.22, 0.55)
	divider.custom_minimum_size = Vector2(0, 3)
	divider.mouse_filter = Control.MOUSE_FILTER_IGNORE
	hero.add_child(divider)
	# Board size adapts to the real viewport height so the screen fills
	# at both 720x1280 and 720x1640: up to 680 px wide (full width).
	var vp := get_viewport_rect().size
	var chrome := 740.0 + (72.0 if Save.coins == 0 else 0.0)
	var board_px := clampf(minf(vp.x - 40.0, vp.y - chrome), 360.0, 680.0)
	var s := board_px / 680.0
	var center := CenterContainer.new()
	center.size_flags_vertical = Control.SIZE_EXPAND_FILL
	center.mouse_filter = Control.MOUSE_FILTER_IGNORE
	hero.add_child(center)
	var board_holder := Control.new()
	board_holder.custom_minimum_size = Vector2(board_px, board_px)
	board_holder.mouse_filter = Control.MOUSE_FILTER_IGNORE
	center.add_child(board_holder)
	var mini := BoardView.new()
	mini.board_id = Save.equipped_board
	mini.striker_id = Save.equipped_striker
	mini.draw_backdrop = false
	mini.show_labels = true
	mini.pieces = _diagram_pieces()
	mini.position = Vector2(-20, -250) * s
	mini.scale = Vector2(s, s)
	board_holder.add_child(mini)
	# ---- Big PLAY ----
	var play := UiKit.gold_button("▶  PLAY", 40)
	play.custom_minimum_size = Vector2(0, 76)
	# v3: PLAY opens the full-screen mode-choice screen (Main handles it).
	# The v2 popup's SOLO/ONLINE buttons were dead on Buddhika's phone
	# (only the X worked); this screen uses the home screen's own plain
	# button layout, which works on his phone. No popup overlay here.
	play.pressed.connect(func() -> void: open_mode_choice.emit())
	root.add_child(play)
	# ---- SOLO / ONLINE ----
	var modes := HBoxContainer.new()
	modes.add_theme_constant_override("separation", 12)
	root.add_child(modes)
	var solo := UiKit.dark_button("SOLO\nvs AI — offline", 24)
	solo.custom_minimum_size = Vector2(0, 84)
	solo.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	solo.pressed.connect(_on_solo_pressed)
	modes.add_child(solo)
	var online := UiKit.dark_button("ONLINE\nvs real players", 24)
	online.custom_minimum_size = Vector2(0, 84)
	online.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	online.pressed.connect(_on_online_pressed)
	modes.add_child(online)
	# ---- Row of 3 ----
	var row := HBoxContainer.new()
	row.add_theme_constant_override("separation", 12)
	root.add_child(row)
	var shop := UiKit.dark_button("SHOP", 22)
	shop.custom_minimum_size = Vector2(0, 56)
	shop.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	shop.pressed.connect(func() -> void: open_shop.emit())
	row.add_child(shop)
	var howto := UiKit.dark_button("HOW TO PLAY", 22)
	howto.custom_minimum_size = Vector2(0, 56)
	howto.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	howto.pressed.connect(func() -> void: open_howto.emit())
	row.add_child(howto)
	_assist_button = UiKit.dark_button("AIM-ASSIST", 22)
	_assist_button.custom_minimum_size = Vector2(0, 56)
	_assist_button.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	_assist_button.pressed.connect(func() -> void: open_aim_assist.emit())
	row.add_child(_assist_button)
	# ---- Ad-ladder strip (visible tiers, current one highlighted) ----
	var ladder_panel := PanelContainer.new()
	ladder_panel.add_theme_stylebox_override("panel", UiKit.panel_style(Color(0.08, 0.09, 0.12, 0.97), Color(0.83, 0.69, 0.22, 0.35), 14, 1))
	root.add_child(ladder_panel)
	_ladder_box = VBoxContainer.new()
	_ladder_box.add_theme_constant_override("separation", 6)
	ladder_panel.add_child(_ladder_box)
	# ---- Daily + free coins ----
	_daily_button = UiKit.gold_button("DAILY BONUS", 22)
	_daily_button.custom_minimum_size = Vector2(0, 52)
	_daily_button.pressed.connect(func() -> void: watch_ad_daily.emit())
	root.add_child(_daily_button)
	_free_coins_button = UiKit.dark_button("FREE COINS", 20)
	_free_coins_button.custom_minimum_size = Vector2(0, 52)
	_free_coins_button.pressed.connect(func() -> void: watch_ad_coins.emit())
	root.add_child(_free_coins_button)
	# ---- Level bar + version ----
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
	root.add_child(_xp_bar)
	var ver := UiKit.muted_label("BMS Carrom v5.0  •  Free to play  •  No account needed", 15)
	root.add_child(ver)
	# ---- Banner-ad slot (bottom; the native banner covers it on Android) ----
	var banner_slot := PanelContainer.new()
	banner_slot.add_theme_stylebox_override("panel", UiKit.panel_style(Color(0.05, 0.05, 0.07, 0.97), Color(0.62, 0.60, 0.55, 0.4), 10, 1))
	banner_slot.custom_minimum_size = Vector2(0, 96)
	banner_slot.mouse_filter = Control.MOUSE_FILTER_IGNORE
	root.add_child(banner_slot)
	var banner_v := VBoxContainer.new()
	banner_v.add_theme_constant_override("separation", 0)
	banner_slot.add_child(banner_v)
	var ad_tag := UiKit.muted_label("AD", 14)
	banner_v.add_child(ad_tag)
	var ad_sub := UiKit.muted_label("Sponsored", 15)
	banner_v.add_child(ad_sub)
	refresh()

## The home diagram pieces: a sparse set so every label points cleanly —
## queen at the centre, one white coin, one black coin, striker on the
## bottom baseline (NOT the standard cluster, which would hide the labels).
func _diagram_pieces() -> Array:
	var pieces: Array = []
	pieces.append(CarromPhysics.make_piece("queen", CarromPhysics.BOARD_CENTER))
	pieces.append(CarromPhysics.make_piece("white", Vector2(240, 450)))
	pieces.append(CarromPhysics.make_piece("black", Vector2(480, 720)))
	pieces.append(CarromPhysics.make_piece("striker", Vector2(CarromPhysics.BOARD_CENTER.x, CarromPhysics.baseline_y(0))))
	return pieces

func refresh() -> void:
	_coins_label.text = "◉ %s" % _fmt(Save.coins)
	_level_label.text = "Lv %d · %s" % [Save.level(), Save.rank_name()]
	_xp_bar.value = Save.xp_into_level()
	_xp_bar.max_value = Save.XP_PER_LEVEL
	_sound_button.text = "♪" if Save.sound_on else "∅"
	_out_box.visible = Save.coins == 0
	if Save.can_claim_daily():
		_daily_button.visible = true
		_daily_button.text = "DAILY BONUS +%d — WATCH AD TO CLAIM" % Save.daily_bonus_amount()
	else:
		_daily_button.visible = false
	if Save.ad_cap_reached():
		_free_coins_button.text = "AD LIMIT REACHED — COME BACK TOMORROW"
		_free_coins_button.disabled = true
	else:
		_free_coins_button.text = "FREE COINS +%d  (watch a short ad)" % Save.ad_next_reward()
		_free_coins_button.disabled = false
	if Save.aim_assist_active():
		var left := Save.aim_assist_remaining_sec()
		_assist_button.text = "AIM-ASSIST %02d:%02d" % [left / 60, left % 60]
	else:
		_assist_button.text = "AIM-ASSIST"
	_build_ladder()

## Rebuilds the ad-ladder strip: five tier chips (1st +150 … 5th+ +400),
## done tiers dimmed with a tick, the CURRENT tier gold, future tiers dark.
func _build_ladder() -> void:
	for c in _ladder_box.get_children():
		c.queue_free()
	var head := HBoxContainer.new()
	_ladder_box.add_child(head)
	var title := Label.new()
	title.text = "AD LADDER — more ads, more coins"
	title.add_theme_font_size_override("font_size", 17)
	title.add_theme_color_override("font_color", UiKit.GOLD_LIGHT)
	title.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	head.add_child(title)
	var today := Label.new()
	today.text = "Today ◉ %d / %d" % [Save.ad_coins_today, Save.DAILY_AD_COIN_CAP]
	today.add_theme_font_size_override("font_size", 16)
	today.add_theme_color_override("font_color", UiKit.MUTED)
	head.add_child(today)
	var chips := HBoxContainer.new()
	chips.add_theme_constant_override("separation", 8)
	_ladder_box.add_child(chips)
	var tier_names := ["1st", "2nd", "3rd", "4th", "5+"]
	var current := Save.ad_current_tier()
	var capped := Save.ad_cap_reached()
	for i in range(5):
		var chip := PanelContainer.new()
		var style := StyleBoxFlat.new()
		style.set_corner_radius_all(10)
		style.content_margin_left = 6
		style.content_margin_right = 6
		style.content_margin_top = 6
		style.content_margin_bottom = 6
		var label := Label.new()
		label.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
		label.add_theme_font_size_override("font_size", 16)
		if capped or i + 1 < current:
			# Done: dimmed, ticked.
			style.bg_color = Color(0.10, 0.11, 0.13)
			style.border_color = Color(0.83, 0.69, 0.22, 0.25)
			style.set_border_width_all(1)
			label.text = "✓ %s +%d" % [tier_names[i], Save.AD_LADDER[i]]
			label.add_theme_color_override("font_color", UiKit.MUTED)
		elif i + 1 == current:
			# Current tier: gold, unmissable.
			style.bg_color = UiKit.GOLD
			style.border_color = UiKit.GOLD_LIGHT
			style.set_border_width_all(2)
			label.text = "%s +%d" % [tier_names[i], Save.AD_LADDER[i]]
			label.add_theme_color_override("font_color", UiKit.DARK_TEXT)
		else:
			style.bg_color = Color(0.16, 0.17, 0.20)
			style.border_color = UiKit.GOLD
			style.set_border_width_all(1)
			label.text = "%s +%d" % [tier_names[i], Save.AD_LADDER[i]]
			label.add_theme_color_override("font_color", UiKit.GOLD_LIGHT)
		chip.add_theme_stylebox_override("panel", style)
		chip.size_flags_horizontal = Control.SIZE_EXPAND_FILL
		chip.add_child(label)
		chips.add_child(chip)

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

func _on_solo_pressed() -> void:
	var pop: Dictionary = UiKit.popup_window("SOLO — vs AI (offline)", Vector2(560, 460))
	add_child(pop["dim"])
	var box: VBoxContainer = pop["box"]
	box.add_child(UiKit.body_label("No internet needed. Free practice — no coins earned. Win coins in online matches or from ads.", 20))
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
	var pop := UiKit.stake_picker(Save.coins, func(stake: int) -> void: play_online.emit(stake))
	add_child(pop["dim"])
