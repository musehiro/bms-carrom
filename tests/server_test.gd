extends SceneTree

## Server matchmaking logic test (no network needed — UDP send is blocked
## in this sandbox, so the live two-client handshake cannot run here).
## Drives the real server script's queue + _try_match directly and checks
## the pairing rules from the design doc (6.5): same table, ±2 levels,
## widen to ±4 after 30 s.
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
	_check("server: ±2 levels match", int(server._matches.get(11, -1)) == 22 and int(server._matches.get(22, -1)) == 11)
	_check("server: queue drained after match", (server._queue as Array).is_empty())
	# 2. Levels 9 apart -> no match.
	server._matches.clear()
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
	_check("server: diff 3 matches after 30s wait", int(server._matches.get(11, -1)) == 22)
	# 5. Different tables never match.
	server._matches.clear()
	(server._queue as Array).clear()
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
	print("=== %d passed, %d failed ===" % [_passed, _failed])
	quit(0 if _failed == 0 else 1)

func _check(name: String, cond: bool) -> void:
	if cond:
		_passed += 1
		print("PASS: ", name)
	else:
		_failed += 1
		print("FAIL: ", name)
