extends SceneTree

## v11 invites + Play-menu tests (standalone, no backend, no UI tree).
## Run: godot --headless --path . -s tests/invites_ui_test.gd
## Prints PASS/FAIL per test and exits 0 (all pass) or 1 (any fail).
##
## Covers, pure (no Supabase, no server):
##   * invite group lifecycle — send/accept/ready/join inputs for 2p
##     and 4p (group_state, group_players), decline + expiry paths
##     (L11: expired/cancelled fail a group like declined).
##   * invite expiry math — invite_age_seconds / is_expired (24 h).
##   * invite row + join-room message shapes (2p invitee, 4p inviter).
##   * the PLAY menu — exactly THREE big buttons, each routing to the
##     right choice (bot / 2 players auto-connect / 4 players
##     auto-connect), plus the secondary World Tour / NEARBY buttons
##     and BACK.
## The live backend half (send -> accept -> group_ready signal,
## decline/expiry/cancel against the mock) lives in
## tests/invites_flow_test_node.gd + tests/invites_flow_test.tscn.

var _passed := 0
var _failed := 0
var _failures: Array = []
var _seen: Array = []

func _initialize() -> void:
	print("=== BMS Carrom invites + Play-menu tests ===")
	_test_group_state_2p()
	_test_group_state_4p()
	_test_group_state_failed_paths()
	_test_group_players()
	_test_invite_expiry()
	_test_invite_row()
	_test_invite_join_message()
	_test_play_menu_buttons()
	_test_play_menu_routing()
	print("=== %d passed, %d failed ===" % [_passed, _failed])
	for f in _failures:
		print("FAIL: ", f)
	quit(0 if _failed == 0 else 1)

func _check(test_name: String, cond: bool, detail: String = "") -> void:
	if cond:
		_passed += 1
		print("PASS: ", test_name)
	else:
		_failed += 1
		_failures.append(test_name + (" — " + detail if detail != "" else ""))
		print("FAIL: ", test_name, (" — " + detail if detail != "" else ""))

func _friends_script() -> GDScript:
	return load("res://scripts/friends.gd")

# ------------------------------------------------------- group lifecycle

func _test_group_state_2p() -> void:
	var F: GDScript = _friends_script()
	_check("invites 2p: one pending is waiting",
		F.group_state([{"status": "pending"}]) == "waiting")
	_check("invites 2p: accepted is ready",
		F.group_state([{"status": "accepted"}]) == "ready")
	_check("invites 2p: empty group is unknown",
		F.group_state([]) == "unknown")

func _test_group_state_4p() -> void:
	var F: GDScript = _friends_script()
	_check("invites 4p: three pending is waiting",
		F.group_state([{"status": "pending"}, {"status": "pending"}, {"status": "pending"}]) == "waiting")
	_check("invites 4p: two accepted + one pending is waiting",
		F.group_state([{"status": "accepted"}, {"status": "accepted"}, {"status": "pending"}]) == "waiting")
	_check("invites 4p: all three accepted is ready",
		F.group_state([{"status": "accepted"}, {"status": "accepted"}, {"status": "accepted"}]) == "ready")

func _test_group_state_failed_paths() -> void:
	var F: GDScript = _friends_script()
	# Decline (either size).
	_check("invites: decline fails a 2p group",
		F.group_state([{"status": "declined"}]) == "failed")
	_check("invites: decline fails a 4p group",
		F.group_state([{"status": "accepted"}, {"status": "accepted"}, {"status": "declined"}]) == "failed")
	# Expiry (L11): an invitee who let the invite lapse fails the group
	# instead of leaving the inviter waiting forever.
	_check("invites: expired fails a 2p group",
		F.group_state([{"status": "expired"}]) == "failed")
	_check("invites: expired fails a 4p group",
		F.group_state([{"status": "accepted"}, {"status": "accepted"}, {"status": "expired"}]) == "failed")
	# Cancel (L1 rollback / v11 cancel_invite): same as declined.
	_check("invites: cancelled fails a 2p group",
		F.group_state([{"status": "cancelled"}]) == "failed")
	_check("invites: cancelled fails a 4p group",
		F.group_state([{"status": "accepted"}, {"status": "cancelled"}, {"status": "pending"}]) == "failed")
	# A dead row anywhere fails the group even if others accepted.
	_check("invites: one dead row fails the group even when the rest accepted",
		F.group_state([{"status": "accepted"}, {"status": "declined"}]) == "failed")

func _test_group_players() -> void:
	var F: GDScript = _friends_script()
	var p2: Array = F.group_players(
		[{"to_id": "u-nimal", "to_name": "Nimal"}], "u-me", "Me")
	_check("invites 2p: group players are inviter first, then the invitee",
		p2.size() == 2 and String(p2[0].get("id", "")) == "u-me"
		and String(p2[1].get("id", "")) == "u-nimal"
		and String(p2[1].get("name", "")) == "Nimal", str(p2))
	var p4: Array = F.group_players([
		{"to_id": "u-a", "to_name": "A"},
		{"to_id": "u-b", "to_name": "B"},
		{"to_id": "u-c", "to_name": "C"},
	], "u-me", "Me")
	_check("invites 4p: group players are inviter + 3 invitees in invite order",
		p4.size() == 4 and String(p4[0].get("id", "")) == "u-me"
		and String(p4[3].get("id", "")) == "u-c", str(p4))

# ------------------------------------------------------------- expiry math

func _iso_ago(seconds: int) -> String:
	# Supabase format: "2026-11-22T13:00:00+00:00".
	var now := int(Time.get_unix_time_from_system()) - seconds
	return Time.get_datetime_string_from_unix_time(now, true).replace(" ", "T") + "+00:00"

func _test_invite_expiry() -> void:
	var F: GDScript = _friends_script()
	var fresh := {"created_at": _iso_ago(60)}
	var day_old := {"created_at": _iso_ago(23 * 3600)}
	var stale := {"created_at": _iso_ago(25 * 3600)}
	_check("invites expiry: fresh invite is not expired", not F.is_expired(fresh))
	_check("invites expiry: 23 h old invite is not expired yet", not F.is_expired(day_old))
	_check("invites expiry: 25 h old invite is expired", F.is_expired(stale))
	_check("invites expiry: age of a 25 h old invite is ~90000 s",
		F.invite_age_seconds(stale) > 89000 and F.invite_age_seconds(stale) < 91000,
		str(F.invite_age_seconds(stale)))
	_check("invites expiry: missing timestamp never counts as expired",
		F.invite_age_seconds({}) == -1 and not F.is_expired({}))
	_check("invites expiry: garbage timestamp never counts as expired",
		not F.is_expired({"created_at": "not a date"}))
	_check("invites expiry: 24 h constant is one day",
		F.INVITE_EXPIRY_SECONDS == 24 * 3600)

# ------------------------------------------------------------ row + join msg

func _test_invite_row() -> void:
	var row2 := SupabaseClient.invite_row("grp-1", "u-me", "u-nimal", "Me", "Nimal", "2p", 100)
	_check("invites row: 2p invite is pending with the stake + names",
		String(row2.get("status", "")) == "pending" and String(row2.get("mode", "")) == "2p"
		and int(row2.get("stake", 0)) == 100
		and String(row2.get("from_name", "")) == "Me"
		and String(row2.get("to_name", "")) == "Nimal")
	var row4 := SupabaseClient.invite_row("grp-2", "u-me", "u-saman", "Me", "Saman", "4p", 200)
	_check("invites row: 4p invite carries mode 4p + the shared group id",
		String(row4.get("mode", "")) == "4p" and String(row4.get("group_id", "")) == "grp-2"
		and int(row4.get("stake", 0)) == 200)

func _test_invite_join_message() -> void:
	# What Main sends to the game server after accept + stake (invitee)
	# and after group_ready (inviter): the join-room step of the flow.
	var join2 := NetClient.invite_join_message("grp-1", "Nimal", 5, 100, "2p", 1, false)
	_check("invites join: 2p invitee message has the group, mode, stake, invitee flag",
		String(join2.get("group_id", "")) == "grp-1" and String(join2.get("mode", "")) == "2p"
		and int(join2.get("stake", 0)) == 100 and not bool(join2.get("is_inviter", true)))
	var join4 := NetClient.invite_join_message("grp-2", "Me", 5, 200, "4p", 1, true)
	_check("invites join: 4p inviter message has the group, 4p mode, inviter flag",
		String(join4.get("group_id", "")) == "grp-2" and String(join4.get("mode", "")) == "4p"
		and int(join4.get("stake", 0)) == 200 and bool(join4.get("is_inviter", false)))

# ------------------------------------------------------------- Play menu

func _make_menu() -> Control:
	# Load by path (not by class_name): the global class cache may not
	# know the new file yet on a fresh checkout.
	var PlayMenuScript: GDScript = load("res://scripts/play_menu.gd")
	var scr = PlayMenuScript.new()
	scr._ready() # same code the live screen runs (test_runner precedent)
	return scr

func _collect_label_texts(node: Node, out: Array) -> void:
	for n in node.get_children():
		if n is Label:
			out.append((n as Label).text)
		if n is Button:
			out.append((n as Button).text)
		_collect_label_texts(n, out)

func _test_play_menu_buttons() -> void:
	var scr := _make_menu()
	var big: Array = []
	for bname in ["BotButton", "TwoPlayersButton", "FourPlayersButton"]:
		var b := scr.find_child(bname, true, false) as Button
		if b != null:
			big.append(b)
	_check("play menu: exactly the three big buttons exist (bot / 2 players / 4 players)",
		big.size() == 3, "found=%d" % big.size())
	var all_big := true
	var all_3d := true
	for b in big:
		if (b as Button).custom_minimum_size.y < 100.0:
			all_big = false
		if not (b is ThreeDButton):
			all_3d = false
	_check("play menu: all three buttons are big (>= 100 px tall)", all_big)
	_check("play menu: all three buttons are chunky-3D (ThreeDButton)", all_3d)
	var texts: Array = []
	_collect_label_texts(scr, texts)
	var joined := " ".join(texts)
	_check("play menu: bot button says BOT", joined.contains("BOT"))
	_check("play menu: 2-players button says 1 VS 1", joined.contains("1 VS 1"))
	_check("play menu: 4-players button says DOUBLES", joined.contains("DOUBLES"))
	_check("play menu: auto-connect buttons say Auto-connect", joined.contains("Auto-connect"))
	_check("play menu: no WORLD / FRIENDS buttons any more", not joined.contains("PLAY WITH THE WORLD") and not joined.contains("PLAY WITH FRIENDS"))
	_check("play menu: SEARCH FRIEND still reachable (separate entry)", joined.contains("SEARCH FRIEND"))
	_check("play menu: World Tour still reachable (secondary)", joined.contains("WORLD TOUR"))
	_check("play menu: NEARBY still reachable (secondary)", joined.contains("NEARBY"))
	scr.free()

func _test_play_menu_routing() -> void:
	# Each button press must emit exactly its own signal — and no other.
	var scr := _make_menu()
	scr.bot_chosen.connect(func() -> void: _seen.append("bot"))
	scr.two_players_chosen.connect(func() -> void: _seen.append("two_players"))
	scr.four_players_chosen.connect(func() -> void: _seen.append("four_players"))
	scr.tour_chosen.connect(func() -> void: _seen.append("tour"))
	scr.nearby_chosen.connect(func() -> void: _seen.append("nearby"))
	scr.search_friend_chosen.connect(func() -> void: _seen.append("search_friend"))
	scr.go_back.connect(func() -> void: _seen.append("back"))
	_seen.clear()
	(scr.find_child("BotButton", true, false) as Button).pressed.emit()
	_check("play menu routing: BOT button routes to bot (solo vs AI)",
		_seen == ["bot"], str(_seen))
	_seen.clear()
	(scr.find_child("TwoPlayersButton", true, false) as Button).pressed.emit()
	_check("play menu routing: 2 PLAYERS button routes to two_players (auto-connect 1 vs 1)",
		_seen == ["two_players"], str(_seen))
	_seen.clear()
	(scr.find_child("FourPlayersButton", true, false) as Button).pressed.emit()
	_check("play menu routing: 4 PLAYERS button routes to four_players (auto-connect doubles)",
		_seen == ["four_players"], str(_seen))
	_seen.clear()
	(scr.find_child("TourButton", true, false) as Button).pressed.emit()
	_check("play menu routing: WORLD TOUR button still routes to tour",
		_seen == ["tour"], str(_seen))
	_seen.clear()
	(scr.find_child("NearbyButton", true, false) as Button).pressed.emit()
	_check("play menu routing: NEARBY button still routes to nearby",
		_seen == ["nearby"], str(_seen))
	_seen.clear()
	(scr.find_child("SearchFriendButton", true, false) as Button).pressed.emit()
	_check("play menu routing: SEARCH FRIEND button routes to search_friend (name-search / invite flow)",
		_seen == ["search_friend"], str(_seen))
	_seen.clear()
	(scr.find_child("BackButton", true, false) as Button).pressed.emit()
	_check("play menu routing: BACK routes home", _seen == ["back"], str(_seen))
	scr.free()
