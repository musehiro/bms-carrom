class_name ThreeDButton
extends Button

## Chunky 3D button — Nana's LingoLand recipe rebuilt in Godot (v10).
##
## The web recipe (theme.css, shared by Nana 2026-11-23 — see
## docs/verification.md v10 for the full Godot translation):
##   (1) two-tone diagonal gradient, bright top-left -> dark bottom-right
##   (2) a solid darker "lip" under the button, 5-7 px tall
##   (3) a soft blurred drop shadow below the lip
##   (4) a white highlight along the top inside edge + a diagonal white sheen
##   (5) big rounded corners (22-26 px; pills fully round)
##   (6) on press, the button sinks 4-5 px and the lip shrinks to 1-2 px
##       in ~0.08 s. Font Baloo 2 Bold (Godot's fallback font is the
##       closest available here — the label is drawn twice, 1 px apart,
##       for a bolder look), white labels with a dark text-shadow
##       (gold buttons keep dark text: white on bright gold reads badly).
##
## Why a custom Button instead of styleboxes: StyleBoxFlat has no
## gradient and StyleBoxTexture has no rounded corners, so the recipe
## cannot be built from theme styleboxes. This subclass draws the whole
## face itself in _draw() (the native text is made transparent and the
## label is drawn here, with its shadow). It IS a Button — `is Button`,
## `.text`, `.pressed` and `.disabled` all work exactly as before, so
## every test that finds buttons by text keeps working.

const LIP_HEIGHT := 6.0 # px, at rest (tile-poster: 7 px; chunky: 6 px)
const LIP_HEIGHT_PRESSED := 2.0 # px, sunk
const SINK_PX := 4.0 # px the face drops on press
const SINK_TIME := 0.08 # seconds, matches the CSS transition
const SHADOW_COLOR := Color(0.145, 0.318, 0.494) # rgba(37,81,126)

var top_color := Color(0.22, 0.71, 1.0)
var bottom_color := Color(0.12, 0.44, 0.85)
var lip_color := Color(0.08, 0.35, 0.67)
var text_color := Color.WHITE
var pill := true # fully round (btn-chunky: radius 9999px); false = tile
var corner_radius := 24.0 # px, tiles only (game-tiles: 22, tile-poster: 26)

var _sink := 0.0 # 0 = up, 1 = sunk
var _sink_target := 0.0
var _hover := false

func _ready() -> void:
	# The face is drawn in _draw(); the theme must draw nothing.
	var empty := StyleBoxEmpty.new()
	add_theme_stylebox_override("normal", empty)
	add_theme_stylebox_override("hover", empty)
	add_theme_stylebox_override("pressed", empty)
	add_theme_stylebox_override("disabled", empty)
	add_theme_stylebox_override("focus", empty)
	# Native text is invisible — the label is drawn in _draw() with its
	# shadow (the .text property itself stays set, for tests + a11y).
	var clear := Color(0, 0, 0, 0)
	add_theme_color_override("font_color", clear)
	add_theme_color_override("font_hover_color", clear)
	add_theme_color_override("font_pressed_color", clear)
	add_theme_color_override("font_disabled_color", clear)
	add_theme_color_override("font_focus_color", clear)
	button_down.connect(func() -> void:
		_sink_target = 1.0
		queue_redraw())
	button_up.connect(func() -> void:
		_sink_target = 0.0
		queue_redraw())
	mouse_entered.connect(func() -> void:
		_hover = true
		queue_redraw())
	mouse_exited.connect(func() -> void:
		_hover = false
		queue_redraw())
	resized.connect(queue_redraw)

func _process(delta: float) -> void:
	if _sink != _sink_target:
		var step := delta / SINK_TIME
		_sink = move_toward(_sink, _sink_target, step)
		queue_redraw()

## Minimum size: the empty styleboxes carry no padding, so the face
## must guarantee BIG buttons itself (clean-UI rule — no tiny buttons).
## Height is the font size x2 + padding; width is the longest label
## line + padding. The layout takes the max of this and any
## custom_minimum_size the caller sets.
func _get_minimum_size() -> Vector2:
	var fsize := get_theme_font_size("font_size")
	var h := float(fsize) * 2.0 + 24.0
	var w := 0.0
	if text != "":
		var font := get_theme_font("font")
		var longest := 0.0
		for line in text.split("\n"):
			longest = maxf(longest, font.get_string_size(line, HORIZONTAL_ALIGNMENT_LEFT, -1, fsize).x)
		w = longest + 32.0
	return Vector2(w, h)

func set_colors(top: Color, bottom: Color, lip: Color, label_color: Color = Color.WHITE) -> void:
	top_color = top
	bottom_color = bottom
	lip_color = lip
	text_color = label_color
	queue_redraw()

## Radius actually used: pills are fully round, tiles use corner_radius.
func _radius_for(rect_size: Vector2) -> float:
	if pill:
		return rect_size.y * 0.5
	return minf(corner_radius, minf(rect_size.x, rect_size.y) * 0.5)

func _draw() -> void:
	var rect := Rect2(Vector2.ZERO, size)
	if rect.size.x < 8.0 or rect.size.y < 8.0:
		return
	var radius := _radius_for(rect.size)
	var top := top_color
	var bottom := bottom_color
	var lip := lip_color
	var label := text_color
	if disabled:
		var grey := Color(0.55, 0.55, 0.55)
		top = top.lerp(grey, 0.55)
		bottom = bottom.lerp(grey, 0.55)
		lip = lip.lerp(grey, 0.55)
		label = label.lerp(grey, 0.5)
	elif _hover:
		top = top.lerp(Color.WHITE, 0.07)
		bottom = bottom.lerp(Color.WHITE, 0.05)
	# (1) soft blurred drop shadow below the lip — two expanding layers.
	var shadow1 := Rect2(rect.position + Vector2(0, 4), rect.size).grow(3.0)
	var shadow2 := Rect2(rect.position + Vector2(0, 8), rect.size).grow(6.0)
	draw_colored_polygon(rounded_rect_points(shadow1, radius + 3.0), Color(SHADOW_COLOR, 0.10))
	draw_colored_polygon(rounded_rect_points(shadow2, radius + 6.0), Color(SHADOW_COLOR, 0.06))
	# (2) the solid darker lip — the full face in lip colour; the body
	# covers all but the bottom strip.
	draw_colored_polygon(rounded_rect_points(rect, radius), lip)
	# (3) the gradient body, sunk by _sink. Its bottom edge sits at
	# size.y - LIP_HEIGHT at rest (6 px of lip showing) and at
	# size.y - LIP_HEIGHT_PRESSED when sunk (2 px showing).
	var sink_px := SINK_PX * _sink
	var body := Rect2(Vector2(0, sink_px), Vector2(rect.size.x, rect.size.y - LIP_HEIGHT))
	var mesh := gradient_mesh(body, radius, top, bottom)
	var tris: PackedVector2Array = mesh["tris"]
	var cols: PackedColorArray = mesh["colors"]
	for t in range(0, tris.size(), 3):
		draw_polygon(PackedVector2Array([tris[t], tris[t + 1], tris[t + 2]]),
			PackedColorArray([cols[t], cols[t + 1], cols[t + 2]]))
	# (4a) white border (2 px, 30% — the tile's white edge).
	var outline := rounded_rect_points(body, radius)
	outline.append(outline[0])
	draw_polyline(outline, Color(1, 1, 1, 0.30), 2.0)
	# (4b) white highlight along the top inside edge.
	var hx0 := radius * 0.8
	var hx1 := rect.size.x - radius * 0.8
	if hx1 > hx0:
		draw_line(Vector2(hx0, sink_px + 3.0), Vector2(hx1, sink_px + 3.0), Color(1, 1, 1, 0.40), 2.0)
	# (4c) diagonal white sheen, fading down-right (the gloss::after).
	var sheen := PackedVector2Array([
		clamp_point_to_rounded_rect(body.position + Vector2(body.size.x * 0.06, body.size.y * 0.04), body, radius),
		clamp_point_to_rounded_rect(body.position + Vector2(body.size.x * 0.58, body.size.y * 0.02), body, radius),
		clamp_point_to_rounded_rect(body.position + Vector2(body.size.x * 0.30, body.size.y * 0.72), body, radius),
		clamp_point_to_rounded_rect(body.position + Vector2(body.size.x * 0.02, body.size.y * 0.55), body, radius),
	])
	draw_polygon(sheen, PackedColorArray([
		Color(1, 1, 1, 0.28), Color(1, 1, 1, 0.28),
		Color(1, 1, 1, 0.0), Color(1, 1, 1, 0.0)]))
	# (5) the label, white (or dark on gold) with a dark text-shadow,
	# drawn twice 1 px apart for a bolder look. Multi-line text
	# ("SOLO\nvs AI") is centred as a block.
	if text != "":
		var font := get_theme_font("font")
		var fsize := get_theme_font_size("font_size")
		var lines := text.split("\n")
		var line_h := font.get_height(fsize)
		var total_h := line_h * lines.size()
		var y := sink_px + (body.size.y - total_h) * 0.5 + font.get_ascent(fsize)
		for line in lines:
			var w := font.get_string_size(line, HORIZONTAL_ALIGNMENT_LEFT, -1, fsize).x
			var x := (rect.size.x - w) * 0.5
			var shadow_col := Color(0, 0, 0, 0.45)
			draw_string(font, Vector2(x + 1.0, y + 3.0), line, HORIZONTAL_ALIGNMENT_LEFT, -1.0, fsize, shadow_col)
			draw_string(font, Vector2(x, y), line, HORIZONTAL_ALIGNMENT_LEFT, -1.0, fsize, label)
			draw_string(font, Vector2(x + 1.0, y), line, HORIZONTAL_ALIGNMENT_LEFT, -1.0, fsize, label)
			y += line_h

# ------------------------------------------------------------ pure helpers
# (unit-tested in tests/test_runner.gd — no drawing needed to check them)

## Diagonal gradient colour: t = 0 is the bright top-left, t = 1 the
## dark bottom-right. t is the average of the x and y fractions.
static func gradient_color_at(t: float, top: Color, bottom: Color) -> Color:
	return top.lerp(bottom, clampf(t, 0.0, 1.0))

## The lip is a darker shade of the tile's dark colour (the CSS mixes
## the lip colour toward deep navy; darkening 45% is the same idea).
static func lip_for(bottom: Color) -> Color:
	return bottom.darkened(0.45)

## Outline points of a rounded rect, clockwise from the top-left arc.
## `seg` points per corner arc.
static func rounded_rect_points(rect: Rect2, radius: float, seg: int = 6) -> PackedVector2Array:
	var r := minf(radius, minf(rect.size.x, rect.size.y) * 0.5)
	var out := PackedVector2Array()
	var centers := [
		rect.position + Vector2(r, r),
		rect.position + Vector2(rect.size.x - r, r),
		rect.position + Vector2(rect.size.x - r, rect.size.y - r),
		rect.position + Vector2(r, rect.size.y - r),
	]
	var starts := [PI, PI * 1.5, 0.0, PI * 0.5]
	for k in range(4):
		for i in range(seg + 1):
			var a: float = starts[k] + (PI * 0.5) * float(i) / float(seg)
			out.append(centers[k] + Vector2(cos(a), sin(a)) * r)
	return out

## Pull a point inside a rounded rect: points in a corner square but
## outside the corner arc are projected onto the arc; everything else
## passes through unchanged.
static func clamp_point_to_rounded_rect(p: Vector2, rect: Rect2, radius: float) -> Vector2:
	var r := minf(radius, minf(rect.size.x, rect.size.y) * 0.5)
	var q := Vector2(clampf(p.x, rect.position.x, rect.end.x), clampf(p.y, rect.position.y, rect.end.y))
	var centre := rect.get_center()
	var corners: Array[Vector2] = [
		rect.position + Vector2(r, r),
		rect.position + Vector2(rect.size.x - r, r),
		rect.position + Vector2(rect.size.x - r, rect.size.y - r),
		rect.position + Vector2(r, rect.size.y - r),
	]
	for c in corners:
		# Only the corner whose quadrant the point sits in can claim
		# it (same side of the centre on both axes). A point in the
		# middle band belongs to no corner and passes through.
		if signf(q.x - centre.x) != signf(c.x - centre.x):
			continue
		if signf(q.y - centre.y) != signf(c.y - centre.y):
			continue
		var d := q - c
		if d.length() > r:
			q = c + d.normalized() * r
	return q

## The diagonal-gradient mesh for a rounded rect: a cols x rows grid of
## quads, each vertex coloured by its diagonal position and clamped to
## the rounded shape. Returns {"tris": PackedVector2Array, "colors":
## PackedColorArray} — two triangles per quad, three vertices each.
static func gradient_mesh(rect: Rect2, radius: float, top: Color, bottom: Color, cols: int = 8, rows: int = 8) -> Dictionary:
	var pts: Array = []
	var cols_arr: Array = []
	for j in range(rows + 1):
		for i in range(cols + 1):
			var fx := float(i) / float(cols)
			var fy := float(j) / float(rows)
			var p := Vector2(rect.position.x + rect.size.x * fx, rect.position.y + rect.size.y * fy)
			pts.append(clamp_point_to_rounded_rect(p, rect, radius))
			cols_arr.append(gradient_color_at((fx + fy) * 0.5, top, bottom))
	var tris := PackedVector2Array()
	var colors := PackedColorArray()
	for j in range(rows):
		for i in range(cols):
			var a: int = j * (cols + 1) + i
			var b: int = a + 1
			var c: int = a + cols + 1
			var d: int = c + 1
			for idx in [a, b, d, a, d, c]:
				tris.append(pts[idx])
				colors.append(cols_arr[idx])
	return {"tris": tris, "colors": colors}
