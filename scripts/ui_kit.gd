class_name UiKit
extends RefCounted

## Shared gold-on-dark UI helpers (design doc 7).


## Fill the parent exactly, deterministically. (set_anchors_preset proved
## unreliable for runtime-created screens: it preserved the zero size.)
static func full_rect(c: Control) -> void:
	c.anchor_left = 0.0
	c.anchor_top = 0.0
	c.anchor_right = 1.0
	c.anchor_bottom = 1.0
	c.offset_left = 0.0
	c.offset_top = 0.0
	c.offset_right = 0.0
	c.offset_bottom = 0.0

const GOLD := Color(0.83, 0.69, 0.22)
const GOLD_LIGHT := Color(0.91, 0.78, 0.40)
## v10: bright vivid-teal panels (was near-black 0.08,0.09,0.12) — the
## whole game interior is brighter now; white text stays readable.
const PANEL := Color(0.06, 0.34, 0.36, 0.97)
const PANEL_BORDER := Color(0.83, 0.69, 0.22, 0.55)
const TEXT := Color(0.96, 0.95, 0.92)
const MUTED := Color(0.80, 0.86, 0.84)
const DARK_TEXT := Color(0.10, 0.08, 0.05)
const RED := Color(0.80, 0.15, 0.18)

## Chunky-3D tile colour pairs (Nana's LingoLand recipe, 2026-11-23 —
## theme.css .game-tiles, two-tone diagonal gradient light -> dark).
## The lip is a darker shade of the dark colour (ThreeDButton.lip_for),
## except BLUE, whose lip is Nana's exact #1558AC.
const TILE_ALPHABET := {"top": Color(0.690, 0.431, 0.910), "bottom": Color(0.478, 0.357, 0.816)} # #B06EE8 -> #7A5BD0
const TILE_PHONICS := {"top": Color(0.494, 0.827, 0.129), "bottom": Color(0.275, 0.639, 0.008)} # #7ED321 -> #46A302
const TILE_SPELLING := {"top": Color(0.098, 0.760, 0.941), "bottom": Color(0.118, 0.435, 0.851)} # #19C2F0 -> #1E6FD9
const TILE_QUIZ := {"top": Color(1.0, 0.717, 0.012), "bottom": Color(1.0, 0.482, 0.329)} # #FFB703 -> #FF7B54
const TILE_BALLOON := {"top": Color(1.0, 0.419, 0.419), "bottom": Color(1.0, 0.180, 0.619)} # #FF6B6B -> #FF2E9E
const TILE_BLUE := {"top": Color(0.219, 0.713, 1.0), "bottom": Color(0.118, 0.435, 0.851), "lip": Color(0.082, 0.345, 0.674)} # #38B6FF -> #1E6FD9, lip #1558AC
const TILE_GOLD := {"top": Color(1.0, 0.851, 0.408), "bottom": Color(0.914, 0.663, 0.110)} # Carrom gold #FFD968 -> #E9A91C
## Premium-redesign tiles (reference home / welcome screens).
const TILE_RED := {"top": Color(0.91, 0.27, 0.18), "bottom": Color(0.72, 0.12, 0.07), "lip": Color(0.49, 0.07, 0.04)} # #E8452E -> #B81E12
const TILE_GREEN := {"top": Color(0.21, 0.78, 0.35), "bottom": Color(0.12, 0.62, 0.27), "lip": Color(0.07, 0.42, 0.16)} # #36C759 -> #1F9E45
const TILE_CREAM := {"top": Color(1.0, 0.96, 0.86), "bottom": Color(0.94, 0.85, 0.63), "lip": Color(0.79, 0.66, 0.42)} # #FFF5DB -> #F0D9A1
const TILE_PURPLE := {"top": Color(0.55, 0.36, 0.96), "bottom": Color(0.43, 0.16, 0.85), "lip": Color(0.29, 0.09, 0.60)} # #8C5CF5 -> #6E29D9

static func panel_style(bg: Color = PANEL, border: Color = PANEL_BORDER, radius: int = 16, border_w: int = 2) -> StyleBoxFlat:
	var s := StyleBoxFlat.new()
	s.bg_color = bg
	s.border_color = border
	s.set_border_width_all(border_w)
	s.set_corner_radius_all(radius)
	s.content_margin_left = 16
	s.content_margin_right = 16
	s.content_margin_top = 10
	s.content_margin_bottom = 10
	return s

## Primary action button — chunky 3D gold (v10, Nana's recipe).
## Gold keeps DARK text: white on bright gold reads badly, and dark
## text on gold is the established Carrom look. Returns a ThreeDButton
## (still a Button — .text / .pressed / .disabled all work as before).
static func gold_button(text: String, font_size: int = 30) -> Button:
	var b := ThreeDButton.new()
	b.text = text
	b.add_theme_font_size_override("font_size", font_size)
	b.set_colors(TILE_GOLD["top"], TILE_GOLD["bottom"], ThreeDButton.lip_for(TILE_GOLD["bottom"]), DARK_TEXT)
	b.pill = true
	return b

## Secondary button — chunky 3D round blue (v10, Nana's exact recipe:
## #38B6FF -> #1E6FD9, 5 px lip #1558AC), white label.
static func dark_button(text: String, font_size: int = 26) -> Button:
	var b := ThreeDButton.new()
	b.text = text
	b.add_theme_font_size_override("font_size", font_size)
	b.set_colors(TILE_BLUE["top"], TILE_BLUE["bottom"], TILE_BLUE["lip"], Color.WHITE)
	b.pill = true
	return b

## A chunky 3D TILE (v10, Nana's .game-tiles): big rounded corners
## (24 px, not a pill), white label, gradient `pair` = {"top", "bottom"}
## (one of the TILE_* constants; the lip is a darker shade of "bottom").
## Use for the big mode tiles and the win-screen offers.
static func tile_button(text: String, font_size: int, pair: Dictionary) -> Button:
	var b := ThreeDButton.new()
	b.text = text
	b.add_theme_font_size_override("font_size", font_size)
	var lip: Color = pair.get("lip", ThreeDButton.lip_for(pair["bottom"]))
	b.set_colors(pair["top"], pair["bottom"], lip, Color.WHITE)
	b.pill = false
	b.corner_radius = 24.0
	return b

## Big red pill — the PLAY button (reference home screen).
static func red_button(text: String, font_size: int = 30) -> Button:
	var b := ThreeDButton.new()
	b.text = text
	b.add_theme_font_size_override("font_size", font_size)
	b.set_colors(TILE_RED["top"], TILE_RED["bottom"], TILE_RED["lip"], Color.WHITE)
	b.pill = true
	return b

## Big green pill — REGISTER & PLAY (reference welcome screen).
static func green_button(text: String, font_size: int = 30) -> Button:
	var b := ThreeDButton.new()
	b.text = text
	b.add_theme_font_size_override("font_size", font_size)
	b.set_colors(TILE_GREEN["top"], TILE_GREEN["bottom"], TILE_GREEN["lip"], Color.WHITE)
	b.pill = true
	return b

## Cream tile — dark text on cream (reference menu tiles: SOLO,
## ONLINE, SHOP, HOW TO PLAY, AIM-ASSIST, LEADERBOARD, ACHIEVEMENTS).
static func cream_tile(text: String, font_size: int = 22) -> Button:
	var b := ThreeDButton.new()
	b.text = text
	b.add_theme_font_size_override("font_size", font_size)
	b.set_colors(TILE_CREAM["top"], TILE_CREAM["bottom"], TILE_CREAM["lip"], DARK_TEXT)
	b.pill = false
	b.corner_radius = 24.0
	return b

## Purple tile — FREE COINS (reference home screen).
static func purple_tile(text: String, font_size: int = 20) -> Button:
	var b := ThreeDButton.new()
	b.text = text
	b.add_theme_font_size_override("font_size", font_size)
	b.set_colors(TILE_PURPLE["top"], TILE_PURPLE["bottom"], TILE_PURPLE["lip"], Color.WHITE)
	b.pill = false
	b.corner_radius = 24.0
	return b

static func title_label(text: String, font_size: int = 40) -> Label:
	var l := Label.new()
	l.text = text
	l.add_theme_font_size_override("font_size", font_size)
	l.add_theme_color_override("font_color", GOLD_LIGHT)
	l.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	return l

static func body_label(text: String, font_size: int = 22) -> Label:
	var l := Label.new()
	l.text = text
	l.add_theme_font_size_override("font_size", font_size)
	l.add_theme_color_override("font_color", TEXT)
	l.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	return l

static func muted_label(text: String, font_size: int = 18) -> Label:
	var l := Label.new()
	l.text = text
	l.add_theme_font_size_override("font_size", font_size)
	l.add_theme_color_override("font_color", MUTED)
	l.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	return l

static func red_x_button() -> Button:
	var b := Button.new()
	b.text = "✕"
	b.add_theme_font_size_override("font_size", 26)
	b.add_theme_color_override("font_color", Color.WHITE)
	var s := StyleBoxFlat.new()
	s.bg_color = RED
	s.set_corner_radius_all(10)
	s.content_margin_left = 12
	s.content_margin_right = 12
	s.content_margin_top = 4
	s.content_margin_bottom = 4
	b.add_theme_stylebox_override("normal", s)
	b.add_theme_stylebox_override("hover", s)
	b.add_theme_stylebox_override("pressed", s)
	b.add_theme_stylebox_override("focus", StyleBoxEmpty.new())
	return b

## Small square popup window with a red X, like Shadow Assassin's How to Play.
static func popup_window(title: String, size: Vector2) -> Dictionary:
	var dim := ColorRect.new()
	dim.color = Color(0, 0, 0, 0.6)
	UiKit.full_rect(dim)
	var win := PanelContainer.new()
	win.add_theme_stylebox_override("panel", panel_style(PANEL, GOLD, 18, 2))
	win.custom_minimum_size = size
	# Centre explicitly: PRESET_CENTER reads the (still zero) size, so set
	# the 0.5 anchors + half-size offsets by hand.
	win.anchor_left = 0.5
	win.anchor_top = 0.5
	win.anchor_right = 0.5
	win.anchor_bottom = 0.5
	win.offset_left = -size.x / 2.0
	win.offset_top = -size.y / 2.0
	win.offset_right = size.x / 2.0
	win.offset_bottom = size.y / 2.0
	var vb := VBoxContainer.new()
	vb.add_theme_constant_override("separation", 10)
	win.add_child(vb)
	var top := HBoxContainer.new()
	var t := title_label(title, 28)
	t.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	t.horizontal_alignment = HORIZONTAL_ALIGNMENT_LEFT
	top.add_child(t)
	var x := red_x_button()
	top.add_child(x)
	vb.add_child(top)
	dim.add_child(win)
	return {"dim": dim, "win": win, "box": vb, "close": x}

## 2-or-4 player choice (2026-11-27, user request): after tapping an
## online player, the player FIRST chooses 2 or 4 players — the match is
## only set once the choice is confirmed. Tapping INVITE must never send
## a 2p invite straight away. Returns the popup_window dict plus "btn2"
## (2 PLAYERS — 1 VS 1) and "btn4" (4 PLAYERS — DOUBLES); the caller
## adds pop["dim"] to its own screen and wires the buttons + close.
static func choose_player_count(display_name: String) -> Dictionary:
	var pop: Dictionary = popup_window("HOW MANY PLAYERS?", Vector2(560, 400))
	var box: VBoxContainer = pop["box"]
	box.add_child(body_label("Invite %s — how many people play? The match is set only after you choose." % display_name, 20))
	var b2 := gold_button("2 PLAYERS — 1 VS 1", 24)
	b2.custom_minimum_size = Vector2(0, 72)
	box.add_child(b2)
	pop["btn2"] = b2
	var b4 := dark_button("4 PLAYERS — DOUBLES", 24)
	b4.custom_minimum_size = Vector2(0, 72)
	box.add_child(b4)
	pop["btn4"] = b4
	box.add_child(body_label("4 players: pick 2 more friends after this — you are the fourth player.", 16))
	return pop

## Stake picker popup (v5, virtual-coin staking): before an online match
## the player chooses ANY stake from 0 up to their balance — no fixed
## amount, no forced match of the opponent's stake. The confirm button
## validates with Stakes.valid_stake and calls on_confirm(stake) only on
## success (the popup is freed here); errors show in the popup itself.
## Quick amounts exist so the flow is one tap on a phone (and testable).
## `title` overrides the popup title (World Tour uses its own, v8).
## Returns {dim, box, close, stake_edit, error_label, confirm}.
static func stake_picker(balance: int, on_confirm: Callable, note: String = "", title: String = "ONLINE — CHOOSE YOUR STAKE") -> Dictionary:
	var pop: Dictionary = popup_window(title, Vector2(580, 580))
	var box: VBoxContainer = pop["box"]
	var intro := note if note != "" else "Real players worldwide, matched within ±2 levels. You choose your own stake — any amount up to your balance. Winner takes the pot (both stakes)."
	box.add_child(body_label(intro, 20))
	var bal := body_label("Your coins: ◉ %d" % balance, 22)
	box.add_child(bal)
	var edit := LineEdit.new()
	edit.name = "StakeEdit"
	edit.text = "0"
	edit.placeholder_text = "Enter your stake"
	edit.add_theme_font_size_override("font_size", 26)
	edit.custom_minimum_size = Vector2(0, 60)
	box.add_child(edit)
	var quick := HBoxContainer.new()
	quick.add_theme_constant_override("separation", 8)
	box.add_child(quick)
	for amount in ["0", "50", "100", "500", "ALL IN"]:
		var q := dark_button(amount, 22)
		q.size_flags_horizontal = Control.SIZE_EXPAND_FILL
		var val: String = amount
		q.pressed.connect(func() -> void:
			edit.text = str(balance) if val == "ALL IN" else val)
		quick.add_child(q)
	var err := Label.new()
	err.name = "StakeError"
	err.add_theme_font_size_override("font_size", 18)
	err.add_theme_color_override("font_color", RED)
	err.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	box.add_child(err)
	if balance == 0:
		box.add_child(UiKit.body_label("Out of coins — play a friendly 0-stake match, or watch an ad to earn coins to stake.", 17))
	else:
		box.add_child(muted_label("Stake 0 = friendly match, no coins won or lost.", 17))
	var confirm := gold_button("FIND OPPONENT", 26)
	box.add_child(confirm)
	confirm.pressed.connect(func() -> void:
		var raw := edit.text.strip_edges()
		if raw == "" or raw.length() > 9 or not raw.is_valid_int():
			err.text = "Enter a whole number of coins."
			return
		var stake := int(raw)
		if not Stakes.valid_stake(stake, balance):
			err.text = "Stake must be 0 to %d coins (your balance)." % balance
			return
		pop["dim"].queue_free()
		on_confirm.call(stake))
	pop["close"].pressed.connect(func() -> void: pop["dim"].queue_free())
	return {"dim": pop["dim"], "box": box, "close": pop["close"],
		"stake_edit": edit, "error_label": err, "confirm": confirm}
