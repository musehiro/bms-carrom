extends SceneTree

## v11 matchmaking + lobby + match-points tests (no network needed —
## UDP send is blocked in this sandbox, so the live two-client
## handshake cannot run here; the server is driven in-process exactly
## like tests/server_test.gd).
## Covers: two queued players get matched (real server queue logic),
## 4p queue grouping, lobby ready flow (2p + 4p), lobby leave/cancel,
## and match-points accumulation + tiers. The 4p MatchScreen setup
## contract (setup_4p BEFORE add_child) lives in
## tests/matchmaking_4p_test_node.gd + .tscn (scene run — see note in
## _initialize), because a -s script cannot compile MatchScreen.
## Run: godot --headless --path . -s tests/matchmaking_test.gd
## Exit 0 = all pass, 1 = any fail.

var _passed := 0
var _failed := 0

func _initialize() -> void:
	print("=== BMS Carrom v11 matchmaking tests ===")
	# ONE server instance for the whole run: its _ready binds UDP
	# port 8910, and a second bind would fail and quit the tree.
	var server := _server()
	_test_random_match_2p(server)
	_test_random_match_4p(server)
	_test_lobby_2p()
	_test_lobby_4p()
	_test_lobby_messages()
	_test_match_points()
	_test_match_points_tiers()
	# NOTE: the 4p MatchScreen setup contract lives in
	# tests/matchmaking_4p_test_node.gd (+ .tscn), NOT here: a -s
	# SceneTree script cannot compile MatchScreen (it names the Save
	# autoload, which -s mode does not resolve), while a scene run
	# can — same split as tests/multiplayer_fix_test_node.gd.
	print("=== %d passed, %d failed ===" % [_passed, _failed])
	quit(0 if _failed == 0 else 1)

func _check(name: String, cond: bool, detail: String = "") -> void:
	if cond:
		_passed += 1
		print("PASS: ", name)
	else:
		_failed += 1
		print("FAIL: ", name, (" — " + detail if detail != "" else ""))

func _server() -> Node:
	var script: GDScript = load("res://server/net_server.gd")
	var server: Node = script.new()
	server.name = "Net"
	root.add_child(server)
	return server

func _reset_server(server: Node) -> void:
	(server._queue as Array).clear()
	(server._rooms as Dictionary).clear()
	(server._peer_room as Dictionary).clear()
	(server._invite_rooms as Dictionary).clear()
	(server._peer_invite as Dictionary).clear()

func _room(server: Node) -> Dictionary:
	var rooms: Dictionary = server._rooms
	if rooms.is_empty():
		return {}
	return rooms.values()[0]

func _roster() -> Array:
	return [
		{"name": "Alice", "level": 5, "stake": 100, "seat": 0},
		{"name": "Bob", "level": 6, "stake": 100, "seat": 1},
		{"name": "Carol", "level": 5, "stake": 100, "seat": 2},
		{"name": "Dave", "level": 7, "stake": 100, "seat": 3},
	]

# --- random matchmaking: two queued players get matched ---------------
func _test_random_match_2p(server: Node) -> void:
	var now := Time.get_unix_time_from_system()
	# Two random players, same band, levels within ±2 -> one room.
	(server._queue as Array).append({"id": 11, "name": "Alice", "level": 5, "table": 0, "mode": "2p", "stake": 100, "at": now})
	(server._queue as Array).append({"id": 22, "name": "Bob", "level": 6, "table": 0, "mode": "2p", "stake": 150, "at": now})
	server._try_match()
	_check("random 2p: two queued players get matched", (server._rooms as Dictionary).size() == 1)
	_check("random 2p: room holds both players", (_room(server).get("players", []) as Array) == [11, 22])
	_check("random 2p: queue drained after match", (server._queue as Array).is_empty())
	# A third player queuing alone stays queued (no phantom match).
	(server._queue as Array).append({"id": 33, "name": "Carol", "level": 5, "table": 0, "mode": "2p", "stake": 0, "at": now})
	server._try_match()
	_check("random 2p: lone queuer waits, no room", (server._rooms as Dictionary).size() == 1 and (server._queue as Array).size() == 1)
	# leave_queue removes the waiter (cancelled search is never matched).
	server._remove_from_queue(33)
	_check("random 2p: cancelled search leaves the queue", (server._queue as Array).is_empty())
	# Levels 9 apart never match, even after the 30 s widening.
	_reset_server(server)
	(server._queue as Array).append({"id": 41, "name": "A", "level": 1, "table": 0, "mode": "2p", "stake": 0, "at": now - 40.0})
	(server._queue as Array).append({"id": 42, "name": "B", "level": 10, "table": 0, "mode": "2p", "stake": 0, "at": now - 40.0})
	server._try_match()
	_check("random 2p: 9 levels apart do not match after widening", (server._rooms as Dictionary).is_empty())

func _test_random_match_4p(server: Node) -> void:
	var now := Time.get_unix_time_from_system()
	for k in range(4):
		(server._queue as Array).append({"id": 51 + k, "name": "P%d" % k, "level": 5 + k, "table": 1, "mode": "4p", "stake": 100, "at": now})
	server._try_match()
	_check("random 4p: four queued players form one room", (server._rooms as Dictionary).size() == 1 and (_room(server).get("players", []) as Array).size() == 4)
	_check("random 4p: room mode is 4p", String(_room(server).get("mode", "")) == "4p")
	# A 2p player on the same band never joins the 4p group.
	_reset_server(server)
	(server._queue as Array).append({"id": 61, "name": "Solo", "level": 5, "table": 1, "mode": "2p", "stake": 0, "at": now})
	for k in range(4):
		(server._queue as Array).append({"id": 71 + k, "name": "R%d" % k, "level": 5, "table": 1, "mode": "4p", "stake": 50, "at": now})
	server._try_match()
	_check("random 4p: 2p player stays queued while 4p group matches", (server._queue as Array).size() == 1 and int((server._queue as Array)[0]["id"]) == 61)

# --- lobby: 2p ready flow ----------------------------------------------
func _test_lobby_2p() -> void:
	var lobby: OnlineLobby = OnlineLobby.from_matched(
		{"opponent": "Bob", "opp_level": 6, "you_break": true, "opp_stake": 150},
		"Alice", 5, 100)
	_check("lobby 2p: two players expected", lobby.expected == 2 and lobby.players.size() == 2)
	_check("lobby 2p: local seat is 0 when we break", lobby.your_seat == 0 and lobby.breaker_seat == 0)
	_check("lobby 2p: opponent is seat 1, not ready", int(lobby.players[1]["seat"]) == 1 and not bool(lobby.players[1]["ready"]))
	_check("lobby 2p: not all ready at open", not lobby.all_ready() and lobby.state == OnlineLobby.STATE_WAITING)
	_check("lobby 2p: status shows 0/2 ready", lobby.status_text() == "Waiting for players… 0/2 ready")
	lobby.mark_ready(0)
	_check("lobby 2p: one ready is not all ready", not lobby.all_ready() and lobby.ready_count() == 1)
	lobby.mark_ready(1)
	_check("lobby 2p: both ready -> all ready, state ready", lobby.all_ready() and lobby.state == OnlineLobby.STATE_READY)
	_check("lobby 2p: begin_start succeeds when all ready", lobby.begin_start() and lobby.state == OnlineLobby.STATE_STARTING)
	_check("lobby 2p: unknown seat ready is ignored", not lobby.mark_ready(7))
	# Leaving before the start cancels the lobby.
	var lobby2: OnlineLobby = OnlineLobby.from_matched(
		{"opponent": "Bob", "opp_level": 6, "you_break": false, "opp_stake": 0},
		"Alice", 5, 0)
	_check("lobby 2p: local seat is 1 when opponent breaks", lobby2.your_seat == 1)
	_check("lobby 2p: leave cancels the lobby", lobby2.player_left(0) and lobby2.state == OnlineLobby.STATE_CANCELLED)
	_check("lobby 2p: cancelled lobby cannot start", not lobby2.can_start() and not lobby2.begin_start())

# --- lobby: 4p ready flow ----------------------------------------------
func _test_lobby_4p() -> void:
	var data := {"mode": "4p", "players": _roster(), "your_seat": 1, "breaker_seat": 2}
	var lobby: OnlineLobby = OnlineLobby.from_matched(data, "Bob", 6, 100)
	_check("lobby 4p: four players expected", lobby.expected == 4 and lobby.players.size() == 4)
	_check("lobby 4p: local seat + breaker seat kept", lobby.your_seat == 1 and lobby.breaker_seat == 2)
	_check("lobby 4p: local player flagged", bool(lobby.players[1]["is_local"]) and not bool(lobby.players[0]["is_local"]))
	for seat in [0, 1, 2]:
		lobby.mark_ready(seat)
	_check("lobby 4p: 3/4 ready is not all ready", not lobby.all_ready() and lobby.ready_count() == 3)
	lobby.mark_ready(3)
	_check("lobby 4p: 4/4 ready -> all ready", lobby.all_ready())
	_check("lobby 4p: teams are seats 0,2 vs 1,3", "Team A" in OnlineLobby.row_text(lobby.players[0], true) and "Team B" in OnlineLobby.row_text(lobby.players[1], true) and "Team A" in OnlineLobby.row_text(lobby.players[2], true))
	_check("lobby 4p: local row is marked YOU", "(YOU)" in OnlineLobby.row_text(lobby.players[1], true))

# --- lobby: wire messages ------------------------------------------------
func _test_lobby_messages() -> void:
	var msg: Dictionary = OnlineLobby.ready_message(2)
	_check("lobby msg: ready message shape", String(msg.get("type", "")) == "lobby_ready" and int(msg.get("seat", -1)) == 2)
	_check("lobby msg: ready seat parses back", OnlineLobby.ready_seat(msg) == 2)
	_check("lobby msg: wrong type rejected", OnlineLobby.ready_seat({"type": "shot", "seat": 1}) == -1)
	_check("lobby msg: missing seat rejected", OnlineLobby.ready_seat({"type": "lobby_ready"}) == -1)
	_check("lobby msg: seat 9 rejected", OnlineLobby.ready_seat({"type": "lobby_ready", "seat": 9}) == -1)
	_check("lobby msg: auto-start is 30s", OnlineLobby.LOBBY_AUTO_START_SECONDS == 30.0)

# --- match points --------------------------------------------------------
# v11 plan §4 (per-coin formula, replaces the flat win+3/draw+1/loss+0):
# 10 pts per own coin, +25 covered queen, +50 win bonus.
func _test_match_points() -> void:
	_check("points: 0 coins, loss is +0", MatchPoints.points_for_coins(0, false, false) == 0)
	_check("points: 5 coins, loss is +50", MatchPoints.points_for_coins(5, false, false) == 50)
	_check("points: 9 coins + covered queen + win is +165", MatchPoints.points_for_coins(9, true, true) == 165)
	_check("points: queen bonus only when covered", MatchPoints.points_for_coins(3, false, false) == 30 and MatchPoints.points_for_coins(3, true, false) == 55)
	_check("points: win bonus is +50", MatchPoints.points_for_coins(0, false, true) == 50)
	_check("points: negative coins clamp to 0", MatchPoints.points_for_coins(-2, false, false) == 0)
	_check("points: legacy outcome win is the win bonus", MatchPoints.points_for("win") == MatchPoints.WIN_BONUS)
	_check("points: legacy outcome draw/loss is +0", MatchPoints.points_for("draw") == 0 and MatchPoints.points_for("loss") == 0 and MatchPoints.points_for("bogus") == 0)
	_check("points: outcome_for win/draw/loss", MatchPoints.outcome_for(true, false) == "win" and MatchPoints.outcome_for(false, true) == "draw" and MatchPoints.outcome_for(false, false) == "loss")
	# Accumulation: 50 (5 coins, loss) + 165 (9 + queen + win) + 30 (3 coins, draw) = 245.
	var total := 0
	total = MatchPoints.apply(total, MatchPoints.points_for_coins(5, false, false))
	total = MatchPoints.apply(total, MatchPoints.points_for_coins(9, true, true))
	total = MatchPoints.apply(total, MatchPoints.points_for_coins(3, false, false))
	_check("points: per-coin matches accumulate to 245", total == 245, "total=%d" % total)
	_check("points: result line shows earned + total + tier", MatchPoints.result_line(115, 340) == "Match points: +115  •  Total 340 (Champion)")
	_check("points: live line shows coins + queen pending", MatchPoints.live_line(7, false, true) == "Points: 70  •  Cover the queen for +25")
	_check("points: live line shows covered queen bonus", MatchPoints.live_line(7, true, false) == "Points: 95")

func _test_match_points_tiers() -> void:
	_check("points tier: 0 is Contender", MatchPoints.tier_name(0) == "Contender")
	_check("points tier: 99 is Contender", MatchPoints.tier_name(99) == "Contender")
	_check("points tier: 100 is Challenger", MatchPoints.tier_name(100) == "Challenger")
	_check("points tier: 250 is Champion", MatchPoints.tier_name(250) == "Champion")
	_check("points tier: 500 is Master", MatchPoints.tier_name(500) == "Master")
	_check("points tier: 1000 is Grand Master", MatchPoints.tier_name(1000) == "Grand Master")
	_check("points tier: 2500 stays Grand Master", MatchPoints.tier_name(2500) == "Grand Master")

