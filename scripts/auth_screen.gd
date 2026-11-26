class_name AuthScreen
extends Control

## Register / sign-in screen (v9 redesign). The FIRST screen of the game:
## registration is mandatory — a player cannot play without an account
## (Buddhika, 2026-11-22: otherwise players lose their progress when
## they reinstall). There is no guest mode and no "play as guest" path.
##
## Look (v9, Buddhika 2026-11-22): a premium, distinctive design of our
## own — deep emerald felt (the carrom-table felt) fading to near-black
## green, a soft gold glow behind a large board-only logo, gold accents
## and cream text. The Google button stays in Google's own style
## (white, the four-colour "G", "Continue with Google"). The bottom of
## the screen is filled with what registration saves + "Free to play •
## No ads until you play" — no dead space on 720x1280 or 720x1640.
##
## Two tabs:
##   REGISTER — display name + Gmail -> REGISTER & PLAY. When Supabase
##     is configured, a 6-digit code is sent to the Gmail and the
##     player verifies it here (VERIFY button, RESEND CODE with a 60 s
##     cooldown, "check Spam" hint); "Verify later" keeps playing with
##     an unverified account — the Gmail can be proven later from the
##     profile. When Supabase is NOT configured yet, registration is
##     local-only and the player goes straight in.
##   SIGN IN — Gmail -> SEND CODE -> 6-digit code -> VERIFY & SIGN IN.
##     Restores coins, level, XP, stats and shop ownership from the
##     cloud profile for that Gmail.
##   CONTINUE WITH GOOGLE — one-tap (PKCE). Tap -> the system browser
##     opens the Google account picker -> tap an account -> registered,
##     nothing typed. The browser returns via the custom-scheme deep link
##     on Android (v11 PRIMARY — intent filter + GodotApp.onNewIntent)
##     and via the 127.0.0.1 loopback listener on desktop/editor; a
##     paste-the-code row covers the case where the automatic return
##     fails, and the moment a return is pending a recovery row offers
##     RETRY (open Google again) and CANCEL (back to Gmail + code), so
##     a failed or cancelled browser trip never leaves the player stuck
##     on "Signing in with Google…"; after ~60 s an explanatory message
##     is added too. Every failure shows an error — never silently
##     nothing. While the project's Google provider is OFF
##     (google_enabled false in backend_config.json — the new project,
##     2026-11-27), the button is hidden and a note points at Gmail +
##     code instead. The OTP email's "Sign in" link uses the same
##     platform return, so tapping it signs the player in — the 6-digit
##     code stays the primary path.
##
## The logo is JUST the carrom board (BoardView, no text — logo rule).

signal registered
signal signed_in

## The Google "G" in its four colours, drawn with arcs + the blue bar.
class GoogleGIcon extends Control:
	func _ready() -> void:
		custom_minimum_size = Vector2(36, 36)
		mouse_filter = Control.MOUSE_FILTER_IGNORE

	func _draw() -> void:
		var c := size * 0.5
		var r := minf(size.x, size.y) * 0.5 - 1.5
		var w := r * 0.38
		# Clockwise from the top: red (top), blue (right), green
		# (bottom-right), yellow (bottom-left).
		draw_arc(c, r, deg_to_rad(-155), deg_to_rad(-25), 32, Color(0.92, 0.26, 0.21), w, true)
		draw_arc(c, r, deg_to_rad(-25), deg_to_rad(45), 24, Color(0.26, 0.51, 0.96), w, true)
		draw_arc(c, r, deg_to_rad(45), deg_to_rad(135), 24, Color(0.20, 0.66, 0.33), w, true)
		draw_arc(c, r, deg_to_rad(135), deg_to_rad(205), 24, Color(0.98, 0.74, 0.04), w, true)
		# The blue bar from the centre to the right edge.
		draw_rect(Rect2(c.x - 1.0, c.y - w * 0.5, r + 1.0, w), Color(0.26, 0.51, 0.96))

var _mode := "register" # register | signin
var _name_edit: LineEdit
var _gmail_edit: LineEdit
var _code_edit: LineEdit
var _paste_edit: LineEdit
var _error_label: Label
var _info_label: Label
var _action_button: Button
var _code_button: Button
var _resend_button: Button
var _google_button: Button
var _google_note: Label # shown instead of the button while the
## project's Google provider is off (google_enabled false)
var _scroll: ScrollContainer # the scrollable content — the recovery
## row is scrolled into view the moment a return is pending
var _verify_later_button: Button
var _code_row: VBoxContainer
var _paste_row: VBoxContainer
var _recovery_row: VBoxContainer # v10: RETRY + CANCEL + help, shown
## the moment a Google return is pending (not after 60 s)
var _recovery_shown := false
var _scroll_to_recovery := false # scroll the recovery row into view
## on the next frame (after the layout settles — a deferred call in
## _set_google_pending runs before the VBox re-sorts, so it scrolls
## to the row's old zero-size rect and nothing moves)
var _pending_gmail := ""
var _pending_allow_create := false # the pending code was sent from the REGISTER tab (verify may create the cloud profile) or SIGN IN (must already exist) — tied to how the code was sent, not to the tab showing now
var _busy := false
var _google_pending := false
var _resend_timer: Timer
var _resend_cooldown := 0

## v10 recovery: if a Google sign-in is still pending after ~60 s the
## browser probably did not come back — show RETRY + the paste row
## prominently instead of leaving the player on a dead screen.
func _process(_delta: float) -> void:
	if _google_pending and not _recovery_shown and Accounts.google_pending_elapsed() > 60.0:
		show_recovery_ui()
	if _scroll_to_recovery and _recovery_row and _recovery_row.visible:
		_scroll_to_recovery = false
		if _scroll:
			_scroll.ensure_control_visible(_recovery_row)

## Show the recovery panel (also called directly by the screenshot
## mode and the auth-flow test). Public on purpose.
func show_recovery_ui() -> void:
	_recovery_shown = true
	# The paste row is part of the recovery: RETRY + the code row, both
	# prominent, so the player is never stuck on a dead screen.
	_set_google_pending(true)
	if _recovery_row:
		_recovery_row.visible = true
	_set_message(_info_label, "Still waiting for Google? The browser sometimes doesn't come back to the game — tap RETRY below, or copy the code from your browser's address bar (the part after code=) and paste it here.")

func _ready() -> void:
	UiKit.full_rect(self)
	# ---- Green foliage background (premium redesign): the photo
	# carries the look now — deep green leaves, sunbeams, sparkles.
	var bg := TextureRect.new()
	bg.texture = preload("res://art/bg_auth_green.jpg")
	bg.expand_mode = TextureRect.EXPAND_IGNORE_SIZE
	bg.stretch_mode = TextureRect.STRETCH_SCALE
	bg.mouse_filter = Control.MOUSE_FILTER_IGNORE
	UiKit.full_rect(bg)
	add_child(bg)
	# ---- Scrollable content (fills the screen; scrolls only when the
	# code row is open on a short screen) ----
	var vp := get_viewport_rect().size
	var content_w := vp.x - 48.0
	var scroll := ScrollContainer.new()
	_scroll = scroll
	scroll.horizontal_scroll_mode = ScrollContainer.SCROLL_MODE_DISABLED
	scroll.vertical_scroll_mode = ScrollContainer.SCROLL_MODE_AUTO
	scroll.follow_focus = true
	UiKit.full_rect(scroll)
	scroll.offset_left = 24
	scroll.offset_right = -24
	scroll.offset_top = 24
	scroll.offset_bottom = -24
	add_child(scroll)
	var root := VBoxContainer.new()
	root.custom_minimum_size = Vector2(content_w, vp.y - 48.0)
	root.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	root.add_theme_constant_override("separation", clampf((vp.y - 1150.0) / 12.0, 12.0, 32.0))
	scroll.add_child(root)
	# ---- Logo: the golden crown "BMS CARROM" + "PLAY & ENJOY" ribbon
	# (the same artwork family as the loading screen and home — the
	# auth screen must look like the same game, not a different one).
	# Full content width; the image is 1200x1140, so it keeps its
	# aspect and the scroll layout absorbs any height.
	var logo := TextureRect.new()
	logo.texture = preload("res://art/logo_carrom_loading.png")
	logo.expand_mode = TextureRect.EXPAND_IGNORE_SIZE
	logo.stretch_mode = TextureRect.STRETCH_SCALE
	logo.custom_minimum_size = Vector2(content_w, content_w * 1140.0 / 1200.0)
	logo.mouse_filter = Control.MOUSE_FILTER_IGNORE
	root.add_child(logo)
	# ---- Why register ----
	var why := UiKit.muted_label("Register once — your coins, level and shop items are saved to your account, so they come back even if you delete the app and reinstall.", 18)
	why.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	why.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	why.add_theme_color_override("font_color", Color(0.96, 0.95, 0.92))
	root.add_child(why)
	# ---- "Create Your Account" header pill (reference welcome screen).
	# No emoji glyph — the bundled fonts carry no emoji, so the pill is
	# text only (an emoji would render as an empty box).
	var create_pill := PanelContainer.new()
	create_pill.add_theme_stylebox_override("panel", UiKit.panel_style(Color(0.05, 0.35, 0.22, 0.97), UiKit.GOLD, 20, 2))
	var create_label := Label.new()
	create_label.text = "Create Your Account"
	create_label.add_theme_font_size_override("font_size", 26)
	create_label.add_theme_color_override("font_color", Color(0.96, 0.95, 0.92))
	create_label.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	create_pill.add_child(create_label)
	root.add_child(create_pill)
	# ---- Google (first — the way most players sign in) ----
	_google_button = _make_google_button()
	root.add_child(_google_button)
	# While the project's Google provider is OFF (google_enabled false
	# in backend_config.json — the new project, 2026-11-27), the button
	# is hidden and this note points at Gmail + code instead: opening
	# the authorize URL would land the player on GoTrue's 400
	# "Unsupported provider" page with no way back into the game.
	_google_note = UiKit.muted_label("Google sign-in isn't set up yet —\nregister with your Gmail + code below.", 17)
	_google_note.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	_google_note.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	_google_note.add_theme_color_override("font_color", Color(0.96, 0.95, 0.92))
	root.add_child(_google_note)
	_apply_google_availability()
	Accounts.google_finished.connect(_on_google_finished)
	# ---- Divider ----
	var divider := UiKit.muted_label("—  or continue with Gmail  —", 16)
	divider.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	root.add_child(divider)
	# ---- Tabs ----
	var tabs := HBoxContainer.new()
	tabs.add_theme_constant_override("separation", 10)
	root.add_child(tabs)
	var reg_tab := UiKit.gold_button("REGISTER", 24)
	reg_tab.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	reg_tab.pressed.connect(func() -> void: _set_mode("register"))
	tabs.add_child(reg_tab)
	var sign_tab := UiKit.dark_button("SIGN IN", 24)
	sign_tab.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	sign_tab.pressed.connect(func() -> void: _set_mode("signin"))
	tabs.add_child(sign_tab)
	# ---- Fields ----
	_name_edit = _field("Your name (shown to other players)")
	root.add_child(_name_edit)
	_gmail_edit = _field("Your Gmail address (…@gmail.com)")
	root.add_child(_gmail_edit)
	# ---- Code row (hidden until a code is sent) ----
	_code_row = VBoxContainer.new()
	_code_row.add_theme_constant_override("separation", 8)
	_code_row.visible = false
	root.add_child(_code_row)
	_code_edit = _field("6-digit code from your Gmail")
	_code_edit.max_length = 6
	_code_row.add_child(_code_edit)
	_code_button = UiKit.dark_button("VERIFY CODE", 24)
	_code_button.custom_minimum_size = Vector2(0, 60)
	_code_button.pressed.connect(_on_verify_code_pressed)
	_code_row.add_child(_code_button)
	var resend_hbox := HBoxContainer.new()
	resend_hbox.add_theme_constant_override("separation", 10)
	_code_row.add_child(resend_hbox)
	_resend_button = UiKit.dark_button("RESEND CODE", 20)
	_resend_button.custom_minimum_size = Vector2(0, 48)
	_resend_button.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	_resend_button.pressed.connect(_on_resend_pressed)
	resend_hbox.add_child(_resend_button)
	_verify_later_button = UiKit.dark_button("Verify later — play now", 20)
	_verify_later_button.custom_minimum_size = Vector2(0, 48)
	_verify_later_button.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	_verify_later_button.pressed.connect(func() -> void: registered.emit())
	resend_hbox.add_child(_verify_later_button)
	var spam_hint := UiKit.muted_label("The code can take a minute to arrive — check your Spam folder too.", 16)
	spam_hint.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	spam_hint.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	_code_row.add_child(spam_hint)
	# ---- Action ----
	_action_button = UiKit.green_button("REGISTER & PLAY", 28)
	_action_button.custom_minimum_size = Vector2(0, 68)
	_action_button.pressed.connect(_on_action_pressed)
	root.add_child(_action_button)
	# ---- Paste-code fallback (only while a Google sign-in is pending) ----
	# v10: BIG and prominent — this is the lifeline when the browser
	# does not return. The hint tells the player exactly where the
	# code is (the browser address bar, after code=).
	_paste_row = VBoxContainer.new()
	_paste_row.add_theme_constant_override("separation", 8)
	_paste_row.visible = false
	root.add_child(_paste_row)
	var paste_hint := UiKit.muted_label("Google taking too long? Paste the code from your browser address bar (the part after code=):", 20)
	paste_hint.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	paste_hint.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	paste_hint.add_theme_color_override("font_color", Color(0.96, 0.95, 0.92))
	_paste_row.add_child(paste_hint)
	var paste_hbox := HBoxContainer.new()
	paste_hbox.add_theme_constant_override("separation", 10)
	_paste_row.add_child(paste_hbox)
	_paste_edit = _field("Paste the code or the link here")
	_paste_edit.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	_paste_edit.custom_minimum_size = Vector2(0, 68)
	paste_hbox.add_child(_paste_edit)
	var use_code := UiKit.dark_button("USE CODE", 24)
	use_code.custom_minimum_size = Vector2(170, 68)
	use_code.pressed.connect(_on_use_pasted_code_pressed)
	paste_hbox.add_child(use_code)
	# ---- Recovery row (v10, shown the moment a Google return is
	# pending — not after 60 s: a failed or cancelled browser return
	# must offer a way back at once, never a dead screen) ----
	_recovery_row = VBoxContainer.new()
	_recovery_row.add_theme_constant_override("separation", 10)
	_recovery_row.visible = false
	root.add_child(_recovery_row)
	var retry := UiKit.gold_button("↻  RETRY GOOGLE SIGN-IN", 26)
	retry.custom_minimum_size = Vector2(0, 68)
	retry.pressed.connect(_on_google_retry_pressed)
	_recovery_row.add_child(retry)
	var cancel := UiKit.dark_button("✕  CANCEL — USE GMAIL + CODE", 22)
	cancel.custom_minimum_size = Vector2(0, 60)
	cancel.pressed.connect(_on_google_cancel_pressed)
	_recovery_row.add_child(cancel)
	# ---- Messages ----
	_error_label = Label.new()
	_error_label.add_theme_font_size_override("font_size", 18)
	_error_label.add_theme_color_override("font_color", UiKit.RED)
	_error_label.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	_error_label.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	_error_label.visible = false
	root.add_child(_error_label)
	_info_label = UiKit.muted_label("", 17)
	_info_label.visible = false
	_info_label.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	_info_label.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	root.add_child(_info_label)
	# ---- Spacer: pushes the benefits panel to the bottom on tall screens ----
	var spacer := Control.new()
	spacer.size_flags_vertical = Control.SIZE_EXPAND_FILL
	spacer.mouse_filter = Control.MOUSE_FILTER_IGNORE
	root.add_child(spacer)
	# ---- What registration saves (fills the bottom — no dead space) ----
	var benefits := PanelContainer.new()
	var bstyle := StyleBoxFlat.new()
	bstyle.bg_color = Color(0.06, 0.30, 0.25, 0.96)
	bstyle.border_color = Color(0.83, 0.69, 0.22, 0.55)
	bstyle.set_border_width_all(1)
	bstyle.set_corner_radius_all(16)
	bstyle.content_margin_left = 18
	bstyle.content_margin_right = 18
	bstyle.content_margin_top = 14
	bstyle.content_margin_bottom = 14
	benefits.add_theme_stylebox_override("panel", bstyle)
	root.add_child(benefits)
	var bcols := VBoxContainer.new()
	bcols.add_theme_constant_override("separation", 10)
	benefits.add_child(bcols)
	bcols.add_child(_benefit_row("◉", "1,000 starting coins — saved to your account forever"))
	bcols.add_child(_benefit_row("★", "Level, XP and match stats — never lost, even after reinstall"))
	bcols.add_child(_benefit_row("◆", "Boards & strikers you own — always yours"))
	var free := UiKit.muted_label("Free to play  •  No ads until you play", 17)
	free.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	free.add_theme_color_override("font_color", UiKit.GOLD_LIGHT)
	bcols.add_child(free)
	# P2-1: version from the single HomeScreen.APP_VERSION constant
	# ("1.0" — the APK's real version), never a hardcoded string.
	var foot := UiKit.muted_label("BMS Carrom " + HomeScreen.APP_VERSION + " • Account required • Free to play", 16)
	foot.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	root.add_child(foot)
	# Resend cooldown timer.
	_resend_timer = Timer.new()
	_resend_timer.wait_time = 1.0
	_resend_timer.timeout.connect(_on_resend_tick)
	add_child(_resend_timer)
	Accounts.otp_link_finished.connect(_on_otp_link_finished)
	# v11 P0-3: the loopback listener failed to start while a browser
	# return was pending — surface it in the UI (see
	# _on_return_listener_failed) instead of a dead screen.
	Accounts.return_listener_failed.connect(_on_return_listener_failed)
	_set_mode("register")
	# A Google sign-in may already be pending (cold start after the
	# browser opened): show the pending state, not a blank screen.
	if Accounts.is_google_pending():
		_set_google_pending(true)
		_set_message(_info_label, "Finishing your Google sign-in — one moment…")
	# v11 P0-3: the loopback restart may already have failed before
	# this screen existed (cold start) — surface it now; the signal
	# above only covers failures after this screen connects.
	if Accounts.loopback_listener_error() != "":
		_on_return_listener_failed(Accounts.loopback_listener_error())

func _logo_pieces() -> Array:
	var pieces: Array = []
	pieces.append(CarromPhysics.make_piece("queen", CarromPhysics.BOARD_CENTER))
	pieces.append(CarromPhysics.make_piece("white", Vector2(240, 450)))
	pieces.append(CarromPhysics.make_piece("black", Vector2(480, 720)))
	pieces.append(CarromPhysics.make_piece("striker", Vector2(CarromPhysics.BOARD_CENTER.x, CarromPhysics.baseline_y(0))))
	return pieces

func _field(placeholder: String) -> LineEdit:
	var e := LineEdit.new()
	e.placeholder_text = placeholder
	e.add_theme_font_size_override("font_size", 24)
	e.add_theme_color_override("font_color", Color(0.96, 0.95, 0.92))
	e.custom_minimum_size = Vector2(0, 62)
	var normal := StyleBoxFlat.new()
	normal.bg_color = Color(0.08, 0.26, 0.21)
	normal.border_color = UiKit.GOLD
	normal.set_border_width_all(2)
	normal.set_corner_radius_all(12)
	normal.content_margin_left = 14
	normal.content_margin_right = 14
	e.add_theme_stylebox_override("normal", normal)
	var focus := normal.duplicate()
	focus.border_color = UiKit.GOLD_LIGHT
	e.add_theme_stylebox_override("focus", focus)
	return e

## Google-style button: white, dark text, the four-colour "G" at the left.
func _make_google_button() -> Button:
	var b := Button.new()
	b.text = "Continue with Google"
	b.custom_minimum_size = Vector2(0, 64)
	b.add_theme_font_size_override("font_size", 24)
	b.add_theme_color_override("font_color", Color(0.12, 0.12, 0.12))
	b.add_theme_color_override("font_hover_color", Color(0.12, 0.12, 0.12))
	b.add_theme_color_override("font_pressed_color", Color(0.12, 0.12, 0.12))
	b.add_theme_color_override("font_disabled_color", Color(0.45, 0.45, 0.45))
	var normal := StyleBoxFlat.new()
	normal.bg_color = Color.WHITE
	normal.set_corner_radius_all(16)
	normal.border_color = Color(0.85, 0.85, 0.85)
	normal.set_border_width_all(1)
	normal.content_margin_top = 12
	normal.content_margin_bottom = 12
	var hover := normal.duplicate()
	hover.bg_color = Color(0.97, 0.98, 0.99)
	var pressed := normal.duplicate()
	pressed.bg_color = Color(0.94, 0.95, 0.96)
	var disabled := normal.duplicate()
	disabled.bg_color = Color(0.95, 0.95, 0.95)
	b.add_theme_stylebox_override("normal", normal)
	b.add_theme_stylebox_override("hover", hover)
	b.add_theme_stylebox_override("pressed", pressed)
	b.add_theme_stylebox_override("disabled", disabled)
	b.add_theme_stylebox_override("focus", StyleBoxEmpty.new())
	b.pressed.connect(_on_google_pressed)
	var gicon := GoogleGIcon.new()
	gicon.position = Vector2(20, 14)
	gicon.size = Vector2(36, 36)
	b.add_child(gicon)
	return b

func _benefit_row(glyph: String, text: String) -> HBoxContainer:
	var row := HBoxContainer.new()
	row.add_theme_constant_override("separation", 12)
	var g := Label.new()
	g.text = glyph
	g.add_theme_font_size_override("font_size", 20)
	g.add_theme_color_override("font_color", UiKit.GOLD_LIGHT)
	row.add_child(g)
	var t := Label.new()
	t.text = text
	t.add_theme_font_size_override("font_size", 18)
	t.add_theme_color_override("font_color", Color(0.96, 0.95, 0.92))
	t.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	t.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	row.add_child(t)
	return row

## Set a message label's text; an empty message hides the label so it
## takes no space (on a 1280 px screen every line counts).
func _set_message(label: Label, text: String) -> void:
	label.text = text
	label.visible = text != ""

func _set_mode(mode: String) -> void:
	_mode = mode
	_set_message(_error_label, "")
	_set_message(_info_label, "")
	# L5: switching tabs must NOT discard a pending code — the code row,
	# the pending Gmail, the resend cooldown and the allow-create flag
	# all survive the switch, so a code sent on one tab can still be
	# verified on the other. Only the tab-specific bits change.
	_name_edit.visible = mode == "register"
	_verify_later_button.visible = mode == "register" and _code_row.visible and _pending_allow_create
	if mode == "register":
		_action_button.text = "REGISTER & PLAY"
	else:
		_action_button.text = "SEND CODE"

func _set_google_pending(pending: bool) -> void:
	_google_pending = pending
	_google_button.disabled = pending
	_google_button.text = "Signing in with Google…" if pending else "Continue with Google"
	_paste_row.visible = pending
	# The recovery row (RETRY + CANCEL) shows the moment a return is
	# pending — not after 60 s: a failed or cancelled browser return
	# must offer a way back at once, never a dead screen. The 60 s
	# timer in _process still adds the explanatory message. Scroll it
	# into view on the next frame: it sits below the fold on a 1280 px
	# screen, and a stuck player must SEE the way back, not have to
	# discover it by scrolling.
	if _recovery_row:
		_recovery_row.visible = pending
		if pending:
			_scroll_to_recovery = true
	if not pending:
		_recovery_shown = false
		_scroll_to_recovery = false

func _start_resend_cooldown() -> void:
	_resend_cooldown = 60
	_resend_button.disabled = true
	_resend_button.text = "RESEND CODE (60s)"
	_resend_timer.start()

func _on_resend_tick() -> void:
	_resend_cooldown -= 1
	if _resend_cooldown <= 0:
		_resend_timer.stop()
		_resend_button.disabled = false
		_resend_button.text = "RESEND CODE"
	else:
		_resend_button.text = "RESEND CODE (%ds)" % _resend_cooldown

func _on_resend_pressed() -> void:
	if _pending_gmail == "" or _busy:
		return
	_set_message(_error_label, "")
	_busy = true
	var sent := await Accounts.request_login_code(_pending_gmail)
	_busy = false
	if not bool(sent.get("ok", false)):
		_set_message(_error_label, String(sent.get("error", "Could not send the code.")))
		return
	_set_message(_info_label, "Code sent again to %s — check your Gmail (and Spam folder)." % _pending_gmail)
	_start_resend_cooldown()

func _on_action_pressed() -> void:
	if _busy:
		return
	_set_message(_error_label, "")
	_set_message(_info_label, "")
	if _mode == "register":
		_busy = true
		var res := await Accounts.register_player(_name_edit.text, _gmail_edit.text)
		_busy = false
		if not bool(res.get("ok", false)):
			_set_message(_error_label, String(res.get("error", "Registration failed.")))
			return
		if String(res.get("error", "")) != "":
			_set_message(_info_label, String(res.get("error", "")))
		if not Supabase.configured:
			registered.emit()
			return
		# Cloud is configured: offer the Gmail code now (verification
		# proves the Gmail, so a later reinstall restores for sure).
		_pending_gmail = _gmail_edit.text.strip_edges().to_lower()
		_pending_allow_create = true # first verification may create the cloud profile
		var sent := await Accounts.request_login_code(_pending_gmail)
		if bool(sent.get("ok", false)):
			_set_message(_info_label, "We sent a 6-digit code to %s — enter it below to verify your Gmail." % _pending_gmail)
			_code_row.visible = true
			_verify_later_button.visible = true
			_start_resend_cooldown()
		else:
			_set_message(_info_label, "Registered! Gmail verification is not available right now — you can verify later.")
			registered.emit()
	else:
		_busy = true
		var sent2 := await Accounts.request_login_code(_gmail_edit.text)
		_busy = false
		if not bool(sent2.get("ok", false)):
			_set_message(_error_label, String(sent2.get("error", "Could not send the code.")))
			return
		_pending_gmail = _gmail_edit.text.strip_edges().to_lower()
		_pending_allow_create = false # sign-in never creates a profile
		_set_message(_info_label, "We sent a 6-digit code to %s — enter it below." % _pending_gmail)
		_code_row.visible = true
		_verify_later_button.visible = false
		_start_resend_cooldown()
		_code_edit.grab_focus()

func _on_verify_code_pressed() -> void:
	if _busy or _pending_gmail == "":
		return
	_set_message(_error_label, "")
	_busy = true
	# L5: allow_create follows how the pending code was SENT (register
	# vs sign-in), not the tab showing now — the player may have
	# switched tabs while the code was in flight.
	var res := await Accounts.verify_code_and_login(_pending_gmail, _code_edit.text, _pending_allow_create)
	_busy = false
	if not bool(res.get("ok", false)):
		_set_message(_error_label, String(res.get("error", "Wrong code — try again.")))
		return
	if _mode == "register":
		registered.emit()
	else:
		signed_in.emit()

func _on_google_pressed() -> void:
	_set_message(_error_label, "")
	if not Supabase.configured:
		_set_message(_error_label, "Google sign-in is not connected yet — register with your Gmail above.")
		return
	if not Accounts.begin_google_sign_in():
		_set_message(_error_label, "Google sign-in could not open your browser — use your Gmail + code below.")
		return
	_set_google_pending(true)
	_set_message(_info_label, "Signing in with Google — pick your account in the browser, then come back here.")

func _on_google_finished(ok: bool, message: String) -> void:
	_set_google_pending(false)
	if ok:
		signed_in.emit()
	else:
		_set_message(_error_label, message)

## An OTP magic-link tap completed the sign-in (v10): the player was
## on the register or sign-in tab, so emit the matching signal.
func _on_otp_link_finished(ok: bool, message: String) -> void:
	_set_google_pending(false)
	if ok:
		if _mode == "register":
			registered.emit()
		else:
			signed_in.emit()
	else:
		_set_message(_error_label, message)

## v11 P0-3: the loopback listener failed to start while a browser
## return was pending — say so plainly and show the paste-the-code
## lifeline at once, instead of leaving the player on a dead screen.
## (On Android this never fires — the custom scheme is the return path.)
func _on_return_listener_failed(message: String) -> void:
	_set_message(_error_label, message)
	_paste_row.visible = true
	_paste_edit.grab_focus()

## RETRY (v10 recovery): cancel the dead pending return and open
## Google again. The player never has to stare at a stuck screen.
func _on_google_retry_pressed() -> void:
	Accounts.cancel_pending_return()
	_set_google_pending(false)
	_set_message(_error_label, "")
	_on_google_pressed()

## CANCEL: drop a pending Google return and go back to Gmail + code.
## The recovery row shows this the moment a return is pending, so a
## failed or cancelled browser trip never leaves the player stuck on
## "Signing in with Google…".
func _on_google_cancel_pressed() -> void:
	Accounts.cancel_pending_return()
	_set_google_pending(false)
	_set_message(_error_label, "")
	_set_message(_info_label, "Google sign-in cancelled — register with your Gmail + code below.")

## Show the Google button or the "not set up yet" note, depending on
## whether the project's Google provider is enabled.
func _apply_google_availability() -> void:
	var on := Supabase.google_enabled
	_google_button.visible = on
	_google_note.visible = not on

func _on_use_pasted_code_pressed() -> void:
	if not Accounts.finish_google_with_pasted_code(_paste_edit.text):
		_set_message(_error_label, "Paste the code from the browser address bar (the part after code=).")
		return
	_set_message(_info_label, "Checking the code — one moment…")
