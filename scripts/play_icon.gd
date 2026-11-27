class_name PlayIcon
extends Control

## Small code-drawn white icons for the Play screen (2026-11-28 restyle).
## Everything is drawn with canvas primitives in `icon_color` — no image
## assets, no font glyphs (Baloo 2 has no people/globe/wifi glyphs).
## `kind` is one of: robot, people, globe, group, wifi, trophy, star,
## info. The control is square-ish; drawing scales to min(size).
## mouse_filter is IGNORE by default so taps pass to the parent button.

const DISPLAY_FONT = preload("res://art/Baloo2-Bold.ttf")

var kind: String = "people":
	set(v):
		kind = v
		queue_redraw()
var icon_color: Color = Color.WHITE:
	set(v):
		icon_color = v
		queue_redraw()

var _rr_sb: StyleBoxFlat = null

func _init() -> void:
	mouse_filter = Control.MOUSE_FILTER_IGNORE

func _ready() -> void:
	_rr_sb = StyleBoxFlat.new()
	_rr_sb.draw_center = true
	_rr_sb.set_border_width_all(0)
	resized.connect(queue_redraw)

func _notification(what: int) -> void:
	if what == NOTIFICATION_DRAW and _rr_sb == null:
		_rr_sb = StyleBoxFlat.new()
		_rr_sb.draw_center = true
		_rr_sb.set_border_width_all(0)

## Rounded-rect fill via a native StyleBoxFlat (GPU-smooth corners).
func _rr(rect: Rect2, radius: float, col: Color) -> void:
	_rr_sb.bg_color = col
	_rr_sb.set_corner_radius_all(int(radius))
	draw_style_box(_rr_sb, rect)

## One person: head circle + dome shoulders. `c` is the head centre,
## `hr` the head radius, `bw` the body half-width.
func _person(c: Vector2, hr: float, bw: float, col: Color) -> void:
	# Shoulders are a FLAT-TOPPED rounded rect starting at neck level
	# (v2 used a semicircle dome, whose curved top swallowed the head
	# circle — the silhouette read as a tombstone). The flat top + the
	# narrower head circle leave visible neck notches, so it reads as
	# a person even at 52 px.
	var neck_y := c.y + hr * 0.75
	var bot_y := c.y + hr * 3.1
	_rr(Rect2(c.x - bw, neck_y, bw * 2.0, bot_y - neck_y), bw * 0.45, col)
	draw_circle(c, hr, col)

## Ellipse outline as a polyline (no native ellipse arc in _draw).
func _ellipse_outline(c: Vector2, rx: float, ry: float, col: Color, width: float, a0: float = 0.0, a1: float = TAU) -> void:
	var pts := PackedVector2Array()
	var seg := 28
	for i in range(seg + 1):
		var a := a0 + (a1 - a0) * float(i) / float(seg)
		pts.append(c + Vector2(cos(a) * rx, sin(a) * ry))
	draw_polyline(pts, col, width, true)

func _star_points(c: Vector2, r_out: float, r_in: float) -> PackedVector2Array:
	var pts := PackedVector2Array()
	for i in range(10):
		var r := r_out if i % 2 == 0 else r_in
		var a := -PI * 0.5 + PI * float(i) / 5.0
		pts.append(c + Vector2(cos(a), sin(a)) * r)
	return pts

func _draw() -> void:
	var s := minf(size.x, size.y)
	if s < 4.0:
		return
	var col := icon_color
	match kind:
		"people":
			# Back person (smaller, darker) then front person.
			_person(Vector2(size.x * 0.68, size.y * 0.40), s * 0.13, s * 0.17, col.darkened(0.18))
			_person(Vector2(size.x * 0.36, size.y * 0.44), s * 0.16, s * 0.21, col)
		"group":
			_person(Vector2(size.x * 0.20, size.y * 0.44), s * 0.11, s * 0.14, col.darkened(0.18))
			_person(Vector2(size.x * 0.80, size.y * 0.44), s * 0.11, s * 0.14, col.darkened(0.18))
			_person(Vector2(size.x * 0.50, size.y * 0.48), s * 0.15, s * 0.20, col)
		"globe":
			var c := size * 0.5
			var r := s * 0.44
			var w := maxf(2.0, s * 0.055)
			draw_arc(c, r, 0.0, TAU, 40, col, w, true)
			_ellipse_outline(c, r * 0.45, r, col, w)
			_ellipse_outline(c, r, r * 0.38, col, w, PI * 0.15, PI * 0.85)
			_ellipse_outline(c, r, r * 0.38, col, w, PI * 1.15, PI * 1.85)
			draw_line(Vector2(c.x - r, c.y), Vector2(c.x + r, c.y), col, w, true)
		"wifi":
			var c := Vector2(size.x * 0.5, size.y * 0.86)
			var w := maxf(2.5, s * 0.07)
			draw_circle(c, s * 0.07, col)
			for k in range(3):
				var r := s * (0.24 + 0.14 * float(k))
				draw_arc(c, r, PI * 1.22, PI * 1.78, 24, col, w, true)
		"trophy":
			var cx := size.x * 0.5
			# Bowl: wide top, narrow bottom.
			draw_colored_polygon(PackedVector2Array([
				Vector2(cx - s * 0.34, size.y * 0.10),
				Vector2(cx + s * 0.34, size.y * 0.10),
				Vector2(cx + s * 0.22, size.y * 0.46),
				Vector2(cx - s * 0.22, size.y * 0.46)]), col)
			# Handles.
			draw_arc(Vector2(cx - s * 0.34, size.y * 0.26), s * 0.11, PI * 0.5, PI * 1.5, 16, col, maxf(2.5, s * 0.06), true)
			draw_arc(Vector2(cx + s * 0.34, size.y * 0.26), s * 0.11, -PI * 0.5, PI * 0.5, 16, col, maxf(2.5, s * 0.06), true)
			# Stem + base.
			_rr(Rect2(cx - s * 0.05, size.y * 0.46, s * 0.10, size.y * 0.26), 2.0, col)
			_rr(Rect2(cx - s * 0.24, size.y * 0.72, s * 0.48, size.y * 0.14), s * 0.04, col)
		"star":
			draw_colored_polygon(_star_points(size * 0.5, s * 0.46, s * 0.20), col)
		"info":
			var c := size * 0.5
			var r := s * 0.44
			draw_arc(c, r, 0.0, TAU, 40, col, maxf(2.5, s * 0.07), true)
			var fs := int(s * 0.62)
			var tw := DISPLAY_FONT.get_string_size("i", HORIZONTAL_ALIGNMENT_LEFT, -1, fs).x
			var pos := Vector2(c.x - tw * 0.5, c.y + DISPLAY_FONT.get_ascent(fs) * 0.5 - s * 0.02)
			draw_string(DISPLAY_FONT, pos, "i", HORIZONTAL_ALIGNMENT_LEFT, -1.0, fs, col)
		"robot":
			var blue := Color(0.10, 0.32, 0.62)
			var cyan := Color(0.35, 0.85, 1.0)
			# Antenna.
			draw_line(Vector2(size.x * 0.42, size.y * 0.20), Vector2(size.x * 0.42, size.y * 0.08), col, maxf(2.5, s * 0.05), true)
			draw_circle(Vector2(size.x * 0.42, size.y * 0.07), s * 0.045, cyan)
			# Ears.
			draw_circle(Vector2(size.x * 0.10, size.y * 0.42), s * 0.06, blue)
			draw_circle(Vector2(size.x * 0.74, size.y * 0.42), s * 0.06, blue)
			# Head.
			_rr(Rect2(size.x * 0.12, size.y * 0.20, size.x * 0.60, size.y * 0.44), s * 0.12, col)
			# Visor + eyes.
			_rr(Rect2(size.x * 0.19, size.y * 0.30, size.x * 0.46, size.y * 0.24), s * 0.08, blue)
			draw_circle(Vector2(size.x * 0.34, size.y * 0.42), s * 0.055, cyan)
			draw_circle(Vector2(size.x * 0.50, size.y * 0.42), s * 0.055, cyan)
			# Body + chest light.
			_rr(Rect2(size.x * 0.26, size.y * 0.68, size.x * 0.32, size.y * 0.22), s * 0.07, col)
			draw_circle(Vector2(size.x * 0.42, size.y * 0.79), s * 0.045, cyan)
			# Thumbs-up hand, right of the head.
			var hx := size.x * 0.76
			var hy := size.y * 0.60
			_rr(Rect2(hx, hy, s * 0.20, s * 0.30), s * 0.07, col)
			draw_circle(Vector2(hx + s * 0.05, hy - s * 0.02), s * 0.055, col)
			draw_line(Vector2(hx + s * 0.20, hy + s * 0.08), Vector2(hx + s * 0.20, hy + s * 0.22), col.darkened(0.25), maxf(1.5, s * 0.02), true)
