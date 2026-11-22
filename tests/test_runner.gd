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
	_test_world_tour_roster()
	_test_world_tour_stakes()
	_test_ai_advanced_errors()
	_test_ai_advanced_accuracy()
	_test_ai_queen_cover()
	_test_ai_defensive_no_queen_chase()
	_test_ai_bank_shot()
	_test_ai_striker_safety()
	_test_shop_stats_capped()
	_test_ray_circle()
	_test_full_break_simulation()
	_test_full_match_ai_vs_ai()
	_test_base_circle_geometry()
	_test_stakes()
	_test_economy_v5_consts()
	_test_supabase_pkce()
	_test_supabase_realtime_parse()
	_test_supabase_rows()
	_test_net_invite_join_message()
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

# ------------------------------------------------------- v8: World Tour
## Helpers: first piece a ray would hit, and whether a shot is a bank.
func _ray_first_piece(pieces: Array, from: Vector2, dir: Vector2) -> Dictionary:
	# First active piece the ray from `from` along `dir` would hit
	# (same clearance as CarromPhysics.path_clear), or {}.
	var best_t := -1.0
	var best: Dictionary = {}
	for p in pieces:
		if not bool(p["active"]) or String(p["kind"]) == "striker":
			continue
		var t := CarromPhysics.ray_circle(from, dir, p["pos"], float(p["r"]) + CarromPhysics.COIN_R + 1.0)
		if t >= 0.0 and (best_t < 0.0 or t < best_t):
			best_t = t
			best = p
	return best

func _ray_target_kind(pieces: Array, from: Vector2, dir: Vector2) -> String:
	var p := _ray_first_piece(pieces, from, dir)
	return String(p.get("kind", "")) if not p.is_empty() else ""

func _shot_hits_wall_first(from: Vector2, dir: Vector2, target: Vector2) -> bool:
	# True when the ray from `from` along `dir` reaches a cushion line
	# before it would reach `target` — i.e. the shot is a bank, not a
	# direct hit. Cushion lines are offset by the striker radius, where
	# its centre actually turns (same lines as CarromAI.bank_shot_for).
	var c := CarromPhysics.BOARD_CENTER
	var half := CarromPhysics.SURFACE_HALF
	var r := CarromPhysics.STRIKER_R
	var wall_t := -1.0
	var walls := [
		{"v": true, "line": c.x - half + r},
		{"v": true, "line": c.x + half - r},
		{"v": false, "line": c.y - half + r},
		{"v": false, "line": c.y + half - r},
	]
	for wall in walls:
		var t := -1.0
		var hit := Vector2.ZERO
		if bool(wall["v"]):
			if absf(dir.x) < 0.001:
				continue
			t = (float(wall["line"]) - from.x) / dir.x
			hit = from + dir * t
			if hit.y < c.y - half + r or hit.y > c.y + half - r:
				continue
		else:
			if absf(dir.y) < 0.001:
				continue
			t = (float(wall["line"]) - from.y) / dir.y
			hit = from + dir * t
			if hit.x < c.x - half + r or hit.x > c.x + half - r:
				continue
		if t > 0.0 and (wall_t < 0.0 or t < wall_t):
			wall_t = t
	if wall_t < 0.0:
		return false
	var to_target := target - from
	var proj := to_target.dot(dir)
	if proj <= 0.0:
		return true # target is behind the shot: the wall comes first
	var perp := (to_target - dir * proj).length()
	if perp < 30.0:
		return wall_t < proj
	return true # the ray never reaches the target: the wall comes first

func _tour_pieces(spec: Array) -> Array:
	# spec: [[kind, pos], ...] — plus the striker on the bottom baseline.
	var out: Array = []
	for s in spec:
		out.append(CarromPhysics.make_piece(String(s[0]), s[1]))
	out.append(CarromPhysics.make_piece("striker", Vector2(CarromPhysics.BOARD_CENTER.x, CarromPhysics.baseline_y(0))))
	return out

func _bank_fence_pieces() -> Array:
	# One own coin whose direct paths from every baseline position are
	# blocked by a fence of white coins — the only way to hit it is a
	# one-cushion bank. Target (300,550); fence at y=405, x=190..505.
	# The fence sits far above the bank legs (the left-wall bank runs
	# from (71,430) down to the target), so the bank stays open.
	var spec: Array = [["black", Vector2(300, 550)]]
	for x in [190, 235, 280, 325, 370, 415, 460, 505]:
		spec.append(["white", Vector2(x, 405)])
	return _tour_pieces(spec)

func _collect_label_texts(node: Node, out: Array) -> void:
	for n in node.get_children():
		if n is Label:
			out.append((n as Label).text)
		_collect_label_texts(n, out)

func _test_world_tour_roster() -> void:
	_check("tour: 5 bots on the roster", WorldTour.BOTS.size() == 5, str(WorldTour.BOTS.size()))
	var ids := {}
	var names := {}
	var all_ok := true
	var prev_level := 0
	for b in WorldTour.BOTS:
		var bid := String(b.get("id", ""))
		var nm := String(b.get("name", ""))
		if bid == "" or nm == "" or ids.has(bid) or names.has(nm):
			all_ok = false
		ids[bid] = true
		names[nm] = true
		if String(b.get("country", "")) == "" or String(b.get("blurb", "")) == "":
			all_ok = false
		if int(b.get("skill", 0)) < 3 or int(b.get("skill", 0)) > 5:
			all_ok = false
		if int(b.get("level", 0)) <= prev_level:
			all_ok = false
		prev_level = int(b.get("level", 0))
		if not (b.get("color") is Color):
			all_ok = false
	_check("tour: unique ids + names, country + blurb set, skill 3-5, levels rising, avatar colour set", all_ok)
	_check("tour: skill names", WorldTour.skill_name(3) == "ADVANCED" and WorldTour.skill_name(4) == "EXPERT" and WorldTour.skill_name(5) == "MASTER")
	_check("tour: bot_by_id finds Arjun (India)", String(WorldTour.bot_by_id("arjun").get("name", "")) == "Arjun Mehta" and String(WorldTour.bot_by_id("arjun").get("country", "")) == "India")
	_check("tour: bot_by_id finds Emma the Master (Lv 26)", int(WorldTour.bot_by_id("emma").get("skill", 0)) == 5 and int(WorldTour.bot_by_id("emma").get("level", 0)) == 26)
	_check("tour: bot_by_id unknown returns empty", WorldTour.bot_by_id("nobody").is_empty())
	_check("tour: every bot above Hard (skill > 2)",
		int(WorldTour.bot_by_id("arjun").get("skill", 0)) > 2 and int(WorldTour.bot_by_id("kasun").get("skill", 0)) > 2 and int(WorldTour.bot_by_id("sarah").get("skill", 0)) > 2 and int(WorldTour.bot_by_id("david").get("skill", 0)) > 2 and int(WorldTour.bot_by_id("emma").get("skill", 0)) > 2)
	# Honest labelling (hard rule, design doc 3.2): the roster screen
	# itself must say BOT / COMPUTER and never claim a real player.
	# Note: in -s mode the tree never iterates, so _ready would not fire
	# after add_child before quit() — build the screen by calling
	# _ready() directly (the same code the live screen runs).
	var scr := TourRosterScreen.new()
	scr._ready()
	var texts: Array = []
	_collect_label_texts(scr, texts)
	var joined := " ".join(texts)
	_check("tour: roster says COMPUTER opponents", joined.contains("COMPUTER"))
	_check("tour: roster tags opponents BOT", joined.contains("BOT"))
	_check("tour: roster never claims a real player",
		not joined.contains("searching for a real") and not joined.contains("real person") and not joined.contains("human opponent") and not joined.contains("real human") and not joined.contains("find a real player"))
	scr.free()

func _test_world_tour_stakes() -> void:
	_check("tour stakes: bot mirrors the stake", WorldTour.mirror_stake(100) == 100 and WorldTour.mirror_stake(250) == 250)
	_check("tour stakes: zero mirrors zero", WorldTour.mirror_stake(0) == 0)
	_check("tour stakes: negative mirrors to zero", WorldTour.mirror_stake(-50) == 0)
	_check("tour stakes: pot is 2x the stake", Stakes.pot(100, WorldTour.mirror_stake(100)) == 200)
	_check("tour stakes: win takes the whole pot", Stakes.payout(100, WorldTour.mirror_stake(100), "win") == 200)
	_check("tour stakes: loss takes nothing", Stakes.payout(100, WorldTour.mirror_stake(100), "loss") == 0)
	_check("tour stakes: draw refunds own stake", Stakes.payout(100, WorldTour.mirror_stake(100), "draw") == 100)
	var all_double := true
	for s in [0, 50, 100, 250, 1000]:
		if Stakes.pot(s, WorldTour.mirror_stake(s)) != 2 * s:
			all_double = false
		if Stakes.payout(s, WorldTour.mirror_stake(s), "win") != 2 * s:
			all_double = false
		if Stakes.payout(s, WorldTour.mirror_stake(s), "draw") != s:
			all_double = false
	_check("tour stakes: pot is always 2x stake (win 2x, draw refunds)", all_double)
	_check("tour stakes: same picker validation as online", Stakes.valid_stake(100, 1000) and not Stakes.valid_stake(1001, 1000))

func _test_ai_advanced_errors() -> void:
	_check("ai adv: 6 difficulties defined", CarromAI.ERRORS.size() == 6, str(CarromAI.ERRORS.size()))
	var hard: Dictionary = CarromAI.ERRORS[2]
	var ok := true
	for d in [3, 4, 5]:
		var cfg: Dictionary = CarromAI.ERRORS[d]
		if float(cfg["aim_deg"]) >= float(hard["aim_deg"]):
			ok = false
		if float(cfg["power"]) >= float(hard["power"]):
			ok = false
		if float(cfg["miss_chance"]) != 0.0:
			ok = false
		if float(cfg["queen_chase"]) != 1.0:
			ok = false
	_check("ai adv: Advanced/Expert/Master aim straighter than Hard, never miss outright, always chase the queen", ok)
	_check("ai adv: accuracy tightens with skill (Master < Expert < Advanced < Hard)",
		float(CarromAI.ERRORS[5]["aim_deg"]) < float(CarromAI.ERRORS[4]["aim_deg"]) and float(CarromAI.ERRORS[4]["aim_deg"]) < float(CarromAI.ERRORS[3]["aim_deg"]) and float(CarromAI.ERRORS[3]["aim_deg"]) < float(CarromAI.ERRORS[2]["aim_deg"]))
	_check("ai adv: power error tightens with skill",
		float(CarromAI.ERRORS[5]["power"]) < float(CarromAI.ERRORS[4]["power"]) and float(CarromAI.ERRORS[4]["power"]) < float(CarromAI.ERRORS[3]["power"]))
	_check("ai adv: tour skills are exactly 3/4/5", int(WorldTour.BOTS[0]["skill"]) == 3 and int(WorldTour.BOTS[2]["skill"]) == 4 and int(WorldTour.BOTS[4]["skill"]) == 5)

func _mean_abs_dev(angles: Array) -> float:
	var mean := 0.0
	for a in angles:
		mean += float(a)
	mean /= float(angles.size())
	var dev := 0.0
	for a in angles:
		dev += absf(float(a) - mean)
	return dev / float(angles.size())

func _test_ai_advanced_accuracy() -> void:
	# Same mid-game position for both: the ideal shot is identical every
	# time (queen chase is deterministic at 1.0 for Hard+), so the spread
	# of the returned directions measures the aim error alone.
	var pieces := CarromPhysics.setup_pieces()
	pieces[1]["pos"] = Vector2(300, 450)
	pieces[2]["pos"] = Vector2(420, 500)
	var state := CarromRules.fresh_state(1)
	(state["pocketed"] as Array)[1] = 2
	var n := 40
	var angles5: Array = []
	var angles2: Array = []
	for i in range(n):
		angles5.append((CarromAI.choose_shot(pieces, "black", 5, state, false)["dir"] as Vector2).angle())
		angles2.append((CarromAI.choose_shot(pieces, "black", 2, state, false)["dir"] as Vector2).angle())
	var mad5 := _mean_abs_dev(angles5)
	var mad2 := _mean_abs_dev(angles2)
	_check("ai adv: Master aim is far tighter than Hard", mad5 < mad2 / 3.0, "mad5=%f mad2=%f" % [mad5, mad2])
	_check("ai adv: Master mean aim error under 0.005 rad", mad5 < 0.005, str(mad5))
	_check("ai adv: Hard still has real spread (comparison is meaningful)", mad2 > 0.001, str(mad2))

func _test_ai_queen_cover() -> void:
	# Queen pending for the AI (she must be covered on THIS shot or she
	# returns): the AI must still play a normal own-coin shot — the
	# cover attempt — not chase the queen and not nudge away.
	var pieces: Array = []
	pieces.append(CarromPhysics.make_piece("black", Vector2(300, 500)))
	pieces.append(CarromPhysics.make_piece("black", Vector2(450, 450)))
	var queen := CarromPhysics.make_piece("queen", Vector2(360, 590))
	queen["active"] = false # pocketed, pending cover
	pieces.append(queen)
	pieces.append(CarromPhysics.make_piece("striker", Vector2(CarromPhysics.BOARD_CENTER.x, CarromPhysics.baseline_y(0))))
	var state := CarromRules.fresh_state(1)
	(state["pocketed"] as Array)[1] = 1
	state["queen"] = "pending"
	state["queen_owner"] = 1
	var shot: Dictionary = CarromAI.choose_shot(pieces, "black", 3, state, false)
	_check("ai cover: valid shot with queen pending", (shot["dir"] as Vector2).length() > 0.9 and float(shot["power"]) >= 0.15 and float(shot["power"]) <= 1.0)
	var from := Vector2(float(shot["striker_x"]), CarromPhysics.baseline_y(1))
	_check("ai cover: shot aims at an own coin (the cover attempt)", _ray_target_kind(pieces, from, shot["dir"]) == "black", _ray_target_kind(pieces, from, shot["dir"]))
	# Same board with the queen NOT pending: the cover bonus is uniform
	# across own-coin shots, so the chosen striker position must not move.
	var state2 := CarromRules.fresh_state(1)
	(state2["pocketed"] as Array)[1] = 1
	state2["queen"] = "board"
	var shot2: Dictionary = CarromAI.choose_shot(pieces, "black", 3, state2, false)
	_check("ai cover: same striker position with/without pending queen", absf(float(shot2["striker_x"]) - float(shot["striker_x"])) < 0.5, "pending=%s board=%s" % [str(shot["striker_x"]), str(shot2["striker_x"])])
	# Cover urgency via the bank: same fence, queen pending — the AI
	# must still find the bank to cover her, not give up with a nudge.
	var fence := _bank_fence_pieces()
	var state3 := CarromRules.fresh_state(1)
	(state3["pocketed"] as Array)[1] = 1
	state3["queen"] = "pending"
	state3["queen_owner"] = 1
	var shot3: Dictionary = CarromAI.choose_shot(fence, "black", 3, state3, false)
	var from3 := Vector2(float(shot3["striker_x"]), CarromPhysics.baseline_y(1))
	_check("ai cover: bank found to cover the queen", _shot_hits_wall_first(from3, shot3["dir"], Vector2(300, 550)))

func _test_ai_defensive_no_queen_chase() -> void:
	# Queen is the best target on this board (short, near-straight shot
	# to the bottom-left pocket); an own coin is second-best.
	var pieces := _tour_pieces([
		["queen", Vector2(200, 500)],
		["black", Vector2(500, 500)],
	])
	# Not ahead: the AI chases the queen (she is worth 3 points).
	var even := CarromRules.fresh_state(1)
	(even["pocketed"] as Array)[0] = 1
	(even["pocketed"] as Array)[1] = 1
	var shot_even: Dictionary = CarromAI.choose_shot(pieces, "black", 3, even, false)
	var from_even := Vector2(float(shot_even["striker_x"]), CarromPhysics.baseline_y(1))
	_check("ai defence: not ahead — AI chases the queen", _ray_target_kind(pieces, from_even, shot_even["dir"]) == "queen", _ray_target_kind(pieces, from_even, shot_even["dir"]))
	# Ahead by exactly 1: still not defending — queen chase stays on.
	var ahead1 := CarromRules.fresh_state(1)
	(ahead1["pocketed"] as Array)[0] = 1
	(ahead1["pocketed"] as Array)[1] = 2
	var shot_a1: Dictionary = CarromAI.choose_shot(pieces, "black", 3, ahead1, false)
	var from_a1 := Vector2(float(shot_a1["striker_x"]), CarromPhysics.baseline_y(1))
	_check("ai defence: ahead by 1 — still chases the queen", _ray_target_kind(pieces, from_a1, shot_a1["dir"]) == "queen", _ray_target_kind(pieces, from_a1, shot_a1["dir"]))
	# Ahead by 2: defending — the queen is off the table as a target.
	var ahead2 := CarromRules.fresh_state(1)
	(ahead2["pocketed"] as Array)[0] = 1
	(ahead2["pocketed"] as Array)[1] = 3
	var shot_a2: Dictionary = CarromAI.choose_shot(pieces, "black", 3, ahead2, false)
	var from_a2 := Vector2(float(shot_a2["striker_x"]), CarromPhysics.baseline_y(1))
	_check("ai defence: ahead by 2 — AI protects the lead, aims at an own coin", _ray_target_kind(pieces, from_a2, shot_a2["dir"]) == "black", _ray_target_kind(pieces, from_a2, shot_a2["dir"]))
	_check("ai defence: defending changes the chosen shot", absf((shot_a2["dir"] as Vector2).angle_to(shot_even["dir"] as Vector2)) > 0.1)

func _test_ai_bank_shot() -> void:
	var pockets := CarromPhysics.pocket_centers()
	# Direct unit check: a centre target banks off a cushion.
	var pieces := _tour_pieces([["black", Vector2(360, 590)]])
	var from := Vector2(360, CarromPhysics.baseline_y(1))
	var target: Dictionary = pieces[0]
	var bank: Dictionary = CarromAI.bank_shot_for(pieces, from, target, pockets)
	_check("ai bank: bank exists for a centre target", not bank.is_empty())
	_check("ai bank: valid dir + power + score", (bank["dir"] as Vector2).length() > 0.9 and float(bank["power"]) >= 0.3 and float(bank["power"]) <= 0.95 and float(bank["score"]) > 0.0)
	_check("ai bank: the shot bounces off a cushion first", _shot_hits_wall_first(from, bank["dir"], Vector2(360, 590)))
	# Negative: every coin->pocket line blocked (blockers sit ON the
	# diagonals, 30 px off the vertical legs), so no bank exists.
	var blocked := _tour_pieces([
		["black", Vector2(360, 590)],
		["white", Vector2(330, 560)], ["white", Vector2(390, 560)],
		["white", Vector2(330, 620)], ["white", Vector2(390, 620)],
	])
	_check("ai bank: no bank when every pocket line is blocked", CarromAI.bank_shot_for(blocked, from, blocked[0], pockets).is_empty())
	# Integration: direct paths fenced off — choose_shot falls back to a bank.
	var fence := _bank_fence_pieces()
	var state := CarromRules.fresh_state(1)
	var shot: Dictionary = CarromAI.choose_shot(fence, "black", 3, state, false)
	var sfrom := Vector2(float(shot["striker_x"]), CarromPhysics.baseline_y(1))
	_check("ai bank: valid shot when only a bank exists", (shot["dir"] as Vector2).length() > 0.9 and float(shot["power"]) >= 0.15 and float(shot["power"]) <= 1.0)
	_check("ai bank: choose_shot picks the bank (cushion first)", _shot_hits_wall_first(sfrom, shot["dir"], Vector2(300, 550)))

func _test_ai_striker_safety() -> void:
	var pockets := CarromPhysics.pocket_centers()
	# Unit: the striker's estimated rest spot (220 px past the hit coin)
	# near a pocket scores 150; far from every pocket scores 0.
	_check("ai safety: rest spot 47 px from a pocket is risky (150)", CarromAI._striker_end_risk(Vector2(200, 430), Vector2(-0.707, -0.707), pockets) == 150.0)
	_check("ai safety: rest spot far from pockets is safe (0)", CarromAI._striker_end_risk(Vector2(360, 590), Vector2(0, -1), pockets) == 0.0)
	_check("ai safety: 69 px from a pocket is risky", CarromAI._striker_end_risk(Vector2(78, 459), Vector2(0, -1), pockets) == 150.0)
	_check("ai safety: 71 px from a pocket is safe", CarromAI._striker_end_risk(Vector2(78, 457), Vector2(0, -1), pockets) == 0.0)
	# Behaviour: two coins — one whose best shot leaves the striker near
	# a pocket (risky) and one safe. Without the penalty the risky shot
	# scores higher, so the AI must pick the safe coin.
	var pieces := _tour_pieces([
		["black", Vector2(600, 700)],
		["black", Vector2(150, 750)],
	])
	var state := CarromRules.fresh_state(1)
	var shot: Dictionary = CarromAI.choose_shot(pieces, "black", 3, state, false)
	var from := Vector2(float(shot["striker_x"]), CarromPhysics.baseline_y(1))
	var hit := _ray_first_piece(pieces, from, shot["dir"])
	_check("ai safety: AI picks the safe coin, not the risky one",
		not hit.is_empty() and (hit["pos"] as Vector2).distance_to(Vector2(150, 750)) < 40.0,
		"hit=%s" % str(hit.get("pos", Vector2.ZERO)) if not hit.is_empty() else "hit=none")

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

func _test_supabase_pkce() -> void:
	# RFC 7636 Appendix B test vector.
	var challenge := SupabaseClient.pkce_challenge("dBjftJeZ4CVP-mB92K27uhbUJU1p1r_wW1gFWFOEjXk")
	_check("v7 supa: PKCE challenge matches RFC 7636 vector", challenge == "E9Melhoa2OwvFrEMTJguCHaoeK1t8URWbuGJSstw-cM")
	var v := SupabaseClient.random_verifier()
	_check("v7 supa: verifier is 64 chars", v.length() == 64)
	var url := SupabaseClient.google_authorize_url("https://xyz.supabase.co", "dBjftJeZ4CVP-mB92K27uhbUJU1p1r_wW1gFWFOEjXk", "http://127.0.0.1:8765/callback")
	_check("v7 supa: authorize URL has provider + S256 challenge", url.contains("provider=google") and url.contains("code_challenge_method=S256") and url.contains("E9Melhoa2OwvFrEMTJguCHaoeK1t8URWbuGJSstw-cM"))
	_check("v7 supa: authorize URL encodes the loopback redirect", url.contains("http%3A%2F%2F127.0.0.1%3A8765%2Fcallback"))

func _test_supabase_realtime_parse() -> void:
	var join_ok := SupabaseClient.parse_realtime_message(JSON.stringify({
		"topic": "realtime:public:invites", "event": "phx_reply",
		"payload": {"status": "ok", "response": {}}, "ref": "1"}))
	_check("v7 supa: join reply parses as joined", String(join_ok.get("kind", "")) == "joined")
	var invite_msg := SupabaseClient.parse_realtime_message(JSON.stringify({
		"topic": "realtime:public:invites", "event": "postgres_changes",
		"payload": {"data": {"record": {"id": "inv-1", "from_name": "Nimal", "status": "pending"}}}}))
	_check("v7 supa: postgres_changes parses as invite with the row", String(invite_msg.get("kind", "")) == "invite" and String((invite_msg.get("record", {}) as Dictionary).get("from_name", "")) == "Nimal")
	var other := SupabaseClient.parse_realtime_message(JSON.stringify({
		"topic": "realtime:public:profiles", "event": "postgres_changes",
		"payload": {"data": {"record": {"id": "x"}}}}))
	_check("v7 supa: other table ignored", other.is_empty())
	_check("v7 supa: garbage ignored", SupabaseClient.parse_realtime_message("not json").is_empty())
	var hb := SupabaseClient.parse_realtime_message(JSON.stringify({
		"topic": "phoenix", "event": "phx_reply",
		"payload": {"status": "ok"}, "ref": "9"}))
	_check("v7 supa: heartbeat reply parses as heartbeat", String(hb.get("kind", "")) == "heartbeat")

func _test_supabase_rows() -> void:
	var row := SupabaseClient.profile_row("uid-1", "nimal@gmail.com", "Nimal", 1500, 1200, 10, 6, 3, 2,
		["classic", "bms"], ["classic", "gold"], "bms", "gold")
	_check("v7 supa: profile row keeps gmail + coins + xp", String(row.get("gmail", "")) == "nimal@gmail.com" and int(row.get("coins", 0)) == 1500 and int(row.get("xp", 0)) == 1200)
	_check("v7 supa: profile row keeps shop ownership", (row.get("owned_boards", []) as Array).size() == 2 and String(row.get("equipped_striker", "")) == "gold")
	var inv := SupabaseClient.invite_row("grp-1", "uid-1", "uid-2", "Nimal", "Saman", "2p", 100)
	_check("v7 supa: invite row is pending 2p with the stake", String(inv.get("status", "")) == "pending" and String(inv.get("mode", "")) == "2p" and int(inv.get("stake", 0)) == 100)
	_check("v7 supa: invite row carries both names", String(inv.get("from_name", "")) == "Nimal" and String(inv.get("to_name", "")) == "Saman")
	var neg := SupabaseClient.invite_row("grp-1", "uid-1", "uid-2", "Nimal", "Saman", "2p", -50)
	_check("v7 supa: negative stake clamped to 0", int(neg.get("stake", -1)) == 0)
	var join := SupabaseClient.realtime_join_payload("uid-1", "3")
	var filters: Array = ((join.get("payload", {}) as Dictionary).get("config", {}) as Dictionary).get("postgres_changes", [])
	_check("v7 supa: realtime join subscribes to my invites both ways", filters.size() == 2 and String((filters[0] as Dictionary).get("filter", "")).contains("to_id=eq.uid-1") and String((filters[1] as Dictionary).get("filter", "")).contains("from_id=eq.uid-1"))

func _test_net_invite_join_message() -> void:
	var msg := NetClient.invite_join_message("grp-9", "Nimal", 3, 100, "2p", 0, false)
	_check("v7 net: invite_join message shape", String(msg.get("type", "")) == "invite_join" and String(msg.get("group_id", "")) == "grp-9" and int(msg.get("stake", 0)) == 100 and not bool(msg.get("is_inviter", true)))
	var inviter := NetClient.invite_join_message("grp-9", "Me", 3, 100, "4p", 1, true)
	_check("v7 net: inviter flag + 4p mode carried", bool(inviter.get("is_inviter", false)) and String(inviter.get("mode", "")) == "4p" and int(inviter.get("table", -1)) == 1)
