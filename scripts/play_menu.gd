class_name PlayMenuScreen
extends Control

## Play menu — restyled 2026-11-28 to the reference Play screen:
## premium wooden background (the repo's own bg_home_wood.jpg, with
## green leaves + carrom coins at the edges), gold "BMS CARROM" crown
## logo on a red ribbon, gold PLAY title with arrows, and chunky
## 3D tiles: gold PLAY WITH A BOT, green 2 PLAYERS, green SAME 2
## PLAYER, red 4 PLAYERS, blue NEARBY / WORLD TOUR / SEARCH FRIEND,
## purple BACK. All icons are code-drawn (PlayIcon) — no image assets
## beyond the repo's own wood + crown, nothing copied from the
## reference image.
##
##   (1) PLAY WITH A BOT — solo vs the computer (free, offline).
##       Routes to the existing solo/BOT flow (Main._start_solo_direct).
##   (2) 2 PLAYERS — 1 VS 1 — tap and it AUTO-CONNECTS with one
##       online player: the existing random-matchmaking queue
##       (find_match, mode '2p') at the standard stake — no stake
##       picker, no invites. Main._start_auto_match owns the stake +
##       broke-player routing; this screen never touches net_client.gd.
##   (2b) SAME 2 PLAYER — same as (2) but same-level only:
##       Main._on_play_same_two_players -> start_matchmaking("2p",
##       false, true). Same green style, right below (2).
##   (3) 4 PLAYERS — DOUBLES — same, but find_match mode '4p':
##       auto-connects with three online players.
##
## PLAY WITH THE WORLD and PLAY WITH FRIENDS are GONE from this
## screen (user 2026-11-28) — replaced by the auto-connect buttons
## above. The Online Lobby and the invite code/screens are NOT
## deleted: they stay in the repo, reachable from the home ONLINE
## tile (stake picker -> lobby) and the home invite box.
##
## The player picks whichever they like. Full-screen layout, same
## plain button construction as the home screen and Shop — the v2
## PLAY popup's buttons were dead on Buddhika's phone, so no popup
## overlay here. World Tour and NEARBY still exist, as smaller
## secondary buttons below the big ones, and SEARCH FRIEND is a
## separate secondary entry below them (user 2026-11-28): the
## name-search / invite flow lives on there — find a friend by name,
## invite them from the invite box. The 2P/4P buttons NEVER send
## invites; only SEARCH FRIEND does.

signal bot_chosen
signal two_players_chosen
signal same_two_players_chosen
signal four_players_chosen
signal tour_chosen
signal nearby_chosen
signal search_friend_chosen
signal go_back

## Auto-connect stake (2026-11-28): the lobby's standard 100 — the
## stake the player used in the lobby. Main caps it at the balance.
const AUTO_STAKE := 100

const DISPLAY_FONT = preload("res://art/Baloo2-Bold.ttf")
const WOOD_BG = preload("res://art/bg_home_wood.jpg")

## The big buttons, named so tests (and future code) can find them
## without depending on layout order.
var bot_button: Button = null
var two_players_button: Button = null
var same_two_players_button: Button = null
var four_players_button: Button = null
var tour_button: Button = null
var nearby_button: Button = null
var search_friend_button: Button = null
var back_button: Button = null

## Chunky 3D tile (UiKit.tile_button, but with a chosen label colour —
## the gold tile needs dark text, white on bright gold reads badly).
func _tile(text: String, font_size: int, pair: Dictionary, label_color: Color) -> ThreeDButton:
	var b := ThreeDButton.new()
	b.text = text
	b.add_theme_font_size_override("font_size", font_size)
	var lip: Color = pair.get("lip", ThreeDButton.lip_for(pair["bottom"]))
	b.set_colors(pair["top"], pair["bottom"], lip, label_color)
	b.pill = false
	b.corner_radius = 24.0
	return b

## Chunky 3D pill (same colours as _tile, fully round).
func _pill(text: String, font_size: int, pair: Dictionary, label_color: Color) -> ThreeDButton:
	var b := _tile(text, font_size, pair, label_color)
	b.pill = true
	return b

## Pin a code-drawn icon to the left (-1) or right (+1) edge of a
## button, vertically centred. Icons are mouse-transparent so taps
## still hit the button.
func _attach_icon(btn: Button, kind: String, side: int, px: float, col: Color = Color.WHITE) -> void:
	var ic := PlayIcon.new()
	ic.kind = kind
	ic.icon_color = col
	ic.custom_minimum_size = Vector2(px, px)
	ic.anchor_top = 0.5
	ic.anchor_bottom = 0.5
	ic.offset_top = -px * 0.5
	ic.offset_bottom = px * 0.5
	if side < 0:
		ic.anchor_left = 0.0
		ic.anchor_right = 0.0
		ic.offset_left = 16.0
		ic.offset_right = 16.0 + px
	else:
		ic.anchor_left = 1.0
		ic.anchor_right = 1.0
		ic.offset_left = -16.0 - px
		ic.offset_right = -16.0
	btn.add_child(ic)

func _ready() -> void:
	mouse_filter = Control.MOUSE_FILTER_IGNORE
	UiKit.full_rect(self)
	# Wooden background: the repo's own home wood photo (1080x1920,
	# the exact 720x1280 aspect) — leaves at the edges, carrom coins
	# along the bottom — plus a light darkening so the gold title and
	# white subtitles read on the pale middle planks.
	var bg := TextureRect.new()
	bg.texture = WOOD_BG
	bg.expand_mode = TextureRect.EXPAND_IGNORE_SIZE
	bg.stretch_mode = TextureRect.STRETCH_SCALE
	bg.mouse_filter = Control.MOUSE_FILTER_IGNORE
	UiKit.full_rect(bg)
	add_child(bg)
	var shade := ColorRect.new()
	shade.color = Color(0.08, 0.03, 0.01, 0.20)
	shade.mouse_filter = Control.MOUSE_FILTER_IGNORE
	UiKit.full_rect(shade)
	add_child(shade)
	var root := VBoxContainer.new()
	UiKit.full_rect(root)
	root.offset_left = 24
	root.offset_right = -24
	root.offset_top = 8
	root.offset_bottom = -8
	root.add_theme_constant_override("separation", 12)
	add_child(root)
	# Hero logo: gold crown + BMS + red CARROM ribbon (code-drawn).
	var logo := PlayLogo.new()
	logo.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	root.add_child(logo)
	# PLAY title in gold, flanked by gold arrows.
	var title_row := HBoxContainer.new()
	title_row.add_theme_constant_override("separation", 10)
	title_row.alignment = BoxContainer.ALIGNMENT_CENTER
	root.add_child(title_row)
	var arrow_l := GoldArrow.new()
	arrow_l.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	arrow_l.custom_minimum_size = Vector2(60, 24)
	title_row.add_child(arrow_l)
	var title := Label.new()
	title.text = "PLAY"
	title.add_theme_font_override("font", DISPLAY_FONT)
	title.add_theme_font_size_override("font_size", 52)
	title.add_theme_color_override("font_color", Color(1.0, 0.85, 0.40))
	title.add_theme_color_override("font_shadow_color", Color(0, 0, 0, 0.9))
	title.add_theme_constant_override("shadow_offset_x", 2)
	title.add_theme_constant_override("shadow_offset_y", 3)
	title.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	title_row.add_child(title)
	var arrow_r := GoldArrow.new()
	arrow_r.flip = true
	arrow_r.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	arrow_r.custom_minimum_size = Vector2(60, 24)
	title_row.add_child(arrow_r)
	var sub := UiKit.muted_label("Pick how you want to play.", 20)
	sub.add_theme_color_override("font_color", Color(0.96, 0.95, 0.92))
	sub.add_theme_color_override("font_shadow_color", Color(0, 0, 0, 0.9))
	sub.add_theme_constant_override("shadow_offset_x", 2)
	sub.add_theme_constant_override("shadow_offset_y", 2)
	root.add_child(sub)
	# (1) Bot — gold tile, dark text, robot icon (thumbs up).
	bot_button = _tile("PLAY WITH A BOT\nSolo vs the computer — free, offline", 24, UiKit.TILE_GOLD, UiKit.DARK_TEXT)
	bot_button.name = "BotButton"
	bot_button.custom_minimum_size = Vector2(0, 100)
	bot_button.pressed.connect(func() -> void: bot_chosen.emit())
	_attach_icon(bot_button, "robot", -1, 52.0)
	root.add_child(bot_button)
	# (2) 2 players — green tile, auto-connect with one online player.
	two_players_button = _tile("2 PLAYERS — 1 VS 1\nAuto-connect with one online player", 24, UiKit.TILE_GREEN, Color.WHITE)
	two_players_button.name = "TwoPlayersButton"
	two_players_button.custom_minimum_size = Vector2(0, 100)
	two_players_button.pressed.connect(func() -> void: two_players_chosen.emit())
	_attach_icon(two_players_button, "people", -1, 52.0)
	_attach_icon(two_players_button, "globe", 1, 52.0)
	root.add_child(two_players_button)
	# (2b) SAME 2 PLAYER — same green style, right below (2):
	# auto-connect with a player at YOUR level only.
	same_two_players_button = _tile("SAME 2 PLAYER\nAuto-connect with a player at your level", 24, UiKit.TILE_GREEN, Color.WHITE)
	same_two_players_button.name = "SameTwoPlayersButton"
	same_two_players_button.custom_minimum_size = Vector2(0, 100)
	same_two_players_button.pressed.connect(func() -> void: same_two_players_chosen.emit())
	_attach_icon(same_two_players_button, "people", -1, 52.0)
	_attach_icon(same_two_players_button, "star", 1, 48.0, Color(1.0, 0.85, 0.40))
	root.add_child(same_two_players_button)
	# (3) 4 players — red tile, auto-connect with three online players.
	four_players_button = _tile("4 PLAYERS — DOUBLES\nAuto-connect with three online players", 24, UiKit.TILE_RED, Color.WHITE)
	four_players_button.name = "FourPlayersButton"
	four_players_button.custom_minimum_size = Vector2(0, 100)
	four_players_button.pressed.connect(func() -> void: four_players_chosen.emit())
	_attach_icon(four_players_button, "people", -1, 52.0)
	_attach_icon(four_players_button, "group", 1, 52.0)
	root.add_child(four_players_button)
	# Stake info box — dark brown panel, gold border, (i) icon, the
	# "Winner takes the pot" line in gold. RichTextLabel autowraps,
	# so the long second line cannot force the VBox wider than the
	# 720 screen (the 2026-11-27 overflow bug — same fix as the
	# Online Lobby). Stake number is wired to AUTO_STAKE.
	var info := PanelContainer.new()
	info.add_theme_stylebox_override("panel", UiKit.panel_style(Color(0.22, 0.10, 0.04, 0.96), UiKit.GOLD, 16, 2))
	root.add_child(info)
	var info_row := HBoxContainer.new()
	info_row.add_theme_constant_override("separation", 12)
	info.add_child(info_row)
	var info_icon := PlayIcon.new()
	info_icon.kind = "info"
	info_icon.icon_color = Color(1.0, 0.85, 0.40)
	info_icon.custom_minimum_size = Vector2(40, 40)
	info_row.add_child(info_icon)
	var hint := RichTextLabel.new()
	hint.bbcode_enabled = true
	hint.fit_content = true
	hint.scroll_active = false
	hint.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	hint.text = "[center]Bot matches are free and pay no coins.\n2-player and 4-player matches use your stake ◎ %d — [color=#FFD968]Winner takes the pot (2p) / winning team splits it (4p).[/color][/center]" % AUTO_STAKE
	hint.add_theme_font_size_override("normal_font_size", 18)
	hint.add_theme_color_override("default_color", Color(0.96, 0.95, 0.92))
	hint.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	info_row.add_child(hint)
	# Secondary, smaller: the two older modes stay reachable.
	# Order follows the user's list: NEARBY first, then WORLD TOUR.
	var more := HBoxContainer.new()
	more.add_theme_constant_override("separation", 12)
	root.add_child(more)
	nearby_button = UiKit.dark_button("NEARBY — Same Wi-Fi", 20)
	nearby_button.name = "NearbyButton"
	nearby_button.custom_minimum_size = Vector2(0, 54)
	nearby_button.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	nearby_button.pressed.connect(func() -> void: nearby_chosen.emit())
	_attach_icon(nearby_button, "wifi", -1, 30.0)
	more.add_child(nearby_button)
	tour_button = UiKit.dark_button("WORLD TOUR", 20)
	tour_button.name = "TourButton"
	tour_button.custom_minimum_size = Vector2(0, 54)
	tour_button.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	tour_button.pressed.connect(func() -> void: tour_chosen.emit())
	_attach_icon(tour_button, "trophy", -1, 30.0)
	more.add_child(tour_button)
	# (6) SEARCH FRIEND — separate secondary entry (user 2026-11-28):
	# the name-search / invite flow lives on here, NOT on the 2P/4P
	# buttons (those auto-connect and never send invites).
	search_friend_button = UiKit.dark_button("SEARCH FRIEND", 22)
	search_friend_button.name = "SearchFriendButton"
	search_friend_button.custom_minimum_size = Vector2(0, 56)
	search_friend_button.pressed.connect(func() -> void: search_friend_chosen.emit())
	_attach_icon(search_friend_button, "people", -1, 34.0)
	root.add_child(search_friend_button)
	var search_note := UiKit.muted_label("Find a friend by name and invite them to a match.", 16)
	search_note.add_theme_color_override("font_color", Color(0.96, 0.95, 0.92))
	search_note.add_theme_color_override("font_shadow_color", Color(0, 0, 0, 0.9))
	search_note.add_theme_constant_override("shadow_offset_x", 2)
	search_note.add_theme_constant_override("shadow_offset_y", 2)
	root.add_child(search_note)
	# Gold divider with a star (reference: the line + star between
	# SEARCH FRIEND and BACK).
	var divider := HBoxContainer.new()
	divider.add_theme_constant_override("separation", 10)
	divider.alignment = BoxContainer.ALIGNMENT_CENTER
	root.add_child(divider)
	var div_l := GoldArrow.new()
	div_l.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	div_l.custom_minimum_size = Vector2(60, 24)
	divider.add_child(div_l)
	var div_star := PlayIcon.new()
	div_star.kind = "star"
	div_star.icon_color = Color(1.0, 0.85, 0.40)
	div_star.custom_minimum_size = Vector2(28, 28)
	divider.add_child(div_star)
	var div_r := GoldArrow.new()
	div_r.flip = true
	div_r.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	div_r.custom_minimum_size = Vector2(60, 24)
	divider.add_child(div_r)
	var spacer := Control.new()
	spacer.size_flags_vertical = Control.SIZE_EXPAND_FILL
	spacer.mouse_filter = Control.MOUSE_FILTER_IGNORE
	root.add_child(spacer)
	back_button = _pill("←  BACK", 24, UiKit.TILE_PURPLE, Color.WHITE)
	back_button.name = "BackButton"
	back_button.custom_minimum_size = Vector2(0, 56)
	back_button.pressed.connect(func() -> void: go_back.emit())
	root.add_child(back_button)
