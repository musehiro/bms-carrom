extends Node

## Headless online test client (scene-based so the SceneTree iterates
## normally and the multiplayer peer gets polled).
## Run two of these against a running server:
##   godot --headless --path . res://tests/net_test.tscn -- --name=Alice --level=5 --table=0
##   godot --headless --path . res://tests/net_test.tscn -- --name=Bob --level=6 --table=0
## Both should print MATCHED and exit 0.

var _name := "Test"
var _level := 1
var _table := 0
var _net: NetClient = null
var _wait := 0.0
var _done := false

func _ready() -> void:
	for a in OS.get_cmdline_user_args():
		if a.begins_with("--name="):
			_name = a.trim_prefix("--name=")
		elif a.begins_with("--level="):
			_level = int(a.trim_prefix("--level="))
		elif a.begins_with("--table="):
			_table = int(a.trim_prefix("--table="))
	_net = NetClient.new()
	_net.name = "Net"
	add_child(_net)
	_net.matched.connect(_on_matched)
	_net.queue_failed.connect(_on_failed)
	_net.connected_to_server.connect(_on_connected)
	print("[NetTest %s] connecting to 127.0.0.1:8910…" % _name)
	_net.connect_to_server("127.0.0.1", 8910)

func _on_connected() -> void:
	print("[NetTest %s] connected, queueing (Lv %d, table %d)" % [_name, _level, _table])
	_net.queue_up(_name, _level, _table)

func _on_matched(data: Dictionary) -> void:
	print("[NetTest %s] MATCHED vs %s (Lv %d), you_break=%s" % [_name, data.get("opponent"), int(data.get("opp_level", 0)), str(data.get("you_break"))])
	_net.send_shot({"sx": 360.0, "dx": 0.0, "dy": -1.0, "power": 0.5})
	_done = true
	get_tree().quit(0)

func _on_failed(message: String) -> void:
	print("[NetTest %s] FAILED: %s" % [_name, message])
	_done = true
	get_tree().quit(1)

func _process(delta: float) -> void:
	if _done:
		return
	_wait += delta
	if _wait > 25.0:
		print("[NetTest %s] TIMEOUT waiting for match" % _name)
		_done = true
		get_tree().quit(1)
