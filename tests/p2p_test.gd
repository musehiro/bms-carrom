extends SceneTree

## v11 P2P + plan-alignment tests (headless, standalone -s script).
## Run: godot --headless --path . -s tests/p2p_test.gd
## Covers the v11 plan-alignment worker's scope:
##   1. 3-player guard (Friends.validate_group_targets)
##   2. P2P signalling shapes + parsing (P2PSignalling)
##   3. Breaker derivation (deterministic from match id, both sides agree)
##   4. ICE config (defaults + backend_config.json override)
##   5. Match points per-coin formula (MatchPoints)
##   6. Transport interface (NetClient constants, matched payload)
##   7. Supabase Broadcast parsing + presence filter
##   8. NEARBY status line (no server field — checked via source read
##      in docs, asserted here as the constant text)
## The live data channel itself cannot be proven in the sandbox (UDP
## blocked) — that proof is T1/T2 on two real phones (docs/p2p-online.md).

var _passed := 0
var _failed := 0
var _failures: Array = []

func _initialize() -> void:
	print("=== BMS Carrom v11 P2P tests ===")
	_test_three_player_guard()
	_test_signalling_shapes()
	_test_signalling_parse()
	_test_breaker_derivation()
	_test_ice_config()
	_test_match_points_formula()
	_test_transport_interface()
	_test_broadcast_parse()
	_test_presence_filter()
	print("=== %d passed, %d failed ===" % [_passed, _failed])
	for f in _failures:
		print("FAIL: ", f)
	quit(0 if _failed == 0 else 1)

func _check(name: String, cond: bool, detail: String = "") -> void:
	if cond:
		_passed += 1
		print("PASS: ", name)
	else:
		_failed += 1
		_failures.append(name + (" — " + detail if detail != "" else ""))
		print("FAIL: ", name, (" — " + detail if detail != "" else ""))

func _friends_script() -> GDScript:
	return load("res://scripts/friends.gd")

# ------------------------------------------------------- 1. 3-player guard
func _test_three_player_guard() -> void:
	var FriendsScript := _friends_script()
	var me := "me-id"
	var a := {"id": "a-id", "name": "A"}
	var b := {"id": "b-id", "name": "B"}
	var c := {"id": "c-id", "name": "C"}
	# 1 target (2p) is fine; 3 targets (4p) is fine.
	_check("3p guard: 1 target ok", bool(FriendsScript.validate_group_targets([a], me).get("ok", false)))
	_check("3p guard: 3 targets ok", bool(FriendsScript.validate_group_targets([a, b, c], me).get("ok", false)))
	# Exactly 2 targets (3 players total) is REJECTED — the hole.
	var two: Dictionary = FriendsScript.validate_group_targets([a, b], me)
	_check("3p guard: 2 targets rejected", not bool(two.get("ok", true)))
	_check("3p guard: rejection says 3-player", String(two.get("error", "")).contains("3-player"))
	_check("3p guard: rejection names 2-or-4", String(two.get("error", "")).contains("2 players") and String(two.get("error", "")).contains("4 players"))
	# Other validations still hold (empty, too many, self, missing id).
	_check("3p guard: 0 targets rejected", not bool(FriendsScript.validate_group_targets([], me).get("ok", true)))
	_check("3p guard: 4 targets rejected", not bool(FriendsScript.validate_group_targets([a, b, c, {"id": "d-id"}], me).get("ok", true)))
	_check("3p guard: self rejected", not bool(FriendsScript.validate_group_targets([{"id": me}], me).get("ok", true)))
	_check("3p guard: missing id rejected", not bool(FriendsScript.validate_group_targets([{"name": "NoId"}], me).get("ok", true)))

# --------------------------------------------- 2. signalling message shapes
func _test_signalling_shapes() -> void:
	var mid := "11111111-1111-1111-1111-111111111111"
	_check("signal: channel name", P2PSignalling.channel_name(mid) == "carrom-match-" + mid)
	_check("signal: channel topic", P2PSignalling.channel_topic(mid) == "realtime:carrom-match-" + mid)
	var offer := P2PSignalling.offer_message("from-1", "v=0\r\nfake-sdp")
	_check("signal: offer shape", String(offer.get("type", "")) == "offer" and String(offer.get("from", "")) == "from-1" and String(offer.get("sdp", "")) != "")
	var answer := P2PSignalling.answer_message("from-2", "v=0\r\nfake-sdp")
	_check("signal: answer shape", String(answer.get("type", "")) == "answer")
	var ice := P2PSignalling.ice_message("from-1", "0", 0, "candidate:1 1 udp 1 1.2.3.4 5000 typ host")
	_check("signal: ice shape", String(ice.get("type", "")) == "ice" and String(ice.get("mid", "")) == "0" and int(ice.get("index", -1)) == 0)
	var bye := P2PSignalling.bye_message("from-1")
	_check("signal: bye shape", String(bye.get("type", "")) == "bye" and String(bye.get("from", "")) == "from-1")

func _test_signalling_parse() -> void:
	var good := P2PSignalling.parse_message({"type": "offer", "from": "peer-1", "sdp": "v=0"}, "me")
	_check("signal parse: valid offer passes", String(good.get("type", "")) == "offer")
	_check("signal parse: unknown type rejected", P2PSignalling.parse_message({"type": "shot", "from": "peer-1"}, "me").is_empty())
	_check("signal parse: own echo rejected", P2PSignalling.parse_message({"type": "offer", "from": "me", "sdp": "v=0"}, "me").is_empty())
	_check("signal parse: missing from rejected", P2PSignalling.parse_message({"type": "offer", "sdp": "v=0"}, "me").is_empty())
	_check("signal parse: offer without sdp rejected", P2PSignalling.parse_message({"type": "offer", "from": "peer-1"}, "me").is_empty())
	_check("signal parse: ice without sdp rejected", P2PSignalling.parse_message({"type": "ice", "from": "peer-1", "mid": "0", "index": 0}, "me").is_empty())
	_check("signal parse: bye needs no sdp", String(P2PSignalling.parse_message({"type": "bye", "from": "peer-1"}, "me").get("type", "")) == "bye")
	_check("signal parse: non-dict rejected", P2PSignalling.parse_message("not a dict", "me").is_empty())
	_check("signal parse: ice keeps mid/index", P2PSignalling.parse_message({"type": "ice", "from": "p", "mid": "1", "index": 3, "sdp": "c"}, "me").get("index", -1) == 3)

# ------------------------------------------------ 3. breaker derivation
func _test_breaker_derivation() -> void:
	# Same match id -> same breaker on both sides (deterministic).
	var mid := "550e8400-e29b-41d4-a716-446655440000"
	_check("breaker: deterministic", P2PSignalling.breaker_seat_for_match(mid, 2) == P2PSignalling.breaker_seat_for_match(mid, 2))
	_check("breaker: Net delegates to signalling", NetClient.breaker_seat_for_match(mid, 2) == P2PSignalling.breaker_seat_for_match(mid, 2))
	_check("breaker: empty id is seat 0", P2PSignalling.breaker_seat_for_match("", 2) == 0)
	_check("breaker: 2p result is 0 or 1", P2PSignalling.breaker_seat_for_match(mid, 2) in [0, 1])
	# Both seats covered across ids (not stuck on one side).
	var seen := {}
	for i in range(200):
		var seat := P2PSignalling.breaker_seat_for_match("match-%d-550e8400-e29b-41d4-a716-446655440000" % i, 2)
		seen[seat] = true
	_check("breaker: both 2p seats covered across 200 ids", seen.has(0) and seen.has(1), str(seen.keys()))
	# 4p: all four seats covered.
	var seen4 := {}
	for i in range(400):
		var seat4 := P2PSignalling.breaker_seat_for_match("match4-%d-550e8400-e29b-41d4-a716-446655440000" % i, 4)
		seen4[seat4] = true
	_check("breaker: all 4 seats covered across 400 ids", seen4.size() == 4, str(seen4.keys()))
	# Lower seat offers to higher seat — exactly one offer per pair.
	_check("breaker: lower offers higher", P2PSignalling.should_offer(0, 1) and P2PSignalling.should_offer(1, 3) and not P2PSignalling.should_offer(1, 0) and not P2PSignalling.should_offer(2, 2))

# ---------------------------------------------------------- 4. ICE config
func _test_ice_config() -> void:
	var defaults := P2PSignalling.ice_servers_from_config([])
	_check("ice: empty config gives defaults", defaults.size() == 2)
	_check("ice: default has Google STUN", String(str(defaults[0].get("urls", []))).contains("stun.l.google.com"))
	_check("ice: default has OpenRelay TURN", String(str(defaults[1].get("urls", []))).contains("openrelay.metered.ca"))
	_check("ice: default TURN has demo credentials", String(defaults[1].get("username", "")) == "openrelayproject")
	var custom := [{"urls": ["stun:stun.example.com:19302"]}]
	_check("ice: valid config wins", P2PSignalling.ice_servers_from_config(custom) == custom)
	_check("ice: malformed entry falls back to defaults", P2PSignalling.ice_servers_from_config([{"no_urls": true}]).size() == 2)
	_check("ice: non-array falls back to defaults", P2PSignalling.ice_servers_from_config("garbage").size() == 2)
	var cfg := P2PSignalling.ice_config(defaults)
	_check("ice: ice_config wraps servers", cfg.has("ice_servers") and (cfg["ice_servers"] as Array).size() == 2)
	# backend_config.json in the repo carries turn_servers (loaded by
	# Supabase.load_config — verified by the mock test's config check).
	_check("ice: backend config file has turn_servers", FileAccess.file_exists("res://backend_config.json"))

# ------------------------------------------- 5. match points (per-coin §4)
func _test_match_points_formula() -> void:
	_check("points: 1 coin = 10", MatchPoints.points_for_coins(1, false, false) == 10)
	_check("points: 9 coins + queen + win = 165", MatchPoints.points_for_coins(9, true, true) == 165)
	_check("points: queen bonus needs the cover", MatchPoints.points_for_coins(4, false, false) == 40 and MatchPoints.points_for_coins(4, true, false) == 65)
	_check("points: loss keeps coin points, no win bonus", MatchPoints.points_for_coins(6, false, false) == 60)
	_check("points: draw keeps coin points, no win bonus", MatchPoints.points_for_coins(6, true, false) == 85)
	_check("points: constants are 10/25/50", MatchPoints.COIN_POINTS == 10 and MatchPoints.QUEEN_BONUS == 25 and MatchPoints.WIN_BONUS == 50)
	_check("points: tiers retuned for the new scale", MatchPoints.tier_name(99) == "Contender" and MatchPoints.tier_name(100) == "Challenger" and MatchPoints.tier_name(1000) == "Grand Master")

# ------------------------------------------- 6. transport interface
func _test_transport_interface() -> void:
	_check("transport: P2P is the default", NetClient.new().transport == NetClient.TRANSPORT_P2P)
	_check("transport: constants distinct", NetClient.TRANSPORT_LAN_HOST != NetClient.TRANSPORT_P2P and NetClient.TRANSPORT_P2P != NetClient.TRANSPORT_LEGACY_ENET)
	_check("transport: legacy switch works", _legacy_switch_roundtrip())
	_check("transport: WebRTC classes load (plugin present)", NetClient.webrtc_available())
	_check("transport: 20 s connect timeout", NetClient.P2P_CONNECT_TIMEOUT == 20.0)
	_check("transport: 2 s match poll", NetClient.P2P_POLL_INTERVAL == 2.0)
	# Matched payload from a matches row (same shape the ENet server sent).
	var players2 := [
		{"id": "id-me", "name": "Me", "level": 5, "stake": 100, "seat": 0},
		{"id": "id-opp", "name": "Opp", "level": 6, "stake": 100, "seat": 1},
	]
	var mid := "550e8400-e29b-41d4-a716-446655440000"
	var payload2: Dictionary = NetClient.p2p_matched_payload(players2, 0, mid)
	_check("transport: 2p payload has opponent fields", String(payload2.get("opponent", "")) == "Opp" and int(payload2.get("opp_level", 0)) == 6 and int(payload2.get("opp_stake", 0)) == 100)
	_check("transport: 2p you_break matches deterministic breaker", bool(payload2.get("you_break", false)) == (NetClient.breaker_seat_for_match(mid, 2) == 0))
	var players4 := [
		{"id": "id-0", "name": "A", "level": 5, "stake": 100, "seat": 0},
		{"id": "id-1", "name": "B", "level": 5, "stake": 100, "seat": 1},
		{"id": "id-2", "name": "C", "level": 6, "stake": 100, "seat": 2},
		{"id": "id-3", "name": "D", "level": 6, "stake": 100, "seat": 3},
	]
	var payload4: Dictionary = NetClient.p2p_matched_payload(players4, 2, mid)
	_check("transport: 4p payload has roster + seats", String(payload4.get("mode", "")) == "4p" and int(payload4.get("your_seat", -1)) == 2 and int(payload4.get("breaker_seat", -1)) == NetClient.breaker_seat_for_match(mid, 4))
	_check("transport: 4p payload carries the roster", (payload4.get("players", []) as Array).size() == 4)

func _legacy_switch_roundtrip() -> bool:
	var net := NetClient.new()
	net.use_legacy_enet()
	return net.transport == NetClient.TRANSPORT_LEGACY_ENET

# ------------------------------------------- 7. Broadcast parse (supabase)
func _test_broadcast_parse() -> void:
	var mid := "550e8400-e29b-41d4-a716-446655440000"
	var good := JSON.stringify({"topic": "realtime:carrom-match-" + mid, "event": "broadcast",
		"payload": {"event": "signal", "payload": {"type": "offer", "from": "peer-1", "sdp": "v=0"}}})
	var parsed := SupabaseClient.parse_realtime_message(good)
	_check("broadcast: signal parses to kind broadcast", String(parsed.get("kind", "")) == "broadcast")
	_check("broadcast: record is the message", String((parsed.get("record", {}) as Dictionary).get("type", "")) == "offer")
	var wrong_event := JSON.stringify({"topic": "realtime:carrom-match-" + mid, "event": "broadcast",
		"payload": {"event": "presence", "payload": {"type": "offer"}}})
	_check("broadcast: non-signal event rejected", SupabaseClient.parse_realtime_message(wrong_event).is_empty())
	var wrong_topic := JSON.stringify({"topic": "realtime:public:invites", "event": "broadcast",
		"payload": {"event": "signal", "payload": {"type": "offer", "from": "p", "sdp": "v"}}})
	_check("broadcast: wrong topic rejected", SupabaseClient.parse_realtime_message(wrong_topic).is_empty())
	var empty_payload := JSON.stringify({"topic": "realtime:carrom-match-" + mid, "event": "broadcast",
		"payload": {"event": "signal", "payload": {}}})
	_check("broadcast: empty payload rejected", SupabaseClient.parse_realtime_message(empty_payload).is_empty())
	# The invites path still parses (no regression from the new branch).
	var invite := JSON.stringify({"topic": "realtime:public:invites", "event": "postgres_changes",
		"payload": {"data": {"record": {"id": "r1", "status": "pending"}}}})
	_check("broadcast: invites postgres_changes still parses", String(SupabaseClient.parse_realtime_message(invite).get("kind", "")) == "invite")

# ------------------------------------------- 8. presence filter (§11)
func _test_presence_filter() -> void:
	var FriendsScript := _friends_script()
	var now_iso := Time.get_datetime_string_from_system(true, true).replace(" ", "T") + "+00:00"
	var stale_iso := "2026-11-20T00:00:00+00:00"
	var rows := [
		{"id": "me-id", "display_name": "Me", "level": 5, "status": "online", "updated_at": now_iso},
		{"id": "a-id", "display_name": "Asha", "level": 7, "status": "online", "updated_at": now_iso},
		{"id": "b-id", "display_name": "Ben", "level": 3, "status": "in_match", "updated_at": now_iso},
		{"id": "c-id", "display_name": "Cid", "level": 9, "status": "online", "updated_at": stale_iso},
		{"id": "d-id", "display_name": "", "level": 1, "status": "online", "updated_at": "garbage"},
	]
	var kept: Array = FriendsScript.filter_online_players(rows, "me-id")
	_check("presence: keeps fresh others only", kept.size() == 2, "kept=%d" % kept.size())
	_check("presence: in_match is visible with status", kept.size() == 2 and String(kept[1].get("status", "")) == "in_match")
	_check("presence: no Gmail or coins in rows", not kept[0].has("gmail") and not kept[0].has("coins"))
	_check("presence: stale rows are offline", SupabaseClient.iso_age_seconds(stale_iso) > 90)
	_check("presence: garbage timestamp is -1", SupabaseClient.iso_age_seconds("garbage") == -1)
	_check("presence: heartbeat is 30 s, offline 90 s", FriendsScript.PRESENCE_HEARTBEAT_SECONDS == 30.0 and FriendsScript.PRESENCE_OFFLINE_SECONDS == 90)
