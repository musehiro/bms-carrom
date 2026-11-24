extends Node

## v11 invite-flow test (live, against tests/mock_supabase.py): drives
## the REAL Friends autoload end to end, no real Supabase, no real
## game server — the mock stands in for Supabase (PostgREST + Realtime).
##   * 2p: send -> invitee accepts -> group_ready fires (inviter side)
##     with the stake/mode Main needs to join the server room.
##   * 4p: send to 3 -> all three accept -> group_ready (3 invites).
##   * Decline: send -> invitee declines -> group_failed fires.
##   * Expiry (L11): send -> backdate the row past 24 h -> poll marks
##     it "expired" on the server and the group fails.
##   * Cancel (v11): send -> inviter cancels -> row is "cancelled" on
##     the server, outgoing clears, no group_ready ever fires.
##   * L2 restore: sent invites survive a simulated restart (outgoing
##     + groups rebuilt by refresh()).
##   * Home invite box: the "WAITING FOR…" list groups by group_id,
##     shows ✓ accepted / • waiting per person, and CANCEL abandons
##     the group; incoming invites render with ACCEPT / DECLINE.
##   * Realtime cancel: a cancelled record for me drops the invite
##     from my inbox live (new _on_realtime_invite branch).
## The last step — joining the game server's invite room — needs a
## live server; the payload Main sends is covered by
## tests/invites_ui_test.gd ("invites join: …"), and the server-side
## invite room is covered by tests/server_test.gd.
## Run headless: godot --headless --path . res://tests/invites_flow_test.tscn
## Exit 0 = all pass, 1 = any fail.

const MOCK_PORT := 18081
const MOCK_URL := "http://127.0.0.1:18081"
const SAVE_PATH := "user://bms_carrom_save.cfg"

var _passed := 0
var _failed := 0
var _failures: Array = []
var _done := false
var _wait := 0.0
var _mock_pid := -1
var _saved_cfg := ""
var _had_save := false
var _signal_seen := false
var _ready_group_id := ""
var _ready_invites: Array = []
var _failed_group_id := ""
var _failed_reason := ""

func _ready() -> void:
	Friends.group_ready.connect(_on_group_ready)
	Friends.group_failed.connect(_on_group_failed)
	_run()

func _process(delta: float) -> void:
	if _done:
		return
	_wait += delta
	if _wait > 120.0:
		_fail("invites flow test timed out")
		_finish()

func _on_group_ready(group_id: String, invites: Array) -> void:
	_ready_group_id = group_id
	_ready_invites = invites

func _on_group_failed(group_id: String, reason: String) -> void:
	_failed_group_id = group_id
	_failed_reason = reason

func _check(test_name: String, cond: bool, detail: String = "") -> void:
	if cond:
		_passed += 1
		print("PASS: ", test_name)
	else:
		_failed += 1
		_failures.append(test_name + (" — " + detail if detail != "" else ""))
		print("FAIL: ", test_name, (" — " + detail if detail != "" else ""))

func _fail(test_name: String) -> void:
	_failed += 1
	_failures.append(test_name)
	print("FAIL: ", test_name)

func _frames(n: int) -> void:
	for i in range(n):
		await get_tree().process_frame

func _iso_now() -> String:
	return Time.get_datetime_string_from_unix_time(int(Time.get_unix_time_from_system()), true).replace(" ", "T") + "+00:00"

func _run() -> void:
	print("=== BMS Carrom invites flow tests ===")
	# Back up the real save file; reset to a known test profile.
	_had_save = FileAccess.file_exists(SAVE_PATH)
	if _had_save:
		_saved_cfg = FileAccess.get_file_as_string(SAVE_PATH)
	Save.coins = 10000
	Save.xp = 0
	Save.account_gmail = "test.player@gmail.com"
	Save.account_id = "user-me"
	Save.account_verified = true
	Save.player_name = "Test Player"
	Save.save()
	# Start the mock.
	var script_path := ProjectSettings.globalize_path("res://tests/mock_supabase.py")
	_mock_pid = OS.create_process("python3", [script_path, "--port", str(MOCK_PORT)])
	if _mock_pid <= 0:
		_fail("could not start the mock Supabase server")
		_finish()
		return
	if not await _wait_for_health():
		_fail("mock Supabase server did not answer /health")
		_finish()
		return
	Supabase.set_config(MOCK_URL, "test-anon-key", "")
	Supabase.access_token = ""
	Supabase.user_id = ""
	# Seed the friend profiles (search is not under test here, but the
	# rows must exist for the invite targets to be real players).
	for p in [
		["user-nimal", "nimal@gmail.com", "Nimal Perera"],
		["user-saman", "saman@gmail.com", "Saman"],
		["user-kasun", "kasun@gmail.com", "Kasun"],
	]:
		var row := SupabaseClient.profile_row(String(p[0]), String(p[1]), String(p[2]), 1500, 1200, 10, 6, 3, 2, ["classic"], ["classic"], "classic", "classic")
		await Supabase.upsert_profile(row)
	Friends.start_listening()
	var connected := await _wait_for_signal(Supabase.realtime_connected, 5.0)
	_check("flow: Realtime channel joined", connected)

	# --- 2p: send -> accept -> group_ready ---
	_ready_group_id = ""
	var sent2 := await Friends.send_invite("user-nimal", "Nimal Perera", 100)
	_check("flow 2p: invite sent", bool(sent2.get("ok", false)) and String(sent2.get("group_id", "")) != "")
	var gid2: String = sent2.get("group_id", "")
	var grp2 := await Supabase.list_group_invites(gid2)
	var rows2: Array = grp2.get("data", [])
	_check("flow 2p: group has the one pending invite", rows2.size() == 1)
	# The invitee accepts (another player would do this from their phone).
	var acc2 := await Supabase.update_invite(String(rows2[0].get("id", "")), "accepted")
	_check("flow 2p: invitee accept lands", bool(acc2.get("ok", false)))
	var ready2 := await _wait_for_condition(func() -> bool: return _ready_group_id == gid2, 15.0)
	_check("flow 2p: group_ready fires for the inviter", ready2, "ready_group=%s" % _ready_group_id)
	_check("flow 2p: ready group carries the stake + mode Main joins with",
		_ready_invites.size() == 1 and int(_ready_invites[0].get("stake", 0)) == 100
		and String(_ready_invites[0].get("mode", "")) == "2p", str(_ready_invites))

	# --- 4p: send to 3 -> all accept -> group_ready ---
	_ready_group_id = ""
	var targets := [
		{"id": "user-nimal", "name": "Nimal Perera"},
		{"id": "user-saman", "name": "Saman"},
		{"id": "user-kasun", "name": "Kasun"},
	]
	var sent4 := await Friends.send_group_invite(targets, 200)
	_check("flow 4p: invite sent to 3 friends", bool(sent4.get("ok", false)))
	var gid4: String = sent4.get("group_id", "")
	var grp4 := await Supabase.list_group_invites(gid4)
	var rows4: Array = grp4.get("data", [])
	_check("flow 4p: group has 3 rows, waiting", rows4.size() == 3 and Friends.group_state(rows4) == "waiting")
	for r in rows4:
		await Supabase.update_invite(String(r.get("id", "")), "accepted")
	var ready4 := await _wait_for_condition(func() -> bool: return _ready_group_id == gid4, 15.0)
	_check("flow 4p: group_ready fires when all three accept", ready4, "ready_group=%s" % _ready_group_id)
	_check("flow 4p: ready group has all 3 invites, mode 4p, stake 200",
		_ready_invites.size() == 3 and String(_ready_invites[0].get("mode", "")) == "4p"
		and int(_ready_invites[0].get("stake", 0)) == 200, str(_ready_invites))
	_check("flow 4p: group players are inviter + 3 invitees",
		Friends.group_players(_ready_invites, Save.account_id, Save.player_name).size() == 4)

	# --- Decline: send -> invitee declines -> group_failed ---
	_failed_group_id = ""
	var sent_d := await Friends.send_invite("user-nimal", "Nimal Perera", 50)
	_check("flow decline: invite sent", bool(sent_d.get("ok", false)))
	var gid_d: String = sent_d.get("group_id", "")
	var grp_d := await Supabase.list_group_invites(gid_d)
	var rows_d: Array = grp_d.get("data", [])
	await Supabase.update_invite(String(rows_d[0].get("id", "")), "declined")
	var failed_d := await _wait_for_condition(func() -> bool: return _failed_group_id == gid_d, 15.0)
	_check("flow decline: group_failed fires for the inviter", failed_d, "failed_group=%s" % _failed_group_id)
	_check("flow decline: failure reason mentions decline/expiry", _failed_reason != "", _failed_reason)

	# --- Expiry (L11): send -> backdate past 24 h -> poll expires it ---
	_failed_group_id = ""
	var sent_e := await Friends.send_invite("user-saman", "Saman", 50)
	_check("flow expiry: invite sent", bool(sent_e.get("ok", false)))
	var gid_e: String = sent_e.get("group_id", "")
	var grp_e := await Supabase.list_group_invites(gid_e)
	var rows_e: Array = grp_e.get("data", [])
	var row_e_id := String(rows_e[0].get("id", ""))
	var backdated := await _patch_created_at(row_e_id, "2020-01-01T00:00:00+00:00")
	_check("flow expiry: row backdated past 24 h", backdated)
	_check("flow expiry: backdated row counts as expired",
		Friends.is_expired({"created_at": "2020-01-01T00:00:00+00:00"}))
	Friends._poll_group(gid_e)
	var failed_e := await _wait_for_condition(func() -> bool: return _failed_group_id == gid_e, 15.0)
	_check("flow expiry: group_failed fires once the invite lapses", failed_e, "failed_group=%s" % _failed_group_id)
	var grp_e2 := await Supabase.list_group_invites(gid_e)
	_check("flow expiry: row is marked expired on the server",
		String((grp_e2.get("data", []) as Array)[0].get("status", "")) == "expired")

	# --- Cancel (v11): send -> inviter cancels -> row cancelled, no ready ---
	_ready_group_id = ""
	var sent_c := await Friends.send_invite("user-kasun", "Kasun", 50)
	_check("flow cancel: invite sent", bool(sent_c.get("ok", false)))
	var gid_c: String = sent_c.get("group_id", "")
	var grp_c := await Supabase.list_group_invites(gid_c)
	var rows_c: Array = grp_c.get("data", [])
	var cancel := await Friends.cancel_invite(rows_c[0])
	_check("flow cancel: cancel_invite succeeds", bool(cancel.get("ok", false)), String(cancel.get("error", "")))
	var grp_c2 := await Supabase.list_group_invites(gid_c)
	_check("flow cancel: row is cancelled on the server",
		String((grp_c2.get("data", []) as Array)[0].get("status", "")) == "cancelled")
	var still_tracked := false
	for inv in Friends.outgoing:
		if String(inv.get("group_id", "")) == gid_c:
			still_tracked = true
	_check("flow cancel: group no longer tracked locally", not still_tracked and not Friends.groups.has(gid_c))
	await _frames(30)
	_check("flow cancel: no group_ready fires for a cancelled group", _ready_group_id != gid_c)

	# --- L2 restore: sent invites survive a simulated restart ---
	var sent_r2 := await Friends.send_invite("user-nimal", "Nimal Perera", 100)
	var gid_r2: String = sent_r2.get("group_id", "")
	var sent_r4 := await Friends.send_group_invite(targets, 200)
	var gid_r4: String = sent_r4.get("group_id", "")
	_check("flow L2: invites sent before the restart", bool(sent_r2.get("ok", false)) and bool(sent_r4.get("ok", false)))
	# Simulate the restart: drop the in-memory tracking, then refresh.
	Friends.outgoing.clear()
	Friends.groups.clear()
	var refreshed := await Friends.refresh()
	_check("flow L2: refresh succeeds", bool(refreshed.get("ok", false)))
	var restored_ids := {}
	for inv in Friends.outgoing:
		restored_ids[String(inv.get("group_id", ""))] = true
	_check("flow L2: both groups restored after refresh",
		restored_ids.has(gid_r2) and restored_ids.has(gid_r4) and Friends.groups.has(gid_r2) and Friends.groups.has(gid_r4),
		"outgoing=%d groups=%s" % [Friends.outgoing.size(), str(Friends.groups.keys())])
	_check("flow L2: restored outgoing has all 4 rows", Friends.outgoing.size() == 4, "outgoing=%d" % Friends.outgoing.size())
	# v11 consumed groups: the two groups that already fired
	# group_ready (gid2, gid4) must NOT come back — their rows stay
	# "accepted" on the server forever, and re-tracking them would
	# re-fire group_ready for a dead room on every launch.
	_check("flow L2: already-ready groups are NOT restored",
		not restored_ids.has(gid2) and not restored_ids.has(gid4),
		"restored=%s" % str(restored_ids.keys()))
	_ready_group_id = ""
	await get_tree().create_timer(12.0).timeout # one full 10 s poll cycle
	_check("flow L2: no group_ready re-fires for consumed groups after a poll",
		_ready_group_id == "", "ready_group=%s" % _ready_group_id)

	# One invitee accepts part-way: the box must show the ✓ mark.
	var grp_r4 := await Supabase.list_group_invites(gid_r4)
	var rows_r4: Array = grp_r4.get("data", [])
	await Supabase.update_invite(String(rows_r4[0].get("id", "")), "accepted")
	Friends._poll_group(gid_r4)
	await _frames(10)

	# --- Home invite box (WAITING FOR… + incoming) ---
	Friends.incoming = [
		{"id": "inv-incoming", "group_id": "grp-inc", "from_id": "user-nimal", "to_id": "user-me",
			"from_name": "Nimal", "to_name": "Test Player", "mode": "2p", "stake": 50,
			"status": "pending", "created_at": _iso_now()},
	]
	var home := HomeScreen.new()
	add_child(home)
	await _frames(5)
	home.open_invite_box()
	await _frames(5)
	var texts: Array = []
	_collect_label_texts(home, texts)
	var joined := " ".join(texts)
	_check("flow box: WAITING FOR… list is shown", joined.contains("WAITING FOR"))
	_check("flow box: sent 2p invitee is listed", joined.contains("Nimal Perera"))
	_check("flow box: accepted invitee shows the ✓ mark", joined.contains("✓"))
	_check("flow box: pending invitees show the • mark", joined.contains("•"))
	_check("flow box: incoming invite renders the inviter", joined.contains("Nimal invited you"))
	var cancel_btn := _find_button(home, "CANCEL")
	_check("flow box: CANCEL button exists for a sent group", cancel_btn != null)
	var accept_btn := _find_button(home, "ACCEPT")
	_check("flow box: incoming invite has ACCEPT", accept_btn != null)
	if cancel_btn != null:
		var before := Friends.outgoing.size()
		cancel_btn.pressed.emit()
		var dropped := await _wait_for_condition(func() -> bool: return Friends.outgoing.size() < before, 5.0)
		_check("flow box: pressing CANCEL drops a whole group from outgoing",
			dropped and Friends.groups.size() == 1,
			"before=%d after=%d groups=%d" % [before, Friends.outgoing.size(), Friends.groups.size()])
	home.queue_free()
	await _frames(5)
	# Clean up the remaining sent group.
	for inv in Friends.outgoing.duplicate():
		await Friends.cancel_invite(inv)
		break
	_check("flow box: cleanup cancel leaves no tracked groups", Friends.groups.is_empty())

	# --- Realtime cancel: a cancelled record drops my incoming invite ---
	Friends.incoming = [
		{"id": "inv-incoming", "group_id": "grp-inc", "from_id": "user-nimal", "to_id": "user-me",
			"from_name": "Nimal", "to_name": "Test Player", "mode": "2p", "stake": 50,
			"status": "pending", "created_at": _iso_now()},
	]
	Friends._on_realtime_invite({"id": "inv-incoming", "group_id": "grp-inc", "from_id": "user-nimal",
		"to_id": "user-me", "from_name": "Nimal", "to_name": "Test Player", "mode": "2p",
		"stake": 50, "status": "cancelled", "created_at": _iso_now()})
	_check("flow realtime: cancelled invite leaves my inbox live", Friends.incoming.is_empty())
	_finish()

func _patch_created_at(invite_id: String, created_at: String) -> bool:
	var http := HTTPRequest.new()
	add_child(http)
	var body := JSON.stringify({"created_at": created_at})
	var err := http.request(MOCK_URL + "/rest/v1/invites?id=eq." + invite_id.uri_encode(),
		PackedStringArray(["Content-Type: application/json"]), HTTPClient.METHOD_PATCH, body)
	if err != OK:
		http.queue_free()
		return false
	var res: Array = await http.request_completed
	http.queue_free()
	return int(res[1]) == 200

func _collect_label_texts(node: Node, out: Array) -> void:
	for n in node.get_children():
		if n is Label:
			out.append((n as Label).text)
		if n is Button:
			out.append((n as Button).text)
		_collect_label_texts(n, out)

func _find_button(root: Node, prefix: String) -> Button:
	for n in root.get_children():
		if n is Button and String((n as Button).text).begins_with(prefix):
			return n
		var found := _find_button(n, prefix)
		if found:
			return found
	return null

func _wait_for_health() -> bool:
	var deadline := Time.get_unix_time_from_system() + 10.0
	while Time.get_unix_time_from_system() < deadline:
		var http := HTTPRequest.new()
		add_child(http)
		http.request(MOCK_URL + "/health")
		var res: Array = await http.request_completed
		http.queue_free()
		if int(res[1]) == 200:
			return true
		await get_tree().create_timer(0.3).timeout
	return false

func _wait_for_signal(sig: Signal, timeout_sec: float) -> bool:
	_signal_seen = false
	var set_flag := func(_a = null, _b = null, _c = null) -> void: _signal_seen = true
	sig.connect(set_flag)
	var deadline := Time.get_unix_time_from_system() + timeout_sec
	while Time.get_unix_time_from_system() < deadline:
		if _signal_seen:
			sig.disconnect(set_flag)
			return true
		await get_tree().create_timer(0.1).timeout
	sig.disconnect(set_flag)
	return _signal_seen

func _wait_for_condition(cond: Callable, timeout_sec: float) -> bool:
	var deadline := Time.get_unix_time_from_system() + timeout_sec
	while Time.get_unix_time_from_system() < deadline:
		if bool(cond.call()):
			return true
		await get_tree().create_timer(0.1).timeout
	return bool(cond.call())

func _finish() -> void:
	Friends.stop_listening()
	# Restore the real save file (the test mutated coins/xp/name).
	if _had_save:
		var f := FileAccess.open(SAVE_PATH, FileAccess.WRITE)
		if f:
			f.store_string(_saved_cfg)
			f.close()
		Save.load_save()
	elif FileAccess.file_exists(SAVE_PATH):
		DirAccess.remove_absolute(SAVE_PATH)
		Save.load_save()
	Supabase.load_config()
	Supabase.access_token = ""
	Supabase.user_id = ""
	if _mock_pid > 0:
		OS.kill(_mock_pid)
		_mock_pid = -1
	_done = true
	print("=== %d passed, %d failed ===" % [_passed, _failed])
	for f in _failures:
		print("FAIL: ", f)
	get_tree().quit(0 if _failed == 0 else 1)
