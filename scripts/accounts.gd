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
##   Google one-tap: PKCE (v11) — on Android the browser returns via
##     the custom-scheme deep link com.musehiro.carrom://auth-callback
##     (intent filter in android/build/AndroidManifest.xml +
##     GodotApp.onNewIntent writes the URI to user://auth_callback.txt,
##     which Accounts polls while a return is pending); on
##     desktop/editor it returns via the 127.0.0.1 loopback listener.
##     The Supabase dashboard must allow-list BOTH redirect URLs (see
##     docs/supabase-setup.md). Needs the Google provider enabled in
##     Supabase (a Google Cloud OAuth client — no card); until then
##     the button explains that Gmail + code is the way in. If the
##     browser does not return within ~60 s, the register screen shows
##     RETRY + the paste-the-code row (v10 recovery UI).
##   OTP magic link (v10, v11): the code email also carries a "Sign in"
##     link; the OTP request sends the platform redirect +
##     a PKCE challenge, so tapping the link returns ?code= via the
##     same return path and signs the player in — the 6-digit code
##     stays the primary path (the dashboard email template must show
##     the code {{.Token}} big and clear).

signal account_changed
signal otp_sent(email: String)
signal otp_failed(message: String)
signal login_finished(ok: bool, message: String)
signal google_finished(ok: bool, message: String)
signal otp_link_finished(ok: bool, message: String)
signal sync_finished(ok: bool)
## v11 P0-3: the loopback listener failed to start while a browser
## return was pending — the auth screen can read the message via
## loopback_listener_error() instead of the player staring at a dead
## screen. (On Android the listener is never started — the custom
## scheme is the return path — so this never fires there.)
signal return_listener_failed(message: String)

const OTP_CODE_LEN := 6

## Scale hardening (2026-11-28): how often the mid-session refresh
## check runs (the check itself is cheap — it only calls GoTrue when
## the token is <5 min from expiry). A session open >1 h used to start
## 401-ing on every poll; the check refreshes proactively instead.
const SESSION_REFRESH_CHECK_SECONDS := 60.0

var _refresh_check_timer := 0.0 # accumulates to SESSION_REFRESH_CHECK_SECONDS
var _refresh_check_busy := false # a refresh attempt is in flight

var _loopback: TCPServer = null
var _loopback_conn: StreamPeerTCP = null
var _loopback_verifier := ""
var _loopback_done := false
## v11 P0-3: "" = the listener is running (or not needed on Android);
## non-empty = listen() failed — a loud, UI-readable failure state.
## Cleared when a listener starts OK or the pending return ends.
var _loopback_error := ""
var _google_pending := false # a browser return is in flight (Google or OTP link)
var _google_deadline := 0.0 # unix time the pending return times out
var _return_kind := "" # "google" | "otp_link" — which return is pending
var _google_started_at := 0.0 # unix time the pending return started; 0 = resumed after a cold start (elapsed unknown)
var _file_poll_accum := 0.0 # throttle for the deep-link file poll
## Session persistence (v11): true when a saved session existed but its
## refresh failed — the player must sign in again. The lobby reads this
## (session_needs_sign_in) and says so instead of a silent empty list.
## Never persisted — a fresh launch re-runs the restore and sets it.
var session_refresh_failed := false

func _ready() -> void:
	# Scale hardening (2026-11-28): every successful refresh — the
	# startup restore, the proactive mid-session check below, or the
	# 401-retry inside Supabase._http — rotates BOTH tokens, so the
	# rotated values must be persisted at once (a restart restores
	# with the NEW refresh token; GoTrue revokes the old one). A dead
	# refresh token surfaces separately: the player must sign in again.
	Supabase.session_refreshed.connect(_persist_session)
	Supabase.session_refresh_invalid.connect(_on_session_refresh_invalid)
	# Resume a browser return that was interrupted by the app being
	# killed while the browser was open: the PKCE verifier was
	# persisted in Save, and the deep link (if it arrived) is waiting
	# in the file GodotApp.java wrote. v10 reads the unified
	# pending_return_* slot first, then the v9 google_pkce_* slot (a
	# v9 install's pending Google sign-in). Started-at is unknown
	# after a cold start, so the recovery UI shows at once (elapsed()
	# returns 999).
	# v11 P0-3: on desktop/editor the loopback listener is RESTARTED
	# here while the return is still pending — the v10 code restored
	# the pending state but never re-listened, so a browser return
	# after a cold start hit a dead port (ERR_CONNECTION_REFUSED).
	# The restart reuses the PERSISTED verifier and the PERSISTED
	# deadline — it never mints a fresh verifier (that would kill the
	# in-flight code) and never extends the deadline. On Android
	# there is no loopback listener to restart: the custom-scheme
	# deep-link file poll is the return path there. The callback file
	# is checked BEFORE the restart, so a code that already arrived
	# is consumed (and ends the pending return) instead of the
	# restart deleting it.
	if Save.pending_return_verifier != "" and Save.pending_return_deadline > int(Time.get_unix_time_from_system()):
		_loopback_verifier = Save.pending_return_verifier
		_return_kind = Save.pending_return_kind
		_google_pending = true
		_google_deadline = float(Save.pending_return_deadline)
		_google_started_at = 0.0
		_check_pending_callback_file()
	elif Save.google_pkce_verifier != "" and Save.google_pkce_deadline > int(Time.get_unix_time_from_system()):
		_loopback_verifier = Save.google_pkce_verifier
		_return_kind = "google"
		_google_pending = true
		_google_deadline = float(Save.google_pkce_deadline)
		_google_started_at = 0.0
		_check_pending_callback_file()
	if _google_pending and not OS.has_feature("android"):
		_restart_loopback_listener()

func _process(delta: float) -> void:
	# Scale hardening (2026-11-28): mid-session token refresh. The
	# check runs every 60 s and only calls GoTrue when the access
	# token is <5 min from expiry (Supabase.session_needs_refresh) —
	# a session open >1 h used to 401 on every poll until the next
	# restart. ensure_fresh_session never loops (single-flight +
	# 60 s backoff inside Supabase); a failed refresh just retries
	# at the next check, and a dead refresh token sets
	# session_refresh_failed via _on_session_refresh_invalid.
	if Supabase.configured and Supabase.access_token != "" and Supabase.refresh_token != "":
		_refresh_check_timer += delta
		if _refresh_check_timer >= SESSION_REFRESH_CHECK_SECONDS and not _refresh_check_busy:
			_refresh_check_timer = 0.0
			if Supabase.session_needs_refresh():
				_maybe_refresh_session()
	if _loopback != null:
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
					_finish_return(code)
				else:
					# Defensive: an implicit-flow redirect carries the
					# tokens in the query (fragments never reach a
					# server, but GoTrue may answer with ?access_token=).
					var target := text.split("\n")[0].trim_prefix("GET ").split(" ")[0]
					var tokens := Supabase.parse_fragment_tokens("http://127.0.0.1" + target)
					if not tokens.is_empty():
						_finish_return_with_tokens(tokens)
					else:
						var kind := _return_kind
						_end_google_pending()
						_emit_return_finished(false, "Sign-in failed — the browser came back without a code. Try again, or register with your Gmail + code.", kind)
	if _google_pending:
		if Time.get_unix_time_from_system() > _google_deadline:
			var kind2 := _return_kind
			_end_google_pending()
			if kind2 == "otp_link":
				_emit_return_finished(false, "The sign-in link expired — enter the 6-digit code from your Gmail instead, or tap RESEND CODE.", kind2)
			else:
				_emit_return_finished(false, "Google sign-in timed out — try again, or register with your Gmail + code.", kind2)
			return
		_file_poll_accum += delta
		if _file_poll_accum >= 0.5:
			_file_poll_accum = 0.0
			_check_pending_callback_file()

## Emit the finished signal for a browser return, by kind. The caller
## passes the kind captured BEFORE _end_google_pending cleared it.
func _emit_return_finished(ok: bool, message: String, kind: String) -> void:
	if kind == "otp_link":
		otp_link_finished.emit(ok, message)
	else:
		google_finished.emit(ok, message)

## Deep-link return path: GodotApp.java writes the URI the browser came
## back with (com.musehiro.carrom://auth-callback?code=...) to
## user://auth_callback.txt. Poll for it while a return is pending and
## consume it exactly once. Also accepts an implicit-flow URI
## (...#access_token=...&refresh_token=...) via tokens.
func _check_pending_callback_file() -> void:
	if not _google_pending:
		return
	if not FileAccess.file_exists(Supabase.AUTH_CALLBACK_FILE):
		return
	var uri := FileAccess.get_file_as_string(Supabase.AUTH_CALLBACK_FILE).strip_edges()
	DirAccess.remove_absolute(ProjectSettings.globalize_path(Supabase.AUTH_CALLBACK_FILE))
	var code := Supabase.parse_callback_code(uri)
	if code != "":
		_finish_return(code)
		return
	var tokens := Supabase.parse_fragment_tokens(uri)
	if not tokens.is_empty():
		_finish_return_with_tokens(tokens)

func _end_google_pending() -> void:
	_google_pending = false
	_return_kind = ""
	_loopback_verifier = ""
	_loopback_error = ""
	_stop_loopback()
	Save.google_pkce_verifier = ""
	Save.google_pkce_deadline = 0
	Save.pending_return_verifier = ""
	Save.pending_return_deadline = 0
	Save.pending_return_kind = ""
	Save.save()

func is_google_pending() -> bool:
	return _google_pending and _return_kind == "google"

func is_return_pending() -> bool:
	return _google_pending

## Fire-and-forget wrapper for the proactive mid-session refresh
## (called from _process WITHOUT await — _process itself must never
## suspend on a network call). The busy flag stops a second attempt
## starting while one is in flight; ensure_fresh_session handles the
## backoff, and _persist_session runs via the session_refreshed signal.
func _maybe_refresh_session() -> void:
	if _refresh_check_busy:
		return
	_refresh_check_busy = true
	var _ok := await Supabase.ensure_fresh_session()
	_refresh_check_busy = false

## The refresh token itself is dead (GoTrue invalid_grant) — no retry
## will fix it. The player must sign in again: flag it (the lobby says
## so instead of showing a silent empty list) and log it. The
## in-memory tokens are left alone — the next launch's restore fails
## the same way and clears them then; signing the player out
## mid-session here would be worse than the flag.
func _on_session_refresh_invalid(message: String) -> void:
	session_refresh_failed = true
	push_warning("Session refresh failed (%s) — the player must sign in again." % message)

## Test helper: the PKCE verifier of the pending browser return ("" when
## none). Lets tests prove a resend reuses the verifier (L5) instead of
## minting a fresh one that would kill the earlier magic link.
func pending_return_verifier() -> String:
	return _loopback_verifier

## v11 P0-3: the loopback-listener failure state the auth screen can
## read. "" = the listener is running, or no listener is needed
## (Android — the custom scheme is the return path). Non-empty =
## listen() failed while a browser return was pending: the return
## cannot arrive on the loopback, so the UI must say so (and offer
## the paste-the-code recovery) instead of waiting silently.
func loopback_listener_error() -> String:
	return _loopback_error

## Seconds since the pending browser return started. -1 when nothing is
## pending; 999 when the return was resumed after a cold start (the
## start time is unknown — the browser trip already happened, so the
## recovery UI shows at once).
func google_pending_elapsed() -> float:
	if not _google_pending:
		return -1.0
	if _google_started_at <= 0.0:
		return 999.0
	return Time.get_unix_time_from_system() - _google_started_at

## Cancel a pending browser return (RETRY button): the player starts
## over instead of staring at a dead screen.
func cancel_pending_return() -> void:
	_end_google_pending()

## Test / screenshot helper: mark a browser return as pending WITHOUT
## opening a browser (the auth screen then shows the pending + recovery
## UI). Never used in the real flow.
func debug_begin_pending_return(kind: String) -> void:
	_start_return_listener(kind, Supabase.random_verifier())

func _stop_loopback() -> void:
	if _loopback != null:
		_loopback.stop()
		_loopback = null
	_loopback_conn = null
	# NOTE: _loopback_done is NOT reset here — it guards against a
	# duplicate finish (loopback + deep link racing). A new sign-in
	# resets it in begin_google_sign_in().

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
	# F7: never silently overwrite an existing VERIFIED account — a new
	# registration would inherit the old player's coins, level and shop
	# and then upload them as the new account's cloud profile. The
	# player must sign out first (which resets local progress), or sign
	# in with the existing Gmail instead.
	if has_account() and is_verified():
		return {"ok": false, "error": "You're already signed in as %s — sign out first to register a different account." % Save.account_gmail, "cloud": false}
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
	if not bool(up.get("ok", false)) and Supabase.user_id != "":
		# A real failure WITH a session (not the "no session" early
		# return above) — surface it in the log instead of failing
		# silently; local progress is kept and sync retries.
		push_warning("Cloud sync failed (%s) — local progress is kept and sync will retry." % String(up.get("error", "unknown error")))
	sync_finished.emit(bool(up.get("ok", false)))
	return up

# ------------------------------------------------------ session persistence
# (v11) The Supabase session used to live in memory only, so every app
# restart lost the sign-in: the lobby showed "No players online right
# now" without any network call, the presence heartbeat ran as `anon`
# (RLS denied it — the phone never appeared in anyone else's lobby)
# and profile sync refused outright. The session is now persisted in
# the app-private save file (Save.session_*, never the cloud profile,
# never logged) and restored on startup before Friends listens.

## True when a saved session existed but its refresh failed — the
## player must sign in again (the lobby shows this instead of a silent
## empty list).
func session_needs_sign_in() -> bool:
	return session_refresh_failed

## Write the current Supabase session (access + refresh tokens) to the
## local save. Called after every successful sign-in and after every
## successful refresh (GoTrue rotates both tokens, so the stored values
## are rewritten each time). No-op when there is no session to store.
## A successful sign-in also clears the stale-refresh flag.
func _persist_session() -> void:
	session_refresh_failed = false
	if Supabase.access_token == "" or Supabase.user_id == "":
		return
	Save.session_access_token = Supabase.access_token
	Save.session_refresh_token = Supabase.refresh_token
	Save.session_saved_at = int(Time.get_unix_time_from_system())
	Save.save()

## Restore the saved Supabase session on startup: exchange the stored
## refresh token for a fresh session (GoTrue rotates both tokens).
## Must run BEFORE Friends.start_listening() — Friends uses the Auth
## uid for Realtime/presence, and without a session the lobby shows an
## empty list and this phone never appears in anyone else's lobby. On
## success the local account id becomes the Auth uid (the profile id
## IS the Auth uid) and the rotated tokens are persisted. On failure
## the saved tokens are cleared and session_refresh_failed is set —
## the player must sign in again; play still works locally and the
## lobby says so instead of showing a silent empty list.
## Returns {ok, error}. Never throws.
func restore_session() -> Dictionary:
	if not Supabase.configured:
		return {"ok": false, "error": "Supabase is not configured yet."}
	if Save.session_refresh_token == "":
		return {"ok": false, "error": "No saved session."}
	var res := await Supabase.refresh_session(Save.session_refresh_token)
	if not bool(res.get("ok", false)):
		_clear_saved_session()
		session_refresh_failed = true
		push_warning("Session restore failed (%s) — the player must sign in again." % String(res.get("error", "refresh failed")))
		return {"ok": false, "error": String(res.get("error", "Session refresh failed."))}
	if Supabase.user_id != "":
		Save.account_id = Supabase.user_id
	_persist_session()
	return {"ok": true, "error": ""}

## Clear the saved + in-memory session (failed refresh / sign out).
func _clear_saved_session() -> void:
	Save.session_access_token = ""
	Save.session_refresh_token = ""
	Save.session_saved_at = 0
	Save.save()
	Supabase.access_token = ""
	Supabase.user_id = ""
	Supabase.refresh_token = ""

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
## The OTP request carries the platform redirect + a PKCE challenge
## (v10/v11): the email's "Sign in" link then returns ?code= via the
## platform return path (custom scheme on Android, loopback listener
## on desktop/editor), so tapping the link signs the player in — the
## 6-digit code in the same email stays the primary path. The listener
## only starts when no Google return is already pending (one pending
## return at a time; the Google verifier must not be clobbered).
func request_login_code(gmail: String) -> Dictionary:
	var gmail_err := valid_gmail(gmail)
	if gmail_err != "":
		return {"ok": false, "error": gmail_err}
	if not Supabase.configured:
		return {"ok": false, "error": "Sign-in with Gmail is not connected yet — register on this device for now."}
	var otp_verifier := ""
	if _google_pending and _return_kind == "otp_link":
		# L5 (resend): reuse the pending OTP-link verifier. The code
		# already emailed carries a PKCE challenge for THIS verifier —
		# sending the resend with a fresh verifier would silently kill
		# the earlier email's "Sign in" link (its code exchange would
		# fail). Both emails' links stay usable.
		otp_verifier = _loopback_verifier
	else:
		otp_verifier = Supabase.random_verifier()
	var res := await Supabase.send_otp(gmail.strip_edges().to_lower(),
		Supabase.auth_redirect_url(), Supabase.pkce_challenge(otp_verifier))
	var sent_with_redirect := false
	if bool(res.get("ok", false)):
		sent_with_redirect = true
	elif Supabase.looks_like_redirect_error(String(res.get("error", ""))):
		# The project's Redirect URLs do not allow the game's return
		# address yet (fresh project, 2026-11-27) — GoTrue rejected
		# the redirect variant. Retry once WITHOUT it: the code email
		# still arrives and the 6-digit code is the primary path; only
		# the magic-link return is lost. No second email is sent when
		# the first request succeeded, and no other failure is retried.
		# If an OTP-link return was already pending, its link is dead
		# too (same redirect) — end it so the code row is the only
		# path and a later Google sign-in is not told one is in flight.
		if _google_pending and _return_kind == "otp_link":
			_end_google_pending()
		res = await Supabase.send_otp_code_only(gmail.strip_edges().to_lower())
	if bool(res.get("ok", false)):
		if not sent_with_redirect:
			# Code-only send: no magic link will come back, so no
			# return listener — the player types the 6-digit code.
			otp_sent.emit(gmail.strip_edges().to_lower())
			return {"ok": true, "error": ""}
		if _google_pending and _return_kind == "otp_link":
			# Same return, still in flight: only extend its deadline
			# — do NOT restart the listener (that would reset the
			# start time, drop the in-flight verifier and delete a
			# callback file that may just have arrived).
			_google_deadline = Time.get_unix_time_from_system() + 300.0
			Save.pending_return_deadline = int(_google_deadline)
			Save.save()
		elif not _google_pending:
			_start_return_listener("otp_link", otp_verifier)
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
	# F6: capture the local profile row FIRST — _end_google_pending()
	# below saves the file, which would make the local profile look
	# brand-new and always win the last-write-wins comparison.
	var local_row := local_profile_row()
	if c.length() != OTP_CODE_LEN or not c.is_valid_int():
		return {"ok": false, "error": "Enter the 6-digit code from your Gmail.", "restored": false}
	if not Supabase.configured:
		return {"ok": false, "error": "Sign-in with Gmail is not connected yet.", "restored": false}
	var ver := await Supabase.verify_otp(g, c)
	if not bool(ver.get("ok", false)):
		return {"ok": false, "error": String(ver.get("error", "Wrong code — try again.")), "restored": false}
	# The code won — persist the session now, so a restart restores the
	# sign-in instead of losing it (v11 session persistence).
	_persist_session()
	# The magic link is no longer needed. End its pending return
	# pending return (loopback listener + persisted slot) so a later
	# Google sign-in can start its own return instead of being told
	# one is "already in flight".
	_end_google_pending()
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
	# F6: last-write-wins via resolve_profile (accounts.gd:447-455) —
	# the local row carries its real last-modified time as an ISO
	# updated_at (see local_profile_row), so both sides compare
	# like-for-like instead of "YYYY-MM-DD HH:MM:SS" against
	# "YYYY-MM-DDTHH:MM:SS+00:00" (the old comparison made same-day
	# newer local progress always lose). Equality is a safe identity
	# test here: the cloud row always carries created_at (and the
	# server id), so it can only equal the local row when the two are
	# content-identical — in which case either branch is correct.
	if resolve_profile(local_row, row) == local_row:
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

## The local profile as a Supabase-shaped row, with updated_at = the
## local profile's REAL last-modified time as an ISO string (F6) — or
## no updated_at at all when the local profile carries nothing newer
## than the cloud (see _local_modified_iso). Callers must capture this
## BEFORE any save in the login flow: a save during login would bump
## the file's mtime and make the local profile look brand-new.
static func local_profile_row() -> Dictionary:
	var row := Supabase.profile_row(Save.account_id, Save.account_gmail, Save.player_name,
		Save.coins, Save.xp, Save.matches_played, Save.matches_won, Save.online_wins,
		Save.queens_covered, Save.owned_boards, Save.owned_strikers,
		Save.equipped_board, Save.equipped_striker)
	var stamp := _local_modified_iso()
	if stamp != "":
		row["updated_at"] = stamp
	return row

## ISO last-modified time of the local profile, or "" when the local
## profile has nothing newer than the cloud (so resolve_profile lets
## the cloud row win). Every coin/XP/stat/shop change saves the file
## immediately, so the save file's mtime IS the local profile's
## last-modified time — with two guards:
## - synced before: the sync itself saves the file, so a mtime within
##   1 s of the last sync is the sync's own save, not new progress;
##   only a later save means the player played offline since syncing.
## - never synced: a fresh install's save file is always "new", so
##   mtime alone would let 1,000 starting coins overwrite real cloud
##   progress on a reinstall — only count it when the local profile
##   actually holds progress beyond the fresh-install defaults.
static func _local_modified_iso() -> String:
	var mtime := FileAccess.get_modified_time(Save.SAVE_PATH)
	if mtime <= 0:
		return ""
	if Save.account_synced_at > 0:
		if mtime <= Save.account_synced_at + 1:
			return ""
	elif not _local_has_progress():
		return ""
	return Time.get_datetime_string_from_unix_time(mtime, true).replace(" ", "T") + "+00:00"

## True when the local profile holds anything beyond a fresh install
## (non-starting coins, any XP/matches, or shop items beyond classic).
static func _local_has_progress() -> bool:
	return Save.coins != Save.STARTING_COINS or Save.xp > 0 \
		or Save.matches_played > 0 or Save.matches_won > 0 \
		or Save.online_wins > 0 or Save.tour_wins > 0 \
		or Save.queens_covered > 0 \
		or (Save.owned_boards as Array).size() > 1 \
		or (Save.owned_strikers as Array).size() > 1

# --------------------------------------------------------- Google one-tap

## Start Google sign-in (PKCE). Opens the Supabase authorize page in the
## browser; the reply comes back via the platform return path (v11):
## the custom-scheme deep link on Android, the 127.0.0.1 loopback
## listener on desktop/editor — with the deep-link file poll as the
## Android path after a cold start. The PKCE verifier is persisted in
## Save so the exchange can still complete after a cold start. Emits
## google_finished when done. Returns false immediately when the
## backend is not configured — the caller shows the Gmail + code path
## instead. Never fails silently: a browser that cannot open, or a
## flow that times out, emits google_finished(false, ...) with a
## message.
func begin_google_sign_in() -> bool:
	if not Supabase.configured:
		return false
	if not Supabase.google_enabled:
		# The project's Google provider is OFF (new project, 2026-11-27):
		# opening the authorize URL would land the player on GoTrue's
		# 400 "Unsupported provider" page with no way back into the
		# game. Refuse here instead — the caller shows the Gmail + code
		# path. Flip `google_enabled` in backend_config.json once the
		# provider is enabled in the dashboard.
		return false
	if _google_pending:
		if _return_kind == "google":
			return true # a Google return is already in flight — don't restart it
		# An OTP-link return is pending and the player switched to
		# Google. One pending return at a time: cancel the OTP one
		# first, or the Google callback would complete as an OTP-link
		# return (wrong signal — and on real Supabase the PKCE
		# exchange would fail with the OTP verifier).
		_end_google_pending()
	# NOTE (v9 root cause 1a): the old code returned false here when
	# Supabase.google_client_id was empty. The OAuth client lives
	# server-side in Supabase — the game never needs a client ID — so
	# that gate silently killed the button. It is gone.
	var verifier := Supabase.random_verifier()
	_start_return_listener("google", verifier)
	var url := Supabase.google_authorize_url(Supabase.base_url, verifier, Supabase.auth_redirect_url())
	var open_err := OS.shell_open(url)
	if open_err != OK and OS.has_feature("android"):
		# No browser to open — fail loudly instead of silently nothing.
		_end_google_pending()
		return false
	return true

## Shared setup for a pending browser return (Google or OTP link):
## fresh verifier, 300 s deadline, persisted so a cold start can
## still finish. A file left over from an abandoned return is stale —
## drop it so the poll can only pick up the code for THIS return.
## The loopback listener only starts on desktop/editor: on Android
## the custom-scheme deep link is the return path (the game is
## backgrounded while the browser is open and Android may kill it,
## so a live socket cannot be relied on). v11 P0-3: when the listener
## IS the return path and listen() fails, that failure is LOUD —
## _loopback_error is set (loopback_listener_error()), push_error
## logs it, and return_listener_failed fires — never the old silent
## "not fatal" path that left the player waiting on a dead port.
func _start_return_listener(kind: String, verifier: String) -> void:
	_loopback_verifier = verifier
	_loopback_done = false
	_loopback_error = ""
	_return_kind = kind
	_google_pending = true
	_google_deadline = Time.get_unix_time_from_system() + 300.0
	_google_started_at = Time.get_unix_time_from_system()
	Save.pending_return_verifier = verifier
	Save.pending_return_deadline = int(_google_deadline)
	Save.pending_return_kind = kind
	Save.save()
	if FileAccess.file_exists(Supabase.AUTH_CALLBACK_FILE):
		DirAccess.remove_absolute(ProjectSettings.globalize_path(Supabase.AUTH_CALLBACK_FILE))
	if not OS.has_feature("android"):
		_start_loopback()

## v11 P0-3: restart the loopback listener for a return resumed
## after a cold start (_ready()). Reuses the PERSISTED verifier and
## the PERSISTED deadline — it touches neither, writes nothing to
## Save, and does NOT delete the callback file (a code that arrived
## while the app was dead must survive). Never mints a fresh verifier:
## the in-flight code was issued against the persisted one, and a
## fresh verifier would make its exchange fail. Desktop/editor only —
## Android has no loopback listener (custom scheme instead). A failed
## listen() fails LOUD via _start_loopback().
func _restart_loopback_listener() -> void:
	if not _google_pending:
		return
	if OS.has_feature("android"):
		return
	if _loopback != null:
		return
	_start_loopback()

## Bind the loopback TCPServer. Returns OK on success. On failure the
## listener is left null AND the failure is surfaced loudly:
## _loopback_error (readable via loopback_listener_error()), a
## push_error log line, and the return_listener_failed signal — so the
## auth screen can tell the player the automatic return is down and
## offer the paste-the-code recovery instead of waiting silently.
func _start_loopback() -> Error:
	_stop_loopback()
	_loopback = TCPServer.new()
	var err := _loopback.listen(Supabase.LOOPBACK_PORT, "127.0.0.1")
	if err != OK:
		_loopback = null
		_loopback_error = "Could not listen for the browser return (port %d: %s) — the automatic sign-in return is down. Paste the code from your browser address bar instead." % [Supabase.LOOPBACK_PORT, error_string(err)]
		push_error(_loopback_error)
		return_listener_failed.emit(_loopback_error)
		return err
	_loopback_error = ""
	return OK

## Finish a pending browser return with a code the player pasted from
## the browser address bar (fallback when the automatic return failed).
## Accepts a bare code or a full callback URL containing ?code=... — or
## a link carrying #access_token=... (implicit flow). Returns false
## when there is no pending return or nothing pasted.
func finish_google_with_pasted_code(raw: String) -> bool:
	if not _google_pending:
		return false
	var text := raw.strip_edges()
	if text == "":
		return false
	var code := Supabase.parse_callback_code(text)
	if code != "":
		_finish_return(code)
		return true
	var tokens := Supabase.parse_fragment_tokens(text)
	if not tokens.is_empty():
		_finish_return_with_tokens(tokens)
		return true
	_finish_return(text)
	return true

## Finish a pending browser return with a PKCE code (loopback, deep
## link, or pasted). The code exchange gives the session; the account
## email is the identity. Emits google_finished or otp_link_finished
## by the pending kind.
func _finish_return(code: String) -> void:
	if _loopback_done:
		return
	_loopback_done = true
	var kind := _return_kind
	var verifier := _loopback_verifier
	# F6: capture the local profile row BEFORE _end_google_pending()
	# saves (that save would make the local profile look brand-new).
	var local_row := local_profile_row()
	_end_google_pending()
	var res := await Supabase.exchange_pkce_code(code, verifier)
	if not bool(res.get("ok", false)):
		_emit_return_finished(false, String(res.get("error", "Sign-in failed.")), kind)
		return
	# The exchange won — persist the session now, so a restart restores
	# the sign-in instead of losing it (v11 session persistence).
	_persist_session()
	var user: Dictionary = (res.get("data", {}) as Dictionary).get("user", {})
	var gmail := String(user.get("email", "")).strip_edges().to_lower()
	if gmail == "":
		_emit_return_finished(false, "Sign-in did not return an email address.", kind)
		return
	var meta: Dictionary = user.get("user_metadata", {})
	var gname := String(meta.get("full_name", meta.get("name", ""))).strip_edges()
	await _complete_sign_in(gmail, gname, kind, local_row)

## Finish a pending browser return from implicit-flow tokens (a pasted
## link with #access_token=...). The user id comes from the token; the
## email comes from GET /auth/v1/user.
func _finish_return_with_tokens(tokens: Dictionary) -> void:
	if _loopback_done:
		return
	_loopback_done = true
	var kind := _return_kind
	# F6: capture the local profile row BEFORE _end_google_pending()
	# saves (that save would make the local profile look brand-new).
	var local_row := local_profile_row()
	_end_google_pending()
	if not Supabase.set_session_from_tokens(String(tokens.get("access_token", "")), String(tokens.get("refresh_token", ""))):
		_emit_return_finished(false, "That sign-in link could not be read — try again, or register with your Gmail + code.", kind)
		return
	# The tokens won — persist the session now, so a restart restores
	# the sign-in instead of losing it (v11 session persistence).
	_persist_session()
	var got := await Supabase.get_user()
	var user: Dictionary = (got.get("data", {}) as Dictionary).get("user", got.get("data", {}))
	var gmail := String(user.get("email", "")).strip_edges().to_lower()
	if gmail == "":
		_emit_return_finished(false, "Sign-in did not return an email address.", kind)
		return
	await _complete_sign_in(gmail, "", kind, local_row)

## Shared tail of every browser-return sign-in: claim or restore the
## cloud profile for the Gmail, then emit the finished signal by kind.
## `local_row` is the local profile captured BEFORE the return finished
## (any save since would fake a brand-new local profile) — the same
## last-write-wins rule as the OTP login path (F6): a newer local
## profile is kept and pushed, otherwise the cloud row is applied.
func _complete_sign_in(gmail: String, provider_name: String, kind: String, local_row: Dictionary) -> void:
	# Use the provider's display name when the player has not set one
	# of their own yet (fresh install: the default "Player").
	if provider_name != "" and (Save.player_name == "" or Save.player_name == "Player"):
		Save.player_name = provider_name.left(20)
		Save.save()
	var got := await Supabase.get_profile_by_gmail(gmail)
	if bool(got.get("ok", false)):
		var row: Dictionary = got.get("data", {})
		if not row.is_empty():
			if resolve_profile(local_row, row) == local_row:
				Save.account_gmail = gmail
				Save.account_verified = true
				Save.save()
				await _cloud_upsert()
			else:
				apply_cloud_profile(row, true)
			_emit_return_finished(true, "", kind)
			return
	# First sign-in with this Gmail: keep the local name/coins, claim it.
	Save.account_gmail = gmail
	Save.account_verified = true
	Save.save()
	var up := await _cloud_upsert()
	if bool(up.get("ok", false)):
		_emit_return_finished(true, "", kind)
	else:
		_emit_return_finished(true, "Signed in — cloud sync will retry.", kind)

# ---------------------------------------------------------------- sign out

## Sign out: clears the local account AND all local progress, so the
## next player starts from a fresh install (F7 — the old version kept
## coins, XP, stats, shop ownership and the player name, and the next
## registration inherited them and uploaded them as its own cloud
## profile). Device preferences (aim guide, sound, server host) are
## NOT progress and are kept. The cloud profile is untouched — the
## player can sign back in with the same Gmail to restore it.
func sign_out() -> void:
	_end_google_pending()
	Save.account_gmail = ""
	Save.account_id = ""
	Save.account_verified = false
	Save.account_created_at = ""
	Save.account_synced_at = 0
	Save.player_name = "Player"
	Save.coins = Save.STARTING_COINS
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
	Save.daily_streak = 0
	Save.last_daily_claim = ""
	Save.ad_count_today = 0
	Save.ad_coins_today = 0
	Save.ad_date = ""
	Save.aim_assist_until = 0
	Save.aim_assist_ads_progress = 0
	Save.interstitial_counter = 0
	Save.pending_pot = 0 # F9: a win pot held on the win screen belongs to this player
	# v11 session persistence: sign-out clears the saved session too,
	# or the next launch would silently restore the old account.
	Save.session_access_token = ""
	Save.session_refresh_token = ""
	Save.session_saved_at = 0
	session_refresh_failed = false
	Save.save()
	Supabase.access_token = ""
	Supabase.user_id = ""
	Supabase.refresh_token = ""
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
