class_name OnlinePlayerLobby
extends Control

## §11 online lobby (v11 plan §11): the player SEES who is online and
## invites them directly — built on the matchmaking worker's match
## lobby (roster/ready, scripts/lobby.gd), which is the SEPARATE
## post-match waiting room. This screen is the player-list screen:
##
##   ONLINE → radar search animation → live player list (display name
##   + level + status Online / In a match ONLY — never Gmail, never
##   coins) → tap INVITE (2p, one tap) or tap 4P on up to 3 players
##   then SEND (4p doubles) → or tap a big RANDOM button for worldwide
##   queue matchmaking. The stake was already chosen before this
##   screen opens (Main passes it in); invites sent from here use that
##   stake, with no second stake picker.
##
## Big chunky-3D buttons (UiKit.tile_button / gold + dark buttons),
## clean list, one clear action per row (INVITE). The radar is a visual
## for "searching online players worldwide" — the game has no physical
## location; players are found by level band, same as find_match.
## Refreshes the list every REFRESH_SECONDS (Main drives the fetch).

signal random_chosen(players: int)
signal invite_chosen(player: Dictionary)
signal group_invite_chosen(players: Array)
signal refresh_requested
signal go_back

const REFRESH_SECONDS := 10.0

var _stake := 0
var _players: Array = []
var _selected_4p := {} # id -> player dict (max 3; 2 picks can never send)
var _list_box: VBoxContainer = null
var _status_label: Label = null
var _send4_button: Button = null
var _refresh_accum := 0.0
var _radar: RadarView = null

## Spinning radar: concentric rings + a rotating sweep line. Pure
## Control drawing, no assets — _process rotates, _draw paints.
class RadarView:
	extends Control
	var _angle := 0.0
	func _ready() -> void:
		mouse_filter = Control.MOUSE_FILTER_IGNORE
	func _process(delta: float) -> void:
		_angle += delta * 1.2
		queue_redraw()
	func _draw() -> void:
		var c := size / 2
		var r := minf(size.x, size.y) / 2.0 - 6.0
		if r <= 0.0:
			return
		for i in range(1, 4):
			draw_arc(c, r * float(i) / 3.0, 0, TAU, 48, Color(0.4, 0.9, 0.5, 0.45), 2.0)
		draw_arc(c, r, 0, TAU, 64, Color(0.4, 0.9, 0.5, 0.8), 2.5)
		var tip := c + Vector2(cos(_angle), sin(_angle)) * r
		draw_line(c, tip, Color(0.5, 1.0, 0.6, 0.95), 3.0)
		draw_circle(tip, 5.0, Color(0.5, 1.0, 0.6))
		draw_circle(c, 4.0, Color(0.83, 0.69, 0.22))

func _init(stake: int = 0) -> void:
	_stake = stake

func _ready() -> void:
	mouse_filter = Control.MOUSE_FILTER_IGNORE
	UiKit.full_rect(self)
	var bg := ColorRect.new()
	bg.color = Color(0.04, 0.45, 0.42)
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
	root.add_child(UiKit.title_label("ONLINE LOBBY", 40))
	# Overflow fix (2026-11-27, user phone screenshots): muted_label
	# has NO autowrap, so this long line's minimum width (~931 px)
	# forced the whole VBox wider than the 720 screen and every
	# button/text ran off the right edge. Wrap it so the VBox stays
	# 672 wide (720 - 24 margins each side).
	var intro := UiKit.muted_label("Players online right now, worldwide. Tap INVITE to play together — or find a random opponent below.", 19)
	intro.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	root.add_child(intro)
	_radar = RadarView.new()
	_radar.custom_minimum_size = Vector2(0, 180)
	root.add_child(_radar)
	_status_label = UiKit.body_label("Searching for players worldwide…", 20)
	root.add_child(_status_label)
	var scroll := ScrollContainer.new()
	scroll.size_flags_vertical = Control.SIZE_EXPAND_FILL
	root.add_child(scroll)
	_list_box = VBoxContainer.new()
	_list_box.add_theme_constant_override("separation", 8)
	# Same ScrollContainer rule as the invite box: without
	# EXPAND_FILL the list keeps its content minimum width — and an
	# autowrapping label's minimum is ~1 px, so the empty-state text
	# drew one character per line in a sliver down the left edge.
	_list_box.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	scroll.add_child(_list_box)
	_list_box.add_child(UiKit.muted_label("Loading players…", 18))
	var b2 := UiKit.gold_button("2 PLAYERS — RANDOM OPPONENT", 26)
	b2.custom_minimum_size = Vector2(0, 96)
	b2.pressed.connect(func() -> void: random_chosen.emit(2))
	root.add_child(b2)
	var b4 := UiKit.dark_button("4 PLAYERS — RANDOM DOUBLES", 26)
	b4.custom_minimum_size = Vector2(0, 96)
	b4.pressed.connect(func() -> void: random_chosen.emit(4))
	root.add_child(b4)
	# Same overflow fix: wrap the stake line (its minimum width grows
	# with the stake and would otherwise widen the whole screen).
	var stake_lbl := UiKit.muted_label("Your stake ◉ %d — winner takes the pot (2p) / winning team splits it (4p)." % _stake, 17)
	stake_lbl.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	root.add_child(stake_lbl)
	var back := UiKit.dark_button("←  BACK", 24)
	back.custom_minimum_size = Vector2(0, 64)
	back.pressed.connect(func() -> void: go_back.emit())
	root.add_child(back)
	refresh_requested.emit()

func _process(delta: float) -> void:
	_refresh_accum += delta
	if _refresh_accum >= REFRESH_SECONDS:
		_refresh_accum = 0.0
		refresh_requested.emit()

## 2-or-4 choice (2026-11-27, user): tapping INVITE on a listed player
## must NOT send a 2p invite straight away — the player first chooses
## how many people play, and the match is only set after the choice.
## 2 PLAYERS sends the invite at once (lobby stake). 4 PLAYERS
## pre-selects this player in the doubles picker below, so 2 more
## friends can be picked and the match is set when SEND is tapped.
func _show_count_choice(player: Dictionary) -> void:
	var pop := UiKit.choose_player_count(String(player.get("display_name", "Player")))
	add_child(pop["dim"])
	var close_pop := func() -> void:
		(pop["dim"] as Control).queue_free()
	(pop["close"] as Button).pressed.connect(close_pop)
	(pop["btn2"] as Button).pressed.connect(func() -> void:
		close_pop.call()
		invite_chosen.emit(player))
	(pop["btn4"] as Button).pressed.connect(func() -> void:
		close_pop.call()
		var pid := String(player.get("id", ""))
		_selected_4p[pid] = player
		set_players(_players))

## The saved session expired and its refresh failed — the player must
## sign in again. Shows that plainly instead of the silent empty list
## (which looks identical to "nobody is online"). The random buttons
## still work — only the live player list needs a session.
func set_session_expired() -> void:
	_players = []
	_refresh_accum = 0.0
	if _list_box == null:
		return
	for c in _list_box.get_children():
		c.queue_free()
	_status_label.text = "Your sign-in expired — sign in again to see who is online."
	# Same overflow rule as the empty state: wrap, don't widen.
	var note := UiKit.muted_label("Your saved sign-in could not be restored. Sign in again with your Gmail, then come back here — the random buttons below still work.", 18)
	note.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	_list_box.add_child(note)

## Rebuild the player list. Rows show name + level + status ONLY.
func set_players(players: Array) -> void:
	_players = players
	_refresh_accum = 0.0
	if _list_box == null:
		return
	for c in _list_box.get_children():
		c.queue_free()
	if players.is_empty():
		_status_label.text = "No players online right now — try a random opponent below."
		# Same overflow fix as the intro label: wrap, don't widen.
		var empty_lbl := UiKit.muted_label("Nobody else is online at this moment. Random matchmaking still works — the queue finds players as they come online.", 18)
		empty_lbl.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
		_list_box.add_child(empty_lbl)
	else:
		_status_label.text = "%d player(s) online now — tap INVITE to play together." % players.size()
	for player in players:
		var pid := String(player.get("id", ""))
		var card := PanelContainer.new()
		card.add_theme_stylebox_override("panel", UiKit.panel_style(UiKit.PANEL, Color(0.83, 0.69, 0.22, 0.35), 12, 1))
		_list_box.add_child(card)
		var row := HBoxContainer.new()
		row.add_theme_constant_override("separation", 10)
		card.add_child(row)
		var status := String(player.get("status", "online"))
		var label := UiKit.body_label("%s  •  Lv %d  •  %s" % [
			String(player.get("display_name", "Player")),
			int(player.get("level", 1)),
			"In a match" if status == "in_match" else "Online"], 20)
		label.size_flags_horizontal = Control.SIZE_EXPAND_FILL
		row.add_child(label)
		var selected := _selected_4p.has(pid)
		var sel := UiKit.dark_button("4P ✓" if selected else "4P", 18)
		sel.custom_minimum_size = Vector2(76, 0)
		sel.pressed.connect(func() -> void:
			if _selected_4p.has(pid):
				_selected_4p.erase(pid)
			elif _selected_4p.size() < Friends.MAX_GROUP_TARGETS:
				_selected_4p[pid] = player
			set_players(_players))
		row.add_child(sel)
		var inv := UiKit.gold_button("INVITE", 20)
		inv.pressed.connect(func() -> void: _show_count_choice(player))
		row.add_child(inv)
	if not _selected_4p.is_empty():
		# 3-player guard (v11): exactly 2 picks can never send — the
		# button is disabled and says so (same rule as the home box).
		var n := _selected_4p.size()
		_send4_button = UiKit.gold_button("SEND 4-PLAYER INVITE (%d)" % n, 20)
		if n == 2:
			_send4_button.disabled = true
			_send4_button.text = "PICK 1 MORE FRIEND (OR REMOVE 1)"
		_send4_button.pressed.connect(func() -> void:
			var picked: Array = []
			for p in _selected_4p.values():
				picked.append(p)
			_selected_4p.clear()
			group_invite_chosen.emit(picked))
		_list_box.add_child(_send4_button)
		var note := "Doubles — you + 3 friends. Matches are 2 or 4 players only."
		if n == 2:
			note = "Pick 1 more friend for doubles (3 total), or remove 1 — a 3-player match is not supported."
		elif n == 1:
			note = "Pick 2 more friends for doubles — or tap INVITE on one friend for a 1 vs 1 match."
		_list_box.add_child(UiKit.body_label(note, 16))
