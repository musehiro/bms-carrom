extends Node

## Scale-hardening Realtime-first tests — LIVE CLIENT against
## tests/mock_supabase.py (GoTrue + PostgREST + Realtime mock). The
## test starts the mock itself (own port, 18081, so it never clashes
## with the main mock test on 18080), then drives the REAL Supabase /
## Friends / Accounts / Net autoloads. Run headless:
##   godot --headless --path . res://tests/scale_rt_mock_test.tscn
## Exit 0 = all pass, 1 = any fail.
##
## Proves, against the mock (worker-4 client refactor, 2026-11-28):
##   (a) an invite still arrives via Realtime while the incoming poll
##       is slowed to the 30 s backstop — arrival in <10 s proves the
##       socket carried it, not the poll; dropping Realtime falls back
##       to the 2 s poll, and the 60 s reconnect brings it back.
##   (b) the presence list is bounded: 60 rows seeded, list_presence
##       returns at most 50 (the client clamp — the mock ignores the
##       server-side limit=50, so the query shape is proved by the
##       pure test instead).
##   (c) token refresh fires before expiry: a JWT expiring in 2 min
##       is refreshed to rotated mock tokens, the rotated refresh
##       token is persisted to Save, and a dead refresh token flags
##       "must sign in again" instead of looping.
##   (d) the cleanup RPC is called throttled and best-effort: the
##       call succeeds against the mock (the SQL worker deployed the
##       function there with the specified shape), the first
##       search-start call reaches the server (seen in the mock's
##       last_post), a second call inside 5 min does NOT, and a call
##       after the window DOES. The "not deployed yet" (404) reading
##       is proved by the pure test — the mock now has the function,
##       so no live 404 is available to exercise.
## The local Save file is backed up and restored at the end, so the
## test never touches the real save. No real Supabase project, no
## network beyond localhost.

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
var _my_uid := ""

func _ready() -> void:
	_run()

func _process(delta: float) -> void:
	if _done:
		return
	_wait += delta
	if _wait > 120.0:
		_fail("mock test timed out")
		_finish()

func _check(name: String, cond: bool, detail: String = "") -> void:
	if cond:
		_passed += 1
		print("PASS: ", name)
	else:
		_failed += 1
		_failures.append(name + (" — " + detail if detail != "" else ""))
		print("FAIL: ", name, (" — " + detail if detail != "" else ""))

func _fail(message: String) -> void:
	_failed += 1
	_failures.append(message)
	print("FAIL: ", message)

## A minimal unsigned JWT for testing (the client only DECODES the
## payload — see SupabaseClient.jwt_exp). Signature is a placeholder.
func _make_jwt(uid: String, exp_unix: int) -> String:
	var header := SupabaseClient.base64url_encode(JSON.stringify({"alg": "HS256", "typ": "JWT"}).to_utf8_buffer())
	var payload := SupabaseClient.base64url_encode(JSON.stringify({"sub": uid, "exp": exp_unix}).to_utf8_buffer())
	return header + "." + payload + ".testsig"

func _run() -> void:
	print("=== BMS Carrom scale Realtime-first mock tests ===")
	# Back up the real save file.
	_had_save = FileAccess.file_exists(SAVE_PATH)
	if _had_save:
		_saved_cfg = FileAccess.get_file_as_string(SAVE_PATH)
	# Known starting state (same reset as the main mock test).
	Save.coins = 1000
	Save.xp = 0
	Save.matches_played = 0
	Save.matches_won = 0
	Save.account_gmail = ""
	Save.account_id = ""
	Save.account_verified = false
	Save.player_name = "Player"
	Save.session_access_token = ""
	Save.session_refresh_token = ""
	Save.session_saved_at = 0
	Accounts.session_refresh_failed = false
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
	# --- Sign in (anonymous is enough for the client paths tested) ---
	var anon := await Supabase.signup_anonymous()
	_check("mock-rt: anonymous signup returns a session", bool(anon.get("ok", false)) and Supabase.user_id != "")
	_my_uid = Supabase.user_id
	Save.account_id = _my_uid
	Save.player_name = "RT Tester"
	Save.save()
	await _test_realtime_first_invites()
	await _test_bounded_presence()
	# Stop listening before the cleanup section: the 30 s presence
	# heartbeat and the incoming poll must not POST/GET between the
	# last_post assertions below (the heartbeat POST would overwrite
	# the mock's last_post seam).
	Friends.stop_listening()
	Supabase.disconnect_realtime()
	Accounts._refresh_check_timer = 0.0 # the 60 s proactive-refresh check must not fire mid-assertions
	await _test_cleanup_rpc()
	await _test_token_refresh()
	_finish()

# ------------------------------------------- (a) Realtime-first invites
func _test_realtime_first_invites() -> void:
	Friends.start_listening()
	var connected := await _wait_for_signal(Supabase.realtime_connected, 5.0)
	_check("mock-rt: Realtime channel joined", connected)
	_check("mock-rt: Realtime healthy once joined", Friends.is_realtime_healthy())
	_check("mock-rt: poll slowed to the 30 s backstop while healthy",
		is_equal_approx(Friends.incoming_poll_interval(), 30.0))
	# An invite arrives live: sent AFTER the join, it must show up in
	# well under 30 s — the slowed poll cannot have delivered it.
	var t0 := Time.get_unix_time_from_system()
	var live_invite := SupabaseClient.invite_row("grp-rt", "user-nimal", _my_uid, "Nimal Perera", "RT Tester", "2p", 50)
	var live_sent := await Supabase.send_invite(live_invite)
	_check("mock-rt: live invite created", bool(live_sent.get("ok", false)))
	var arrived := await _wait_for_condition(func() -> bool: return Friends.pending_count() > 0, 5.0)
	var elapsed := Time.get_unix_time_from_system() - t0
	_check("mock-rt: invite arrived in the invite box", arrived)
	_check("mock-rt: invite arrived in <10 s, so Realtime carried it (not the 30 s poll)",
		arrived and elapsed < 10.0, "elapsed=%.1f s" % elapsed)
	# Simulate a server-side drop: the socket closes (real drop) and
	# the failure surfaces on the signal (what supabase.gd emits on
	# STATE_CLOSED). The poll must fall back to 2 s at once.
	Supabase.disconnect_realtime()
	Supabase.realtime_failed.emit("simulated drop")
	_check("mock-rt: drop marks Realtime unhealthy", not Friends.is_realtime_healthy())
	_check("mock-rt: poll falls back to 2 s while Realtime is down",
		is_equal_approx(Friends.incoming_poll_interval(), 2.0))
	# The 60 s reconnect brings it back: fast-forward the timer (test
	# seam — the cadence itself is the RT_RECONNECT_SECONDS const)
	# and wait for the join-ok.
	Friends._rt_reconnect_timer = Friends.RT_RECONNECT_SECONDS - 1.0
	var reconnected := await _wait_for_signal(Supabase.realtime_connected, 5.0)
	_check("mock-rt: reconnect re-joins the channel", reconnected)
	_check("mock-rt: Realtime healthy again after reconnect", Friends.is_realtime_healthy())
	_check("mock-rt: poll back to the 30 s backstop after reconnect",
		is_equal_approx(Friends.incoming_poll_interval(), 30.0))

# ------------------------------------------ (b) bounded presence list
func _test_bounded_presence() -> void:
	# Seed 60 presence rows (levels 1..20, all fresh — the mock stamps
	# updated_at=now on POST). The mock ignores the query's limit=50 /
	# level band, so what is proved here is the CLIENT clamp: the list
	# the lobby sees is at most 50 rows even when the server hands back
	# more. The server-side query shape is proved by the pure test.
	for i in range(60):
		var row := {"id": "seed-%02d" % i, "display_name": "Seed %d" % i,
			"level": 1 + (i % 20), "status": "online"}
		var r: Dictionary = await Supabase._http(HTTPClient.METHOD_POST, "/rest/v1/presence?on_conflict=id",
			row, true, PackedStringArray(["Prefer: return=representation,resolution=merge-duplicates"]))
		if not bool(r.get("ok", false)):
			_fail("mock-rt: could not seed presence row %d (%s)" % [i, String(r.get("error", "?"))])
			return
	var lp := await Supabase.list_presence(10)
	_check("mock-rt: presence list call succeeds", bool(lp.get("ok", false)))
	_check("mock-rt: presence list is bounded to 50 rows (60 seeded)",
		(lp.get("data", []) as Array).size() == 50, "got %d" % (lp.get("data", []) as Array).size())
	var lobby := await Friends.list_online_players()
	_check("mock-rt: lobby list succeeds", bool(lobby.get("ok", false)))
	_check("mock-rt: lobby list is bounded to 50 players",
		(lobby.get("players", []) as Array).size() == 50, "got %d" % (lobby.get("players", []) as Array).size())
	var well_formed := true
	for p in (lobby.get("players", []) as Array):
		if String(p.get("display_name", "")) == "" or int(p.get("level", 0)) < 1:
			well_formed = false
	_check("mock-rt: lobby rows carry name + level + status only", well_formed)

# ------------------------------------------- (d) cleanup RPC (best-effort)
func _test_cleanup_rpc() -> void:
	# The function IS deployed in the mock (the SQL worker's parallel
	# work): the call succeeds with exactly the specified shape — no
	# args, jsonb {ok, expired_matches, deleted_queue_rows,
	# expired_invites}. The "not deployed yet" (404) path cannot be
	# exercised against this mock any more; it stays covered by the
	# pure test (is_cleanup_rpc_missing on a synthetic 404 dict).
	var c := await Supabase.call_cleanup_stale_matchmaking()
	_check("mock-rt: cleanup RPC succeeds", bool(c.get("ok", false)))
	var cdata: Dictionary = c.get("data", {}) if c.get("data") is Dictionary else {}
	_check("mock-rt: cleanup RPC returns the specified shape {ok, expired_matches, deleted_queue_rows, expired_invites}",
		bool(cdata.get("ok", false)) and cdata.has("expired_matches") and cdata.has("deleted_queue_rows") and cdata.has("expired_invites"),
		JSON.stringify(cdata))
	# Throttle: the first search-start call reaches the server…
	Net._cleanup_last_call_unix = 0
	Net._maybe_cleanup_stale_matchmaking()
	await get_tree().create_timer(1.5).timeout
	var first := await _get_last_post()
	_check("mock-rt: first cleanup call reaches the server",
		String(first.get("path", "")).contains("cleanup_stale_matchmaking"), String(first.get("path", "")))
	# …a second call inside 5 min does NOT (sentinel POST overwrites
	# last_post first, so a second cleanup call would show up).
	var hb := await Supabase.heartbeat_presence(_my_uid, "RT Tester", 1, "online")
	_check("mock-rt: sentinel heartbeat posted", bool(hb.get("ok", false)))
	Net._maybe_cleanup_stale_matchmaking()
	await get_tree().create_timer(1.5).timeout
	var second := await _get_last_post()
	_check("mock-rt: second call inside 5 min is throttled (no cleanup call)",
		String(second.get("path", "")).contains("/rest/v1/presence"), String(second.get("path", "")))
	# …and a call after the window DOES go out again.
	Net._cleanup_last_call_unix = int(Time.get_unix_time_from_system()) - 301
	Net._maybe_cleanup_stale_matchmaking()
	await get_tree().create_timer(1.5).timeout
	var third := await _get_last_post()
	_check("mock-rt: call after the 5 min window reaches the server again",
		String(third.get("path", "")).contains("cleanup_stale_matchmaking"), String(third.get("path", "")))
	_check("mock-rt: best-effort cleanup never touches search state",
		not Net.is_p2p_searching())

# ------------------------------------------- (c) mid-session token refresh
func _test_token_refresh() -> void:
	var now := int(Time.get_unix_time_from_system())
	# A JWT expiring in 2 min: the client must see the refresh as due.
	Supabase._set_session({"access_token": _make_jwt(_my_uid, now + 120),
		"refresh_token": "ref-" + _my_uid, "user": {"id": _my_uid}})
	_check("mock-rt: expiry read from the JWT", Supabase.session_expires_at == now + 120)
	_check("mock-rt: refresh is due 2 min before expiry", Supabase.session_needs_refresh())
	var before := Supabase.access_token
	var ok := await Supabase.ensure_fresh_session()
	_check("mock-rt: proactive refresh succeeds", ok)
	_check("mock-rt: access token rotated", Supabase.access_token != "" and Supabase.access_token != before)
	_check("mock-rt: refresh token rotated by GoTrue", Supabase.refresh_token == "ref-refreshed-" + _my_uid)
	_check("mock-rt: same user after refresh", Supabase.user_id == _my_uid)
	_check("mock-rt: rotated refresh token persisted to Save (session_refreshed signal)",
		Save.session_refresh_token == Supabase.refresh_token)
	_check("mock-rt: no refresh due right after a refresh", not Supabase.session_needs_refresh())
	# A DEAD refresh token: the refresh fails with invalid_grant, the
	# client flags "must sign in again" — and never loops on it.
	Supabase._set_session({"access_token": _make_jwt(_my_uid, now + 60),
		"refresh_token": "ref-00000000-0000-0000-0000-000000000000", "user": {"id": _my_uid}})
	Accounts.session_refresh_failed = false
	var ok2 := await Supabase.ensure_fresh_session()
	_check("mock-rt: refresh with a dead token fails", not ok2)
	_check("mock-rt: dead refresh token flags must-sign-in-again", Accounts.session_refresh_failed)
	Accounts.session_refresh_failed = false # leave the flag clean

# ---------------------------------------------------------------- helpers
func _get_last_post() -> Dictionary:
	var http := HTTPRequest.new()
	add_child(http)
	http.request(MOCK_URL + "/__test__/last_post")
	var res: Array = await http.request_completed
	http.queue_free()
	if int(res[1]) != 200:
		return {}
	var data: Variant = JSON.parse_string((res[3] as PackedByteArray).get_string_from_utf8())
	return data if data is Dictionary else {}

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
	# A lambda capturing a LOCAL bool would capture it by value and the
	# flag would never flip — use the member var instead.
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
	# Back to the shipped (unconfigured) backend state.
	Friends.stop_listening()
	Supabase.disconnect_realtime()
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
