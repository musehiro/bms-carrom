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
##   Session persistence (v11): OTP sign-in persists its tokens ->
##   simulated restart (in-memory session cleared) restores the
##   session with ROTATED tokens -> bad refresh token fails, needs
##   sign-in again, saved tokens cleared -> restore with no saved
##   session fails fast -> sign-out clears the saved session.
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
var _count_server: TCPServer = null # retry test: accepts + instantly drops
var _count_accepted := 0 # connections the counting server has taken
var _counting := false # drain the counting server in _process while set

func _ready() -> void:
	_run()

func _process(delta: float) -> void:
	if _done:
		return
	_wait += delta
	if _counting and _count_server != null:
		# Retry test: accept each pending connection and drop it at
		# once (the client sees a transport failure, status 0).
		while _count_server.is_connection_available():
			var peer := _count_server.take_connection()
			_count_accepted += 1
			peer.disconnect_from_host()
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

func _collect_button_texts(node: Node, out: Array) -> void:
	for n in node.get_children():
		if n is Button:
			out.append((n as Button).text)
		_collect_button_texts(n, out)

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
	# v11 session persistence: a stale saved session from an earlier
	# (possibly interrupted) run would make the persist checks vacuous.
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
	# v11 session persistence: the OTP sign-in persisted its session.
	_check("mock: OTP sign-in persisted the session tokens", Save.session_refresh_token != "" and Save.session_access_token != "" and Supabase.refresh_token == Save.session_refresh_token)
	_check("mock: saved access token matches the live session", Save.session_access_token == Supabase.access_token)
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
	# --- Auth fix (2026-11-27): Google off + OTP redirect fallback ---
	# Google disabled (new project): begin refuses fast — no browser
	# opens, so the player never sees GoTrue's 400 "Unsupported
	# provider" page. Re-enable right away: the Google loopback tests
	# below need it on.
	Supabase.google_enabled = false
	_check("mock: Google sign-in refuses fast while the provider is off", not Accounts.begin_google_sign_in())
	Supabase.google_enabled = true
	# OTP redirect rejected (fresh project, no Redirect URLs
	# allow-listed): the code-only retry still sends the code, starts
	# NO return listener (no magic link will come back), and the code
	# verifies. The flag is turned off again right after.
	await _set_otp_redirect_fail(true)
	var sent_fb := await Accounts.request_login_code("test.player@gmail.com")
	_check("mock: OTP sent via the code-only fallback", bool(sent_fb.get("ok", false)))
	_check("mock: fallback starts no return listener", not Accounts.is_return_pending())
	var right_fb := await Accounts.verify_code_and_login("test.player@gmail.com", "123456", false)
	_check("mock: fallback code verifies", bool(right_fb.get("ok", false)))
	await _set_otp_redirect_fail(false)
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
	# --- Round 4 single-flight (2026-11-28 05:18:47): two concurrent
	# ticks called create_match_from_invites for the same group in
	# the same second and made TWO duplicate matches. The cause was
	# start_p2p_invite resetting _p2p_poll_busy while a tick was in
	# flight awaiting HTTP — the next frame started a second tick.
	# Reproduce it: start the invite search, drive a tick manually
	# (it suspends on its first HTTP await with busy=true), then
	# re-enter start_p2p_invite in the SAME frame, as _on_group_ready
	# did while a random search's tick was in flight. On unfixed
	# code the re-entry clears busy, a second tick starts, and the
	# RPC runs twice (the mock's 0.05 s validation window makes the
	# double-insert deterministic). On fixed code exactly one RPC
	# runs and one match forms.
	var counts_before := await Supabase._http(HTTPClient.METHOD_GET, "/__test__/rpc_counts", {}, true)
	var rpc_before: int = int((counts_before.get("data", {}) as Dictionary).get("create_match_from_invites", 0))
	Net.start_p2p_invite(gid, Save.player_name, 1, 100, "2p", 0, true)
	Net._p2p_tick() # runs to its first await (pre-RPC poll), busy=true
	Net.start_p2p_invite(gid, Save.player_name, 1, 100, "2p", 0, true)
	var single_flight := await _wait_for_condition(func() -> bool: return MatchState.match_id != "", 6.0)
	_check("mock: round4 double-tick joins the invite match", single_flight and Net._p2p_match_id == MatchState.match_id)
	var counts_after := await Supabase._http(HTTPClient.METHOD_GET, "/__test__/rpc_counts", {}, true)
	var rpc_after: int = int((counts_after.get("data", {}) as Dictionary).get("create_match_from_invites", 0))
	_check("mock: round4 single-flight — exactly ONE create_match_from_invites call", rpc_after - rpc_before == 1, "before=%d after=%d" % [rpc_before, rpc_after])
	var matches_sf := await Supabase._http(HTTPClient.METHOD_GET, "/rest/v1/matches?select=*", {}, true)
	var mrows_sf: Array = matches_sf.get("data", []) if matches_sf.get("data") is Array else []
	_check("mock: round4 single-flight — exactly ONE match for the group", mrows_sf.size() == 1, str(mrows_sf.size()))
	Net.cancel_p2p_search()
	MatchState.clear()
	# --- join_match (2026-11-28): the accepted group forms a 'waiting'
	# matches row via the RPC, and Net.join_match fetches it, validates
	# it (player_ids + status), stores it in MatchState and begins the
	# mesh — the ONE shared entry into a formed match. The mesh itself
	# cannot connect in the sandbox (UDP blocked), so the test asserts
	# up to the mesh begin, then tears the P2P state down again.
	var rpc := await Supabase.call_create_match_from_invites(gid)
	var mid: String = String((rpc.get("data", {}) as Dictionary).get("match_id", ""))
	_check("mock: create_match_from_invites forms the match", bool(rpc.get("ok", false)) and bool((rpc.get("data", {}) as Dictionary).get("ok", false)) and mid != "")
	# Direct join (explicit match_id; the discovery poll is NOT running
	# yet, so no tick can race this call). _p2p_my_id is set directly
	# — the test never searched, so no search set it.
	Net._p2p_my_id = Supabase.user_id
	var joined: bool = await Net.join_match(mid)
	_check("mock: join_match joins the invite match", joined and MatchState.match_id == mid and MatchState.my_seat == 0 and Net._p2p_match_id == mid)
	_check("mock: MatchState stores the waiting match", MatchState.status == "waiting" and MatchState.mode == "2p" and MatchState.players.size() == 2)
	var fetched := await Supabase.get_match_by_id(mid)
	_check("mock: get_match_by_id fetches the row", String(fetched.get("id", "")) == mid and String(fetched.get("status", "")) == "waiting")
	Net.cancel_p2p_search()
	MatchState.clear()
	_check("mock: cancel tears the P2P state down", Net._p2p_match_id == "" and not Net.is_p2p_searching())
	# Discovery join: the sender-side poll finds the same 'waiting'
	# row (preferring the group) and joins it with no RPC call.
	Net.start_match_discovery(gid, "2p")
	var discovered := await _wait_for_condition(func() -> bool: return MatchState.match_id == mid, 6.0)
	_check("mock: discovery poll finds + joins the waiting match", discovered and Net._p2p_match_id == mid)
	Net.cancel_p2p_search()
	MatchState.clear()
	# --- Invite join fix (2026-11-28 round 3): the two phones sent
	# invites to EACH OTHER, so two matches existed with the same
	# players and each phone joined its own — both waited forever in
	# different channels. These tests prove the tick polls for an
	# existing match BEFORE calling the RPC (no second match is
	# formed), and that while a peer has not connected the client
	# migrates to a strictly newer match with the same players.
	# A second accepted group (sent by me, so the mock's inviter-coin
	# check passes — the mock has no profile for user-nimal).
	var sentB := await Friends.send_invite("user-nimal", "Nimal Perera", 100)
	_check("mock: invitefix second group sent", bool(sentB.get("ok", false)))
	var gidB: String = sentB.get("group_id", "")
	var grpB := await Supabase.list_group_invites(gidB)
	var accB := await Friends.accept_invite((grpB.get("data", []) as Array)[0])
	_check("mock: invitefix second group accepted", bool(accB.get("ok", false)))
	Net.start_p2p_invite(gidB, Save.player_name, 1, 100, "2p", 0, true)
	var joined_existing := await _wait_for_condition(func() -> bool: return MatchState.match_id == mid, 6.0)
	_check("mock: invitefix pre-RPC poll joins the existing match, no RPC", joined_existing and Net._p2p_match_id == mid)
	var matches_after := await Supabase._http(HTTPClient.METHOD_GET, "/rest/v1/matches?select=*", {}, true)
	var mrows: Array = matches_after.get("data", []) if matches_after.get("data") is Array else []
	_check("mock: invitefix pre-RPC poll formed no second match", mrows.size() == 1, str(mrows.size()))
	# Settle migration: a newer match with the same players appears
	# (the other phone's RPC fired before either side discovered the
	# first one) — the client must move to it while the peer has not
	# connected, so both phones converge on the same match.
	var rpcB := await Supabase.call_create_match_from_invites(gidB)
	var midB := String((rpcB.get("data", {}) as Dictionary).get("match_id", ""))
	_check("mock: invitefix second match created for the settle test", bool(rpcB.get("ok", false)) and midB != "" and midB != mid)
	var migrated := await _wait_for_condition(func() -> bool: return Net._p2p_match_id == midB, 8.0)
	_check("mock: invitefix settle tick migrates to the newer same-players match", migrated and MatchState.match_id == midB)
	Net.cancel_p2p_search()
	MatchState.clear()
	# --- Round 4 no-refire (incident 2026-11-28 05:18): the OLD
	# accepted group 7710c914 re-fired _on_group_ready on a later
	# launch because refresh() re-tracked it (never consumed ON THAT
	# PHONE) and the group poll fired it again — starting a second
	# resolution loop over a match that already existed. Both groups
	# here (gid, gidB) are ready, NOT consumed, and already have a
	# live match — refresh() must consume them and NOT re-track them,
	# and the group poll must never fire group_ready for them.
	var refire := [0]
	var refire_cb := func(_gid: String, _inv: Array) -> void: refire[0] += 1
	Friends.group_ready.connect(refire_cb)
	_check("mock: round4 handled groups are tracked before refresh", Friends.groups.has(gid) and Friends.groups.has(gidB))
	var ref := await Friends.refresh()
	_check("mock: round4 refresh succeeds", bool(ref.get("ok", false)))
	_check("mock: round4 refresh does not re-track groups with a live match", not Friends.groups.has(gid) and not Friends.groups.has(gidB))
	_check("mock: round4 refresh consumed both handled groups", Save.consumed_invite_groups.has(gid) and Save.consumed_invite_groups.has(gidB))
	Friends._poll_outgoing_groups()
	await get_tree().create_timer(1.0).timeout
	_check("mock: round4 group poll does not re-fire handled groups", refire[0] == 0, str(refire[0]))
	# The _poll_group layer: a ready group that is STILL tracked
	# (never refreshed) but whose match already exists must also
	# not fire — it is consumed by the poll itself. Fresh group so
	# neither earlier test has consumed it.
	var sentR := await Friends.send_invite("user-nimal", "Nimal Perera", 100)
	_check("mock: round4 refire group sent", bool(sentR.get("ok", false)))
	var gidR: String = sentR.get("group_id", "")
	var grpR := await Supabase.list_group_invites(gidR)
	var accR := await Friends.accept_invite((grpR.get("data", []) as Array)[0])
	_check("mock: round4 refire group accepted", bool(accR.get("ok", false)))
	var rpcR := await Supabase.call_create_match_from_invites(gidR)
	_check("mock: round4 refire group match formed", bool(rpcR.get("ok", false)) and bool((rpcR.get("data", {}) as Dictionary).get("ok", false)))
	_check("mock: round4 refire group is tracked before the poll", Friends.groups.has(gidR))
	Friends._poll_outgoing_groups()
	await get_tree().create_timer(1.0).timeout
	_check("mock: round4 poll consumes a ready group with a live match without firing", refire[0] == 0 and not Friends.groups.has(gidR) and Save.consumed_invite_groups.has(gidR), "refire=%d tracked=%s" % [refire[0], str(Friends.groups.has(gidR))])
	Friends.group_ready.disconnect(refire_cb)
	# --- Queue insert (2026-11-28): the b2706f4 build never joined the
	# queue — its [MATCH] log called String() on the INT table/stake
	# fields, and GDScript 4.3 has no String(int) constructor, so
	# queue_insert threw BEFORE the POST and the caller saw the
	# "(connection failed)" default. These tests prove the POST leaves
	# the phone with the right URL/body/Prefer header, every failure
	# path carries a real non-empty error, and a transport failure
	# retries exactly once then fails fast with the real error.
	var qrow := NetClient.queue_row(Supabase.user_id, Save.player_name, 1, 0, 100, "2p")
	var qins := await Supabase.queue_insert(qrow)
	_check("mock: queue_insert posts the row (regression: String(int) throw)", bool(qins.get("ok", false)))
	var qlast := await Supabase._http(HTTPClient.METHOD_GET, "/__test__/last_post", {}, true)
	var qlp: Dictionary = qlast.get("data", {})
	_check("mock: queue upsert hits the on_conflict URL", String(qlp.get("path", "")).begins_with("/rest/v1/matchmaking_queue?on_conflict=id"), String(qlp.get("path", "")))
	var qlb: Dictionary = qlp.get("body", {})
	_check("mock: queue upsert body has all 7 fields", String(qlb.get("id", "")) == Supabase.user_id and String(qlb.get("user_id", "")) == Supabase.user_id and String(qlb.get("display_name", "")) == Save.player_name and int(qlb.get("level", 0)) == 1 and int(qlb.get("table", -1)) == 0 and int(qlb.get("stake", -1)) == 100 and String(qlb.get("mode", "")) == "2p")
	var qlh: Dictionary = qlp.get("headers", {})
	var qprefer := String(qlh.get("Prefer", qlh.get("prefer", "")))
	_check("mock: queue upsert sends the merge-duplicates Prefer", qprefer.contains("return=representation") and qprefer.contains("resolution=merge-duplicates"), qprefer)
	var qrows := await Supabase._http(HTTPClient.METHOD_GET, "/rest/v1/matchmaking_queue", {}, true)
	_check("mock: queue row landed on the server", (qrows.get("data", []) as Array).size() == 1)
	# Every failure path carries a real non-empty error string.
	var nf := await Supabase._http(HTTPClient.METHOD_GET, "/rest/v1/definitely-not-a-table", {}, true)
	_check("mock: HTTP 404 returns a real non-empty error", not bool(nf.get("ok", false)) and String(nf.get("error", "")) != "", String(nf.get("error", "")))
	Supabase.set_config("http://127.0.0.1:9", "test-anon-key")
	var dead := await Supabase._http(HTTPClient.METHOD_GET, "/rest/v1/profiles", {}, true)
	_check("mock: transport failure returns status 0 + a real error (never the bare default)", not bool(dead.get("ok", false)) and int(dead.get("status", 0)) == 0 and String(dead.get("error", "")) != "" and String(dead.get("error", "")) != "connection failed", String(dead.get("error", "")))
	# Transport failure retries exactly once, then fails fast with the
	# real error. The counting server accepts and instantly drops the
	# connection (status 0 both times); _process drains it. Point the
	# client AT the counting server first (the dead-port config above
	# would never reach it).
	_count_server = TCPServer.new()
	_count_accepted = 0
	_counting = _count_server.listen(18081) == OK
	_check("mock: counting server listens for the retry test", _counting)
	if _counting:
		Supabase.set_config("http://127.0.0.1:18081", "test-anon-key")
		var qdead := await Supabase.queue_insert(qrow)
		await get_tree().create_timer(0.5).timeout
		_check("mock: queue_insert on a dead connection fails fast with the real error", not bool(qdead.get("ok", false)) and String(qdead.get("error", "")).begins_with("Connection failed ("), String(qdead.get("error", "")))
		_check("mock: transport failure retried exactly once (2 attempts)", _count_accepted == 2, str(_count_accepted))
		_counting = false
		_count_server.stop()
		_count_server = null
	Supabase.set_config(MOCK_URL, "test-anon-key", "")
	# Back on the mock: the row is still there (the dead attempts never
	# reached it) — clean it up so later tests see a fresh queue.
	var qdel := await Supabase.queue_delete(Supabase.user_id)
	_check("mock: queue row deleted after the test", bool(qdel.get("ok", false)))
	# Net-level: start_p2p_search against the mock joins the queue and
	# keeps searching (no queue_failed) — the full path the user taps.
	# A FRESH player id: the mock still holds the invite match from
	# the section above, and the search tick's matches poll would
	# legitimately join it (the player IS in it) — that would end the
	# search before the check. The fresh id has no matches, so the
	# search stays searching. Restore the real uid right after.
	var search_uid := Supabase.user_id
	Supabase.user_id = "22222222-3333-4444-5555-666666666666"
	var qfailed: Array = []
	var qfail_cb := func(msg: String) -> void: qfailed.append(msg)
	Net.queue_failed.connect(qfail_cb)
	Net.start_p2p_search(Save.player_name, 1, 0, 100, "2p")
	await get_tree().create_timer(1.0).timeout
	_check("mock: start_p2p_search joins the queue with no failure", qfailed.is_empty() and Net._p2p_searching, JSON.stringify(qfailed))
	# Self-heal (2026-11-28 round 3): the live log showed find_match
	# answering "You are not in the queue." when the tick fired before
	# the async insert landed. The tick now re-inserts the row and
	# keeps searching instead of treating it as a dead end.
	await get_tree().create_timer(0.5).timeout
	await Supabase.queue_delete("22222222-3333-4444-5555-666666666666")
	await get_tree().create_timer(4.0).timeout
	var qafter := await Supabase._http(HTTPClient.METHOD_GET, "/rest/v1/matchmaking_queue?select=*", {}, true)
	var qrows_heal: Array = qafter.get("data", []) if qafter.get("data") is Array else []
	_check("mock: invitefix self-heal re-inserts the queue row", qrows_heal.any(func(r: Dictionary) -> bool: return String(r.get("id", "")) == "22222222-3333-4444-5555-666666666666"), JSON.stringify(qrows_heal))
	_check("mock: invitefix self-heal keeps searching (no queue_failed)", qfailed.is_empty() and Net.is_p2p_searching(), JSON.stringify(qfailed))
	Net.cancel_p2p_search()
	Net.queue_failed.disconnect(qfail_cb)
	Supabase.user_id = search_uid
	await Supabase.queue_delete("22222222-3333-4444-5555-666666666666")
	# RPC ok:false survival (2026-11-28 round 3): a group that is not
	# fully accepted yet answers the RPC with {"ok": false} — the old
	# tick swallowed it with NO log. The tick must log it and keep
	# searching, not fail. A FRESH player id (as above): the pre-RPC
	# poll must find no match for this id, so the RPC actually runs.
	var sentC := await Friends.send_invite("user-nimal", "Nimal Perera", 100)
	_check("mock: invitefix pending group sent", bool(sentC.get("ok", false)))
	var gidC: String = sentC.get("group_id", "")
	var rpc_uid := Supabase.user_id
	Supabase.user_id = "33333333-4444-5555-6666-777777777777"
	Net.start_p2p_invite(gidC, Save.player_name, 1, 100, "2p", 0, true)
	await get_tree().create_timer(3.5).timeout
	_check("mock: invitefix RPC ok:false is survived (still searching)", Net._p2p_invite_searching)
	Net.cancel_p2p_search()
	Supabase.user_id = rpc_uid
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
	# --- v11 session restore: simulated restart (in-memory session
	# cleared, saved tokens kept) -> restore brings it back, rotated ---
	var saved_refresh := Save.session_refresh_token
	var saved_uid := Supabase.user_id
	_check("mock: a saved refresh token exists before the restart", saved_refresh != "" and saved_uid != "")
	Supabase.access_token = ""
	Supabase.user_id = ""
	Supabase.refresh_token = ""
	var restored := await Accounts.restore_session()
	_check("mock: saved session restores after a restart", bool(restored.get("ok", false)) and Supabase.user_id == saved_uid)
	_check("mock: refresh rotated the tokens", Supabase.access_token != "" and Supabase.access_token != "tok-" + saved_uid and Supabase.refresh_token == "ref-refreshed-" + saved_uid)
	_check("mock: rotated tokens persisted", Save.session_refresh_token == Supabase.refresh_token and Save.session_access_token == Supabase.access_token)
	_check("mock: restored account id is the Auth uid", Save.account_id == saved_uid)
	# --- Failed refresh: bad token -> needs sign-in, tokens cleared ---
	Save.session_refresh_token = "ref-no-such-user"
	Save.session_access_token = "tok-no-such-user"
	Save.save()
	Supabase.access_token = ""
	Supabase.user_id = ""
	Supabase.refresh_token = ""
	var bad := await Accounts.restore_session()
	_check("mock: bad refresh token fails the restore", not bool(bad.get("ok", false)))
	_check("mock: failed refresh needs sign-in again", Accounts.session_needs_sign_in())
	_check("mock: failed refresh clears the saved tokens", Save.session_refresh_token == "" and Save.session_access_token == "" and Supabase.user_id == "")
	# --- Restore with no saved session fails fast (no network) ---
	var none := await Accounts.restore_session()
	_check("mock: restore with no saved session fails fast", not bool(none.get("ok", false)))
	# --- v11 re-sign-in entry: the home screen carries a small SIGN OUT
	# button that emits sign_out_requested (Main signs out and shows
	# the auth screen again). Checked here, not in test_runner: in -s
	# script mode home.gd's first compile runs before the autoloads
	# register, so the Friends autoload is a bare Node and HomeScreen
	# _ready dies on Friends.invites_changed — in this scene the
	# autoloads are real, so the screen builds as on the phone. Placed
	# right after the failed-refresh checks: this is the exact moment
	# the player needs the button (lobby says "sign in again").
	var home = load("res://scripts/home.gd").new()
	add_child(home)
	var btn_texts: Array = []
	_collect_button_texts(home, btn_texts)
	_check("mock: home has a SIGN OUT button", "SIGN OUT" in btn_texts)
	_check("mock: sign-out button is visible", home._sign_out_button.visible)
	_check("mock: home has the sign_out_requested signal", home.has_signal("sign_out_requested"))
	var signout_seen := {"fired": false}
	home.sign_out_requested.connect(func() -> void: signout_seen["fired"] = true)
	home._sign_out_button.pressed.emit()
	_check("mock: pressing SIGN OUT emits sign_out_requested", bool(signout_seen["fired"]))
	home.queue_free()
	# --- Sign-out clears the saved session ---
	# (put a session back first so sign-out has something to clear)
	Save.session_refresh_token = saved_refresh
	Save.save()
	Supabase.access_token = "tok-" + saved_uid
	Supabase.user_id = saved_uid
	Supabase.refresh_token = saved_refresh
	Accounts.sign_out()
	_check("mock: sign-out clears the saved session", Save.session_refresh_token == "" and Save.session_access_token == "" and Supabase.refresh_token == "" and Supabase.user_id == "")
	_check("mock: sign-out clears the needs-sign-in flag", not Accounts.session_needs_sign_in())
	Friends.stop_listening()
	_finish()

## Test seam: toggle the mock's fresh-project OTP behaviour (reject
## OTP requests that carry redirect_to). Returns true on a 200.
func _set_otp_redirect_fail(enabled: bool) -> bool:
	var http := HTTPRequest.new()
	add_child(http)
	http.request(MOCK_URL + "/__test__/otp_redirect_fail", ["Content-Type: application/json"], HTTPClient.METHOD_POST, JSON.stringify({"enabled": enabled}))
	var res: Array = await http.request_completed
	http.queue_free()
	return int(res[1]) == 200

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
