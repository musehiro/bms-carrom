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
# Invite rooms (v7): friends join by group_id after accepting an invite.
# The match starts when every expected player has joined; the room is
# cleaned up after 3 minutes so a slow invitee does not hold it forever.
const INVITE_ROOM_TIMEOUT := 180.0
# F13 Phase 1 — the server used to trust whatever the client claimed
# (any level, any stake, any name). Claimed fields are now sanitised
# before they are stored or matched on; nothing here verifies them
# against Supabase (that is Phase 2 — see the report). Caps are
# deliberately generous so no legitimate player is ever blocked:
# levels are 1..100, stakes 0..1,000,000, names 32 chars, tables 0..2.
const MAX_CLAIMED_NAME_LEN := 32
const MAX_CLAIMED_LEVEL := 100
const MAX_CLAIMED_STAKE := 1000000
const MAX_TABLE := 2
# Relay rate limit: a client can legitimately send ~1 shot + 1 state
# per turn (a few per second at most). Over 10 shot/state messages in
# one second is flooding — drop the excess, and disconnect a peer that
# sustains it (5 over-limit windows).
const RELAY_MAX_PER_SEC := 10
const RELAY_MAX_VIOLATIONS := 5

var _peer: ENetMultiplayerPeer = null
var _queue: Array = [] # {id, name, level, table, stake, mode, at}
var _rooms := {} # room_id -> {mode, players: [peer ids]}
var _peer_room := {} # peer_id -> room_id
var _names := {} # peer_id -> display name
var _invite_rooms := {} # group_id -> {mode, expected, table, players: [...], at}
var _peer_invite := {} # peer_id -> group_id (waiting in an invite room)
var _relay_limits := {} # F13: peer_id -> {window_start, count, violations}
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
		_expire_invite_rooms()

func _on_peer_connected(id: int) -> void:
	print("[Server] Peer connected: %d" % id)

func _on_peer_disconnected(id: int) -> void:
	print("[Server] Peer disconnected: %d" % id)
	_remove_from_queue(id)
	_leave_invite_room(id)
	_relay_limits.erase(id)
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
			# F13 Phase 1: sanitise the claim before it is stored or
			# matched on. A non-numeric level/stake or a negative
			# stake is not queued at all.
			var claim := sanitize_claim(data)
			if not bool(claim.get("ok", false)):
				_send_to(sender, {"type": "error", "message": String(claim.get("error", "Bad matchmaking request."))})
				print("[Server] Rejected queue from peer %d: %s" % [sender, claim.get("error", "")])
				return
			_names[sender] = String(claim["name"])
			_remove_from_queue(sender)
			var mode := String(claim["mode"])
			_queue.append({"id": sender, "name": String(claim["name"]),
				"level": int(claim["level"]), "table": int(claim["table"]),
				"stake": int(claim["stake"]), "mode": mode,
				"at": Time.get_unix_time_from_system()})
			print("[Server] %s (Lv %d) queued for %s table %d, stake %d" % [claim["name"], int(claim["level"]), mode, int(claim["table"]), int(claim["stake"])])
			_try_match()
		"invite_join":
			_names[sender] = String(data.get("name", "Player"))
			_join_invite_room(sender, data)
		"shot", "state":
			_relay_to_room(sender, data)
		"forfeit":
			var room_id2: int = int(_peer_room.get(sender, -1))
			if room_id2 >= 0:
				_dissolve_room(room_id2, sender)

## Relay a shot/state message to everyone else in the sender's room.
## F13 Phase 1: per-peer rate limiting — a flooding peer's excess
## messages are dropped, and a peer that sustains flooding is
## disconnected (its room then dissolves via _on_peer_disconnected).
func _relay_to_room(sender: int, data: Dictionary) -> void:
	var room_id: int = int(_peer_room.get(sender, -1))
	if room_id < 0:
		return
	var check := relay_rate_check(_relay_limits.get(sender, {}), Time.get_unix_time_from_system())
	_relay_limits[sender] = check["state"]
	if not bool(check.get("allowed", false)):
		if bool(check.get("disconnect", false)):
			print("[Server] Disconnecting peer %d for relay flooding" % sender)
			_relay_limits.erase(sender)
			_peer.disconnect_peer(sender)
		return
	var room: Dictionary = _rooms.get(room_id, {})
	for pid in room.get("players", []):
		if int(pid) != sender:
			_send_to(int(pid), data)

## F13 Phase 1 — sanitise a client's claimed identity for queue /
## invite_join. Pure, unit-tested. Returns {ok, name, level, table,
## stake, mode} on success, {ok: false, error} when the claim is not
## even well-formed (non-numeric level/stake, negative stake).
## Clamping (not rejection) is used for out-of-range-but-numeric
## values, so a slightly-off client still plays: level 1..100, stake
## 0..1,000,000, table 0..2, name stripped + truncated to 32 chars.
static func sanitize_claim(data: Dictionary) -> Dictionary:
	var level_raw: Variant = data.get("level", 1)
	var stake_raw: Variant = data.get("stake", 0)
	var table_raw: Variant = data.get("table", 0)
	if typeof(level_raw) != TYPE_INT and typeof(level_raw) != TYPE_FLOAT:
		return {"ok": false, "error": "Level must be a number."}
	if typeof(stake_raw) != TYPE_INT and typeof(stake_raw) != TYPE_FLOAT:
		return {"ok": false, "error": "Stake must be a number."}
	if typeof(table_raw) != TYPE_INT and typeof(table_raw) != TYPE_FLOAT:
		return {"ok": false, "error": "Table must be a number."}
	var stake := int(stake_raw)
	if stake < 0:
		return {"ok": false, "error": "Stake cannot be negative."}
	var mode := String(data.get("mode", "2p"))
	if mode != "4p":
		mode = "2p"
	var pname := String(data.get("name", "Player")).strip_edges()
	if pname == "":
		pname = "Player"
	if pname.length() > MAX_CLAIMED_NAME_LEN:
		pname = pname.substr(0, MAX_CLAIMED_NAME_LEN)
	return {"ok": true, "name": pname,
		"level": clampi(int(level_raw), 1, MAX_CLAIMED_LEVEL),
		"table": clampi(int(table_raw), 0, MAX_TABLE),
		"stake": mini(stake, MAX_CLAIMED_STAKE), "mode": mode, "error": ""}

## F13 Phase 1 — one relay-rate-limit step for a peer. `state` is the
## peer's {window_start, count, violations} ({} for a new peer).
## Returns {allowed, disconnect, state}. Pure, unit-tested.
static func relay_rate_check(state: Dictionary, now: float) -> Dictionary:
	var window_start := float(state.get("window_start", now))
	var count := int(state.get("count", 0))
	var violations := int(state.get("violations", 0))
	if now - window_start >= 1.0:
		# New window: a clean previous window forgives one past
		# violation; an over-limit one does not.
		if count <= RELAY_MAX_PER_SEC:
			violations = maxi(0, violations - 1)
		window_start = now
		count = 1
		return {"allowed": true, "disconnect": false,
			"state": {"window_start": window_start, "count": count, "violations": violations}}
	count += 1
	if count > RELAY_MAX_PER_SEC:
		violations += 1
		return {"allowed": false, "disconnect": violations >= RELAY_MAX_VIOLATIONS,
			"state": {"window_start": window_start, "count": count, "violations": violations}}
	return {"allowed": true, "disconnect": false,
		"state": {"window_start": window_start, "count": count, "violations": violations}}

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

## Invite rooms (v7): friends join by group_id after accepting a
## Supabase invite. The match starts when every expected player has
## joined; stakes lock only at match start, as in v6. The inviter is
## always seat 0 (they join last, when the group is ready); invitees
## take seats 1.. in join order.

func _join_invite_room(sender: int, data: Dictionary) -> void:
	var group_id := String(data.get("group_id", ""))
	if group_id == "":
		_send_to(sender, {"type": "invite_failed", "error": "No invite group — try again."})
		return
	# F13 Phase 1: sanitise the claim once, up front — the room table
	# and the stored player fields all use these values, never the
	# raw client JSON.
	var claim := sanitize_claim(data)
	if not bool(claim.get("ok", false)):
		_send_to(sender, {"type": "invite_failed", "error": String(claim.get("error", "Bad invite request."))})
		return
	var mode := String(claim["mode"])
	var table := int(claim["table"])
	var expected := 4 if mode == "4p" else 2
	if _peer_invite.has(sender):
		return # duplicate join — already waiting
	var room: Dictionary = _invite_rooms.get(group_id, {})
	if room.is_empty():
		room = {"mode": mode, "expected": expected,
			"table": table, "players": [],
			"at": Time.get_unix_time_from_system()}
		_invite_rooms[group_id] = room
	if String(room.get("mode", "2p")) != mode or int(room.get("table", 0)) != table:
		_send_to(sender, {"type": "invite_failed", "error": "This invite does not match the group."})
		return
	var players: Array = room["players"]
	players.append({"id": sender, "name": String(claim["name"]),
		"level": int(claim["level"]), "stake": int(claim["stake"]),
		"is_inviter": bool(data.get("is_inviter", false))})
	_peer_invite[sender] = group_id
	print("[Server] Invite room %s: %s joined (%d/%d)" % [group_id, data.get("name"), players.size(), expected])
	if invite_room_ready(players, expected):
		_start_invite_match(group_id, room)

func _start_invite_match(group_id: String, room: Dictionary) -> void:
	var ordered := invite_room_order(room["players"])
	var mode := String(room.get("mode", "2p"))
	var ids: Array = []
	for p in ordered:
		ids.append(int(p["id"]))
		_peer_invite.erase(int(p["id"]))
	_invite_rooms.erase(group_id)
	if mode == "4p":
		var infos := invite_room_players_to_infos(ordered)
		var breaker_seat := randi() % 4
		var room_id := _new_room("4p", ids)
		var payloads := matched_payloads_4p(infos, breaker_seat)
		for k in range(4):
			_send_to(ids[k], payloads[k])
		print("[Server] Invite match #%d (4p, group %s): %s + %s vs %s + %s" % [room_id, group_id, infos[0]["name"], infos[2]["name"], infos[1]["name"], infos[3]["name"]])
	else:
		var a_breaks := randi() % 2 == 0
		var room_id2 := _new_room("2p", ids)
		var payloads2 := matched_payloads(ordered[0], ordered[1], a_breaks)
		_send_to(ids[0], payloads2["a"])
		_send_to(ids[1], payloads2["b"])
		print("[Server] Invite match #%d (2p, group %s): %s vs %s" % [room_id2, group_id, ordered[0]["name"], ordered[1]["name"]])

## A player left (or disconnected) before the invite match started:
## the rest cannot play, so tell them and drop the group.
func _leave_invite_room(peer_id: int) -> void:
	var group_id: String = String(_peer_invite.get(peer_id, ""))
	if group_id == "":
		return
	_peer_invite.erase(peer_id)
	var room: Dictionary = _invite_rooms.get(group_id, {})
	if room.is_empty():
		return
	var players: Array = room["players"]
	for i in range(players.size() - 1, -1, -1):
		if int(players[i]["id"]) == peer_id:
			players.remove_at(i)
	if players.is_empty():
		_invite_rooms.erase(group_id)
		return
	for p in players:
		_peer_invite.erase(int(p["id"]))
		_send_to(int(p["id"]), {"type": "invite_failed", "error": "A player left before the match started."})
	_invite_rooms.erase(group_id)
	print("[Server] Invite room %s dissolved (a player left)" % group_id)

## Drop invite rooms that never filled within the timeout.
func _expire_invite_rooms() -> void:
	var now := Time.get_unix_time_from_system()
	var dead: Array = []
	for gid in _invite_rooms.keys():
		var room: Dictionary = _invite_rooms[gid]
		if now - float(room.get("at", 0.0)) > INVITE_ROOM_TIMEOUT:
			dead.append(gid)
	for gid in dead:
		var room2: Dictionary = _invite_rooms[gid]
		for p in room2.get("players", []):
			_peer_invite.erase(int(p["id"]))
			_send_to(int(p["id"]), {"type": "invite_failed", "error": "Not everyone joined in time — send the invite again."})
		_invite_rooms.erase(gid)
		print("[Server] Invite room %s expired (not everyone joined)" % gid)

## Pure helpers (unit-tested): the room is ready when every expected
## player has joined.
static func invite_room_ready(players: Array, expected: int) -> bool:
	return players.size() >= expected

## Seat order: the inviter is seat 0; invitees take seats 1.. in join
## order. Pure — unit-tested.
static func invite_room_order(players: Array) -> Array:
	var ordered: Array = []
	for p in players:
		if bool(p.get("is_inviter", false)):
			ordered.push_front(p)
		else:
			ordered.append(p)
	return ordered

## Ordered invite-room players -> the infos shape matched_payloads_4p
## wants ({name, level, stake, seat}). Pure — unit-tested.
static func invite_room_players_to_infos(ordered: Array) -> Array:
	var infos: Array = []
	for k in range(ordered.size()):
		var p: Dictionary = ordered[k]
		infos.append({"name": String(p["name"]), "level": int(p["level"]),
			"stake": maxi(0, int(p.get("stake", 0))), "seat": k})
	return infos

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
