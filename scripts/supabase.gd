class_name SupabaseClient
extends Node

## Supabase backend client (v7): Auth (anonymous sign-in + email OTP +
## Google PKCE loopback), PostgREST (profiles, invites, search_players
## RPC) and Realtime (invite delivery over WebSocket).
##
## Config comes from res://backend_config.json (see
## backend_config.example.json). When it is empty, `configured` is false
## and every call fails fast with a clear error — the game then runs
## local-only (registration still works, stored on the device).
##
## The client never uses the service_role key: all calls use the anon
## key + the player's Supabase Auth session (OTP-verified Gmail, or
## Google sign-in). Row-level security (supabase/schema.sql) enforces
## that a player can only read/write their own rows (plus the
## search_players RPC, which returns name + level only).
##
## Auth flow: the player verifies their Gmail with a 6-digit OTP code
## (send_otp -> verify_otp). That sign-in IS the account — the Auth
## user id for the Gmail becomes the profile id, so there is exactly
## one account per Gmail and the profile restores by signing in with
## the same Gmail. Anonymous sign-in exists as a client capability but
## registration deliberately does NOT use it (an anonymous user id
## would differ from the email user's id, and the profile would end up
## under the wrong id).
##
## Auth endpoints used (GoTrue):
##   POST /auth/v1/signup {}                        -> anonymous session
##   POST /auth/v1/otp {email, create_user:true}    -> sends 6-digit code
##   POST /auth/v1/verify {email, token, type}      -> links Gmail, session
##   POST /auth/v1/token?grant_type=pkce            -> PKCE code exchange
##   POST /auth/v1/token?grant_type=refresh_token   -> restore a saved session
##   GET  /auth/v1/authorize?provider=google...     -> Google sign-in page
##
## Realtime (phoenix channels over WebSocket):
##   wss://<host>/realtime/v1/websocket?apikey=<key>&vsn=1.0.0
##   join realtime:public:invites with a postgres_changes filter;
##   INSERT/UPDATE rows arrive as postgres_changes events.

signal realtime_invite_changed(invite: Dictionary)
signal realtime_connected
signal realtime_failed(message: String)
## Scale hardening (2026-11-28): a session refresh completed (new access
## + refresh tokens) — Accounts persists the rotated tokens on this.
signal session_refreshed
## Scale hardening (2026-11-28): a refresh failed because the refresh
## token itself is dead (invalid_grant) — the player must sign in again.
signal session_refresh_invalid(message: String)
## v11 P2P (§1.4): a signalling message arrived on the match Broadcast
## channel — {type: offer|answer|ice|bye, from, sdp, ...}. Emitted
## after P2PSignalling.parse_message validation in _handle_realtime_text.
signal broadcast_received(msg: Dictionary)

const CONFIG_PATH := "res://backend_config.json"
const REALTIME_VSN := "1.0.0"
const LOOPBACK_PORT := 8765
const LOOPBACK_PATH := "/callback"

## The loopback URL the browser returns to after a Google sign-in or an
## OTP magic-link tap — DESKTOP / EDITOR ONLY (v11). Pure GDScript
## TCPServer — no native code, no intent filter — so it works in the
## editor and on desktop, where the game process stays alive with a
## live socket. It can NOT be relied on on Android: opening the
## browser backgrounds the game and Android routinely kills it, so the
## loopback port is dead by the time the browser returns (v11 user
## report: ERR_CONNECTION_REFUSED on 127.0.0.1:8765). Must stay
## allow-listed in Supabase Dashboard -> Authentication -> URL
## Configuration -> Redirect URLs (desktop/editor sign-ins use it).
const LOOPBACK_REDIRECT := "http://127.0.0.1:8765/callback"

## The URL Android's browser goes back to after a Google sign-in or an
## OTP magic-link tap — the PRIMARY return path on Android (v11).
## Registered in Supabase's Redirect URLs allow-list AND as an intent
## filter in android/build/AndroidManifest.xml (the Gradle main
## manifest — NOT src/debug/AndroidManifest.xml, which Godot
## regenerates from scratch on every export); GodotApp.java writes
## the incoming URI to AUTH_CALLBACK_FILE for the game to pick up
## (vanilla Godot 4.3 does not surface deep links to GDScript).
## Use auth_redirect_url() to pick the right one per platform.
const CUSTOM_SCHEME_REDIRECT := "com.musehiro.carrom://auth-callback"
## File the native side writes the deep-link URI into (getFilesDir() is
## the same directory Godot maps user:// to on Android).
const AUTH_CALLBACK_FILE := "user://auth_callback.txt"

## The redirect_to for an auth return on THIS platform: the custom
## scheme on Android (the browser re-opens the game, even after a cold
## start), the loopback URL on desktop/editor (the game listens on
## 127.0.0.1:8765). Pure — unit-testable via OS.has_feature.
static func auth_redirect_url() -> String:
	return CUSTOM_SCHEME_REDIRECT if OS.has_feature("android") else LOOPBACK_REDIRECT

## Extract the ?code=... from an OAuth callback URI — custom scheme
## (com.musehiro.carrom://auth-callback?code=...) or loopback
## (http://127.0.0.1:8765/callback?code=...). "" when there is no code.
## Pure — unit-tested.
static func parse_callback_code(uri: String) -> String:
	var q := uri.find("?")
	if q < 0:
		return ""
	for part in uri.substr(q + 1).split("&"):
		var kv := part.split("=", false, 1)
		if kv.size() == 2 and kv[0] == "code":
			return kv[1].uri_decode()
	return ""

var configured := false
var base_url := ""
var anon_key := ""
var google_client_id := ""
## Whether the Supabase project's Google provider is enabled (Auth ->
## Providers -> Google). The NEW project (2026-11-27) was created with
## Google OFF, so the game's "Continue with Google" button opened the
## authorize URL and GoTrue answered 400 "Unsupported provider:
## provider is not enabled" — a dead browser page and a stuck player.
## backend_config.json carries this flag (false for the new project);
## the auth screen hides the Google button while it is false, and
## begin_google_sign_in() refuses fast. Default true: configs written
## before the flag existed (old project, Google on) keep working.
var google_enabled := true
var access_token := "" # Supabase Auth session ("" = not signed in)
var refresh_token := "" # GoTrue refresh token ("" = none) — persisted by
## Accounts (Save) so a restart can restore the session; GoTrue rotates
## it on every refresh, so the stored value is rewritten each time.
var user_id := "" # Supabase Auth user id ("" = none)
## Scale hardening (2026-11-28): unix time the access token expires
## (the JWT "exp" claim, read in _set_session). 0 = unknown (the token
## is not a decodable JWT — e.g. the test mock's "tok-<uid>"). The
## proactive refresh (ensure_fresh_session) fires ~5 min before this.
var session_expires_at := 0
## Scale hardening (2026-11-28): refresh 5 min before the access token
## expires, so a session open >1 h never starts 401-ing on every poll.
const TOKEN_REFRESH_LEAD_SECONDS := 300
## Scale hardening (2026-11-28): the 401-retry single-flight flag +
## the earliest unix time another refresh may be attempted (a failed
## refresh backs off 60 s instead of retrying on every 401'd request).
var _refresh_in_flight := false
var _refresh_next_try_at := 0

var _ws: WebSocketPeer = null
var _ws_want := false
var _ws_ref := 0
var _ws_my_id := ""
var _ws_heartbeat := 0.0
var _ws_joined := false
## v11 P2P (§1.4): the match Broadcast channel joined on THIS socket
## ("" = none). One socket total — the invites postgres_changes channel
## and the match Broadcast channel share this one WebSocketPeer.
var _ws_match_channel := ""
var _ws_match_joined := false

## v11 P2P (§1.5): ICE servers from backend_config.json ("turn_servers").
## Empty/absent = the plan defaults (Google STUN + OpenRelay demo TURN)
## via P2PSignalling.ice_servers_from_config. Never logged.
var turn_servers: Array = []

func _ready() -> void:
	load_config()

## L8: a malformed backend_config.json must fall back to local-only
## cleanly — JSON.parse_string returns null on bad JSON (and a
## non-Dictionary on e.g. a JSON array), so check the type BEFORE
## touching the value; the old code called .is_empty() on the null and
## errored out of the load. `path` is a test seam: the mock test feeds
## a bad file to prove the fallback.
func load_config(path: String = CONFIG_PATH) -> void:
	if not FileAccess.file_exists(path):
		configured = false
		return
	var text := FileAccess.get_file_as_string(path)
	var parsed: Variant = JSON.parse_string(text)
	if not (parsed is Dictionary):
		configured = false
		return
	var data: Dictionary = parsed
	if data.is_empty():
		configured = false
		return
	base_url = String(data.get("supabase_url", "")).strip_edges().trim_suffix("/")
	anon_key = String(data.get("supabase_anon_key", "")).strip_edges()
	google_client_id = String(data.get("google_client_id", "")).strip_edges()
	# Google provider flag (see var google_enabled above): absent =
	# true, so pre-flag configs keep the old behaviour.
	google_enabled = bool(data.get("google_enabled", true))
	# v11 P2P: ICE servers override (backend_config.json "turn_servers").
	# Anything else (missing, wrong type, empty) falls back to the
	# plan defaults inside ice_servers() — never a hard failure.
	var ts: Variant = data.get("turn_servers", [])
	turn_servers = ts if ts is Array else []
	configured = base_url != "" and anon_key != ""

## v11 P2P (§1.5): the ICE server list for WebRTCPeerConnection — the
## configured turn_servers when valid, else the plan defaults.
func ice_servers() -> Array:
	return P2PSignalling.ice_servers_from_config(turn_servers)

## Test override: point the client at a mock server (tests) instead of
## the configured project. Pass "" to clear the override.
func set_config(url: String, key: String, client_id: String = "", google: bool = true) -> void:
	base_url = url.strip_edges().trim_suffix("/")
	anon_key = key.strip_edges()
	google_client_id = client_id.strip_edges()
	google_enabled = google
	configured = base_url != "" and anon_key != ""

func _process(delta: float) -> void:
	if _ws == null:
		return
	_ws.poll()
	var state := _ws.get_ready_state()
	if state == WebSocketPeer.STATE_OPEN:
		if not _ws_joined:
			_ws_joined = true
			_join_realtime_channel()
		# v11 P2P: the match Broadcast channel joins on this same
		# socket once it is open (join_match_channel may have been
		# called before the socket was ready — the name is stored).
		if _ws_match_channel != "" and not _ws_match_joined:
			_ws_match_joined = true
			_join_match_channel()
		_ws_heartbeat += delta
		if _ws_heartbeat >= 30.0:
			_ws_heartbeat = 0.0
			_ws_ref += 1
			_ws.send_text(JSON.stringify({"topic": "phoenix", "event": "heartbeat", "payload": {}, "ref": str(_ws_ref)}))
		while _ws.get_available_packet_count() > 0:
			var text := _ws.get_packet().get_string_from_utf8()
			_handle_realtime_text(text)
	elif state == WebSocketPeer.STATE_CLOSED and _ws_want:
		_ws_want = false
		_ws = null
		realtime_failed.emit("Realtime connection closed.")

# ------------------------------------------------------------------ HTTP

func _headers(auth: bool) -> PackedStringArray:
	var h := PackedStringArray()
	h.append("apikey: %s" % anon_key)
	if auth and access_token != "":
		h.append("Authorization: Bearer %s" % access_token)
	else:
		h.append("Authorization: Bearer %s" % anon_key)
	h.append("Content-Type: application/json")
	return h

## Human name for an HTTPRequest result code (for error strings and
## logs — a bare "HTTP 0" never says why a request died). Pure.
static func _http_result_name(result: int) -> String:
	match result:
		HTTPRequest.RESULT_SUCCESS:
			return "ok"
		HTTPRequest.RESULT_CHUNKED_BODY_SIZE_MISMATCH:
			return "chunked body size mismatch"
		HTTPRequest.RESULT_CANT_CONNECT:
			return "could not connect to the server"
		HTTPRequest.RESULT_CANT_RESOLVE:
			return "could not resolve the server address"
		HTTPRequest.RESULT_CONNECTION_ERROR:
			return "connection error"
		HTTPRequest.RESULT_TLS_HANDSHAKE_ERROR:
			return "TLS handshake failed"
		HTTPRequest.RESULT_NO_RESPONSE:
			return "server gave no response"
		HTTPRequest.RESULT_BODY_SIZE_LIMIT_EXCEEDED:
			return "response too large"
		HTTPRequest.RESULT_BODY_DECOMPRESS_FAILED:
			return "response could not be decompressed"
		HTTPRequest.RESULT_REQUEST_FAILED:
			return "request failed"
		HTTPRequest.RESULT_DOWNLOAD_FILE_CANT_OPEN:
			return "download file could not be opened"
		HTTPRequest.RESULT_DOWNLOAD_FILE_WRITE_ERROR:
			return "download file write failed"
		HTTPRequest.RESULT_REDIRECT_LIMIT_REACHED:
			return "too many redirects"
		HTTPRequest.RESULT_TIMEOUT:
			return "timed out"
		_:
			return "unknown transport error (%d)" % result

## Human name for an HTTPClient method (logs only). Pure.
static func _http_method_name(method: int) -> String:
	match method:
		HTTPClient.METHOD_GET:
			return "GET"
		HTTPClient.METHOD_POST:
			return "POST"
		HTTPClient.METHOD_PUT:
			return "PUT"
		HTTPClient.METHOD_PATCH:
			return "PATCH"
		HTTPClient.METHOD_DELETE:
			return "DELETE"
		_:
			return "HTTP %d" % method

## One HTTP call. Returns {ok, status, data, error}. `path` is appended
## to base_url (already starts with "/"). `timeout_sec` caps the wait —
## the default 15 s is for user-initiated calls (OTP verify, sign-in);
## session restore at startup passes a shorter cap so a hanging network
## cannot stall the home screen. Never throws. Every failure path
## returns a dict WITH a non-empty "error" string (2026-11-28: the
## queue insert surfaced the "(connection failed)" DEFAULT because a
## caller got a dict with no error key at all — that must never happen
## again; a transport failure names its HTTPRequest result code).
func _http(method: int, path: String, body: Dictionary = {}, auth: bool = true, extra_headers: PackedStringArray = PackedStringArray(), timeout_sec: float = 15.0, _allow_401_retry: bool = true) -> Dictionary:
	if not configured:
		return {"ok": false, "status": 0, "data": null, "error": "Supabase is not configured yet (backend_config.json is empty)."}
	var req := HTTPRequest.new()
	req.timeout = timeout_sec
	add_child(req)
	var headers := _headers(auth)
	for extra in extra_headers:
		headers.append(extra)
	var payload := JSON.stringify(body) if not body.is_empty() else ""
	var url := base_url + path
	var err := req.request(url, headers, method, payload)
	if err != OK:
		print("[HTTP] request could not start: %s %s err=%s" % [_http_method_name(method), url, error_string(err)])
		req.queue_free()
		return {"ok": false, "status": 0, "data": null, "error": "Could not start the request (%s)." % error_string(err)}
	var res: Array = await req.request_completed
	req.queue_free()
	# res[0] is the HTTPRequest result code — it MUST be checked: a
	# transport failure (connection refused, TLS error, timeout) fires
	# request_completed with result != SUCCESS, status 0 and an empty
	# body, which the old code read as "Request failed (HTTP 0)." with
	# no hint of the cause. Name the result instead.
	var result := int(res[0])
	if result != HTTPRequest.RESULT_SUCCESS:
		var rname := _http_result_name(result)
		print("[HTTP] request failed: %s %s result=%d (%s)" % [_http_method_name(method), url, result, rname])
		return {"ok": false, "status": 0, "data": null, "error": "Connection failed (%s)." % rname}
	var status := int(res[1])
	# Scale hardening (2026-11-28): a 401 on an authenticated call
	# means the access token expired mid-session (GoTrue JWTs live
	# 1 h). Refresh once and retry the SAME request once with the new
	# token instead of failing every poll until the next restart. The
	# retry is single-flight + backoff-guarded inside
	# _refresh_session_once, and never recurses (the retry passes
	# _allow_401_retry=false; the token endpoint itself is excluded
	# by should_retry_after_401). A failed refresh returns the
	# original 401 — the caller sees the same error as before.
	if should_retry_after_401(status, auth, path, _allow_401_retry):
		if await _refresh_session_once():
			return await _http(method, path, body, auth, extra_headers, timeout_sec, false)
	var raw: PackedByteArray = res[3]
	var text := raw.get_string_from_utf8()
	var data: Variant = JSON.parse_string(text) if text != "" else null
	if status >= 200 and status < 300:
		return {"ok": true, "status": status, "data": data, "error": ""}
	var msg := ""
	if data is Dictionary and String(data.get("msg", "")) != "":
		msg = String(data.get("msg"))
	elif data is Dictionary and String(data.get("message", "")) != "":
		msg = String(data.get("message"))
	elif data is Dictionary and String(data.get("error_description", "")) != "":
		msg = String(data.get("error_description"))
	elif text != "":
		msg = text.substr(0, 200)
	else:
		msg = "Request failed (HTTP %d)." % status
	return {"ok": false, "status": status, "data": data, "error": msg}

func _set_session(session: Dictionary) -> void:
	access_token = String(session.get("access_token", ""))
	# Scale hardening (2026-11-28): track the token expiry for the
	# proactive mid-session refresh (ensure_fresh_session). A token
	# with no decodable "exp" leaves the expiry unknown (0) — the
	# 401-retry path in _http is the backstop for those.
	session_expires_at = jwt_exp(access_token)
	# GoTrue rotates the refresh token on refresh — keep the new one.
	# A response without one (never in practice) keeps the old token
	# instead of blanking it.
	var new_refresh := String(session.get("refresh_token", ""))
	if new_refresh != "":
		refresh_token = new_refresh
	var user: Dictionary = session.get("user", {})
	user_id = String(user.get("id", ""))

# ------------------------------------------------------------------ Auth

## Anonymous sign-in (no email, no password). Creates a Supabase Auth
## user. Kept as a client capability (and exercised by the mock test);
## registration does NOT use it — the OTP-verified Gmail IS the
## account, so the profile id is always the email user's id. Requires
## "Allow anonymous sign-ins" in the dashboard (see docs/supabase-setup.md).
func signup_anonymous() -> Dictionary:
	var res := await _http(HTTPClient.METHOD_POST, "/auth/v1/signup", {}, false)
	if not bool(res["ok"]):
		return res
	_set_session(res["data"] if res["data"] is Dictionary else {})
	if access_token == "" or user_id == "":
		return {"ok": false, "status": int(res["status"]), "data": res["data"], "error": "Anonymous sign-in did not return a session."}
	return {"ok": true, "status": int(res["status"]), "data": res["data"], "error": ""}

## Send a 6-digit login code to the Gmail (Supabase sends it). Works
## for a new Gmail (creates the Auth user) and for an existing one.
## `redirect_to` + `code_challenge` go on the REQUEST PATH as query
## parameters (v10): GoTrue takes them as options, NOT in the JSON body
## — the body form returns HTTP 400. The redirect is
## auth_redirect_url() (custom scheme on Android, loopback on
## desktop/editor) so the email's "Sign in" link returns to the game
## instead of the Site URL (localhost:3000); the challenge makes the
## link carry ?code= so the return path can complete it (PKCE, like the
## official clients). The email template itself must ALSO show the
## 6-digit code {{.Token}} — that is a dashboard setting, not code
## (see docs/verification.md v10).
static func otp_path(redirect_to: String = "", code_challenge: String = "") -> String:
	var path := "/auth/v1/otp"
	var params := PackedStringArray()
	if redirect_to != "":
		params.append("redirect_to=" + redirect_to.uri_encode())
	if code_challenge != "":
		params.append("code_challenge=" + code_challenge.uri_encode())
		params.append("code_challenge_method=S256")
	if not params.is_empty():
		path += "?" + "&".join(params)
	return path

func send_otp(email: String, redirect_to: String = "", code_challenge: String = "") -> Dictionary:
	return await _http(HTTPClient.METHOD_POST, otp_path(redirect_to, code_challenge),
		{"email": email, "create_user": true}, false)

## Send the 6-digit code WITHOUT a redirect or PKCE challenge (the
## fallback in Accounts.request_login_code). A fresh Supabase project
## allow-lists no Redirect URLs, so GoTrue can reject the redirect
## variant above — the code email itself still works without it; only
## the "Sign in" magic-link return is lost, and the 6-digit code stays
## the primary path. No return listener is started for this variant.
func send_otp_code_only(email: String) -> Dictionary:
	return await _http(HTTPClient.METHOD_POST, "/auth/v1/otp",
		{"email": email, "create_user": true}, false)

## True when a GoTrue error message says the redirect was rejected
## ("redirect_to is not allowed" and friends). Pure — unit-tested.
## Used to decide the code-only retry above; a failed OTP for any
## other reason (rate limit, bad email) must NOT be retried — the
## player would get a second code email for a problem a resend cannot
## fix, and a rate-limit retry would only burn the quota.
static func looks_like_redirect_error(msg: String) -> bool:
	return msg.strip_edges().to_lower().contains("redirect")

## Verify the 6-digit code. On success the Gmail is linked to the
## current Auth user and a session is returned.
func verify_otp(email: String, token: String) -> Dictionary:
	var res := await _http(HTTPClient.METHOD_POST, "/auth/v1/verify",
		{"email": email, "token": token, "type": "email"}, false)
	if not bool(res["ok"]):
		return res
	_set_session(res["data"] if res["data"] is Dictionary else {})
	if access_token == "" or user_id == "":
		return {"ok": false, "status": int(res["status"]), "data": res["data"], "error": "Verification did not return a session."}
	return {"ok": true, "status": int(res["status"]), "data": res["data"], "error": ""}

## Google sign-in, PKCE flavour: on Android the browser returns via
## the custom-scheme deep link (auth_redirect_url()), on desktop via
## the http://127.0.0.1:8765/callback loopback listener, so no native
## plugin is needed on desktop. Returns the authorize URL + the
## verifier the caller must keep for the exchange. The caller opens
## the URL in the browser (OS.shell_open) and feeds the ?code=... from
## the callback into exchange_pkce_code().
static func google_authorize_url(base: String, verifier: String, redirect_to: String) -> String:
	var challenge := pkce_challenge(verifier)
	return "%s/auth/v1/authorize?provider=google&redirect_to=%s&code_challenge=%s&code_challenge_method=S256" % [
		base, redirect_to.uri_encode(), challenge]

func exchange_pkce_code(code: String, verifier: String) -> Dictionary:
	var res := await _http(HTTPClient.METHOD_POST, "/auth/v1/token?grant_type=pkce",
		{"auth_code": code, "code_verifier": verifier}, false)
	if not bool(res["ok"]):
		return res
	_set_session(res["data"] if res["data"] is Dictionary else {})
	if access_token == "" or user_id == "":
		return {"ok": false, "status": int(res["status"]), "data": res["data"], "error": "Google sign-in did not return a session."}
	return {"ok": true, "status": int(res["status"]), "data": res["data"], "error": ""}

## Extract OAuth tokens from a callback URI's fragment OR query
## (...#access_token=...&refresh_token=... or
## ...?access_token=...&refresh_token=...). Browsers never send the
## fragment to a server, so this only arrives via a pasted link or the
## deep-link file — the defensive path when GoTrue answers with an
## implicit-flow redirect instead of ?code=. {} when absent. Pure.
static func parse_fragment_tokens(uri: String) -> Dictionary:
	var tail := ""
	var h := uri.find("#")
	if h >= 0:
		tail = uri.substr(h + 1)
	else:
		var q := uri.find("?")
		if q < 0:
			return {}
		tail = uri.substr(q + 1)
	var out := {}
	for part in tail.split("&"):
		var kv := part.split("=", false, 1)
		if kv.size() == 2 and (kv[0] == "access_token" or kv[0] == "refresh_token"):
			out[kv[0]] = kv[1].uri_decode()
	if String(out.get("access_token", "")) == "":
		return {}
	return out

## The "sub" (user id) inside a JWT access token. Pure — no network.
## "" when the token is not a decodable JWT.
static func jwt_sub(token: String) -> String:
	var parts := token.split(".")
	if parts.size() != 3:
		return ""
	var payload_b64: String = parts[1].replace("-", "+").replace("_", "/")
	while payload_b64.length() % 4 != 0:
		payload_b64 += "="
	var payload: Variant = JSON.parse_string(Marshalls.base64_to_raw(payload_b64).get_string_from_utf8())
	if payload is Dictionary:
		return String(payload.get("sub", ""))
	return ""

## The "exp" (expiry, unix seconds) inside a JWT access token. Pure —
## no network. 0 when the token is not a decodable JWT or carries no
## "exp" (the test mock's "tok-<uid>" tokens) — the caller treats 0 as
## "expiry unknown", never as "already expired".
static func jwt_exp(token: String) -> int:
	var parts := token.split(".")
	if parts.size() != 3:
		return 0
	var payload_b64: String = parts[1].replace("-", "+").replace("_", "/")
	while payload_b64.length() % 4 != 0:
		payload_b64 += "="
	var payload: Variant = JSON.parse_string(Marshalls.base64_to_raw(payload_b64).get_string_from_utf8())
	if payload is Dictionary:
		return int(payload.get("exp", 0))
	return 0

## The refresh-token grant path (GoTrue). Pure — unit-tested.
static func refresh_token_path() -> String:
	return "/auth/v1/token?grant_type=refresh_token"

## Exchange a stored refresh token for a fresh session (GoTrue rotates
## both tokens). Used by Accounts.restore_session() on startup — the
## session must be restored BEFORE Friends starts listening, or the
## lobby/presence run as `anon` and RLS denies them. The restore call
## is capped at 8 s so a hanging network cannot stall the home screen
## (the default 15 s cap is for user-initiated calls). Returns the raw
## result dict {ok, status, data, error}; on success _set_session has
## run (new access + refresh tokens, same user). Never throws.
func refresh_session(refresh_token_value: String) -> Dictionary:
	if refresh_token_value == "":
		return {"ok": false, "status": 0, "data": null, "error": "No saved session to restore."}
	var res := await _http(HTTPClient.METHOD_POST, refresh_token_path(),
		{"refresh_token": refresh_token_value}, false, PackedStringArray(), 8.0)
	if not bool(res["ok"]):
		# Scale hardening (2026-11-28): a dead refresh token is not a
		# transient failure — no retry will fix it, and the player
		# must sign in again. Surface it on its own signal so
		# Accounts can say so (lobby "sign in again") instead of
		# silently 401-ing every call until the next restart.
		if looks_like_invalid_refresh_token(res):
			session_refresh_invalid.emit(String(res.get("error", "Invalid refresh token.")))
		return res
	_set_session(res["data"] if res["data"] is Dictionary else {})
	if access_token == "" or user_id == "":
		return {"ok": false, "status": int(res["status"]), "data": res["data"], "error": "Session refresh did not return a session."}
	# The refresh rotated both tokens — Accounts persists them on
	# this signal (a restart must restore with the NEW refresh token;
	# GoTrue revokes the old one).
	session_refreshed.emit()
	return {"ok": true, "status": int(res["status"]), "data": res["data"], "error": ""}

## True when a GoTrue refresh failure says the refresh token itself is
## dead ("Invalid refresh token." / invalid_grant) — as opposed to a
## transient failure (network, 5xx) that a later retry may fix. Pure —
## unit-tested. Only a dead token sets the must-sign-in-again state.
static func looks_like_invalid_refresh_token(res: Dictionary) -> bool:
	if int(res.get("status", 0)) != 400:
		return false
	var msg := String(res.get("error", "")).to_lower()
	return msg.contains("invalid refresh token") or msg.contains("invalid_grant") or msg.contains("refresh token not found")

## True when a 401 on an authenticated call is worth one refresh +
## retry (the _http backstop). Pure — unit-tested. The token endpoint
## itself is excluded (a 401 there IS the refresh failing — retrying
## it would loop), as are unauthenticated calls (no session to refresh)
## and retries (exactly one retry per request).
static func should_retry_after_401(status: int, auth: bool, path: String, allow_retry: bool) -> bool:
	return allow_retry and auth and status == 401 and not path.begins_with("/auth/v1/token")

## True when the session should be refreshed NOW: a live access token
## whose expiry is known and less than TOKEN_REFRESH_LEAD_SECONDS
## away. Unknown expiry (0) is false — with no "exp" to read there is
## nothing to schedule, and the 401-retry path is the backstop.
func session_needs_refresh() -> bool:
	if access_token == "" or session_expires_at <= 0:
		return false
	return int(Time.get_unix_time_from_system()) >= session_expires_at - TOKEN_REFRESH_LEAD_SECONDS

## Proactively refresh the session when it is about to expire (the
## mid-session refresh — called by Accounts' 60 s check, and by _http
## after a 401). Returns true when no refresh was needed or the
## refresh succeeded, false when a refresh was due but could not be
## done. Never loops: a failed attempt backs off 60 s (see
## _refresh_next_try_at) and a concurrent attempt waits for the one
## already in flight instead of starting a second refresh.
func ensure_fresh_session() -> bool:
	if not session_needs_refresh():
		return true
	return await _refresh_session_once()

## One refresh attempt, single-flight + backoff-guarded. When another
## refresh is already in flight, waits for it (up to 10 s) and reports
## whether the session came back live. When the last attempt failed
## recently, returns false at once instead of hammering GoTrue on
## every 401'd request. Never throws.
func _refresh_session_once() -> bool:
	if _refresh_in_flight:
		var waited := 0.0
		while _refresh_in_flight and waited < 10.0:
			await get_tree().create_timer(0.1).timeout
			waited += 0.1
		return access_token != "" and not session_needs_refresh()
	if int(Time.get_unix_time_from_system()) < _refresh_next_try_at:
		return false
	if refresh_token == "":
		return false
	_refresh_in_flight = true
	var res := await refresh_session(refresh_token)
	_refresh_in_flight = false
	if bool(res.get("ok", false)):
		print("[AUTH] session refreshed (mid-session, before expiry)")
		return true
	# Back off 60 s: a failing refresh must not be retried on every
	# poll tick (a dead network would turn every 2 s poll into a
	# refresh attempt). A dead refresh token is signalled separately
	# by refresh_session (session_refresh_invalid).
	_refresh_next_try_at = int(Time.get_unix_time_from_system()) + 60
	print("[AUTH] session refresh failed (%s) — backing off 60 s" % String(res.get("error", "unknown error")))
	return false

## Adopt tokens received out-of-band (a pasted implicit-flow link).
## Sets the session from the access token; the caller still needs the
## user's email (get_user) before the profile can load. The refresh
## token is kept too (it used to be dropped) so the session can be
## restored after a restart like any other sign-in.
func set_session_from_tokens(access_token_value: String, refresh_token_value: String) -> bool:
	var sub := jwt_sub(access_token_value)
	if sub == "":
		return false
	access_token = access_token_value
	refresh_token = refresh_token_value
	session_expires_at = jwt_exp(access_token_value)
	user_id = sub
	return true

## Fetch the signed-in user's record (the email lives here when the
## session came from tokens rather than a PKCE code exchange).
func get_user() -> Dictionary:
	return await _http(HTTPClient.METHOD_GET, "/auth/v1/user", {}, true)

# ---------------------------------------------------------------- profiles

func upsert_profile(row: Dictionary) -> Dictionary:
	var res := await _http(HTTPClient.METHOD_POST, "/rest/v1/profiles?on_conflict=id",
		row, true, PackedStringArray(["Prefer: return=representation,resolution=merge-duplicates"]))
	if not bool(res["ok"]):
		return res
	return {"ok": true, "status": int(res["status"]), "data": res["data"], "error": ""}

func get_profile_by_id(profile_id: String) -> Dictionary:
	var res := await _http(HTTPClient.METHOD_GET,
		"/rest/v1/profiles?select=*&id=eq.%s" % profile_id.uri_encode(), {}, true)
	if not bool(res["ok"]):
		return res
	var rows: Array = res["data"] if res["data"] is Array else []
	return {"ok": true, "status": int(res["status"]),
		"data": rows[0] if not rows.is_empty() else {}, "error": ""}

func get_profile_by_gmail(gmail: String) -> Dictionary:
	var res := await _http(HTTPClient.METHOD_GET,
		"/rest/v1/profiles?select=*&gmail=eq.%s" % gmail.uri_encode(), {}, true)
	if not bool(res["ok"]):
		return res
	var rows: Array = res["data"] if res["data"] is Array else []
	return {"ok": true, "status": int(res["status"]),
		"data": rows[0] if not rows.is_empty() else {}, "error": ""}

# ------------------------------------------------------------------ search

## Friend search by display name only (never by Gmail). Returns an Array
## of {id, display_name, level}. The caller (exclude_id) is excluded.
func search_players(query: String, exclude_id: String) -> Dictionary:
	var res := await _http(HTTPClient.METHOD_POST, "/rest/v1/rpc/search_players",
		{"q": query, "exclude_id": exclude_id}, true)
	if not bool(res["ok"]):
		return res
	return {"ok": true, "status": int(res["status"]),
		"data": res["data"] if res["data"] is Array else [], "error": ""}

# ----------------------------------------------------------------- invites

func send_invite(row: Dictionary) -> Dictionary:
	var res := await _http(HTTPClient.METHOD_POST, "/rest/v1/invites",
		row, true, PackedStringArray(["Prefer: return=representation"]))
	if not bool(res["ok"]):
		return res
	var rows: Array = res["data"] if res["data"] is Array else []
	return {"ok": true, "status": int(res["status"]),
		"data": rows[0] if not rows.is_empty() else {}, "error": ""}

func list_incoming_invites(my_id: String) -> Dictionary:
	var res := await _http(HTTPClient.METHOD_GET,
		"/rest/v1/invites?select=*&to_id=eq.%s&status=eq.pending&order=created_at.desc" % my_id.uri_encode(),
		{}, true)
	if not bool(res["ok"]):
		return res
	return {"ok": true, "status": int(res["status"]),
		"data": res["data"] if res["data"] is Array else [], "error": ""}

## L2: invites I sent (pending AND accepted) — restoring them after a
## restart is what lets pre-restart groups become ready. The accepted
## half matters: a half-accepted group has accepted rows, and fetching
## only pending rows would make _check_group see a group that can
## never become "ready". RLS "invites read for parties" permits the
## sender (from_id) to select these rows (supabase/schema.sql).
func list_outgoing_invites(my_id: String) -> Dictionary:
	var res := await _http(HTTPClient.METHOD_GET,
		"/rest/v1/invites?select=*&from_id=eq.%s&status=in.(pending,accepted)&order=created_at.desc" % my_id.uri_encode(),
		{}, true)
	if not bool(res["ok"]):
		return res
	return {"ok": true, "status": int(res["status"]),
		"data": res["data"] if res["data"] is Array else [], "error": ""}

func list_group_invites(group_id: String) -> Dictionary:
	var res := await _http(HTTPClient.METHOD_GET,
		"/rest/v1/invites?select=*&group_id=eq.%s&order=created_at.asc" % group_id.uri_encode(),
		{}, true)
	if not bool(res["ok"]):
		return res
	return {"ok": true, "status": int(res["status"]),
		"data": res["data"] if res["data"] is Array else [], "error": ""}

func update_invite(invite_id: String, status: String) -> Dictionary:
	var res := await _http(HTTPClient.METHOD_PATCH,
		"/rest/v1/invites?id=eq.%s" % invite_id.uri_encode(),
		{"status": status}, true, PackedStringArray(["Prefer: return=representation"]))
	if not bool(res["ok"]):
		return res
	var rows: Array = res["data"] if res["data"] is Array else []
	return {"ok": true, "status": int(res["status"]),
		"data": rows[0] if not rows.is_empty() else {}, "error": ""}

# ------------------------------------------------- v11 P2P matchmaking (plan §1.3)
# Queue + matches rows + the find_match / create_match_from_invites
# RPCs (supabase/schema-p2p.sql — run in the dashboard first; until
# then these calls fail cleanly and ONLINE falls back to the legacy
# ENet path via Net's transport switch).

## Insert (or refresh) my matchmaking_queue row.
## Belt and braces (2026-11-28): the live queue UPDATE policy was
## keyed on user_id while rows carry id = auth uid, so an upsert of an
## existing row 403'd. The row is stamped with user_id = the Auth uid
## (alongside id) so it satisfies either policy convention; the SQL
## side adds an id-based UPDATE policy too. Never throws.
## ROOT CAUSE (2026-11-28 03:3x): this function's [MATCH] log used
## String(row.get("table")) / String(row.get("stake")) — but table and
## stake are INTS, and GDScript 4.3 has NO String(int) constructor, not
## even through a Variant: the print threw "Nonexistent 'String'
## constructor" BEFORE the await, so the POST never left the phone and
## the caller saw the "(connection failed)" DEFAULT. str() converts
## anything (int, String, null) — NEVER use String() on a value that
## might be an int. A transport failure (status 0) is retried ONCE.
func queue_insert(row: Dictionary) -> Dictionary:
	if user_id != "" and String(row.get("user_id", "")) == "":
		row["user_id"] = user_id
	print("[MATCH] queue_insert -> player=%s mode=%s table=%s stake=%s url=%s t=%s" % [
		str(row.get("id", "")), str(row.get("mode", "")), str(row.get("table", "")),
		str(row.get("stake", "")), base_url + "/rest/v1/matchmaking_queue?on_conflict=id",
		Time.get_datetime_string_from_system(true, false)])
	var res := await _queue_insert_once(row)
	if should_retry_queue_insert(res):
		print("[MATCH] queue_insert transport failure, retrying once: %s" % str(res.get("error", "")))
		res = await _queue_insert_once(row)
	print("[MATCH] queue_insert <- ok=%s status=%s body=%s" % [
		str(res.get("ok", false)), str(res.get("status", 0)), JSON.stringify(res.get("data"))])
	if not bool(res.get("ok", false)):
		return res
	var rows: Array = res["data"] if res["data"] is Array else []
	return {"ok": true, "status": int(res["status"]),
		"data": rows[0] if not rows.is_empty() else {}, "error": ""}

## Retry the queue insert ONLY on a transport failure (status 0 — the
## request never reached the server, so a second attempt is safe and
## cannot double-insert). An HTTP error (403/404/5xx) is NOT retried:
## the server answered, and retrying a 4xx would only repeat it.
## Pure — unit-tested.
static func should_retry_queue_insert(res: Dictionary) -> bool:
	return not bool(res.get("ok", false)) and int(res.get("status", 0)) == 0

## One queue upsert attempt (POST with the merge-duplicates Prefer).
func _queue_insert_once(row: Dictionary) -> Dictionary:
	return await _http(HTTPClient.METHOD_POST, "/rest/v1/matchmaking_queue?on_conflict=id",
		row, true, PackedStringArray(["Prefer: return=representation,resolution=merge-duplicates"]))

## Delete my queue row (cancel / timeout / matched).
func queue_delete(my_id: String) -> Dictionary:
	return await _http(HTTPClient.METHOD_DELETE,
		"/rest/v1/matchmaking_queue?id=eq.%s" % my_id.uri_encode(), {}, true)

## The find_match RPC body. p_strict is sent ONLY when strict is true:
## the live function gains p_strict additively, and PostgREST rejects
## an RPC call carrying an argument the function does not have yet —
## sending it always would break every non-strict call until the SQL
## lands. Strict = same-level only (window 0); default = the normal
## ±2 window (±4 widened). Pure — unit-tested.
static func find_match_body(mode: String, widen: bool, strict: bool = false) -> Dictionary:
	var body := {"p_mode": mode, "p_widen": widen}
	if strict:
		body["p_strict"] = true
	return body

## The atomic pairing RPC. Returns the raw RPC dict: {matched, match_id,
## players} or {matched:false, error?}. The caller must have queued first.
## A 404 / 5xx / network error here is TRANSIENT (2026-11-28: the one
## call that should have matched died on a PostgREST 42883 schema-cache
## error) — the caller retries in 2-3 s, never treats it as fatal.
## [MATCH] logs every call and every response, greppable in the log.
func call_find_match(mode: String, widen: bool, strict: bool = false) -> Dictionary:
	print("[MATCH] find_match -> player=%s mode=%s widen=%s strict=%s t=%s" % [
		user_id, mode, str(widen), str(strict), Time.get_datetime_string_from_system(true, false)])
	var res := await _http(HTTPClient.METHOD_POST, "/rest/v1/rpc/find_match",
		find_match_body(mode, widen, strict), true)
	print("[MATCH] find_match <- ok=%s status=%s body=%s" % [
		str(res.get("ok", false)), str(res.get("status", 0)), JSON.stringify(res.get("data"))])
	return res

## The invite-match RPC. Returns {ok, match_id, players} once every
## invite in the group is accepted, else {ok:false}.
func call_create_match_from_invites(group_id: String) -> Dictionary:
	print("[MATCH] create_match_from_invites -> player=%s group=%s t=%s" % [
		user_id, group_id, Time.get_datetime_string_from_system(true, false)])
	var res := await _http(HTTPClient.METHOD_POST, "/rest/v1/rpc/create_match_from_invites",
		{"p_group_id": group_id}, true)
	print("[MATCH] create_match_from_invites <- ok=%s status=%s body=%s" % [
		str(res.get("ok", false)), str(res.get("status", 0)), JSON.stringify(res.get("data"))])
	return res

## Fetch one matches row by id (join_match). Returns the row dict or {}.
## The id filter is exact on PostgREST; the id on the returned row is
## still checked, so a stray row can never be joined by mistake.
func get_match_by_id(match_id: String) -> Dictionary:
	print("[MATCH] get_match -> player=%s id=%s t=%s" % [
		user_id, match_id, Time.get_datetime_string_from_system(true, false)])
	var res := await _http(HTTPClient.METHOD_GET,
		"/rest/v1/matches?select=*&id=eq.%s" % match_id.uri_encode(), {}, true)
	print("[MATCH] get_match <- ok=%s status=%s body=%s" % [
		str(res.get("ok", false)), str(res.get("status", 0)), JSON.stringify(res.get("data"))])
	if not bool(res["ok"]):
		return {}
	var rows: Array = res["data"] if res["data"] is Array else []
	for row in rows:
		if row is Dictionary and String(row.get("id", "")) == match_id:
			return row
	return {}

## All joinable matches rows I am in, newest first. Status is the
## in.(waiting,ready,playing) set — a match NEVER moves to 'started'
## (nothing sets it), so waiting-only would work today but would miss
## a row the server later marks ready/playing. [] on any error: the
## caller retries next tick, never treats it as fatal.
func poll_matches_for_me(my_id: String) -> Array:
	print("[MATCH] poll_matches_for_me -> player=%s t=%s" % [
		my_id, Time.get_datetime_string_from_system(true, false)])
	var res := await _http(HTTPClient.METHOD_GET,
		"/rest/v1/matches?select=*&player_ids=cs.{%s}&status=in.(waiting,ready,playing)&order=created_at.desc" % my_id.uri_encode(),
		{}, true)
	print("[MATCH] poll_matches_for_me <- ok=%s status=%s body=%s" % [
		str(res.get("ok", false)), str(res.get("status", 0)), JSON.stringify(res.get("data"))])
	if not bool(res["ok"]):
		return []
	return res["data"] if res["data"] is Array else []

## Poll for a matches row I am in (the OTHER side of a random pairing
## learns it was matched this way — REST polling, unlimited on the free
## tier, no Realtime messages). Returns the row dict or {}. Legacy
## single-row helper over poll_matches_for_me (newest first).
func poll_match_for_me(my_id: String) -> Dictionary:
	var rows := await poll_matches_for_me(my_id)
	return rows[0] if not rows.is_empty() else {}

## All joinable matches rows for an invite group, newest first.
func poll_matches_by_group(group_id: String) -> Array:
	print("[MATCH] poll_matches_by_group -> player=%s group=%s t=%s" % [
		user_id, group_id, Time.get_datetime_string_from_system(true, false)])
	var res := await _http(HTTPClient.METHOD_GET,
		"/rest/v1/matches?select=*&group_id=eq.%s&status=in.(waiting,ready,playing)&order=created_at.desc" % group_id.uri_encode(),
		{}, true)
	print("[MATCH] poll_matches_by_group <- ok=%s status=%s body=%s" % [
		str(res.get("ok", false)), str(res.get("status", 0)), JSON.stringify(res.get("data"))])
	if not bool(res["ok"]):
		return []
	return res["data"] if res["data"] is Array else []

## Poll for a matches row for an invite group (the invitee learns the
## match id this way; the inviter gets it from the RPC return).
## Legacy single-row helper over poll_matches_by_group (newest first).
func poll_match_by_group(group_id: String) -> Dictionary:
	var rows := await poll_matches_by_group(group_id)
	return rows[0] if not rows.is_empty() else {}

## Mark a matches row expired (best-effort — a dead match must not
## linger as 'waiting'). Direct UPDATE is blocked by RLS in
## schema-p2p.sql (no update policy for authenticated), so this is
## expected to fail until a cleanup RPC exists; the caller ignores
## the result. Rows older than 10 min are cleaned by the next search.
func expire_match(match_id: String) -> Dictionary:
	return await _http(HTTPClient.METHOD_PATCH,
		"/rest/v1/matches?id=eq.%s" % match_id.uri_encode(),
		{"status": "expired"}, true, PackedStringArray(["Prefer: return=representation"]))

# ------------------------------------------------------- v11 presence (§11)
# Lobby live-player list: one presence row per online player, heartbeat
# ~30 s. Rows older than ~90 s are treated as offline (client filter).

## Heartbeat my presence row (upsert by id). status: "online" | "in_match".
func heartbeat_presence(my_id: String, display_name: String, level: int, status: String) -> Dictionary:
	var row := {"id": my_id, "display_name": display_name, "level": level,
		"status": status, "updated_at": Time.get_datetime_string_from_system(true, true).replace(" ", "T") + "+00:00"}
	return await _http(HTTPClient.METHOD_POST, "/rest/v1/presence?on_conflict=id",
		row, true, PackedStringArray(["Prefer: return=representation,resolution=merge-duplicates"]))

## Delete my presence row (going offline / signing out).
func delete_presence(my_id: String) -> Dictionary:
	return await _http(HTTPClient.METHOD_DELETE,
		"/rest/v1/presence?id=eq.%s" % my_id.uri_encode(), {}, true)

## All presence rows, newest first — BOUNDED (scale hardening,
## 2026-11-28): the old call fetched the WHOLE presence table
## unpaginated every 10 s in the lobby (an egress bomb at 10k
## players). The query now filters server-side to rows updated in the
## last PRESENCE_FRESH_SECONDS, caps at PRESENCE_MAX_ROWS, and — when
## the viewer's level is known — to the viewer's level band (±4, the
## same band find_match plays in). The client still clamps to
## PRESENCE_MAX_ROWS (a server that ignores `limit` cannot blow the
## list up) and the caller still drops stale rows (Friends
## filter_online_players) as a second net.
const PRESENCE_MAX_ROWS := 50
const PRESENCE_FRESH_SECONDS := 90
const PRESENCE_LEVEL_BAND := 4

## The PostgREST path for list_presence. Pure — unit-tested.
## `now_unix` is a test seam (defaults to now): the freshness cutoff
## is now - PRESENCE_FRESH_SECONDS.
static func presence_list_path(my_level: int = 0, now_unix: int = -1) -> String:
	var now := now_unix if now_unix >= 0 else int(Time.get_unix_time_from_system())
	var since_iso := Time.get_datetime_string_from_unix_time(now - PRESENCE_FRESH_SECONDS, true).replace(" ", "T") + "+00:00"
	var path := "/rest/v1/presence?select=id,display_name,level,status,updated_at&updated_at=gt.%s&order=updated_at.desc&limit=%d" % [since_iso.uri_encode(), PRESENCE_MAX_ROWS]
	if my_level > 0:
		path += "&level=gte.%d&level=lte.%d" % [maxi(1, my_level - PRESENCE_LEVEL_BAND), my_level + PRESENCE_LEVEL_BAND]
	return path

func list_presence(my_level: int = 0) -> Dictionary:
	var res := await _http(HTTPClient.METHOD_GET, presence_list_path(my_level), {}, true)
	if not bool(res["ok"]):
		return res
	var rows: Array = res["data"] if res["data"] is Array else []
	if rows.size() > PRESENCE_MAX_ROWS:
		rows = rows.slice(0, PRESENCE_MAX_ROWS)
	return {"ok": true, "status": int(res["status"]), "data": rows, "error": ""}

## Opportunistic stale-matchmaking cleanup (scale hardening,
## 2026-11-28): POST /rest/v1/rpc/cleanup_stale_matchmaking — no args,
## returns jsonb {ok, expired_matches, deleted_queue_rows,
## expired_invites}. The SQL worker owns the function; until it is
## deployed PostgREST answers 404 ("function does not exist") — the
## caller (Net._maybe_cleanup_stale_matchmaking) treats that as a
## silent no-op via is_cleanup_rpc_missing, never an error. Best-effort
## only: the result is logged, never surfaced to the player.
func call_cleanup_stale_matchmaking() -> Dictionary:
	var res := await _http(HTTPClient.METHOD_POST, "/rest/v1/rpc/cleanup_stale_matchmaking", {}, true)
	if bool(res.get("ok", false)):
		var data: Dictionary = res.get("data", {}) if res.get("data") is Dictionary else {}
		print("[MATCH] cleanup_stale_matchmaking ok=%s expired_matches=%s deleted_queue_rows=%s expired_invites=%s" % [
			str(data.get("ok", false)), str(data.get("expired_matches", "?")),
			str(data.get("deleted_queue_rows", "?")), str(data.get("expired_invites", "?"))])
	return res

## True when a cleanup-RPC result means "the function is not deployed
## yet" (404, or GoTrue/PostgREST's "function does not exist" /
## PGRST202). Pure — unit-tested. Any other failure is a real error
## (logged, not fatal — the cleanup is best-effort).
static func is_cleanup_rpc_missing(res: Dictionary) -> bool:
	if int(res.get("status", 0)) == 404:
		return true
	var msg := String(res.get("error", "")).to_lower()
	return msg.contains("does not exist") or msg.contains("pgrst202") or msg.contains("could not find the function")

## Seconds since an ISO timestamp (Supabase "2026-11-22T13:00:00+00:00").
## -1 when it cannot be parsed. Pure — used for presence staleness
## (90 s) and invite expiry (24 h) alike.
static func iso_age_seconds(iso: String) -> int:
	if iso == "":
		return -1
	var core := iso.split("+", false, 1)[0]
	core = core.split("Z", false, 1)[0]
	core = core.replace("T", " ")
	var stamp := Time.get_unix_time_from_datetime_string(core)
	if stamp <= 0:
		return -1
	return int(Time.get_unix_time_from_system()) - int(stamp)

# --------------------------------------------------------------- Realtime

## Subscribe to invite changes for one player (incoming invites where
## to_id = my_id, plus rows I sent where from_id = my_id, so the inviter
## sees accepts). Reconnects are the caller's job (Friends polls too).
func connect_realtime(my_id: String) -> void:
	if not configured or my_id == "":
		return
	disconnect_realtime()
	_ws_my_id = my_id
	var host := base_url.trim_prefix("https://").trim_prefix("http://")
	# wss for https projects (real Supabase), plain ws for http (the
	# local mock in tests) — wss against a plain server fails the TLS
	# handshake.
	var scheme := "wss" if base_url.begins_with("https://") else "ws"
	var ws_url := "%s://%s/realtime/v1/websocket?apikey=%s&vsn=%s" % [scheme, host, anon_key, REALTIME_VSN]
	_ws = WebSocketPeer.new()
	_ws_want = true
	_ws_heartbeat = 0.0
	_ws_joined = false
	var err := _ws.connect_to_url(ws_url)
	if err != OK:
		_ws = null
		_ws_want = false
		realtime_failed.emit("Could not open the Realtime connection (%s)." % error_string(err))
		return
	# The channel join is sent from _process once the socket is open
	# (see the STATE_OPEN branch above).
	_ws_ref = 0

func disconnect_realtime() -> void:
	_ws_want = false
	if _ws != null:
		_ws.close()
		_ws = null

## Scale hardening (2026-11-28): true when the Realtime socket is
## currently open. Friends uses this to decide whether a reconnect
## attempt is needed — an open socket whose join reply is still in
## flight must NOT be torn down and re-opened every 60 s.
func realtime_is_open() -> bool:
	return _ws != null and _ws.get_ready_state() == WebSocketPeer.STATE_OPEN

func _join_realtime_channel() -> void:
	if _ws == null:
		return
	# The live join MUST be the same shape the tests check: build it
	# from the one static helper, never a second hand-written copy
	# (a drifted copy is how a wrong-table / wrong-column filter
	# ships — every from_id filter in this file is on the invites
	# table, which is the only table that HAS from_id; matches,
	# presence and matchmaking_queue do not).
	_ws_ref += 1
	_ws.send_text(JSON.stringify(realtime_join_payload(_ws_my_id, str(_ws_ref))))

## v11 P2P (§1.4): join the match Broadcast channel on the SAME socket
## as the invites channel. Safe to call before the socket is open —
## the channel name is stored and the join is sent from _process once
## the socket opens. One socket total, never a second WebSocketPeer.
func join_match_channel(match_id: String) -> void:
	if match_id == "":
		return
	_ws_match_channel = P2PSignalling.channel_name(match_id)
	_ws_match_joined = false
	if _ws != null and _ws.get_ready_state() == WebSocketPeer.STATE_OPEN and _ws_joined:
		_ws_match_joined = true
		_join_match_channel()

func leave_match_channel() -> void:
	if _ws_match_channel == "" or _ws == null:
		_ws_match_channel = ""
		_ws_match_joined = false
		return
	_ws_ref += 1
	_ws.send_text(JSON.stringify({
		"topic": "realtime:%s" % _ws_match_channel,
		"event": "phx_leave",
		"payload": {},
		"ref": str(_ws_ref),
	}))
	_ws_match_channel = ""
	_ws_match_joined = false

func _join_match_channel() -> void:
	if _ws == null or _ws_match_channel == "":
		return
	_ws_ref += 1
	_ws.send_text(JSON.stringify({
		"topic": "realtime:%s" % _ws_match_channel,
		"event": "phx_join",
		"payload": {"config": {"broadcast": {"self": false}}},
		"ref": str(_ws_ref),
	}))

## v11 P2P: send one signalling message on the match Broadcast channel.
## No-op when no channel is joined (the caller joins first). Returns
## false when there is no open socket — the caller treats that as a
## failed connection, never a silent drop.
func send_broadcast(msg: Dictionary) -> bool:
	if _ws == null or _ws_match_channel == "":
		return false
	if _ws.get_ready_state() != WebSocketPeer.STATE_OPEN:
		return false
	_ws_ref += 1
	_ws.send_text(JSON.stringify({
		"topic": "realtime:%s" % _ws_match_channel,
		"event": "broadcast",
		"payload": {"event": "signal", "payload": msg},
		"ref": str(_ws_ref),
	}))
	return true

func _handle_realtime_text(text: String) -> void:
	var parsed := parse_realtime_message(text)
	if parsed.is_empty():
		return
	match String(parsed.get("kind", "")):
		"joined":
			realtime_connected.emit()
		"realtime_error":
			# The invites channel join was REJECTED (e.g. a filter the
			# server cannot apply — the P0001 "invalid column for
			# filter" class of error). This used to be swallowed as a
			# heartbeat, so live invites silently never arrived and
			# only the poll backstop could find them. Surface it.
			var reason := String((parsed.get("record", {}) as Dictionary).get("message", ""))
			print("[MATCH] Realtime invites join rejected: %s" % reason)
			realtime_failed.emit("Realtime invites channel rejected: %s" % reason)
		"invite":
			realtime_invite_changed.emit(parsed.get("record", {}))
		"broadcast":
			# v11 P2P: a signalling message on the match channel.
			# Validated here (own echoes + malformed messages dropped)
			# so Net only ever sees well-formed peer messages.
			var msg := P2PSignalling.parse_message(parsed.get("record", {}), user_id)
			if not msg.is_empty():
				broadcast_received.emit(msg)
		"heartbeat":
			pass

## Pure parser for Realtime (phoenix) messages — unit-tested with canned
## payloads. Returns {} for anything that is not a recognised message.
## Kinds: "joined" (our channel join was accepted), "realtime_error"
## (our invites channel join was REJECTED — the payload's reason is in
## "record"."message"; a rejected join used to be swallowed as a
## heartbeat, so live invites silently never arrived), "invite" (a
## postgres_changes INSERT/UPDATE on invites, with the row in "record"),
## "broadcast" (a Broadcast "signal" on a carrom-match-* channel, with
## the message in "record"), "heartbeat" (a phx_reply to our heartbeat).
static func parse_realtime_message(text: String) -> Dictionary:
	var data: Variant = JSON.parse_string(text)
	if not (data is Dictionary):
		return {}
	var event := String(data.get("event", ""))
	var topic := String(data.get("topic", ""))
	if event == "phx_reply":
		var payload: Dictionary = data.get("payload", {})
		var pstatus := String(payload.get("status", ""))
		if pstatus == "ok" and topic == "realtime:public:invites":
			return {"kind": "joined"}
		if pstatus == "error" and topic == "realtime:public:invites":
			var resp: Dictionary = payload.get("response", {})
			var reason := String(resp.get("reason", resp.get("message", "")))
			if reason == "":
				reason = JSON.stringify(payload)
			return {"kind": "realtime_error", "record": {"message": reason}}
		return {"kind": "heartbeat"}
	if event == "postgres_changes" and topic == "realtime:public:invites":
		var payload2: Dictionary = data.get("payload", {})
		var record: Dictionary = payload2.get("data", {}).get("record", {})
		if record.is_empty():
			return {}
		return {"kind": "invite", "record": record}
	if event == "broadcast" and topic.begins_with("realtime:carrom-match-"):
		# Supabase Broadcast: payload = {"event": "signal",
		# "payload": {the signalling message}}.
		var payload3: Dictionary = data.get("payload", {})
		if String(payload3.get("event", "")) != "signal":
			return {}
		var msg: Dictionary = payload3.get("payload", {})
		if msg.is_empty():
			return {}
		return {"kind": "broadcast", "record": msg}
	return {}

# ------------------------------------------------------------ pure helpers

## PKCE S256 challenge for a verifier (RFC 7636). Test vector:
## verifier "dBjftJeZ4CVP-mB92K27uhbUJU1p1r_wW1gFWFOEjXk" ->
## challenge "E9Melhoa2OwvFrEMTJguCHaoeK1t8URWbuGJSstw-cM".
static func pkce_challenge(verifier: String) -> String:
	var h := HashingContext.new()
	h.start(HashingContext.HASH_SHA256)
	h.update(verifier.to_utf8_buffer())
	return base64url_encode(h.finish())

static func base64url_encode(bytes: PackedByteArray) -> String:
	return Marshalls.raw_to_base64(bytes).replace("+", "-").replace("/", "_").rstrip("=")

static func random_verifier() -> String:
	const ALPHABET := "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-._~"
	var out := ""
	for i in range(64):
		out += ALPHABET[randi() % ALPHABET.length()]
	return out

## A profile row for PostgREST, from the local Save values.
static func profile_row(profile_id: String, gmail: String, display_name: String, coins: int, xp: int,
		matches_played: int, matches_won: int, online_wins: int, queens_covered: int,
		owned_boards: Array, owned_strikers: Array, equipped_board: String, equipped_striker: String) -> Dictionary:
	return {
		"id": profile_id, "gmail": gmail, "display_name": display_name,
		"coins": coins, "xp": xp, "matches_played": matches_played,
		"matches_won": matches_won, "online_wins": online_wins,
		"queens_covered": queens_covered,
		"owned_boards": owned_boards, "owned_strikers": owned_strikers,
		"equipped_board": equipped_board, "equipped_striker": equipped_striker,
	}

## An invite row for PostgREST.
static func invite_row(group_id: String, from_id: String, to_id: String, from_name: String, to_name: String, mode: String, stake: int) -> Dictionary:
	return {
		"group_id": group_id, "from_id": from_id, "to_id": to_id,
		"from_name": from_name, "to_name": to_name,
		"mode": mode, "stake": maxi(0, stake), "status": "pending",
	}

## Join payload for the Realtime channel (used by tests to check the
## subscription shape without opening a socket).
static func realtime_join_payload(my_id: String, ref: String) -> Dictionary:
	return {
		"topic": "realtime:public:invites",
		"event": "phx_join",
		"payload": {"config": {"postgres_changes": [
			{"event": "*", "schema": "public", "table": "invites", "filter": "to_id=eq.%s" % my_id},
			{"event": "*", "schema": "public", "table": "invites", "filter": "from_id=eq.%s" % my_id},
		]}},
		"ref": ref,
	}
