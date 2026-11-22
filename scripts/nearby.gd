class_name NearbyScreen
extends Control

## NEARBY — same-Wi-Fi play (v6). No internet server exists yet (hosting
## needs an Oracle account + a card for verification — see
## docs/online-server.md), so two phones on the same Wi-Fi match
## directly: one HOSTS, the other JOINS. No internet needed.
##
## Also holds the internet server address field, so a future hosted
## server IP can be entered without a new build: ONLINE will use it
## once a server exists.

signal host_chosen
signal join_chosen
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
	var srv_title := UiKit.body_label("INTERNET SERVER — worldwide play (for later)", 20)
	root.add_child(srv_title)
	var srv_note := UiKit.muted_label("Now: %s — no worldwide server yet, so use NEARBY above. When a server exists, type its address here and tap SAVE; ONLINE will use it." % Save.online_host, 17)
	# Autowrap is essential: without it this long line's minimum width
	# (~1159 px) blows the whole VBox out past the screen edge.
	srv_note.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	root.add_child(srv_note)
	var row := HBoxContainer.new()
	row.add_theme_constant_override("separation", 10)
	root.add_child(row)
	var edit := LineEdit.new()
	edit.text = Save.online_host
	edit.placeholder_text = "Server IP or hostname"
	edit.add_theme_font_size_override("font_size", 22)
	edit.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	edit.custom_minimum_size = Vector2(0, 56)
	row.add_child(edit)
	var save := UiKit.dark_button("SAVE", 22)
	save.pressed.connect(func() -> void:
		var v := edit.text.strip_edges()
		if v == "":
			return
		Save.online_host = v
		Save.save()
		srv_note.text = "Saved — ONLINE will use %s." % v)
	row.add_child(save)
	var spacer := Control.new()
	spacer.size_flags_vertical = Control.SIZE_EXPAND_FILL
	spacer.mouse_filter = Control.MOUSE_FILTER_IGNORE
	root.add_child(spacer)
	var back := UiKit.dark_button("←  BACK", 24)
	back.custom_minimum_size = Vector2(0, 64)
	back.pressed.connect(func() -> void: go_back.emit())
	root.add_child(back)
