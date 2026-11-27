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
# Optional photo backdrop (match screen only): when set, the wood-table
# photo replaces the procedural gradient + halo behind the board.
var backdrop_texture: Texture2D = null
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

# Graphics-quality tier (Grok plan step 6, adapted to 2D): the extra
# glow/shadow/grain layers below are skipped on low-end GPUs so the
# board stays fast on cheap phones. Detected once, in _ready, from the
# GPU name — an empty name (headless/editor) means full quality.
var quality_low := false
const GRAIN_HIGH := 44
const GRAIN_LOW := 26

func _is_low_end_gpu() -> bool:
	var adapter := RenderingServer.get_video_adapter_name()
	if adapter == "":
		return false
	var low := ["Adreno 5", "Adreno 6", "Mali-G31", "Mali-G52", "Mali-G57", "Mali-T", "PowerVR GE8"]
	for tag in low:
		if tag in adapter:
			return true
	return false

func _ready() -> void:
	_font = ThemeDB.fallback_font
	quality_low = _is_low_end_gpu()
	var rng := RandomNumberGenerator.new()
	rng.seed = 12345
	var grain_count := GRAIN_LOW if quality_low else GRAIN_HIGH
	for i in range(grain_count):
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

	# Full-screen backdrop (v11 lighting: calm warm-neutral ivory ->
	# sand, NOT vivid teal — the wood board is the hero now; the
	# interior stays bright, just without garish competing colour).
	if draw_backdrop:
		var bg_rect := Rect2(Vector2(-200, -200), Vector2(1120, 2100))
		if backdrop_texture != null:
			# Photo backdrop (match screen): the wood table carries the
			# light, so the gradient + halo are skipped entirely.
			draw_texture_rect(backdrop_texture, bg_rect, false)
		else:
			var top_col := Color(0.96, 0.93, 0.88)
			var bot_col := Color(0.83, 0.78, 0.69)
			var strips := 28
			for i in range(strips):
				var t := float(i) / float(strips - 1)
				var strip := Rect2(bg_rect.position + Vector2(0, bg_rect.size.y * float(i) / strips), Vector2(bg_rect.size.x, bg_rect.size.y / strips + 1.0))
				draw_rect(strip, top_col.lerp(bot_col, t))
			# Soft warm halo behind the board (one warm tone only, very
			# faint — replaces the old magenta + blue + gold glow rings).
			for i in range(3):
				draw_circle(c, half + frame + 180.0 - float(i) * 35.0, Color(1.0, 0.88, 0.62, 0.03), true, -1.0, true)
			# Wider, even fainter halo so the board sits in a pool of warm
			# light (skipped on low-end GPUs).
			if not quality_low:
				draw_circle(c, half + frame + 250.0, Color(1.0, 0.88, 0.62, 0.02), true, -1.0, true)
	# Frame (rosewood) with a soft drop shadow under the whole board.
	var frame_rect := Rect2(c - Vector2(half + frame, half + frame), Vector2(2.0 * (half + frame), 2.0 * (half + frame)))
	# Soft drop shadow under the whole board: three layers, farthest
	# faintest, so the edge falls off gently instead of a hard step.
	if not quality_low:
		var shadow_far2 := frame_rect.grow(24.0)
		shadow_far2.position += Vector2(9, 13)
		draw_rect(shadow_far2, Color(0, 0, 0, 0.08))
	var shadow_far := frame_rect.grow(16.0)
	shadow_far.position += Vector2(7, 10)
	draw_rect(shadow_far, Color(0, 0, 0, 0.16))
	var shadow_near := frame_rect.grow(8.0)
	shadow_near.position += Vector2(5, 7)
	draw_rect(shadow_near, Color(0, 0, 0, 0.30))
	draw_rect(frame_rect, frame_c)
	# Polished rosewood: a warm lighter band toward the inner edge, so the
	# frame reads as varnished wood instead of a flat brown border.
	var inner_band := Rect2(frame_rect.position + Vector2(6, 6), frame_rect.size - Vector2(12, 12))
	draw_rect(inner_band, Color(frame_c.r * 1.25, frame_c.g * 1.22, frame_c.b * 1.18, 0.55))
	# Crisp highlight/shadow pair on the frame edge: light catches the top
	# and left, shadow falls on the bottom and right (polished bevel).
	var tl := frame_rect.position
	var tr := frame_rect.position + Vector2(frame_rect.size.x, 0)
	var br := frame_rect.position + frame_rect.size
	var bl := frame_rect.position + Vector2(0, frame_rect.size.y)
	draw_line(tl, tr, Color(1.0, 0.88, 0.62, 0.55), 2.0, true)
	draw_line(tl, bl, Color(1.0, 0.88, 0.62, 0.55), 2.0, true)
	draw_line(tr, br, Color(0, 0, 0, 0.35), 2.0, true)
	draw_line(bl, br, Color(0, 0, 0, 0.35), 2.0, true)
	# Strong gold inner trim: dark gold underlay for a crisp edge, then the
	# bright gold line (4 px, up from 3).
	draw_rect(frame_rect, Color(0.45, 0.28, 0.08, 0.65), false, 5.5)
	draw_rect(frame_rect, Color(0.95, 0.78, 0.32), false, 4.0)
	var surf_rect := Rect2(c - Vector2(half, half), Vector2(2.0 * half, 2.0 * half))
	draw_rect(surf_rect, surf)
	# Richer wood: each plank gets its own tone (deterministic variation).
	var tones := [1.0, 0.90, 1.08, 0.94, 1.06, 0.88]
	for i in range(6):
		var x0 := c.x - half + float(i) * (2.0 * half / 6.0)
		var base_col: Color = surf2 if i % 2 == 0 else surf
		var t: float = tones[i]
		draw_rect(Rect2(x0, c.y - half, 2.0 * half / 6.0, 2.0 * half), Color(base_col.r * t, base_col.g * t, base_col.b * t))
		# Thin separator between planks (v5 polish: reads as real boards).
		if i > 0:
			draw_line(Vector2(x0, c.y - half), Vector2(x0, c.y + half), Color(0, 0, 0, 0.14), 1.5, true)
	# Warm centre glow, kept EVEN: three wide, faint, equal-alpha
	# circles (r300 reaches almost to the board edges) so there is no
	# hot spot in the middle and no dark corners — centre ~0.06
	# combined, mid ~0.04, edge ~0.02, instead of the old 0.10 centre.
	# One wider, fainter circle (r360) on top so the glow reaches the
	# board edges (skipped on low-end GPUs).
	if not quality_low:
		draw_circle(c, 360.0, Color(1.0, 0.88, 0.62, 0.012), true, -1.0, true)
	draw_circle(c, 300.0, Color(1.0, 0.88, 0.62, 0.02), true, -1.0, true)
	draw_circle(c, 210.0, Color(1.0, 0.88, 0.62, 0.02), true, -1.0, true)
	draw_circle(c, 120.0, Color(1.0, 0.88, 0.62, 0.02), true, -1.0, true)
	# Polished sheen: ONE broad, very faint diagonal band only (the old
	# narrow bright band is gone; alpha 0.05/0.035 -> 0.012) so the
	# wood is never washed out.
	var sheen := PackedVector2Array([
		Vector2(c.x - half + 60.0, c.y - half), Vector2(c.x + half, c.y - half),
		Vector2(c.x + half - 60.0, c.y + half), Vector2(c.x - half, c.y + half)])
	draw_colored_polygon(sheen, Color(1, 1, 1, 0.012))
	# Lacquer clearcoat, second band: another broad, even fainter
	# diagonal band, offset from the first, so the varnish reads as
	# depth rather than one flat highlight (skipped on low-end GPUs).
	if not quality_low:
		var sheen2 := PackedVector2Array([
			Vector2(c.x - half + 260.0, c.y - half), Vector2(c.x + half, c.y - half),
			Vector2(c.x + half - 260.0, c.y + half), Vector2(c.x - half, c.y + half)])
		draw_colored_polygon(sheen2, Color(1, 1, 1, 0.008))
	# Directional light pool: a large, very faint warm-white pool
	# centred up-left of the board centre, so the light has a
	# direction (top-left) instead of sitting dead-centre.
	draw_circle(c + Vector2(-90, -110), 340.0, Color(1.0, 0.96, 0.86, 0.02), true, -1.0, true)
	# Wood grain (fine vertical wavy lines, matching the vertical planks):
	# thin dark pore + a faint light ridge beside it, so it reads as wood
	# without muddying the surface.
	for g in _grain:
		var pts := PackedVector2Array()
		for y in range(0, 25):
			var py := c.y - half + float(y) * (2.0 * half / 24.0)
			pts.append(Vector2(g["x"] + sin(float(y) * 0.5 + g["phase"]) * g["amp"], py))
		draw_polyline(pts, Color(0.0, 0.0, 0.0, g["dark"] * 0.7), 1.0, true)
		var pts2 := PackedVector2Array()
		for pt in pts:
			pts2.append(pt + Vector2(2.5, 0))
		draw_polyline(pts2, Color(1.0, 0.9, 0.7, g["dark"] * 0.4), 1.0, true)
	# Surface border shadow + inner gold line. Shadow kept light
	# (alpha 0.25 -> 0.10, width 4.0 -> 3.0) so the board edges no
	# longer go dark; the thin gold inner line is unchanged and crisp.
	draw_rect(surf_rect, Color(0, 0, 0, 0.10), false, 3.0)
	draw_rect(surf_rect.grow(3.0), Color(0.85, 0.68, 0.25, 0.8), false, 1.5)

	# Centre: two concentric circles with the red ring between them (ICF:
	# outer circle 17 cm diameter, centre spot 3.18 cm) + a solid red
	# centre spot where the queen starts.
	draw_arc(c, 70.0, 0, TAU, 64, accent, 3.0, true)
	draw_arc(c, 62.0, 0, TAU, 64, Color(accent, 0.45), 14.0, true)
	draw_arc(c, 54.0, 0, TAU, 64, accent, 3.0, true)
	draw_circle(c, 13.0, accent, true, -1.0, true)
	draw_arc(c, 13.0, 0, TAU, 32, Color(0.95, 0.93, 0.88, 0.9), 2.0, true)
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
		draw_line(c + pdir * 78.0, pp - pdir * 36.0, Color(line_c, 0.8), 2.5, true)

	# Pockets: large, glossy, near-black with a small white highlight at
	# the top and a thin red rim (Carrom Pool look).
	for i in range(pockets.size()):
		var p: Vector2 = pockets[i]
		draw_circle(p, CarromPhysics.POCKET_R + 4.0, Color(0, 0, 0, 0.45), true, -1.0, true)
		draw_circle(p, CarromPhysics.POCKET_R, Color(0.02, 0.02, 0.02), true, -1.0, true)
		draw_circle(p, CarromPhysics.POCKET_R - 6.0, Color(0, 0, 0, 0.65), true, -1.0, true)
		# Crisp dark edge where the pocket meets the wood, then the red rim.
		draw_arc(p, CarromPhysics.POCKET_R + 3.5, 0, TAU, 28, Color(0, 0, 0, 0.5), 1.5, true)
		draw_arc(p, CarromPhysics.POCKET_R + 2.0, 0, TAU, 28, Color(0.85, 0.16, 0.14, 0.95), 2.5, true)
		draw_arc(p, CarromPhysics.POCKET_R - 2.0, 0, TAU, 24, Color(0.5, 0.4, 0.2, 0.6), 2.0, true)
		draw_arc(p, CarromPhysics.POCKET_R - 1.0, PI * 1.2, PI * 1.8, 16, Color(1, 1, 1, 0.8), 3.0, true)
		draw_circle(p + Vector2(-6, -7), 3.5, Color(1, 1, 1, 0.9), true, -1.0, true)
		if pocket_glow == i:
			var t := 0.5 + 0.5 * sin(Time.get_ticks_msec() / 150.0)
			draw_arc(p, CarromPhysics.POCKET_R + 7.0, 0, TAU, 32, Color(1.0, 0.85, 0.3, 0.6 + 0.4 * t), 4.0, true)

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
		draw_circle(puff["pos"], (1.0 - k) * 26.0 + 6.0, Color(puff["color"], k * 0.7), true, -1.0, true)
		draw_circle(puff["pos"], (1.0 - k) * 14.0 + 3.0, Color(1, 1, 1, k * 0.5), true, -1.0, true)
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
	draw_line(p1a, p1b, Color(0.35, 0.18, 0.10, 0.22), 6.0, true)
	draw_line(p1a, p1b, line_c, 3.5, true)
	draw_line(p2a, p2b, Color(0.35, 0.18, 0.10, 0.22), 6.0, true)
	draw_line(p2a, p2b, line_c, 3.5, true)
	# Red base circles: ONE per lane end, centred on the lane centreline
	# (ICF: 3.18 cm diameter) — exactly 2 per corner, 8 total, with a
	# clear gap between the pair at each corner. (v3 drew one at the end
	# of EACH line = 4 per side, so 3 clustered at each corner; v4 moved
	# them to the centreline but kept the wrong line spacing, so the pair
	# still nearly touched; v5 uses the real ICF spacing.)
	for px in [-end_off, end_off]:
		var p: Vector2 = xform * Vector2(px, oc)
		draw_circle(p, BASE_CIRCLE_R, accent, true, -1.0, true)
		draw_arc(p, BASE_CIRCLE_R + 1.0, 0, TAU, 24, Color(0.45, 0.08, 0.08, 0.6), 1.5, true)
		draw_arc(p, BASE_CIRCLE_R, 0, TAU, 24, Color(0.96, 0.94, 0.88, 0.95), 2.5, true)
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
	draw_line(start, end, Color(0.35, 0.18, 0.10, 0.22), 7.0, true)
	draw_line(start, end, accent, 5.0, true)
	draw_line(end, end - dir.rotated(0.5) * 18.0, accent, 5.0, true)
	draw_line(end, end - dir.rotated(-0.5) * 18.0, accent, 5.0, true)

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
		draw_line(rect.get_center(), target, Color(0.83, 0.69, 0.22, 0.9), 2.0, true)
		draw_circle(target, 4.0, Color(0.83, 0.69, 0.22), true, -1.0, true)
		draw_style_box(pill_style, rect)
		draw_string(_font, rect.position + Vector2(12, 22), text, HORIZONTAL_ALIGNMENT_LEFT, -1, 18, Color(0.96, 0.95, 0.92))

## Literal coin colours (2026-11-27): a piece must read as its NAME
## at a glance. White = a white face, black = a black face — only a
## thin accent band and a small centre dot tell them apart; the face
## itself is never blue or gold (the old blue-centre white / gold-ring
## black read as yellow and blue on the board). Queen stays red with
## a gold star. Returns {base, rim, outline, dot}. Pure — the coin
## tests pin these values so the colours can never drift again.
static func piece_palette(kind: String, striker_id: String) -> Dictionary:
	if kind == "white":
		return {"base": Color(0.97, 0.97, 0.95), "rim": Color(0.13, 0.14, 0.19),
			"outline": Color(0.13, 0.14, 0.19), "dot": Color(0.13, 0.14, 0.19)}
	if kind == "black":
		return {"base": Color(0.05, 0.05, 0.06), "rim": Color(0.85, 0.68, 0.25),
			"outline": Color(0.93, 0.91, 0.84), "dot": Color(0.93, 0.91, 0.84)}
	if kind == "queen":
		return {"base": Color(0.78, 0.12, 0.16), "rim": Color(0.5, 0.05, 0.08),
			"outline": Color(0.20, 0.04, 0.06), "dot": Color(1.0, 0.85, 0.25)}
	var s: Dictionary = ShopData.striker_by_id(striker_id)
	var base: Color = s["color"]
	var lum := 0.2126 * base.r + 0.7152 * base.g + 0.0722 * base.b
	return {"base": base, "rim": s["ring"],
		"outline": Color(0.12, 0.12, 0.14) if lum > 0.45 else Color(0.96, 0.93, 0.82),
		"dot": Color(0.9, 0.35, 0.12)}

func _draw_piece(p: Dictionary) -> void:
	var pos: Vector2 = p["pos"]
	var r: float = p["r"]
	# Soft drop shadow, deeper than before but still soft: a faint wide
	# bloom plus a darker core, both offset down-right. A third, widest
	# faintest layer (skipped on low-end GPUs) softens the edge further.
	if not quality_low:
		draw_circle(pos + Vector2(3, 6), r + 5.0, Color(0, 0, 0, 0.08), true, -1.0, true)
	draw_circle(pos + Vector2(2, 4), r + 2.0, Color(0, 0, 0, 0.16), true, -1.0, true)
	draw_circle(pos + Vector2(2, 3), r, Color(0, 0, 0, 0.42), true, -1.0, true)
	var kind: String = p["kind"]
	# Literal coin colours (2026-11-27): a piece must read as its NAME.
	# The previous blue-centre white / gold-ring black read as yellow
	# and blue on the board, so the faces are literal now: white = a
	# white face, black = a black face. Only a THIN accent band (a
	# tenth of the radius) and a SMALL centre dot tell them apart —
	# the face itself is never blue or gold. Queen stays red + gold
	# star; the striker is untouched.
	var pal: Dictionary = piece_palette(kind, striker_id)
	var base: Color = pal["base"]
	var rim: Color = pal["rim"]
	var outline: Color = pal["outline"]
	var dot_col: Color = pal["dot"]
	# Thin accent band for coins (r*0.10 — the old 0.23 band is what
	# made the rim colour dominate the face); queen and striker keep
	# the thicker band, which is part of their look.
	var outline_w: float = r * 0.10 if (kind == "white" or kind == "black") else r * 0.23
	# Glowing orange halo around the striker on your turn.
	if kind == "striker" and your_turn:
		var pulse := 0.55 + 0.35 * sin(Time.get_ticks_msec() / 180.0)
		draw_circle(pos, r + 7.0, Color(1.0, 0.55, 0.15, 0.10 + 0.08 * pulse), true, -1.0, true)
		draw_arc(pos, r + 7.0, 0, TAU, 40, Color(1.0, 0.55, 0.15, 0.5 + 0.3 * pulse), 3.0, true)
		# Second, wider pulsing ring (skipped on low-end GPUs).
		if not quality_low:
			draw_circle(pos, r + 14.0, Color(1.0, 0.55, 0.15, 0.05 + 0.04 * pulse), true, -1.0, true)
	# Steady warm glow ring around the queen so she pops on any board.
	if kind == "queen":
		draw_circle(pos, r + 6.0, Color(1.0, 0.75, 0.25, 0.10), true, -1.0, true)
		draw_arc(pos, r + 6.0, 0, TAU, 40, Color(1.0, 0.75, 0.25, 0.35), 3.0, true)
	# Layered edge: thin outline band, then the coloured rim ring (2 px),
	# then the face. Nothing here changes r or pos (physics is untouched).
	draw_circle(pos, r, outline, true, -1.0, true)
	draw_circle(pos, r - outline_w, rim, true, -1.0, true)
	draw_circle(pos, r - outline_w - 2.0, base, true, -1.0, true)
	# Thin outer ring — dark for the white coin (it vanishes on pale
	# beech without it), gold for the black coin (it vanishes on the
	# dark shop boards without it). Striker: no ring; its sun emblem
	# + halo already mark it.
	if kind == "white":
		draw_arc(pos, r + 2.0, 0, TAU, 32, dot_col, 2.0, true)
	elif kind == "black":
		draw_arc(pos, r + 2.0, 0, TAU, 32, rim, 2.0, true)
	# Centre motif (coins only; the striker gets a sun emblem below).
	# Coins: ONE small dot — dark on white, light on black. No big
	# centre disc any more: the disc is what made the faces read blue
	# and gold. Queen: gold five-point star.
	if kind == "white" or kind == "black":
		draw_circle(pos, r * 0.15, dot_col, true, -1.0, true)
	elif kind == "queen":
		var star := PackedVector2Array()
		for k in range(10):
			var ang := -PI / 2.0 + float(k) * PI / 5.0
			var rad := r * 0.42 if k % 2 == 0 else r * 0.18
			star.append(pos + Vector2(cos(ang), sin(ang)) * rad)
		draw_colored_polygon(star, dot_col)
	# Gloss highlight + bright specular dot (coins look glossy, not flat).
	# Kept inside the face so the white gloss never washes out the edge.
	# On black the gloss is smaller and fainter, so the face stays black.
	var gloss_a := 0.5
	var gloss_r := r * 0.30
	var dot_a := 0.85
	if kind == "black":
		gloss_a = 0.35
		gloss_r = r * 0.22
		dot_a = 0.5
	draw_circle(pos + Vector2(-r * 0.22, -r * 0.25), gloss_r, Color(1, 1, 1, gloss_a), true, -1.0, true)
	draw_circle(pos + Vector2(-r * 0.30, -r * 0.34), r * 0.14, Color(1, 1, 1, dot_a), true, -1.0, true)
	# Bottom inner shadow for depth, hugging the face edge.
	draw_arc(pos, r - outline_w - 3.0, PI * 0.15, PI * 0.85, 16, Color(0, 0, 0, 0.30), 2.0, true)
	if kind == "striker":
		# Sun emblem: red-orange face + rays (Carrom Pool gold striker).
		var sun := Color(0.9, 0.35, 0.12)
		draw_circle(pos, r * 0.3, sun, true, -1.0, true)
		for k in range(8):
			var a := TAU * float(k) / 8.0
			var d := Vector2(cos(a), sin(a))
			draw_line(pos + d * (r * 0.36), pos + d * (r * 0.52), sun, 2.0, true)
		draw_arc(pos, r * 0.62, 0, TAU, 32, rim, 2.0, true)

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
	# Dotted guide line (Carrom Pool look: dots, not dashes). Each dot
	# gets a dark halo + bright core so it reads on pale beech wood
	# AND on dark boards, over a faint dark underlay line.
	_draw_dotted(from, hit_pos, Color(1, 1, 1, 1.0))
	# Bold orange arrow with a dark edge right at the striker, so it
	# reads on light wood. Shaft length unchanged (44 px).
	var arrow_start := from + dir * (CarromPhysics.STRIKER_R + 4.0)
	var arrow_end := arrow_start + dir * 44.0
	var arrow_dark := Color(0.25, 0.1, 0.0, 0.85)
	var arrow_col := Color(1.0, 0.55, 0.1)
	draw_line(arrow_start, arrow_end, arrow_dark, 11.0, true)
	draw_line(arrow_end, arrow_end - dir.rotated(0.45) * 18.0, arrow_dark, 11.0, true)
	draw_line(arrow_end, arrow_end - dir.rotated(-0.45) * 18.0, arrow_dark, 11.0, true)
	draw_line(arrow_start, arrow_end, arrow_col, 7.0, true)
	draw_line(arrow_end, arrow_end - dir.rotated(0.45) * 18.0, arrow_col, 7.0, true)
	draw_line(arrow_end, arrow_end - dir.rotated(-0.45) * 18.0, arrow_col, 7.0, true)
	# Large faint translucent circle around the striker area.
	draw_circle(from, 64.0, Color(1, 1, 1, 0.07), true, -1.0, true)
	draw_arc(from, 64.0, 0, TAU, 48, Color(1, 1, 1, 0.28), 2.5, true)
	# Aim-assist: one cushion bounce.
	if aim_assist and hit_coin == null and wall_t >= 0.0 and wall_t < max_len:
		var n := _wall_normal(hit_pos)
		var bounce_dir := dir - 2.0 * dir.dot(n) * n
		var bounce_end := hit_pos + bounce_dir * 260.0
		_draw_dashed(hit_pos, bounce_end, Color(1, 0.9, 0.4, 0.7), 4.0)
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
		_draw_dashed(contact, contact + coin_dir * defl_len, Color(1.0, 0.85, 0.3, 0.95), 4.5)
		draw_arc(coin_pos, CarromPhysics.COIN_R + 4.0, 0, TAU, 24, Color(1.0, 0.85, 0.3, 0.95), 3.5, true)
		var sdir: Vector2 = pred["striker_dir"]
		if sdir.length() > 0.05:
			var tlen := 90.0 if not aim_assist else 200.0
			_draw_dashed(hit_pos, hit_pos + sdir.normalized() * tlen, Color(1, 1, 1, 0.8), 4.0)
	# Power hint: striker ring fills with power. Dark underlay arc
	# first so the coloured ring reads on pale wood.
	var power_col := Color(0.3, 0.9, 0.4).lerp(Color(0.95, 0.2, 0.15), aim_power)
	draw_arc(from, CarromPhysics.STRIKER_R + 8.0, 0, TAU, 32, Color(0, 0, 0, 0.35), 8.0, true)
	draw_arc(from, CarromPhysics.STRIKER_R + 8.0, -PI / 2.0, -PI / 2.0 + TAU * aim_power, 32, power_col, 6.0, true)

func _draw_dashed(from: Vector2, to: Vector2, color: Color, width: float) -> void:
	var total := from.distance_to(to)
	var dash := 12.0
	var gap := 8.0
	var dir := (to - from).normalized()
	var d := 0.0
	while d < total:
		var a := from + dir * d
		var b := from + dir * minf(d + dash, total)
		# Dark underlay first so the dash reads on any board colour,
		# then the coloured dash on top.
		draw_line(a, b, Color(0, 0, 0, 0.55), width + 3.0, true)
		draw_line(a, b, color, width, true)
		d += dash + gap

func _draw_dotted(from: Vector2, to: Vector2, color: Color) -> void:
	var total := from.distance_to(to)
	if total <= 0.0:
		return
	var dir := (to - from).normalized()
	# Faint dark underlay line beneath the dots (keeps the dotted
	# Carrom Pool feel while giving the dots something to sit on).
	draw_line(from, to, Color(0, 0, 0, 0.30), 7.0, true)
	var d := 0.0
	while d < total:
		var p := from + dir * d
		# Dark halo ring + bright core: reads on pale wood and dark boards.
		draw_circle(p, 5.5, Color(0, 0, 0, 0.55), true, -1.0, true)
		draw_circle(p, 3.5, color, true, -1.0, true)
		d += 12.0

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
