class_name TourRosterScreen
extends Control

## World Tour roster (v8): pick an advanced computer opponent.
##
## Honest labelling is a HARD RULE (design doc §3.2 — "never a fake
## human"): the title, the subtitle and EVERY bot card say these are
## COMPUTER opponents (BOT). There is no "searching for a real player"
## anywhere — the player picks a named bot and the match starts at
## once. Names + countries + cartoon avatars are the flavour; the BOT
## tag is the truth.
##
## The bots are the WorldTour roster: name, country, skill (3 Advanced,
## 4 Expert, 5 Master — all above Hard), level, and a cartoon avatar
## drawn in-game (BotAvatar: coloured face, eyes, smile — no photos).

signal bot_chosen(bot: Dictionary)
signal go_back

## Cartoon avatar: a coloured face with eyes and a smile, drawn
## in-game. No photo, no emoji.
class BotAvatar:
	extends Control
	var face_color := Color(0.5, 0.5, 0.5)

	func _draw() -> void:
		var c := size * 0.5
		var r := minf(size.x, size.y) * 0.5 - 2.0
		if r <= 0.0:
			return
		draw_circle(c, r, face_color)
		draw_arc(c, r, 0, TAU, 32, Color(0, 0, 0, 0.35), 3.0)
		var eye_r := r * 0.09
		var eye_c := Color(0.10, 0.08, 0.05)
		draw_circle(c + Vector2(-r * 0.35, -r * 0.15), eye_r, eye_c)
		draw_circle(c + Vector2(r * 0.35, -r * 0.15), eye_r, eye_c)
		draw_arc(c + Vector2(0, r * 0.05), r * 0.45, deg_to_rad(20.0), deg_to_rad(160.0), 16, eye_c, 3.0)

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
	root.offset_top = 60
	root.offset_bottom = -60
	root.add_theme_constant_override("separation", 14)
	add_child(root)
	var title := UiKit.title_label("WORLD TOUR", 48)
	root.add_child(title)
	var sub := UiKit.muted_label("Advanced COMPUTER opponents from around the world.\nEvery opponent is a BOT — clearly marked. No real players here.", 20)
	root.add_child(sub)
	var divider := ColorRect.new()
	divider.color = Color(0.83, 0.69, 0.22, 0.55)
	divider.custom_minimum_size = Vector2(0, 3)
	divider.mouse_filter = Control.MOUSE_FILTER_IGNORE
	root.add_child(divider)
	var scroll := ScrollContainer.new()
	scroll.size_flags_vertical = Control.SIZE_EXPAND_FILL
	scroll.horizontal_scroll_mode = ScrollContainer.SCROLL_MODE_DISABLED
	root.add_child(scroll)
	var list := VBoxContainer.new()
	list.add_theme_constant_override("separation", 12)
	list.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	scroll.add_child(list)
	for bot in WorldTour.BOTS:
		list.add_child(_bot_card(bot))
	var note := UiKit.muted_label("Stakes like a real match: winner takes the pot.\nBots play hard — sometimes you win, sometimes you lose.\nThink with your brain.", 18)
	root.add_child(note)
	var back := UiKit.dark_button("←  BACK", 24)
	back.custom_minimum_size = Vector2(0, 64)
	back.pressed.connect(func() -> void: go_back.emit())
	root.add_child(back)

func _bot_card(bot: Dictionary) -> Button:
	var b := UiKit.dark_button("", 26)
	b.custom_minimum_size = Vector2(0, 128)
	var row := HBoxContainer.new()
	row.mouse_filter = Control.MOUSE_FILTER_IGNORE
	UiKit.full_rect(row)
	row.add_theme_constant_override("separation", 14)
	b.add_child(row)
	var av := BotAvatar.new()
	av.face_color = bot.get("color", Color(0.5, 0.5, 0.5))
	av.custom_minimum_size = Vector2(84, 84)
	av.mouse_filter = Control.MOUSE_FILTER_IGNORE
	row.add_child(av)
	var vb := VBoxContainer.new()
	vb.mouse_filter = Control.MOUSE_FILTER_IGNORE
	vb.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	vb.add_theme_constant_override("separation", 2)
	row.add_child(vb)
	var top := HBoxContainer.new()
	top.mouse_filter = Control.MOUSE_FILTER_IGNORE
	vb.add_child(top)
	var nm := Label.new()
	nm.text = String(bot.get("name", "?"))
	nm.add_theme_font_size_override("font_size", 26)
	nm.add_theme_color_override("font_color", UiKit.TEXT)
	nm.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	nm.mouse_filter = Control.MOUSE_FILTER_IGNORE
	top.add_child(nm)
	var tag := Label.new()
	tag.text = "BOT"
	tag.add_theme_font_size_override("font_size", 20)
	tag.add_theme_color_override("font_color", UiKit.GOLD_LIGHT)
	tag.mouse_filter = Control.MOUSE_FILTER_IGNORE
	top.add_child(tag)
	var meta := Label.new()
	meta.text = "%s  •  %s  •  Lv %d" % [String(bot.get("country", "?")), WorldTour.skill_name(int(bot.get("skill", 3))), int(bot.get("level", 1))]
	meta.add_theme_font_size_override("font_size", 18)
	meta.add_theme_color_override("font_color", UiKit.GOLD_LIGHT)
	meta.mouse_filter = Control.MOUSE_FILTER_IGNORE
	vb.add_child(meta)
	var blurb := Label.new()
	blurb.text = String(bot.get("blurb", ""))
	blurb.add_theme_font_size_override("font_size", 16)
	blurb.add_theme_color_override("font_color", UiKit.MUTED)
	blurb.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	blurb.mouse_filter = Control.MOUSE_FILTER_IGNORE
	vb.add_child(blurb)
	var bot_copy: Dictionary = bot
	b.pressed.connect(func() -> void: bot_chosen.emit(bot_copy))
	return b
