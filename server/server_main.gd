extends Node

## Server main scene script — the Net autoload does the work; this node
## just keeps the tree alive and logs a heartbeat.

var _ticks := 0

func _ready() -> void:
	print("[Server] BMS Carrom server ready. Matchmaking + relay only.")

func _process(delta: float) -> void:
	_ticks += 1
	if _ticks % 3600 == 0:
		print("[Server] Heartbeat — still listening.")
