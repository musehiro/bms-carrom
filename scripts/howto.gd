class_name HowToScreen
extends Control

## How to Play: small square window with a red X (like Shadow Assassin).
## P1-3 (2026-11-24): the labelled-board tutorial lives HERE now — the
## home board is the clean hero, and new players learn the parts
## (Pocket, White coin, Black coin, Queen, Centre circle, Diagonal,
## Base line, Striker) from the diagram at the top of this screen,
## drawn by BoardView with show_labels = true on the same sparse
## diagram pieces home used to carry.

signal closed

const RULES_TEXT := """HOW TO PLAY CARROM

SETUP
9 white coins, 9 black coins and the red queen start in the middle. The breaker plays WHITE.

AIM & SHOOT
• Drag the striker sideways along your baseline to slide it.
• Pull back from the striker to aim — the line shows where it will go.
• Pull further for more power. Release to shoot.
• Pocket one of your own coins and you shoot again. Pocket nothing and the turn passes.

THE QUEEN
• Pocket her only AFTER you have pocketed one of your own coins.
• Then cover her: pocket one of your own coins on the same shot or the very next shot, or she goes back to the centre.
• NEVER pocket your last coin while the queen is still on the board — you LOSE the board.

FOULS
• Striker pocketed = lose your turn and one of your pocketed coins comes back.
• Pocketing an opponent's coin is not a foul — it stays pocketed (and helps them!).
• Pocketing your opponent's LAST coin loses you the board.

WINNING
• First to pocket all 9 of your own coins (queen covered first) wins the board.
• You have 20 seconds per shot. Two time-outs in a row online = forfeit.

TIP: Use the aim guide (Full / Basic / Off in Settings). Aim-Assist gives an exact line + pocket glow for an hour — 2,000 coins or 2 short ads."""

static func show_on(parent: Control) -> HowToScreen:
	var h := HowToScreen.new()
	parent.add_child(h)
	return h

func _ready() -> void:
	UiKit.full_rect(self)
	var pop: Dictionary = UiKit.popup_window("HOW TO PLAY", Vector2(620, 780))
	add_child(pop["dim"])
	var box: VBoxContainer = pop["box"]
	var scroll := ScrollContainer.new()
	scroll.custom_minimum_size = Vector2(560, 640)
	scroll.horizontal_scroll_mode = ScrollContainer.SCROLL_MODE_DISABLED
	box.add_child(scroll)
	# The scroll body holds the labelled-board diagram first, then the
	# rules — the popup itself is fixed-size, so the diagram scrolls
	# with the text instead of pushing the window taller.
	var scroll_body := VBoxContainer.new()
	scroll_body.add_theme_constant_override("separation", 8)
	scroll_body.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	scroll.add_child(scroll_body)
	# ---- Labelled board diagram (P1-3, moved from home) ----
	# Same board, same label positions as the old home diagram
	# (BoardView._draw_labels): the labels sit on the empty board
	# areas and never cover a labelled piece. Board-local coords are
	# 680 wide (board spans x 20..700, y 250..930), so the mini is
	# offset (-20, -250) and scaled, exactly as home did it.
	var board_px := 520.0
	var board_center := CenterContainer.new()
	board_center.mouse_filter = Control.MOUSE_FILTER_IGNORE
	scroll_body.add_child(board_center)
	var holder := Control.new()
	holder.custom_minimum_size = Vector2(board_px, board_px)
	holder.mouse_filter = Control.MOUSE_FILTER_IGNORE
	board_center.add_child(holder)
	var s := board_px / 680.0
	var mini := BoardView.new()
	mini.board_id = Save.equipped_board
	mini.striker_id = Save.equipped_striker
	mini.draw_backdrop = false
	mini.show_labels = true
	mini.pieces = _diagram_pieces()
	mini.position = Vector2(-20, -250) * s
	mini.scale = Vector2(s, s)
	holder.add_child(mini)
	var cap := UiKit.muted_label("The board — every part labelled.", 17)
	scroll_body.add_child(cap)
	var text := UiKit.body_label(RULES_TEXT, 20)
	text.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	scroll_body.add_child(text)
	pop["close"].pressed.connect(func() -> void:
		closed.emit()
		queue_free())

## The diagram pieces (moved from home.gd, P1-3): a sparse set so
## every label points cleanly — queen at the centre, one white coin,
## one black coin, striker on the bottom baseline (NOT the standard
## cluster, which would hide the labels).
func _diagram_pieces() -> Array:
	var pieces: Array = []
	pieces.append(CarromPhysics.make_piece("queen", CarromPhysics.BOARD_CENTER))
	pieces.append(CarromPhysics.make_piece("white", Vector2(240, 450)))
	pieces.append(CarromPhysics.make_piece("black", Vector2(480, 720)))
	pieces.append(CarromPhysics.make_piece("striker", Vector2(CarromPhysics.BOARD_CENTER.x, CarromPhysics.baseline_y(0))))
	return pieces
