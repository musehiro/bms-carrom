class_name Fireworks
extends Control

## Fireworks burst for the win screen (v10): gold, red, teal, white and
## purple particles burst from random points in the top half, fall with
## gravity and fade. Pure drawing — no textures, no audio.
## start_celebration() fires 6 bursts over ~2.4 s, then goes quiet so the
## win screen stays readable. Mouse-transparent, so the win buttons
## underneath keep working.
## Win/lose fix: bursts now mix fireworks dots with flower petals
## (small rotated ellipses, pink/white/yellow) and confetti (small
## rotated rects) — the win celebration reads as flowers + confetti,
## not just sparks. Each particle carries "shape" (dot | petal | rect),
## "rot" and "spin".

const BURST_COUNT := 6
const BURST_GAP := 0.4
const PARTICLES_PER_BURST := 42
const COLORS := [
	Color(1.0, 0.85, 0.30), # gold
	Color(1.0, 0.40, 0.35), # red
	Color(0.20, 0.90, 0.80), # teal
	Color(1.0, 1.0, 1.0), # white
	Color(0.85, 0.55, 1.0), # purple
	Color(1.0, 0.55, 0.75), # flower pink
	Color(1.0, 0.90, 0.40), # flower yellow
]

var _particles: Array = []
var _bursts_left := 0
var _burst_accum := 0.0

func _ready() -> void:
	mouse_filter = Control.MOUSE_FILTER_IGNORE
	set_process(false)

func start_celebration() -> void:
	_bursts_left = BURST_COUNT
	_burst_accum = 0.0
	_spawn_burst()
	set_process(true)

func particle_count() -> int:
	return _particles.size()

func bursts_remaining() -> int:
	return _bursts_left

func _spawn_burst() -> void:
	# Fall back to the 720x1280 layout size when the control has not
	# been laid out yet (headless tests).
	var w := size.x if size.x > 0.0 else 720.0
	var h := size.y if size.y > 0.0 else 1280.0
	var origin := Vector2(randf_range(w * 0.15, w * 0.85), randf_range(h * 0.08, h * 0.45))
	for i in range(PARTICLES_PER_BURST):
		var a := randf() * TAU
		var speed := randf_range(120.0, 420.0)
		# Shape mix: ~45% spark dots, ~30% flower petals, ~25% confetti.
		var roll := randf()
		var shape := "dot"
		if roll >= 0.75:
			shape = "rect"
		elif roll >= 0.45:
			shape = "petal"
		_particles.append({
			"pos": origin, "vel": Vector2(cos(a), sin(a)) * speed,
			"life": randf_range(0.7, 1.3), "max": 1.3,
			"color": COLORS[randi() % COLORS.size()], "size": randf_range(3.0, 6.5),
			"shape": shape, "rot": randf() * TAU, "spin": randf_range(-6.0, 6.0),
		})

func _process(delta: float) -> void:
	if _bursts_left > 0:
		_burst_accum += delta
		if _burst_accum >= BURST_GAP:
			_burst_accum = 0.0
			_bursts_left -= 1
			_spawn_burst()
	var any_alive := false
	for i in range(_particles.size() - 1, -1, -1):
		var p: Dictionary = _particles[i]
		p["life"] = float(p["life"]) - delta
		if float(p["life"]) <= 0.0:
			_particles.remove_at(i)
			continue
		any_alive = true
		p["vel"] = (p["vel"] as Vector2) + Vector2(0, 520.0) * delta
		p["pos"] = (p["pos"] as Vector2) + (p["vel"] as Vector2) * delta
		p["rot"] = float(p.get("rot", 0.0)) + float(p.get("spin", 0.0)) * delta
	if any_alive or _bursts_left > 0:
		queue_redraw()
	else:
		set_process(false)

func _draw() -> void:
	for p in _particles:
		var k := clampf(float(p["life"]) / float(p["max"]), 0.0, 1.0)
		var col := Color(p["color"], k)
		var size := float(p["size"]) * (0.5 + 0.5 * k)
		match String(p.get("shape", "dot")):
			"petal":
				# Flower petal: small rotated ellipse.
				draw_set_transform(p["pos"], float(p.get("rot", 0.0)), Vector2(1.0, 0.55))
				draw_circle(Vector2.ZERO, size, col)
				draw_set_transform(Vector2.ZERO, 0.0, Vector2.ONE)
			"rect":
				# Confetti: small rotated rect.
				draw_set_transform(p["pos"], float(p.get("rot", 0.0)), Vector2.ONE)
				draw_rect(Rect2(-size, -size * 0.6, size * 2.0, size * 1.2), col)
				draw_set_transform(Vector2.ZERO, 0.0, Vector2.ONE)
			_:
				draw_circle(p["pos"], size, col)
