extends Node

## BMS Carrom server — matchmaking + relay (NOT a physics authority).
## The server matches players of similar level on the same table, then
## only relays their shot/state messages. Both clients simulate the same
## physics from the same inputs, with a full state snapshot after each shot
## to resync. This keeps the server tiny and cheap to host.
##
## Two modes (v6): "2p" singles and "4p" doubles (two teams of two —
## seats 0,2 vs 1,3, partners opposite). Each mode has its own queue.
##
## Scale (v6, for 100K–200K players): one process is a matchmaking queue
## + independent game rooms. Matching runs ONLY when the queue changes
## (a player queues or leaves) plus once a second for the 30 s widening
## — never every frame — so a big queue stays cheap. See
## docs/online-server.md for honest capacity numbers.
##
## Node path MUST be /root/Net (autoload "Net") — the same as the client's
## autoload — because Godot RPCs are addressed by node path.
##
## Run:  godot --headless --path server -- --port 8910
## (or just: godot --headless --path server)

const DEFAULT_PORT := 8910
const MAX_PEERS := 1024 # ENet cap per process; see docs for real capacity
const WIDEN_AFTER_SEC := 30.0
const MATCH_SCAN_INTERVAL := 1.0 # seconds between widening re-scans

var _peer: ENetMultiplayerPeer = null
var _queue: Array = [] # {id, name, level, table, stake, mode, at}
var _rooms := {} # room_id -> {mode, players: [peer ids]}
var _peer_room := {} # peer_id -> room_id
var _names := {} # peer_id -> display name
var _room_seq := 0
var _scan_timer := 0.0

func _ready() -> void:
	var port := DEFAULT_PORT
	for a in OS.get_cmdline_user_args():
		if a.begins_with("--port="):
			port = int(a.trim_prefix("--port="))
	_peer = ENetMultiplayerPeer.new()
	var err := _peer.create_server(port, MAX_PEERS)
	if err != OK:
		printerr("[Server] Failed to start on port %d: %s" % [port, error_string(err)])
		get_tree().quit(1)
		return
	multiplayer.multiplayer_peer = _peer
	multiplayer.peer_connected.connect(_on_peer_connected)
	multiplayer.peer_disconnected.connect(_on_peer_disconnected)
	print("[Server] BMS Carrom matchmaking server listening on port %d (max %d peers)" % [port, MAX_PEERS])
	print("[Server] Waiting for players… (Ctrl+C to stop)")

func _process(delta: float) -> void:
	# Widening re-scan only: matching itself is event-driven (on queue /
	# disconnect), so a big queue costs nothing between events.
	_scan_timer += delta
	if _scan_timer >= MATCH_SCAN_INTERVAL:
		_scan_timer = 0.0
		_try_match()

func _on_peer_connected(id: int) -> void:
	print("[Server] Peer connected: %d" % id)

func _on_peer_disconnected(id: int) -> void:
	print("[Server] Peer disconnected: %d" % id)
	_remove_from_queue(id)
	var room_id: int = int(_peer_room.get(id, -1))
	if room_id >= 0:
		_dissolve_room(room_id, id)
	_names.erase(id)

func _remove_from_queue(id: int) -> void:
	for i in range(_queue.size() - 1, -1, -1):
		if int(_queue[i]["id"]) == id:
			_queue.remove_at(i)

## Dissolve a room because a player left: the rest get opponent_left
## (with the leaver's seat for 4p rooms, so clients can work out which
## team forfeited). The room is gone — no rejoin.
func _dissolve_room(room_id: int, leaver_id: int) -> void:
	var room: Dictionary = _rooms.get(room_id, {})
	if room.is_empty():
		return
	var players: Array = room.get("players", [])
	var leaver_seat := players.find(leaver_id)
	for pid in players:
		_peer_room.erase(int(pid))
		if int(pid) != leaver_id:
			var msg := {"type": "opponent_left"}
			if String(room.get("mode", "2p")) == "4p":
				msg["seat"] = leaver_seat
			_send_to(int(pid), msg)
	_rooms.erase(room_id)
	print("[Server] Room %d dissolved (player %d left)" % [room_id, leaver_id])

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
			var mode := String(data.get("mode", "2p"))
			if mode != "4p":
				mode = "2p"
			_queue.append({"id": sender, "name": String(data.get("name", "Player")),
				"level": int(data.get("level", 1)), "table": int(data.get("table", 0)),
				"stake": maxi(0, int(data.get("stake", 0))), "mode": mode,
				"at": Time.get_unix_time_from_system()})
			print("[Server] %s (Lv %d) queued for %s table %d, stake %d" % [data.get("name"), int(data.get("level", 1)), mode, int(data.get("table", 0)), int(data.get("stake", 0))])
			_try_match()
		"shot", "state":
			_relay_to_room(sender, data)
		"forfeit":
			var room_id2: int = int(_peer_room.get(sender, -1))
			if room_id2 >= 0:
				_dissolve_room(room_id2, sender)

## Relay a shot/state message to everyone else in the sender's room.
func _relay_to_room(sender: int, data: Dictionary) -> void:
	var room_id: int = int(_peer_room.get(sender, -1))
	if room_id < 0:
		return
	var room: Dictionary = _rooms.get(room_id, {})
	for pid in room.get("players", []):
		if int(pid) != sender:
			_send_to(int(pid), data)

## Pair up waiting players. 2p: two players, same mode+table, levels
## within ±2 (±4 after 30 s). 4p: four players on the same mode+table
## whose levels are all within the window of the first player's level.
## Runs on queue/disconnect events + once a second (widening only).
func _try_match() -> void:
	var now := Time.get_unix_time_from_system()
	var i := 0
	while i < _queue.size():
		var a: Dictionary = _queue[i]
		var mode := String(a.get("mode", "2p"))
		var wait_a: float = now - float(a["at"])
		var window := 2
		if wait_a >= WIDEN_AFTER_SEC:
			window = 4
		if mode == "4p":
			var group := _collect_group(a, window, now)
			if group.size() == 4:
				for e in group:
					_remove_from_queue(int(e["id"]))
				_start_match_4p(group)
				# Queue shrank — restart the scan from the top.
				i = 0
				continue
			i += 1
		else:
			var matched := false
			for j in range(i + 1, _queue.size()):
				var b: Dictionary = _queue[j]
				if String(b.get("mode", "2p")) != "2p":
					continue
				if int(a["table"]) != int(b["table"]):
					continue
				var wait_b: float = now - float(b["at"])
				var w := window
				if wait_b >= WIDEN_AFTER_SEC:
					w = 4
				if absf(int(a["level"]) - int(b["level"])) <= w:
					_queue.remove_at(j)
					_queue.remove_at(i)
					_start_match_2p(a, b)
					matched = true
					break
			if not matched:
				i += 1

## Collect up to 4 queue entries for a 4p group: same mode+table, levels
## within `window` of the anchor's level. Returns the group (may be < 4).
func _collect_group(anchor: Dictionary, window: int, now: float) -> Array:
	var group: Array = [anchor]
	for e in _queue:
		if group.size() >= 4:
			break
		if int(e["id"]) == int(anchor["id"]):
			continue
		if String(e.get("mode", "2p")) != "4p":
			continue
		if int(e["table"]) != int(anchor["table"]):
			continue
		var wait_e: float = now - float(e["at"])
		var w := window
		if wait_e >= WIDEN_AFTER_SEC:
			w = 4
		if absf(int(e["level"]) - int(anchor["level"])) <= w:
			group.append(e)
	return group

func _new_room(mode: String, player_ids: Array) -> int:
	_room_seq += 1
	_rooms[_room_seq] = {"mode": mode, "players": player_ids}
	for pid in player_ids:
		_peer_room[int(pid)] = _room_seq
	return _room_seq

func _start_match_2p(a: Dictionary, b: Dictionary) -> void:
	var a_breaks := randi() % 2 == 0
	var room_id := _new_room("2p", [int(a["id"]), int(b["id"])])
	var payloads := matched_payloads(a, b, a_breaks)
	_send_to(int(a["id"]), payloads["a"])
	_send_to(int(b["id"]), payloads["b"])
	print("[Server] Match #%d (2p): %s (Lv %d, stake %d) vs %s (Lv %d, stake %d), table %d — %s breaks" % [
		room_id, a["name"], int(a["level"]), int(a.get("stake", 0)),
		b["name"], int(b["level"]), int(b.get("stake", 0)), int(a["table"]),
		a["name"] if a_breaks else b["name"]])

func _start_match_4p(group: Array) -> void:
	# Seats 0-3 in queue order; a random seat breaks (their team plays white).
	var breaker_seat := randi() % 4
	var ids: Array = []
	var infos: Array = []
	for k in range(4):
		var e: Dictionary = group[k]
		ids.append(int(e["id"]))
		infos.append({"name": String(e["name"]), "level": int(e["level"]),
			"stake": maxi(0, int(e.get("stake", 0))), "seat": k})
	var room_id := _new_room("4p", ids)
	var payloads := matched_payloads_4p(infos, breaker_seat)
	for k in range(4):
		_send_to(ids[k], payloads[k])
	print("[Server] Match #%d (4p): %s (Lv %d) + %s (Lv %d) vs %s (Lv %d) + %s (Lv %d), table %d — seat %d breaks" % [
		room_id, infos[0]["name"], int(infos[0]["level"]), infos[2]["name"], int(infos[2]["level"]),
		infos[1]["name"], int(infos[1]["level"]), infos[3]["name"], int(infos[3]["level"]),
		int(group[0]["table"]), breaker_seat])

## The two "matched" payloads (pure function, unit-tested): each side gets
## the opponent's name, level and STAKE, so both clients can show the pot
## and pay it out. Stakes default to 0 when absent (old clients / tests).
static func matched_payloads(a: Dictionary, b: Dictionary, a_breaks: bool) -> Dictionary:
	return {
		"a": {"type": "matched", "opponent": String(b["name"]),
			"opp_level": int(b["level"]), "you_break": a_breaks,
			"opp_stake": int(b.get("stake", 0))},
		"b": {"type": "matched", "opponent": String(a["name"]),
			"opp_level": int(a["level"]), "you_break": not a_breaks,
			"opp_stake": int(a.get("stake", 0))},
	}

## 4p matched payloads (pure function, unit-tested): every player gets
## the full seat-ordered roster (name/level/stake/seat), their own seat
## and the breaker seat — so each client can show the teams, the pot and
## the turn order. Returns an Array of 4 payloads, one per seat.
static func matched_payloads_4p(infos: Array, breaker_seat: int) -> Array:
	var out: Array = []
	for k in range(4):
		var roster: Array = []
		for e in infos:
			roster.append({"name": String(e["name"]), "level": int(e["level"]),
				"stake": maxi(0, int(e.get("stake", 0))), "seat": int(e["seat"])})
		out.append({"type": "matched", "mode": "4p", "players": roster,
			"your_seat": k, "breaker_seat": breaker_seat,
			"you_break": k == breaker_seat})
	return out

func _send_to(peer_id: int, data: Dictionary) -> void:
	rpc_id(peer_id, "_relay", JSON.stringify(data))
