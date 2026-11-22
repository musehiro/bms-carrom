extends SceneTree

## LAN (same-Wi-Fi) host-mode test — no real sockets. Covers the pure
## beacon helpers and the host-side state machine (_handle_host_queue /
## _handle_host_message), which are split out so tests can drive them
## directly. The live two-phone LAN match can only be confirmed on real
## phones (UDP is blocked in this sandbox).
## Run: godot --headless --path . -s tests/lan_test.gd

var _passed := 0
var _failed := 0
var _matched: Dictionary = {}
var _shots: Array = []
var _left := false

func _initialize() -> void:
	print("=== BMS Carrom LAN tests ===")
	var script: GDScript = load("res://scripts/net_client.gd")
	# --- beacon payload round-trip ---
	var payload: String = script.lan_beacon_payload("Buddhika")
	var parsed: Dictionary = script.lan_parse_beacon(payload.to_utf8_buffer(), "192.168.1.7")
	_check("lan: beacon round-trips name", String(parsed.get("name", "")) == "Buddhika")
	_check("lan: beacon round-trips ip", String(parsed.get("ip", "")) == "192.168.1.7")
	_check("lan: beacon round-trips port 8910", int(parsed.get("port", 0)) == 8910)
	# --- parse rejects bad input ---
	_check("lan: wrong type rejected", (script.lan_parse_beacon(JSON.stringify({"type": "other", "name": "X"}).to_utf8_buffer(), "192.168.1.7") as Dictionary).is_empty())
	_check("lan: bad JSON rejected", (script.lan_parse_beacon("not json".to_utf8_buffer(), "192.168.1.7") as Dictionary).is_empty())
	_check("lan: empty name rejected", (script.lan_parse_beacon(JSON.stringify({"type": "carrom-host", "name": "  "}).to_utf8_buffer(), "192.168.1.7") as Dictionary).is_empty())
	_check("lan: empty sender ip rejected", (script.lan_parse_beacon(payload.to_utf8_buffer(), "") as Dictionary).is_empty())
	# --- local IPs are private only ---
	var ips: Array = script.lan_local_ips()
	var all_private := true
	for ip in ips:
		var s := String(ip)
		if not (s.begins_with("192.168.") or s.begins_with("10.") or (s.begins_with("172.") and int(s.split(".")[1]) >= 16 and int(s.split(".")[1]) <= 31)):
			all_private = false
	_check("lan: local IPs are private only", all_private)
	# --- host-mode state machine (no sockets) ---
	var net: Node = script.new()
	net.name = "NetTest"
	root.add_child(net)
	net.matched.connect(func(d: Dictionary) -> void: _matched = d)
	net.shot_received.connect(func(d: Dictionary) -> void: _shots.append(d))
	net.opponent_left.connect(func() -> void: _left = true)
	net._host_entry = {"name": "Host", "level": 5, "table": 0, "stake": 100}
	net._handle_host_queue(7, {"type": "queue", "name": "Joiner", "level": 6, "stake": 50})
	_check("lan host: first joiner is matched", int(net._host_partner) == 7)
	_check("lan host: matched payload names the joiner", String(_matched.get("opponent", "")) == "Joiner")
	_check("lan host: matched payload carries the joiner's stake", int(_matched.get("opp_stake", 0)) == 50)
	_check("lan host: matched payload has a breaker flag", _matched.has("you_break"))
	net._handle_host_queue(9, {"type": "queue", "name": "Late", "level": 5, "stake": 10})
	_check("lan host: second joiner ignored while matched", int(net._host_partner) == 7 and String(_matched.get("opponent", "")) == "Joiner")
	net._handle_host_message(7, {"type": "shot", "dx": 0.5, "dy": -0.5, "power": 0.8})
	_check("lan host: partner's shot is relayed", _shots.size() == 1)
	net._handle_host_message(9, {"type": "shot", "dx": 0.5, "dy": -0.5, "power": 0.8})
	_check("lan host: stranger's shot is ignored", _shots.size() == 1)
	net._handle_host_message(7, {"type": "forfeit"})
	_check("lan host: partner forfeit clears the partner + emits left", int(net._host_partner) == -1 and _left)
	print("=== %d passed, %d failed ===" % [_passed, _failed])
	quit(0 if _failed == 0 else 1)

func _check(name: String, cond: bool) -> void:
	if cond:
		_passed += 1
		print("PASS: ", name)
	else:
		_failed += 1
		print("FAIL: ", name)
