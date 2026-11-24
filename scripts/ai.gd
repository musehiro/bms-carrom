class_name CarromAI
extends RefCounted

## Error-based AI (design doc 6.2): the AI picks the best shot by geometry,
## then adds Gaussian aim/power error per difficulty. Easy never chases the
## queen; Medium sometimes does; Hard chases her and plays cut + bank shots.
##
## Difficulties: 0 Easy, 1 Medium, 2 Hard, 3 Advanced, 4 Expert, 5 Master
## (World Tour bots, v8 — all above Hard).
##   Easy:     aim error ~2 deg, power error ~16%, misses ~1 in 5
##   Medium:   aim error ~1 deg, power error ~8%
##   Hard:     aim error ~0.3 deg, power error ~3%
##   Advanced: aim error ~0.15 deg, power error ~2%
##   Expert:   aim error ~0.1 deg, power error ~1.5%
##   Master:   aim error ~0.05 deg, power error ~1%
## Difficulties 3+ also play SMARTER, not just straighter (v8):
##   * Queen cover is urgent: when the queen is pending for the AI (she
##     must be covered on this very shot or she returns), own-coin shots
##     get a big bonus — the cover comes first.
##   * Defensive when ahead: ahead by 2+ coins, the AI stops chasing
##     the queen (she is not worth the risk) and penalises high cut
##     angles harder — it protects the lead instead of gambling.
##     EXCEPTION (last-coin guard): at 8 pocketed with the queen still
##     uncovered, the queen is the ONLY target — a plain 9th coin
##     forfeits the board, so defending never suppresses the chase there.
##   * Striker safety: shots whose striker would end up near a pocket
##     (a foul waiting to happen) are penalised.
##   * Bank shots: when no direct shot exists, the AI tries a
##     one-cushion bank (mirror the target across the cushion) before
##     falling back to a defensive nudge.

const ERRORS := [
	{"aim_deg": 2.0, "power": 0.16, "miss_chance": 0.20, "queen_chase": 0.0},
	{"aim_deg": 1.0, "power": 0.08, "miss_chance": 0.05, "queen_chase": 0.5},
	{"aim_deg": 0.3, "power": 0.03, "miss_chance": 0.0, "queen_chase": 1.0},
	{"aim_deg": 0.15, "power": 0.02, "miss_chance": 0.0, "queen_chase": 1.0},
	{"aim_deg": 0.10, "power": 0.015, "miss_chance": 0.0, "queen_chase": 1.0},
	{"aim_deg": 0.05, "power": 0.01, "miss_chance": 0.0, "queen_chase": 1.0},
]

static func _gauss(sigma: float) -> float:
	# Box-Muller gaussian.
	var u1 := randf()
	var u2 := randf()
	if u1 < 0.00001:
		u1 = 0.00001
	return sqrt(-2.0 * log(u1)) * cos(TAU * u2) * sigma

## Choose a shot. Returns {"striker_x": float, "dir": Vector2, "power": float}.
## ai_seat is the AI's seat (default 1, the top seat in solo/tour matches).
static func choose_shot(pieces: Array, own_color: String, difficulty: int, rules_state: Dictionary, is_break: bool, ai_seat: int = 1) -> Dictionary:
	var cfg: Dictionary = ERRORS[clampi(difficulty, 0, ERRORS.size() - 1)]
	var baseline_y := CarromPhysics.baseline_y(1) # AI plays from the top
	var best := {}
	var best_score := -1.0e9

	# Game sense (v8): how the board stands for the AI.
	var my_team := CarromRules.team_of(rules_state, ai_seat)
	var my_pocketed := int((rules_state.get("pocketed", [0, 0]) as Array)[my_team])
	var opp_pocketed := int((rules_state.get("pocketed", [0, 0]) as Array)[1 - my_team])
	var ahead_by := my_pocketed - opp_pocketed
	var defending := ahead_by >= 2
	# Last-coin guard (win/lose fix): pocketing your 9th coin while the
	# queen is still uncovered LOSES the board (rules.gd: the queen must
	# be "covered", or already covered by the opponent — then clearing
	# your coins still wins). At 8 coins with the queen uncovered, the
	# AI must chase the queen and NEVER take the plain 9th-coin shot.
	# The one safe exception is a queen pending for the AI herself:
	# pocketing an own coin on this shot COVERS her (rules.gd), so the
	# cover shot is the winning shot, not a forfeit. A queen pending for
	# the other side can never be the state at the AI's turn start (the
	# shooter keeps the turn after pocketing her), but it is treated as
	# uncovered here anyway — the safe default.
	var queen_state := String(rules_state.get("queen", "board"))
	var queen_pending_me := queen_state == "pending" and int(rules_state.get("queen_owner", -1)) == ai_seat
	var last_coin_guard := my_pocketed == 8 and queen_state != "covered" and not queen_pending_me
	# Queen pending for the AI: she MUST be covered on this shot or she
	# goes back to the centre — covering her outranks everything.

	# Candidate targets: own coins, plus the queen when allowed.
	# Defending a lead: never chase the queen — she is not worth the risk.
	# EXCEPT under the last-coin guard: at 8 coins with the queen
	# uncovered, the queen is the ONLY safe target — defending must never
	# suppress queen-chasing there (a plain 9th coin forfeits the board).
	var targets: Array = []
	for p in pieces:
		if not p["active"]:
			continue
		if p["kind"] == own_color:
			if not last_coin_guard:
				targets.append(p)
		elif p["kind"] == "queen" and (last_coin_guard or (float(cfg["queen_chase"]) > 0.0 and not defending)):
			# "returned" is on the board too (she went back to the centre).
			if my_pocketed >= 1 and (queen_state == "board" or queen_state == "returned"):
				if last_coin_guard or randf() < float(cfg["queen_chase"]):
					targets.append(p)

	if is_break or targets.is_empty():
		if last_coin_guard:
			# No queen to aim at (she is off the board in this position):
			# NEVER blast the centre cluster — a hard break could pocket
			# the 9th coin and lose the board on the spot. Soft nudge
			# straight down the middle instead.
			return _apply_error({"striker_x": CarromPhysics.BOARD_CENTER.x, "dir": Vector2.DOWN, "power": 0.3}, cfg)
		# Break: aim at the centre cluster with near-full power.
		var sx := CarromPhysics.BOARD_CENTER.x + _gauss(30.0)
		var from := Vector2(sx, baseline_y)
		var dir := (CarromPhysics.BOARD_CENTER - from).normalized()
		return _apply_error({"striker_x": sx, "dir": dir, "power": 0.95}, cfg)

	var pockets := CarromPhysics.pocket_centers()
	# Try striker positions along the baseline.
	for sx_i in range(9):
		var sx := CarromPhysics.BOARD_CENTER.x - CarromPhysics.BASELINE_HALF_LEN + float(sx_i) * (2.0 * CarromPhysics.BASELINE_HALF_LEN / 8.0)
		var from := Vector2(sx, baseline_y)
		for target in targets:
			var tpos: Vector2 = target["pos"]
			if not CarromPhysics.path_clear(pieces, from, tpos, target):
				continue
			for pocket in pockets:
				var pk: Vector2 = pocket
				# Coin -> pocket must be clear.
				if not CarromPhysics.path_clear(pieces, tpos, pk, target):
					continue
				var to_coin := (tpos - from)
				var to_pocket: Vector2 = (pk - tpos)
				var d1 := to_coin.length()
				var d2: float = to_pocket.length()
				if d1 < 1.0 or d2 < 1.0:
					continue
				# Cut angle: how far off straight the hit is.
				var cut := rad_to_deg(acos(clampf(to_coin.normalized().dot(to_pocket.normalized()), -1.0, 1.0)))
				if cut > 75.0:
					continue
				# Score: prefer short total distance and small cut angle.
				# Queen targets get a bonus on Hard (she is worth covering).
				var score: float = 1000.0 - d1 * 0.5 - d2 * 0.8 - cut * 6.0
				if target["kind"] == "queen":
					score += 120.0
				# v8 game sense:
				if queen_pending_me and target["kind"] == own_color:
					# Cover first — losing the queen costs 3 points.
					score += 200.0
				if defending:
					# Protect the lead: high cut angles are a gamble.
					score -= cut * 4.0
				# Striker safety: the striker runs on past the coin
				# roughly along the shot line — if it would end up
				# near a pocket, that is a foul waiting to happen.
				score -= _striker_end_risk(tpos, to_coin.normalized(), pockets)
				if score > best_score:
					best_score = score
					var power := clampf(0.35 + (d1 + d2) / 1100.0, 0.3, 0.95)
					best = {"striker_x": sx, "dir": to_coin.normalized(), "power": power}
	if best.is_empty():
		# No direct shot: try a one-cushion bank before the nudge.
		best = _find_bank_shot(pieces, targets, pockets, baseline_y, cfg, queen_pending_me, defending)
	if best.is_empty():
		# No clean shot: hit the nearest own coin toward the nearest pocket
		# with a soft touch (defensive nudge).
		var nearest = null
		var nearest_d := 1.0e9
		for target in targets:
			var d := Vector2(target["pos"].x, baseline_y).distance_to(target["pos"])
			if d < nearest_d:
				nearest_d = d
				nearest = target
		if nearest == null:
			return {"striker_x": CarromPhysics.BOARD_CENTER.x, "dir": Vector2.DOWN, "power": 0.4}
		var from := Vector2(clampf(nearest["pos"].x, CarromPhysics.BOARD_CENTER.x - CarromPhysics.BASELINE_HALF_LEN, CarromPhysics.BOARD_CENTER.x + CarromPhysics.BASELINE_HALF_LEN), baseline_y)
		best = {"striker_x": from.x, "dir": (nearest["pos"] - from).normalized(), "power": 0.45}
	return _apply_error(best, cfg)

## Penalty when the striker's estimated resting spot (220 px past the
## hit coin, along the shot line) lands near a pocket. 0 when safe.
static func _striker_end_risk(tpos: Vector2, shot_dir: Vector2, pockets: Array) -> float:
	var end_pos: Vector2 = tpos + shot_dir * 220.0
	for pk in pockets:
		if end_pos.distance_to(pk as Vector2) < 70.0:
			return 150.0
	return 0.0

## One-cushion bank shot: mirror the target coin across the cushion's
## striker-bounce line, aim at the mirrored coin — the striker bounces
## off the cushion into the real coin. Returns a shot dict or {} when
## no bank exists. Pure geometry, unit-testable via bank_shot_for().
static func _find_bank_shot(pieces: Array, targets: Array, pockets: Array, baseline_y: float, cfg: Dictionary, queen_pending_me: bool, defending: bool) -> Dictionary:
	var best := {}
	var best_score := -1.0e9
	for sx_i in range(9):
		var sx := CarromPhysics.BOARD_CENTER.x - CarromPhysics.BASELINE_HALF_LEN + float(sx_i) * (2.0 * CarromPhysics.BASELINE_HALF_LEN / 8.0)
		var from := Vector2(sx, baseline_y)
		for target in targets:
			var shot: Dictionary = bank_shot_for(pieces, from, target, pockets)
			if shot.is_empty():
				continue
			var score: float = float(shot["score"])
			if queen_pending_me:
				score += 200.0
			if defending:
				score -= 40.0 # banks are a gamble; less so when protecting a lead
			if score > best_score:
				best_score = score
				best = {"striker_x": sx, "dir": shot["dir"], "power": shot["power"]}
	return best

## The bank geometry for one striker position and one target coin.
## Returns {"dir": Vector2, "power": float, "score": float} or {}.
## The striker bounces off a cushion line (offset by the striker radius,
## where its centre actually turns) into the coin, which then runs to a
## pocket. The bounce point must sit on the wall segment, clear of the
## corner pockets, with both legs of the path clear.
static func bank_shot_for(pieces: Array, from: Vector2, target: Dictionary, pockets: Array) -> Dictionary:
	var tpos: Vector2 = target["pos"]
	var c := CarromPhysics.BOARD_CENTER
	var half := CarromPhysics.SURFACE_HALF
	var r := CarromPhysics.STRIKER_R
	# Cushion lines the striker centre bounces on: [axis, line, is_vertical].
	var walls := [
		{"v": true, "line": c.x - half + r},
		{"v": true, "line": c.x + half - r},
		{"v": false, "line": c.y - half + r},
		{"v": false, "line": c.y + half - r},
	]
	var best := {}
	var best_score := -1.0e9
	for wall in walls:
		var mirrored := Vector2.ZERO
		if bool(wall["v"]):
			mirrored = Vector2(2.0 * float(wall["line"]) - tpos.x, tpos.y)
		else:
			mirrored = Vector2(tpos.x, 2.0 * float(wall["line"]) - tpos.y)
		var to_mirror := mirrored - from
		if to_mirror.length() < 1.0:
			continue
		var dir := to_mirror.normalized()
		# Bounce point: where the ray crosses the wall line.
		var t := -1.0
		if bool(wall["v"]):
			if absf(dir.x) < 0.001:
				continue
			t = (float(wall["line"]) - from.x) / dir.x
		else:
			if absf(dir.y) < 0.001:
				continue
			t = (float(wall["line"]) - from.y) / dir.y
		if t <= 0.0:
			continue
		var bounce: Vector2 = from + dir * t
		# The bounce must sit on the wall segment (not past a corner).
		if bool(wall["v"]):
			if bounce.y < c.y - half + r or bounce.y > c.y + half - r:
				continue
		else:
			if bounce.x < c.x - half + r or bounce.x > c.x + half - r:
				continue
		# Keep the bounce clear of the corner pockets.
		var near_pocket := false
		for pk in pockets:
			if bounce.distance_to(pk as Vector2) < 45.0:
				near_pocket = true
				break
		if near_pocket:
			continue
		if not CarromPhysics.path_clear(pieces, from, bounce, target):
			continue
		if not CarromPhysics.path_clear(pieces, bounce, tpos, target):
			continue
		# The coin leaves along the striker's arrival direction.
		var coin_dir := (tpos - bounce).normalized()
		for pocket in pockets:
			var pk: Vector2 = pocket
			if not CarromPhysics.path_clear(pieces, tpos, pk, target):
				continue
			var to_pocket: Vector2 = pk - tpos
			var d2: float = to_pocket.length()
			if d2 < 1.0:
				continue
			var cut := rad_to_deg(acos(clampf(coin_dir.dot(to_pocket.normalized()), -1.0, 1.0)))
			if cut > 75.0:
				continue
			# Banks score below direct shots (same geometry, -100).
			var d1 := (tpos - from).length()
			var score: float = 900.0 - d1 * 0.5 - d2 * 0.8 - cut * 6.0
			if score > best_score:
				best_score = score
				var power := clampf((0.35 + (d1 + d2) / 1100.0) * 1.15, 0.3, 0.95)
				best = {"dir": dir, "power": power, "score": score}
	return best

static func _apply_error(shot: Dictionary, cfg: Dictionary) -> Dictionary:
	var dir: Vector2 = shot["dir"]
	var power: float = shot["power"]
	# Occasional outright miss (Easy).
	if randf() < float(cfg["miss_chance"]):
		dir = dir.rotated(deg_to_rad(randf_range(6.0, 12.0) * (1.0 if randf() < 0.5 else -1.0)))
	else:
		dir = dir.rotated(deg_to_rad(_gauss(float(cfg["aim_deg"]))))
	power = clampf(power * (1.0 + _gauss(float(cfg["power"]))), 0.15, 1.0)
	shot["dir"] = dir.normalized()
	shot["power"] = power
	return shot

static func _find(pieces: Array, kind: String) -> Dictionary:
	for p in pieces:
		if p["kind"] == kind:
			return p
	return {}
