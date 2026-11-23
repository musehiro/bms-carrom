extends Node

## Live client test (v7): drives the REAL Supabase client (autoload),
## Accounts and Friends against tests/mock_supabase.py — a local Python
## mock of GoTrue + PostgREST + Realtime. The test starts the mock
## itself (OS.create_process), waits for /health, then runs the whole
## account + invite flow end to end:
##   anonymous signup -> register (name + Gmail, local only) ->
##   OTP send -> wrong code rejected -> right code verified ->
##   cloud profile created from the local save -> fetch by Gmail ->
##   second player seeded -> search (name only, no Gmail in results)
##   -> 2p invite send -> accept -> 4p group send -> all accept ->
##   group ready -> Realtime: connect + invite broadcast arrives in
##   Friends.incoming -> Google loopback: begin_google_sign_in +
##   GET /callback?code=TESTCODE -> google_finished ok, Gmail linked.
##   Google deep link: begin + write user://auth_callback.txt with the
##   custom-scheme URI -> google_finished ok (file path). Google paste:
##   begin + finish_google_with_pasted_code(full URL / bare code) ->
##   google_finished ok. The Google flow needs NO google_client_id
##   (the mock config sets it to "").
## The local Save file is backed up and restored at the end, so the
## test never touches the real save. No real Supabase project, no
## network beyond localhost.
## Run headless: godot --headless --path . res://tests/supabase_mock_test.tscn
## Exit 0 = all pass, 1 = any fail.

const MOCK_PORT := 18080
const MOCK_URL := "http://127.0.0.1:18080"
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

func _fail(name: String) -> void:
	_failed += 1
	_failures.append(name)
	print("FAIL: ", name)

func _run() -> void:
	print("=== BMS Carrom supabase mock tests ===")
	# Back up the real save file.
	_had_save = FileAccess.file_exists(SAVE_PATH)
	if _had_save:
		_saved_cfg = FileAccess.get_file_as_string(SAVE_PATH)
	# v9: the starting-coins / restore assertions need a KNOWN starting
	# state — the sandbox save is dirty from earlier test runs (staked
	# matches left it at 900 coins / 14 matches), so reset the profile
	# fields to a fresh install here. The file is restored at the end.
	Save.coins = 1000
	Save.xp = 0
	Save.matches_played = 0
	Save.matches_won = 0
	Save.solo_wins = 0
	Save.online_wins = 0
	Save.tour_wins = 0
	Save.queens_covered = 0
	Save.owned_boards = ["classic"]
	Save.owned_strikers = ["classic"]
	Save.equipped_board = "classic"
	Save.equipped_striker = "classic"
	Save.ad_count_today = 0
	Save.ad_coins_today = 0
	Save.interstitial_counter = 0
	# F7: a verified account left in the save would make register_player
	# refuse — reset the account too, so the register step is hermetic.
	Save.account_gmail = ""
	Save.account_id = ""
	Save.account_verified = false
	Save.account_created_at = ""
	Save.account_synced_at = 0
	Save.player_name = "Player"
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
	Supabase.set_config(MOCK_URL, "test-anon-key", "") # v9: no google_client_id needed at all
	Supabase.access_token = ""
	Supabase.user_id = ""
	# --- Auth: anonymous signup (client capability) ---
	var anon := await Supabase.signup_anonymous()
	_check("mock: anonymous signup returns a session", bool(anon.get("ok", false)) and Supabase.user_id != "" and Supabase.access_token != "")
	Supabase.access_token = ""
	Supabase.user_id = ""
	# --- Register (local only — no session yet) ---
	var reg := await Accounts.register_player("Test Player", "test.player@gmail.com")
	_check("mock: register creates the local account", bool(reg.get("ok", false)) and Accounts.has_account() and Save.account_gmail == "test.player@gmail.com" and Save.player_name == "Test Player")
	_check("mock: register does not claim the cloud yet", not bool(reg.get("cloud", true)))
	# --- OTP: send, resend, wrong code, right code ---
	var sent := await Accounts.request_login_code("test.player@gmail.com")
	_check("mock: OTP code sent", bool(sent.get("ok", false)))
	# L5: resending reuses the pending OTP-link verifier — a fresh one
	# would silently kill the first email's "Sign in" link.
	var v1 := Accounts.pending_return_verifier()
	var sent_again := await Accounts.request_login_code("test.player@gmail.com")
	_check("mock: resend reuses the pending OTP verifier", bool(sent_again.get("ok", false)) and v1 != "" and Accounts.pending_return_verifier() == v1)
	var wrong := await Accounts.verify_code_and_login("test.player@gmail.com", "000000", true)
	_check("mock: wrong code rejected", not bool(wrong.get("ok", false)))
	var right := await Accounts.verify_code_and_login("test.player@gmail.com", "123456", true)
	_check("mock: right code verifies and creates the cloud profile", bool(right.get("ok", false)) and Accounts.is_verified())
	# v10 regression: verifying the code ends the OTP-link pending
	# return (loopback listener) — otherwise a later Google sign-in
	# is told one is "already in flight" and its callback completes
	# as an OTP-link return (wrong signal, wrong PKCE verifier).
	_check("mock: OTP verify ends the pending return", not Accounts.is_return_pending())
	_check("mock: account id is now the Supabase user id", Save.account_id == Supabase.user_id and Save.account_id != "")
	# --- Profile fetch by Gmail (restore path) ---
	var got := await Supabase.get_profile_by_gmail("test.player@gmail.com")
	var row: Dictionary = got.get("data", {})
	_check("mock: profile fetch by Gmail finds the row", bool(got.get("ok", false)) and String(row.get("display_name", "")) == "Test Player")
	_check("mock: cloud profile has the starting coins", int(row.get("coins", 0)) == 1000)
	# --- Sign-in restore: wipe local, verify again, profile comes back ---
	Save.coins = 0
	Save.xp = 0
	var again := await Accounts.verify_code_and_login("test.player@gmail.com", "123456", false)
	_check("mock: sign-in restores the cloud profile", bool(again.get("ok", false)) and bool(again.get("restored", false)) and Save.coins == 1000)
	# verifyOtp leading-zero check: the 6-digit code must travel as a
	# STRING — "012345" verifies end to end (the mock only accepts it
	# with the zero intact; an int parse anywhere would send "12345").
	var sent_lz := await Accounts.request_login_code("test.player@gmail.com")
	_check("mock: OTP code re-sent for the leading-zero check", bool(sent_lz.get("ok", false)))
	var lz := await Accounts.verify_code_and_login("test.player@gmail.com", "012345", false)
	_check("mock: code with a leading zero verifies (string, never int)", bool(lz.get("ok", false)) and Save.coins == 1000)
	# --- Second player + search (name only) ---
	var p2 := SupabaseClient.profile_row("user-nimal", "nimal@gmail.com", "Nimal Perera", 1500, 1200, 10, 6, 3, 2, ["classic"], ["classic"], "classic", "classic")
	var up2 := await Supabase.upsert_profile(p2)
	_check("mock: second profile upserted", bool(up2.get("ok", false)))
	var search := await Friends.search("nim")
	_check("mock: search finds Nimal by name", bool(search.get("ok", false)) and (search.get("results", []) as Array).size() == 1)
	var hit: Dictionary = (search.get("results", []) as Array)[0] if (search.get("results", []) as Array).size() == 1 else {}
	_check("mock: search result has no Gmail (privacy)", not hit.has("gmail") and not hit.has("coins"))
	_check("mock: search result has id + name + level", String(hit.get("display_name", "")) == "Nimal Perera" and int(hit.get("level", 0)) == 3)
	var nohit := await Friends.search("zzz-no-such-name")
	_check("mock: search with no match returns empty", bool(nohit.get("ok", false)) and (nohit.get("results", []) as Array).is_empty())
	# --- 2p invite: send, list, accept ---
	var sent2 := await Friends.send_invite("user-nimal", "Nimal Perera", 100)
	_check("mock: 2p invite sent", bool(sent2.get("ok", false)) and String(sent2.get("group_id", "")) != "")
	var gid: String = sent2.get("group_id", "")
	var grp := await Supabase.list_group_invites(gid)
	_check("mock: group has the one pending invite", bool(grp.get("ok", false)) and (grp.get("data", []) as Array).size() == 1 and String((grp.get("data", []) as Array)[0].get("status", "")) == "pending")
	var acc := await Friends.accept_invite((grp.get("data", []) as Array)[0])
	_check("mock: invite accepted", bool(acc.get("ok", false)) and String((acc.get("invite", {}) as Dictionary).get("status", "")) == "accepted")
	# --- 4p group: send to 3, all accept -> ready ---
	var targets := [
		{"id": "user-nimal", "name": "Nimal Perera"},
		{"id": "user-saman", "name": "Saman"},
		{"id": "user-kasun", "name": "Kasun"},
	]
	var sent4 := await Friends.send_group_invite(targets, 200)
	_check("mock: 4p invite sent to 3 friends", bool(sent4.get("ok", false)))
	var gid4: String = sent4.get("group_id", "")
	var grp4 := await Supabase.list_group_invites(gid4)
	var rows4: Array = grp4.get("data", [])
	_check("mock: 4p group has 3 rows, waiting", rows4.size() == 3 and Friends.group_state(rows4) == "waiting")
	for r in rows4:
		await Supabase.update_invite(String(r.get("id", "")), "accepted")
	var grp4b := await Supabase.list_group_invites(gid4)
	_check("mock: 4p group ready after all accept", Friends.group_state(grp4b.get("data", [])) == "ready")
	var players: Array = Friends.group_players(grp4b.get("data", []), Save.account_id, Save.player_name)
	_check("mock: 4p group players — inviter + 3 invitees", players.size() == 4 and String(players[0].get("name", "")) == "Test Player")
	# --- Realtime: connect, then an invite arrives live ---
	Friends.start_listening()
	var connected := await _wait_for_signal(Supabase.realtime_connected, 5.0)
	_check("mock: Realtime channel joined", connected)
	var live_invite := SupabaseClient.invite_row("grp-live", "user-nimal", Save.account_id, "Nimal Perera", "Test Player", "2p", 50)
	var live_sent := await Supabase.send_invite(live_invite)
	_check("mock: live invite created", bool(live_sent.get("ok", false)))
	var arrived := await _wait_for_condition(func() -> bool: return Friends.pending_count() > 0, 5.0)
	_check("mock: Realtime invite arrived in the invite box", arrived)
	# --- Google loopback: begin sign-in, fake the browser callback ---
	var started := Accounts.begin_google_sign_in()
	_check("mock: Google loopback server started", started)
	if started:
		var http := HTTPRequest.new()
		add_child(http)
		http.request("http://127.0.0.1:8765/callback?code=TESTCODE")
		var gok := await _wait_for_signal(Accounts.google_finished, 5.0)
		_check("mock: Google sign-in finished via loopback", gok)
		_check("mock: Google Gmail linked", Save.account_gmail == "google-user@gmail.com" and Accounts.is_verified())
		http.queue_free()
	# --- Google deep link: begin, then the native side writes the file ---
	var started2 := Accounts.begin_google_sign_in()
	_check("mock: Google deep-link flow started (no client id)", started2)
	if started2:
		var f := FileAccess.open(Supabase.AUTH_CALLBACK_FILE, FileAccess.WRITE)
		f.store_string("com.musehiro.carrom://auth-callback?code=TESTCODE&state=x")
		f.close()
		var gok2 := await _wait_for_signal(Accounts.google_finished, 5.0)
		_check("mock: Google sign-in finished via deep-link file", gok2)
		_check("mock: deep-link Gmail linked", Save.account_gmail == "google-user@gmail.com" and Accounts.is_verified())
	# --- Google paste-code fallback: full URL, then a bare code ---
	var started3 := Accounts.begin_google_sign_in()
	_check("mock: Google paste flow started", started3)
	if started3:
		var pasted := Accounts.finish_google_with_pasted_code("com.musehiro.carrom://auth-callback?code=TESTCODE&state=x")
		_check("mock: paste-code accepted while pending", pasted)
		var gok3 := await _wait_for_signal(Accounts.google_finished, 5.0)
		_check("mock: Google sign-in finished via pasted URL", gok3)
	var started4 := Accounts.begin_google_sign_in()
	_check("mock: Google bare-code flow started", started4)
	if started4:
		var pasted4 := Accounts.finish_google_with_pasted_code("TESTCODE")
		_check("mock: bare code accepted while pending", pasted4)
		var gok4 := await _wait_for_signal(Accounts.google_finished, 5.0)
		_check("mock: Google sign-in finished via pasted bare code", gok4)
	# --- Google paste with nothing pending is refused ---
	var pasted5 := Accounts.finish_google_with_pasted_code("TESTCODE")
	_check("mock: paste-code refused when nothing is pending", not pasted5)
	Friends.stop_listening()
	_finish()

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
