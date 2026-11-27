extends Node

## Auth-flow + invite-box UI test (v9). Drives the REAL Main scene:
##   A1: with no account, Main opens the register/login screen FIRST
##       (registration is mandatory — no guest mode, no "Play as guest").
##   A2: no button anywhere offers guest play.
##   A4: the Google button is Google-styled (white, "Continue with
##       Google") and tapping it with no backend shows an error — never
##       silently nothing.
##   A5: the register screen is full (benefits panel + "No ads until you
##       play" present, footer "v9.0" sits at the bottom of the screen).
##   A6: the paste-code fallback row is hidden until a Google sign-in
##       is pending, then it appears.
##   A7: RESEND CODE exists (hidden until a code is sent).
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
	# A leftover pending browser return (e.g. the --shot=googlepending
	# run quits without cancelling it) would make _ready() show the
	# "Signing in with Google…" state instead of the plain auth screen
	# — clear it so the test is hermetic.
	Accounts.cancel_pending_return()
	# v9: force local-only so this test is hermetic — it must not depend
	# on backend_config.json (which is now a live, configured project)
	# or on the network. The cloud paths are covered by the mock test.
	Supabase.set_config("", "", "")
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

func _find_texture_with(root: Node, path_part: String) -> TextureRect:
	if root is TextureRect and (root as TextureRect).texture != null and (root as TextureRect).texture.resource_path.contains(path_part):
		return root
	for c in root.get_children():
		var found := _find_texture_with(c, path_part)
		if found:
			return found
	return null

func _run() -> void:
	await _frames(5)
	# --- A1/A2: auth first, no guest path ---
	_check("auth: auth screen shown first with no account", _main._auth != null)
	var guest_btn := _find_button_containing(_main, "GUEST")
	_check("auth: no guest-play button anywhere", guest_btn == null)
	# --- A4: Google button is Google-styled and never silently nothing ---
	var google_btn := _find_button(_main._auth, "Continue with Google")
	_check("auth: Google button says Continue with Google", google_btn != null)
	var gsb := google_btn.get_theme_stylebox("normal") if google_btn else null
	_check("auth: Google button is white (Google style)", gsb is StyleBoxFlat and (gsb as StyleBoxFlat).bg_color == Color.WHITE)
	google_btn.pressed.emit()
	await _frames(3)
	_check("auth: Google tap with no backend shows an error", _main._auth._error_label.text != "" and _main._auth._error_label.text.contains("not connected"))
	# --- A9 (auth fix, 2026-11-27): Google off hides the button ---
	# The new project has the Google provider OFF: the button must be
	# hidden and a note must point at Gmail + code, so the player never
	# lands on GoTrue's 400 "Unsupported provider" page.
	Supabase.google_enabled = false
	_main._show_auth()
	await _frames(3)
	var google_btn_off := _find_button(_main._auth, "Continue with Google")
	_check("auth: Google button hidden while the provider is off", google_btn_off != null and not google_btn_off.is_visible_in_tree())
	var gnote := _find_label_containing(_main._auth, "Google sign-in isn't set up yet")
	_check("auth: note points at Gmail + code while Google is off", gnote != null and gnote.is_visible_in_tree())
	Supabase.google_enabled = true
	_main._show_auth()
	await _frames(3)
	var google_btn_on := _find_button(_main._auth, "Continue with Google")
	_check("auth: Google button back when the provider is on", google_btn_on != null and google_btn_on.is_visible_in_tree())
	# --- A11 (Google sign-in, 2026-11-27): the dead "Create Your
	# Account" pill is gone — it did nothing when tapped, and REGISTER
	# is already there.
	_check("auth: dead Create Your Account pill is gone", _find_label_containing(_main._auth, "Create Your Account") == null)
	# --- A5: register screen is full (benefits + footer at the bottom) ---
	_check("auth: benefits panel present", _find_label_containing(_main._auth, "saved to your account forever") != null)
	_check("auth: free-to-play / no-ads line present", _find_label_containing(_main._auth, "No ads until you play") != null)
	var foot := _find_label_containing(_main._auth, "BMS Carrom 1.0")
	_check("auth: footer says 1.0", foot != null)
	var vp_y: float = _main.get_viewport_rect().size.y
	_check("auth: footer sits at the bottom of the screen (no dead space)", foot != null and foot.get_global_rect().end.y >= vp_y - 40.0)
	# --- A6: paste-code fallback row only while Google is pending ---
	var use_code := _find_button(_main._auth, "USE CODE")
	_check("auth: paste-code row hidden until Google is pending", use_code != null and not use_code.is_visible_in_tree())
	_main._auth._set_google_pending(true)
	await _frames(2)
	_check("auth: paste-code row appears while Google is pending", use_code.is_visible_in_tree())
	# Auth fix (2026-11-27): the recovery row (RETRY + CANCEL) shows
	# the moment a return is pending — not after 60 s — so a failed or
	# cancelled browser trip offers a way back at once.
	var retry_now := _find_button_containing(_main._auth, "RETRY GOOGLE SIGN-IN")
	_check("auth: recovery row shows at once while Google is pending", retry_now != null and retry_now.is_visible_in_tree())
	var cancel_now := _find_button_containing(_main._auth, "CANCEL")
	_check("auth: recovery row shows CANCEL at once too", cancel_now != null and cancel_now.is_visible_in_tree())
	_main._auth._set_google_pending(false)
	await _frames(2)
	_check("auth: paste-code row hides again when Google finishes", not use_code.is_visible_in_tree())
	# --- A8 (v10): recovery UI — if the browser never returns (dead
	# redirect), the player gets a RETRY button + the paste row, big and
	# clear, instead of a silent dead register screen. ---
	_main._auth.show_recovery_ui()
	await _frames(2)
	var retry := _find_button_containing(_main._auth, "RETRY GOOGLE SIGN-IN")
	_check("auth: recovery shows RETRY GOOGLE SIGN-IN", retry != null and retry.is_visible_in_tree())
	_check("auth: recovery keeps the paste-code row visible", use_code.is_visible_in_tree())
	var cancel := _find_button_containing(_main._auth, "CANCEL")
	_check("auth: recovery shows CANCEL — USE GMAIL + CODE", cancel != null and cancel.is_visible_in_tree())
	_main._auth._set_google_pending(false)
	await _frames(2)
	_check("auth: recovery hides again when Google finishes", retry != null and not retry.is_visible_in_tree())
	# --- A10 (auth fix): CANCEL drops a pending Google return ---
	# A real pending return (debug helper, as the screenshot mode
	# does), then CANCEL: the pending state ends and the Google button
	# comes back enabled — the player is never stuck on "Signing in
	# with Google…".
	Accounts.debug_begin_pending_return("google")
	_main._auth._set_google_pending(true)
	await _frames(2)
	var cancel2 := _find_button_containing(_main._auth, "CANCEL")
	_check("auth: CANCEL button present on a real pending return", cancel2 != null and cancel2.is_visible_in_tree())
	cancel2.pressed.emit()
	await _frames(2)
	_check("auth: CANCEL drops the pending Google return", not Accounts.is_return_pending())
	_check("auth: CANCEL brings the Google button back enabled", _main._auth._google_button != null and not _main._auth._google_button.disabled)
	# --- A12 (Google sign-in, 2026-11-27): the deep-link return file
	# is consumed. The Java side (GodotApp.onNewIntent / onCreate)
	# writes the browser-return URI to user://auth_callback.txt and
	# Accounts polls it while a return is pending. Simulate the Java
	# write: a pending return + the file with a code URI -> the file
	# is consumed (deleted) and the pending return ends. The code
	# exchange itself has no backend here, so it fails — the point is
	# the return is never left hanging on a file nobody reads.
	Accounts.debug_begin_pending_return("google")
	var cb := FileAccess.open(Supabase.AUTH_CALLBACK_FILE, FileAccess.WRITE)
	cb.store_string("com.musehiro.carrom://auth-callback?code=TESTCODE123&state=x")
	cb.close()
	Accounts._check_pending_callback_file()
	_check("auth: deep-link callback file is consumed", not FileAccess.file_exists(Supabase.AUTH_CALLBACK_FILE))
	_check("auth: pending return ends after the callback is consumed", not Accounts.is_return_pending())
	await _frames(3)
	# --- A7: RESEND CODE exists (hidden until a code is sent) ---
	_check("auth: RESEND CODE button exists", _main._auth._resend_button != null)
	_check("auth: RESEND CODE hidden until a code is sent", not _main._auth._resend_button.is_visible_in_tree())
	# --- L5 (v10): switching tabs keeps a pending code ---
	_main._auth._pending_gmail = "test.player@gmail.com"
	_main._auth._pending_allow_create = true
	_main._auth._code_row.visible = true
	_main._auth._code_edit.text = "123456"
	_main._auth._set_mode("signin")
	await _frames(2)
	_check("auth: tab switch keeps the pending code row", _main._auth._code_row.visible and _main._auth._pending_gmail == "test.player@gmail.com")
	_check("auth: tab switch keeps the typed code", _main._auth._code_edit.text == "123456")
	_check("auth: tab switch keeps the allow-create flag", _main._auth._pending_allow_create)
	_main._auth._set_mode("register")
	await _frames(2)
	_check("auth: switching back keeps the pending code too", _main._auth._code_row.visible and _main._auth._pending_gmail == "test.player@gmail.com")
	# Reset the faked pending state so the register step starts clean.
	_main._auth._pending_gmail = ""
	_main._auth._pending_allow_create = false
	_main._auth._code_row.visible = false
	_main._auth._code_edit.text = ""
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
			"status": "pending", "created_at": Time.get_datetime_string_from_system(true, false) + "+00:00"},
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
	# --- I2: ACCEPT -> stake picker (F1: the Supabase accept must
	# succeed first). No backend is configured in this test, so the
	# accept fails and the picker must NOT open — the flow stops
	# instead of joining a match the inviter can never start.
	var accept := _find_button(_main._home._invite_panel, "ACCEPT")
	accept.pressed.emit()
	await _frames(5)
	_check("invitebox: failed accept does not open the stake picker", _find_button_containing(_main, "FIND OPPONENT") == null)
	# The same invite, already accepted (e.g. a re-delivered row): the
	# double-accept path skips the PATCH and the picker opens.
	Friends.incoming[0]["status"] = "accepted"
	_main._home._toggle_invite_box()
	await _frames(5)
	accept = _find_button(_main._home._invite_panel, "ACCEPT")
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
	# --- L6 (auth fix, 2026-11-27): the loading screen is the new look ---
	# Wood background, BMS crown logo, mini board, and a gold bar that
	# fills with real progress — not the old teal screen with dots.
	_main._show_loading("LOADING GAME", "Starting…")
	var ls = _main._loading
	_check("loading: screen is shown", ls != null)
	_check("loading: bar starts at 0 on a fresh screen", ls._bar.value == 0.0)
	await _frames(2)
	ls._process(0.6)
	_check("loading: bar auto-advances over the 1.2 s wait", ls._bar.value >= 50.0)
	ls.set_progress(0.5)
	_check("loading: bar shows real progress (50%)", ls._bar.value == 50.0)
	ls.set_progress(1.0)
	_check("loading: bar reaches 100", ls._bar.value == 100.0)
	ls.set_progress(2.0)
	_check("loading: progress clamps at 100%", ls._bar.value == 100.0)
	ls.set_progress(-1.0)
	_check("loading: progress clamps at 0%", ls._bar.value == 0.0)
	ls.set_status("Restoring your sign-in…")
	_check("loading: status text updates", ls._status.text == "Restoring your sign-in…")
	_check("loading: BMS crown logo is shown", _find_texture_with(ls, "logo_carrom_loading.png") != null)
	_check("loading: wood background is shown", _find_texture_with(ls, "bg_home_wood.jpg") != null)
	_check("loading: mini board has the full 20-piece setup", ls._mini != null and ls._mini.pieces.size() == 20)
	_done = true
	print("=== auth flow test: %d passed, %d failed ===" % [_passed, _failed])
	get_tree().quit(0 if _failed == 0 else 1)
