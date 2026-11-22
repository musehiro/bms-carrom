class_name ShopScreen
extends Control

## Coins-only shop (design doc 6.4): 6 boards + 7 strikers. No real-money
## purchases in v1. Items unlock by level and price; stat differences are
## small and capped (+15%).

signal closed

var _coins_label: Label
var _list: VBoxContainer
var _tab := "boards"

func _ready() -> void:
	UiKit.full_rect(self)
	var bg := ColorRect.new()
	bg.color = Color(0.10, 0.08, 0.07)
	UiKit.full_rect(bg)
	add_child(bg)
	var root := VBoxContainer.new()
	UiKit.full_rect(root)
	root.offset_left = 20
	root.offset_right = -20
	root.offset_top = 14
	root.offset_bottom = -14
	root.add_theme_constant_override("separation", 12)
	add_child(root)
	var top := HBoxContainer.new()
	top.add_theme_constant_override("separation", 10)
	var title := UiKit.title_label("SHOP", 40)
	title.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	title.horizontal_alignment = HORIZONTAL_ALIGNMENT_LEFT
	top.add_child(title)
	_coins_label = Label.new()
	_coins_label.add_theme_font_size_override("font_size", 24)
	_coins_label.add_theme_color_override("font_color", UiKit.GOLD_LIGHT)
	top.add_child(_coins_label)
	var back := UiKit.dark_button("BACK", 22)
	back.pressed.connect(func() -> void: closed.emit())
	top.add_child(back)
	root.add_child(top)
	var tabs := HBoxContainer.new()
	tabs.add_theme_constant_override("separation", 12)
	var b_tab := UiKit.gold_button("BOARDS", 24)
	b_tab.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	b_tab.pressed.connect(func() -> void: _set_tab("boards"))
	tabs.add_child(b_tab)
	var s_tab := UiKit.dark_button("STRIKERS", 24)
	s_tab.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	s_tab.pressed.connect(func() -> void: _set_tab("strikers"))
	tabs.add_child(s_tab)
	root.add_child(tabs)
	var scroll := ScrollContainer.new()
	scroll.size_flags_vertical = Control.SIZE_EXPAND_FILL
	scroll.horizontal_scroll_mode = ScrollContainer.SCROLL_MODE_DISABLED
	root.add_child(scroll)
	_list = VBoxContainer.new()
	_list.add_theme_constant_override("separation", 10)
	_list.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	scroll.add_child(_list)
	var note := UiKit.muted_label("Coins only — no real-money purchases. Win matches to earn coins.", 16)
	root.add_child(note)
	_refresh()

func _set_tab(t: String) -> void:
	_tab = t
	_refresh()

func _refresh() -> void:
	_coins_label.text = "◉ %d" % Save.coins
	for c in _list.get_children():
		c.queue_free()
	var items: Array = ShopData.BOARDS if _tab == "boards" else ShopData.STRIKERS
	for item in items:
		var owned: bool = (Save.owned_boards if _tab == "boards" else Save.owned_strikers).has(item["id"])
		var equipped: bool = (Save.equipped_board if _tab == "boards" else Save.equipped_striker) == item["id"]
		var locked := Save.level() < int(item["level"])
		var panel := PanelContainer.new()
		panel.add_theme_stylebox_override("panel", UiKit.panel_style())
		var vb := VBoxContainer.new()
		panel.add_child(vb)
		var name_row := HBoxContainer.new()
		var nm := Label.new()
		nm.text = item["name"]
		nm.add_theme_font_size_override("font_size", 26)
		nm.add_theme_color_override("font_color", UiKit.GOLD_LIGHT)
		nm.size_flags_horizontal = Control.SIZE_EXPAND_FILL
		name_row.add_child(nm)
		if _tab == "strikers":
			var stats := Label.new()
			stats.text = "Force %d • Aim %d • Time %ds" % [int(item["force"]), int(item["aim"]), int(item["time"])]
			stats.add_theme_font_size_override("font_size", 18)
			stats.add_theme_color_override("font_color", UiKit.MUTED)
			name_row.add_child(stats)
		vb.add_child(name_row)
		var desc := UiKit.body_label(item["desc"], 19)
		vb.add_child(desc)
		var row := HBoxContainer.new()
		var price := Label.new()
		price.add_theme_font_size_override("font_size", 22)
		if equipped:
			price.text = "EQUIPPED"
			price.add_theme_color_override("font_color", Color(0.4, 0.9, 0.5))
		elif locked:
			price.text = "Unlocks at Lv %d" % int(item["level"])
			price.add_theme_color_override("font_color", UiKit.MUTED)
		elif owned:
			price.text = "Owned"
			price.add_theme_color_override("font_color", UiKit.TEXT)
		else:
			price.text = "◉ %d coins" % int(item["price"])
			price.add_theme_color_override("font_color", UiKit.GOLD_LIGHT)
		price.size_flags_horizontal = Control.SIZE_EXPAND_FILL
		row.add_child(price)
		var btn: Button
		if equipped:
			btn = UiKit.dark_button("EQUIPPED", 20)
			btn.disabled = true
		elif locked:
			btn = UiKit.dark_button("LOCKED", 20)
			btn.disabled = true
		elif owned:
			btn = UiKit.gold_button("EQUIP", 20)
			var id := String(item["id"])
			btn.pressed.connect(func() -> void: _equip(id))
		else:
			btn = UiKit.gold_button("BUY", 20)
			var id := String(item["id"])
			btn.pressed.connect(func() -> void: _buy(id))
		btn.custom_minimum_size = Vector2(150, 48)
		row.add_child(btn)
		vb.add_child(row)
		_list.add_child(panel)

func _buy(id: String) -> void:
	var item: Dictionary = ShopData.board_by_id(id) if _tab == "boards" else ShopData.striker_by_id(id)
	if Save.level() < int(item["level"]):
		return
	if not Save.spend_coins(int(item["price"])):
		return
	if _tab == "boards":
		Save.owned_boards.append(id)
		Save.equipped_board = id
	else:
		Save.owned_strikers.append(id)
		Save.equipped_striker = id
	Save.save()
	Sfx.win()
	_refresh()

func _equip(id: String) -> void:
	if _tab == "boards":
		Save.equipped_board = id
	else:
		Save.equipped_striker = id
	Save.save()
	Sfx.tap()
	_refresh()
