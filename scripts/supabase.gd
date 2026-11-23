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
##   GET  /auth/v1/authorize?provider=google...     -> Google sign-in page
##
## Realtime (phoenix channels over WebSocket):
##   wss://<host>/realtime/v1/websocket?apikey=<key>&vsn=1.0.0
##   join realtime:public:invites with a postgres_changes filter;
##   INSERT/UPDATE rows arrive as postgres_changes events.

signal realtime_invite_changed(invite: Dictionary)
signal realtime_connected
signal realtime_failed(message: String)

const CONFIG_PATH := "res://backend_config.json"
const REALTIME_VSN := "1.0.0"
const LOOPBACK_PORT := 8765
const LOOPBACK_PATH := "/callback"

## The URL Android's browser goes back to after the Google sign-in, so
## the browser can open the game again. Registered in Supabase's Redirect
## URLs allow-list AND as an intent filter in android/build/AndroidManifest.xml;
## GodotApp.java writes the incoming URI to AUTH_CALLBACK_FILE for the
## game to pick up (vanilla Godot 4.3 does not surface deep links to GDScript).
const CUSTOM_SCHEME_REDIRECT := "com.musehiro.carrom://auth-callback"
## File the native side writes the deep-link URI into (getFilesDir() is
## the same directory Godot maps user:// to on Android).
const AUTH_CALLBACK_FILE := "user://auth_callback.txt"

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
var access_token := "" # Supabase Auth session ("" = not signed in)
var user_id := "" # Supabase Auth user id ("" = none)

var _ws: WebSocketPeer = null
var _ws_want := false
var _ws_ref := 0
var _ws_my_id := ""
var _ws_heartbeat := 0.0
var _ws_joined := false

func _ready() -> void:
	load_config()

func load_config() -> void:
	if not FileAccess.file_exists(CONFIG_PATH):
		configured = false
		return
	var text := FileAccess.get_file_as_string(CONFIG_PATH)
	var data: Dictionary = JSON.parse_string(text)
	if data.is_empty():
		configured = false
		return
	base_url = String(data.get("supabase_url", "")).strip_edges().trim_suffix("/")
	anon_key = String(data.get("supabase_anon_key", "")).strip_edges()
	google_client_id = String(data.get("google_client_id", "")).strip_edges()
	configured = base_url != "" and anon_key != ""

## Test override: point the client at a mock server (tests) instead of
## the configured project. Pass "" to clear the override.
func set_config(url: String, key: String, client_id: String = "") -> void:
	base_url = url.strip_edges().trim_suffix("/")
	anon_key = key.strip_edges()
	google_client_id = client_id.strip_edges()
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

## One HTTP call. Returns {ok, status, data, error}. `path` is appended
## to base_url (already starts with "/"). Never throws.
func _http(method: int, path: String, body: Dictionary = {}, auth: bool = true, extra_headers: PackedStringArray = PackedStringArray()) -> Dictionary:
	if not configured:
		return {"ok": false, "status": 0, "data": null, "error": "Supabase is not configured yet (backend_config.json is empty)."}
	var req := HTTPRequest.new()
	req.timeout = 15.0
	add_child(req)
	var headers := _headers(auth)
	for extra in extra_headers:
		headers.append(extra)
	var payload := JSON.stringify(body) if not body.is_empty() else ""
	var err := req.request(base_url + path, headers, method, payload)
	if err != OK:
		req.queue_free()
		return {"ok": false, "status": 0, "data": null, "error": "Could not start the request (%s)." % error_string(err)}
	var res: Array = await req.request_completed
	req.queue_free()
	var status := int(res[1])
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
func send_otp(email: String) -> Dictionary:
	return await _http(HTTPClient.METHOD_POST, "/auth/v1/otp",
		{"email": email, "create_user": true}, false)

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

## Google sign-in, PKCE loopback flavour: the game listens on
## http://127.0.0.1:8765/callback for Supabase's redirect, so no native
## plugin and no deep-link intent filter are needed. Returns the
## authorize URL + the verifier the caller must keep for the exchange.
## The caller opens the URL in the browser (OS.shell_open) and feeds the
## ?code=... from the loopback callback into exchange_pkce_code().
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

func _join_realtime_channel() -> void:
	if _ws == null:
		return
	_ws_ref += 1
	var join := {
		"topic": "realtime:public:invites",
		"event": "phx_join",
		"payload": {"config": {"postgres_changes": [
			{"event": "*", "schema": "public", "table": "invites", "filter": "to_id=eq.%s" % _ws_my_id},
			{"event": "*", "schema": "public", "table": "invites", "filter": "from_id=eq.%s" % _ws_my_id},
		]}},
		"ref": str(_ws_ref),
	}
	_ws.send_text(JSON.stringify(join))

func _handle_realtime_text(text: String) -> void:
	var parsed := parse_realtime_message(text)
	if parsed.is_empty():
		return
	match String(parsed.get("kind", "")):
		"joined":
			realtime_connected.emit()
		"invite":
			realtime_invite_changed.emit(parsed.get("record", {}))
		"heartbeat":
			pass

## Pure parser for Realtime (phoenix) messages — unit-tested with canned
## payloads. Returns {} for anything that is not a recognised message.
## Kinds: "joined" (our channel join was accepted), "invite" (a
## postgres_changes INSERT/UPDATE on invites, with the row in "record"),
## "heartbeat" (a phx_reply to our heartbeat).
static func parse_realtime_message(text: String) -> Dictionary:
	var data: Variant = JSON.parse_string(text)
	if not (data is Dictionary):
		return {}
	var event := String(data.get("event", ""))
	var topic := String(data.get("topic", ""))
	if event == "phx_reply":
		var payload: Dictionary = data.get("payload", {})
		if String(payload.get("status", "")) == "ok" and topic == "realtime:public:invites":
			return {"kind": "joined"}
		return {"kind": "heartbeat"}
	if event == "postgres_changes" and topic == "realtime:public:invites":
		var payload2: Dictionary = data.get("payload", {})
		var record: Dictionary = payload2.get("data", {}).get("record", {})
		if record.is_empty():
			return {}
		return {"kind": "invite", "record": record}
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
