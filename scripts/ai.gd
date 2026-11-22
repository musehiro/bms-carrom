class_name CarromAI
extends RefCounted

## Error-based AI (design doc 6.2): the AI picks the best shot by geometry,
## then adds Gaussian aim/power error per difficulty. Easy never chases the
## queen; Medium sometimes does; Hard chases her and plays cut + bank shots.
##
## Difficulties: 0 Easy, 1 Medium, 2 Hard.
##   Easy:   aim error ~2 deg, power error ~16%, misses ~1 in 5
##   Medium: aim error ~1 deg, power error ~8%
##   Hard:   aim error ~0.3 deg, power error ~3%

const ERRORS := [
	{"aim_deg": 2.0, "power": 0.16, "miss_chance": 0.20, "queen_chase": 0.0},
	{"aim_deg": 1.0, "power": 0.08, "miss_chance": 0.05, "queen_chase": 0.5},
	{"aim_deg": 0.3, "power": 0.03, "miss_chance": 0.0, "queen_chase": 1.0},
]

static func _gauss(sigma: float) -> float:
	# Box-Muller gaussian.
	var u1 := randf()
	var u2 := randf()
	if u1 < 0.00001:
		u1 = 0.00001
	return sqrt(-2.0 * log(u1)) * cos(TAU * u2) * sigma

## Choose a shot. Returns {"striker_x": float, "dir": Vector2, "power": float}.
static func choose_shot(pieces: Array, own_color: String, difficulty: int, rules_state: Dictionary, is_break: bool) -> Dictionary:
	var cfg: Dictionary = ERRORS[clampi(difficulty, 0, 2)]
	var striker: Dictionary = _find(pieces, "striker")
	var baseline_y := CarromPhysics.baseline_y(1) # AI plays from the top
	var best := {}
	var best_score := -1.0e9

	# Candidate targets: own coins, plus the queen when allowed.
	var targets: Array = []
	for p in pieces:
		if not p["active"]:
			continue
		if p["kind"] == own_color:
			targets.append(p)
		elif p["kind"] == "queen" and float(cfg["queen_chase"]) > 0.0:
			var own_pocketed: int = rules_state["pocketed"][1]
			if own_pocketed >= 1 and rules_state["queen"] == "board":
				if randf() < float(cfg["queen_chase"]):
					targets.append(p)

	if is_break or targets.is_empty():
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
				if score > best_score:
					best_score = score
					var power := clampf(0.35 + (d1 + d2) / 1100.0, 0.3, 0.95)
					best = {"striker_x": sx, "dir": to_coin.normalized(), "power": power}
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
