class_name AuthScreen
extends Control

## Register / sign-in screen (v7). The FIRST screen of the game:
## registration is mandatory — a player cannot play without an account
## (Buddhika, 2026-11-22: otherwise players lose their progress when
## they reinstall). There is no guest mode and no "play as guest" path.
##
## Two tabs:
##   REGISTER — display name + Gmail -> REGISTER & PLAY. When Supabase
##     is configured, a 6-digit code is sent to the Gmail and the
##     player verifies it here (VERIFY button); "Verify later" keeps
##     playing with an unverified account — the Gmail can be proven
##     later from the profile. When Supabase is NOT configured yet,
##     registration is local-only and the player goes straight in.
##   SIGN IN — Gmail -> SEND CODE -> 6-digit code -> VERIFY & SIGN IN.
##     Restores coins, level, XP, stats and shop ownership from the
##     cloud profile for that Gmail.
##   SIGN IN WITH GOOGLE — one-tap (PKCE loopback). Falls back to an
##   explanation when the Google provider is not set up yet; Gmail +
##   code always works as the way in.
##
## The logo is JUST the carrom board (BoardView, no text — logo rule).

signal registered
signal signed_in

var _mode := "register" # register | signin
var _name_edit: LineEdit
var _gmail_edit: LineEdit
var _code_edit: LineEdit
var _error_label: Label
var _info_label: Label
var _action_button: Button
var _code_button: Button
var _google_button: Button
var _verify_later_button: Button
var _code_row: VBoxContainer
var _pending_gmail := ""
var _busy := false

func _ready() -> void:
	UiKit.full_rect(self)
	var bg := ColorRect.new()
	bg.color = Color(0.15, 0.11, 0.07)
	bg.mouse_filter = Control.MOUSE_FILTER_IGNORE
	UiKit.full_rect(bg)
	add_child(bg)
	var root := VBoxContainer.new()
	UiKit.full_rect(root)
	root.offset_left = 24
	root.offset_right = -24
	root.offset_top = 24
	root.offset_bottom = -24
	root.add_theme_constant_override("separation", 12)
	add_child(root)
	# ---- Logo: just the board, no text ----
	var vp := get_viewport_rect().size
	var board_px := clampf(minf(vp.x - 120.0, 420.0), 300.0, 420.0)
	var s := board_px / 680.0
	var center := CenterContainer.new()
	center.mouse_filter = Control.MOUSE_FILTER_IGNORE
	root.add_child(center)
	var board_holder := Control.new()
	board_holder.custom_minimum_size = Vector2(board_px, board_px)
	board_holder.mouse_filter = Control.MOUSE_FILTER_IGNORE
	center.add_child(board_holder)
	var mini := BoardView.new()
	mini.board_id = Save.equipped_board
	mini.striker_id = Save.equipped_striker
	mini.draw_backdrop = false
	mini.show_labels = false
	mini.pieces = _logo_pieces()
	mini.position = Vector2(-20, -250) * s
	mini.scale = Vector2(s, s)
	board_holder.add_child(mini)
	# ---- Title + why ----
	root.add_child(UiKit.title_label("WELCOME TO CARROM", 34))
	var why := UiKit.muted_label("Register once — your coins, level and shop items are saved to your account, so they come back even if you delete the app and reinstall.", 18)
	why.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	root.add_child(why)
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
	_verify_later_button = UiKit.dark_button("Verify later — play now", 20)
	_verify_later_button.custom_minimum_size = Vector2(0, 48)
	_verify_later_button.pressed.connect(func() -> void: registered.emit())
	_code_row.add_child(_verify_later_button)
	# ---- Action ----
	_action_button = UiKit.gold_button("REGISTER & PLAY", 28)
	_action_button.custom_minimum_size = Vector2(0, 68)
	_action_button.pressed.connect(_on_action_pressed)
	root.add_child(_action_button)
	# ---- Google ----
	_google_button = UiKit.dark_button("G  SIGN IN WITH GOOGLE", 24)
	_google_button.custom_minimum_size = Vector2(0, 60)
	_google_button.pressed.connect(_on_google_pressed)
	root.add_child(_google_button)
	Accounts.google_finished.connect(_on_google_finished)
	# ---- Messages ----
	_error_label = Label.new()
	_error_label.add_theme_font_size_override("font_size", 18)
	_error_label.add_theme_color_override("font_color", UiKit.RED)
	_error_label.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	_error_label.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	root.add_child(_error_label)
	_info_label = UiKit.muted_label("", 17)
	_info_label.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	root.add_child(_info_label)
	var foot := UiKit.muted_label("BMS Carrom v7.0 • Account required • Free to play", 16)
	root.add_child(foot)
	_set_mode("register")

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
	e.custom_minimum_size = Vector2(0, 62)
	var normal := StyleBoxFlat.new()
	normal.bg_color = Color(0.16, 0.17, 0.20)
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

func _set_mode(mode: String) -> void:
	_mode = mode
	_error_label.text = ""
	_info_label.text = ""
	_code_row.visible = false
	_code_edit.text = ""
	_pending_gmail = ""
	_name_edit.visible = mode == "register"
	_verify_later_button.visible = false
	if mode == "register":
		_action_button.text = "REGISTER & PLAY"
		_google_button.visible = true
	else:
		_action_button.text = "SEND CODE"
		_google_button.visible = true

func _on_action_pressed() -> void:
	if _busy:
		return
	_error_label.text = ""
	_info_label.text = ""
	if _mode == "register":
		_busy = true
		var res := await Accounts.register_player(_name_edit.text, _gmail_edit.text)
		_busy = false
		if not bool(res.get("ok", false)):
			_error_label.text = String(res.get("error", "Registration failed."))
			return
		if String(res.get("error", "")) != "":
			_info_label.text = String(res.get("error", ""))
		if not Supabase.configured:
			registered.emit()
			return
		# Cloud is configured: offer the Gmail code now (verification
		# proves the Gmail, so a later reinstall restores for sure).
		_pending_gmail = _gmail_edit.text.strip_edges().to_lower()
		var sent := await Accounts.request_login_code(_pending_gmail)
		if bool(sent.get("ok", false)):
			_info_label.text = "We sent a 6-digit code to %s — enter it below to verify your Gmail." % _pending_gmail
			_code_row.visible = true
			_verify_later_button.visible = true
		else:
			_info_label.text = "Registered! Gmail verification is not available right now — you can verify later."
			registered.emit()
	else:
		_busy = true
		var sent2 := await Accounts.request_login_code(_gmail_edit.text)
		_busy = false
		if not bool(sent2.get("ok", false)):
			_error_label.text = String(sent2.get("error", "Could not send the code."))
			return
		_pending_gmail = _gmail_edit.text.strip_edges().to_lower()
		_info_label.text = "We sent a 6-digit code to %s — enter it below." % _pending_gmail
		_code_row.visible = true
		_verify_later_button.visible = false
		_code_edit.grab_focus()

func _on_verify_code_pressed() -> void:
	if _busy or _pending_gmail == "":
		return
	_error_label.text = ""
	_busy = true
	var res := await Accounts.verify_code_and_login(_pending_gmail, _code_edit.text, _mode == "register")
	_busy = false
	if not bool(res.get("ok", false)):
		_error_label.text = String(res.get("error", "Wrong code — try again."))
		return
	if _mode == "register":
		registered.emit()
	else:
		signed_in.emit()

func _on_google_pressed() -> void:
	_error_label.text = ""
	if not Supabase.configured:
		_error_label.text = "Google sign-in is not connected yet — register with your Gmail above."
		return
	if not Accounts.begin_google_sign_in():
		_error_label.text = "Google sign-in is not set up yet — use your Gmail + code above."
		return
	_info_label.text = "Signing in with Google — finish in your browser, then come back here."

func _on_google_finished(ok: bool, message: String) -> void:
	if ok:
		signed_in.emit()
	else:
		_error_label.text = message
