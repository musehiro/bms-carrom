extends SceneTree

## Headless test runner for BMS Carrom core logic.
## Run: godot --headless --path . -s tests/test_runner.gd
## Prints PASS/FAIL per test and exits 0 (all pass) or 1 (any fail).
## No UI, no autoloads — pure rules/physics/AI/economy.

var _passed := 0
var _failed := 0
var _failures: Array = []

func _initialize() -> void:
	print("=== BMS Carrom tests ===")
	_test_setup()
	_test_physics_movement()
	_test_physics_pocket()
	_test_physics_wall_bounce()
	_test_physics_collision()
	_test_physics_no_magnet()
	_test_rules_keep_turn()
	_test_rules_queen_early()
	_test_rules_queen_cover()
	_test_rules_queen_cover_missed()
	_test_rules_last_coin_queen_on_board_loses()
	_test_rules_last_coin_queen_covered_wins()
	_test_rules_striker_foul_alone()
	_test_rules_striker_foul_with_coins()
	_test_rules_opponent_last_coin_loses()
	_test_rules_due_owed()
	_test_ai_break_shot()
	_test_ai_midgame_shot()
	_test_ai_easy_misses_sometimes()
	_test_shop_stats_capped()
	_test_ray_circle()
	_test_full_break_simulation()
	_test_full_match_ai_vs_ai()
	_test_base_circle_geometry()
	_test_stakes()
	_test_economy_v5_consts()
	print("=== %d passed, %d failed ===" % [_passed, _failed])
	for f in _failures:
		print("FAIL: ", f)
	quit(0 if _failed == 0 else 1)

func _check(name: String, cond: bool, detail: String = "") -> void:
	if cond:
		_passed += 1
		print("PASS: ", name)
	else:
		_failed += 1
		_failures.append(name + (" — " + detail if detail != "" else ""))
		print("FAIL: ", name, (" — " + detail if detail != "" else ""))

func _approx(a: float, b: float, tol: float = 0.5) -> bool:
	return absf(a - b) <= tol

# ------------------------------------------------------------------ physics

func _test_setup() -> void:
	var pieces := CarromPhysics.setup_pieces()
	var whites := 0
	var blacks := 0
	var queens := 0
	var strikers := 0
	for p in pieces:
		match p["kind"]:
			"white": whites += 1
			"black": blacks += 1
			"queen": queens += 1
			"striker": strikers += 1
	_check("setup: 9 white", whites == 9, str(whites))
	_check("setup: 9 black", blacks == 9, str(blacks))
	_check("setup: 1 queen", queens == 1, str(queens))
	_check("setup: 1 striker", strikers == 1, str(strikers))
	_check("setup: queen on centre", pieces[0]["pos"].distance_to(CarromPhysics.BOARD_CENTER) < 0.5)
	# All coins inside the outer circle (radius 70) and touching neighbours.
	var max_r := 0.0
	for p in pieces:
		if p["kind"] != "striker":
			max_r = maxf(max_r, (p["pos"] as Vector2).distance_to(CarromPhysics.BOARD_CENTER))
	_check("setup: all coins inside outer circle", max_r <= 71.0, str(max_r))

func _test_physics_movement() -> void:
	var pieces := CarromPhysics.setup_pieces()
	var striker: Dictionary = pieces[pieces.size() - 1]
	striker["vel"] = Vector2(0, -1000)
	var start: Vector2 = striker["pos"]
	var res: Dictionary = CarromPhysics.simulate(pieces, 8.0)
	_check("physics: shot moves striker", striker["pos"].distance_to(start) > 100.0, str(striker["pos"].distance_to(start)))
	_check("physics: everything stops", CarromPhysics.all_stopped(pieces))
	_check("physics: simulate returns dict", res.has("pocketed") and res.has("striker_pocketed"))

func _test_physics_pocket() -> void:
	var pieces: Array = []
	var coin: Dictionary = CarromPhysics.make_piece("white", Vector2(120, 350))
	coin["vel"] = Vector2(-200, -200)
	pieces.append(coin)
	var pocket: Vector2 = CarromPhysics.pocket_centers()[0]
	# Aim the coin straight at the top-left pocket.
	coin["pos"] = pocket + Vector2(60, 60)
	coin["vel"] = (pocket - coin["pos"]).normalized() * 300.0
	var res: Dictionary = CarromPhysics.simulate(pieces, 3.0)
	_check("physics: coin into pocket is pocketed", (res["pocketed"] as Array).has("white"), str(res["pocketed"]))
	_check("physics: pocketed coin inactive", not bool(coin["active"]))

func _test_physics_wall_bounce() -> void:
	var pieces: Array = []
	var coin: Dictionary = CarromPhysics.make_piece("white", Vector2(360, 500))
	coin["vel"] = Vector2(0, -800)
	pieces.append(coin)
	var bounced := false
	for i in range(240):
		CarromPhysics.step(pieces, CarromPhysics.FIXED_DT)
		if (coin["vel"] as Vector2).y > 0.0:
			bounced = true
			break
	_check("physics: cushion bounce reverses direction", bounced)
	_check("physics: coin stays inside surface", absf((coin["pos"] as Vector2).x - 360.0) <= CarromPhysics.SURFACE_HALF)

func _test_physics_collision() -> void:
	var pieces: Array = []
	var striker: Dictionary = CarromPhysics.make_piece("striker", Vector2(360, 700))
	striker["vel"] = Vector2(0, -500)
	var coin: Dictionary = CarromPhysics.make_piece("white", Vector2(360, 600))
	pieces.append(striker)
	pieces.append(coin)
	for i in range(120):
		CarromPhysics.step(pieces, CarromPhysics.FIXED_DT)
		if (coin["vel"] as Vector2).length() > 50.0:
			break
	_check("physics: striker transfers momentum to coin", (coin["vel"] as Vector2).length() > 50.0, str((coin["vel"] as Vector2).length()))
	_check("physics: striker slows after impact", (striker["vel"] as Vector2).length() < 500.0, str((striker["vel"] as Vector2).length()))

func _test_physics_no_magnet() -> void:
	# A coin sitting still near (but outside) a pocket must NOT get sucked in.
	var pieces: Array = []
	var pocket: Vector2 = CarromPhysics.pocket_centers()[0]
	var coin: Dictionary = CarromPhysics.make_piece("white", pocket + Vector2(45, 0))
	pieces.append(coin)
	CarromPhysics.simulate(pieces, 2.0)
	_check("physics: no pocket magnet (coin stays)", bool(coin["active"]) and (coin["pos"] as Vector2).distance_to(pocket) > 40.0, str((coin["pos"] as Vector2).distance_to(pocket)))

# -------------------------------------------------------------------- rules

func _test_rules_keep_turn() -> void:
	var s := CarromRules.fresh_state(0)
	var res: Dictionary = CarromRules.resolve_shot(s, ["white"], false)
	_check("rules: pocket own coin keeps turn", int(s["turn"]) == 0)
	_check("rules: pocketed count 1", int((s["pocketed"] as Array)[0]) == 1)
	_check("rules: event own_pocketed", _has_event(res, "own_pocketed"))

func _test_rules_queen_early() -> void:
	var s := CarromRules.fresh_state(0)
	var res: Dictionary = CarromRules.resolve_shot(s, ["queen"], false)
	_check("rules: queen before first coin returns", String(s["queen"]) == "returned")
	_check("rules: early queen ends turn", int(s["turn"]) == 1)
	_check("rules: event queen_early", _has_event(res, "queen_early"))

func _test_rules_queen_cover() -> void:
	var s := CarromRules.fresh_state(0)
	CarromRules.resolve_shot(s, ["white"], false)
	var res: Dictionary = CarromRules.resolve_shot(s, ["queen"], false)
	_check("rules: queen pocketed after coin -> pending", String(s["queen"]) == "pending")
	_check("rules: queen keeps turn for cover shot", int(s["turn"]) == 0)
	var res2: Dictionary = CarromRules.resolve_shot(s, ["white"], false)
	_check("rules: cover on next shot -> covered", String(s["queen"]) == "covered")
	_check("rules: event queen_covered", _has_event(res2, "queen_covered"))

func _test_rules_queen_cover_missed() -> void:
	var s := CarromRules.fresh_state(0)
	CarromRules.resolve_shot(s, ["white"], false)
	CarromRules.resolve_shot(s, ["queen"], false)
	var res: Dictionary = CarromRules.resolve_shot(s, [], false)
	_check("rules: missed cover -> queen returns", String(s["queen"]) == "returned")
	_check("rules: event queen_returned", _has_event(res, "queen_returned"))

func _test_rules_last_coin_queen_on_board_loses() -> void:
	var s := CarromRules.fresh_state(0)
	(s["pocketed"] as Array)[0] = 8
	var res: Dictionary = CarromRules.resolve_shot(s, ["white"], false)
	_check("rules: last coin with queen on board loses", bool(s["over"]) and int(s["winner"]) == 1)
	_check("rules: lose reason", String(s["lose_reason"]) == "last_coin_queen_on_board")
	_check("rules: event board_lost", _has_event(res, "board_lost"))

func _test_rules_last_coin_queen_covered_wins() -> void:
	var s := CarromRules.fresh_state(0)
	(s["pocketed"] as Array)[0] = 8
	s["queen"] = "covered"
	s["queen_owner"] = 0
	var res: Dictionary = CarromRules.resolve_shot(s, ["white"], false)
	_check("rules: last coin with queen covered wins", bool(s["over"]) and int(s["winner"]) == 0)
	_check("rules: event board_won", _has_event(res, "board_won"))

func _test_rules_striker_foul_alone() -> void:
	var s := CarromRules.fresh_state(0)
	(s["pocketed"] as Array)[0] = 2
	var res: Dictionary = CarromRules.resolve_shot(s, [], true)
	_check("rules: striker foul loses turn", int(s["turn"]) == 1)
	_check("rules: striker foul returns one coin", int((s["pocketed"] as Array)[0]) == 1)
	_check("rules: event foul_striker", _has_event(res, "foul_striker"))

func _test_rules_striker_foul_with_coins() -> void:
	var s := CarromRules.fresh_state(0)
	(s["pocketed"] as Array)[0] = 2
	var res: Dictionary = CarromRules.resolve_shot(s, ["white", "white"], true)
	# Striker + own coins: those coins come back + one more due, keep turn.
	_check("rules: striker+coins keeps turn", int(s["turn"]) == 0)
	_check("rules: striker+coins returns pocketed coins", int((s["pocketed"] as Array)[0]) == 1, str((s["pocketed"] as Array)[0]))
	_check("rules: event coins_returned", _has_event(res, "coins_returned"))

func _test_rules_opponent_last_coin_loses() -> void:
	var s := CarromRules.fresh_state(0)
	(s["pocketed"] as Array)[1] = 8
	var res: Dictionary = CarromRules.resolve_shot(s, ["black"], false)
	_check("rules: pocketing opponent's last coin loses", bool(s["over"]) and int(s["winner"]) == 1)
	_check("rules: event board_lost", _has_event(res, "board_lost"))

func _test_rules_due_owed() -> void:
	var s := CarromRules.fresh_state(0)
	# Foul with nothing pocketed: due is owed.
	CarromRules.resolve_shot(s, [], true)
	_check("rules: due owed when nothing pocketed", int((s["due"] as Array)[0]) == 1)
	# Opponent plays, then shooter pockets a coin: due is paid from it.
	CarromRules.resolve_shot(s, [], false) # opponent turn passes back
	var res: Dictionary = CarromRules.resolve_shot(s, ["white"], false)
	_check("rules: due paid from first pocketed coin", int((s["pocketed"] as Array)[0]) == 0 and int((s["due"] as Array)[0]) == 0)
	_check("rules: event due_paid", _has_event(res, "due_paid"))

func _has_event(res: Dictionary, type: String) -> bool:
	for e in res["events"]:
		if String(e["type"]) == type:
			return true
	return false

# ------------------------------------------------------------------------ AI

func _test_ai_break_shot() -> void:
	var pieces := CarromPhysics.setup_pieces()
	var state := CarromRules.fresh_state(1) # AI (seat 1) breaks
	var shot: Dictionary = CarromAI.choose_shot(pieces, "black", 2, state, true)
	_check("ai: break shot has dir", (shot["dir"] as Vector2).length() > 0.9)
	_check("ai: break shot near full power", float(shot["power"]) > 0.8, str(float(shot["power"])))
	_check("ai: break striker x on baseline", absf(float(shot["striker_x"]) - 360.0) < 250.0)

func _test_ai_midgame_shot() -> void:
	var pieces := CarromPhysics.setup_pieces()
	# Scatter a few coins to make a mid-game position.
	pieces[1]["pos"] = Vector2(300, 450)
	pieces[2]["pos"] = Vector2(420, 500)
	var state := CarromRules.fresh_state(1)
	(state["pocketed"] as Array)[1] = 2
	var shot: Dictionary = CarromAI.choose_shot(pieces, "black", 2, state, false)
	_check("ai: midgame shot valid dir", (shot["dir"] as Vector2).length() > 0.9)
	_check("ai: midgame power in range", float(shot["power"]) >= 0.15 and float(shot["power"]) <= 1.0)

func _test_ai_easy_misses_sometimes() -> void:
	var pieces := CarromPhysics.setup_pieces()
	var state := CarromRules.fresh_state(1)
	var dirs: Array = []
	for i in range(30):
		var shot: Dictionary = CarromAI.choose_shot(pieces, "black", 0, state, true)
		dirs.append((shot["dir"] as Vector2).angle())
	var spread := 0.0
	for d in dirs:
		spread = maxf(spread, absf(float(d) - float(dirs[0])))
	_check("ai: easy has aim spread (error applied)", spread > 0.02, str(spread))

# ------------------------------------------------------------------ shop/aim

func _test_shop_stats_capped() -> void:
	var best := ShopData.striker_by_id("diamond")
	var base := ShopData.striker_by_id("classic")
	_check("shop: best force <= +15%", float(best["force"]) <= float(base["force"]) * 1.15 + 0.001)
	_check("shop: best aim <= +15%", float(best["aim"]) <= float(base["aim"]) * 1.15 + 0.001)
	_check("shop: 6 boards", ShopData.BOARDS.size() == 6)
	_check("shop: 7 strikers", ShopData.STRIKERS.size() == 7)
	_check("shop: max speed scales with force", ShopData.max_speed("diamond") > ShopData.max_speed("classic"))

func _test_ray_circle() -> void:
	var t := CarromPhysics.ray_circle(Vector2(0, 0), Vector2(1, 0), Vector2(100, 0), 10.0)
	_check("ray: hits circle ahead", _approx(t, 90.0, 1.0), str(t))
	var miss := CarromPhysics.ray_circle(Vector2(0, 0), Vector2(1, 0), Vector2(100, 50), 10.0)
	_check("ray: misses circle off-line", miss < 0.0, str(miss))

func _test_full_break_simulation() -> void:
	var pieces := CarromPhysics.setup_pieces()
	var state := CarromRules.fresh_state(0)
	var shot: Dictionary = CarromAI.choose_shot(pieces, "white", 2, state, true)
	var striker: Dictionary = pieces[pieces.size() - 1]
	striker["pos"] = Vector2(float(shot["striker_x"]), CarromPhysics.baseline_y(0))
	striker["vel"] = (shot["dir"] as Vector2) * float(shot["power"]) * ShopData.max_speed("classic")
	var res: Dictionary = CarromPhysics.simulate(pieces, 8.0)
	_check("sim: break shot settles", CarromPhysics.all_stopped(pieces))
	_check("sim: break scatters coins", _scattered(pieces))
	# Rules resolve on the simulated result without crashing.
	var r: Dictionary = CarromRules.resolve_shot(state, res["pocketed"], bool(res["striker_pocketed"]))
	_check("sim: rules resolve after break", r.has("events"))

func _scattered(pieces: Array) -> bool:
	for p in pieces:
		if p["kind"] == "white" and (p["pos"] as Vector2).distance_to(CarromPhysics.BOARD_CENTER) > 80.0:
			return true
	return false

## Full match, AI vs AI (Hard), with the board mirrored for seat 0 (the AI
## picks shots from the top baseline). Validates the whole loop end to end:
## turns, queen cover, fouls/dues, coin returns, and a winner.
func _test_full_match_ai_vs_ai() -> void:
	var pieces := CarromPhysics.setup_pieces()
	var state := CarromRules.fresh_state(randi() % 2)
	var striker: Dictionary = pieces[pieces.size() - 1]
	var shots := 0
	var queen_returns := 0
	var fouls := 0
	while not bool(state["over"]) and shots < 300:
		var seat: int = state["turn"]
		# Striker on the current player's baseline.
		striker["active"] = true
		striker["vel"] = Vector2.ZERO
		striker["pos"] = Vector2(CarromPhysics.BOARD_CENTER.x, CarromPhysics.baseline_y(seat))
		var own := CarromRules.own_color(state, seat)
		var is_break := shots == 0
		var shot: Dictionary
		if seat == 1:
			shot = CarromAI.choose_shot(pieces, own, 2, state, is_break)
		else:
			# Mirror the board vertically so the AI (top-baseline logic)
			# can pick a shot for the bottom player.
			var mirrored := _mirror_pieces(pieces)
			shot = CarromAI.choose_shot(mirrored, own, 2, state, is_break)
			shot["dir"] = (shot["dir"] as Vector2) * Vector2(1, -1)
		striker["pos"].x = float(shot["striker_x"])
		striker["vel"] = (shot["dir"] as Vector2) * float(shot["power"]) * ShopData.max_speed("classic")
		var res: Dictionary = CarromPhysics.simulate(pieces, 8.0)
		var events: Dictionary = CarromRules.resolve_shot(state, res["pocketed"], bool(res["striker_pocketed"]))
		for e in events["events"]:
			match String(e["type"]):
				"queen_returned", "queen_early":
					queen_returns += 1
					_reactivate_test(pieces, "queen", CarromPhysics.BOARD_CENTER)
				"coins_returned":
					for i in range(int(e["count"])):
						_reactivate_test(pieces, own, CarromPhysics.BOARD_CENTER)
				"due_paid":
					_reactivate_test(pieces, own, CarromPhysics.BOARD_CENTER)
				"foul_striker":
					fouls += 1
		shots += 1
	_check("match: AI vs AI finishes", bool(state["over"]), "shots=%d winner=%s pocketed=%s queen=%s" % [shots, str(state["winner"]), str(state["pocketed"]), str(state["queen"])])
	_check("match: winner is a real player", int(state["winner"]) == 0 or int(state["winner"]) == 1)
	_check("match: finished in a sane number of shots", shots < 300 and shots > 5, "shots=%d" % shots)
	_check("match: winner cleared all 9 coins (or won on opponent's mistake)",
		int((state["pocketed"] as Array)[int(state["winner"])]) == 9 or String(state["lose_reason"]) != "",
		"pocketed=%s lose_reason=%s" % [str(state["pocketed"]), str(state["lose_reason"])])
	print("INFO: full AI match: %d shots, %d queen returns, %d fouls, winner=%d" % [shots, queen_returns, fouls, int(state["winner"])])

func _mirror_pieces(pieces: Array) -> Array:
	var out: Array = []
	var cy := CarromPhysics.BOARD_CENTER.y
	for p in pieces:
		var q: Dictionary = (p as Dictionary).duplicate()
		q["pos"] = Vector2((p["pos"] as Vector2).x, 2.0 * cy - (p["pos"] as Vector2).y)
		out.append(q)
	return out

func _reactivate_test(pieces: Array, kind: String, near: Vector2) -> void:
	for p in pieces:
		if not p["active"] and p["kind"] == kind:
			p["active"] = true
			p["vel"] = Vector2.ZERO
			p["pos"] = near + Vector2(30, 0)
			return

# ------------------------------------------------------------- v5: geometry
## ICF base circles: exactly 8 centres, 2 per corner, the pair clearly
## separated (centre distance ~37 px, gap ~11 px), all on the lane
## centreline (same radius from the board centre), and the bottom side's
## right centre exactly where the geometry says it must be.
func _test_base_circle_geometry() -> void:
	var centers: Array = BoardView.base_circle_centers()
	_check("geo: 8 base circles", centers.size() == 8, str(centers.size()))
	var c := CarromPhysics.BOARD_CENTER
	var min_pair := 1e9
	var max_pair := 0.0
	var all_on_lane := true
	for i in range(centers.size()):
		var r := (centers[i] as Vector2).distance_to(c)
		if not _approx(r, 277.4, 1.0):
			all_on_lane = false
		for j in range(i + 1, centers.size()):
			var d := (centers[i] as Vector2).distance_to(centers[j] as Vector2)
			min_pair = minf(min_pair, d)
			max_pair = maxf(max_pair, d)
	_check("geo: all centres on the lane centreline (r ~277.4)", all_on_lane)
	_check("geo: closest pair ~37 px apart (gap ~11 px)", min_pair > 30.0 and min_pair < 45.0, str(min_pair))
	_check("geo: opposite corners far apart", max_pair > 300.0, str(max_pair))
	var found_br := false
	var found_bl := false
	for p in centers:
		if (p as Vector2).distance_to(Vector2(542.7, 798.85)) < 1.5:
			found_br = true
		if (p as Vector2).distance_to(Vector2(177.3, 798.85)) < 1.5:
			found_bl = true
	_check("geo: bottom-right base circle at (542.7, 798.85)", found_br)
	_check("geo: bottom-left base circle at (177.3, 798.85)", found_bl)
	# Striker centres on the corrected lane (306 - 208.85 = 97.15).
	_check("geo: baseline_y(0) centres striker on the lane", _approx(CarromPhysics.baseline_y(0), 798.85, 1.0), str(CarromPhysics.baseline_y(0)))

# -------------------------------------------------------------- v5: staking
func _test_stakes() -> void:
	_check("stakes: band 0 below 250", Stakes.band_for_stake(0) == 0 and Stakes.band_for_stake(249) == 0)
	_check("stakes: band 1 from 250", Stakes.band_for_stake(250) == 1 and Stakes.band_for_stake(999) == 1)
	_check("stakes: band 2 from 1000", Stakes.band_for_stake(1000) == 2 and Stakes.band_for_stake(50000) == 2)
	_check("stakes: 0 and full balance are valid", Stakes.valid_stake(0, 1000) and Stakes.valid_stake(1000, 1000))
	_check("stakes: over balance is invalid", not Stakes.valid_stake(1001, 1000))
	_check("stakes: negative is invalid", not Stakes.valid_stake(-1, 1000))
	_check("stakes: pot is both stakes", Stakes.pot(200, 350) == 550)
	_check("stakes: win takes the whole pot", Stakes.payout(200, 350, "win") == 550)
	_check("stakes: loss takes nothing", Stakes.payout(200, 350, "loss") == 0)
	_check("stakes: draw refunds own stake", Stakes.payout(200, 350, "draw") == 200)
	_check("stakes: win with zero stakes pays zero", Stakes.payout(0, 0, "win") == 0)
	_check("stakes: draw with zero stakes refunds zero", Stakes.payout(0, 0, "draw") == 0)

# -------------------------------------------------------------- v5: economy
## Constants only (no Save instance): the v5 coin model — ad ladder +
## online stakes are the only sources; solo pays zero; no free grants.
func _test_economy_v5_consts() -> void:
	var SaveScript: GDScript = load("res://scripts/save_data.gd")
	_check("econ: ladder tiers 150/200/250/300/400", SaveScript.AD_LADDER == [150, 200, 250, 300, 400])
	_check("econ: daily ad cap 2500", SaveScript.DAILY_AD_COIN_CAP == 2500)
	_check("econ: cap is exactly 8 ads (150+200+250+300+400x4)", 150 + 200 + 250 + 300 + 400 * 4 == SaveScript.DAILY_AD_COIN_CAP)
	_check("econ: starting balance stays 1000", SaveScript.STARTING_COINS == 1000)
