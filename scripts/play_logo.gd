class_name PlayLogo
extends Control

## "BMS CARROM" crown logo for the Play screen (2026-11-28 restyle).
## Code-drawn to match the reference: the project's own gold crown
## texture (art/icon_crown_gold.png) on top, BMS in gold Baloo, CARROM
## in cream on a code-drawn red ribbon with folded tails, gold laurel
## sprigs flanking BMS. Nothing is copied from the reference image —
## the crown is the repo's bundled asset, the rest is drawn here.
## Fixed height 170 (see _get_minimum_size); width follows the parent.

const DISPLAY_FONT = preload("res://art/Baloo2-Bold.ttf")
const CROWN_TEX = preload("res://art/icon_crown_gold.png")

const GOLD_TEXT := Color(1.0, 0.85, 0.40)
const GOLD_DARK := Color(0.85, 0.60, 0.10)
const CREAM := Color(1.0, 0.96, 0.86)
const RIBBON_TOP := Color(0.85, 0.13, 0.18)
const RIBBON_BOTTOM := Color(0.64, 0.05, 0.12)
const RIBBON_TAIL := Color(0.55, 0.05, 0.09)

var _ribbon_sb: StyleBoxFlat = null
var _ribbon_top_sb: StyleBoxFlat = null

func _init() -> void:
	mouse_filter = Control.MOUSE_FILTER_IGNORE

func _ready() -> void:
	_build_styleboxes()
	resized.connect(queue_redraw)

func _notification(what: int) -> void:
	if what == NOTIFICATION_DRAW and _ribbon_sb == null:
		_build_styleboxes()

func _build_styleboxes() -> void:
	_ribbon_sb = StyleBoxFlat.new()
	_ribbon_sb.draw_center = true
	_ribbon_sb.set_border_width_all(0)
	_ribbon_sb.bg_color = RIBBON_BOTTOM
	_ribbon_sb.set_corner_radius_all(12)
	_ribbon_top_sb = StyleBoxFlat.new()
	_ribbon_top_sb.draw_center = true
	_ribbon_top_sb.set_border_width_all(0)
	_ribbon_top_sb.bg_color = RIBBON_TOP
	_ribbon_top_sb.corner_radius_top_left = 12
	_ribbon_top_sb.corner_radius_top_right = 12
	_ribbon_top_sb.corner_radius_bottom_left = 0
	_ribbon_top_sb.corner_radius_bottom_right = 0

func _get_minimum_size() -> Vector2:
	return Vector2(0, 170)

## One leaf: a pointed oval from `base`, pointing along `angle`
## (radians), `length` long and `width` wide, bulging on both sides.
func _leaf_points(base: Vector2, angle: float, length: float, width: float) -> PackedVector2Array:
	var dir := Vector2(cos(angle), sin(angle))
	var perp := Vector2(-dir.y, dir.x)
	var pts := PackedVector2Array()
	var seg := 6
	for i in range(seg + 1):
		var t := float(i) / float(seg)
		var bulge := sin(PI * t) * width * 0.5
		pts.append(base + dir * (t * length) + perp * bulge)
	for i in range(seg, -1, -1):
		var t := float(i) / float(seg)
		var bulge := sin(PI * t) * width * 0.5
		pts.append(base + dir * (t * length) - perp * bulge)
	return pts

## A 3-leaf laurel sprig fanning up-and-out from `base`.
## `outward` is -1 (left side) or +1 (right side).
func _laurel(base: Vector2, outward: float) -> void:
	var angles := [-0.35, -0.85, -1.35] if outward < 0.0 else [-PI + 0.35, -PI + 0.85, -PI + 1.35]
	var offs := [Vector2(0, 0), Vector2(14 * outward, -8), Vector2(28 * outward, -18)]
	for k in range(3):
		var pts := _leaf_points(base + offs[k], angles[k], 26.0, 11.0)
		draw_colored_polygon(pts, GOLD_TEXT if k != 1 else GOLD_DARK)

func _draw() -> void:
	if _ribbon_sb == null:
		_build_styleboxes()
	var cx := size.x * 0.5
	# Crown (repo's own gold crown texture), centred on top.
	var cw := 108.0
	var ch := cw * 354.0 / 512.0
	draw_texture_rect(CROWN_TEX, Rect2(cx - cw * 0.5, 0.0, cw, ch), false)
	# BMS in gold Baloo with a dark outline.
	var bms_size := 48
	var bms_w := DISPLAY_FONT.get_string_size("BMS", HORIZONTAL_ALIGNMENT_LEFT, -1, bms_size).x
	var bms_y := 118.0
	var bms_x := cx - bms_w * 0.5
	draw_string_outline(DISPLAY_FONT, Vector2(bms_x, bms_y), "BMS", HORIZONTAL_ALIGNMENT_LEFT, -1.0, bms_size, 6, Color(0.23, 0.11, 0.02))
	draw_string(DISPLAY_FONT, Vector2(bms_x, bms_y), "BMS", HORIZONTAL_ALIGNMENT_LEFT, -1.0, bms_size, GOLD_TEXT)
	# Gold laurels flanking BMS.
	_laurel(Vector2(bms_x - 18.0, bms_y - 6.0), -1.0)
	_laurel(Vector2(bms_x + bms_w + 18.0, bms_y - 6.0), 1.0)
	# Ribbon: folded tails first (darker red), then the band.
	var ry0 := 126.0
	var ry1 := 166.0
	var rx0 := cx - 215.0
	var rx1 := cx + 215.0
	draw_colored_polygon(PackedVector2Array([
		Vector2(rx0 + 8, ry0 + 4), Vector2(rx0 - 36, ry0 + 12),
		Vector2(rx0 - 20, ry0 + 20), Vector2(rx0 - 38, ry0 + 30),
		Vector2(rx0 + 8, ry1 - 4)]), RIBBON_TAIL)
	draw_colored_polygon(PackedVector2Array([
		Vector2(rx1 - 8, ry0 + 4), Vector2(rx1 + 36, ry0 + 12),
		Vector2(rx1 + 20, ry0 + 20), Vector2(rx1 + 38, ry0 + 30),
		Vector2(rx1 - 8, ry1 - 4)]), RIBBON_TAIL)
	draw_style_box(_ribbon_sb, Rect2(rx0, ry0, rx1 - rx0, ry1 - ry0))
	draw_style_box(_ribbon_top_sb, Rect2(rx0, ry0, rx1 - rx0, (ry1 - ry0) * 0.55))
	# Gold edge lines top + bottom of the band.
	draw_line(Vector2(rx0 + 12, ry0 + 1.5), Vector2(rx1 - 12, ry0 + 1.5), GOLD_TEXT, 2.0, true)
	draw_line(Vector2(rx0 + 12, ry1 - 1.5), Vector2(rx1 - 12, ry1 - 1.5), GOLD_TEXT, 2.0, true)
	# CARROM in cream on the ribbon.
	var car_size := 38
	var car_w := DISPLAY_FONT.get_string_size("CARROM", HORIZONTAL_ALIGNMENT_LEFT, -1, car_size).x
	var car_x := cx - car_w * 0.5
	var car_y := ry0 + 30.0
	draw_string_outline(DISPLAY_FONT, Vector2(car_x, car_y), "CARROM", HORIZONTAL_ALIGNMENT_LEFT, -1.0, car_size, 5, Color(0.43, 0.04, 0.07))
	draw_string(DISPLAY_FONT, Vector2(car_x, car_y), "CARROM", HORIZONTAL_ALIGNMENT_LEFT, -1.0, car_size, CREAM)
