class_name GoldArrow
extends Control

## Gold divider arrow for the PLAY title row (2026-11-28 restyle):
## a horizontal gold line with a diamond at the outer end and an
## arrowhead at the inner end. `flip` mirrors it (arrowhead on the
## left, for the right-hand side of the title).

const GOLD := Color(1.0, 0.85, 0.40)
const GOLD_DARK := Color(0.83, 0.62, 0.15)

var flip: bool = false:
	set(v):
		flip = v
		queue_redraw()

func _init() -> void:
	mouse_filter = Control.MOUSE_FILTER_IGNORE

func _ready() -> void:
	resized.connect(queue_redraw)

func _get_minimum_size() -> Vector2:
	return Vector2(60, 24)

func _draw() -> void:
	var mid_y := size.y * 0.5
	var w := size.x
	# Direction: arrowhead at the inner end (right when not flipped).
	var dir := -1.0 if flip else 1.0
	var x_head: float = w - 4.0 if not flip else 4.0
	var x_tail: float = 14.0 if not flip else w - 14.0
	# Shaft.
	draw_line(Vector2(x_tail, mid_y), Vector2(x_head - dir * 16.0, mid_y), GOLD, 4.0, true)
	# Arrowhead.
	var tip := Vector2(x_head, mid_y)
	var b1 := Vector2(x_head - dir * 16.0, mid_y - 9.0)
	var b2 := Vector2(x_head - dir * 16.0, mid_y + 9.0)
	draw_colored_polygon(PackedVector2Array([tip, b1, b2]), GOLD)
	# Diamond at the outer end.
	var dc := Vector2(x_tail, mid_y)
	draw_colored_polygon(PackedVector2Array([
		dc + Vector2(0, -7), dc + Vector2(7, 0),
		dc + Vector2(0, 7), dc + Vector2(-7, 0)]), GOLD_DARK)
