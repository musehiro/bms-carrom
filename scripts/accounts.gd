extends Node

## Accounts (v7, mandatory registration — NO guest mode).
## A player CANNOT play without registering: the first screen is
## register/login (display name + Gmail). The profile lives locally
## (Save) AND, when Supabase is configured, in the cloud (profiles
## table) — so deleting the app and logging in again with the same
## Gmail restores coins, level, XP, stats and shop ownership.
##
## Why mandatory (Buddhika, 2026-11-22): otherwise players lose their
## progress when they reinstall, and that becomes their problem later.
##
## Flows:
##   Register: name + Gmail -> local account -> a 6-digit code is sent
##     to the Gmail -> verify it here -> the OTP sign-in IS the account
##     (Supabase Auth user for that Gmail) -> the local profile is
##     uploaded as the cloud profile. "Verify later" keeps playing
##     with an unverified account; the home screen shows a VERIFY
##     GMAIL reminder until the Gmail is proven, and the cloud profile
##     is created then. Cloud failure never blocks play: the local
##     account is the source of truth on the device.
##   Sign in (returning player): Gmail -> 6-digit code sent to the
##     Gmail -> verify -> fetch the cloud profile -> apply it
##     (resolve_profile: last write wins). No cloud profile yet means
##     the player must register first.
##   Google one-tap: PKCE loopback — the game listens on
##     http://127.0.0.1:8765/callback for Supabase's redirect, so no
##     native plugin and no deep-link intent filter are needed. The
##     Supabase dashboard must allow-list that redirect URL (see
##     docs/supabase-setup.md). Needs the Google provider enabled in
##     Supabase (a Google Cloud OAuth client — no card); until then
##     the button explains that Gmail + code is the way in.

signal account_changed
signal otp_sent(email: String)
signal otp_failed(message: String)
signal login_finished(ok: bool, message: String)
signal google_finished(ok: bool, message: String)
signal sync_finished(ok: bool)

const OTP_CODE_LEN := 6

var _loopback: TCPServer = null
var _loopback_conn: StreamPeerTCP = null
var _loopback_verifier := ""
var _loopback_done := false
var _loopback_deadline := 0.0

func _process(_delta: float) -> void:
	if _loopback == null:
		return
	var now := Time.get_unix_time_from_system()
	if now > _loopback_deadline:
		_stop_loopback()
		google_finished.emit(false, "Google sign-in timed out — try again.")
		return
	if _loopback_conn == null and _loopback.is_connection_available():
		_loopback_conn = _loopback.take_connection()
	if _loopback_conn != null:
		var avail := _loopback_conn.get_available_bytes()
		if avail > 0:
			var data: Array = _loopback_conn.get_data(avail)
			var text := (data[1] as PackedByteArray).get_string_from_utf8()
			var code := _parse_loopback_code(text)
			var body := "<html><body><h1>Signed in — you can close this tab and return to BMS Carrom.</h1></body></html>"
			var resp := "HTTP/1.1 200 OK\r\nContent-Type: text/html\r\nContent-Length: %d\r\nConnection: close\r\n\r\n%s" % [body.length(), body]
			_loopback_conn.put_data(resp.to_utf8_buffer())
			_loopback_conn.disconnect_from_host()
			_loopback_conn = null
			_stop_loopback()
			if code != "":
				_finish_google_sign_in(code)

func _stop_loopback() -> void:
	if _loopback != null:
		_loopback.stop()
		_loopback = null
	_loopback_conn = null
	_loopback_done = false

## Extract the ?code=... from a loopback GET request. Returns "" when
## the request has no code (e.g. a stray probe). Pure — unit-tested.
static func _parse_loopback_code(request_text: String) -> String:
	var first_line := request_text.split("\n")[0].strip_edges()
	# "GET /callback?code=abc&state=x HTTP/1.1"
	if not first_line.begins_with("GET "):
		return ""
	var path := first_line.trim_prefix("GET ").split(" ")[0]
	if not path.begins_with("/callback"):
		return ""
	var query := path.split("?", false, 1)
	if query.size() < 2:
		return ""
	for part in query[1].split("&"):
		var kv := part.split("=", false, 1)
		if kv.size() == 2 and kv[0] == "code":
			return kv[1].uri_decode()
	return ""

# ------------------------------------------------------------------ state

func has_account() -> bool:
	return Save.account_gmail != ""

func is_verified() -> bool:
	return Save.account_verified

func display_name() -> String:
	return Save.player_name

## The account's cloud id (Supabase Auth user id). "" when the account
## was created locally and has not synced yet.
func account_id() -> String:
	return Save.account_id

# -------------------------------------------------------------- validation

static func valid_display_name(raw_name: String) -> String:
	var n := raw_name.strip_edges()
	if n.length() < 2:
		return "Enter a name (at least 2 characters)."
	if n.length() > 20:
		return "Keep the name to 20 characters or fewer."
	return ""

static func valid_gmail(raw_gmail: String) -> String:
	var g := raw_gmail.strip_edges().to_lower()
	if g == "":
		return "Enter your Gmail address."
	if g.find("@") < 1 or g.ends_with("@"):
		return "That does not look like an email address."
	var domain := g.split("@", false, 1)[1] if g.contains("@") else ""
	if domain != "gmail.com" and domain != "googlemail.com":
		return "Use a Gmail address (…@gmail.com)."
	if g.find(" ") >= 0:
		return "The Gmail address must not contain spaces."
	return ""

# ------------------------------------------------------------ registration

## Register a new player (mandatory — no guest path). Creates the local
## account immediately so play is never blocked. The cloud profile is
## created when the Gmail is verified (OTP): the OTP sign-in IS the
## account — the Supabase Auth user id for that Gmail becomes the
## profile id, so there is exactly one account per Gmail and the
## profile can always be restored by signing in with the same Gmail.
## (An anonymous sign-in would create a *different* user id from the
## email user, and the profile would end up under the wrong id — so
## registration deliberately does NOT sign in anonymously first.)
## Returns {ok, error, cloud} — `cloud` is true only when the profile
## was uploaded (only after verification).
func register_player(raw_name: String, raw_gmail: String) -> Dictionary:
	var name_err := valid_display_name(raw_name)
	if name_err != "":
		return {"ok": false, "error": name_err, "cloud": false}
	var gmail_err := valid_gmail(raw_gmail)
	if gmail_err != "":
		return {"ok": false, "error": gmail_err, "cloud": false}
	var display_name := raw_name.strip_edges()
	var gmail := raw_gmail.strip_edges().to_lower()
	Save.player_name = display_name
	Save.account_gmail = gmail
	Save.account_id = generate_uuid()
	Save.account_verified = false
	Save.account_created_at = Save.today_str()
	Save.account_synced_at = 0
	Save.save()
	account_changed.emit()
	return {"ok": true, "error": "", "cloud": false}

## Upload the local profile to Supabase. Needs a session (OTP-verified
## Gmail or Google sign-in) — the profile id IS the session's user id,
## which is also what RLS requires. Returns {ok, error}.
func sync_to_cloud() -> Dictionary:
	if not has_account():
		return {"ok": false, "error": "No account to sync."}
	if not Supabase.configured:
		return {"ok": false, "error": "Supabase is not configured yet."}
	if Supabase.user_id == "":
		return {"ok": false, "error": "Verify your Gmail first to sync."}
	var up := await _cloud_upsert()
	sync_finished.emit(bool(up.get("ok", false)))
	return up

func _cloud_upsert() -> Dictionary:
	if Supabase.user_id == "":
		return {"ok": false, "error": "No Supabase session — verify your Gmail first."}
	var row := Supabase.profile_row(Save.account_id, Save.account_gmail, Save.player_name,
		Save.coins, Save.xp, Save.matches_played, Save.matches_won, Save.online_wins,
		Save.queens_covered, Save.owned_boards, Save.owned_strikers,
		Save.equipped_board, Save.equipped_striker)
	# The profile id IS the Supabase Auth user id — so the row must use
	# the session's user id, not the local uuid (they match after the
	# first successful sync; before that the local uuid is a placeholder).
	row["id"] = Supabase.user_id
	var res := await Supabase.upsert_profile(row)
	if not bool(res.get("ok", false)):
		return {"ok": false, "error": String(res.get("error", "Profile upload failed."))}
	Save.account_id = Supabase.user_id
	Save.account_synced_at = int(Time.get_unix_time_from_system())
	Save.save()
	return {"ok": true, "error": ""}

# ------------------------------------------------------------------- login

## Send the 6-digit login code to a Gmail. Fails fast when Supabase is
## not configured yet (the player then registers locally instead).
func request_login_code(gmail: String) -> Dictionary:
	var gmail_err := valid_gmail(gmail)
	if gmail_err != "":
		return {"ok": false, "error": gmail_err}
	if not Supabase.configured:
		return {"ok": false, "error": "Sign-in with Gmail is not connected yet — register on this device for now."}
	var res := await Supabase.send_otp(gmail.strip_edges().to_lower())
	if bool(res.get("ok", false)):
		otp_sent.emit(gmail.strip_edges().to_lower())
		return {"ok": true, "error": ""}
	otp_failed.emit(String(res.get("error", "Could not send the code.")))
	return {"ok": false, "error": String(res.get("error", "Could not send the code."))}

## Verify the code and restore the cloud profile for that Gmail.
## Returns {ok, error, restored} — restored=false means no cloud
## profile existed yet. `allow_create` is true only for the REGISTER
## tab: a first verification uploads the local profile as the cloud
## profile (the account is new). On the SIGN IN tab it is false: a
## Gmail with no profile means the player must register first.
func verify_code_and_login(gmail: String, code: String, allow_create: bool = false) -> Dictionary:
	var g := gmail.strip_edges().to_lower()
	var c := code.strip_edges()
	if c.length() != OTP_CODE_LEN or not c.is_valid_int():
		return {"ok": false, "error": "Enter the 6-digit code from your Gmail.", "restored": false}
	if not Supabase.configured:
		return {"ok": false, "error": "Sign-in with Gmail is not connected yet.", "restored": false}
	var ver := await Supabase.verify_otp(g, c)
	if not bool(ver.get("ok", false)):
		return {"ok": false, "error": String(ver.get("error", "Wrong code — try again.")), "restored": false}
	var got := await Supabase.get_profile_by_gmail(g)
	if not bool(got.get("ok", false)):
		return {"ok": false, "error": String(got.get("error", "Could not load the profile.")), "restored": false}
	var row: Dictionary = got.get("data", {})
	if row.is_empty():
		if not allow_create:
			return {"ok": false, "error": "No account found for that Gmail yet — register first.", "restored": false}
		# First verification: this Gmail has no cloud profile yet — the
		# local profile IS the account, so upload it as the cloud row.
		Save.account_verified = true
		Save.save()
		var up := await _cloud_upsert()
		login_finished.emit(true, "")
		if bool(up.get("ok", false)):
			return {"ok": true, "error": "", "restored": false}
		return {"ok": true, "error": "Verified — cloud sync will retry.", "restored": false}
	# Last-write-wins: if this device's local profile is newer than the
	# cloud row (played offline while the cloud was unreachable), keep
	# the local progress and push it to the cloud instead of overwriting
	# it with the older cloud row.
	var local_at := ""
	if Save.account_synced_at > 0:
		local_at = Time.get_datetime_string_from_unix_time(Save.account_synced_at, true)
	var cloud_at := String(row.get("updated_at", ""))
	if local_at != "" and cloud_at != "" and local_at > cloud_at:
		Save.account_verified = true
		Save.save()
		await _cloud_upsert()
		login_finished.emit(true, "")
		return {"ok": true, "error": "", "restored": true}
	apply_cloud_profile(row, true)
	login_finished.emit(true, "")
	return {"ok": true, "error": "", "restored": true}

## Write a cloud profile row into the local Save (coins, XP, stats,
## shop, name). `verified` marks the Gmail as proven.
func apply_cloud_profile(row: Dictionary, verified: bool) -> void:
	Save.account_id = String(row.get("id", Save.account_id))
	Save.account_gmail = String(row.get("gmail", Save.account_gmail))
	Save.player_name = String(row.get("display_name", Save.player_name))
	Save.coins = int(row.get("coins", Save.coins))
	Save.xp = int(row.get("xp", Save.xp))
	Save.matches_played = int(row.get("matches_played", Save.matches_played))
	Save.matches_won = int(row.get("matches_won", Save.matches_won))
	Save.online_wins = int(row.get("online_wins", Save.online_wins))
	Save.queens_covered = int(row.get("queens_covered", Save.queens_covered))
	var boards: Array = row.get("owned_boards", Save.owned_boards)
	if boards is Array and not boards.is_empty():
		Save.owned_boards = boards
	var strikers: Array = row.get("owned_strikers", Save.owned_strikers)
	if strikers is Array and not strikers.is_empty():
		Save.owned_strikers = strikers
	Save.equipped_board = String(row.get("equipped_board", Save.equipped_board))
	Save.equipped_striker = String(row.get("equipped_striker", Save.equipped_striker))
	Save.account_verified = verified
	Save.account_synced_at = int(Time.get_unix_time_from_system())
	Save.save()
	account_changed.emit()

## Last-write-wins between a local profile row and a cloud row (both in
## Supabase profile shape, with updated_at ISO strings). Pure — tested.
## Missing/empty side loses; a tie goes to the cloud row.
static func resolve_profile(local_row: Dictionary, cloud_row: Dictionary) -> Dictionary:
	if local_row.is_empty():
		return cloud_row
	if cloud_row.is_empty():
		return local_row
	var local_at := String(local_row.get("updated_at", ""))
	var cloud_at := String(cloud_row.get("updated_at", ""))
	if local_at == "" and cloud_at == "":
		return cloud_row
	if local_at == "":
		return cloud_row
	if cloud_at == "":
		return local_row
	return cloud_row if cloud_at >= local_at else local_row

# --------------------------------------------------------- Google one-tap

## Start Google sign-in (PKCE loopback). Opens the Supabase authorize
## page in the browser; the reply lands on http://127.0.0.1:8765 and
## the exchange runs automatically. Emits google_finished when done.
## Returns false immediately when the backend (or Google provider) is
## not configured — the caller shows the Gmail + code path instead.
func begin_google_sign_in() -> bool:
	if not Supabase.configured:
		return false
	if Supabase.google_client_id == "":
		return false
	_loopback_verifier = Supabase.random_verifier()
	_loopback = TCPServer.new()
	var err := _loopback.listen(Supabase.LOOPBACK_PORT, "127.0.0.1")
	if err != OK:
		_loopback = null
		return false
	_loopback_done = false
	_loopback_deadline = Time.get_unix_time_from_system() + 300.0
	var redirect_to := "http://127.0.0.1:%d%s" % [Supabase.LOOPBACK_PORT, Supabase.LOOPBACK_PATH]
	var url := Supabase.google_authorize_url(Supabase.base_url, _loopback_verifier, redirect_to)
	OS.shell_open(url)
	return true

func _finish_google_sign_in(code: String) -> void:
	if _loopback_done:
		return
	_loopback_done = true
	var res := await Supabase.exchange_pkce_code(code, _loopback_verifier)
	if not bool(res.get("ok", false)):
		google_finished.emit(false, String(res.get("error", "Google sign-in failed.")))
		return
	# The Google account's email is the identity: fetch the profile for
	# it (or create one from the local save if this is a first sign-in).
	var user: Dictionary = (res.get("data", {}) as Dictionary).get("user", {})
	var gmail := String(user.get("email", "")).strip_edges().to_lower()
	if gmail == "":
		google_finished.emit(false, "Google did not return an email address.")
		return
	var got := await Supabase.get_profile_by_gmail(gmail)
	if bool(got.get("ok", false)):
		var row: Dictionary = got.get("data", {})
		if not row.is_empty():
			apply_cloud_profile(row, true)
			google_finished.emit(true, "")
			return
	# First Google sign-in: keep the local name/coins, claim the Gmail.
	Save.account_gmail = gmail
	Save.account_verified = true
	Save.save()
	var up := await _cloud_upsert()
	if bool(up.get("ok", false)):
		google_finished.emit(true, "")
	else:
		google_finished.emit(true, "Signed in with Google — cloud sync will retry.")

# ---------------------------------------------------------------- sign out

## Sign out: clears the local account and the Supabase session. The
## game shows the register/login screen again (registration is
## mandatory — there is no guest mode to fall back to).
func sign_out() -> void:
	Save.account_gmail = ""
	Save.account_id = ""
	Save.account_verified = false
	Save.account_created_at = ""
	Save.account_synced_at = 0
	Save.save()
	Supabase.access_token = ""
	Supabase.user_id = ""
	Supabase.disconnect_realtime()
	account_changed.emit()

# ------------------------------------------------------------------ utils

static func generate_uuid() -> String:
	const HEX := "0123456789abcdef"
	var out := ""
	for i in range(32):
		if i == 8 or i == 12 or i == 16 or i == 20:
			out += "-"
		if i == 12:
			out += "4" # version 4
		elif i == 16:
			out += HEX[8 + randi() % 4] # variant 10xx
		else:
			out += HEX[randi() % 16]
	return out
