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
##   C->S {"type":"queue","name":str,"level":int,"table":int,"stake":int}
##   S->C {"type":"matched","opponent":str,"opp_level":int,"you_break":bool,"opp_stake":int}
##   C->S {"type":"shot","sx":float,"dx":float,"dy":float,"power":float}
##   S->C {"type":"shot", ...same...}            (relayed to the opponent)
##   C->S {"type":"state", ...}                  (snapshot after settling)
##   S->C {"type":"state", ...}                  (relayed)
##   C->S {"type":"forfeit"}  /  S->C {"type":"opponent_left"}
##   S->C {"type":"error","message":str}
## "table" is only the matchmaking BAND (from Stakes.band_for_stake) — the
## pot uses each player's own "stake", which the server exchanges in the
## matched message. Missing stake fields default to 0 (friendly match).

signal matched(opponent: Dictionary)
signal shot_received(data: Dictionary)
signal state_received(data: Dictionary)
signal opponent_left
signal queue_failed(message: String)
signal connected_to_server
signal lan_host_found(host: Dictionary) # {name, ip, port}
signal lan_discovery_failed(message: String)

const DEFAULT_HOST := "127.0.0.1" # localhost for testing; set a real host in Settings
const DEFAULT_PORT := 8910
const LAN_BEACON_PORT := 8911 # UDP broadcast port for same-Wi-Fi discovery
const LAN_BEACON_INTERVAL := 1.0 # seconds between host beacons

var _peer: ENetMultiplayerPeer = null
var _connected := false

## Seat of the player who last left a 4p match (-1 = unknown / 2p match).
## MatchScreen reads this on opponent_left to work out which team
## forfeited. Set from the server's opponent_left message (4p rooms
## include the leaver's seat); cleared on every new match.
var last_opponent_left_seat := -1

# --- LAN (same-Wi-Fi) hosting + discovery (v6) -------------------------
# No internet server exists yet (hosting needs an Oracle account + a
# card for verification — see docs/online-server.md), so two phones on
# the same Wi-Fi match directly: one phone HOSTS (runs the matchmaking
# server inside the game), the other JOINS by discovery or by IP.
# Same protocol as the internet server (queue/matched/shot/state/
# forfeit/opponent_left), so MatchScreen needs no changes.
# LAN matches are a direct challenge between two people, not random
# matchmaking — so there is no ±2 level gate and no stake band gate.
var _hosting := false
var _host_entry: Dictionary = {} # {name, level, table, stake}
var _host_partner := -1 # peer id of the joined opponent, -1 = none yet
var _beacon: PacketPeerUDP = null
var _beacon_timer := 0.0
var _discovery: PacketPeerUDP = null
var _discovering := false
var _found_hosts: Dictionary = {} # ip -> {name, ip, port}

func _process(delta: float) -> void:
	if _hosting and _beacon != null:
		_beacon_timer += delta
		if _beacon_timer >= LAN_BEACON_INTERVAL:
			_beacon_timer = 0.0
			_send_beacon()
	if _discovering and _discovery != null:
		_poll_discovery()

func is_hosting() -> bool:
	return _hosting

func is_discovering() -> bool:
	return _discovering

## Start hosting a LAN match: this phone becomes the server (ENet,
## port 8910) and beacons on the Wi-Fi so the other phone can find it.
func start_host(player_name: String, level: int, table: int, stake: int) -> void:
	stop_all_net()
	_peer = ENetMultiplayerPeer.new()
	var err := _peer.create_server(DEFAULT_PORT, 2)
	if err != OK:
		_peer = null
		queue_failed.emit("Could not start Wi-Fi hosting on port %d (%s). Another app may be using it." % [DEFAULT_PORT, error_string(err)])
		return
	multiplayer.multiplayer_peer = _peer
	if not multiplayer.peer_connected.is_connected(_on_host_peer_connected):
		multiplayer.peer_connected.connect(_on_host_peer_connected)
	if not multiplayer.peer_disconnected.is_connected(_on_host_peer_disconnected):
		multiplayer.peer_disconnected.connect(_on_host_peer_disconnected)
	_hosting = true
	_host_partner = -1
	_host_entry = {"name": player_name, "level": level, "table": table, "stake": maxi(0, stake)}
	_beacon = PacketPeerUDP.new()
	_beacon.set_broadcast_enabled(true)
	_beacon.set_dest_address("255.255.255.255", LAN_BEACON_PORT)
	_beacon_timer = 0.0
	print("[Net] Hosting LAN match on port %d as %s (Lv %d, stake %d)" % [DEFAULT_PORT, player_name, level, stake])

func stop_host() -> void:
	if not _hosting:
		return
	_beacon = null
	_hosting = false
	_host_partner = -1
	_host_entry = {}
	if _peer:
		_peer.close()
		_peer = null
	multiplayer.multiplayer_peer = null

## Listen for LAN host beacons on the Wi-Fi. Found hosts arrive via
## lan_host_found (once per host; re-beacons refresh the entry).
func start_discovery() -> void:
	stop_discovery()
	_discovery = PacketPeerUDP.new()
	var err := _discovery.bind(LAN_BEACON_PORT)
	if err != OK:
		_discovery = null
		lan_discovery_failed.emit("Could not listen for nearby players (%s)." % error_string(err))
		return
	_discovering = true
	_found_hosts.clear()
	print("[Net] Listening for LAN hosts on port %d…" % LAN_BEACON_PORT)

func stop_discovery() -> void:
	if _discovery != null:
		_discovery.close()
		_discovery = null
	_discovering = false

func _send_beacon() -> void:
	if _beacon == null:
		return
	# put_packet returns an error code; UDP send can be blocked in
	# sandboxes — the beacon is best-effort, never fatal.
	_beacon.put_packet(lan_beacon_payload(String(_host_entry.get("name", "Player"))).to_utf8_buffer())

func _poll_discovery() -> void:
	while _discovery.get_available_packet_count() > 0:
		var pkt := _discovery.get_packet()
		var ip := _discovery.get_packet_ip()
		var host := lan_parse_beacon(pkt, ip)
		if host.is_empty():
			continue
		if _is_own_ip(ip):
			continue
		var known: Dictionary = _found_hosts.get(ip, {})
		_found_hosts[ip] = host
		if String(known.get("name", "")) != String(host["name"]):
			lan_host_found.emit(host)

func _is_own_ip(ip: String) -> bool:
	return ip in IP.get_local_addresses()

## Private LAN addresses of this device (for the host screen + manual
## IP entry). Loopback and public addresses are never listed.
static func lan_local_ips() -> Array:
	var out: Array = []
	for a in IP.get_local_addresses():
		if a == "127.0.0.1" or "::" in a:
			continue
		var parts := String(a).split(".")
		if parts.size() != 4:
			continue
		var o1 := int(parts[0])
		var o2 := int(parts[1])
		if String(a).begins_with("192.168.") or String(a).begins_with("10."):
			out.append(a)
		elif o1 == 172 and o2 >= 16 and o2 <= 31:
			out.append(a)
	return out

## Beacon payload (pure, unit-tested): the host advertises its name.
static func lan_beacon_payload(host_name: String) -> String:
	return JSON.stringify({"type": "carrom-host", "name": host_name, "port": DEFAULT_PORT})

## Parse one discovery packet. Returns {} for anything that is not a
## well-formed carrom-host beacon (wrong type, bad JSON, no name/ip).
static func lan_parse_beacon(pkt: PackedByteArray, sender_ip: String) -> Dictionary:
	if sender_ip == "":
		return {}
	var data: Dictionary = JSON.parse_string(pkt.get_string_from_utf8())
	if data.is_empty() or String(data.get("type", "")) != "carrom-host":
		return {}
	var host_name := String(data.get("name", "")).strip_edges()
	if host_name == "":
		return {}
	return {"name": host_name, "ip": sender_ip, "port": int(data.get("port", DEFAULT_PORT))}

func _on_host_peer_connected(id: int) -> void:
	print("[Net] LAN peer connected: %d (match starts on their queue message)" % id)

func _on_host_peer_disconnected(id: int) -> void:
	print("[Net] LAN peer disconnected: %d" % id)
	if id == _host_partner:
		_host_partner = -1
		opponent_left.emit()

## Host-side relay: this phone IS the server. Only the matched partner's
## shot/state/forfeit messages reach the local game; a queue message
## from anyone starts a match (LAN is a direct challenge — no level or
## band gate). Split into two pure-ish handlers so tests can drive them
## without real sockets.
func _relay_as_host(data: Dictionary) -> void:
	var sender := multiplayer.get_remote_sender_id()
	var mtype := String(data.get("type", ""))
	if _host_partner > 0:
		if sender == _host_partner:
			_handle_host_message(sender, data)
		return
	if mtype == "queue":
		_handle_host_queue(sender, data)

func _handle_host_queue(sender: int, data: Dictionary) -> void:
	if _host_partner > 0:
		return # already matched — one opponent per host
	var opp := {"name": String(data.get("name", "Player")), "level": int(data.get("level", 1)),
		"stake": maxi(0, int(data.get("stake", 0)))}
	_host_partner = sender
	_beacon = null # stop advertising: this host is busy now
	var you_break := randi() % 2 == 0
	var to_joiner := {"type": "matched", "opponent": String(_host_entry.get("name", "Player")),
		"opp_level": int(_host_entry.get("level", 1)), "you_break": not you_break,
		"opp_stake": int(_host_entry.get("stake", 0))}
	rpc_id(sender, "_relay", JSON.stringify(to_joiner))
	var to_host := {"type": "matched", "opponent": String(opp["name"]),
		"opp_level": int(opp["level"]), "you_break": you_break,
		"opp_stake": int(opp["stake"])}
	matched.emit(to_host)
	print("[Net] LAN match: %s vs %s — %s breaks" % [_host_entry.get("name"), opp["name"],
		_host_entry.get("name") if you_break else opp["name"]])

func _handle_host_message(sender: int, data: Dictionary) -> void:
	if sender != _host_partner:
		return
	match String(data.get("type", "")):
		"shot":
			shot_received.emit(data)
		"state":
			state_received.emit(data)
		"forfeit":
			_host_partner = -1
			opponent_left.emit()

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

func queue_up(player_name: String, level: int, table: int, stake: int = 0, mode: String = "2p") -> void:
	if _hosting:
		return # the host never queues — its entry is set by start_host
	if not _connected:
		queue_failed.emit("Not connected to the server yet.")
		return
	_send({"type": "queue", "name": player_name, "level": level, "table": table, "stake": stake, "mode": mode})

## Join an invite room (v7): after accepting a friend invite (or when
## the group is ready, for the inviter), both sides send this to the
## game server with the same group_id. The server starts the match when
## every expected player has joined. The inviter is seat 0; invitees
## take seats 1.. in join order. Requires a connection to the internet
## game server (not LAN hosting) — invite matches do not run over
## NEARBY; NEARBY is the direct challenge instead.
func join_invite_room(group_id: String, player_name: String, level: int, stake: int = 0, mode: String = "2p", table: int = 0, is_inviter: bool = false) -> void:
	if _hosting:
		queue_failed.emit("Invite matches need the game server — use NEARBY to play together on the same Wi-Fi.")
		return
	if not _connected:
		queue_failed.emit("Not connected to the game server yet — the server is not online. Play NEARBY together for now.")
		return
	_send(invite_join_message(group_id, player_name, level, stake, mode, table, is_inviter))

## The invite_join message (pure, unit-tested).
static func invite_join_message(group_id: String, player_name: String, level: int, stake: int, mode: String, table: int, is_inviter: bool) -> Dictionary:
	return {"type": "invite_join", "group_id": group_id, "name": player_name,
		"level": level, "stake": maxi(0, stake), "mode": mode, "table": table,
		"is_inviter": is_inviter}

func send_shot(data: Dictionary) -> void:
	data["type"] = "shot"
	_send(data)

func send_state(data: Dictionary) -> void:
	data["type"] = "state"
	_send(data)

func send_forfeit() -> void:
	_send({"type": "forfeit"})

func _send(data: Dictionary) -> void:
	if _peer == null:
		return
	if _hosting:
		# Host mode: this phone IS the server — send straight to the
		# matched partner (never rpc_id(1), which would target itself).
		if _host_partner > 0:
			rpc_id(_host_partner, "_relay", JSON.stringify(data))
		return
	if _peer.get_connection_status() != ENetMultiplayerPeer.CONNECTION_CONNECTED:
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
	if _hosting:
		_relay_as_host(data)
		return
	match String(data.get("type", "")):
		"matched":
			matched.emit(data)
		"shot":
			shot_received.emit(data)
		"state":
			state_received.emit(data)
		"opponent_left":
			last_opponent_left_seat = int(data.get("seat", -1))
			opponent_left.emit()
		"invite_failed":
			queue_failed.emit(String(data.get("error", "The invite match could not start.")))
		"error":
			queue_failed.emit(String(data.get("message", "Server error")))

## Tears down EVERYTHING: client peer, host server, beacon, discovery.
## Called by disconnect_client() and by start_host()/connect_to_server()
## before they take over the peer.
func stop_all_net() -> void:
	stop_discovery()
	_beacon = null
	_hosting = false
	_host_partner = -1
	_host_entry = {}
	if _peer:
		_peer.close()
		_peer = null
	multiplayer.multiplayer_peer = null
	_connected = false

func disconnect_client() -> void:
	stop_all_net()
