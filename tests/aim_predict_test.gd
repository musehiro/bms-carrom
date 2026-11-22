extends SceneTree

## Aim-prediction test (v4): BoardView.predict_hit — the math behind the
## aim guide's three lines (striker path to impact, struck coin's outgoing
## direction, striker's deflection). Run headless:
##   godot --headless --path . -s tests/aim_predict_test.gd
## Exit 0 = all pass, 1 = any fail. No UI, no autoloads.

var _passed := 0
var _failed := 0
var _failures: Array = []

func _initialize() -> void:
	print("=== BMS Carrom aim-prediction tests ===")
	_test_head_on()
	_test_glancing()
	_test_empty_space()
	_test_wall_first()
	_test_inactive_ignored()
	_test_striker_ignored()
	_test_angle_moves_prediction()
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

func _approx_vec(a: Vector2, b: Vector2, tol: float = 0.05) -> bool:
	return (a - b).length() <= tol

func _test_head_on() -> void:
	# Striker straight below the coin: dead head-on hit.
	var pieces: Array = [CarromPhysics.make_piece("white", Vector2(360, 600))]
	var from := Vector2(360, 900)
	var pred := BoardView.predict_hit(from, Vector2(0, -1), pieces, 900.0)
	_check("head-on: coin hit", pred["hit_coin"] != null)
	_check("head-on: coin dir is straight up", _approx_vec(pred["coin_dir"], Vector2(0, -1)), str(pred["coin_dir"]))
	_check("head-on: striker stops dead (no deflection)", (pred["striker_dir"] as Vector2).length() < 0.05, str(pred["striker_dir"]))
	# Impact point: striker centre stops one coin+striker radius short.
	var hit_pos: Vector2 = pred["hit_pos"]
	_check("head-on: impact point short of coin", hit_pos.y > 600.0 and hit_pos.y < 640.0, str(hit_pos))

func _test_glancing() -> void:
	# Aim at a point 18 px off the coin centre (perpendicular): glancing hit.
	var coin_pos := Vector2(400, 620)
	var from := Vector2(360, 900)
	var to_coin := (coin_pos - from).normalized()
	var perp := Vector2(-to_coin.y, to_coin.x)
	var aim_target := coin_pos + perp * 18.0
	var dir := (aim_target - from).normalized()
	var pieces: Array = [CarromPhysics.make_piece("white", coin_pos)]
	var pred := BoardView.predict_hit(from, dir, pieces, 900.0)
	_check("glancing: coin hit", pred["hit_coin"] != null)
	var coin_dir: Vector2 = pred["coin_dir"]
	var sdir: Vector2 = pred["striker_dir"]
	_check("glancing: coin dir mostly upward", coin_dir.y < -0.5, str(coin_dir))
	_check("glancing: striker deflects (nonzero tangent)", sdir.length() > 0.1, str(sdir))
	_check("glancing: deflection perpendicular to coin dir", absf(coin_dir.dot(sdir.normalized())) < 0.05, str(coin_dir.dot(sdir.normalized())))
	_check("glancing: deflection points away from coin dir", sdir.dot(perp) > 0.0, str(sdir))

func _test_empty_space() -> void:
	# No coins on the ray: plain straight line to the wall.
	var pieces: Array = [CarromPhysics.make_piece("white", Vector2(100, 400))]
	var from := Vector2(360, 900)
	var pred := BoardView.predict_hit(from, Vector2(0, -1), pieces, 900.0)
	_check("empty: no coin hit", pred["hit_coin"] == null)
	_check("empty: no coin dir", (pred["coin_dir"] as Vector2) == Vector2.ZERO)
	_check("empty: no striker deflection", (pred["striker_dir"] as Vector2) == Vector2.ZERO)
	var hit_pos: Vector2 = pred["hit_pos"]
	# Top wall: centre y 590 - half 306 + striker r 17 = 301.
	_check("empty: line ends at top wall", absf(hit_pos.y - 301.0) < 1.0 and absf(hit_pos.x - 360.0) < 1.0, str(hit_pos))

func _test_wall_first() -> void:
	# Diagonal aim, no coins near the ray: wall is the first hit.
	var pieces: Array = [CarromPhysics.make_piece("black", Vector2(600, 300))]
	var from := Vector2(360, 900)
	var pred := BoardView.predict_hit(from, Vector2(-0.6, -0.8).normalized(), pieces, 900.0)
	_check("wall: no coin hit", pred["hit_coin"] == null)
	_check("wall: wall_t positive", float(pred["wall_t"]) > 0.0, str(pred["wall_t"]))

func _test_inactive_ignored() -> void:
	var coin := CarromPhysics.make_piece("white", Vector2(360, 600))
	coin["active"] = false
	var pieces: Array = [coin]
	var pred := BoardView.predict_hit(Vector2(360, 900), Vector2(0, -1), pieces, 900.0)
	_check("inactive coin ignored", pred["hit_coin"] == null)

func _test_striker_ignored() -> void:
	# Another striker sitting on the ray must not count as a hit.
	var pieces: Array = [CarromPhysics.make_piece("striker", Vector2(360, 700))]
	var pred := BoardView.predict_hit(Vector2(360, 900), Vector2(0, -1), pieces, 900.0)
	_check("striker piece ignored", pred["hit_coin"] == null)

func _test_angle_moves_prediction() -> void:
	# Same coin, two slightly different aim angles: the predicted coin
	# direction must move with the angle (proves the live update).
	var coin_pos := Vector2(400, 620)
	var from := Vector2(360, 900)
	var to_coin := (coin_pos - from).normalized()
	var perp := Vector2(-to_coin.y, to_coin.x)
	var pieces: Array = [CarromPhysics.make_piece("white", coin_pos)]
	var dir1 := ((coin_pos + perp * 5.0) - from).normalized()
	var dir2 := ((coin_pos + perp * 20.0) - from).normalized()
	var p1 := BoardView.predict_hit(from, dir1, pieces, 900.0)
	var p2 := BoardView.predict_hit(from, dir2, pieces, 900.0)
	_check("angle: both hit the coin", p1["hit_coin"] != null and p2["hit_coin"] != null)
	var d1: Vector2 = p1["coin_dir"]
	var d2: Vector2 = p2["coin_dir"]
	_check("angle: coin dir moves with aim angle", absf(d1.angle_to(d2)) > 0.02, "angle=%f" % d1.angle_to(d2))
