class_name HowToScreen
extends Control

## How to Play: small square window with a red X (like Shadow Assassin).

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
	var text := UiKit.body_label(RULES_TEXT, 20)
	text.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	scroll.add_child(text)
	pop["close"].pressed.connect(func() -> void:
		closed.emit()
		queue_free())
