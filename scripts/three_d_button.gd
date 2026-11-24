class_name ThreeDButton
extends Button

## Chunky 3D button — Nana's LingoLand recipe rebuilt in Godot (v11).
##
## The web recipe (theme.css, shared by Nana 2026-11-23 — see
## docs/verification.md v10 for the full Godot translation):
##   (1) two-tone diagonal gradient, bright top-left -> dark bottom-right
##   (2) a solid darker "lip" under the button, 5-7 px tall
##   (3) a soft blurred drop shadow below the lip
##   (4) a white highlight along the top inside edge + a diagonal white sheen
##   (5) big rounded corners (22-26 px; pills fully round)
##   (6) on press, the button sinks 4-5 px and the lip shrinks to 1-2 px
##       in ~0.08 s. Font Baloo 2 Bold, white labels with a real font
##       outline (gold buttons keep dark text: white on bright gold
##       reads badly).
##
## v11 rebuild (P1-1 + P1-2, 2026-11-24): the v10 face was a hand-built
## 8x8-quad mesh with 6-segment corner arcs — on a ~1000 px tile each
## quad was ~125 px wide, so the face showed diagonal facets and the
## 2 px outline followed the same coarse arcs (torn/wavy edges on the
## player's phone). The label was drawn THREE times (shadow + label +
## label again 1 px over "for a bolder look"), which read as doubled
## letters, in Godot's default font (no display font was bundled).
## The face is now built from native pieces instead:
##   * shadow layers + lip + border are StyleBoxFlat, drawn with
##     draw_style_box() — native GPU-rounded corners, no faceting;
##   * the gradient face is a GradientTexture2D (diagonal fill, exactly
##     the old (fx+fy)/2 gradient) sampled through a 32-segment
##     rounded-rect polygon via draw_polygon() UVs — sub-pixel arcs,
##     GPU-smooth gradient, no mesh at all;
##   * the label is drawn ONCE in bundled Baloo 2 Bold
##     (res://art/Baloo2-Bold.ttf, OFL 1.1) with a real outline via
##     draw_string_outline() — no fake-bold double-draw anywhere.
## It IS a Button — `is Button`, `.text`, `.pressed` and `.disabled`
## all work exactly as before, so every test that finds buttons by text
## keeps working. Public API is unchanged: same exported properties,
## same set_colors(), same static helpers (gradient_mesh() and friends
## are kept as pure helpers for the tests, but _draw() no longer uses
## the mesh).

## Bundled display font: Baloo 2 Bold, static wght=700 instance of the
## OFL-1.1 variable font from https://github.com/google/fonts
## (ofl/baloo2/Baloo2[wght].ttf), instantiated with fontTools
## varLib.instancer (wght=700) + name-table Bold fix. art/ is the
## repo's bundled-assets dir (cf. art/bms_splash.png). There is no
## project-wide Theme resource in this codebase (project.godot sets
## no gui/theme; every screen builds its UI in code), so the font is
## applied as a theme override on each button — every UiKit button
## and every direct ThreeDButton.new() gets it in _ready().
const DISPLAY_FONT = preload("res://art/Baloo2-Bold.ttf")

## Corner-arc segments for the face polygon: chord error at r=50 px is
## ~0.004 px, i.e. invisible (v10 used 6 — visibly faceted).
const FACE_ARC_SEG := 32

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

# Native rounded-corner pieces, built once in _ready() and recoloured
# per draw (cheap property sets; no allocation in _draw()).
var _shadow_sb1: StyleBoxFlat
var _shadow_sb2: StyleBoxFlat
var _lip_sb: StyleBoxFlat
var _border_sb: StyleBoxFlat
# Diagonal gradient source for the face. Colours are pushed in only
# when they change (tracked below), so the press animation — which
# redraws every frame for ~0.08 s — costs nothing extra.
var _grad_tex: GradientTexture2D
var _grad_top := Color(-1, -1, -1, -1) # sentinel: "not built yet"
var _grad_bottom := Color(-1, -1, -1, -1)

func _ready() -> void:
	_build_styleboxes()
	# Baloo 2 Bold is this button's font (see DISPLAY_FONT above).
	add_theme_font_override("font", DISPLAY_FONT)
	# The face is drawn in _draw(); the theme must draw nothing.
	var empty := StyleBoxEmpty.new()
	add_theme_stylebox_override("normal", empty)
	add_theme_stylebox_override("hover", empty)
	add_theme_stylebox_override("pressed", empty)
	add_theme_stylebox_override("disabled", empty)
	add_theme_stylebox_override("focus", empty)
	# Native text is invisible — the label is drawn in _draw() (it
	# needs multi-line centring + the press sink + a real outline,
	# which the native single-line label cannot do). The .text
	# property itself stays set, for tests + a11y.
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

func _build_styleboxes() -> void:
	_shadow_sb1 = StyleBoxFlat.new()
	_shadow_sb1.draw_center = true
	_shadow_sb1.set_border_width_all(0)
	_shadow_sb2 = StyleBoxFlat.new()
	_shadow_sb2.draw_center = true
	_shadow_sb2.set_border_width_all(0)
	_lip_sb = StyleBoxFlat.new()
	_lip_sb.draw_center = true
	_lip_sb.set_border_width_all(0)
	# Border only: transparent centre, 2 px white edge, native arcs.
	_border_sb = StyleBoxFlat.new()
	_border_sb.draw_center = false
	_border_sb.bg_color = Color(0, 0, 0, 0)
	_border_sb.border_color = Color(1, 1, 1, 0.30)
	_border_sb.set_border_width_all(2)
	var grad := Gradient.new()
	grad.set_color(0, top_color)
	grad.set_color(1, bottom_color)
	_grad_tex = GradientTexture2D.new()
	_grad_tex.width = 256
	_grad_tex.height = 256
	_grad_tex.fill_from = Vector2(0, 0)
	_grad_tex.fill_to = Vector2(1, 1)
	_grad_tex.gradient = grad
	_grad_top = top_color
	_grad_bottom = bottom_color

func _process(delta: float) -> void:
	if _sink != _sink_target:
		var step := delta / SINK_TIME
		_sink = move_toward(_sink, _sink_target, step)
		queue_redraw()

## Minimum size: the empty styleboxes carry no padding, so the face
## must guarantee BIG buttons itself (clean-UI rule — no tiny buttons).
## Height is the font size x2 + padding; width is the longest label
## line + padding. The layout takes the max of this and any
## custom_minimum_size the caller sets. Measured in Baloo 2 Bold
## (DISPLAY_FONT directly: _ready() may not have run yet when the
## layout first asks, e.g. in the headless tests).
func _get_minimum_size() -> Vector2:
	var fsize := get_theme_font_size("font_size")
	var h := float(fsize) * 2.0 + 24.0
	var w := 0.0
	if text != "":
		var font: Font = DISPLAY_FONT
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
	if _grad_tex != null:
		_push_gradient(top, bottom)
	queue_redraw()

## Push new end colours into the shared gradient texture (no-op
## unless they actually changed).
func _push_gradient(top: Color, bottom: Color) -> void:
	if _grad_tex == null:
		return
	if top.is_equal_approx(_grad_top) and bottom.is_equal_approx(_grad_bottom):
		return
	_grad_tex.gradient.set_color(0, top)
	_grad_tex.gradient.set_color(1, bottom)
	_grad_top = top
	_grad_bottom = bottom

## Radius actually used: pills are fully round, tiles use corner_radius.
func _radius_for(rect_size: Vector2) -> float:
	if pill:
		return rect_size.y * 0.5
	return minf(corner_radius, minf(rect_size.x, rect_size.y) * 0.5)

func _draw() -> void:
	if _shadow_sb1 == null:
		_build_styleboxes()
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
	_push_gradient(top, bottom)
	# (1) soft blurred drop shadow below the lip — two expanding
	# layers, native StyleBoxFlat rounded corners (no faceting).
	_shadow_sb1.bg_color = Color(SHADOW_COLOR, 0.10)
	_shadow_sb1.set_corner_radius_all(int(radius + 3.0))
	_shadow_sb2.bg_color = Color(SHADOW_COLOR, 0.06)
	_shadow_sb2.set_corner_radius_all(int(radius + 6.0))
	draw_style_box(_shadow_sb1, Rect2(rect.position + Vector2(0, 4), rect.size).grow(3.0))
	draw_style_box(_shadow_sb2, Rect2(rect.position + Vector2(0, 8), rect.size).grow(6.0))
	# (2) the solid darker lip — the full face in lip colour; the body
	# covers all but the bottom strip. Native rounded corners.
	_lip_sb.bg_color = lip
	_lip_sb.set_corner_radius_all(int(radius))
	draw_style_box(_lip_sb, rect)
	# (3) the gradient body, sunk by _sink. Its bottom edge sits at
	# size.y - LIP_HEIGHT at rest (6 px of lip showing) and at
	# size.y - LIP_HEIGHT_PRESSED when sunk (2 px showing).
	# The face is the GradientTexture2D sampled through a 32-segment
	# rounded-rect polygon: UV (0,0)->(1,1) over the body rect makes
	# the texture's diagonal fill exactly the old (fx+fy)/2 gradient,
	# GPU-smooth, with sub-pixel corner arcs — no mesh, no facets.
	var sink_px := SINK_PX * _sink
	var body := Rect2(Vector2(0, sink_px), Vector2(rect.size.x, rect.size.y - LIP_HEIGHT))
	var pts := rounded_rect_points(body, radius, FACE_ARC_SEG)
	var uvs := PackedVector2Array()
	uvs.resize(pts.size())
	var white := PackedColorArray()
	white.resize(pts.size())
	for i in range(pts.size()):
		uvs[i] = (pts[i] - body.position) / body.size
		white[i] = Color.WHITE
	draw_polygon(pts, white, uvs, _grad_tex)
	# (4a) white border (2 px, 30% — the tile's white edge), native
	# StyleBoxFlat arcs instead of a coarse polyline.
	_border_sb.set_corner_radius_all(int(radius))
	draw_style_box(_border_sb, body)
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
	# (5) the label, drawn ONCE in Baloo 2 Bold with a real outline
	# (draw_string_outline) — the v10 triple-draw (shadow + label +
	# label again 1 px over "for a bolder look") read as doubled
	# letters on the phone, so it is gone. The outline gives the
	# contrast the old offset shadow was for: dark around light
	# labels, light around dark (gold-button) labels. Multi-line
	# text ("SOLO\nvs AI") is centred as a block, exactly as before.
	if text != "":
		var font: Font = DISPLAY_FONT
		var fsize := get_theme_font_size("font_size")
		var lines := text.split("\n")
		var line_h := font.get_height(fsize)
		var total_h := line_h * lines.size()
		var y := sink_px + (body.size.y - total_h) * 0.5 + font.get_ascent(fsize)
		var outline_px := maxi(2, int(roundf(float(fsize) / 12.0)))
		var outline_col := Color(0, 0, 0, 0.45) if label.get_luminance() > 0.5 else Color(1, 1, 1, 0.35)
		for line in lines:
			var w := font.get_string_size(line, HORIZONTAL_ALIGNMENT_LEFT, -1, fsize).x
			var x := (rect.size.x - w) * 0.5
			var pos := Vector2(x, y)
			draw_string_outline(font, pos, line, HORIZONTAL_ALIGNMENT_LEFT, -1.0, fsize, outline_px, outline_col)
			draw_string(font, pos, line, HORIZONTAL_ALIGNMENT_LEFT, -1.0, fsize, label)
			y += line_h

# ------------------------------------------------------------ pure helpers
# (unit-tested in tests/test_runner.gd — no drawing needed to check them.
# gradient_mesh() is no longer used by _draw() — the face is a textured
# polygon now — but it stays as a tested pure helper.)

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
## LEGACY: _draw() no longer builds the face from this mesh (v11
## textured-polygon face, above) — kept because tests/test_runner.gd
## asserts its geometry, and it is still a correct pure helper.
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
