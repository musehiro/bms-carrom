class_name ModeChoiceScreen
extends Control

## Full-screen mode choice (v3). PLAY opens THIS screen instead of a popup.
##
## Why: the v2 PLAY popup's SOLO/ONLINE buttons were dead on Buddhika's
## real phone (only the X worked), while the same buttons on the home
## screen and in the difficulty popup DO work there. Every desktop
## simulation (headless, Xvfb 720x1280 and 720x1640, touch-only and
## Android-style touch+emulated-mouse) passed, and the Godot 4.3 Button /
## Viewport source confirms the mechanism is sound — so the popup overlay
## itself is the unproven layer on his device. This screen uses the exact
## same plain full-screen button layout as the home screen and Shop, both
## proven to work on his phone: no popup window, no dim overlay.
##
## Flow: PLAY -> this screen -> SOLO -> difficulty popup (proven) -> match;
## ONLINE -> stake picker (proven) -> search with the 12 s BOT fallback.
## NEARBY -> same-Wi-Fi play (v6): one phone HOSTS, the other JOINS.

signal solo_chosen
signal tour_chosen
signal online_chosen
signal nearby_chosen
signal go_back

func _ready() -> void:
	mouse_filter = Control.MOUSE_FILTER_IGNORE
	UiKit.full_rect(self)
	var bg := ColorRect.new()
	bg.color = Color(0.09, 0.07, 0.05)
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
	var title := UiKit.title_label("CHOOSE A MODE", 48)
	root.add_child(title)
	var sub := UiKit.muted_label("Solo is free practice vs the computer.\nWorld Tour is advanced computer champions — with stakes.\nOnline is a real player, anywhere in the world.", 20)
	root.add_child(sub)
	var divider := ColorRect.new()
	divider.color = Color(0.83, 0.69, 0.22, 0.55)
	divider.custom_minimum_size = Vector2(0, 3)
	divider.mouse_filter = Control.MOUSE_FILTER_IGNORE
	root.add_child(divider)
	var solo := UiKit.gold_button("SOLO — vs AI (offline)", 30)
	solo.custom_minimum_size = Vector2(0, 96)
	solo.pressed.connect(func() -> void: solo_chosen.emit())
	root.add_child(solo)
	# v8 World Tour: advanced computer opponents with stakes. The button
	# and the roster both say BOT — never a fake human (design doc 3.2).
	var tour := UiKit.gold_button("WORLD TOUR — vs computer champions", 30)
	tour.custom_minimum_size = Vector2(0, 96)
	tour.pressed.connect(func() -> void: tour_chosen.emit())
	root.add_child(tour)
	var online := UiKit.dark_button("ONLINE — vs real players", 30)
	online.custom_minimum_size = Vector2(0, 96)
	online.pressed.connect(func() -> void: online_chosen.emit())
	root.add_child(online)
	var nearby := UiKit.dark_button("NEARBY — same Wi-Fi", 30)
	nearby.custom_minimum_size = Vector2(0, 96)
	nearby.pressed.connect(func() -> void: nearby_chosen.emit())
	root.add_child(nearby)
	var hint := UiKit.muted_label("World Tour bots are computers (BOT) — hard to beat, stakes like a real match.\nOnline matches pair you within ±2 levels.\nNearby matches two phones on the same Wi-Fi — one HOSTS, one JOINS.\nNo opponent in 12 s? Play vs the computer instead.", 18)
	root.add_child(hint)
	var spacer := Control.new()
	spacer.size_flags_vertical = Control.SIZE_EXPAND_FILL
	spacer.mouse_filter = Control.MOUSE_FILTER_IGNORE
	root.add_child(spacer)
	var back := UiKit.dark_button("←  BACK", 24)
	back.custom_minimum_size = Vector2(0, 64)
	back.pressed.connect(func() -> void: go_back.emit())
	root.add_child(back)
