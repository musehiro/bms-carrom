extends SceneTree

## Server matchmaking logic test (no network needed — UDP send is blocked
## in this sandbox, so the live two-client handshake cannot run here).
## Drives the real server script's queue + _try_match directly and checks
## the pairing rules from the design doc (6.5): same table, ±2 levels,
## widen to ±4 after 30 s. v6: separate 2p/4p queues, rooms, dissolve.
## Run: godot --headless --path . -s tests/server_test.gd

var _passed := 0
var _failed := 0

func _initialize() -> void:
	print("=== BMS Carrom server tests ===")
	var script: GDScript = load("res://server/net_server.gd")
	var server: Node = script.new()
	server.name = "Net"
	root.add_child(server)
	# _ready binds the ENet server (bind is allowed here; UDP *send* is not).
	var now := Time.get_unix_time_from_system()
	# 1. Same table, levels within ±2 -> match.
	(server._queue as Array).append({"id": 11, "name": "Alice", "level": 5, "table": 0, "at": now})
	(server._queue as Array).append({"id": 22, "name": "Bob", "level": 6, "table": 0, "at": now})
	server._try_match()
	_check("server: ±2 levels match", _room_count(server) == 1 and _room_players(server) == [11, 22])
	_check("server: queue drained after match", (server._queue as Array).is_empty())
	# 2. Levels 9 apart -> no match.
	_reset(server)
	(server._queue as Array).append({"id": 11, "name": "Alice", "level": 1, "table": 0, "at": now})
	(server._queue as Array).append({"id": 22, "name": "Bob", "level": 10, "table": 0, "at": now})
	server._try_match()
	_check("server: 9 levels apart do not match", (server._queue as Array).size() == 2)
	# 3. Same pair, Bob waited 40 s -> window ±4, still no match (diff 9).
	(server._queue as Array)[1]["at"] = now - 40.0
	server._try_match()
	_check("server: ±4 after 30s still blocks diff 9", (server._queue as Array).size() == 2)
	# 4. Diff 3 with 40 s wait -> match (widened window).
	(server._queue as Array)[1]["level"] = 4
	server._try_match()
	_check("server: diff 3 matches after 30s wait", _room_count(server) == 1)
	# 5. Different tables never match.
	_reset(server)
	(server._queue as Array).append({"id": 11, "name": "Alice", "level": 5, "table": 0, "at": now})
	(server._queue as Array).append({"id": 22, "name": "Bob", "level": 5, "table": 1, "at": now})
	server._try_match()
	_check("server: different tables do not match", (server._queue as Array).size() == 2)
	# 6. Disconnect removes queue entry and notifies partner (partner
	#    notification goes over the network, so here we check the queue).
	server._remove_from_queue(11)
	_check("server: disconnect removes from queue", (server._queue as Array).size() == 1)
	# 7. Matched payloads exchange stakes (v5 staking): each side learns
	#    the opponent's stake so both clients can show and pay the pot.
	var payloads: Dictionary = script.matched_payloads(
		{"name": "Alice", "level": 5, "stake": 200},
		{"name": "Bob", "level": 6, "stake": 350}, true)
	_check("server: A learns Bob's stake (350)", int(payloads["a"]["opp_stake"]) == 350 and String(payloads["a"]["opponent"]) == "Bob")
	_check("server: B learns Alice's stake (200)", int(payloads["b"]["opp_stake"]) == 200 and String(payloads["b"]["opponent"]) == "Alice")
	_check("server: breaker flags are opposite", bool(payloads["a"]["you_break"]) != bool(payloads["b"]["you_break"]))
	# 8. Missing stakes default to 0 (old clients / direct queue entries).
	var old_payloads: Dictionary = script.matched_payloads(
		{"name": "Alice", "level": 5}, {"name": "Bob", "level": 6}, false)
	_check("server: missing stake defaults to 0", int(old_payloads["a"]["opp_stake"]) == 0 and int(old_payloads["b"]["opp_stake"]) == 0)
	# --- v6: 4-player doubles ---
	# 9. Four 4p players, same table, levels within ±2 -> one room of 4.
	_reset(server)
	for k in range(4):
		(server._queue as Array).append({"id": 31 + k, "name": "P%d" % k, "level": 5 + k, "table": 0, "mode": "4p", "stake": 100, "at": now})
	server._try_match()
	_check("server 4p: four players form one room", _room_count(server) == 1 and _room_players(server).size() == 4)
	_check("server 4p: room mode is 4p", String(_room(server).get("mode", "")) == "4p")
	_check("server 4p: queue drained after match", (server._queue as Array).is_empty())
	# 10. Only three 4p players -> no match (need four).
	_reset(server)
	for k in range(3):
		(server._queue as Array).append({"id": 41 + k, "name": "Q%d" % k, "level": 5, "table": 0, "mode": "4p", "stake": 50, "at": now})
	server._try_match()
	_check("server 4p: three players do not match", _room_count(server) == 0 and (server._queue as Array).size() == 3)
	# 11. 2p and 4p queues are separate — a 2p player never joins a 4p group.
	_reset(server)
	(server._queue as Array).append({"id": 51, "name": "Solo", "level": 5, "table": 0, "mode": "2p", "stake": 0, "at": now})
	for k in range(4):
		(server._queue as Array).append({"id": 61 + k, "name": "R%d" % k, "level": 5, "table": 0, "mode": "4p", "stake": 50, "at": now})
	server._try_match()
	_check("server 4p: 2p player stays queued while 4p group matches", _room_count(server) == 1 and (server._queue as Array).size() == 1 and int((server._queue as Array)[0]["id"]) == 51)
	# 12. 4p payloads: every seat gets the full roster, its own seat and
	#     the breaker seat; exactly one player breaks.
	var infos: Array = []
	for k in range(4):
		infos.append({"name": "P%d" % k, "level": 5 + k, "stake": 100, "seat": k})
	var p4: Array = script.matched_payloads_4p(infos, 2)
	_check("server 4p: four payloads, one per seat", p4.size() == 4)
	_check("server 4p: each payload has the full 4-player roster", (p4[0]["players"] as Array).size() == 4)
	_check("server 4p: your_seat matches the payload index", int(p4[3]["your_seat"]) == 3)
	_check("server 4p: breaker seat is 2, only seat 2 breaks", int(p4[2]["breaker_seat"]) == 2 and bool(p4[2]["you_break"]) and not bool(p4[0]["you_break"]) and not bool(p4[1]["you_break"]) and not bool(p4[3]["you_break"]))
	_check("server 4p: roster carries stakes", int((p4[1]["players"] as Array)[0]["stake"]) == 100)
	# 13. Dissolve: a leaver's room is gone and the others are un-roomed.
	_reset(server)
	for k in range(4):
		(server._queue as Array).append({"id": 71 + k, "name": "S%d" % k, "level": 5, "table": 0, "mode": "4p", "stake": 50, "at": now})
	server._try_match()
	var rid := _room_id(server)
	server._dissolve_room(rid, 71)
	_check("server 4p: dissolve removes the room", _room_count(server) == 0)
	_check("server 4p: dissolve clears peer->room for the rest", not (server._peer_room as Dictionary).has(72) and not (server._peer_room as Dictionary).has(74))
	# --- v7: invite rooms ---
	# 14. Two invite_join (2p, invitee first, inviter last) -> one room,
	#     inviter is seat 0, invite room is gone.
	_reset(server)
	server._join_invite_room(82, {"group_id": "grp-1", "name": "Bob", "level": 6, "stake": 150, "mode": "2p", "table": 0, "is_inviter": false})
	_check("server invite: one joiner waits, no room yet", _room_count(server) == 0 and (server._invite_rooms as Dictionary).size() == 1)
	server._join_invite_room(81, {"group_id": "grp-1", "name": "Alice", "level": 5, "stake": 100, "mode": "2p", "table": 0, "is_inviter": true})
	_check("server invite: both joined -> one 2p room", _room_count(server) == 1 and _room_players(server) == [81, 82])
	_check("server invite: inviter is seat 0", _room_players(server)[0] == 81)
	_check("server invite: invite room cleaned up after start", (server._invite_rooms as Dictionary).is_empty())
	# 15. Duplicate join is ignored (same peer joins twice).
	_reset(server)
	server._join_invite_room(91, {"group_id": "grp-2", "name": "Bob", "level": 6, "stake": 0, "mode": "2p", "table": 0, "is_inviter": false})
	server._join_invite_room(91, {"group_id": "grp-2", "name": "Bob", "level": 6, "stake": 0, "mode": "2p", "table": 0, "is_inviter": false})
	_check("server invite: duplicate join ignored", ((server._invite_rooms as Dictionary)["grp-2"]["players"] as Array).size() == 1)
	# 16. Mismatched table join is refused (not added to the room).
	server._join_invite_room(92, {"group_id": "grp-2", "name": "Carol", "level": 5, "stake": 0, "mode": "2p", "table": 1, "is_inviter": true})
	_check("server invite: wrong-table joiner refused", ((server._invite_rooms as Dictionary)["grp-2"]["players"] as Array).size() == 1)
	# 17. 4p invite: three invitees + inviter -> one 4p room, seats 0-3.
	_reset(server)
	for k in range(3):
		server._join_invite_room(101 + k, {"group_id": "grp-3", "name": "P%d" % k, "level": 5, "stake": 100, "mode": "4p", "table": 0, "is_inviter": false})
	_check("server invite 4p: three joined, still waiting", _room_count(server) == 0)
	server._join_invite_room(104, {"group_id": "grp-3", "name": "Host", "level": 5, "stake": 100, "mode": "4p", "table": 0, "is_inviter": true})
	_check("server invite 4p: fourth joined -> one 4p room of 4", _room_count(server) == 1 and _room_players(server).size() == 4)
	_check("server invite 4p: room mode is 4p", String(_room(server).get("mode", "")) == "4p")
	_check("server invite 4p: inviter is seat 0", _room_players(server)[0] == 104)
	# 18. A player leaving before the match starts dissolves the group.
	_reset(server)
	server._join_invite_room(111, {"group_id": "grp-4", "name": "Bob", "level": 6, "stake": 0, "mode": "2p", "table": 0, "is_inviter": false})
	server._join_invite_room(112, {"group_id": "grp-4", "name": "Alice", "level": 5, "stake": 0, "mode": "2p", "table": 0, "is_inviter": true})
	# (grp-4 started — use a fresh waiting group for the leave test)
	server._join_invite_room(121, {"group_id": "grp-5", "name": "Bob", "level": 6, "stake": 0, "mode": "2p", "table": 0, "is_inviter": false})
	server._leave_invite_room(121)
	_check("server invite: leaver dissolves the waiting group", (server._invite_rooms as Dictionary).is_empty())
	# 19. Pure helpers: ready / order / infos.
	_check("server invite: room not ready with 1 of 2", not script.invite_room_ready([{"id": 1}], 2))
	_check("server invite: room ready with 2 of 2", script.invite_room_ready([{"id": 1}, {"id": 2}], 2))
	var ordered: Array = script.invite_room_order([
		{"id": 2, "name": "Bob", "level": 6, "stake": 150, "is_inviter": false},
		{"id": 1, "name": "Alice", "level": 5, "stake": 100, "is_inviter": true}])
	_check("server invite: order puts the inviter first", int(ordered[0]["id"]) == 1 and int(ordered[1]["id"]) == 2)
	var ordered_infos: Array = script.invite_room_players_to_infos(ordered)
	_check("server invite: infos carry seats 0,1 in order", int(ordered_infos[0]["seat"]) == 0 and int(ordered_infos[1]["seat"]) == 1 and String(ordered_infos[0]["name"]) == "Alice" and int(ordered_infos[1]["stake"]) == 150)
	# --- F13 Phase 1: server-side clamping + relay rate limiting ---
	# 20. Absurd-but-numeric claims are clamped, not rejected.
	var c1: Dictionary = script.sanitize_claim({"name": "Alice", "level": 999, "table": 7, "stake": 9999999, "mode": "2p"})
	_check("server f13: level 999 clamps to 100", int(c1["level"]) == 100)
	_check("server f13: stake 9999999 clamps to 1000000", int(c1["stake"]) == 1000000)
	_check("server f13: table 7 clamps to 2", int(c1["table"]) == 2)
	# 21. A 40-char name truncates to 32; a blank name becomes "Player".
	var c2: Dictionary = script.sanitize_claim({"name": "A".repeat(40), "level": 5, "table": 0, "stake": 0})
	_check("server f13: 40-char name truncates to 32", String(c2["name"]).length() == 32)
	var c3: Dictionary = script.sanitize_claim({"name": "   ", "level": 5, "table": 0, "stake": 0})
	_check("server f13: blank name becomes Player", String(c3["name"]) == "Player")
	# 22. Non-numeric level/stake and negative stake are rejected.
	_check("server f13: non-numeric level rejected", not bool(script.sanitize_claim({"name": "X", "level": "abc", "stake": 0}).get("ok", true)))
	_check("server f13: non-numeric stake rejected", not bool(script.sanitize_claim({"name": "X", "level": 5, "stake": "lots"}).get("ok", true)))
	_check("server f13: negative stake rejected", not bool(script.sanitize_claim({"name": "X", "level": 5, "stake": -50}).get("ok", true)))
	# 23. Missing fields default sanely (old clients).
	var c4: Dictionary = script.sanitize_claim({})
	_check("server f13: missing fields default to Player/Lv 1/stake 0", String(c4["name"]) == "Player" and int(c4["level"]) == 1 and int(c4["stake"]) == 0 and bool(c4.get("ok", false)))
	# 24. Rate limiting: 10 msgs/window pass, the 11th drops, and 5
	# over-limit windows disconnect; a normal 3/s rate never drops.
	var rstate := {}
	var now2 := 1000.0
	var first_ten_ok := true
	var eleventh_allowed := false
	var disconnected := false
	for w in range(5):
		for m in range(11):
			var chk: Dictionary = script.relay_rate_check(rstate, now2)
			rstate = chk["state"]
			if w == 0 and m < 10 and not bool(chk["allowed"]):
				first_ten_ok = false
			if w == 0 and m == 10:
				eleventh_allowed = bool(chk["allowed"])
			if bool(chk.get("disconnect", false)):
				disconnected = true
		now2 += 1.0
	_check("server f13: first 10 relay msgs in a window allowed", first_ten_ok)
	_check("server f13: 11th relay msg in a window dropped", not eleventh_allowed)
	_check("server f13: sustained flooding disconnects the peer", disconnected)
	var legit := {}
	var legit_ok := true
	var t2 := 2000.0
	for w in range(6):
		for m in range(3):
			var c5: Dictionary = script.relay_rate_check(legit, t2)
			legit = c5["state"]
			if not bool(c5["allowed"]) or bool(c5.get("disconnect", false)):
				legit_ok = false
		t2 += 1.0
	_check("server f13: normal relay rate (3/s) never dropped", legit_ok)
	print("=== %d passed, %d failed ===" % [_passed, _failed])
	quit(0 if _failed == 0 else 1)

func _reset(server: Node) -> void:
	(server._queue as Array).clear()
	(server._rooms as Dictionary).clear()
	(server._peer_room as Dictionary).clear()
	(server._invite_rooms as Dictionary).clear()
	(server._peer_invite as Dictionary).clear()

func _room_count(server: Node) -> int:
	return (server._rooms as Dictionary).size()

func _room(server: Node) -> Dictionary:
	var rooms: Dictionary = server._rooms
	if rooms.is_empty():
		return {}
	return rooms.values()[0]

func _room_id(server: Node) -> int:
	var rooms: Dictionary = server._rooms
	if rooms.is_empty():
		return -1
	return int(rooms.keys()[0])

func _room_players(server: Node) -> Array:
	var r := _room(server)
	if r.is_empty():
		return []
	return r.get("players", [])

func _check(name: String, cond: bool) -> void:
	if cond:
		_passed += 1
		print("PASS: ", name)
	else:
		_failed += 1
		print("FAIL: ", name)
