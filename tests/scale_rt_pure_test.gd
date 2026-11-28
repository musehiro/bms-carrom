extends SceneTree

## Scale-hardening Realtime-first tests — PURE (headless, standalone -s
## script, no network, no mock server).
## Run: godot --headless --path . -s tests/scale_rt_pure_test.gd
## Covers the worker-4 client refactor (2026-11-28):
##   (a) Realtime-first incoming invites: the poll interval is 30 s
##       while Realtime is healthy, 2 s while it is down.
##   (b) Bounded presence list: the query carries a 90 s freshness
##       cutoff, limit=50, and the viewer's level band (±4).
##   (c) Mid-session token refresh: JWT "exp" parsing, refresh-due
##       decision, the 401-retry rule, and dead-refresh-token detection.
##   (d) Opportunistic cleanup RPC: throttle rule + "function does not
##       exist" detection.
## The live behaviour (invite arriving over the socket, the refresh
## actually rotating tokens, the cleanup call reaching the server) is
## proved against the mock in tests/scale_rt_mock_test_node.gd.

var _passed := 0
var _failed := 0
var _failures: Array = []

func _initialize() -> void:
	print("=== BMS Carrom scale Realtime-first tests (pure) ===")
	_test_poll_interval()
	_test_presence_path()
	_test_jwt_exp()
	_test_session_needs_refresh()
	_test_401_retry_rule()
	_test_invalid_refresh_token()
	_test_cleanup_due()
	_test_cleanup_rpc_missing()
	print("=== %d passed, %d failed ===" % [_passed, _failed])
	for f in _failures:
		print("FAIL: ", f)
	quit(0 if _failed == 0 else 1)

func _check(name: String, cond: bool, detail: String = "") -> void:
	if cond:
		_passed += 1
		print("PASS: ", name)
	else:
		_failed += 1
		_failures.append(name + (" — " + detail if detail != "" else ""))
		print("FAIL: ", name, (" — " + detail if detail != "" else ""))

func _friends_script() -> GDScript:
	return load("res://scripts/friends.gd")

func _net_script() -> GDScript:
	return load("res://scripts/net_client.gd")

## A minimal unsigned JWT for testing: header.payload.testsig, with the
## payload carrying the given claims. The client only ever DECODES the
## payload (never verifies a signature), like jwt_sub / jwt_exp do.
func _make_jwt(claims: Dictionary) -> String:
	var header := SupabaseClient.base64url_encode(JSON.stringify({"alg": "HS256", "typ": "JWT"}).to_utf8_buffer())
	var payload := SupabaseClient.base64url_encode(JSON.stringify(claims).to_utf8_buffer())
	return header + "." + payload + ".testsig"

# ------------------------------------------------- (a) poll interval
func _test_poll_interval() -> void:
	var FriendsScript := _friends_script()
	_check("poll: healthy Realtime -> 30 s backstop",
		is_equal_approx(float(FriendsScript.incoming_poll_interval_seconds(true)), 30.0))
	_check("poll: Realtime down -> 2 s fallback",
		is_equal_approx(float(FriendsScript.incoming_poll_interval_seconds(false)), 2.0))
	_check("poll: backstop is slower than the fallback (load drops when live)",
		float(FriendsScript.incoming_poll_interval_seconds(true)) > float(FriendsScript.incoming_poll_interval_seconds(false)))

# ---------------------------------------------- (b) presence list path
func _test_presence_path() -> void:
	var now := 1794000000 # fixed "now" so the cutoff is deterministic
	var path := SupabaseClient.presence_list_path(0, now)
	_check("presence: path filters to fresh rows only", path.contains("updated_at=gt."))
	_check("presence: path caps at 50 rows", path.contains("limit=50"))
	_check("presence: path selects only the lobby columns",
		path.contains("select=id,display_name,level,status,updated_at") and not path.contains("select=*"))
	_check("presence: path orders newest first", path.contains("order=updated_at.desc"))
	# The cutoff decodes to exactly now - 90 s.
	var cutoff := path.split("updated_at=gt.", false, 1)[1].split("&", false, 1)[0].uri_decode()
	var cutoff_unix := Time.get_unix_time_from_datetime_string(cutoff.replace("T", " ").split("+", false, 1)[0])
	_check("presence: freshness cutoff is now - 90 s", cutoff_unix == now - 90, str(cutoff_unix))
	# Level band: viewer level 10 -> levels 6..14.
	var banded := SupabaseClient.presence_list_path(10, now)
	_check("presence: level band gte viewer-4", banded.contains("level=gte.6"))
	_check("presence: level band lte viewer+4", banded.contains("level=lte.14"))
	# No level -> no level filter at all (a logged-out / unknown level
	# must not filter the lobby down to nothing).
	_check("presence: no level -> no level filter", not path.contains("level="))
	# Low level clamps the lower bound at 1 (no "level=gte.0" / negative).
	var low := SupabaseClient.presence_list_path(2, now)
	_check("presence: low level clamps gte at 1", low.contains("level=gte.1") and low.contains("level=lte.6"))

# ------------------------------------------------ (c) token expiry
func _test_jwt_exp() -> void:
	var exp := 1794003600
	_check("jwt_exp: reads exp from a JWT payload",
		SupabaseClient.jwt_exp(_make_jwt({"sub": "u1", "exp": exp})) == exp)
	_check("jwt_exp: no exp claim -> 0 (unknown, never 'expired')",
		SupabaseClient.jwt_exp(_make_jwt({"sub": "u1"})) == 0)
	_check("jwt_exp: mock-style token is not a JWT -> 0",
		SupabaseClient.jwt_exp("tok-some-uid") == 0)
	_check("jwt_exp: garbage -> 0", SupabaseClient.jwt_exp("not-a-token") == 0)
	_check("jwt_exp: empty -> 0", SupabaseClient.jwt_exp("") == 0)

func _test_session_needs_refresh() -> void:
	var sb := SupabaseClient.new()
	var now := int(Time.get_unix_time_from_system())
	# No session at all -> no refresh.
	_check("refresh-due: no session -> false", not sb.session_needs_refresh())
	# Token expiring in an hour -> not due.
	sb._set_session({"access_token": _make_jwt({"sub": "u1", "exp": now + 3600}),
		"refresh_token": "ref-u1", "user": {"id": "u1"}})
	_check("refresh-due: expiry read from the token", sb.session_expires_at == now + 3600)
	_check("refresh-due: 1 h away -> false", not sb.session_needs_refresh())
	# Token expiring in 4 min (inside the 5 min lead) -> due.
	sb._set_session({"access_token": _make_jwt({"sub": "u1", "exp": now + 240}),
		"refresh_token": "ref-u1", "user": {"id": "u1"}})
	_check("refresh-due: 4 min away -> true", sb.session_needs_refresh())
	# Token expiring in 6 min (outside the lead) -> not due yet.
	sb._set_session({"access_token": _make_jwt({"sub": "u1", "exp": now + 360}),
		"refresh_token": "ref-u1", "user": {"id": "u1"}})
	_check("refresh-due: 6 min away -> false", not sb.session_needs_refresh())
	# Already expired -> due.
	sb._set_session({"access_token": _make_jwt({"sub": "u1", "exp": now - 10}),
		"refresh_token": "ref-u1", "user": {"id": "u1"}})
	_check("refresh-due: already expired -> true", sb.session_needs_refresh())
	# Non-JWT token (expiry unknown) -> never proactively due; the
	# 401-retry path is the backstop for those.
	sb._set_session({"access_token": "tok-u1", "refresh_token": "ref-u1", "user": {"id": "u1"}})
	_check("refresh-due: unknown expiry -> false (no refresh loop)", not sb.session_needs_refresh())
	sb.queue_free()

func _test_401_retry_rule() -> void:
	_check("401-rule: 401 on an authed REST call -> retry",
		SupabaseClient.should_retry_after_401(401, true, "/rest/v1/invites", true))
	_check("401-rule: 401 on the token endpoint itself -> no retry (would loop)",
		not SupabaseClient.should_retry_after_401(401, true, "/auth/v1/token?grant_type=refresh_token", true))
	_check("401-rule: 401 on an unauthenticated call -> no retry (nothing to refresh)",
		not SupabaseClient.should_retry_after_401(401, false, "/rest/v1/invites", true))
	_check("401-rule: 404 -> no retry", not SupabaseClient.should_retry_after_401(404, true, "/rest/v1/invites", true))
	_check("401-rule: retry already used -> no second retry",
		not SupabaseClient.should_retry_after_401(401, true, "/rest/v1/invites", false))

func _test_invalid_refresh_token() -> void:
	_check("dead-token: 400 'Invalid refresh token.' -> true",
		SupabaseClient.looks_like_invalid_refresh_token({"status": 400, "error": "Invalid refresh token."}))
	_check("dead-token: 400 invalid_grant -> true",
		SupabaseClient.looks_like_invalid_refresh_token({"status": 400, "error": "invalid_grant: refresh token not found"}))
	_check("dead-token: 400 network error -> false (transient, retry later)",
		not SupabaseClient.looks_like_invalid_refresh_token({"status": 400, "error": "Connection failed (timed out)."}))
	_check("dead-token: 500 with the same words -> false (status must be 400)",
		not SupabaseClient.looks_like_invalid_refresh_token({"status": 500, "error": "Invalid refresh token."}))
	_check("dead-token: transport failure (status 0) -> false",
		not SupabaseClient.looks_like_invalid_refresh_token({"status": 0, "error": "Connection failed."}))

# ------------------------------------------- (d) cleanup RPC throttle
func _test_cleanup_due() -> void:
	var now := 1794000000
	_check("cleanup-due: never called -> due", NetClient.cleanup_due(0, now))
	_check("cleanup-due: called just now -> not due", not NetClient.cleanup_due(now, now))
	_check("cleanup-due: called 299 s ago -> not due", not NetClient.cleanup_due(now - 299, now))
	_check("cleanup-due: called 300 s ago -> due", NetClient.cleanup_due(now - 300, now))
	_check("cleanup-due: called 1000 s ago -> due", NetClient.cleanup_due(now - 1000, now))

func _test_cleanup_rpc_missing() -> void:
	_check("cleanup-missing: 404 -> true (not deployed yet)",
		SupabaseClient.is_cleanup_rpc_missing({"ok": false, "status": 404, "error": "Not Found"}))
	_check("cleanup-missing: 'could not find the function' -> true",
		SupabaseClient.is_cleanup_rpc_missing({"ok": false, "status": 400, "error": "Could not find the function public.cleanup_stale_matchmaking in the schema cache"}))
	_check("cleanup-missing: PGRST202 -> true",
		SupabaseClient.is_cleanup_rpc_missing({"ok": false, "status": 400, "error": "PGRST202: could not find the function"}))
	_check("cleanup-missing: success -> false",
		not SupabaseClient.is_cleanup_rpc_missing({"ok": true, "status": 200, "data": {"ok": true}}))
	_check("cleanup-missing: 500 -> false (a real error, not 'not deployed')",
		not SupabaseClient.is_cleanup_rpc_missing({"ok": false, "status": 500, "error": "database error"}))
	_check("cleanup-missing: transport failure -> false",
		not SupabaseClient.is_cleanup_rpc_missing({"ok": false, "status": 0, "error": "Connection failed (timed out)."}))
