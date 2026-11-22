class_name MatchScreen
extends Node2D

## The match scene: board + physics + rules + turns + AI + HUD + result.
## Local player is always the bottom seat (seat 0); the opponent is the top
## seat (seat 1). Rules player index == seat index; the breaker plays white.

signal exit_to_home
signal rematch_requested

class Dots:
	extends Control
	var filled := 0
	var total := 9
	var color := Color(0.94, 0.92, 0.86)
	func _draw() -> void:
		for i in range(total):
			var x := 12.0 + float(i) * 21.0
			var c := color if i < filled else Color(1, 1, 1, 0.18)
			draw_circle(Vector2(x, 11), 7.5, c)
			draw_arc(Vector2(x, 11), 7.5, 0, TAU, 16, Color(0, 0, 0, 0.4), 1.5)

var mode := "solo" # solo | online
var difficulty := 1 # 0 Easy, 1 Medium, 2 Hard
var table := 0 # online entry index: 0 Low 100, 1 Mid 500, 2 High 2000
var opponent_name := "Computer"
var opponent_level := 1
var net: NetClient = null

var pieces: Array = []
var rules_state: Dictionary = {}
var board_view: BoardView
var phase := "place" # place | shooting | over
var local_seat := 0
var is_break := true
var break_misses := 0
var turn_time_left := 20.0
var turn_time_max := 20.0
var timeouts_in_a_row := 0
var remote_timeouts := 0
var local_covered_queen := false
var result_shown := false
var entry_paid := false

var _striker = null
var _dragging := false
var _drag_mode := ""
var _press_pos := Vector2.ZERO
var _aim_dir := Vector2.UP
var _aim_power := 0.0
var _shot_pocketed: Array = []
var _shot_striker_pocketed := false
var _shot_start_pos := {}
var _ai_wait := 0.0
var _ai_shot := {}
var _ai_stage := 0
var _accum := 0.0
var _prev_striker_vel := Vector2.ZERO
var _msg_timer := 0.0

# HUD nodes.
var _hud: CanvasLayer
var _opp_dots: Dots
var _my_dots: Dots
var _turn_label: Label
var _msg_label: Label
var _timer_bar: ProgressBar
var _power_bar: ProgressBar
var _assist_chip: Label
var _opp_panel: PanelContainer
var _my_panel: PanelContainer

var _breaker_override := -1

func setup(p_mode: String, p_difficulty: int, p_table: int, p_opp_name: String, p_opp_level: int, p_net: NetClient, p_breaker: int = -1) -> void:
	mode = p_mode
	difficulty = p_difficulty
	table = p_table
	opponent_name = p_opp_name
	opponent_level = p_opp_level
	net = p_net
	_breaker_override = p_breaker

func _ready() -> void:
	randomize()
	_build_hud()
	board_view = BoardView.new()
	board_view.board_id = Save.equipped_board
	board_view.striker_id = Save.equipped_striker
	board_view.aim_mode = Save.aim_guide
	add_child(board_view)
	# Place the board behind the HUD.
	move_child(board_view, 0)
	pieces = CarromPhysics.setup_pieces()
	_striker = _find_piece("striker")
	var breaker := _breaker_override if _breaker_override >= 0 else randi() % 2
	rules_state = CarromRules.fresh_state(breaker)
	board_view.pieces = pieces
	_place_striker_for_turn()
	turn_time_max = _shot_time()
	turn_time_left = turn_time_max
	_update_hud()
	_show_message("Breaker plays WHITE" if breaker == 0 else "Opponent breaks — plays WHITE", 2.5)
	if mode == "online" and entry_paid == false:
		entry_paid = true
		# Entry fee is deducted when the match starts; the winner takes the pot.
		Save.spend_coins(Save.ONLINE_ENTRY[table])
	if net:
		net.shot_received.connect(_on_remote_shot)
		net.state_received.connect(_on_remote_state)
		net.opponent_left.connect(_on_opponent_left)

func _shot_time() -> float:
	var t := ShopData.shot_time(Save.equipped_striker)
	if Save.aim_assist_active():
		t += 5.0
	return t

func _find_piece(kind: String):
	for p in pieces:
		if p["kind"] == kind:
			return p
	return null

func _place_striker_for_turn() -> void:
	var seat: int = rules_state["turn"]
	_striker["active"] = true
	_striker["vel"] = Vector2.ZERO
	_striker["pos"] = Vector2(CarromPhysics.BOARD_CENTER.x, CarromPhysics.baseline_y(seat))
	board_view.aim_visible = false

func _is_local_turn() -> bool:
	return int(rules_state["turn"]) == local_seat and phase == "place"

# ------------------------------------------------------------------- input

func _unhandled_input(event: InputEvent) -> void:
	if phase != "place" or not _is_local_turn():
		return
	var pos := Vector2.ZERO
	var pressed := false
	var released := false
	var dragged := false
	if event is InputEventScreenTouch:
		pos = event.position
		pressed = event.pressed
		released = not event.pressed
	elif event is InputEventScreenDrag:
		pos = event.position
		dragged = true
	elif event is InputEventMouseButton and event.button_index == MOUSE_BUTTON_LEFT:
		pos = event.position
		pressed = event.pressed
		released = not event.pressed
	elif event is InputEventMouseMotion and event.button_mask & MOUSE_BUTTON_MASK_LEFT:
		pos = event.position
		dragged = true
	if pressed:
		if _striker["active"] and pos.distance_to(_striker["pos"]) < 70.0:
			_dragging = true
			_drag_mode = ""
			_press_pos = pos
		elif _striker["active"] and absf(pos.y - CarromPhysics.baseline_y(local_seat)) < 55.0 and absf(pos.x - CarromPhysics.BOARD_CENTER.x) <= CarromPhysics.BASELINE_HALF_LEN + 40.0:
			# Forgiving grab (v2): touching the baseline anywhere starts a
			# slide, so the striker is easy to move on a phone.
			_dragging = true
			_drag_mode = "slide"
			_press_pos = pos
	elif dragged and _dragging:
		_handle_drag(pos)
	elif released and _dragging:
		_dragging = false
		if _drag_mode == "aim" and _aim_power >= 0.08:
			_shoot(_aim_dir, _aim_power, true)
		board_view.aim_visible = false
		board_view.pocket_glow = -1
		_power_bar.visible = false

func _handle_drag(pos: Vector2) -> void:
	var delta := pos - _press_pos
	if _drag_mode == "":
		if absf(delta.x) > 10.0 and absf(delta.x) > absf(delta.y):
			_drag_mode = "slide"
		elif absf(delta.y) > 10.0:
			_drag_mode = "aim"
	if _drag_mode == "slide":
		var cx := CarromPhysics.BOARD_CENTER.x
		_striker["pos"].x = clampf(pos.x, cx - CarromPhysics.BASELINE_HALF_LEN, cx + CarromPhysics.BASELINE_HALF_LEN)
		_striker["pos"].y = CarromPhysics.baseline_y(local_seat)
	elif _drag_mode == "aim":
		var pull: Vector2 = _striker["pos"] - pos
		if pull.length() < 12.0:
			board_view.aim_visible = false
			_power_bar.visible = false
			return
		var dir := pull.normalized()
		# Local seat is the bottom: aim must point up the board.
		if dir.y > -0.05:
			return
		_aim_dir = dir
		_aim_power = clampf(pull.length() / 280.0, 0.0, 1.0)
		board_view.aim_visible = true
		board_view.aim_from = _striker["pos"]
		board_view.aim_dir = dir
		board_view.aim_power = _aim_power
		board_view.aim_assist = Save.aim_assist_active()
		board_view.pocket_glow = _lined_up_pocket(dir)
		_power_bar.visible = true
		_power_bar.value = _aim_power * 100.0

func _lined_up_pocket(dir: Vector2) -> int:
	# Deflection preview: does the first coin hit send a coin near a pocket?
	var from: Vector2 = _striker["pos"]
	var best_t := 1200.0
	var hit_coin = null
	for p in pieces:
		if not p["active"] or p["kind"] == "striker":
			continue
		var t := CarromPhysics.ray_circle(from, dir, p["pos"], p["r"] + CarromPhysics.STRIKER_R)
		if t >= 0.0 and t < best_t:
			best_t = t
			hit_coin = p
	if hit_coin == null:
		return -1
	var defl: Vector2 = (hit_coin["pos"] - from).normalized()
	var pockets := CarromPhysics.pocket_centers()
	for i in range(pockets.size()):
		var to_pocket: Vector2 = pockets[i] - hit_coin["pos"]
		var along := to_pocket.dot(defl)
		if along < 0.0:
			continue
		var perp := (to_pocket - defl * along).length()
		if perp < 30.0:
			return i
	return -1

# ---------------------------------------------------------------- shooting

func _shoot(dir: Vector2, power: float, by_local: bool) -> void:
	if phase != "place":
		return
	phase = "shooting"
	_striker["vel"] = dir * power * ShopData.max_speed(Save.equipped_striker)
	_shot_pocketed.clear()
	_shot_striker_pocketed = false
	_shot_start_pos.clear()
	for i in range(pieces.size()):
		_shot_start_pos[i] = pieces[i]["pos"]
	_prev_striker_vel = _striker["vel"]
	Sfx.click(power)
	if by_local and net:
		net.send_shot({"sx": _striker["pos"].x, "dx": dir.x, "dy": dir.y, "power": power})

func _physics_process(delta: float) -> void:
	if phase != "shooting":
		return
	_accum += delta
	while _accum >= CarromPhysics.FIXED_DT:
		_accum -= CarromPhysics.FIXED_DT
		var hit := CarromPhysics.step(pieces, CarromPhysics.FIXED_DT)
		for p in hit:
			_on_piece_pocketed(p)
		# Cushion click: striker velocity flipped on an axis.
		var v: Vector2 = _striker["vel"]
		if (v.x > 0.0) != (_prev_striker_vel.x > 0.0) and absf(v.x) > 60.0:
			Sfx.cushion()
		elif (v.y > 0.0) != (_prev_striker_vel.y > 0.0) and absf(v.y) > 60.0:
			Sfx.cushion()
		_prev_striker_vel = v
	if CarromPhysics.all_stopped(pieces):
		phase = "settling"
		_resolve_shot()

func _on_piece_pocketed(p: Dictionary) -> void:
	_shot_pocketed.append(p)
	var col := Color(0.94, 0.92, 0.86)
	if p["kind"] == "black":
		col = Color(0.2, 0.2, 0.22)
	elif p["kind"] == "queen":
		col = Color(0.85, 0.15, 0.2)
	elif p["kind"] == "striker":
		col = Color(0.85, 0.68, 0.25)
		_shot_striker_pocketed = true
	board_view.spawn_puff(p["pos"], col)
	Sfx.pocket()

func _free_spot_near(pos: Vector2) -> Vector2:
	var offsets := [Vector2.ZERO, Vector2(30, 0), Vector2(-30, 0), Vector2(0, 30), Vector2(0, -30),
		Vector2(30, 30), Vector2(-30, -30), Vector2(30, -30), Vector2(-30, 30), Vector2(60, 0), Vector2(-60, 0)]
	for off in offsets:
		var off_v: Vector2 = off
		var cand: Vector2 = pos + off_v
		var ok := true
		for p in pieces:
			if p["active"] and cand.distance_to(p["pos"]) < 30.0:
				ok = false
				break
		if ok:
			return cand
	return pos + Vector2(90, 0)

func _reactivate(kind: String, near: Vector2) -> void:
	for p in pieces:
		if not p["active"] and p["kind"] == kind:
			p["active"] = true
			p["vel"] = Vector2.ZERO
			p["pos"] = _free_spot_near(near)
			return

func _resolve_shot() -> void:
	var kinds: Array = []
	for p in _shot_pocketed:
		kinds.append(p["kind"])
	# Break contact check: did the striker touch any coin?
	if is_break:
		var touched := false
		for i in range(pieces.size()):
			var p: Dictionary = pieces[i]
			if p["kind"] != "striker" and p["active"]:
				if (p["pos"] as Vector2).distance_to(_shot_start_pos.get(i, p["pos"])) > 3.0:
					touched = true
					break
		if not touched and kinds.is_empty() and not _shot_striker_pocketed:
			break_misses += 1
			_show_message("Break missed — striker touched nothing (%d/3)" % break_misses, 2.0)
			if break_misses >= 3:
				_show_message("3 missed breaks — opponent breaks", 2.5)
		else:
			is_break = false
	var shooter: int = rules_state["turn"]
	var res: Dictionary = CarromRules.resolve_shot(rules_state, kinds, _shot_striker_pocketed)
	_apply_events(res["events"], shooter)
	_update_hud()
	if bool(rules_state["over"]):
		_show_result()
		return
	phase = "place"
	_place_striker_for_turn()
	turn_time_max = _shot_time()
	turn_time_left = turn_time_max
	timeouts_in_a_row = 0
	if net:
		net.send_state(_serialize_state())

func _apply_events(events: Array, shooter: int) -> void:
	var own := CarromRules.own_color(rules_state, shooter)
	for e in events:
		match e["type"]:
			"queen_pocketed":
				_show_message("QUEEN pocketed! Cover her next shot.", 2.5)
				Sfx.pocket()
			"queen_covered":
				_show_message("Queen COVERED! +3 points.", 2.5)
				if shooter == local_seat:
					local_covered_queen = true
					Save.queens_covered += 1
			"queen_early":
				_show_message("Queen too early — back to the centre.", 2.5)
				_reactivate("queen", CarromPhysics.BOARD_CENTER)
			"queen_returned":
				_show_message("Queen NOT covered — back to the centre.", 2.5)
				_reactivate("queen", CarromPhysics.BOARD_CENTER)
			"foul_striker":
				_show_message("FOUL! Striker pocketed.", 2.5)
				Sfx.foul()
			"coins_returned":
				for i in range(int(e["count"])):
					_reactivate(own, CarromPhysics.BOARD_CENTER)
				_show_message("%d coin(s) returned (foul)." % int(e["count"]), 2.0)
			"due_paid":
				_reactivate(own, CarromPhysics.BOARD_CENTER)
			"opp_pocketed":
				_show_message("Opponent's coin pocketed — helps them!", 2.0)
			"turn_kept":
				pass
			"turn_passed":
				pass

func _serialize_state() -> Dictionary:
	var arr: Array = []
	for p in pieces:
		arr.append({"kind": p["kind"], "x": p["pos"].x, "y": p["pos"].y, "active": p["active"]})
	return {"pieces": arr, "rules": rules_state.duplicate(true), "is_break": is_break}

func _on_remote_shot(data: Dictionary) -> void:
	if phase != "place" or int(rules_state["turn"]) == local_seat:
		return
	_striker["pos"] = Vector2(float(data["sx"]), CarromPhysics.baseline_y(1 - local_seat))
	_shoot(Vector2(float(data["dx"]), float(data["dy"])), float(data["power"]), false)

func _on_remote_state(data: Dictionary) -> void:
	if phase == "shooting":
		return
	for i in range(mini(data["pieces"].size(), pieces.size())):
		var sp: Dictionary = data["pieces"][i]
		pieces[i]["pos"] = Vector2(float(sp["x"]), float(sp["y"]))
		pieces[i]["active"] = bool(sp["active"])
	rules_state = data["rules"]
	is_break = bool(data["is_break"])
	_place_striker_for_turn()
	turn_time_max = _shot_time()
	turn_time_left = turn_time_max
	_update_hud()

func _on_opponent_left() -> void:
	if result_shown:
		return
	_show_message("Opponent left — you win!", 2.5)
	rules_state["over"] = true
	rules_state["winner"] = local_seat
	_show_result()

# ---------------------------------------------------------------------- AI

func _process(delta: float) -> void:
	if _msg_timer > 0.0:
		_msg_timer -= delta
		if _msg_timer <= 0.0:
			_msg_label.visible = false
	if phase == "place" and not result_shown:
		# Turn timer (local player only in solo; both seats online).
		if mode == "solo":
			if int(rules_state["turn"]) == local_seat:
				_tick_timer(delta)
		else:
			_tick_timer(delta)
		# AI move.
		if mode == "solo" and int(rules_state["turn"]) != local_seat:
			_run_ai(delta)
	_update_timer_bar()

func _tick_timer(delta: float) -> void:
	turn_time_left -= delta
	if turn_time_left <= 0.0:
		turn_time_left = turn_time_max
		if int(rules_state["turn"]) == local_seat:
			timeouts_in_a_row += 1
			_show_message("Time out! Turn passes.", 2.0)
			if mode == "online" and timeouts_in_a_row >= 2:
				_show_message("2 time-outs — you forfeit.", 2.5)
				rules_state["over"] = true
				rules_state["winner"] = 1 - local_seat
				_show_result()
				return
		else:
			remote_timeouts += 1
			_show_message("Opponent timed out.", 2.0)
			if mode == "online" and remote_timeouts >= 2:
				rules_state["over"] = true
				rules_state["winner"] = local_seat
				_show_result()
				return
		# Missed shot: resolve an empty stroke.
		_shot_pocketed.clear()
		_shot_striker_pocketed = false
		phase = "settling"
		_resolve_shot()

func _run_ai(delta: float) -> void:
	if _ai_stage == 0:
		_ai_wait += delta
		if _ai_wait >= 0.9:
			_ai_wait = 0.0
			var own := CarromRules.own_color(rules_state, 1 - local_seat)
			_ai_shot = CarromAI.choose_shot(pieces, own, difficulty, rules_state, is_break)
			_ai_stage = 1
	elif _ai_stage == 1:
		# Slide the striker to the chosen x, then shoot.
		var target_x: float = _ai_shot["striker_x"]
		_striker["pos"].x = move_toward(_striker["pos"].x, target_x, 900.0 * delta)
		if absf(_striker["pos"].x - target_x) < 2.0:
			_ai_stage = 0
			_shoot(_ai_shot["dir"], _ai_shot["power"], false)

func _update_timer_bar() -> void:
	if phase == "place" and not result_shown:
		_timer_bar.visible = true
		_timer_bar.max_value = turn_time_max
		_timer_bar.value = turn_time_left
	else:
		_timer_bar.visible = false

# -------------------------------------------------------------------- result

func _show_result() -> void:
	if result_shown:
		return
	result_shown = true
	phase = "over"
	var winner: int = rules_state["winner"]
	var won := winner == local_seat
	Sfx.win() if won else Sfx.foul()
	# Economy.
	var coins_earned := 0
	var lines: Array = []
	if mode == "solo":
		coins_earned = Save.SOLO_WIN_COINS[difficulty] if won else Save.SOLO_LOSS_COINS
		lines.append("Solo %s: %+d coins" % ["win" if won else "loss", coins_earned])
		if won:
			Save.solo_wins += 1
	else:
		var entry: int = Save.ONLINE_ENTRY[table]
		if won:
			coins_earned = entry * 2 # pot: both entries (entry was deducted at start)
			lines.append("Online win — pot: +%d coins" % coins_earned)
			Save.online_wins += 1
		else:
			coins_earned = 0
			lines.append("Online loss — entry %d coins" % entry)
	if won and local_covered_queen:
		coins_earned += Save.QUEEN_BONUS_COINS
		lines.append("Queen bonus: +%d coins" % Save.QUEEN_BONUS_COINS)
	if won and Save.aim_guide == "off":
		coins_earned += Save.GUIDE_OFF_WIN_BONUS
		lines.append("No-guide bonus: +%d coins" % Save.GUIDE_OFF_WIN_BONUS)
	var xp_earned := Save.XP_PER_MATCH + (Save.XP_PER_WIN if won else 0) + (Save.XP_PER_QUEEN if local_covered_queen else 0)
	var level_bonus := Save.add_xp(xp_earned)
	Save.add_coins(coins_earned)
	Save.matches_played += 1
	if won:
		Save.matches_won += 1
	Save.interstitial_counter += 1
	Save.save()
	lines.append("XP: +%d" % xp_earned)
	if level_bonus > 0:
		lines.append("LEVEL UP! +%d coins (now Lv %d · %s)" % [level_bonus, Save.level(), Save.rank_name()])
	lines.append("Board score: %d" % CarromRules.board_score(rules_state, winner))
	if rules_state.get("lose_reason", "") != "":
		lines.append("Reason: %s" % String(rules_state["lose_reason"]).replace("_", " "))
	# Interstitial policy: only after every 3rd match.
	var show_ad := Save.interstitial_counter % AdsConfig.INTERSTITIAL_EVERY_N_MATCHES == 0
	# Build the result popup.
	var pop: Dictionary = UiKit.popup_window("YOU WIN!" if won else "YOU LOSE", Vector2(560, 560))
	_hud.add_child(pop["dim"])
	var box: VBoxContainer = pop["box"]
	box.add_child(UiKit.body_label("\n".join(lines), 24))
	var again := UiKit.gold_button("REMATCH" if mode == "solo" else "FIND REMATCH", 28)
	var home := UiKit.dark_button("HOME", 26)
	box.add_child(again)
	box.add_child(home)
	pop["close"].pressed.connect(func() -> void: exit_to_home.emit())
	home.pressed.connect(func() -> void: exit_to_home.emit())
	again.pressed.connect(func() -> void: rematch_requested.emit())
	if show_ad:
		Ads.maybe_show_interstitial()

# ---------------------------------------------------------------------- HUD

func _build_hud() -> void:
	_hud = CanvasLayer.new()
	add_child(_hud)
	var root := Control.new()
	UiKit.full_rect(root)
	root.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_hud.add_child(root)
	# Every non-interactive HUD piece must be IGNORE too (v2): a STOP panel
	# or label over the board would eat the drag before _unhandled_input.
	# Only the pause Button stays interactive (default STOP).
	# Opponent panel (top).
	_opp_panel = PanelContainer.new()
	_opp_panel.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_opp_panel.add_theme_stylebox_override("panel", UiKit.panel_style())
	_opp_panel.set_anchors_preset(Control.PRESET_TOP_WIDE)
	_opp_panel.offset_left = 16
	_opp_panel.offset_right = -16
	_opp_panel.offset_top = 12
	_opp_panel.offset_bottom = 108
	root.add_child(_opp_panel)
	var opp_box := VBoxContainer.new()
	opp_box.name = "OppBox"
	_opp_panel.add_child(opp_box)
	var opp_top := HBoxContainer.new()
	opp_top.name = "OppTop"
	var opp_name := Label.new()
	opp_name.text = "Opponent"
	opp_name.name = "OppName"
	opp_name.add_theme_font_size_override("font_size", 24)
	opp_name.add_theme_color_override("font_color", UiKit.TEXT)
	opp_top.add_child(opp_name)
	var opp_lv := Label.new()
	opp_lv.text = "Lv 1"
	opp_lv.name = "OppLevel"
	opp_lv.add_theme_font_size_override("font_size", 20)
	opp_lv.add_theme_color_override("font_color", UiKit.GOLD_LIGHT)
	opp_top.add_child(opp_lv)
	opp_box.add_child(opp_top)
	_opp_dots = Dots.new()
	_opp_dots.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_opp_dots.color = Color(0.15, 0.15, 0.17)
	_opp_dots.custom_minimum_size = Vector2(200, 24)
	opp_box.add_child(_opp_dots)
	# Turn label.
	_turn_label = Label.new()
	_turn_label.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_turn_label.add_theme_font_size_override("font_size", 26)
	_turn_label.add_theme_color_override("font_color", UiKit.GOLD_LIGHT)
	_turn_label.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	_turn_label.set_anchors_preset(Control.PRESET_CENTER_TOP)
	_turn_label.offset_top = 118
	_turn_label.offset_left = -200
	_turn_label.offset_right = 200
	root.add_child(_turn_label)
	# Timer bar.
	_timer_bar = ProgressBar.new()
	_timer_bar.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_timer_bar.min_value = 0
	_timer_bar.max_value = 20
	_timer_bar.show_percentage = false
	_timer_bar.set_anchors_preset(Control.PRESET_CENTER_TOP)
	_timer_bar.offset_top = 158
	_timer_bar.offset_left = -140
	_timer_bar.offset_right = 140
	_timer_bar.offset_bottom = 172
	_timer_bar.add_theme_stylebox_override("background", UiKit.panel_style(Color(0, 0, 0, 0.5), Color(0, 0, 0, 0), 6, 0))
	var fill := StyleBoxFlat.new()
	fill.bg_color = UiKit.GOLD
	fill.set_corner_radius_all(6)
	_timer_bar.add_theme_stylebox_override("fill", fill)
	root.add_child(_timer_bar)
	# Aim-assist chip.
	_assist_chip = Label.new()
	_assist_chip.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_assist_chip.add_theme_font_size_override("font_size", 18)
	_assist_chip.add_theme_color_override("font_color", Color(0.4, 0.9, 0.5))
	_assist_chip.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	_assist_chip.set_anchors_preset(Control.PRESET_CENTER_TOP)
	_assist_chip.offset_top = 178
	_assist_chip.offset_left = -200
	_assist_chip.offset_right = 200
	root.add_child(_assist_chip)
	# Message label (centre of board).
	_msg_label = Label.new()
	_msg_label.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_msg_label.add_theme_font_size_override("font_size", 28)
	_msg_label.add_theme_color_override("font_color", Color(1, 0.9, 0.5))
	_msg_label.add_theme_color_override("font_shadow_color", Color(0, 0, 0, 0.9))
	_msg_label.add_theme_constant_override("shadow_offset_x", 2)
	_msg_label.add_theme_constant_override("shadow_offset_y", 2)
	_msg_label.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	_msg_label.set_anchors_preset(Control.PRESET_CENTER)
	_msg_label.offset_top = -300
	_msg_label.offset_bottom = -240
	_msg_label.offset_left = -340
	_msg_label.offset_right = 340
	_msg_label.visible = false
	root.add_child(_msg_label)
	# Power meter (horizontal, just above the bottom panel, while aiming).
	_power_bar = ProgressBar.new()
	_power_bar.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_power_bar.min_value = 0
	_power_bar.max_value = 100
	_power_bar.show_percentage = false
	_power_bar.set_anchors_preset(Control.PRESET_BOTTOM_WIDE)
	_power_bar.offset_left = 120
	_power_bar.offset_right = -120
	_power_bar.offset_top = -196
	_power_bar.offset_bottom = -182
	_power_bar.visible = false
	var pfill := StyleBoxFlat.new()
	pfill.bg_color = Color(0.3, 0.9, 0.4)
	pfill.set_corner_radius_all(8)
	_power_bar.add_theme_stylebox_override("fill", pfill)
	_power_bar.add_theme_stylebox_override("background", UiKit.panel_style(Color(0, 0, 0, 0.5), Color(0, 0, 0, 0), 8, 0))
	root.add_child(_power_bar)
	# My panel (bottom).
	_my_panel = PanelContainer.new()
	_my_panel.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_my_panel.add_theme_stylebox_override("panel", UiKit.panel_style())
	_my_panel.set_anchors_preset(Control.PRESET_BOTTOM_WIDE)
	_my_panel.offset_left = 16
	_my_panel.offset_right = -16
	_my_panel.offset_top = -176
	_my_panel.offset_bottom = -16
	root.add_child(_my_panel)
	var my_box := VBoxContainer.new()
	_my_panel.add_child(my_box)
	var my_top := HBoxContainer.new()
	var my_name := Label.new()
	my_name.text = Save.player_name + " (YOU)"
	my_name.add_theme_font_size_override("font_size", 24)
	my_name.add_theme_color_override("font_color", UiKit.TEXT)
	my_top.add_child(my_name)
	var my_lv := Label.new()
	my_lv.text = "Lv %d · %s" % [Save.level(), Save.rank_name()]
	my_lv.add_theme_font_size_override("font_size", 20)
	my_lv.add_theme_color_override("font_color", UiKit.GOLD_LIGHT)
	my_top.add_child(my_lv)
	var pause := UiKit.dark_button("II", 22)
	pause.custom_minimum_size = Vector2(56, 44)
	pause.pressed.connect(_on_pause_pressed)
	my_top.add_child(pause)
	my_box.add_child(my_top)
	_my_dots = Dots.new()
	_my_dots.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_my_dots.color = Color(0.94, 0.92, 0.86)
	_my_dots.custom_minimum_size = Vector2(200, 24)
	my_box.add_child(_my_dots)
	var hint := UiKit.muted_label("Drag the striker sideways to slide • Pull back to aim • Release to shoot", 16)
	my_box.add_child(hint)

func _on_pause_pressed() -> void:
	if phase == "over":
		return
	var pop: Dictionary = UiKit.popup_window("PAUSED", Vector2(480, 380))
	_hud.add_child(pop["dim"])
	var box: VBoxContainer = pop["box"]
	var resume := UiKit.gold_button("RESUME", 28)
	var sound := UiKit.dark_button("SOUND: ON" if Save.sound_on else "SOUND: OFF", 24)
	var forfeit := UiKit.dark_button("FORFEIT MATCH", 24)
	box.add_child(resume)
	box.add_child(sound)
	box.add_child(forfeit)
	resume.pressed.connect(func() -> void: pop["dim"].queue_free())
	sound.pressed.connect(func() -> void:
		Save.sound_on = not Save.sound_on
		Sfx.set_enabled(Save.sound_on)
		Save.save()
		sound.text = "SOUND: ON" if Save.sound_on else "SOUND: OFF")
	forfeit.pressed.connect(func() -> void:
		pop["dim"].queue_free()
		if mode == "online" and net:
			net.send_forfeit()
		rules_state["over"] = true
		rules_state["winner"] = 1 - local_seat
		_show_result())
	pop["close"].pressed.connect(func() -> void: pop["dim"].queue_free())

func _show_message(text: String, seconds: float) -> void:
	_msg_label.text = text
	_msg_label.visible = true
	_msg_timer = seconds

func _update_hud() -> void:
	var opp_panel_name: Label = _opp_panel.get_node("OppBox/OppTop/OppName")
	opp_panel_name.text = opponent_name
	var opp_lv: Label = _opp_panel.get_node("OppBox/OppTop/OppLevel")
	opp_lv.text = "Lv %d" % opponent_level
	var my_color := CarromRules.own_color(rules_state, local_seat)
	var opp_color := CarromRules.opp_color(rules_state, local_seat)
	# Dots show pocketed coins of each seat's colour.
	_opp_dots.filled = int(rules_state["pocketed"][1 - local_seat])
	_opp_dots.color = Color(0.15, 0.15, 0.17) if opp_color == "black" else Color(0.94, 0.92, 0.86)
	_my_dots.filled = int(rules_state["pocketed"][local_seat])
	_my_dots.color = Color(0.15, 0.15, 0.17) if my_color == "black" else Color(0.94, 0.92, 0.86)
	_opp_dots.queue_redraw()
	_my_dots.queue_redraw()
	_turn_label.text = "YOUR TURN — %s" % my_color.to_upper() if int(rules_state["turn"]) == local_seat else "OPPONENT'S TURN — %s" % opp_color.to_upper()
	_turn_label.add_theme_color_override("font_color", UiKit.GOLD_LIGHT if int(rules_state["turn"]) == local_seat else UiKit.MUTED)
	# Glowing orange halo around the striker on your turn (Carrom Pool look).
	if board_view != null:
		board_view.your_turn = int(rules_state["turn"]) == local_seat
	if Save.aim_assist_active():
		var left := Save.aim_assist_remaining_sec()
		_assist_chip.text = "✦ AIM-ASSIST %02d:%02d" % [left / 60, left % 60]
		_assist_chip.visible = true
	else:
		_assist_chip.visible = false
