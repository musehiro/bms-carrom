class_name NetClient
extends Node

## Online client for BMS Carrom (design doc 6.2, 6.5).
## Autoload "Net" — the node path (/root/Net) MUST match the server's relay
## node path, because Godot RPCs are addressed by node path. The server
## (server/ project) runs the same path with a server-side script.
##
## Connects to the BMS Carrom relay/matchmaking server (see
## docs/online-server.md) over ENet. The server only matches players and
## relays messages — both clients simulate the same physics from the same
## shot inputs, with a full state snapshot after every shot to resync.
##
## Protocol (JSON strings sent via the _relay RPC):
##   C->S {"type":"queue","name":str,"level":int,"table":int}
##   S->C {"type":"matched","opponent":str,"opp_level":int,"you_break":bool}
##   C->S {"type":"shot","sx":float,"dx":float,"dy":float,"power":float}
##   S->C {"type":"shot", ...same...}            (relayed to the opponent)
##   C->S {"type":"state", ...}                  (snapshot after settling)
##   S->C {"type":"state", ...}                  (relayed)
##   C->S {"type":"forfeit"}  /  S->C {"type":"opponent_left"}
##   S->C {"type":"error","message":str}

signal matched(opponent: Dictionary)
signal shot_received(data: Dictionary)
signal state_received(data: Dictionary)
signal opponent_left
signal queue_failed(message: String)
signal connected_to_server

const DEFAULT_HOST := "127.0.0.1" # localhost for testing; set a real host in Settings
const DEFAULT_PORT := 8910

var _peer: ENetMultiplayerPeer = null
var _connected := false

func is_connected_to_server() -> bool:
	return _connected

func connect_to_server(host: String, port: int) -> void:
	if _peer:
		disconnect_client()
	_peer = ENetMultiplayerPeer.new()
	var err := _peer.create_client(host, port)
	if err != OK:
		queue_failed.emit("Could not start network client (%s)" % error_string(err))
		return
	multiplayer.multiplayer_peer = _peer
	if not multiplayer.connected_to_server.is_connected(_on_connected):
		multiplayer.connected_to_server.connect(_on_connected)
	if not multiplayer.connection_failed.is_connected(_on_connection_failed):
		multiplayer.connection_failed.connect(_on_connection_failed)
	if not multiplayer.server_disconnected.is_connected(_on_server_disconnected):
		multiplayer.server_disconnected.connect(_on_server_disconnected)

func _on_connected() -> void:
	_connected = true
	print("[Net] Connected to server.")
	connected_to_server.emit()

func _on_connection_failed() -> void:
	queue_failed.emit("Could not reach the matchmaking server. Check your connection and the server address in Settings.")

func _on_server_disconnected() -> void:
	_connected = false
	opponent_left.emit()

func queue_up(player_name: String, level: int, table: int) -> void:
	if not _connected:
		queue_failed.emit("Not connected to the server yet.")
		return
	_send({"type": "queue", "name": player_name, "level": level, "table": table})

func send_shot(data: Dictionary) -> void:
	data["type"] = "shot"
	_send(data)

func send_state(data: Dictionary) -> void:
	data["type"] = "state"
	_send(data)

func send_forfeit() -> void:
	_send({"type": "forfeit"})

func _send(data: Dictionary) -> void:
	if _peer == null or _peer.get_connection_status() != ENetMultiplayerPeer.CONNECTION_CONNECTED:
		return
	# Server is peer id 1. The server relays to the opponent by calling
	# _relay on the opponent's /root/Net node.
	rpc_id(1, "_relay", JSON.stringify(data))

@rpc("any_peer", "reliable")
func _relay(payload: String) -> void:
	# Runs on the receiving client when the server relays a message.
	var data: Dictionary = JSON.parse_string(payload)
	if data.is_empty():
		return
	match String(data.get("type", "")):
		"matched":
			matched.emit(data)
		"shot":
			shot_received.emit(data)
		"state":
			state_received.emit(data)
		"opponent_left":
			opponent_left.emit()
		"error":
			queue_failed.emit(String(data.get("message", "Server error")))

func disconnect_client() -> void:
	if _peer:
		_peer.close()
		_peer = null
	multiplayer.multiplayer_peer = null
	_connected = false
