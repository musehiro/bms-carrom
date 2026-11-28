extends Node

## Stuck-search-popup test (round 4, incident 2026-11-28 05:18).
## The WAITING FOR PLAYERS popup froze at "0s" with dead CANCEL/X:
## _join_invite_room created a SECOND search popup without closing
## the random-search popup, so _searching pointed at the new one and
## the VISIBLE (old) one was orphaned — its timer never advanced and
## its CANCEL/X freed the hidden one.
##
## Reproduces the incident sequence on Main with the mock backend:
##   1. random search (2 PLAYERS) -> 1 popup, timer advancing
##   2. _on_group_ready fires for an old accepted group (stake 500)
##      while the random search is still running -> still exactly
##      1 popup (the invite one), timer advancing
##   3. CANCEL -> 0 popups
##   4. watchdog: orphan a popup (visible, no active search) -> the
##      watchdog force-closes it within ~1 s
## On unfixed code step 2 leaves 2 popups, step 3 leaves 1 orphan,
## and step 4 never closes anything.
## Run: godot --headless --path . --resolution 720x1280
##      res://tests/search_popup_stuck_test.tscn
## Exit 0 = all pass, 1 = any fail.

const MOCK_PORT := 18080
const MOCK_URL := "http://127.0.0.1:18080"

var _passed := 0
var _failed := 0
var _main = null
var _done := false
var _wait := 0.0
var _mock_pid := 0

func _ready() -> void:
	# Seed a test account so Main reaches the home screen instead of
	# the auth screen (same as popup_double_test).
	Save.account_gmail = "test.player@gmail.com"
	Save.account_id = "test-account-id"
	Save.account_verified = true
	Save.player_name = "Test Player"
	Save.coins = 1000
	Save.save()
	var main_scene: PackedScene = load("res://scenes/main.tscn")
	_main = main_scene.instantiate()
	add_child(_main)
	_run()

func _process(delta: float) -> void:
	if _done:
		return
	_wait += delta
	if _wait > 60.0:
		print("[SearchPopupStuckTest] TIMEOUT")
		_done = true
		if _mock_pid > 0:
			OS.kill(_mock_pid)
		get_tree().quit(1)

func _frames(n: int) -> void:
	for i in range(n):
		await get_tree().process_frame

func _check(test_name: String, cond: bool, detail: String = "") -> void:
	if cond:
		_passed += 1
		print("PASS: ", test_name)
	else:
		_failed += 1
		print("FAIL: ", test_name, (" — " + detail if detail != "" else ""))

## Count the VISIBLE search popups by their title label text — an
## independent count, not the code's own _count_search_popups().
func _count_visible_search_popups(node: Node) -> int:
	var n := 0
	if node is Label:
		var t := String((node as Label).text)
		if t == "WAITING FOR PLAYERS" or t == "FINDING OPPONENT":
			n += 1
	for c in node.get_children():
		n += _count_visible_search_popups(c)
	return n

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

func _run() -> void:
	# Main shows the loading screen first (session restore + the
	# 1.5 s minimum bar pace) — wait for home with a deadline, not
	# a fixed frame count. (The old 5-frame wait fails in headless:
	# popup_double_test fails the same way here.)
	var home_deadline := Time.get_unix_time_from_system() + 15.0
	while _main._home == null and Time.get_unix_time_from_system() < home_deadline:
		await get_tree().process_frame
	_check("home shown", _main._home != null)
	if _main._home == null:
		_finish()
		return
	# Backend: the mock Supabase server (same as the mock test node).
	# _start_matchmaking fails fast via queue_failed when Supabase is
	# not configured, so the mock IS required for this test.
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
	var anon := await Supabase.signup_anonymous()
	_check("mock: anonymous signup gives a user id", bool(anon.get("ok", false)) and Supabase.user_id != "")
	if Supabase.user_id == "":
		_finish()
		return
	Save.account_id = Supabase.user_id
	Save.save()

	# --- Step 1: random search -> exactly 1 popup, timer advancing.
	_main._start_matchmaking(100, "", 2)
	await get_tree().create_timer(1.0).timeout
	_check("random search shows exactly 1 popup", _count_visible_search_popups(_main) == 1, str(_count_visible_search_popups(_main)))
	_check("random search timer advances", _main._search_elapsed > 0.5, str(_main._search_elapsed))

	# --- Step 2: an old accepted group fires while the random search
	# is still running (the incident) -> still exactly 1 popup, and
	# it is the invite one; the random popup must be GONE.
	_main._on_group_ready("old-group-test", [{"stake": 500, "mode": "2p", "id": "x"}])
	await get_tree().create_timer(0.5).timeout
	_check("invite re-fire leaves exactly 1 popup", _count_visible_search_popups(_main) == 1, str(_count_visible_search_popups(_main)))
	_check("invite popup replaced the random one", _main._search_mode == "invite" and _main._searching_active)
	_check("invite search timer advances", _main._search_elapsed > 0.2, str(_main._search_elapsed))
	await get_tree().create_timer(1.0).timeout
	_check("invite popup still exactly 1 after a second", _count_visible_search_popups(_main) == 1, str(_count_visible_search_popups(_main)))

	# --- Step 3: CANCEL closes the VISIBLE popup (not a hidden one).
	_main._cancel_search()
	await get_tree().create_timer(0.5).timeout
	_check("CANCEL leaves 0 popups", _count_visible_search_popups(_main) == 0, str(_count_visible_search_popups(_main)))
	_check("CANCEL clears the search state", not _main._searching_active and _main._searching == null)

	# --- Step 4: watchdog — orphan a popup (visible, no active
	# search, timer frozen) and the watchdog must force-close it.
	_main._start_matchmaking(100, "", 2)
	await get_tree().create_timer(0.5).timeout
	_check("watchdog setup: 1 popup before orphaning", _count_visible_search_popups(_main) == 1, str(_count_visible_search_popups(_main)))
	_main._searching = null # simulate the orphan: the popup is still
	_main._searching_active = false # a child of _home, but nothing references it
	await get_tree().create_timer(1.5).timeout
	_check("watchdog force-closes the orphaned popup", _count_visible_search_popups(_main) == 0, str(_count_visible_search_popups(_main)))
	_finish()

func _fail(test_name: String) -> void:
	_failed += 1
	print("FAIL: ", test_name)

func _finish() -> void:
	_done = true
	if _mock_pid > 0:
		OS.kill(_mock_pid)
	print("=== search popup stuck test: %d passed, %d failed ===" % [_passed, _failed])
	get_tree().quit(0 if _failed == 0 else 1)
