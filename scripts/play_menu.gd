class_name PlayMenuScreen
extends Control

## Play menu — big buttons (Buddhika's design, redesigned 2026-11-28).
## PLAY opens THIS screen instead of a popup.
##
##   (1) PLAY WITH A BOT — solo vs the computer (free, offline).
##       Routes to the existing solo/BOT flow (Main._start_solo_direct).
##   (2) 2 PLAYERS — 1 VS 1 — tap and it AUTO-CONNECTS with one
##       online player: the existing random-matchmaking queue
##       (find_match, mode '2p') at the standard stake — no stake
##       picker, no invites. Main._start_auto_match owns the stake +
##       broke-player routing; this screen never touches net_client.gd.
##   (3) 4 PLAYERS — DOUBLES — same, but find_match mode '4p':
##       auto-connects with three online players.
##
## PLAY WITH THE WORLD and PLAY WITH FRIENDS are GONE from this
## screen (user 2026-11-28) — replaced by the two auto-connect
## buttons above. The Online Lobby and the invite code/screens are
## NOT deleted: they stay in the repo, reachable from the home
## ONLINE tile (stake picker -> lobby) and the home invite box.
##
## The player picks whichever they like. Full-screen layout, same plain
## button construction as the home screen and Shop — the v2 PLAY popup's
## buttons were dead on Buddhika's phone, so no popup overlay here.
## World Tour and NEARBY still exist, as smaller secondary buttons
## below the three big ones, and SEARCH FRIEND is a separate
## secondary entry below them (user 2026-11-28): the name-search /
## invite flow lives on there — find a friend by name, invite them
## from the invite box. The 2P/4P buttons NEVER send invites; only
## SEARCH FRIEND does.

signal bot_chosen
signal two_players_chosen
signal four_players_chosen
signal tour_chosen
signal nearby_chosen
signal search_friend_chosen
signal go_back

## Auto-connect stake (2026-11-28): the lobby's standard 100 — the
## stake the player used in the lobby. Main caps it at the balance.
const AUTO_STAKE := 100

## The three big buttons, named so tests (and future code) can find
## them without depending on layout order.
var bot_button: Button = null
var two_players_button: Button = null
var four_players_button: Button = null
var tour_button: Button = null
var nearby_button: Button = null
var search_friend_button: Button = null
var back_button: Button = null

func _ready() -> void:
	mouse_filter = Control.MOUSE_FILTER_IGNORE
	UiKit.full_rect(self)
	var bg := ColorRect.new()
	bg.color = Color(0.04, 0.45, 0.42) # v10: vivid teal, not near-black
	bg.mouse_filter = Control.MOUSE_FILTER_IGNORE
	UiKit.full_rect(bg)
	add_child(bg)
	var root := VBoxContainer.new()
	UiKit.full_rect(root)
	root.offset_left = 24
	root.offset_right = -24
	root.offset_top = 70
	root.offset_bottom = -70
	root.add_theme_constant_override("separation", 18)
	add_child(root)
	var title := UiKit.title_label("PLAY", 48)
	root.add_child(title)
	var sub := UiKit.muted_label("Pick how you want to play.", 20)
	root.add_child(sub)
	var divider := ColorRect.new()
	divider.color = Color(0.83, 0.69, 0.22, 0.55)
	divider.custom_minimum_size = Vector2(0, 3)
	divider.mouse_filter = Control.MOUSE_FILTER_IGNORE
	root.add_child(divider)
	# (1) Bot — green tile, free solo practice vs the computer.
	bot_button = UiKit.tile_button("▶  PLAY WITH A BOT\nSolo vs the computer — free, offline", 28, UiKit.TILE_PHONICS)
	bot_button.name = "BotButton"
	bot_button.custom_minimum_size = Vector2(0, 120)
	bot_button.pressed.connect(func() -> void: bot_chosen.emit())
	root.add_child(bot_button)
	# (2) 2 players — blue tile (the old World's colour), auto-connect
	# with one online player at the standard stake.
	two_players_button = UiKit.tile_button("2 PLAYERS — 1 VS 1\nAuto-connect with one online player", 28, UiKit.TILE_SPELLING)
	two_players_button.name = "TwoPlayersButton"
	two_players_button.custom_minimum_size = Vector2(0, 120)
	two_players_button.pressed.connect(func() -> void: two_players_chosen.emit())
	root.add_child(two_players_button)
	# (3) 4 players — pink tile (the old Friends' colour), auto-connect
	# with three online players.
	four_players_button = UiKit.tile_button("4 PLAYERS — DOUBLES\nAuto-connect with three online players", 28, UiKit.TILE_BALLOON)
	four_players_button.name = "FourPlayersButton"
	four_players_button.custom_minimum_size = Vector2(0, 120)
	four_players_button.pressed.connect(func() -> void: four_players_chosen.emit())
	root.add_child(four_players_button)
	# Overflow fix (same as the Online Lobby, 2026-11-27): muted_label
	# has NO autowrap, so this long second line's minimum width
	# (~900 px) would force the whole VBox wider than the 720 screen
	# and every button would run off the right edge. Wrap it.
	var hint := UiKit.muted_label("Bot matches are free and pay no coins.\n2-player and 4-player matches use your stake ◉ 100 — winner takes the pot (2p) / winning team splits it (4p).", 18)
	hint.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	root.add_child(hint)
	# Secondary, smaller: the two older modes stay reachable.
	# Order follows the user's list: NEARBY first, then WORLD TOUR.
	var more := HBoxContainer.new()
	more.add_theme_constant_override("separation", 12)
	root.add_child(more)
	nearby_button = UiKit.dark_button("NEARBY — same Wi-Fi", 20)
	nearby_button.name = "NearbyButton"
	nearby_button.custom_minimum_size = Vector2(0, 56)
	nearby_button.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	nearby_button.pressed.connect(func() -> void: nearby_chosen.emit())
	more.add_child(nearby_button)
	tour_button = UiKit.dark_button("WORLD TOUR", 20)
	tour_button.name = "TourButton"
	tour_button.custom_minimum_size = Vector2(0, 56)
	tour_button.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	tour_button.pressed.connect(func() -> void: tour_chosen.emit())
	more.add_child(tour_button)
	# (6) SEARCH FRIEND — separate secondary entry (user 2026-11-28):
	# the name-search / invite flow lives on here, NOT on the 2P/4P
	# buttons (those auto-connect and never send invites).
	search_friend_button = UiKit.dark_button("SEARCH FRIEND", 22)
	search_friend_button.name = "SearchFriendButton"
	search_friend_button.custom_minimum_size = Vector2(0, 64)
	search_friend_button.pressed.connect(func() -> void: search_friend_chosen.emit())
	root.add_child(search_friend_button)
	var search_note := UiKit.muted_label("Find a friend by name and invite them to a match.", 16)
	root.add_child(search_note)
	var spacer := Control.new()
	spacer.size_flags_vertical = Control.SIZE_EXPAND_FILL
	spacer.mouse_filter = Control.MOUSE_FILTER_IGNORE
	root.add_child(spacer)
	back_button = UiKit.dark_button("←  BACK", 24)
	back_button.name = "BackButton"
	back_button.custom_minimum_size = Vector2(0, 64)
	back_button.pressed.connect(func() -> void: go_back.emit())
	root.add_child(back_button)
