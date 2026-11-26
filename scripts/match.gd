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

var mode := "solo" # solo | online | tour (v8 World Tour: staked bot match)
var difficulty := 1 # 0 Easy, 1 Medium, 2 Hard, 3 Advanced, 4 Expert, 5 Master
var table := 0 # online matchmaking band (from Stakes.band_for_stake): 0 <250, 1 <1000, 2 >=1000
var your_stake := 0 # online: own stake, locked (deducted) at match start
var opp_stake := 0 # online 2p: opponent's stake, from the server's matched message
# F13 Phase 2 (v11): true when the server verified both stakes and put
# them in the matched payload (verified_stakes=true) — the pot then
# uses ONLY the server-sent stakes, never the claimed ones. False for
# LAN / bot / tour / solo and old servers (local Stakes math applies).
var stakes_verified := false
var practice := false # true for the labelled BOT fallback match (zero coins)
var opponent_name := "Computer"
var opponent_level := 1
var net: NetClient = null
# 4-player doubles (v6): player_count 2 = singles, 4 = doubles.
# players4 is seat-ordered [{name, level, stake, seat}]; stakes4 is the
# four stakes in seat order. Teams: seats 0,2 vs 1,3 (partners opposite).
var player_count := 2
var players4: Array = []
var stakes4: Array = []
# Win-pot hold (v6 premium win screen): an online win does NOT credit
# the pot immediately — the player COLLECTs it, or watches 2 ads to
# DOUBLE it. Closing the screen without collecting credits the base pot
# (coins are never lost). _pot_pending is the base pot; _pot_credited
# guards against double-credit; _double_ads counts the doubling ads.
var _pot_pending := 0
var _pot_credited := false
var _double_ads := 0
var _double_button: Button = null
var _double_label: Label = null
var _double_amount_label: Label = null # v11: "DOUBLE TO ◉ N" line, so a
	# late server settlement can re-price the double offer.
# F13 Phase 2 (v11): the server's authoritative settlement for this
# match, when one arrives. -1 = none yet (offline / LAN / old server /
# not settled). Stored when it arrives before the result screen and
# applied in _show_result; applied live to the held pot otherwise.
var _server_settlement := -1
var _server_settlement_pot := 0
var _collect_button: Button = null
var _collect_amount_label: Label = null
var _result_pop: Dictionary = {}
# v8 solo win ad-earn: WATCH AD button on the solo win screen.
var _solo_earn_button: Button = null
var _solo_earn_label: Label = null
# v10 win screen: fireworks overlay + the pot-0 earn mode (a staked win
# with a 0 pot shows WATCH 2 ADS -> EARN instead of a bare ◉ 0 — the
# two ads pay the next two ladder steps; _earn_coins_before is the
# ad-coins counter at press time, so the final label shows the real
# amount earned even if the daily cap cuts it short).
var _fireworks: Fireworks = null
var _earn_mode := false
var _earn_coins_before := 0

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
## v11 match points (§4, per-coin formula): the LOCAL player's OWN
## pocketed coins, net of foul returns/dues — tracked shot by shot in
## _apply_events from the "own_pocketed" / "coins_returned" /
## "due_paid" events (shooter == local_seat only, so a doubles
## partner's coins never count toward MY points). _my_queen_pending
## is true while I pocketed the queen and still owe the cover — the
## +25 bonus is shown as "to come" until the cover lands, never
## counted early.
var _my_coins_pocketed := 0
var _my_queen_pending := false
var _points_label: Label = null
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
var _turn_pill: PanelContainer
var _msg_pill: PanelContainer
var _opp_avatar_label: Label
var _my_avatar_label: Label
var _opp_coins_label: Label
var _timer_bar: ProgressBar
var _power_bar: ProgressBar
# Power-bar easing target (Grok plan step 5, adapted): the drag sets
# this target directly and _process eases the visible bar toward it,
# so the bar glides instead of snapping. Aiming itself stays 1:1.
var _power_target := 0.0
var _assist_chip: Label
var _opp_panel: PanelContainer
var _my_panel: PanelContainer

var _breaker_override := -1
var _ready_done := false # F2 layer 2: true once _ready() has run — if
	# setup()/setup_4p() runs after that, the rules state/HUD/breaker
	# must be re-derived from the real config (see _rederive_after_setup).

## The breaker for this match: the server-assigned seat when setup()
## supplied one, else a local roll. The roll covers every seat in
## 4p (the old `randi() % 2` could never pick seats 2/3).
func _pick_breaker() -> int:
	if _breaker_override >= 0:
		return _breaker_override
	return randi() % player_count

func setup(p_mode: String, p_difficulty: int, p_table: int, p_opp_name: String, p_opp_level: int, p_net: NetClient, p_breaker: int = -1, p_your_stake: int = 0, p_opp_stake: int = 0, p_practice: bool = false) -> void:
	mode = p_mode
	difficulty = p_difficulty
	table = p_table
	opponent_name = p_opp_name
	opponent_level = p_opp_level
	net = p_net
	_breaker_override = p_breaker
	your_stake = p_your_stake
	opp_stake = p_opp_stake
	practice = p_practice
	_lock_entry_stake()
	# Refresh the HUD now that the opponent name/level are known —
	# _ready() built the panels with the default "Computer" before
	# setup() ran (v8 fix: the tour panel showed "Computer Lv 1").
	# F2 layer 2: if _ready() already ran, re-derive FIRST — _update_hud
	# reads team_of() off rules_state, so it must never run with a
	# stale 2-player state under a 4-player config (pocketed[2] crash).
	if _ready_done:
		_rederive_after_setup()
	else:
		_update_hud()

## 4-player doubles setup (v6): p_players is seat-ordered
## [{name, level, stake, seat}]; p_your_seat is the local player's seat;
## p_breaker_seat is the seat that breaks (their team plays white).
func setup_4p(p_players: Array, p_your_seat: int, p_breaker_seat: int, p_net: NetClient) -> void:
	mode = "online"
	player_count = 4
	players4 = p_players
	stakes4 = []
	for p in p_players:
		stakes4.append(int(p.get("stake", 0)))
	local_seat = p_your_seat
	_breaker_override = p_breaker_seat
	your_stake = int(stakes4[p_your_seat]) if p_your_seat < stakes4.size() else 0
	opp_stake = 0 # 2p field unused in 4p; the pot is Stakes.pot_4p(stakes4)
	net = p_net
	# Opponent panel header shows the partner (seat+2) — set in _update_hud.
	opponent_name = String(p_players[(p_your_seat + 2) % 4].get("name", "Partner")) + " (partner)"
	opponent_level = int(p_players[(p_your_seat + 2) % 4].get("level", 1))
	_lock_entry_stake()
	# F2 layer 2: if _ready() already ran, re-derive FIRST (it ends
	# with _update_hud) — see setup() for why the order matters.
	if _ready_done:
		_rederive_after_setup()
	else:
		_update_hud()

## F2 layer 2 / F3: setup() ran AFTER _ready(). _ready() already built
## a rules state, HUD and breaker roll from the DEFAULTS (2 players,
## solo mode, locally rolled breaker) — re-derive all three from the
## real config now, so a call site that forgot the setup-before-
## add_child order cannot silently ship 2-player rules or a
## client-rolled breaker. Safe to call at construction time only:
## no shot has been taken yet, so nothing is lost by rebuilding.
func _rederive_after_setup() -> void:
	var breaker := _pick_breaker()
	rules_state = CarromRules.fresh_state(breaker, player_count)
	_place_striker_for_turn()
	turn_time_max = _shot_time()
	turn_time_left = turn_time_max
	_show_breaker_message(breaker)
	_connect_net_signals()
	_update_hud()

## Connect the net signals (guarded: _ready() already connects them
## when setup() ran first, and a double-connect would deliver every
## remote shot twice).
func _connect_net_signals() -> void:
	if net == null:
		return
	if not net.shot_received.is_connected(_on_remote_shot):
		net.shot_received.connect(_on_remote_shot)
	if not net.state_received.is_connected(_on_remote_state):
		net.state_received.connect(_on_remote_state)
	if not net.opponent_left.is_connected(_on_opponent_left):
		net.opponent_left.connect(_on_opponent_left)

## The "X breaks" banner (4p: the breaker seat's name + their team
## plays white; 2p: breaker vs opponent). Shown by _ready() and again
## by _rederive_after_setup() when the real breaker is only known late.
func _show_breaker_message(breaker: int) -> void:
	if player_count == 4:
		var bname := String(players4[breaker].get("name", "Player")) if breaker < players4.size() else "Player"
		_show_message("%s breaks — their team plays WHITE" % bname, 2.5)
	else:
		_show_message("Breaker plays WHITE" if breaker == 0 else "Opponent breaks — plays WHITE", 2.5)

## Lock (deduct) the entry stake now that mode + stakes are known.
## Called from setup()/setup_4p() — NOT from _ready(): _ready runs at
## add_child, which main.gd calls BEFORE setup(), so in _ready the mode
## is still "" and the stake 0 and the deduction never fired. That made
## every staked match free — the winner collected the full pot without
## ever paying in (v8 fix, caught by the tour test).
## L6: entry_paid is set ONLY when the spend succeeds — marking it paid
## before spending let a failed spend play a staked match for free.
func _lock_entry_stake() -> void:
	if _is_staked_mode() and not entry_paid:
		if your_stake <= 0 or Save.spend_coins(your_stake):
			entry_paid = true

## v8: a match against a local computer opponent (solo practice or a
## World Tour bot). Both run the AI locally; only the stakes differ.
func _is_local_ai_mode() -> bool:
	return mode == "solo" or mode == "tour"

## v8: a match with coins at stake — online (real player) or World Tour
## (advanced bot mirroring the stake). Both lock the stake at match
## start, hold the pot on a win, and offer COLLECT / DOUBLE.
func _is_staked_mode() -> bool:
	return mode == "online" or mode == "tour"

func _ready() -> void:
	randomize()
	_build_hud()
	board_view = BoardView.new()
	board_view.board_id = Save.equipped_board
	board_view.striker_id = Save.equipped_striker
	board_view.aim_mode = Save.aim_guide
	# Premium wood-table backdrop behind the board (reference look).
	board_view.backdrop_texture = preload("res://art/bg_home_wood.jpg")
	add_child(board_view)
	# Place the board behind the HUD.
	move_child(board_view, 0)
	pieces = CarromPhysics.setup_pieces()
	_striker = _find_piece("striker")
	# F3: the breaker comes from setup() (server-assigned) when it ran
	# before add_child; only solo/tour/BOT matches roll locally.
	var breaker := _pick_breaker()
	rules_state = CarromRules.fresh_state(breaker, player_count)
	board_view.pieces = pieces
	_place_striker_for_turn()
	turn_time_max = _shot_time()
	turn_time_left = turn_time_max
	_update_hud()
	_show_breaker_message(breaker)
	_connect_net_signals()
	_ready_done = true
	# F11: a fresh match starts with no missed breaks.
	break_misses = 0
	# F9: recover a win pot held when the app was killed on the win
	# screen — the pot was persisted to Save, so it is never lost.
	# (Recovered here, at the next match start; the home screen does
	# not credit it, so a player who never plays again keeps it in
	# Save.pending_pot until their next match.)
	if Save.pending_pot > 0:
		var recovered := Save.pending_pot
		Save.pending_pot = 0
		Save.add_coins(recovered)
		_show_message("Recovered ◉ %d winnings from your last match!" % recovered, 3.0)

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
	# baseline_pos works for every seat (bottom/top/left/right); for
	# singles it is identical to the old baseline_y behaviour.
	_striker["pos"] = CarromPhysics.baseline_pos(seat)
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
		elif _striker["active"] and _near_baseline(pos):
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
		_power_bar.value = 0.0
		_power_target = 0.0

func _near_baseline(pos: Vector2) -> bool:
	# Is this touch on (or near) the local seat's baseline band? Bottom
	# and top seats slide along x; left and right seats slide along y.
	var base := CarromPhysics.baseline_pos(local_seat)
	if CarromPhysics.baseline_axis(local_seat) == "x":
		return absf(pos.y - base.y) < 55.0 and absf(pos.x - CarromPhysics.BOARD_CENTER.x) <= CarromPhysics.BASELINE_HALF_LEN + 40.0
	return absf(pos.x - base.x) < 55.0 and absf(pos.y - CarromPhysics.BOARD_CENTER.y) <= CarromPhysics.BASELINE_HALF_LEN + 40.0

func _handle_drag(pos: Vector2) -> void:
	var delta := pos - _press_pos
	if _drag_mode == "":
		# Bottom/top seats slide horizontally and aim vertically; left/
		# right seats slide vertically and aim horizontally.
		if CarromPhysics.baseline_axis(local_seat) == "x":
			if absf(delta.x) > 10.0 and absf(delta.x) > absf(delta.y):
				_drag_mode = "slide"
			elif absf(delta.y) > 10.0:
				_drag_mode = "aim"
		else:
			if absf(delta.y) > 10.0 and absf(delta.y) > absf(delta.x):
				_drag_mode = "slide"
			elif absf(delta.x) > 10.0:
				_drag_mode = "aim"
	if _drag_mode == "slide":
		var base := CarromPhysics.baseline_pos(local_seat)
		if CarromPhysics.baseline_axis(local_seat) == "x":
			_striker["pos"].x = clampf(pos.x, CarromPhysics.BOARD_CENTER.x - CarromPhysics.BASELINE_HALF_LEN, CarromPhysics.BOARD_CENTER.x + CarromPhysics.BASELINE_HALF_LEN)
			_striker["pos"].y = base.y
		else:
			_striker["pos"].y = clampf(pos.y, CarromPhysics.BOARD_CENTER.y - CarromPhysics.BASELINE_HALF_LEN, CarromPhysics.BOARD_CENTER.y + CarromPhysics.BASELINE_HALF_LEN)
			_striker["pos"].x = base.x
	elif _drag_mode == "aim":
		var pull: Vector2 = _striker["pos"] - pos
		if pull.length() < 12.0:
			board_view.aim_visible = false
			_power_bar.visible = false
			_power_target = 0.0
			return
		var dir := pull.normalized()
		# Aim must point into the board from your seat (up from the
		# bottom, down from the top, right from the left, left from
		# the right) — never away from it.
		if dir.dot(CarromPhysics.aim_into_board(local_seat)) <= 0.05:
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
		_power_target = _aim_power * 100.0

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
		# The shot carries the striker's position + seat so every client
		# (2p or 4p, any seat) replays it from exactly the same spot.
		net.send_shot({"sx": _striker["pos"].x, "sy": _striker["pos"].y, "seat": int(rules_state["turn"]), "dx": dir.x, "dy": dir.y, "power": power})

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
	# Puff colours follow the new coin motifs (white = sky blue,
	# black = gold, queen = red, striker = gold).
	var col := Color(0.30, 0.62, 0.95)
	if p["kind"] == "black":
		col = Color(0.96, 0.76, 0.20)
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

## Resolve one completed stroke. from_timeout = true when the turn timer
## expired with no shot taken — a timeout is NOT a shot (F11a/F4).
func _resolve_shot(from_timeout: bool = false) -> void:
	var kinds: Array = []
	for p in _shot_pocketed:
		kinds.append(p["kind"])
	# Break contact check: did the striker touch any coin? A turn
	# timeout never counts as a missed break — no shot was taken (F11a).
	var break_passed := false
	if is_break and not from_timeout:
		var touched := false
		for i in range(pieces.size()):
			var p: Dictionary = pieces[i]
			if p["kind"] != "striker" and p["active"]:
				if (p["pos"] as Vector2).distance_to(_shot_start_pos.get(i, p["pos"])) > 3.0:
					touched = true
					break
		if not touched and kinds.is_empty() and not _shot_striker_pocketed:
			break_misses += 1
			if break_misses >= 3:
				# 3 missed breaks: the break passes to the opponent and
				# the break phase ends (is_break clears) — the counter
				# resets so it can never climb to (4/3), (5/3)… (F11b).
				break_misses = 0
				is_break = false
				break_passed = true
				_show_message("3 missed breaks — break over, opponent's turn", 2.5)
			else:
				_show_message("Break missed — striker touched nothing (%d/3)" % break_misses, 2.0)
		else:
			is_break = false
			break_misses = 0
	var shooter: int = rules_state["turn"]
	var res: Dictionary = CarromRules.resolve_shot(rules_state, kinds, _shot_striker_pocketed)
	_apply_events(res["events"], shooter)
	_update_hud()
	if bool(rules_state["over"]):
		_show_result()
		return
	if break_passed:
		# The breaker really changes: force the turn to the next seat
		# even if this stroke's foul rules would have kept it.
		rules_state["turn"] = (shooter + 1) % int(rules_state.get("players", player_count))
	phase = "place"
	_place_striker_for_turn()
	turn_time_max = _shot_time()
	turn_time_left = turn_time_max
	# Timeout counters reset only on a REAL shot (F4): a timeout resolve
	# must leave them alone, so two CONSECUTIVE timeouts can reach 2 and
	# forfeit. A real shot by the remote player resets their counter, so
	# only consecutive remote timeouts forfeit the opponent.
	if not from_timeout:
		if shooter == local_seat:
			timeouts_in_a_row = 0
		else:
			remote_timeouts = 0
	if net:
		net.send_state(_serialize_state())

func _apply_events(events: Array, shooter: int) -> void:
	var own := CarromRules.own_color(rules_state, shooter)
	# v11 match points: track MY OWN pocketed coins (net). The events
	# carry the shooter, so remote shots (replayed locally) count only
	# when the shooter is me. Foul returns/dues subtract again — the
	# count is the net coins I hold at any moment, which is also what
	# rules_state pocketed[my_team] shows for singles.
	for e in events:
		if int(e.get("player", -1)) != local_seat:
			continue
		match String(e.get("type", "")):
			"own_pocketed":
				_my_coins_pocketed += int(e.get("count", 0))
			"coins_returned":
				_my_coins_pocketed = maxi(0, _my_coins_pocketed - int(e.get("count", 0)))
			"due_paid":
				_my_coins_pocketed = maxi(0, _my_coins_pocketed - 1)
	for e in events:
		match e["type"]:
			"queen_pocketed":
				_show_message("QUEEN pocketed! Cover her next shot.", 2.5)
				Sfx.pocket()
				if shooter == local_seat:
					_my_queen_pending = true
			"queen_covered":
				_show_message("Queen COVERED! +%d points." % MatchPoints.QUEEN_BONUS, 2.5)
				if shooter == local_seat:
					_my_queen_pending = false
					local_covered_queen = true
					Save.queens_covered += 1
					# Play Games: unlock "Pocket the Queen" now (native
					# toast during the match; no-ops while signed out).
					PlayGames.report_queen_covered()
			"queen_early":
				_show_message("Queen too early — back to the centre.", 2.5)
				_reactivate("queen", CarromPhysics.BOARD_CENTER)
			"queen_returned":
				_show_message("Queen NOT covered — back to the centre.", 2.5)
				if shooter == local_seat:
					_my_queen_pending = false
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
	# The sender's striker position travels with the shot (v6) — place
	# it exactly there. Old 2p messages only carry sx: fall back to the
	# opponent's baseline, as before.
	if data.has("sy"):
		_striker["pos"] = Vector2(float(data["sx"]), float(data["sy"]))
	else:
		# L7: the shooter's seat travels in the message — use its
		# full baseline (left/right seats vary in x, not y). The old
		# fallback only knew top/bottom, so a seat-2/3 shot landed
		# on the wrong side of the board.
		var shooter_seat := int(data.get("seat", 1 - local_seat))
		_striker["pos"] = CarromPhysics.baseline_pos(clampi(shooter_seat, 0, 3))
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
	# 4p: the server tells us which seat left (Net.last_opponent_left_seat).
	# If my PARTNER left, my team forfeits; if an opponent left, my team wins.
	if player_count == 4 and net != null and net.last_opponent_left_seat >= 0 and CarromRules.team_of(rules_state, net.last_opponent_left_seat) == CarromRules.team_of(rules_state, local_seat):
		_show_message("Your partner left — your team loses.", 2.5)
		rules_state["over"] = true
		rules_state["winner"] = (local_seat + 1) % player_count
	else:
		_show_message("Opponent left — you win!", 2.5)
		rules_state["over"] = true
		rules_state["winner"] = local_seat
	_show_result()

# ---------------------------------------------------------------------- AI

func _process(delta: float) -> void:
	if _msg_timer > 0.0:
		_msg_timer -= delta
		if _msg_timer <= 0.0:
			_msg_pill.visible = false
	# Power bar eases toward its target instead of snapping (smooth
	# feel; the drag still sets the target directly, so aiming stays 1:1).
	if _power_bar != null and _power_bar.visible:
		_power_bar.value = lerpf(_power_bar.value, _power_target, minf(1.0, delta * 14.0))
	if phase == "place" and not result_shown:
		# Turn timer (local player only in solo/tour; both seats online).
		if _is_local_ai_mode():
			if int(rules_state["turn"]) == local_seat:
				_tick_timer(delta)
		else:
			_tick_timer(delta)
		# AI move.
		if _is_local_ai_mode() and int(rules_state["turn"]) != local_seat:
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
				# Winner is a seat on the opposing team (2p: 1 - local).
				rules_state["winner"] = (local_seat + 1) % player_count
				_show_result()
				return
		else:
			remote_timeouts += 1
			var timed_out: int = rules_state["turn"]
			var my_team := CarromRules.team_of(rules_state, local_seat)
			if player_count == 4 and CarromRules.team_of(rules_state, timed_out) == my_team:
				_show_message("Your partner timed out.", 2.0)
			else:
				_show_message("Opponent timed out.", 2.0)
			if mode == "online" and remote_timeouts >= 2:
				rules_state["over"] = true
				# If the timed-out player is on MY team, my team loses;
				# otherwise my team wins (2p: always the opponent).
				if player_count == 4 and CarromRules.team_of(rules_state, timed_out) == my_team:
					rules_state["winner"] = (local_seat + 1) % player_count
				else:
					rules_state["winner"] = local_seat
				_show_result()
				return
		# Missed shot: resolve an empty stroke. This is a timeout, not a
		# shot — _resolve_shot(true) leaves the timeout counters and the
		# break-miss count alone (F4, F11a).
		_shot_pocketed.clear()
		_shot_striker_pocketed = false
		phase = "settling"
		_resolve_shot(true)

func _run_ai(delta: float) -> void:
	if _ai_stage == 0:
		_ai_wait += delta
		if _ai_wait >= 0.9:
			_ai_wait = 0.0
			var own := CarromRules.own_color(rules_state, 1 - local_seat)
			_ai_shot = CarromAI.choose_shot(pieces, own, difficulty, rules_state, is_break, 1 - local_seat)
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
	# F5: a result must never leave the tree paused (e.g. an opponent
	# leaving while the pause menu is open) — the result screen runs
	# unpaused.
	get_tree().paused = false
	var winner: int = rules_state["winner"]
	# A draw is winner < 0. The rules engine never produces one yet (every
	# board has a winner); the refund path below is implemented + tested
	# so it is ready when a draw outcome exists.
	var is_draw := winner < 0
	# Win = the winning TEAM is my team (2p: team == player).
	var won := false
	if not is_draw:
		won = CarromRules.team_of(rules_state, winner) == CarromRules.team_of(rules_state, local_seat)
	if won:
		Sfx.win()
		Sfx.cheer()
	elif not is_draw:
		Sfx.foul()
	# Pot math (staked modes only: online + tour). 2p: pot = your stake +
	# opponent's stake. 4p: pot = all four stakes; YOUR share = your
	# team's half of the pot. Tour: the bot mirrors your stake, so the
	# pot is always 2x your stake (WorldTour.mirror_stake).
	var pot := 0
	var my_share := 0
	if _is_staked_mode():
		if player_count == 4:
			pot = Stakes.pot_4p(stakes4)
			my_share = Stakes.payout_4p(stakes4, local_seat, "win" if won else ("draw" if is_draw else "loss"))
		else:
			pot = your_stake + opp_stake
			my_share = Stakes.payout(your_stake, opp_stake, "win" if won else ("draw" if is_draw else "loss"))
	# F13 Phase 2: a settlement that arrived before the result screen
	# (belt-and-braces — normally it arrives after our own report, once
	# both sides agree) overrides the local computation for online
	# matches. The server's payout is authoritative; the local math
	# above is only the fallback when no settlement exists.
	if mode == "online" and _server_settlement >= 0:
		if player_count == 4:
			my_share = Settlement.credit_for_outcome_4p(stakes4, local_seat, "win" if won else ("draw" if is_draw else "loss"), _server_settlement, true)
		else:
			my_share = Settlement.credit_for_outcome(your_stake, opp_stake, "win" if won else ("draw" if is_draw else "loss"), _server_settlement, true)
		pot = _server_settlement_pot
	# F13 Phase 2: report the outcome so the server can settle the pot.
	# It pays only when both sides' reports agree (win+loss, or
	# draw+draw); a forfeit/disconnect win reports too, but the room is
	# already gone by then, so the server ignores it and the local win
	# stands. Tour/solo/bot matches never report (no server, no stakes).
	if mode == "online" and net != null:
		net.send_result("win" if won else ("draw" if is_draw else "loss"))
	# Economy (v5): solo vs AI is free practice — ZERO coins, win or lose.
	# Staked modes pay the POT — but a WIN does not credit immediately:
	# the premium win screen HOLDS the pot until the player COLLECTs it,
	# or watches 2 ads to DOUBLE it (see _show_premium_win). A draw
	# refunds immediately; a loss credits nothing. No queen / no-guide /
	# level-up coin bonuses anywhere — the only coin sources are the ad
	# ladder and match stakes, so a zero balance can never be farmed
	# back through matches. World Tour (v8) is staked exactly like
	# online: the bot mirrors your stake, so the pot is real coins in
	# and out — and losing a tour match costs the stake.
	var coins_earned := 0
	if mode == "solo":
		if won:
			Save.solo_wins += 1
	elif won:
		if mode == "tour":
			Save.tour_wins += 1
		else:
			Save.online_wins += 1
		_pot_pending = my_share
		_pot_credited = false
		_double_ads = 0
		# F9: persist the held pot — if the app is killed on the win
		# screen, the next match recovers it from Save.pending_pot.
		Save.pending_pot = my_share
		Save.save()
	elif is_draw:
		coins_earned = my_share # refund of own stake
	# v11 match points (§4, per-coin formula): 10 pts per OWN coin
	# pocketed + 25 for a covered queen + 50 win bonus. Computed
	# BEFORE the XP line — points FEED the XP/level system, so an
	# online match's XP is the base XP + the points earned. Solo/tour
	# pay no points (and no XP from points), like they pay no coins.
	var mp_earned := 0
	if mode == "online":
		mp_earned = MatchPoints.points_for_coins(_my_coins_pocketed, local_covered_queen, won)
		Save.match_points += mp_earned
		if is_draw:
			Save.online_draws += 1
	var xp_earned := Save.XP_PER_MATCH + (Save.XP_PER_WIN if won else 0) + (Save.XP_PER_QUEEN if local_covered_queen else 0) + mp_earned
	var new_level := Save.add_xp(xp_earned)
	Save.add_coins(coins_earned)
	Save.matches_played += 1
	if won:
		Save.matches_won += 1
	Save.interstitial_counter += 1
	Save.save()
	# Play Games Services: report the finished match — leaderboard score
	# + achievement triggers. Fire-and-forget: PlayGames no-ops while
	# signed out / offline / unconfigured, so the result screen never
	# blocks on it. Win streak + lifetime coins pocketed are tracked
	# here (Hat-Trick needs consecutive wins; Sharpshooter needs the
	# lifetime coin total) — no economy change, these are counters only.
	var my_team := CarromRules.team_of(rules_state, local_seat)
	var my_coins := int((rules_state["pocketed"] as Array)[my_team])
	Save.total_coins_pocketed += my_coins
	if won:
		Save.win_streak += 1
	else:
		Save.win_streak = 0
	Save.save()
	PlayGames.report_match_result({
		"won": won,
		"matches_played": Save.matches_played,
		"matches_won": Save.matches_won,
		"win_streak": Save.win_streak,
		"coins_pocketed": my_coins,
		"queen_covered": local_covered_queen,
		"clean_sweep": won and my_coins >= 9,
		"total_coins_pocketed": Save.total_coins_pocketed,
		"score": PlayGames.compute_match_score(my_coins, local_covered_queen, won),
		"match_points": mp_earned,
		"match_points_total": Save.match_points,
	})
	# Interstitial policy: only after every 3rd match.
	var show_ad := Save.interstitial_counter % AdsConfig.INTERSTITIAL_EVERY_N_MATCHES == 0
	if won:
		_show_premium_win(my_share, pot, xp_earned, new_level, winner, mp_earned)
	else:
		var lines: Array = []
		if mode == "solo":
			lines.append("Practice loss — no coins lost.")
		elif is_draw:
			lines.append("Draw — your stake ◉ %d refunded" % your_stake)
		else:
			if player_count == 4:
				lines.append("Your team lost — the pot ◉ %d goes to the other team" % pot)
			else:
				lines.append("Your stake ◉ %d  •  Opponent stake ◉ %d" % [your_stake, opp_stake])
				if mode == "tour":
					lines.append("World Tour loss — %s wins your stake ◉ %d" % [opponent_name, your_stake])
				else:
					lines.append("Online loss — you lost your stake ◉ %d" % your_stake)
		lines.append("XP: +%d" % xp_earned)
		if mode == "online":
			lines.append(MatchPoints.result_line(mp_earned, Save.match_points))
		if new_level > 0:
			lines.append("LEVEL UP! Now Lv %d · %s" % [new_level, Save.rank_name()])
		if winner >= 0:
			lines.append("Board score: %d" % CarromRules.board_score(rules_state, winner))
		if rules_state.get("lose_reason", "") != "":
			lines.append("Reason: %s" % String(rules_state["lose_reason"]).replace("_", " "))
		var pop: Dictionary = UiKit.popup_window("DRAW" if is_draw else "You Lost", Vector2(560, 560))
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

## Premium win screen (v6, redesigned v10): fireworks burst on win, the
## amount BIG and beautiful in the centre, TWO BIG chunky 3D buttons —
## (1) COLLECT with the winnings total BIG in the middle, (2) WATCH 2
## ADS to DOUBLE the winnings. The pot is HELD (not credited) until the
## player collects, doubles, or leaves the screen — leaving without
## collecting credits the base pot, so coins are never lost.
## Pot 0 (stake 0, or a friendly match): NEVER a bare "◉ 0" — the big
## button is the earn path instead (WATCH 2 ADS -> EARN the next two
## ladder steps). The stake line shows no numbers at all when the pot
## is 0. Clean-UI rule: no duplicate buttons — the old solo "PRACTICE
## WIN / TAP TO CONTINUE" button is gone (it duplicated REMATCH).
func _show_premium_win(my_share: int, pot: int, xp_earned: int, new_level: int, winner: int, mp_earned: int = 0) -> void:
	_earn_mode = false
	var has_pot := _is_staked_mode() and my_share > 0
	var pop_size := Vector2(620, 780) if has_pot or not _is_staked_mode() else Vector2(620, 660)
	var pop: Dictionary = UiKit.popup_window("MATCH RESULT", pop_size)
	_result_pop = pop
	_hud.add_child(pop["dim"])
	var box: VBoxContainer = pop["box"]
	# Fireworks over the whole screen (mouse-transparent, so the win
	# buttons underneath keep working).
	_fireworks = Fireworks.new()
	UiKit.full_rect(_fireworks)
	_hud.add_child(_fireworks)
	_fireworks.start_celebration()
	var big := Label.new()
	big.text = "★ WINNER ★"
	big.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	big.add_theme_font_size_override("font_size", 52)
	big.add_theme_color_override("font_color", UiKit.GOLD_LIGHT)
	big.add_theme_color_override("font_shadow_color", Color(0, 0, 0, 0.9))
	big.add_theme_constant_override("shadow_offset_x", 3)
	big.add_theme_constant_override("shadow_offset_y", 3)
	box.add_child(big)
	# Win-screen honesty: a forfeit win used to look identical to a clean
	# win. When the loser forfeited (rules_state["lose_reason"] is set),
	# say so plainly, naming the opponent — mirroring the lose screen's
	# "Reason:" line. Clean wins (lose_reason == "") show nothing here.
	var lose_reason := String(rules_state.get("lose_reason", ""))
	if lose_reason != "":
		var reason_text := ""
		# 4p: opponent_name is the PARTNER's name (setup_4p), and the
		# forfeiter's seat is not recorded in rules_state — so name the
		# other team, not a person. 2p: the forfeiter is the opponent.
		if lose_reason == "last_coin_queen_on_board":
			if player_count == 4:
				reason_text = "You win — the other team pocketed their last coin with the queen still on the board."
			else:
				reason_text = "You win — %s pocketed their last coin with the queen still on the board." % opponent_name
		elif lose_reason == "pocketed_opponent_last":
			if player_count == 4:
				reason_text = "You win — the other team pocketed your team's last coin."
			else:
				reason_text = "You win — %s pocketed your last coin." % opponent_name
		else:
			reason_text = "You win — %s (%s)." % [opponent_name, lose_reason.replace("_", " ")]
		box.add_child(UiKit.body_label(reason_text, 20))
	if _is_staked_mode():
		if my_share > 0:
			if player_count == 4:
				box.add_child(UiKit.body_label("Your team wins!  Pot ◉ %d (4 stakes) — your team's half ◉ %d" % [pot, my_share], 20))
			else:
				box.add_child(UiKit.body_label("Your stake ◉ %d + Opponent stake ◉ %d" % [your_stake, opp_stake], 20))
			if mode == "tour":
				# The opponent is a computer — say so right on the win screen.
				box.add_child(UiKit.body_label("World Tour — you beat %s" % opponent_name, 20))
		else:
			# Stake 0: a friendly match — no numbers at all, never ◉ 0.
			if mode == "tour":
				box.add_child(UiKit.body_label("World Tour — you beat %s (friendly match, no stake)" % opponent_name, 20))
			elif player_count == 4:
				box.add_child(UiKit.body_label("Friendly doubles — no stakes.", 20))
			else:
				box.add_child(UiKit.body_label("Friendly match — no stake.", 20))
	else:
		box.add_child(UiKit.body_label("Practice win — no coins earned.", 20))
	# Button 1 — COLLECT (staked, pot > 0): the TOTAL big in the middle.
	if _is_staked_mode():
		if my_share > 0:
			var collect := _stacked_button([
				{"text": "◉ %d" % my_share, "size": 48, "color": Color(0.12, 0.10, 0.02)},
				{"text": "TAP TO COLLECT", "size": 20, "color": Color(0.12, 0.10, 0.02)}], "gold")
			_collect_button = collect["button"]
			_collect_amount_label = collect["labels"][0]
			_collect_button.pressed.connect(_on_collect_pot)
			box.add_child(_collect_button)
			# Button 2 — DOUBLE (only when there is a pot to double).
			var dbl := _stacked_button([
				{"text": "WATCH 2 ADS", "size": 26, "color": Color(1, 1, 1)},
				{"text": "DOUBLE TO ◉ %d" % (my_share * 2), "size": 36, "color": UiKit.GOLD_LIGHT}], "purple")
			_double_button = dbl["button"]
			_double_button.pressed.connect(_on_double_pressed)
			box.add_child(_double_button)
			_double_amount_label = dbl["labels"][1] # "DOUBLE TO ◉ N" line
			_double_label = UiKit.muted_label("2 ads double your winnings — each ad also pays the ad ladder.", 17)
			_double_label.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
			box.add_child(_double_label)
		else:
			# Pot 0: no COLLECT, no DOUBLE — ONE big earn button. Two
			# ads pay the next two ladder steps (the amount shown).
			_earn_mode = true
			_earn_coins_before = Save.ad_coins_today
			var first := Save.ad_next_reward()
			if first > 0:
				var earn_amount := first + Save.ad_reward_at(Save.ad_count_today + 1)
				var earn := _stacked_button([
					{"text": "WATCH 2 ADS", "size": 26, "color": Color(1, 1, 1)},
					{"text": "EARN ◉ %d" % earn_amount, "size": 36, "color": UiKit.GOLD_LIGHT}], "pink")
				_double_button = earn["button"]
				_double_button.pressed.connect(_on_double_pressed)
				box.add_child(_double_button)
				_double_label = UiKit.muted_label("Two ads pay the ad ladder twice — no stake needed.", 17)
				_double_label.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
				box.add_child(_double_label)
			else:
				var capped := UiKit.muted_label("Ad limit reached today — come back tomorrow for ad coins.", 17)
				capped.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
				box.add_child(capped)
	else:
		# v8: a solo win pays no coins — but the player may watch ONE ad
		# to earn the ladder amount (same ladder as the FREE COINS panel).
		# The ladder itself is paid by Main's rewarded handler; this
		# button is only the offer. Capped days show "come back tomorrow".
		var earn_amount := Save.ad_next_reward()
		if earn_amount > 0:
			var earn := _stacked_button([
				{"text": "WATCH 1 AD", "size": 26, "color": Color(1, 1, 1)},
				{"text": "EARN ◉ %d" % earn_amount, "size": 36, "color": UiKit.GOLD_LIGHT}], "pink")
			_solo_earn_button = earn["button"]
			_solo_earn_label = earn["labels"][1]
			_solo_earn_button.pressed.connect(_on_solo_earn_pressed)
			box.add_child(_solo_earn_button)
			var earn_note := UiKit.muted_label("One ad pays the ad-ladder amount — same as FREE COINS.", 17)
			earn_note.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
			box.add_child(earn_note)
		else:
			var capped := UiKit.muted_label("Ad limit reached today — come back tomorrow for ad coins.", 17)
			capped.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
			box.add_child(capped)
	# Info line: XP / level / board score / match points.
	var info := "XP: +%d" % xp_earned
	if mode == "online":
		info += "  •  " + MatchPoints.result_line(mp_earned, Save.match_points)
	if new_level > 0:
		info += "  •  LEVEL UP! Now Lv %d · %s" % [new_level, Save.rank_name()]
	if winner >= 0:
		info += "  •  Board score: %d" % CarromRules.board_score(rules_state, winner)
	var info_l := UiKit.muted_label(info, 18)
	info_l.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	box.add_child(info_l)
	var again := UiKit.gold_button("REMATCH" if mode == "solo" else "FIND REMATCH", 28)
	var home := UiKit.dark_button("HOME", 26)
	box.add_child(again)
	box.add_child(home)
	pop["close"].pressed.connect(func() -> void: _exit_result_home())
	home.pressed.connect(func() -> void: _exit_result_home())
	again.pressed.connect(func() -> void: _exit_result_rematch())

## A big chunky 3D button with stacked centred lines (amount BIG in the
## middle). Returns {button, labels}. `style` picks the tile pair:
## "gold" (COLLECT), "purple" (DOUBLE), "pink" (earn offers).
func _stacked_button(lines: Array, style: String) -> Dictionary:
	var pair: Dictionary = UiKit.TILE_GOLD
	if style == "purple":
		pair = UiKit.TILE_ALPHABET
	elif style == "pink":
		pair = UiKit.TILE_BALLOON
	var b := UiKit.tile_button("", 28, pair)
	b.custom_minimum_size = Vector2(0, 124)
	var vb := VBoxContainer.new()
	vb.mouse_filter = Control.MOUSE_FILTER_IGNORE
	UiKit.full_rect(vb)
	vb.alignment = BoxContainer.ALIGNMENT_CENTER
	vb.add_theme_constant_override("separation", 2)
	var labels: Array = []
	for ln in lines:
		var l := Label.new()
		l.text = String(ln.get("text", ""))
		l.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
		l.add_theme_font_size_override("font_size", int(ln.get("size", 24)))
		l.add_theme_color_override("font_color", ln.get("color", UiKit.TEXT))
		l.mouse_filter = Control.MOUSE_FILTER_IGNORE
		vb.add_child(l)
		labels.append(l)
	b.add_child(vb)
	return {"button": b, "labels": labels}

## F13 Phase 2 (v11): apply the server's authoritative settlement for
## this online match. Called by Main when Net.settlement_received fires.
##   * Invalid settlement (bad shape, payout outside 0..pot) — ignored;
##     the locally held pot stands.
##   * Result not shown yet — stored and applied in _show_result.
##   * Win screen open with the pot still held — the held pot is
##     RE-PRICED to the server's payout (COLLECT / DOUBLE labels updated,
##     Save.pending_pot updated so a kill on the win screen still
##     recovers the settled amount, not the claimed one).
##   * Nothing held (loss, draw already refunded, already collected) —
##     nothing to re-price; the settlement is ignored.
func apply_server_settlement(data: Dictionary) -> void:
	if mode != "online":
		return
	var parsed := Settlement.parse_settlement(data)
	if not bool(parsed.get("ok", false)):
		return
	var payout := int(parsed["payout"])
	var pot := int(parsed["pot"])
	if not result_shown:
		_server_settlement = payout
		_server_settlement_pot = pot
		return
	if _pot_credited or _pot_pending <= 0:
		return
	_server_settlement = payout
	_server_settlement_pot = pot
	_pot_pending = payout
	Save.pending_pot = payout
	Save.save()
	if _collect_amount_label:
		_collect_amount_label.text = "◉ %d" % payout
	if _double_amount_label:
		_double_amount_label.text = "DOUBLE TO ◉ %d" % (payout * 2)
	if _double_label:
		_double_label.text = "Server settled your winnings at ◉ %d — 2 ads double them." % payout

## Credit the held pot if it has not been credited yet (base amount —
## used by COLLECT and by every exit path, so coins are never lost).
func _collect_pot_if_pending() -> void:
	if _pot_pending > 0 and not _pot_credited:
		Save.add_coins(_pot_pending)
		_pot_credited = true
		_pot_pending = 0
		Save.pending_pot = 0
		Save.save()

func _on_collect_pot() -> void:
	if _pot_credited:
		return
	var amount := _pot_pending
	_collect_pot_if_pending()
	if _collect_amount_label:
		_collect_amount_label.text = "COLLECTED ✓ ◉ %d" % amount
	if _collect_button:
		_collect_button.disabled = true
	if _double_button:
		_double_button.disabled = true
	if _double_label:
		_double_label.text = "Collected ◉ %d ✓" % amount

func _on_double_pressed() -> void:
	if _pot_credited or _double_ads >= 2:
		return
	# Earn mode (pot 0) has no pot to double — the two ads ARE the earn.
	if not _earn_mode and _pot_pending <= 0:
		return
	Ads.show_rewarded("double_win")
	if _double_button:
		_double_button.disabled = true # re-enabled after ad 1 lands
	if _double_label:
		_double_label.text = "Ad 1 of 2 playing…"

## Called by Main when a "double_win" rewarded ad completes. Each of the
## two ads ALSO pays the ad ladder (Main's handler pays the ladder for
## every rewarded ad) and advances it — the doubling is on top of that.
## After the 2nd ad the held pot is credited DOUBLED. In earn mode
## (pot 0) the two ads are the earn itself: the label shows the real
## amount the ladder paid (ad_coins_today delta).
func on_double_ad_watched() -> void:
	if _earn_mode:
		_double_ads += 1
		if _double_ads >= 2:
			var earned := Save.ad_coins_today - _earn_coins_before
			if _double_button:
				_double_button.disabled = true
			if _double_label:
				_double_label.text = "EARNED ◉ %d ✓" % earned
			_show_message("Ad coins earned — ◉ %d!" % earned, 3.0)
		else:
			if _double_button:
				_double_button.disabled = false
			if _double_label:
				_double_label.text = "Ad 1 of 2 watched — one more to earn!"
		return
	if _pot_credited or _pot_pending <= 0:
		return
	_double_ads += 1
	if _double_ads >= 2:
		# v11: the doubling formula lives in Stakes (one formula for
		# the win screen and the tests) — 2 ads double the SETTLED pot
		# (which a server settlement may already have re-priced).
		var doubled := Stakes.doubled_winnings(_pot_pending, _double_ads)
		_pot_credited = true
		_pot_pending = 0
		Save.pending_pot = 0
		Save.add_coins(doubled)
		Save.save()
		if _collect_button:
			_collect_button.disabled = true
		if _double_button:
			_double_button.disabled = true
		if _double_label:
			_double_label.text = "DOUBLED! ◉ %d collected ✓" % doubled
		_show_message("Winnings DOUBLED — ◉ %d!" % doubled, 3.0)
	else:
		if _double_button:
			_double_button.disabled = false
		if _double_label:
			_double_label.text = "Ad 1 of 2 watched — one more to DOUBLE to ◉ %d!" % (_pot_pending * 2)

## Solo win ad-earn (v8): one rewarded ad pays the ladder amount. The
## ladder itself is credited by Main's rewarded handler; these methods
## only update this screen's button. Called by Main.
func _on_solo_earn_pressed() -> void:
	if _solo_earn_button:
		_solo_earn_button.disabled = true # re-enabled only if the ad fails
	Ads.show_rewarded("solo_win")

func on_solo_win_ad_watched() -> void:
	if _solo_earn_button:
		_solo_earn_button.disabled = true
	if _solo_earn_label:
		_solo_earn_label.text = "EARNED ✓"
	_show_message("Ad coins earned — check your balance!", 2.5)

func on_solo_win_ad_failed() -> void:
	if _solo_earn_button:
		_solo_earn_button.disabled = false

## F8: a failed "double_win" ad must re-enable the DOUBLE button (and
## the pot-0 EARN button — it is the same _double_button) so the offer
## is not dead for the rest of the win screen. Called by Main's
## _on_rewarded_failed("double_win"). Mirror of on_solo_win_ad_failed.
func on_double_ad_failed() -> void:
	if _double_button:
		_double_button.disabled = false

## Exit paths from the win screen: credit the base pot first if it is
## still held, then leave (coins are never lost by closing the screen).
func _exit_result_home() -> void:
	_collect_pot_if_pending()
	exit_to_home.emit()

func _exit_result_rematch() -> void:
	_collect_pot_if_pending()
	rematch_requested.emit()

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
	# Opponent panel (top). 4p needs a taller panel (3 player rows).
	# Premium: dark wood + gold border (reference in-game screen).
	_opp_panel = PanelContainer.new()
	_opp_panel.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_opp_panel.add_theme_stylebox_override("panel", UiKit.panel_style(Color(0.16, 0.10, 0.06, 0.95), UiKit.GOLD, 16, 2))
	_opp_panel.set_anchors_preset(Control.PRESET_TOP_WIDE)
	_opp_panel.offset_left = 16
	_opp_panel.offset_right = -16
	_opp_panel.offset_top = 12
	_opp_panel.offset_bottom = 186 if player_count == 4 else 126
	root.add_child(_opp_panel)
	var opp_box := VBoxContainer.new()
	opp_box.name = "OppBox"
	_opp_panel.add_child(opp_box)
	var opp_top := HBoxContainer.new()
	opp_top.name = "OppTop"
	# Gold avatar circle (reference top bar) — initial refreshed in
	# _update_hud alongside the name.
	var opp_avatar := PanelContainer.new()
	opp_avatar.add_theme_stylebox_override("panel", UiKit.panel_style(UiKit.GOLD, UiKit.GOLD, 28, 2))
	opp_avatar.custom_minimum_size = Vector2(52, 52)
	_opp_avatar_label = Label.new()
	_opp_avatar_label.text = opponent_name.substr(0, 1).to_upper()
	_opp_avatar_label.add_theme_font_size_override("font_size", 26)
	_opp_avatar_label.add_theme_color_override("font_color", UiKit.DARK_TEXT)
	_opp_avatar_label.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	_opp_avatar_label.vertical_alignment = VERTICAL_ALIGNMENT_CENTER
	opp_avatar.add_child(_opp_avatar_label)
	opp_top.add_child(opp_avatar)
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
	# Coins (local balance, reference top bar) — refreshed in _update_hud.
	var opp_spacer := Control.new()
	opp_spacer.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	opp_spacer.mouse_filter = Control.MOUSE_FILTER_IGNORE
	opp_top.add_child(opp_spacer)
	_opp_coins_label = Label.new()
	_opp_coins_label.text = "◉ %d" % Save.coins
	_opp_coins_label.add_theme_font_size_override("font_size", 22)
	_opp_coins_label.add_theme_color_override("font_color", UiKit.GOLD_LIGHT)
	opp_top.add_child(_opp_coins_label)
	opp_box.add_child(opp_top)
	# 4p doubles: two more rows so all three other players are listed
	# (partner + two opponents, seat order). Names are set in _update_hud.
	if player_count == 4:
		for k in range(1, 3):
			var row := HBoxContainer.new()
			row.name = "OppRow%d" % k
			var nm := Label.new()
			nm.name = "OppName%d" % k
			nm.text = "Player"
			nm.add_theme_font_size_override("font_size", 20)
			nm.add_theme_color_override("font_color", UiKit.TEXT)
			row.add_child(nm)
			var lv := Label.new()
			lv.name = "OppLevel%d" % k
			lv.text = "Lv 1"
			lv.add_theme_font_size_override("font_size", 18)
			lv.add_theme_color_override("font_color", UiKit.GOLD_LIGHT)
			row.add_child(lv)
			opp_box.add_child(row)
	# Online: show both stakes under the opponent name so the pot is
	# visible for the whole match. Tour shows the same line (the bot
	# mirrors your stake).
	if _is_staked_mode():
		var stake_l := Label.new()
		stake_l.name = "StakeLine"
		stake_l.mouse_filter = Control.MOUSE_FILTER_IGNORE
		if player_count == 4:
			stake_l.text = "Pot ◉ %d — your team's half ◉ %d" % [Stakes.pot_4p(stakes4), Stakes.payout_4p(stakes4, local_seat, "win")]
		else:
			stake_l.text = "Your stake ◉ %d  •  Opponent stake ◉ %d" % [your_stake, opp_stake]
		stake_l.add_theme_font_size_override("font_size", 18)
		stake_l.add_theme_color_override("font_color", UiKit.GOLD_LIGHT)
		opp_box.add_child(stake_l)
	_opp_dots = Dots.new()
	_opp_dots.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_opp_dots.color = Color(0.15, 0.15, 0.17)
	_opp_dots.custom_minimum_size = Vector2(200, 24)
	opp_box.add_child(_opp_dots)
	# Turn banner: dark pill with a gold border (reference in-game
	# screen). The pill is the positioned node; the label lives inside
	# it. Height 40 px fits the 40 px gap to the timer bar below.
	# (Panel + banner sit 18 px lower than before — the avatar circle
	# made the opponent panel taller.)
	_turn_pill = PanelContainer.new()
	_turn_pill.mouse_filter = Control.MOUSE_FILTER_IGNORE
	var turn_style := UiKit.panel_style(Color(0.10, 0.08, 0.05, 0.92), UiKit.GOLD, 20, 2)
	turn_style.content_margin_top = 4
	turn_style.content_margin_bottom = 4
	_turn_pill.add_theme_stylebox_override("panel", turn_style)
	_turn_pill.set_anchors_preset(Control.PRESET_CENTER_TOP)
	_turn_pill.offset_top = 196 if player_count == 4 else 136
	_turn_pill.offset_bottom = 236 if player_count == 4 else 176
	_turn_pill.offset_left = -200
	_turn_pill.offset_right = 200
	root.add_child(_turn_pill)
	_turn_label = Label.new()
	_turn_label.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_turn_label.add_theme_font_size_override("font_size", 26)
	_turn_label.add_theme_color_override("font_color", UiKit.GOLD_LIGHT)
	_turn_label.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	_turn_label.vertical_alignment = VERTICAL_ALIGNMENT_CENTER
	_turn_pill.add_child(_turn_label)
	# Timer bar.
	_timer_bar = ProgressBar.new()
	_timer_bar.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_timer_bar.min_value = 0
	_timer_bar.max_value = 20
	_timer_bar.show_percentage = false
	_timer_bar.set_anchors_preset(Control.PRESET_CENTER_TOP)
	_timer_bar.offset_top = 236 if player_count == 4 else 176
	_timer_bar.offset_left = -140
	_timer_bar.offset_right = 140
	_timer_bar.offset_bottom = 250 if player_count == 4 else 190
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
	_assist_chip.offset_top = 256 if player_count == 4 else 196
	_assist_chip.offset_left = -200
	_assist_chip.offset_right = 200
	root.add_child(_assist_chip)
	# Message banner (centre of board): dark pill with a gold border
	# + the gold crown at the left (reference queen banner). The pill
	# is the positioned node and the visibility toggle; the label
	# inside only carries the text.
	_msg_pill = PanelContainer.new()
	_msg_pill.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_msg_pill.add_theme_stylebox_override("panel", UiKit.panel_style(Color(0.10, 0.08, 0.05, 0.92), UiKit.GOLD, 20, 2))
	_msg_pill.set_anchors_preset(Control.PRESET_CENTER)
	_msg_pill.offset_top = -300
	_msg_pill.offset_bottom = -240
	_msg_pill.offset_left = -340
	_msg_pill.offset_right = 340
	_msg_pill.visible = false
	root.add_child(_msg_pill)
	var msg_row := HBoxContainer.new()
	msg_row.add_theme_constant_override("separation", 10)
	msg_row.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_msg_pill.add_child(msg_row)
	var crown := TextureRect.new()
	crown.texture = preload("res://art/icon_crown_gold.png")
	crown.expand_mode = TextureRect.EXPAND_IGNORE_SIZE
	crown.stretch_mode = TextureRect.STRETCH_KEEP_ASPECT_CENTERED
	crown.custom_minimum_size = Vector2(44, 30)
	crown.mouse_filter = Control.MOUSE_FILTER_IGNORE
	msg_row.add_child(crown)
	_msg_label = Label.new()
	_msg_label.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_msg_label.add_theme_font_size_override("font_size", 28)
	_msg_label.add_theme_color_override("font_color", Color(1, 0.9, 0.5))
	_msg_label.add_theme_color_override("font_shadow_color", Color(0, 0, 0, 0.9))
	_msg_label.add_theme_constant_override("shadow_offset_x", 2)
	_msg_label.add_theme_constant_override("shadow_offset_y", 2)
	_msg_label.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	_msg_label.vertical_alignment = VERTICAL_ALIGNMENT_CENTER
	_msg_label.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	_msg_label.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	msg_row.add_child(_msg_label)
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
	# My panel (bottom). Premium: dark wood + gold border, same as the
	# opponent panel (reference in-game screen).
	_my_panel = PanelContainer.new()
	_my_panel.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_my_panel.add_theme_stylebox_override("panel", UiKit.panel_style(Color(0.16, 0.10, 0.06, 0.95), UiKit.GOLD, 16, 2))
	_my_panel.set_anchors_preset(Control.PRESET_BOTTOM_WIDE)
	_my_panel.offset_left = 16
	_my_panel.offset_right = -16
	_my_panel.offset_top = -176
	_my_panel.offset_bottom = -16
	root.add_child(_my_panel)
	var my_box := VBoxContainer.new()
	_my_panel.add_child(my_box)
	var my_top := HBoxContainer.new()
	# Gold avatar circle (reference bottom bar).
	var my_avatar := PanelContainer.new()
	my_avatar.add_theme_stylebox_override("panel", UiKit.panel_style(UiKit.GOLD, UiKit.GOLD, 28, 2))
	my_avatar.custom_minimum_size = Vector2(52, 52)
	_my_avatar_label = Label.new()
	_my_avatar_label.text = Save.player_name.substr(0, 1).to_upper()
	_my_avatar_label.add_theme_font_size_override("font_size", 26)
	_my_avatar_label.add_theme_color_override("font_color", UiKit.DARK_TEXT)
	_my_avatar_label.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	_my_avatar_label.vertical_alignment = VERTICAL_ALIGNMENT_CENTER
	my_avatar.add_child(_my_avatar_label)
	my_top.add_child(my_avatar)
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
	# v11 match points (§4): live running score beside the board
	# score — online matches only (solo/tour pay no points). Text is
	# set in _update_hud from _my_coins_pocketed + queen state.
	_points_label = UiKit.muted_label("", 18)
	_points_label.name = "PointsLine"
	_points_label.mouse_filter = Control.MOUSE_FILTER_IGNORE
	my_box.add_child(_points_label)
	var hint := UiKit.muted_label("Drag the striker sideways to slide • Pull back to aim • Release to shoot", 16)
	my_box.add_child(hint)

func _on_pause_pressed() -> void:
	if phase == "over":
		return
	if get_tree().paused:
		return
	# F5: actually pause — freezing the tree stops _process (turn timer
	# + AI) and _physics_process while the menu is open. The popup runs
	# with PROCESS_MODE_ALWAYS so its buttons still work; every exit
	# from it unpauses first.
	get_tree().paused = true
	var pop: Dictionary = UiKit.popup_window("PAUSED", Vector2(480, 380))
	pop["dim"].process_mode = Node.PROCESS_MODE_ALWAYS
	_hud.add_child(pop["dim"])
	var box: VBoxContainer = pop["box"]
	var resume := UiKit.gold_button("RESUME", 28)
	var sound := UiKit.dark_button("SOUND: ON" if Save.sound_on else "SOUND: OFF", 24)
	var forfeit := UiKit.dark_button("FORFEIT MATCH", 24)
	box.add_child(resume)
	box.add_child(sound)
	box.add_child(forfeit)
	var close_pause := func() -> void:
		get_tree().paused = false
		pop["dim"].queue_free()
	resume.pressed.connect(close_pause)
	sound.pressed.connect(func() -> void:
		Save.sound_on = not Save.sound_on
		Sfx.set_enabled(Save.sound_on)
		Save.save()
		sound.text = "SOUND: ON" if Save.sound_on else "SOUND: OFF")
	forfeit.pressed.connect(func() -> void:
		close_pause.call()
		if mode == "online" and net:
			net.send_forfeit()
		rules_state["over"] = true
		rules_state["winner"] = (local_seat + 1) % player_count
		_show_result())
	pop["close"].pressed.connect(close_pause)

func _show_message(text: String, seconds: float) -> void:
	_msg_label.text = text
	_msg_pill.visible = true
	_msg_timer = seconds

## F2 layer 2: create the missing OppRow1/OppRow2 rows when a 4p match
## was configured after _ready() built a 2-player HUD — the same rows
## _build_hud creates for 4p, in the same order (OppTop, rows, then
## the stake line / dots), with the taller 4p panel geometry.
func _ensure_opp_rows() -> void:
	var opp_box: VBoxContainer = _opp_panel.get_node("OppBox")
	for k in range(1, 3):
		if opp_box.get_node_or_null("OppRow%d" % k) != null:
			continue
		var row := HBoxContainer.new()
		row.name = "OppRow%d" % k
		var nm := Label.new()
		nm.name = "OppName%d" % k
		nm.text = "Player"
		nm.add_theme_font_size_override("font_size", 20)
		nm.add_theme_color_override("font_color", UiKit.TEXT)
		row.add_child(nm)
		var lv := Label.new()
		lv.name = "OppLevel%d" % k
		lv.text = "Lv 1"
		lv.add_theme_font_size_override("font_size", 18)
		lv.add_theme_color_override("font_color", UiKit.GOLD_LIGHT)
		row.add_child(lv)
		opp_box.add_child(row)
		opp_box.move_child(row, k)
	_opp_panel.offset_bottom = 186
	_turn_pill.offset_top = 196
	_turn_pill.offset_bottom = 236
	_timer_bar.offset_top = 236
	_timer_bar.offset_bottom = 250
	_assist_chip.offset_top = 256

func _update_hud() -> void:
	# F2 layer 1: setup()/setup_4p() may run before add_child now, so
	# this is called before _ready() built the HUD — return early;
	# _ready() calls _update_hud() again once the panels exist.
	# (rules_state is also still empty at that point.)
	if _hud == null or _opp_panel == null:
		return
	var my_team := CarromRules.team_of(rules_state, local_seat)
	var my_color := CarromRules.own_color(rules_state, local_seat)
	var opp_color := CarromRules.opp_color(rules_state, local_seat)
	# F10: the stake line is built/updated here, not only in _build_hud —
	# _ready() runs before setup(), when mode is still "solo", so the
	# _build_hud stake line never existed for staked matches. setup()
	# and setup_4p() both call _update_hud(), so the line appears once
	# the mode and stakes are known, and its text stays current.
	if _is_staked_mode():
		# A 0-stake (friendly) match shows NO stake line at all — the
		# v10 clean-UI rule is never a bare "◉ 0" anywhere (the win
		# screen test checks this). Only show the line when a real
		# pot exists.
		var pot_total := Stakes.pot_4p(stakes4) if player_count == 4 else your_stake + opp_stake
		var opp_box: VBoxContainer = _opp_panel.get_node("OppBox")
		var stake_l: Label = opp_box.get_node_or_null("StakeLine")
		if pot_total <= 0:
			if stake_l != null:
				stake_l.queue_free()
		else:
			if stake_l == null:
				stake_l = Label.new()
				stake_l.name = "StakeLine"
				stake_l.mouse_filter = Control.MOUSE_FILTER_IGNORE
				stake_l.add_theme_font_size_override("font_size", 18)
				stake_l.add_theme_color_override("font_color", UiKit.GOLD_LIGHT)
				opp_box.add_child(stake_l)
				# Keep it above the dots, as _build_hud lays it out.
				opp_box.move_child(stake_l, _opp_dots.get_index())
			if player_count == 4:
				stake_l.text = "Pot ◉ %d — your team's half ◉ %d" % [Stakes.pot_4p(stakes4), Stakes.payout_4p(stakes4, local_seat, "win")]
			else:
				stake_l.text = "Your stake ◉ %d  •  Opponent stake ◉ %d" % [your_stake, opp_stake]
	if player_count == 4:
		# Top panel lists the three other players in seat order, with
		# a team tag (PARTNER = my team, OPP = the other team).
		# F2 layer 2: the rows may not exist if _ready() built a
		# 2-player HUD (setup ran after add_child) — create them.
		_ensure_opp_rows()
		var others: Array = []
		for s in range(4):
			if s != local_seat:
				others.append(s)
		for k in range(3):
			var seat: int = others[k]
			var p: Dictionary = players4[seat]
			var tag := "PARTNER" if CarromRules.team_of(rules_state, seat) == my_team else "OPP"
			var nm: Label
			var lv: Label
			if k == 0:
				nm = _opp_panel.get_node("OppBox/OppTop/OppName")
				lv = _opp_panel.get_node("OppBox/OppTop/OppLevel")
			else:
				nm = _opp_panel.get_node("OppBox/OppRow%d/OppName%d" % [k, k])
				lv = _opp_panel.get_node("OppBox/OppRow%d/OppLevel%d" % [k, k])
			nm.text = "%s (%s)" % [String(p.get("name", "Player")), tag]
			lv.text = "Lv %d" % int(p.get("level", 1))
		# Avatar shows the first listed player (the OppTop row).
		if _opp_avatar_label != null and others.size() > 0:
			var top_p: Dictionary = players4[others[0]]
			_opp_avatar_label.text = String(top_p.get("name", "Player")).substr(0, 1).to_upper()
	else:
		var opp_panel_name: Label = _opp_panel.get_node("OppBox/OppTop/OppName")
		opp_panel_name.text = opponent_name
		var opp_lv: Label = _opp_panel.get_node("OppBox/OppTop/OppLevel")
		opp_lv.text = "Lv %d" % opponent_level
		if _opp_avatar_label != null:
			_opp_avatar_label.text = opponent_name.substr(0, 1).to_upper()
	# Coins in the top panel (local balance, reference top bar).
	if _opp_coins_label != null:
		_opp_coins_label.text = "◉ %d" % Save.coins
	# Dots show pocketed coins of each TEAM's colour.
	_opp_dots.filled = int(rules_state["pocketed"][1 - my_team])
	_opp_dots.color = Color(0.15, 0.15, 0.17) if opp_color == "black" else Color(0.94, 0.92, 0.86)
	_my_dots.filled = int(rules_state["pocketed"][my_team])
	_my_dots.color = Color(0.15, 0.15, 0.17) if my_color == "black" else Color(0.94, 0.92, 0.86)
	_opp_dots.queue_redraw()
	_my_dots.queue_redraw()
	# v11 match points (§4): live running score in MY panel — online
	# only. The dots above already show the TEAM count; the points
	# line is MY OWN coins (10 each) + covered-queen bonus (25).
	if _points_label != null:
		if mode == "online":
			_points_label.text = MatchPoints.live_line(_my_coins_pocketed, local_covered_queen, _my_queen_pending)
			_points_label.visible = true
		else:
			_points_label.visible = false
	var turn_seat: int = rules_state["turn"]
	if player_count == 4:
		var turn_name := String(players4[turn_seat].get("name", "Player")) if turn_seat < players4.size() else "Player"
		if turn_seat == local_seat:
			_turn_label.text = "YOUR TURN — %s" % my_color.to_upper()
		else:
			_turn_label.text = "%s'S TURN — %s" % [turn_name.to_upper(), CarromRules.own_color(rules_state, turn_seat).to_upper()]
	else:
		_turn_label.text = "YOUR TURN — %s" % my_color.to_upper() if turn_seat == local_seat else "OPPONENT'S TURN — %s" % opp_color.to_upper()
	_turn_label.add_theme_color_override("font_color", UiKit.GOLD_LIGHT if turn_seat == local_seat else UiKit.MUTED)
	# Glowing orange halo around the striker on your turn (Carrom Pool look).
	if board_view != null:
		board_view.your_turn = int(rules_state["turn"]) == local_seat
	if Save.aim_assist_active():
		var left := Save.aim_assist_remaining_sec()
		_assist_chip.text = "✦ AIM-ASSIST %02d:%02d" % [left / 60, left % 60]
		_assist_chip.visible = true
	else:
		_assist_chip.visible = false
