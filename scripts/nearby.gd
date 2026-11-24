class_name NearbyScreen
extends Control

## NEARBY — same-Wi-Fi play (v6). Two phones on the same Wi-Fi match
## directly: one HOSTS, the other JOINS. No internet needed.
##
## v11: ONLINE plays worldwide over P2P/WebRTC (see docs/p2p-online.md)
## — no server address is needed, and this screen no longer has an
## INTERNET SERVER field. The legacy ENet server path is kept behind
## the transport switch in net_client.gd for one version (rollback).

signal host_chosen
signal join_chosen
signal go_back

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
	root.add_theme_constant_override("separation", 16)
	add_child(root)
	var title := UiKit.title_label("NEARBY — SAME WI-FI", 44)
	root.add_child(title)
	var sub := UiKit.muted_label("Two phones on the same Wi-Fi can play each other.\nOne phone HOSTS, the other JOINS. No internet server needed.", 20)
	sub.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	root.add_child(sub)
	var divider := ColorRect.new()
	divider.color = Color(0.83, 0.69, 0.22, 0.55)
	divider.custom_minimum_size = Vector2(0, 3)
	divider.mouse_filter = Control.MOUSE_FILTER_IGNORE
	root.add_child(divider)
	var host := UiKit.gold_button("HOST A MATCH", 30)
	host.custom_minimum_size = Vector2(0, 96)
	host.pressed.connect(func() -> void: host_chosen.emit())
	root.add_child(host)
	root.add_child(UiKit.muted_label("This phone waits for a nearby player to join.", 17))
	var join := UiKit.dark_button("JOIN A MATCH", 30)
	join.custom_minimum_size = Vector2(0, 96)
	join.pressed.connect(func() -> void: join_chosen.emit())
	root.add_child(join)
	root.add_child(UiKit.muted_label("Finds a phone on your Wi-Fi that is hosting.", 17))
	var srv_title := UiKit.body_label("ONLINE — WORLDWIDE PLAY", 20)
	root.add_child(srv_title)
	# v11 (plan §3/§5): ONLINE plays over P2P/WebRTC — there is no
	# server address any more, so the INTERNET SERVER field is gone.
	# Save.online_host stays in the save file (compatibility) but is
	# no longer read for ONLINE; LAN HOST/JOIN above are untouched.
	var srv_note := UiKit.muted_label("Online: worldwide over the internet — no address needed.", 17)
	srv_note.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	root.add_child(srv_note)
	var spacer := Control.new()
	spacer.size_flags_vertical = Control.SIZE_EXPAND_FILL
	spacer.mouse_filter = Control.MOUSE_FILTER_IGNORE
	root.add_child(spacer)
	var back := UiKit.dark_button("←  BACK", 24)
	back.custom_minimum_size = Vector2(0, 64)
	back.pressed.connect(func() -> void: go_back.emit())
	root.add_child(back)
