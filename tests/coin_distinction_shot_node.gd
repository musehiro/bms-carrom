extends Node2D

## One-off render check (2026-11-27, literal coin colours): the starting
## setup on all six board themes, saved as PNGs for eyeballing.
## Run under Xvfb:
##   xvfb-run -a godot --path . --resolution 720x1280 \
##     res://tests/coin_distinction_shot.tscn -- --shot-out-dir=<dir>
## Not a test — it just captures one frame per theme and quits.
## Kept in tests/ because the repo already carries its shot scenes there.

var _themes := ["classic", "mahogany", "midnight", "emerald", "palace", "signature"]
var _out_dir := "user://"
var _board: BoardView = null

func _ready() -> void:
	for a in OS.get_cmdline_user_args():
		if a.begins_with("--shot-out-dir="):
			_out_dir = a.trim_prefix("--shot-out-dir=")
	_board = BoardView.new()
	_board.pieces = CarromPhysics.setup_pieces()
	_board.draw_backdrop = true
	add_child(_board)
	_run()

func _run() -> void:
	for theme in _themes:
		_board.board_id = String(theme)
		_board.queue_redraw()
		await get_tree().process_frame
		await get_tree().process_frame
		await get_tree().process_frame
		var img := get_viewport().get_texture().get_image()
		var path: String = _out_dir + "/shot-board-" + String(theme) + ".png"
		var err := img.save_png(path)
		print("SHOT_SAVED ", path, " err=", err, " size=", img.get_size())
	get_tree().quit()
