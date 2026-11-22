class_name CarromPhysics
extends RefCounted

## Custom circle-collision physics for carrom (design doc 6.7).
## Deterministic fixed-step solver: circles + walls + pockets.
## Striker is heavier (mass 1.5) than coins (mass 1.0).

const BOARD_CENTER := Vector2(360, 590)
const SURFACE_HALF := 306.0 # half of the 612px playing surface
const FRAME := 34.0
const COIN_R := 13.0
const STRIKER_R := 17.0
const POCKET_R := 19.0
const POCKET_CAPTURE := 21.0 # centre within this of a pocket centre = pocketed
const BASELINE_OFFSET := 97.0 # striker centre line from the surface edge
# v5: 97 centres the striker on the corrected base lane (ICF: lane
# centreline 208.85 px from the surface centre; 306 - 208.85 = 97.15).
const BASELINE_HALF_LEN := 194.0
const FRICTION := 420.0 # px/s^2 linear decel (powdered board: low friction)
const REST_COIN := 0.92
const REST_WALL := 0.85
const MIN_SPEED := 6.0
const MAX_SPEED := 1500.0 # at Force 100; scaled by striker Force stat
const FIXED_DT := 1.0 / 120.0

static func pocket_centers() -> Array:
	var o := SURFACE_HALF - 24.0
	return [
		BOARD_CENTER + Vector2(-o, -o),
		BOARD_CENTER + Vector2(o, -o),
		BOARD_CENTER + Vector2(-o, o),
		BOARD_CENTER + Vector2(o, o),
	]

static func baseline_y(player: int) -> float:
	# player 0 = bottom (white/breaker side), player 1 = top.
	if player == 0:
		return BOARD_CENTER.y + SURFACE_HALF - BASELINE_OFFSET
	return BOARD_CENTER.y - SURFACE_HALF + BASELINE_OFFSET

## Striker start position for any seat (v6 doubles): 0 bottom, 1 top,
## 2 left, 3 right — each on their own baseline, centred.
static func baseline_pos(seat: int) -> Vector2:
	match int(seat) % 4:
		0:
			return Vector2(BOARD_CENTER.x, BOARD_CENTER.y + SURFACE_HALF - BASELINE_OFFSET)
		1:
			return Vector2(BOARD_CENTER.x, BOARD_CENTER.y - SURFACE_HALF + BASELINE_OFFSET)
		2:
			return Vector2(BOARD_CENTER.x - SURFACE_HALF + BASELINE_OFFSET, BOARD_CENTER.y)
		_:
			return Vector2(BOARD_CENTER.x + SURFACE_HALF - BASELINE_OFFSET, BOARD_CENTER.y)

## Axis the striker slides along on this seat's baseline: "x" for the
## bottom/top seats, "y" for the left/right seats.
static func baseline_axis(seat: int) -> String:
	return "y" if int(seat) % 4 >= 2 else "x"

## Unit vector pointing INTO the board from this seat (aim must have a
## positive dot with it — you shoot toward the board, never away).
static func aim_into_board(seat: int) -> Vector2:
	match int(seat) % 4:
		0:
			return Vector2(0, -1)
		1:
			return Vector2(0, 1)
		2:
			return Vector2(1, 0)
		_:
			return Vector2(-1, 0)

static func make_piece(kind: String, pos: Vector2) -> Dictionary:
	var r := COIN_R
	var mass := 1.0
	if kind == "striker":
		r = STRIKER_R
		mass = 1.5
	return {"kind": kind, "pos": pos, "vel": Vector2.ZERO, "active": true, "r": r, "mass": mass}

## Standard ICF setup (design doc 1.3): queen centre, alternating rings,
## whites forming a "Y" toward the breaker (bottom).
static func setup_pieces() -> Array:
	var pieces: Array = []
	pieces.append(make_piece("queen", BOARD_CENTER))
	# Inner ring: 6 coins, radius = one coin diameter + 1px.
	var inner_angles := [90.0, 30.0, 150.0, 210.0, 270.0, 330.0]
	var inner_colors := ["white", "black", "white", "black", "white", "black"]
	for i in range(6):
		var a := deg_to_rad(inner_angles[i])
		pieces.append(make_piece(inner_colors[i], BOARD_CENTER + Vector2(cos(a), sin(a)) * (COIN_R * 2.0 + 1.0)))
	# Outer ring: 12 coins at radius 54, alternating.
	for i in range(12):
		var a := deg_to_rad(float(i * 30))
		var color := "white" if i % 2 == 1 else "black"
		pieces.append(make_piece(color, BOARD_CENTER + Vector2(cos(a), sin(a)) * (COIN_R * 4.0 + 2.0)))
	# Striker starts on the bottom baseline, centred.
	pieces.append(make_piece("striker", Vector2(BOARD_CENTER.x, baseline_y(0))))
	return pieces

static func _pocket_hit(pos: Vector2) -> int:
	var centers := pocket_centers()
	for i in range(centers.size()):
		if pos.distance_to(centers[i]) <= POCKET_CAPTURE:
			return i
	return -1

## One fixed physics step. Returns array of pocketed piece dicts this step.
static func step(pieces: Array, dt: float) -> Array:
	var pocketed: Array = []
	var left := BOARD_CENTER.x - SURFACE_HALF
	var right := BOARD_CENTER.x + SURFACE_HALF
	var top := BOARD_CENTER.y - SURFACE_HALF
	var bottom := BOARD_CENTER.y + SURFACE_HALF
	# Integrate + friction + pockets + walls.
	for p in pieces:
		if not p["active"]:
			continue
		var vel: Vector2 = p["vel"]
		if vel.length() < 0.001:
			continue
		p["pos"] = p["pos"] + vel * dt
		var speed := vel.length()
		var ns := maxf(0.0, speed - FRICTION * dt)
		if ns < MIN_SPEED:
			p["vel"] = Vector2.ZERO
		else:
			p["vel"] = vel.normalized() * ns
		# Pocket capture first (pockets are holes in the corners — no bounce).
		if _pocket_hit(p["pos"]) >= 0:
			p["active"] = false
			p["vel"] = Vector2.ZERO
			pocketed.append(p)
			continue
		# Walls.
		var pos: Vector2 = p["pos"]
		var r: float = p["r"]
		var v: Vector2 = p["vel"]
		if pos.x - r < left:
			pos.x = left + r
			v.x = -v.x * REST_WALL
		elif pos.x + r > right:
			pos.x = right - r
			v.x = -v.x * REST_WALL
		if pos.y - r < top:
			pos.y = top + r
			v.y = -v.y * REST_WALL
		elif pos.y + r > bottom:
			pos.y = bottom - r
			v.y = -v.y * REST_WALL
		p["pos"] = pos
		p["vel"] = v
	# Coin-coin collisions (impulse + positional correction).
	for i in range(pieces.size()):
		var a: Dictionary = pieces[i]
		if not a["active"]:
			continue
		for j in range(i + 1, pieces.size()):
			var b: Dictionary = pieces[j]
			if not b["active"]:
				continue
			var delta: Vector2 = b["pos"] - a["pos"]
			var dist := delta.length()
			var min_dist: float = a["r"] + b["r"]
			if dist >= min_dist or dist < 0.001:
				continue
			var n := delta / dist
			var overlap := min_dist - dist
			var total_mass: float = a["mass"] + b["mass"]
			a["pos"] = a["pos"] - n * overlap * (b["mass"] / total_mass)
			b["pos"] = b["pos"] + n * overlap * (a["mass"] / total_mass)
			var rel: Vector2 = b["vel"] - a["vel"]
			var vn := rel.dot(n)
			if vn < 0.0:
				var ma: float = a["mass"]
				var mb: float = b["mass"]
				var impulse := -(1.0 + REST_COIN) * vn / (1.0 / ma + 1.0 / mb)
				a["vel"] = a["vel"] - n * (impulse / ma)
				b["vel"] = b["vel"] + n * (impulse / mb)
	return pocketed

static func all_stopped(pieces: Array) -> bool:
	for p in pieces:
		if p["active"] and (p["vel"] as Vector2).length() > 0.01:
			return false
	return true

## Simulate a shot to rest. Returns {"pocketed": [kinds], "striker_pocketed": bool}.
## Used by tests (and AI evaluation). Max 8 simulated seconds.
static func simulate(pieces: Array, max_seconds: float = 8.0) -> Dictionary:
	var pocketed_kinds: Array = []
	var striker_pocketed := false
	var steps := int(max_seconds / FIXED_DT)
	for i in range(steps):
		var hit := step(pieces, FIXED_DT)
		for p in hit:
			if p["kind"] == "striker":
				striker_pocketed = true
			else:
				pocketed_kinds.append(p["kind"])
		if all_stopped(pieces):
			break
	return {"pocketed": pocketed_kinds, "striker_pocketed": striker_pocketed}

## Ray vs circle: returns distance t along ray or -1. Used by the aim guide
## and the AI to test whether a path is clear.
static func ray_circle(origin: Vector2, dir: Vector2, centre: Vector2, radius: float) -> float:
	var oc := centre - origin
	var t := oc.dot(dir)
	if t < 0.0:
		return -1.0
	var d2 := oc.length_squared() - t * t
	var r2 := radius * radius
	if d2 > r2:
		return -1.0
	return t - sqrt(r2 - d2)

## Is the segment from->to clear of all pieces (except `ignore`)?
static func path_clear(pieces: Array, from: Vector2, to: Vector2, ignore: Dictionary = {}) -> bool:
	var dir := to - from
	var length := dir.length()
	if length < 1.0:
		return true
	dir = dir / length
	for p in pieces:
		if not p["active"] or p == ignore:
			continue
		var t := ray_circle(from, dir, p["pos"], p["r"] + COIN_R + 1.0)
		if t >= 0.0 and t < length:
			return false
	return true
