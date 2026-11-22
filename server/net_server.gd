extends Node

## BMS Carrom server — matchmaking + relay (NOT a physics authority).
## The server matches two players of similar level on the same table, then
## only relays their shot/state messages. Both clients simulate the same
## physics from the same inputs, with a full state snapshot after each shot
## to resync. This keeps the server tiny and cheap to host.
##
## Node path MUST be /root/Net (autoload "Net") — the same as the client's
## autoload — because Godot RPCs are addressed by node path.
##
## Run:  godot --headless --path server -- --port 8910
## (or just: godot --headless --path server)

const DEFAULT_PORT := 8910

var _peer: ENetMultiplayerPeer = null
var _queue: Array = [] # {id, name, level, table, at}
var _matches := {} # peer_id -> partner peer_id
var _names := {} # peer_id -> display name

func _ready() -> void:
	var port := DEFAULT_PORT
	for a in OS.get_cmdline_user_args():
		if a.begins_with("--port="):
			port = int(a.trim_prefix("--port="))
	_peer = ENetMultiplayerPeer.new()
	var err := _peer.create_server(port, 64)
	if err != OK:
		printerr("[Server] Failed to start on port %d: %s" % [port, error_string(err)])
		get_tree().quit(1)
		return
	multiplayer.multiplayer_peer = _peer
	multiplayer.peer_connected.connect(_on_peer_connected)
	multiplayer.peer_disconnected.connect(_on_peer_disconnected)
	print("[Server] BMS Carrom matchmaking server listening on port %d" % port)
	print("[Server] Waiting for players… (Ctrl+C to stop)")

func _process(_delta: float) -> void:
	# Widen the level window for players waiting 30+ s (doc 6.5).
	_try_match()

func _on_peer_connected(id: int) -> void:
	print("[Server] Peer connected: %d" % id)

func _on_peer_disconnected(id: int) -> void:
	print("[Server] Peer disconnected: %d" % id)
	_remove_from_queue(id)
	var partner: int = int(_matches.get(id, -1))
	if partner > 0:
		_matches.erase(id)
		_matches.erase(partner)
		_send_to(partner, {"type": "opponent_left"})
	_names.erase(id)

func _remove_from_queue(id: int) -> void:
	for i in range(_queue.size() - 1, -1, -1):
		if int(_queue[i]["id"]) == id:
			_queue.remove_at(i)

@rpc("any_peer", "reliable")
func _relay(payload: String) -> void:
	var sender := multiplayer.get_remote_sender_id()
	var data: Dictionary = JSON.parse_string(payload)
	if data.is_empty():
		return
	match String(data.get("type", "")):
		"queue":
			_names[sender] = String(data.get("name", "Player"))
			_remove_from_queue(sender)
			_queue.append({"id": sender, "name": String(data.get("name", "Player")),
				"level": int(data.get("level", 1)), "table": int(data.get("table", 0)),
				"at": Time.get_unix_time_from_system()})
			print("[Server] %s (Lv %d) queued for table %d" % [data.get("name"), int(data.get("level", 1)), int(data.get("table", 0))])
			_try_match()
		"shot", "state":
			var partner: int = int(_matches.get(sender, -1))
			if partner > 0:
				_send_to(partner, data)
		"forfeit":
			var partner2: int = int(_matches.get(sender, -1))
			if partner2 > 0:
				_send_to(partner2, {"type": "opponent_left"})
				_matches.erase(sender)
				_matches.erase(partner2)

func _try_match() -> void:
	var now := Time.get_unix_time_from_system()
	var i := 0
	while i < _queue.size():
		var a: Dictionary = _queue[i]
		var matched := false
		for j in range(i + 1, _queue.size()):
			var b: Dictionary = _queue[j]
			if int(a["table"]) != int(b["table"]):
				continue
			var wait_a: float = now - float(a["at"])
			var wait_b: float = now - float(b["at"])
			var window := 2
			if wait_a >= 30.0 or wait_b >= 30.0:
				window = 4
			if absf(int(a["level"]) - int(b["level"])) <= window:
				_queue.remove_at(j)
				_queue.remove_at(i)
				_start_match(a, b)
				matched = true
				break
		if not matched:
			i += 1

func _start_match(a: Dictionary, b: Dictionary) -> void:
	var a_breaks := randi() % 2 == 0
	_matches[int(a["id"])] = int(b["id"])
	_matches[int(b["id"])] = int(a["id"])
	_send_to(int(a["id"]), {"type": "matched", "opponent": String(b["name"]),
		"opp_level": int(b["level"]), "you_break": a_breaks})
	_send_to(int(b["id"]), {"type": "matched", "opponent": String(a["name"]),
		"opp_level": int(a["level"]), "you_break": not a_breaks})
	print("[Server] Match: %s (Lv %d) vs %s (Lv %d), table %d — %s breaks" % [
		a["name"], int(a["level"]), b["name"], int(b["level"]), int(a["table"]),
		a["name"] if a_breaks else b["name"]])

func _send_to(peer_id: int, data: Dictionary) -> void:
	rpc_id(peer_id, "_relay", JSON.stringify(data))
