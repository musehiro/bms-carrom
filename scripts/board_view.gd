class_name BoardView
extends Node2D

## Draws the whole carrom board: wood, markings, pockets, coins, striker,
## aim guide and pocketing puffs. All procedural — no image assets.

var pieces: Array = []
var board_id := "classic"
var striker_id := "classic"
# Full-screen warm backdrop + glow behind the board (match only). The home
# mini board must NOT draw it: it is scaled/offset and would paint over the
# title and top bar drawn before it.
var draw_backdrop := true
# Labelled diagram (home only): English part names with leader lines so new
# players learn the board — Striker, White coin, Black coin, Queen, Pocket,
# Base line, Centre circle, Diagonal (Buddhika, 2026-11-22).
var show_labels := false

# Base-lane geometry (ICF Laws, 74 cm board, 612 px = 74 cm -> 8.2703 px/cm):
# outer line 10.15 cm from the frame edge; the two parallel lines 3.18 cm
# apart; base circles 3.18 cm diameter, centred between the lines, closing
# each lane end — exactly 2 per corner, 8 total, with a clear gap between
# the pair at a corner (~1.27 cm between the circles, ICF). v4 drew the
# circles at the line ends (±194 px) with the lines 34 px apart, so the
# pair nearly touched and looked cut in half; v5 uses the real geometry.
const BASE_LANE_OUTER_PX := 84.0 # 10.15 cm from the frame edge
const BASE_LANE_GAP_PX := 26.3 # 3.18 cm between the two parallel lines
const BASE_CIRCLE_R := 13.0 # 3.18 cm diameter -> 13.0 px radius
const BASE_LANE_HALF_LEN := 194.0 # half the 47 cm lane

## ICF base-lane geometry in board-local coords: o1 (outer line offset),
## o2 (inner line offset), oc (lane centreline), end_off (circle centre
## distance from the lane middle along the lane).
static func base_lane_geometry() -> Dictionary:
	var half := CarromPhysics.SURFACE_HALF
	var o1 := half - BASE_LANE_OUTER_PX
	var o2 := o1 - BASE_LANE_GAP_PX
	var oc := (o1 + o2) / 2.0
	var end_off := o2 - BASE_CIRCLE_R
	return {"o1": o1, "o2": o2, "oc": oc, "end_off": end_off}

## The 8 base-circle centres (board-local), 2 per corner — used by the
## geometry test (count + pair gap) and shared with the renderer so the
## test and the drawing can never drift apart.
static func base_circle_centers() -> Array:
	var c := CarromPhysics.BOARD_CENTER
	var g := base_lane_geometry()
	var oc: float = g["oc"]
	var end_off: float = g["end_off"]
	var out: Array = []
	for side in range(4):
		var rot: float = [0.0, PI, PI / 2.0, -PI / 2.0][side]
		var xform := Transform2D(rot, c)
		for px in [-end_off, end_off]:
			out.append(xform * Vector2(px, oc))
	return out

# Aim guide state (set by the match controller each frame while aiming).
var aim_visible := false
var aim_from := Vector2.ZERO
var aim_dir := Vector2.UP
var aim_power := 0.0
var aim_mode := "full" # full | basic | off
var aim_assist := false
var pocket_glow := -1
# True when it is the local player's turn: the striker gets a glowing
# orange halo (Carrom Pool look). Set by the match controller.
var your_turn := false

var _grain: Array = []
var _puffs: Array = []
var _font: Font

func _ready() -> void:
	_font = ThemeDB.fallback_font
	var rng := RandomNumberGenerator.new()
	rng.seed = 12345
	for i in range(26):
		var x := CarromPhysics.BOARD_CENTER.x - CarromPhysics.SURFACE_HALF + rng.randf() * 2.0 * CarromPhysics.SURFACE_HALF
		_grain.append({"x": x, "amp": rng.randf_range(2.0, 7.0), "phase": rng.randf() * TAU, "dark": rng.randf_range(0.03, 0.07)})

func spawn_puff(pos: Vector2, color: Color) -> void:
	_puffs.append({"pos": pos, "life": 0.35, "max": 0.35, "color": color})

func _process(delta: float) -> void:
	for i in range(_puffs.size() - 1, -1, -1):
		_puffs[i]["life"] -= delta
		if _puffs[i]["life"] <= 0.0:
			_puffs.remove_at(i)
	queue_redraw()

func _draw() -> void:
	var board: Dictionary = ShopData.board_by_id(board_id)
	var c := CarromPhysics.BOARD_CENTER
	var half := CarromPhysics.SURFACE_HALF
	var frame := CarromPhysics.FRAME
	var surf: Color = board["surface"]
	var surf2: Color = board["surface2"]
	var frame_c: Color = board["frame"]
	var line_c: Color = board["line"]
	var accent: Color = board["accent"]

	# Full-screen BRIGHT backdrop (v10: vivid teal -> emerald, NOT
	# near-black — the whole game interior is brighter now).
	if draw_backdrop:
		var bg_rect := Rect2(Vector2(-200, -200), Vector2(1120, 2100))
		var top_col := Color(0.02, 0.55, 0.62)
		var bot_col := Color(0.02, 0.62, 0.38)
		var strips := 28
		for i in range(strips):
			var t := float(i) / float(strips - 1)
			var strip := Rect2(bg_rect.position + Vector2(0, bg_rect.size.y * float(i) / strips), Vector2(bg_rect.size.x, bg_rect.size.y / strips + 1.0))
			draw_rect(strip, top_col.lerp(bot_col, t))
		# Coloured glow behind the board: magenta + blue, plus a faint gold.
		for i in range(3):
			draw_circle(c, half + frame + 180.0 - float(i) * 35.0, Color(0.85, 0.25, 0.60, 0.05))
		for i in range(3):
			draw_circle(c, half + frame + 150.0 - float(i) * 35.0, Color(0.30, 0.45, 0.95, 0.045))
		for i in range(2):
			draw_circle(c, half + frame + 110.0 - float(i) * 30.0, Color(0.9, 0.7, 0.3, 0.04))
	# Frame (rosewood) with a soft drop shadow under the whole board.
	var frame_rect := Rect2(c - Vector2(half + frame, half + frame), Vector2(2.0 * (half + frame), 2.0 * (half + frame)))
	var shadow_far := frame_rect.grow(16.0)
	shadow_far.position += Vector2(7, 10)
	draw_rect(shadow_far, Color(0, 0, 0, 0.16))
	var shadow_near := frame_rect.grow(8.0)
	shadow_near.position += Vector2(5, 7)
	draw_rect(shadow_near, Color(0, 0, 0, 0.30))
	draw_rect(frame_rect, frame_c)
	draw_rect(frame_rect, Color(0.85, 0.68, 0.25), false, 3.0)
	var surf_rect := Rect2(c - Vector2(half, half), Vector2(2.0 * half, 2.0 * half))
	draw_rect(surf_rect, surf)
	# Richer wood: each plank gets its own tone (deterministic variation).
	var tones := [1.0, 0.93, 1.06, 0.96, 1.04, 0.94]
	for i in range(6):
		var x0 := c.x - half + float(i) * (2.0 * half / 6.0)
		var base_col: Color = surf2 if i % 2 == 0 else surf
		var t: float = tones[i]
		draw_rect(Rect2(x0, c.y - half, 2.0 * half / 6.0, 2.0 * half), Color(base_col.r * t, base_col.g * t, base_col.b * t))
		# Thin separator between planks (v5 polish: reads as real boards).
		if i > 0:
			draw_line(Vector2(x0, c.y - half), Vector2(x0, c.y + half), Color(0, 0, 0, 0.10), 1.5)
	# Warm centre glow (soft light on the middle of the board).
	draw_circle(c, 210.0, Color(1.0, 0.85, 0.5, 0.05))
	draw_circle(c, 130.0, Color(1.0, 0.9, 0.6, 0.05))
	# Polished sheen: two diagonal light bands across the surface.
	var sheen := PackedVector2Array([
		Vector2(c.x - half + 60.0, c.y - half), Vector2(c.x + half, c.y - half),
		Vector2(c.x + half - 60.0, c.y + half), Vector2(c.x - half, c.y + half)])
	draw_colored_polygon(sheen, Color(1, 1, 1, 0.035))
	var sheen2 := PackedVector2Array([
		Vector2(c.x - half + 210.0, c.y - half), Vector2(c.x - half + 300.0, c.y - half),
		Vector2(c.x - half + 150.0, c.y + half), Vector2(c.x - half + 60.0, c.y + half)])
	draw_colored_polygon(sheen2, Color(1, 1, 1, 0.05))
	# Wood grain (fine vertical wavy lines, matching the vertical planks).
	for g in _grain:
		var pts := PackedVector2Array()
		for y in range(0, 25):
			var py := c.y - half + float(y) * (2.0 * half / 24.0)
			pts.append(Vector2(g["x"] + sin(float(y) * 0.5 + g["phase"]) * g["amp"], py))
		draw_polyline(pts, Color(0.0, 0.0, 0.0, g["dark"]), 1.5)
	# Surface border shadow + inner gold line.
	draw_rect(surf_rect, Color(0, 0, 0, 0.25), false, 4.0)
	draw_rect(surf_rect.grow(3.0), Color(0.85, 0.68, 0.25, 0.8), false, 1.5)

	# Centre: two concentric circles with the red ring between them (ICF:
	# outer circle 17 cm diameter, centre spot 3.18 cm) + a solid red
	# centre spot where the queen starts.
	draw_arc(c, 70.0, 0, TAU, 64, accent, 2.5)
	draw_arc(c, 62.0, 0, TAU, 64, Color(accent, 0.45), 16.0)
	draw_arc(c, 54.0, 0, TAU, 64, accent, 2.5)
	draw_circle(c, 13.0, accent)
	draw_arc(c, 13.0, 0, TAU, 32, Color(0.95, 0.93, 0.88, 0.9), 1.5)
	if board_id == "signature":
		draw_string(_font, c + Vector2(-52, 8), "BMS", HORIZONTAL_ALIGNMENT_LEFT, -1, 34, Color(0.85, 0.68, 0.25, 0.55))
	# Base lines + base circles + diagonal arrows (all four sides).
	_draw_side_markings(c, half, line_c, accent, 0)
	_draw_side_markings(c, half, line_c, accent, 1)
	_draw_side_markings(c, half, line_c, accent, 2)
	_draw_side_markings(c, half, line_c, accent, 3)
	# Thin diagonal lines from the centre toward each pocket (Carrom Pool
	# motif) — muted, never heavy; they stop short of the pocket rim.
	var pockets := CarromPhysics.pocket_centers()
	for pi in range(pockets.size()):
		var pp: Vector2 = pockets[pi]
		var pdir := (pp - c).normalized()
		draw_line(c + pdir * 78.0, pp - pdir * 36.0, Color(line_c, 0.7), 2.0)

	# Pockets: large, glossy, near-black with a small white highlight at
	# the top and a thin red rim (Carrom Pool look).
	for i in range(pockets.size()):
		var p: Vector2 = pockets[i]
		draw_circle(p, CarromPhysics.POCKET_R + 4.0, Color(0, 0, 0, 0.45))
		draw_circle(p, CarromPhysics.POCKET_R, Color(0.02, 0.02, 0.02))
		draw_circle(p, CarromPhysics.POCKET_R - 6.0, Color(0, 0, 0, 0.65))
		draw_arc(p, CarromPhysics.POCKET_R + 2.0, 0, TAU, 28, Color(0.82, 0.18, 0.16, 0.85), 2.0)
		draw_arc(p, CarromPhysics.POCKET_R - 2.0, 0, TAU, 24, Color(0.5, 0.4, 0.2, 0.6), 2.0)
		draw_arc(p, CarromPhysics.POCKET_R - 1.0, PI * 1.2, PI * 1.8, 16, Color(1, 1, 1, 0.7), 2.5)
		draw_circle(p + Vector2(-6, -7), 3.5, Color(1, 1, 1, 0.85))
		if pocket_glow == i:
			var t := 0.5 + 0.5 * sin(Time.get_ticks_msec() / 150.0)
			draw_arc(p, CarromPhysics.POCKET_R + 7.0, 0, TAU, 32, Color(1.0, 0.85, 0.3, 0.6 + 0.4 * t), 4.0)

	# Coins + striker.
	for p in pieces:
		if not p["active"]:
			continue
		_draw_piece(p)
	# Aim guide on top.
	if aim_visible and aim_mode != "off":
		_draw_aim_guide()
	# Puffs.
	for puff in _puffs:
		var k := float(puff["life"]) / float(puff["max"])
		draw_circle(puff["pos"], (1.0 - k) * 26.0 + 6.0, Color(puff["color"], k * 0.7))
		draw_circle(puff["pos"], (1.0 - k) * 14.0 + 3.0, Color(1, 1, 1, k * 0.5))
	# Labelled diagram (home only, drawn last so pills sit on top).
	if show_labels:
		_draw_labels()

func _draw_side_markings(c: Vector2, half: float, line_c: Color, accent: Color, side: int) -> void:
	# side: 0 bottom, 1 top, 2 left, 3 right. ICF geometry from
	# base_lane_geometry(): outer line 10.15 cm from the edge, inner line
	# 3.18 cm above it, circles centred on the lane centreline at each
	# lane end — exactly 2 per corner with a clear gap between the pair.
	var g := base_lane_geometry()
	var len2 := BASE_LANE_HALF_LEN
	var o1: float = g["o1"]
	var o2: float = g["o2"]
	var oc: float = g["oc"]
	var end_off: float = g["end_off"]
	var rot: float = [0.0, PI, PI / 2.0, -PI / 2.0][side]
	var xform := Transform2D(rot, c)
	var p1a: Vector2 = xform * Vector2(-len2, o1)
	var p1b: Vector2 = xform * Vector2(len2, o1)
	var p2a: Vector2 = xform * Vector2(-len2, o2)
	var p2b: Vector2 = xform * Vector2(len2, o2)
	# Base lines: a soft warm underlay then the thin muted line on top —
	# thin, muted dark-red/brown, NEVER heavy black (Carrom Pool look).
	# ICF: 47 cm long, outer line 10.15 cm from the frame, lines 3.18 cm
	# apart — the striker touches both.
	draw_line(p1a, p1b, Color(0.35, 0.18, 0.10, 0.25), 5.0)
	draw_line(p1a, p1b, line_c, 3.0)
	draw_line(p2a, p2b, Color(0.35, 0.18, 0.10, 0.25), 5.0)
	draw_line(p2a, p2b, line_c, 3.0)
	# Red base circles: ONE per lane end, centred on the lane centreline
	# (ICF: 3.18 cm diameter) — exactly 2 per corner, 8 total, with a
	# clear gap between the pair at each corner. (v3 drew one at the end
	# of EACH line = 4 per side, so 3 clustered at each corner; v4 moved
	# them to the centreline but kept the wrong line spacing, so the pair
	# still nearly touched; v5 uses the real ICF spacing.)
	for px in [-end_off, end_off]:
		var p: Vector2 = xform * Vector2(px, oc)
		draw_circle(p, BASE_CIRCLE_R, accent)
		draw_arc(p, BASE_CIRCLE_R, 0, TAU, 24, Color(0.96, 0.94, 0.88, 0.95), 2.0)
	# Diagonal arrow from this side's base circle toward the NEAREST pocket
	# (one per corner, like a real board). v2 pointed sides 1 and 3 at the
	# far pocket; fixed here (side 0 -> BL, 1 -> TR, 2 -> TL, 3 -> BR).
	var pockets := CarromPhysics.pocket_centers()
	var target: Vector2 = pockets[2] if side == 0 else (pockets[1] if side == 1 else (pockets[0] if side == 2 else pockets[3]))
	var base_c: Vector2 = xform * Vector2(-end_off, oc)
	var dir := (target - base_c).normalized()
	var start := base_c + dir * 16.0
	var arrow_len := base_c.distance_to(target) - 40.0
	var end := start + dir * arrow_len
	draw_line(start, end, accent, 4.0)
	draw_line(end, end - dir.rotated(0.5) * 16.0, accent, 4.0)
	draw_line(end, end - dir.rotated(-0.5) * 16.0, accent, 4.0)

## Labelled diagram (home only): dark pill + gold border + white text, with
## a thin gold leader line to the part. Pill positions are board-local and
## tuned for the home diagram pieces (queen centre, one white coin, one
## black coin, striker on the bottom baseline); they are drawn on top of
## the empty board areas so they never cover a labelled piece.
func _draw_labels() -> void:
	if _font == null:
		return
	var pill_style := StyleBoxFlat.new()
	pill_style.bg_color = Color(0.06, 0.07, 0.10, 0.92)
	pill_style.border_color = Color(0.83, 0.69, 0.22)
	pill_style.set_border_width_all(2)
	pill_style.set_corner_radius_all(14)
	pill_style.content_margin_left = 12
	pill_style.content_margin_right = 12
	pill_style.content_margin_top = 5
	pill_style.content_margin_bottom = 5
	# [text, pill top-left, leader target]
	var labels := [
		["Pocket", Vector2(468, 288), Vector2(628, 306)],
		["Base line", Vector2(498, 856), Vector2(556, 800)],
		["Diagonal", Vector2(148, 688), Vector2(205, 742)],
		["Centre circle", Vector2(498, 476), Vector2(428, 560)],
		["Queen", Vector2(148, 554), Vector2(344, 584)],
		["White coin", Vector2(108, 396), Vector2(224, 444)],
		["Black coin", Vector2(556, 738), Vector2(498, 726)],
		["Striker", Vector2(148, 866), Vector2(338, 800)],
	]
	for entry in labels:
		var text: String = entry[0]
		var pill_pos: Vector2 = entry[1]
		var target: Vector2 = entry[2]
		var tw := _font.get_string_size(text, HORIZONTAL_ALIGNMENT_LEFT, -1, 18).x
		var rect := Rect2(pill_pos, Vector2(tw + 24, 30))
		# Leader first (under the pill), then the pill, then the text.
		draw_line(rect.get_center(), target, Color(0.83, 0.69, 0.22, 0.9), 2.0)
		draw_circle(target, 4.0, Color(0.83, 0.69, 0.22))
		draw_style_box(pill_style, rect)
		draw_string(_font, rect.position + Vector2(12, 22), text, HORIZONTAL_ALIGNMENT_LEFT, -1, 18, Color(0.96, 0.95, 0.92))

func _draw_piece(p: Dictionary) -> void:
	var pos: Vector2 = p["pos"]
	var r: float = p["r"]
	# Soft drop shadow.
	draw_circle(pos + Vector2(2, 3), r, Color(0, 0, 0, 0.28))
	var kind: String = p["kind"]
	# Glossy two-tone discs (Carrom Pool look): coloured ring + bright
	# centre, white specular highlight, soft shadow. Light coins keep a
	# pale blue ring, dark coins a deep purple ring, queen red + yellow.
	var base := Color(0.94, 0.92, 0.86)
	var rim := Color(0.62, 0.66, 0.92)
	var center_col := Color(0.95, 0.78, 0.25)
	if kind == "black":
		base = Color(0.13, 0.13, 0.15)
		rim = Color(0.28, 0.24, 0.48)
	elif kind == "queen":
		base = Color(0.78, 0.12, 0.16)
		rim = Color(0.5, 0.05, 0.08)
		center_col = Color(1.0, 0.85, 0.25)
	elif kind == "striker":
		var s: Dictionary = ShopData.striker_by_id(striker_id)
		base = s["color"]
		rim = s["ring"]
	# Glowing orange halo around the striker on your turn.
	if kind == "striker" and your_turn:
		var pulse := 0.55 + 0.35 * sin(Time.get_ticks_msec() / 180.0)
		draw_circle(pos, r + 7.0, Color(1.0, 0.55, 0.15, 0.10 + 0.08 * pulse))
		draw_arc(pos, r + 7.0, 0, TAU, 40, Color(1.0, 0.55, 0.15, 0.5 + 0.3 * pulse), 3.0)
	draw_circle(pos, r, rim)
	draw_circle(pos, r - 2.0, base)
	# Two-tone centre disc (coins only; the striker gets a sun emblem).
	if kind != "striker":
		draw_circle(pos, r * 0.52, center_col)
		draw_arc(pos, r * 0.52, 0, TAU, 24, rim, 1.5)
	# Gloss highlight + bright specular dot (coins look glossy, not flat).
	draw_circle(pos + Vector2(-r * 0.3, -r * 0.35), r * 0.38, Color(1, 1, 1, 0.5))
	draw_circle(pos + Vector2(-r * 0.38, -r * 0.42), r * 0.14, Color(1, 1, 1, 0.85))
	# Bottom inner shadow for depth.
	draw_arc(pos, r - 3.0, PI * 0.15, PI * 0.85, 16, Color(0, 0, 0, 0.28), 2.0)
	if kind == "striker":
		# Sun emblem: red-orange face + rays (Carrom Pool gold striker).
		var sun := Color(0.9, 0.35, 0.12)
		draw_circle(pos, r * 0.3, sun)
		for k in range(8):
			var a := TAU * float(k) / 8.0
			var d := Vector2(cos(a), sin(a))
			draw_line(pos + d * (r * 0.36), pos + d * (r * 0.52), sun, 2.0)
		draw_arc(pos, r - 4.5, 0, TAU, 32, rim, 2.0)

func _draw_aim_guide() -> void:
	var from := aim_from
	var dir := aim_dir
	var max_len := 340.0 * ShopData.aim_length_factor(striker_id)
	if aim_assist:
		max_len = 900.0
	var pred := predict_hit(from, dir, pieces, max_len)
	var hit_pos: Vector2 = pred["hit_pos"]
	var hit_coin = pred["hit_coin"]
	var wall_t: float = pred["wall_t"]
	# Dotted white guide line (Carrom Pool look: small dots, not dashes).
	_draw_dotted(from, hit_pos, Color(1, 1, 1, 0.9))
	# Bold solid orange arrow with arrowhead right at the striker.
	var arrow_start := from + dir * (CarromPhysics.STRIKER_R + 4.0)
	var arrow_end := arrow_start + dir * 44.0
	draw_line(arrow_start, arrow_end, Color(1.0, 0.55, 0.1), 5.0)
	draw_line(arrow_end, arrow_end - dir.rotated(0.45) * 13.0, Color(1.0, 0.55, 0.1), 5.0)
	draw_line(arrow_end, arrow_end - dir.rotated(-0.45) * 13.0, Color(1.0, 0.55, 0.1), 5.0)
	# Large faint translucent circle around the striker area.
	draw_circle(from, 64.0, Color(1, 1, 1, 0.05))
	draw_arc(from, 64.0, 0, TAU, 48, Color(1, 1, 1, 0.14), 1.5)
	# Aim-assist: one cushion bounce.
	if aim_assist and hit_coin == null and wall_t >= 0.0 and wall_t < max_len:
		var n := _wall_normal(hit_pos)
		var bounce_dir := dir - 2.0 * dir.dot(n) * n
		var bounce_end := hit_pos + bounce_dir * 260.0
		_draw_dashed(hit_pos, bounce_end, Color(1, 0.9, 0.4, 0.7), 2.5)
	# Hit prediction (Full mode, or assist): the dotted striker path
	# already ends at the impact point. Two more lines, both live as
	# the aim angle changes:
	# (2) the struck coin's outgoing direction — gold dashed, from the
	# contact point along the line joining the striker centre to the
	# coin centre at impact;
	# (3) the striker's deflection — white dashed, along the tangent
	# (perpendicular to that centre line). Head-on => no deflection:
	# the striker stops dead and the coin takes it all.
	if hit_coin != null and (aim_mode == "full" or aim_assist):
		var coin_pos: Vector2 = hit_coin["pos"]
		var coin_dir: Vector2 = pred["coin_dir"]
		var contact := hit_pos + coin_dir * CarromPhysics.STRIKER_R
		var defl_len := 130.0 if not aim_assist else 300.0
		_draw_dashed(contact, contact + coin_dir * defl_len, Color(1.0, 0.85, 0.3, 0.9), 2.5)
		draw_arc(coin_pos, CarromPhysics.COIN_R + 4.0, 0, TAU, 24, Color(1.0, 0.85, 0.3, 0.9), 2.0)
		var sdir: Vector2 = pred["striker_dir"]
		if sdir.length() > 0.05:
			var tlen := 90.0 if not aim_assist else 200.0
			_draw_dashed(hit_pos, hit_pos + sdir.normalized() * tlen, Color(1, 1, 1, 0.65), 2.5)
	# Power hint: striker ring fills with power.
	var power_col := Color(0.3, 0.9, 0.4).lerp(Color(0.95, 0.2, 0.15), aim_power)
	draw_arc(from, CarromPhysics.STRIKER_R + 8.0, -PI / 2.0, -PI / 2.0 + TAU * aim_power, 32, power_col, 4.0)

func _draw_dashed(from: Vector2, to: Vector2, color: Color, width: float) -> void:
	var total := from.distance_to(to)
	var dash := 12.0
	var gap := 8.0
	var dir := (to - from).normalized()
	var d := 0.0
	while d < total:
		var a := from + dir * d
		var b := from + dir * minf(d + dash, total)
		draw_line(a, b, color, width)
		d += dash + gap

func _draw_dotted(from: Vector2, to: Vector2, color: Color) -> void:
	var total := from.distance_to(to)
	if total <= 0.0:
		return
	var dir := (to - from).normalized()
	var d := 0.0
	while d < total:
		draw_circle(from + dir * d, 3.0, color)
		d += 16.0

## Pure hit prediction for the aim guide (also used by the aim test):
## given the striker centre and aim direction, find the first thing the
## striker would hit (coin or wall) within max_len.
## Returns {hit_pos, hit_coin, wall_t, coin_dir, striker_dir}:
##   hit_pos     — striker centre at first contact (or from + dir*max_len)
##   hit_coin    — the first coin hit, or null (wall / nothing)
##   wall_t      — distance to the wall along dir, or -1
##   coin_dir    — struck coin's outgoing direction: the line joining the
##                 striker centre to the coin centre at impact
##   striker_dir — striker's deflected direction (tangent to that line),
##                 or ZERO when head-on (striker stops dead) / no coin hit.
static func predict_hit(from: Vector2, dir: Vector2, pieces: Array, max_len: float) -> Dictionary:
	dir = dir.normalized()
	var best_t := max_len
	var hit_coin = null
	for p in pieces:
		if not p["active"] or p["kind"] == "striker":
			continue
		var t := CarromPhysics.ray_circle(from, dir, p["pos"], p["r"] + CarromPhysics.STRIKER_R)
		if t >= 0.0 and t < best_t:
			best_t = t
			hit_coin = p
	var wall_t := _ray_wall(from, dir)
	if wall_t >= 0.0 and wall_t < best_t:
		best_t = wall_t
		hit_coin = null
	var hit_pos := from + dir * best_t
	var coin_dir := Vector2.ZERO
	var striker_dir := Vector2.ZERO
	if hit_coin != null:
		var coin_pos: Vector2 = hit_coin["pos"]
		coin_dir = (coin_pos - hit_pos).normalized()
		# Tangent component of the incoming direction.
		striker_dir = dir - coin_dir * dir.dot(coin_dir)
	return {"hit_pos": hit_pos, "hit_coin": hit_coin, "wall_t": wall_t, "coin_dir": coin_dir, "striker_dir": striker_dir}

static func _ray_wall(from: Vector2, dir: Vector2) -> float:
	var c := CarromPhysics.BOARD_CENTER
	var half := CarromPhysics.SURFACE_HALF
	var best := -1.0
	if dir.x > 0.001:
		var t := (c.x + half - CarromPhysics.STRIKER_R - from.x) / dir.x
		if t >= 0.0 and (best < 0.0 or t < best):
			best = t
	elif dir.x < -0.001:
		var t := (c.x - half + CarromPhysics.STRIKER_R - from.x) / dir.x
		if t >= 0.0 and (best < 0.0 or t < best):
			best = t
	if dir.y > 0.001:
		var t := (c.y + half - CarromPhysics.STRIKER_R - from.y) / dir.y
		if t >= 0.0 and (best < 0.0 or t < best):
			best = t
	elif dir.y < -0.001:
		var t := (c.y - half + CarromPhysics.STRIKER_R - from.y) / dir.y
		if t >= 0.0 and (best < 0.0 or t < best):
			best = t
	return best

static func _wall_normal(pos: Vector2) -> Vector2:
	var c := CarromPhysics.BOARD_CENTER
	var half := CarromPhysics.SURFACE_HALF
	var dx := minf(absf(pos.x - (c.x - half)), absf(pos.x - (c.x + half)))
	var dy := minf(absf(pos.y - (c.y - half)), absf(pos.y - (c.y + half)))
	if dx < dy:
		return Vector2(-1, 0) if pos.x < c.x else Vector2(1, 0)
	return Vector2(0, -1) if pos.y < c.y else Vector2(0, 1)
