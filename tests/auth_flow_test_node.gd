extends Node

## Auth-flow + invite-box UI test (v7). Drives the REAL Main scene:
##   A1: with no account, Main opens the register/login screen FIRST
##       (registration is mandatory — no guest mode, no "Play as guest").
##   A2: no button anywhere offers guest play.
##   A3: registering (name + Gmail, local-only — no backend here)
##       reaches the home screen.
##   I1: the invite box opens from the ✉ button and shows an incoming
##       invite with ACCEPT / DECLINE.
##   I2: ACCEPT opens the stake picker (choose YOUR stake, then join).
##   I3: tapping 4P on a search result selects it for a 4-player
##       invite and the SEND 4-PLAYER INVITE button appears.
## Run headless: xvfb-run -a godot --headless --path . res://tests/auth_flow_test.tscn
## Exit 0 = all pass, 1 = any fail.

var _passed := 0
var _failed := 0
var _main = null
var _done := false
var _wait := 0.0

func _ready() -> void:
	# Start with NO account so the auth-first rule is exercised.
	Save.account_gmail = ""
	Save.account_id = ""
	Save.account_verified = false
	Save.account_created_at = ""
	Save.account_synced_at = 0
	Save.player_name = "Player"
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
		print("[AuthFlowTest] TIMEOUT")
		_done = true
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

func _find_button(root: Node, text: String) -> Button:
	if root is Button and (root as Button).text == text:
		return root
	for c in root.get_children():
		var found := _find_button(c, text)
		if found:
			return found
	return null

func _find_button_containing(root: Node, text: String) -> Button:
	if root is Button and (root as Button).text.contains(text):
		return root
	for c in root.get_children():
		var found := _find_button_containing(c, text)
		if found:
			return found
	return null

func _find_label_containing(root: Node, text: String) -> Label:
	if root is Label and (root as Label).text.contains(text):
		return root
	for c in root.get_children():
		var found := _find_label_containing(c, text)
		if found:
			return found
	return null

func _run() -> void:
	await _frames(5)
	# --- A1/A2: auth first, no guest path ---
	_check("auth: auth screen shown first with no account", _main._auth != null)
	var guest_btn := _find_button_containing(_main, "GUEST")
	_check("auth: no guest-play button anywhere", guest_btn == null)
	# --- A3: register -> home ---
	_main._auth._name_edit.text = "Test Player"
	_main._auth._gmail_edit.text = "test.player@gmail.com"
	_main._auth._on_action_pressed()
	await _frames(5)
	_check("auth: home shown after register", _main._home != null and _main._auth == null)
	_check("auth: account saved locally", Accounts.has_account() and Save.account_gmail == "test.player@gmail.com")
	# --- I1: invite box opens with an incoming invite ---
	Friends.incoming = [
		{"id": "inv-1", "group_id": "grp-1", "from_id": "p-nimal", "to_id": "me",
			"from_name": "Nimal", "to_name": "Test Player", "mode": "2p", "stake": 100,
			"status": "pending", "created_at": "2026-11-22T13:00:00+00:00"},
	]
	Friends.outgoing = []
	_main._home._search_results = [
		{"id": "p-saman", "display_name": "Saman", "level": 5},
	]
	_main._home._toggle_invite_box()
	await _frames(5)
	_check("invitebox: panel opens", _main._home._invite_panel != null)
	_check("invitebox: incoming invite shown", _find_label_containing(_main._home._invite_panel, "Nimal") != null)
	_check("invitebox: ACCEPT button shown", _find_button(_main._home._invite_panel, "ACCEPT") != null)
	_check("invitebox: DECLINE button shown", _find_button(_main._home._invite_panel, "DECLINE") != null)
	# --- I2: ACCEPT -> stake picker ---
	var accept := _find_button(_main._home._invite_panel, "ACCEPT")
	accept.pressed.emit()
	await _frames(5)
	_check("invitebox: accept opens the stake picker", _find_button_containing(_main, "FIND OPPONENT") != null)
	# Close the picker with its X so the next step starts clean.
	var x := _find_button(_main, "✕")
	if x:
		x.pressed.emit()
	await _frames(3)
	# --- I3: 4P selection -> SEND 4-PLAYER INVITE ---
	_main._home._toggle_invite_box()
	await _frames(5)
	var four_p := _find_button(_main._home._invite_panel, "4P")
	_check("invitebox: 4P button shown on a search result", four_p != null)
	four_p.pressed.emit()
	await _frames(5)
	_check("invitebox: SEND 4-PLAYER INVITE appears after selecting", _find_button_containing(_main._home._invite_panel, "SEND 4-PLAYER INVITE") != null)
	# Clean up: close the box, clear the canned invites.
	_main._home._toggle_invite_box()
	Friends.incoming = []
	Friends.outgoing = []
	_done = true
	print("=== auth flow test: %d passed, %d failed ===" % [_passed, _failed])
	get_tree().quit(0 if _failed == 0 else 1)
