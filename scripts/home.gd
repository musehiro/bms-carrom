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
# v7 invites: the invite box lives on this screen; Main owns the stake
# picker + the game-server join, so these signals hand the choice over.
signal invite_accept_chosen(invite: Dictionary)
signal invite_send_chosen(player: Dictionary)
signal group_invite_send_chosen(players: Array)

var _coins_label: Label
var _level_label: Label
var _xp_bar: ProgressBar
var _daily_button: Button
var _sound_button: Button
var _invite_button: Button
var _assist_button: Button
var _free_coins_button: Button
var _out_box: PanelContainer
var _verify_box: PanelContainer
var _ladder_box: VBoxContainer
# v7 invite box (side panel) + friend search state.
var _invite_dim: ColorRect = null
var _invite_panel: PanelContainer = null
var _invite_content: VBoxContainer = null
var _invite_body: VBoxContainer = null
var _search_edit: LineEdit = null
var _search_results: Array = []
var _selected_4p: Dictionary = {} # player id -> {id, name, level}

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
	# v7: invite box — ✉ in the top bar, with the pending-invite count
	# in the label (e.g. "✉ 2"). Tapping opens the side panel.
	_invite_button = UiKit.dark_button("✉", 24)
	_invite_button.custom_minimum_size = Vector2(52, 52)
	_invite_button.pressed.connect(_toggle_invite_box)
	top.add_child(_invite_button)
	Friends.invites_changed.connect(_on_invites_changed)
	# ---- Verify-Gmail banner (v7, only until the Gmail is proven) ----
	# An unverified account has no cloud profile yet — if the player
	# deletes the app now, there is nothing to restore. The banner
	# stays until verification so the protection is not forgotten.
	_verify_box = PanelContainer.new()
	_verify_box.add_theme_stylebox_override("panel", UiKit.panel_style(Color(0.25, 0.18, 0.05, 0.97), UiKit.GOLD, 14, 2))
	root.add_child(_verify_box)
	var ver_v := VBoxContainer.new()
	ver_v.add_theme_constant_override("separation", 4)
	_verify_box.add_child(ver_v)
	var ver_title := UiKit.body_label("VERIFY YOUR GMAIL", 22)
	ver_title.add_theme_color_override("font_color", UiKit.GOLD_LIGHT)
	ver_title.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	ver_v.add_child(ver_title)
	var ver_body := UiKit.body_label("Your coins and level are only saved on this phone until your Gmail is verified — verify now so they come back if you reinstall.", 17)
	ver_body.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	ver_v.add_child(ver_body)
	var ver_btn := UiKit.gold_button("VERIFY GMAIL", 22)
	ver_btn.pressed.connect(_open_verify_popup)
	ver_v.add_child(ver_btn)
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
	var ver := UiKit.muted_label("BMS Carrom v7.0  •  Account required  •  Free to play", 15)
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
	var pending := Friends.pending_count()
	_invite_button.text = "✉ %d" % pending if pending > 0 else "✉"
	_verify_box.visible = Supabase.configured and Accounts.has_account() and not Accounts.is_verified()
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
	if _invite_panel != null:
		_refresh_invite_box()

func _on_invites_changed() -> void:
	refresh()

## Verify-Gmail popup (v7): sends a fresh code to the account Gmail,
## the player enters it, and the cloud profile is created from the
## local save (verify_code_and_login with allow_create=true).
func _open_verify_popup() -> void:
	var pop: Dictionary = UiKit.popup_window("VERIFY YOUR GMAIL", Vector2(560, 520))
	add_child(pop["dim"])
	var box: VBoxContainer = pop["box"]
	box.add_child(UiKit.body_label("We will send a 6-digit code to %s. Enter it below — your coins, level and shop items are then saved to your account." % Save.account_gmail, 20))
	var code_edit := LineEdit.new()
	code_edit.placeholder_text = "6-digit code"
	code_edit.max_length = 6
	code_edit.add_theme_font_size_override("font_size", 26)
	code_edit.custom_minimum_size = Vector2(0, 60)
	box.add_child(code_edit)
	var err := Label.new()
	err.add_theme_font_size_override("font_size", 18)
	err.add_theme_color_override("font_color", UiKit.RED)
	err.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	box.add_child(err)
	var send := UiKit.dark_button("SEND CODE", 22)
	send.pressed.connect(func() -> void:
		var res := await Accounts.request_login_code(Save.account_gmail)
		if not bool(res.get("ok", false)):
			err.text = String(res.get("error", "Could not send the code."))
		else:
			err.text = ""
			code_edit.grab_focus())
	box.add_child(send)
	var verify := UiKit.gold_button("VERIFY", 24)
	verify.pressed.connect(func() -> void:
		var res := await Accounts.verify_code_and_login(Save.account_gmail, code_edit.text, true)
		if not bool(res.get("ok", false)):
			err.text = String(res.get("error", "Wrong code — try again."))
			return
		pop["dim"].queue_free()
		refresh())
	box.add_child(verify)
	pop["close"].pressed.connect(func() -> void: pop["dim"].queue_free())

# ------------------------------------------------------- invite box (v7)
# A side panel on the right of the home screen: incoming invites
# (Accept / Decline), sent invites (waiting), and FRIENDS — search by
# display name, invite one friend (2 players) or pick up to 3 friends
# for a 4-player doubles invite. The panel rebuilds whenever the
# invite state changes (Realtime / poll) while it is open.

func _toggle_invite_box() -> void:
	if _invite_panel != null:
		_invite_dim.queue_free()
		_invite_panel.queue_free()
		_invite_dim = null
		_invite_panel = null
		_invite_content = null
		_invite_body = null
		_search_edit = null
		return
	_invite_dim = ColorRect.new()
	_invite_dim.color = Color(0, 0, 0, 0.55)
	_invite_dim.mouse_filter = Control.MOUSE_FILTER_STOP
	UiKit.full_rect(_invite_dim)
	_invite_dim.gui_input.connect(func(event: InputEvent) -> void:
		if event is InputEventMouseButton and (event as InputEventMouseButton).pressed:
			_toggle_invite_box())
	add_child(_invite_dim)
	_invite_panel = PanelContainer.new()
	_invite_panel.add_theme_stylebox_override("panel", UiKit.panel_style(Color(0.10, 0.10, 0.13, 1.0), UiKit.GOLD, 18, 2))
	_invite_panel.anchor_left = 1.0
	_invite_panel.anchor_top = 0.0
	_invite_panel.anchor_right = 1.0
	_invite_panel.anchor_bottom = 1.0
	_invite_panel.offset_left = -580.0
	_invite_panel.offset_top = 0.0
	_invite_panel.offset_right = 0.0
	_invite_panel.offset_bottom = 0.0
	add_child(_invite_panel)
	_invite_content = VBoxContainer.new()
	_invite_content.add_theme_constant_override("separation", 10)
	_invite_panel.add_child(_invite_content)
	var scroll := ScrollContainer.new()
	scroll.size_flags_vertical = Control.SIZE_EXPAND_FILL
	# No horizontal scrolling: the body must fit the panel width so
	# labels wrap and buttons stay on screen (a ScrollContainer child
	# otherwise grows to its widest content and everything overflows).
	scroll.horizontal_scroll_mode = ScrollContainer.SCROLL_MODE_DISABLED
	_invite_content.add_child(scroll)
	# The scrollable body is rebuilt by _refresh_invite_box; keep a
	# stable reference to it.
	_invite_body = VBoxContainer.new()
	_invite_body.add_theme_constant_override("separation", 10)
	scroll.add_child(_invite_body)
	_refresh_invite_box()

func _refresh_invite_box() -> void:
	if _invite_panel == null or _invite_body == null:
		return
	var body: VBoxContainer = _invite_body
	for c in body.get_children():
		c.queue_free()
	var top := HBoxContainer.new()
	body.add_child(top)
	var title := UiKit.title_label("✉  INVITE BOX", 28)
	title.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	title.horizontal_alignment = HORIZONTAL_ALIGNMENT_LEFT
	top.add_child(title)
	var x := UiKit.red_x_button()
	x.pressed.connect(_toggle_invite_box)
	top.add_child(x)
	if not Supabase.configured:
		# The backend is not set up yet (v7 ships with an empty
		# backend_config.json until the Supabase project exists). Say
		# so at the top — but still render any invites below, so the
		# box stays truthful and testable.
		body.add_child(UiKit.body_label("Invites are not connected yet — the account server is still being set up. Play NEARBY together on the same Wi-Fi for now.", 18))
	# ---- Incoming invites ----
	var incoming: Array = []
	for inv in Friends.incoming:
		if not Friends.is_expired(inv):
			incoming.append(inv)
	if incoming.is_empty():
		body.add_child(UiKit.muted_label("No invites yet — search for a friend below and send one!", 17))
	else:
		for inv in incoming:
			var card := PanelContainer.new()
			card.add_theme_stylebox_override("panel", UiKit.panel_style(Color(0.16, 0.17, 0.20), UiKit.GOLD, 12, 1))
			body.add_child(card)
			var vb := VBoxContainer.new()
			vb.add_theme_constant_override("separation", 6)
			card.add_child(vb)
			var mode_text := "4 players — doubles" if String(inv.get("mode", "2p")) == "4p" else "2 players — 1 vs 1"
			vb.add_child(UiKit.body_label("%s invited you — %s, stake ◉ %d" % [String(inv.get("from_name", "A player")), mode_text, int(inv.get("stake", 0))], 20))
			var row := HBoxContainer.new()
			row.add_theme_constant_override("separation", 10)
			vb.add_child(row)
			var accept := UiKit.gold_button("ACCEPT", 22)
			accept.size_flags_horizontal = Control.SIZE_EXPAND_FILL
			var inv_copy: Dictionary = inv
			accept.pressed.connect(func() -> void:
				_toggle_invite_box()
				invite_accept_chosen.emit(inv_copy))
			row.add_child(accept)
			var decline := UiKit.dark_button("DECLINE", 22)
			decline.size_flags_horizontal = Control.SIZE_EXPAND_FILL
			decline.pressed.connect(func() -> void:
				var res := await Friends.decline_invite(inv_copy)
				if not bool(res.get("ok", false)):
					refresh())
			row.add_child(decline)
	# ---- Sent invites (waiting) ----
	if not Friends.outgoing.is_empty():
		body.add_child(UiKit.muted_label("WAITING FOR…", 17))
		for inv in Friends.outgoing:
			var st := String(inv.get("status", "pending"))
			if st == "pending":
				body.add_child(UiKit.body_label("• %s — %s" % [String(inv.get("to_name", "a player")), "4 players" if String(inv.get("mode", "2p")) == "4p" else "2 players"], 18))
	# ---- Friends: search + invite ----
	body.add_child(UiKit.title_label("FRIENDS", 24))
	body.add_child(UiKit.muted_label("Search by display name — never by Gmail.", 16))
	var srow := HBoxContainer.new()
	srow.add_theme_constant_override("separation", 10)
	body.add_child(srow)
	_search_edit = LineEdit.new()
	_search_edit.placeholder_text = "Friend's name…"
	_search_edit.add_theme_font_size_override("font_size", 22)
	_search_edit.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	_search_edit.custom_minimum_size = Vector2(0, 56)
	srow.add_child(_search_edit)
	var search_btn := UiKit.dark_button("SEARCH", 22)
	search_btn.custom_minimum_size = Vector2(130, 56)
	search_btn.pressed.connect(_on_search_pressed)
	srow.add_child(search_btn)
	for player in _search_results:
		var pcard := PanelContainer.new()
		pcard.add_theme_stylebox_override("panel", UiKit.panel_style(Color(0.16, 0.17, 0.20), Color(0.83, 0.69, 0.22, 0.35), 12, 1))
		body.add_child(pcard)
		var prow := HBoxContainer.new()
		prow.add_theme_constant_override("separation", 10)
		pcard.add_child(prow)
		var plabel := UiKit.body_label("%s  •  Lv %d" % [String(player.get("display_name", "?")), int(player.get("level", 1))], 20)
		plabel.size_flags_horizontal = Control.SIZE_EXPAND_FILL
		prow.add_child(plabel)
		var pid := String(player.get("id", ""))
		var selected := _selected_4p.has(pid)
		var sel_btn := UiKit.dark_button("4P ✓" if selected else "4P", 18)
		sel_btn.custom_minimum_size = Vector2(76, 0)
		sel_btn.pressed.connect(func() -> void:
			if _selected_4p.has(pid):
				_selected_4p.erase(pid)
			elif _selected_4p.size() < Friends.MAX_GROUP_TARGETS:
				_selected_4p[pid] = player
			_refresh_invite_box())
		prow.add_child(sel_btn)
		var inv_btn := UiKit.gold_button("INVITE", 20)
		inv_btn.pressed.connect(func() -> void:
			_toggle_invite_box()
			invite_send_chosen.emit(player))
		prow.add_child(inv_btn)
	if not _selected_4p.is_empty():
		var send4 := UiKit.gold_button("SEND 4-PLAYER INVITE (%d)" % _selected_4p.size(), 20)
		send4.pressed.connect(func() -> void:
			var picked: Array = []
			for p in _selected_4p.values():
				picked.append(p)
			_selected_4p.clear()
			_toggle_invite_box()
			group_invite_send_chosen.emit(picked))
		body.add_child(send4)
		var picked_names: Array = []
		for p in _selected_4p.values():
			picked_names.append(String(p.get("display_name", "?")))
		# body_label (autowrap) — a muted_label has no autowrap, so a
		# long note would widen the whole scroll body past the panel.
		body.add_child(UiKit.body_label("To: %s. Tap 4P on 1–3 friends, then send — the match starts when all accept. You are the fourth player." % ", ".join(picked_names), 16))

func _on_search_pressed() -> void:
	if _search_edit == null:
		return
	var res := await Friends.search(_search_edit.text)
	if not bool(res.get("ok", false)):
		_search_results = []
		_refresh_invite_box()
		return
	_search_results = res.get("results", [])
	_refresh_invite_box()

# ------------------------------------------------------- invite box (v7)
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
