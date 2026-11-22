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
const PANEL := Color(0.08, 0.09, 0.12, 0.97)
const PANEL_BORDER := Color(0.83, 0.69, 0.22, 0.55)
const TEXT := Color(0.96, 0.95, 0.92)
const MUTED := Color(0.62, 0.60, 0.55)
const DARK_TEXT := Color(0.10, 0.08, 0.05)
const RED := Color(0.80, 0.15, 0.18)

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

static func gold_button(text: String, font_size: int = 30) -> Button:
	var b := Button.new()
	b.text = text
	b.add_theme_font_size_override("font_size", font_size)
	b.add_theme_color_override("font_color", DARK_TEXT)
	b.add_theme_color_override("font_hover_color", DARK_TEXT)
	b.add_theme_color_override("font_pressed_color", DARK_TEXT)
	var normal := StyleBoxFlat.new()
	normal.bg_color = GOLD
	normal.set_corner_radius_all(14)
	normal.content_margin_top = 12
	normal.content_margin_bottom = 12
	var hover := normal.duplicate()
	hover.bg_color = GOLD_LIGHT
	var pressed := normal.duplicate()
	pressed.bg_color = Color(0.70, 0.56, 0.16)
	b.add_theme_stylebox_override("normal", normal)
	b.add_theme_stylebox_override("hover", hover)
	b.add_theme_stylebox_override("pressed", pressed)
	b.add_theme_stylebox_override("focus", StyleBoxEmpty.new())
	return b

static func dark_button(text: String, font_size: int = 26) -> Button:
	var b := Button.new()
	b.text = text
	b.add_theme_font_size_override("font_size", font_size)
	b.add_theme_color_override("font_color", GOLD_LIGHT)
	b.add_theme_color_override("font_hover_color", GOLD_LIGHT)
	var normal := StyleBoxFlat.new()
	normal.bg_color = Color(0.16, 0.17, 0.20)
	normal.border_color = GOLD
	normal.set_border_width_all(2)
	normal.set_corner_radius_all(14)
	normal.content_margin_top = 10
	normal.content_margin_bottom = 10
	var hover := normal.duplicate()
	hover.bg_color = Color(0.22, 0.23, 0.27)
	b.add_theme_stylebox_override("normal", normal)
	b.add_theme_stylebox_override("hover", hover)
	b.add_theme_stylebox_override("pressed", hover)
	b.add_theme_stylebox_override("focus", StyleBoxEmpty.new())
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
	win.add_theme_stylebox_override("panel", panel_style(Color(0.10, 0.10, 0.13, 1.0), GOLD, 18, 2))
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
