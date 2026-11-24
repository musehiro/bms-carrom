class_name PlayMenuScreen
extends Control

## v11 Play menu — THREE BIG BUTTONS (Buddhika's design). PLAY opens
## THIS screen instead of a popup.
##
##   (1) PLAY WITH A BOT — solo vs the computer (free, offline).
##       Routes to the existing solo/BOT flow (Main._start_solo_direct).
##   (2) PLAY WITH THE WORLD — a real player, anywhere in the world.
##       Routes to the existing random-matchmaking flow: stake picker,
##       then the 2p/4p choice, then the NetClient queue (Main
##       ._show_online_stake -> _start_matchmaking -> Net.queue_up).
##       This screen never touches net_client.gd.
##   (3) PLAY WITH FRIENDS — invite friends, 2, 3 or 4 players in one
##       match. Routes to the invite flow: back home with the invite
##       box open (search by name, send a 2p or 4p invite).
##
## The player picks whichever they like. Full-screen layout, same plain
## button construction as the home screen and Shop — the v2 PLAY popup's
## buttons were dead on Buddhika's phone, so no popup overlay here.
## World Tour and NEARBY still exist, as smaller secondary buttons
## below the three big ones (nothing is removed, only re-ordered).

signal bot_chosen
signal world_chosen
signal friends_chosen
signal tour_chosen
signal nearby_chosen
signal go_back

## The three big buttons, named so tests (and future code) can find
## them without depending on layout order.
var bot_button: Button = null
var world_button: Button = null
var friends_button: Button = null
var tour_button: Button = null
var nearby_button: Button = null
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
	# (2) The world — blue tile, random matchmaking anywhere on Earth.
	world_button = UiKit.tile_button("🌍  PLAY WITH THE WORLD\nA real player, anywhere in the world", 28, UiKit.TILE_SPELLING)
	world_button.name = "WorldButton"
	world_button.custom_minimum_size = Vector2(0, 120)
	world_button.pressed.connect(func() -> void: world_chosen.emit())
	root.add_child(world_button)
	# (3) Friends — pink tile, invite people you know, 2–4 players.
	# (Gold would need dark text — tile_button labels are white — so
	# friends gets the pink tile instead; gold stays the PLAY colour.)
	friends_button = UiKit.tile_button("✉  PLAY WITH FRIENDS\nInvite friends — 2, 3 or 4 players in one match", 28, UiKit.TILE_BALLOON)
	friends_button.name = "FriendsButton"
	friends_button.custom_minimum_size = Vector2(0, 120)
	friends_button.pressed.connect(func() -> void: friends_chosen.emit())
	root.add_child(friends_button)
	var hint := UiKit.muted_label("Bot matches are free and pay no coins.\nWorld and Friends matches use your stake — winner takes the pot.", 18)
	root.add_child(hint)
	# Secondary, smaller: the two older modes stay reachable.
	var more := HBoxContainer.new()
	more.add_theme_constant_override("separation", 12)
	root.add_child(more)
	tour_button = UiKit.dark_button("WORLD TOUR", 20)
	tour_button.name = "TourButton"
	tour_button.custom_minimum_size = Vector2(0, 56)
	tour_button.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	tour_button.pressed.connect(func() -> void: tour_chosen.emit())
	more.add_child(tour_button)
	nearby_button = UiKit.dark_button("NEARBY — same Wi-Fi", 20)
	nearby_button.name = "NearbyButton"
	nearby_button.custom_minimum_size = Vector2(0, 56)
	nearby_button.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	nearby_button.pressed.connect(func() -> void: nearby_chosen.emit())
	more.add_child(nearby_button)
	var spacer := Control.new()
	spacer.size_flags_vertical = Control.SIZE_EXPAND_FILL
	spacer.mouse_filter = Control.MOUSE_FILTER_IGNORE
	root.add_child(spacer)
	back_button = UiKit.dark_button("←  BACK", 24)
	back_button.name = "BackButton"
	back_button.custom_minimum_size = Vector2(0, 64)
	back_button.pressed.connect(func() -> void: go_back.emit())
	root.add_child(back_button)
