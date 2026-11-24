extends Node

## BMS Carrom server — matchmaking + relay (NOT a physics authority).
## The server matches players of similar level on the same table, then
## only relays their shot/state messages. Both clients simulate the same
## physics from the same inputs, with a full state snapshot after each shot
## to resync. This keeps the server tiny and cheap to host.
##
## F13 Phase 2 (v11) — verified stakes + server-authoritative settlement:
## when the host sets SUPABASE_URL + SUPABASE_SERVICE_ROLE_KEY in the
## environment, the server verifies every queue / invite_join that carries
## an account_id + access token: it checks the token with Supabase Auth
## (GET /auth/v1/user), confirms the token's user id matches the claimed
## account_id, reads the real level (xp/500+1) and coin balance from the
## profiles row, uses the VERIFIED level for matchmaking, rejects a stake
## above the verified balance, and puts the VERIFIED stakes into the
## matched payloads (your_stake + verified_stakes=true). At match end
## each client reports its outcome ("result") and the server settles
## only when both reports agree (win+loss, or draw+draw) — the server,
## not each client, decides the payout, and sends each side a
## `settlement` {payout, pot}. Conflicting reports refund each player's
## own stake (nobody profits from a disputed match). A forfeit or
## disconnect dissolves the room with NO server settlement — the
## remaining player's local forfeit win stands, as before.
## Without those env vars the server runs exactly as before (Phase 1
## clamps only) — local/bot/LAN play is unaffected, and old clients
## that send no token simply play unverified. The service key lives
## ONLY on this host (see deploy-oracle.sh) — never in the repo, never
## in the client, never in a log line.
##
## HONEST LIMIT: the settlement above is the payout DECISION. The coin
## credit still happens client-side (Save + cloud upsert). A server-side
## coin ledger (PATCHing both profiles with the service key after
## settlement) is the remaining step before internet play goes live —
## it needs a live Supabase project to test against, and must be
## reconciled with the client's cloud upsert so nobody is paid twice.
## It is NOT in this patch; see the v11 stakes summary.
##
## Two modes (v6): "2p" singles and "4p" doubles (two teams of two —
## seats 0,2 vs 1,3, partners opposite). Each mode has its own queue.
##
## Scale (v6, for 100K–200K players): one process is a matchmaking queue
## + independent game rooms. Matching runs ONLY when the queue changes
## (a player queues or leaves) plus once a second for the 30 s widening
## — never every frame — so a big queue stays cheap. See
## docs/online-server.md for honest capacity numbers.
##
## Node path MUST be /root/Net (autoload "Net") — the same as the client's
## autoload — because Godot RPCs are addressed by node path.
##
## Run:  godot --headless --path server -- --port 8910
## (or just: godot --headless --path server)

const DEFAULT_PORT := 8910
const MAX_PEERS := 1024 # ENet cap per process; see docs for real capacity
const WIDEN_AFTER_SEC := 30.0
const MATCH_SCAN_INTERVAL := 1.0 # seconds between widening re-scans
# Invite rooms (v7): friends join by group_id after accepting an invite.
# The match starts when every expected player has joined; the room is
# cleaned up after 3 minutes so a slow invitee does not hold it forever.
const INVITE_ROOM_TIMEOUT := 180.0
# F13 Phase 1 — the server used to trust whatever the client claimed
# (any level, any stake, any name). Claimed fields are now sanitised
# before they are stored or matched on; nothing here verifies them
# against Supabase (that is Phase 2 — see the report). Caps are
# deliberately generous so no legitimate player is ever blocked:
# levels are 1..100, stakes 0..1,000,000, names 32 chars, tables 0..2.
const MAX_CLAIMED_NAME_LEN := 32
const MAX_CLAIMED_LEVEL := 100
const MAX_CLAIMED_STAKE := 1000000
const MAX_TABLE := 2
# Relay rate limit: a client can legitimately send ~1 shot + 1 state
# per turn (a few per second at most). Over 10 shot/state messages in
# one second is flooding — drop the excess, and disconnect a peer that
# sustains it (5 over-limit windows).
const RELAY_MAX_PER_SEC := 10
const RELAY_MAX_VIOLATIONS := 5

var _peer: ENetMultiplayerPeer = null
var _queue: Array = [] # {id, name, level, table, stake, mode, at}
var _rooms := {} # room_id -> {mode, players: [peer ids]}
var _peer_room := {} # peer_id -> room_id
var _names := {} # peer_id -> display name
var _invite_rooms := {} # group_id -> {mode, expected, table, players: [...], at}
var _peer_invite := {} # peer_id -> group_id (waiting in an invite room)
var _relay_limits := {} # F13: peer_id -> {window_start, count, violations}
var _room_seq := 0
var _scan_timer := 0.0
# F13 Phase 2 — Supabase verification (env-configured, off by default).
# _verify_key is the SERVICE-ROLE key: it lives only in this process's
# environment (Oracle host), is never logged, never sent anywhere
# except to Supabase, and never appears in the repo or the client.
var _verify_enabled := false
var _verify_url := ""
var _verify_key := ""
var _pending_verify := {} # peer_id -> {kind, data, claim, stage, user_id, http}

func _ready() -> void:
	var port := DEFAULT_PORT
	for a in OS.get_cmdline_user_args():
		if a.begins_with("--port="):
			port = int(a.trim_prefix("--port="))
	_peer = ENetMultiplayerPeer.new()
	var err := _peer.create_server(port, MAX_PEERS)
	if err != OK:
		printerr("[Server] Failed to start on port %d: %s" % [port, error_string(err)])
		get_tree().quit(1)
		return
	multiplayer.multiplayer_peer = _peer
	multiplayer.peer_connected.connect(_on_peer_connected)
	multiplayer.peer_disconnected.connect(_on_peer_disconnected)
	print("[Server] BMS Carrom matchmaking server listening on port %d (max %d peers)" % [port, MAX_PEERS])
	# F13 Phase 2: verification is OFF unless the host sets BOTH env
	# vars. No key is ever printed — only whether verification is on.
	var supa_url := OS.get_environment("SUPABASE_URL").strip_edges().trim_suffix("/")
	var supa_key := OS.get_environment("SUPABASE_SERVICE_ROLE_KEY").strip_edges()
	if supa_url != "" and supa_key != "":
		_verify_enabled = true
		_verify_url = supa_url
		_verify_key = supa_key
		print("[Server] F13 Phase 2 verification ENABLED (Supabase account + stakes verified)")
	else:
		print("[Server] F13 Phase 2 verification DISABLED — set SUPABASE_URL + SUPABASE_SERVICE_ROLE_KEY in the environment to enable it (Phase 1 clamps still apply)")
	print("[Server] Waiting for players… (Ctrl+C to stop)")

func _process(delta: float) -> void:
	# Widening re-scan only: matching itself is event-driven (on queue /
	# disconnect), so a big queue costs nothing between events.
	_scan_timer += delta
	if _scan_timer >= MATCH_SCAN_INTERVAL:
		_scan_timer = 0.0
		_try_match()
		_expire_invite_rooms()

func _on_peer_connected(id: int) -> void:
	print("[Server] Peer connected: %d" % id)

func _on_peer_disconnected(id: int) -> void:
	print("[Server] Peer disconnected: %d" % id)
	_cleanup_verification(id)
	_remove_from_queue(id)
	_leave_invite_room(id)
	_relay_limits.erase(id)
	var room_id: int = int(_peer_room.get(id, -1))
	if room_id >= 0:
		_dissolve_room(room_id, id)
	_names.erase(id)

func _remove_from_queue(id: int) -> void:
	for i in range(_queue.size() - 1, -1, -1):
		if int(_queue[i]["id"]) == id:
			_queue.remove_at(i)

## Dissolve a room because a player left: the rest get opponent_left
## (with the leaver's seat for 4p rooms, so clients can work out which
## team forfeited). The room is gone — no rejoin.
func _dissolve_room(room_id: int, leaver_id: int) -> void:
	var room: Dictionary = _rooms.get(room_id, {})
	if room.is_empty():
		return
	var players: Array = room.get("players", [])
	var leaver_seat := players.find(leaver_id)
	for pid in players:
		_peer_room.erase(int(pid))
		if int(pid) != leaver_id:
			var msg := {"type": "opponent_left"}
			if String(room.get("mode", "2p")) == "4p":
				msg["seat"] = leaver_seat
			_send_to(int(pid), msg)
	_rooms.erase(room_id)
	print("[Server] Room %d dissolved (player %d left)" % [room_id, leaver_id])

@rpc("any_peer", "reliable")
func _relay(payload: String) -> void:
	var sender := multiplayer.get_remote_sender_id()
	var data: Dictionary = JSON.parse_string(payload)
	if data.is_empty():
		return
	match String(data.get("type", "")):
		"queue":
			# F13 Phase 1: sanitise the claim before it is stored or
			# matched on. A non-numeric level/stake or a negative
			# stake is not queued at all.
			var claim := sanitize_claim(data)
			if not bool(claim.get("ok", false)):
				_send_to(sender, {"type": "error", "message": String(claim.get("error", "Bad matchmaking request."))})
				print("[Server] Rejected queue from peer %d: %s" % [sender, claim.get("error", "")])
				return
			# F13 Phase 2: when verification is enabled, the claim is
			# only a starting point — the player queues with VERIFIED
			# level/stake (or not at all). Disabled: Phase 1 path.
			if _verify_enabled:
				_begin_verification(sender, "queue", data, claim)
				return
			_enqueue_player(sender, claim, {})
		"invite_join":
			# F13 Phase 2: same verification gate as "queue" (the
			# invite room itself re-sanitises on join, so this check
			# only decides whether to verify first).
			if _verify_enabled:
				var iclaim := sanitize_claim(data)
				if not bool(iclaim.get("ok", false)):
					_send_to(sender, {"type": "invite_failed", "error": String(iclaim.get("error", "Bad invite request."))})
					return
				_begin_verification(sender, "invite_join", data, iclaim)
				return
			_join_invite_room(sender, data)
		"result":
			# F13 Phase 2: one side's match outcome — the server
			# settles only when both sides have reported (see
			# _record_result). Ignored outside a live room.
			_record_result(sender, data)
		"leave_queue":
			# v11: a search cancelled without disconnecting — drop the
			# entry so the player is never matched after cancelling.
			_remove_from_queue(sender)
		"lobby_leave":
			# v11: a player left the lobby before the match started —
			# dissolve the room; the rest get opponent_left.
			var lobby_room: int = int(_peer_room.get(sender, -1))
			if lobby_room >= 0:
				_dissolve_room(lobby_room, sender)
		"shot", "state", "lobby_ready":
			_relay_to_room(sender, data)
		"forfeit":
			var room_id2: int = int(_peer_room.get(sender, -1))
			if room_id2 >= 0:
				_dissolve_room(room_id2, sender)

## Put a sanitised claim on the matchmaking queue. `verified` is the
## Phase 2 verification result {level, stake, balance} ({} when
## unverified): a verified player's VERIFIED level drives the ±2/±4
## matchmaking window and the VERIFIED stake is what the matched
## payloads carry. Unverified entries play exactly as before.
func _enqueue_player(sender: int, claim: Dictionary, verified: Dictionary) -> void:
	_names[sender] = String(claim["name"])
	_remove_from_queue(sender)
	var mode := String(claim["mode"])
	var entry := {"id": sender, "name": String(claim["name"]),
		"level": int(claim["level"]), "table": int(claim["table"]),
		"stake": int(claim["stake"]), "mode": mode,
		"at": Time.get_unix_time_from_system()}
	if not verified.is_empty():
		entry["verified"] = verified
		entry["level"] = int(verified["level"])
		entry["stake"] = int(verified["stake"])
	_queue.append(entry)
	print("[Server] %s (Lv %d) queued for %s table %d, stake %d%s" % [claim["name"], int(entry["level"]), mode, int(entry["table"]), int(entry["stake"]), " [verified]" if not verified.is_empty() else ""])
	_try_match()

## F13 Phase 2 — verification (server-side only; never in the client).
## Two Supabase calls, both with the SERVICE key in the environment:
##   1. GET /auth/v1/user with the player's access token — proves the
##      token is real and yields its user id (must equal account_id).
##   2. GET /rest/v1/profiles?id=eq.<id> — the real level + balance.
## The stake is then checked against the VERIFIED balance (see
## verify_profile). Any failure refuses the queue/invite with a
## generic message — the client never learns which check failed.
## DESIGN: when verification is enabled, an unauthenticated request
## (no account_id / token) is REFUSED, not downgraded — otherwise
## omitting the token would bypass verification entirely. When it is
## disabled, nothing here runs and Phase 1 applies.
func _begin_verification(peer_id: int, kind: String, data: Dictionary, claim: Dictionary) -> void:
	var account_id := String(data.get("account_id", ""))
	var token := String(data.get("access_token", ""))
	if account_id == "" or token == "":
		if kind == "invite_join":
			_send_to(peer_id, {"type": "invite_failed", "error": "Sign in again to play online — your account could not be verified."})
		else:
			_send_to(peer_id, {"type": "error", "message": "Sign in again to play online — your account could not be verified."})
		print("[Server] Refused unverified %s from peer %d (verification enforced)" % [kind, peer_id])
		return
	if _pending_verify.has(peer_id):
		return # verification already running for this peer
	var http := HTTPRequest.new()
	http.timeout = 15.0
	add_child(http)
	_pending_verify[peer_id] = {"kind": kind, "data": data, "claim": claim,
		"stage": "user", "user_id": "", "http": http}
	http.request_completed.connect(_on_verify_request_completed.bind(peer_id))
	var err := http.request(_verify_url + "/auth/v1/user",
		PackedStringArray(["apikey: " + _verify_key, "Authorization: Bearer " + token]))
	if err != OK:
		_fail_verification(peer_id, "Verification service error — try again.")

func _on_verify_request_completed(result: int, response_code: int, _headers: PackedStringArray, body: PackedByteArray, peer_id: int) -> void:
	var pending: Dictionary = _pending_verify.get(peer_id, {})
	if pending.is_empty():
		return
	var http: HTTPRequest = pending.get("http", null)
	if String(pending.get("stage", "")) == "user":
		if result != HTTPRequest.RESULT_SUCCESS or response_code != 200:
			_fail_verification(peer_id, "Could not verify your account — check your sign-in and try again.")
			return
		var user: Variant = JSON.parse_string(body.get_string_from_utf8())
		if not (user is Dictionary) or String(user.get("id", "")) == "":
			_fail_verification(peer_id, "Could not verify your account — check your sign-in and try again.")
			return
		if String(user["id"]) != String(pending["data"].get("account_id", "")):
			# Token belongs to a different account than claimed.
			_fail_verification(peer_id, "Could not verify your account — check your sign-in and try again.")
			return
		pending["stage"] = "profile"
		pending["user_id"] = String(user["id"])
		_pending_verify[peer_id] = pending
		var err := http.request(_verify_url + "/rest/v1/profiles?select=id,coins,xp&id=eq." + String(user["id"]).uri_encode(),
			PackedStringArray(["apikey: " + _verify_key, "Authorization: Bearer " + _verify_key]))
		if err != OK:
			_fail_verification(peer_id, "Verification service error — try again.")
		return
	# stage == "profile": the row decides level, balance and stake.
	if result != HTTPRequest.RESULT_SUCCESS or response_code != 200:
		_fail_verification(peer_id, "Could not verify your account — check your sign-in and try again.")
		return
	var rows: Variant = JSON.parse_string(body.get_string_from_utf8())
	if not (rows is Array) or rows.is_empty():
		_fail_verification(peer_id, "Your profile was not found — finish registration and try again.")
		return
	var profile: Dictionary = rows[0]
	var claim: Dictionary = pending.get("claim", {})
	var check := verify_profile(String(pending["data"].get("account_id", "")),
		String(pending.get("user_id", "")), profile, int(claim.get("stake", 0)))
	if not bool(check.get("ok", false)):
		_fail_verification(peer_id, String(check.get("error", "Stake not allowed.")))
		return
	_complete_verification(peer_id, check)

func _complete_verification(peer_id: int, check: Dictionary) -> void:
	var pending: Dictionary = _pending_verify.get(peer_id, {})
	if pending.is_empty():
		return
	var kind := String(pending.get("kind", ""))
	var data: Dictionary = pending.get("data", {})
	var claim: Dictionary = pending.get("claim", {})
	_cleanup_verification(peer_id)
	var verified := {"level": int(check["level"]), "stake": int(check["stake"]),
		"balance": int(check["balance"])}
	if kind == "invite_join":
		_join_invite_room(peer_id, data, verified)
	else:
		_enqueue_player(peer_id, claim, verified)
	print("[Server] Peer %d verified (Lv %d, balance %d, stake %d)" % [peer_id, int(verified["level"]), int(verified["balance"]), int(verified["stake"])])

func _fail_verification(peer_id: int, message: String) -> void:
	var pending: Dictionary = _pending_verify.get(peer_id, {})
	if pending.is_empty():
		return
	var kind := String(pending.get("kind", ""))
	_cleanup_verification(peer_id)
	if kind == "invite_join":
		_send_to(peer_id, {"type": "invite_failed", "error": message})
	else:
		_send_to(peer_id, {"type": "error", "message": message})
	print("[Server] Verification failed for peer %d (%s)" % [peer_id, kind])

func _cleanup_verification(peer_id: int) -> void:
	var pending: Dictionary = _pending_verify.get(peer_id, {})
	var http: HTTPRequest = pending.get("http", null)
	if http != null and is_instance_valid(http):
		http.queue_free()
	_pending_verify.erase(peer_id)

## Relay a shot/state message to everyone else in the sender's room.
## F13 Phase 1: per-peer rate limiting — a flooding peer's excess
## messages are dropped, and a peer that sustains flooding is
## disconnected (its room then dissolves via _on_peer_disconnected).
func _relay_to_room(sender: int, data: Dictionary) -> void:
	var room_id: int = int(_peer_room.get(sender, -1))
	if room_id < 0:
		return
	var check := relay_rate_check(_relay_limits.get(sender, {}), Time.get_unix_time_from_system())
	_relay_limits[sender] = check["state"]
	if not bool(check.get("allowed", false)):
		if bool(check.get("disconnect", false)):
			print("[Server] Disconnecting peer %d for relay flooding" % sender)
			_relay_limits.erase(sender)
			_peer.disconnect_peer(sender)
		return
	var room: Dictionary = _rooms.get(room_id, {})
	for pid in room.get("players", []):
		if int(pid) != sender:
			_send_to(int(pid), data)

## F13 Phase 1 — sanitise a client's claimed identity for queue /
## invite_join. Pure, unit-tested. Returns {ok, name, level, table,
## stake, mode} on success, {ok: false, error} when the claim is not
## even well-formed (non-numeric level/stake, negative stake).
## Clamping (not rejection) is used for out-of-range-but-numeric
## values, so a slightly-off client still plays: level 1..100, stake
## 0..1,000,000, table 0..2, name stripped + truncated to 32 chars.
static func sanitize_claim(data: Dictionary) -> Dictionary:
	var level_raw: Variant = data.get("level", 1)
	var stake_raw: Variant = data.get("stake", 0)
	var table_raw: Variant = data.get("table", 0)
	if typeof(level_raw) != TYPE_INT and typeof(level_raw) != TYPE_FLOAT:
		return {"ok": false, "error": "Level must be a number."}
	if typeof(stake_raw) != TYPE_INT and typeof(stake_raw) != TYPE_FLOAT:
		return {"ok": false, "error": "Stake must be a number."}
	if typeof(table_raw) != TYPE_INT and typeof(table_raw) != TYPE_FLOAT:
		return {"ok": false, "error": "Table must be a number."}
	var stake := int(stake_raw)
	if stake < 0:
		return {"ok": false, "error": "Stake cannot be negative."}
	var mode := String(data.get("mode", "2p"))
	if mode != "4p":
		mode = "2p"
	var pname := String(data.get("name", "Player")).strip_edges()
	if pname == "":
		pname = "Player"
	if pname.length() > MAX_CLAIMED_NAME_LEN:
		pname = pname.substr(0, MAX_CLAIMED_NAME_LEN)
	return {"ok": true, "name": pname,
		"level": clampi(int(level_raw), 1, MAX_CLAIMED_LEVEL),
		"table": clampi(int(table_raw), 0, MAX_TABLE),
		"stake": mini(stake, MAX_CLAIMED_STAKE), "mode": mode, "error": ""}

## F13 Phase 1 — one relay-rate-limit step for a peer. `state` is the
## peer's {window_start, count, violations} ({} for a new peer).
## Returns {allowed, disconnect, state}. Pure, unit-tested.
static func relay_rate_check(state: Dictionary, now: float) -> Dictionary:
	var window_start := float(state.get("window_start", now))
	var count := int(state.get("count", 0))
	var violations := int(state.get("violations", 0))
	if now - window_start >= 1.0:
		# New window: a clean previous window forgives one past
		# violation; an over-limit one does not.
		if count <= RELAY_MAX_PER_SEC:
			violations = maxi(0, violations - 1)
		window_start = now
		count = 1
		return {"allowed": true, "disconnect": false,
			"state": {"window_start": window_start, "count": count, "violations": violations}}
	count += 1
	if count > RELAY_MAX_PER_SEC:
		violations += 1
		return {"allowed": false, "disconnect": violations >= RELAY_MAX_VIOLATIONS,
			"state": {"window_start": window_start, "count": count, "violations": violations}}
	return {"allowed": true, "disconnect": false,
		"state": {"window_start": window_start, "count": count, "violations": violations}}

## Pair up waiting players. 2p: two players, same mode+table, levels
## within ±2 (±4 after 30 s). 4p: four players on the same mode+table
## whose levels are all within the window of the first player's level.
## Runs on queue/disconnect events + once a second (widening only).
func _try_match() -> void:
	var now := Time.get_unix_time_from_system()
	var i := 0
	while i < _queue.size():
		var a: Dictionary = _queue[i]
		var mode := String(a.get("mode", "2p"))
		var wait_a: float = now - float(a["at"])
		var window := 2
		if wait_a >= WIDEN_AFTER_SEC:
			window = 4
		if mode == "4p":
			var group := _collect_group(a, window, now)
			if group.size() == 4:
				for e in group:
					_remove_from_queue(int(e["id"]))
				_start_match_4p(group)
				# Queue shrank — restart the scan from the top.
				i = 0
				continue
			i += 1
		else:
			var matched := false
			for j in range(i + 1, _queue.size()):
				var b: Dictionary = _queue[j]
				if String(b.get("mode", "2p")) != "2p":
					continue
				if int(a["table"]) != int(b["table"]):
					continue
				var wait_b: float = now - float(b["at"])
				var w := window
				if wait_b >= WIDEN_AFTER_SEC:
					w = 4
				if absf(int(a["level"]) - int(b["level"])) <= w:
					_queue.remove_at(j)
					_queue.remove_at(i)
					_start_match_2p(a, b)
					matched = true
					break
			if not matched:
				i += 1

## Collect up to 4 queue entries for a 4p group: same mode+table, levels
## within `window` of the anchor's level. Returns the group (may be < 4).
func _collect_group(anchor: Dictionary, window: int, now: float) -> Array:
	var group: Array = [anchor]
	for e in _queue:
		if group.size() >= 4:
			break
		if int(e["id"]) == int(anchor["id"]):
			continue
		if String(e.get("mode", "2p")) != "4p":
			continue
		if int(e["table"]) != int(anchor["table"]):
			continue
		var wait_e: float = now - float(e["at"])
		var w := window
		if wait_e >= WIDEN_AFTER_SEC:
			w = 4
		if absf(int(e["level"]) - int(anchor["level"])) <= w:
			group.append(e)
	return group

## Invite rooms (v7): friends join by group_id after accepting a
## Supabase invite. The match starts when every expected player has
## joined; stakes lock only at match start, as in v6. The inviter is
## always seat 0 (they join last, when the group is ready); invitees
## take seats 1.. in join order.

func _join_invite_room(sender: int, data: Dictionary, verified: Dictionary = {}) -> void:
	var group_id := String(data.get("group_id", ""))
	if group_id == "":
		_send_to(sender, {"type": "invite_failed", "error": "No invite group — try again."})
		return
	# F13 Phase 1: sanitise the claim once, up front — the room table
	# and the stored player fields all use these values, never the
	# raw client JSON.
	var claim := sanitize_claim(data)
	if not bool(claim.get("ok", false)):
		_send_to(sender, {"type": "invite_failed", "error": String(claim.get("error", "Bad invite request."))})
		return
	_names[sender] = String(claim["name"])
	var mode := String(claim["mode"])
	var table := int(claim["table"])
	# F13 Phase 2: a verified join plays for the VERIFIED level/stake,
	# not the claimed ones.
	var plevel := int(claim["level"])
	var pstake := int(claim["stake"])
	if not verified.is_empty():
		plevel = int(verified.get("level", plevel))
		pstake = int(verified.get("stake", pstake))
	var expected := 4 if mode == "4p" else 2
	if _peer_invite.has(sender):
		return # duplicate join — already waiting
	var room: Dictionary = _invite_rooms.get(group_id, {})
	if room.is_empty():
		room = {"mode": mode, "expected": expected,
			"table": table, "players": [],
			"at": Time.get_unix_time_from_system()}
		_invite_rooms[group_id] = room
	if String(room.get("mode", "2p")) != mode or int(room.get("table", 0)) != table:
		_send_to(sender, {"type": "invite_failed", "error": "This invite does not match the group."})
		return
	var players: Array = room["players"]
	players.append({"id": sender, "name": String(claim["name"]),
		"level": plevel, "stake": pstake,
		"is_inviter": bool(data.get("is_inviter", false)), "verified": verified})
	_peer_invite[sender] = group_id
	print("[Server] Invite room %s: %s joined (%d/%d)" % [group_id, data.get("name"), players.size(), expected])
	if invite_room_ready(players, expected):
		_start_invite_match(group_id, room)

func _start_invite_match(group_id: String, room: Dictionary) -> void:
	var ordered := invite_room_order(room["players"])
	var mode := String(room.get("mode", "2p"))
	var ids: Array = []
	for p in ordered:
		ids.append(int(p["id"]))
		_peer_invite.erase(int(p["id"]))
	_invite_rooms.erase(group_id)
	if mode == "4p":
		var infos := invite_room_players_to_infos(ordered)
		var breaker_seat := randi() % 4
		# F13 Phase 2: the room plays for the verified stakes (the
		# infos already carry them — _join_invite_room stored the
		# verified stake in each player's "stake").
		var verified_all := true
		for p in ordered:
			if (p.get("verified", {}) as Dictionary).is_empty():
				verified_all = false
		var stakes4 := {}
		var seats4 := {}
		for k in range(4):
			stakes4[ids[k]] = int(infos[k]["stake"])
			seats4[ids[k]] = k
		var room_id := _new_room("4p", ids, stakes4, seats4, verified_all)
		var payloads := matched_payloads_4p_verified(infos, breaker_seat, verified_all)
		for k in range(4):
			_send_to(ids[k], payloads[k])
		print("[Server] Invite match #%d (4p, group %s): %s + %s vs %s + %s" % [room_id, group_id, infos[0]["name"], infos[2]["name"], infos[1]["name"], infos[3]["name"]])
	else:
		var a_breaks := randi() % 2 == 0
		var ver_a: Dictionary = ordered[0].get("verified", {})
		var ver_b: Dictionary = ordered[1].get("verified", {})
		var stakes2 := {ids[0]: int(ver_a.get("stake", ordered[0].get("stake", 0))),
			ids[1]: int(ver_b.get("stake", ordered[1].get("stake", 0)))}
		var room_id2 := _new_room("2p", ids, stakes2, {ids[0]: 0, ids[1]: 1},
			not ver_a.is_empty() and not ver_b.is_empty())
		var payloads2 := matched_payloads_verified(ordered[0], ordered[1], a_breaks, ver_a, ver_b)
		_send_to(ids[0], payloads2["a"])
		_send_to(ids[1], payloads2["b"])
		print("[Server] Invite match #%d (2p, group %s): %s vs %s" % [room_id2, group_id, ordered[0]["name"], ordered[1]["name"]])

## A player left (or disconnected) before the invite match started:
## the rest cannot play, so tell them and drop the group.
func _leave_invite_room(peer_id: int) -> void:
	var group_id: String = String(_peer_invite.get(peer_id, ""))
	if group_id == "":
		return
	_peer_invite.erase(peer_id)
	var room: Dictionary = _invite_rooms.get(group_id, {})
	if room.is_empty():
		return
	var players: Array = room["players"]
	for i in range(players.size() - 1, -1, -1):
		if int(players[i]["id"]) == peer_id:
			players.remove_at(i)
	if players.is_empty():
		_invite_rooms.erase(group_id)
		return
	for p in players:
		_peer_invite.erase(int(p["id"]))
		_send_to(int(p["id"]), {"type": "invite_failed", "error": "A player left before the match started."})
	_invite_rooms.erase(group_id)
	print("[Server] Invite room %s dissolved (a player left)" % group_id)

## Drop invite rooms that never filled within the timeout.
func _expire_invite_rooms() -> void:
	var now := Time.get_unix_time_from_system()
	var dead: Array = []
	for gid in _invite_rooms.keys():
		var room: Dictionary = _invite_rooms[gid]
		if now - float(room.get("at", 0.0)) > INVITE_ROOM_TIMEOUT:
			dead.append(gid)
	for gid in dead:
		var room2: Dictionary = _invite_rooms[gid]
		for p in room2.get("players", []):
			_peer_invite.erase(int(p["id"]))
			_send_to(int(p["id"]), {"type": "invite_failed", "error": "Not everyone joined in time — send the invite again."})
		_invite_rooms.erase(gid)
		print("[Server] Invite room %s expired (not everyone joined)" % gid)

## Pure helpers (unit-tested): the room is ready when every expected
## player has joined.
static func invite_room_ready(players: Array, expected: int) -> bool:
	return players.size() >= expected

## Seat order: the inviter is seat 0; invitees take seats 1.. in join
## order. Pure — unit-tested.
static func invite_room_order(players: Array) -> Array:
	var ordered: Array = []
	for p in players:
		if bool(p.get("is_inviter", false)):
			ordered.push_front(p)
		else:
			ordered.append(p)
	return ordered

## Ordered invite-room players -> the infos shape matched_payloads_4p
## wants ({name, level, stake, seat}). Pure — unit-tested.
static func invite_room_players_to_infos(ordered: Array) -> Array:
	var infos: Array = []
	for k in range(ordered.size()):
		var p: Dictionary = ordered[k]
		infos.append({"name": String(p["name"]), "level": int(p["level"]),
			"stake": maxi(0, int(p.get("stake", 0))), "seat": k})
	return infos

func _new_room(mode: String, player_ids: Array, stakes: Dictionary = {}, seats: Dictionary = {}, verified_stakes: bool = false) -> int:
	_room_seq += 1
	# F13 Phase 2: the room remembers the stakes it plays for
	# (peer_id -> stake), each peer's seat, and whether the stakes were
	# verified — settlement (see _record_result) pays from these, never
	# from a later client claim. "reports" collects one outcome per
	# player; "settled" stops a second settlement.
	_rooms[_room_seq] = {"mode": mode, "players": player_ids,
		"reports": {}, "settled": false, "stakes": stakes, "seats": seats,
		"verified_stakes": verified_stakes}
	for pid in player_ids:
		_peer_room[int(pid)] = _room_seq
	return _room_seq

func _start_match_2p(a: Dictionary, b: Dictionary) -> void:
	var a_breaks := randi() % 2 == 0
	# F13 Phase 2: verified entries play for their verified stakes.
	var ver_a: Dictionary = a.get("verified", {})
	var ver_b: Dictionary = b.get("verified", {})
	var stakes := {int(a["id"]): int(ver_a.get("stake", a.get("stake", 0))),
		int(b["id"]): int(ver_b.get("stake", b.get("stake", 0)))}
	var verified_both := not ver_a.is_empty() and not ver_b.is_empty()
	var room_id := _new_room("2p", [int(a["id"]), int(b["id"])], stakes,
		{int(a["id"]): 0, int(b["id"]): 1}, verified_both)
	var payloads := matched_payloads_verified(a, b, a_breaks, ver_a, ver_b)
	_send_to(int(a["id"]), payloads["a"])
	_send_to(int(b["id"]), payloads["b"])
	print("[Server] Match #%d (2p): %s (Lv %d, stake %d) vs %s (Lv %d, stake %d), table %d — %s breaks" % [
		room_id, a["name"], int(a["level"]), int(a.get("stake", 0)),
		b["name"], int(b["level"]), int(b.get("stake", 0)), int(a["table"]),
		a["name"] if a_breaks else b["name"]])

func _start_match_4p(group: Array) -> void:
	# Seats 0-3 in queue order; a random seat breaks (their team plays white).
	var breaker_seat := randi() % 4
	var ids: Array = []
	var infos: Array = []
	for k in range(4):
		var e: Dictionary = group[k]
		ids.append(int(e["id"]))
		infos.append({"name": String(e["name"]), "level": int(e["level"]),
			"stake": maxi(0, int(e.get("stake", 0))), "seat": k})
	# F13 Phase 2: the room plays for the (verified, when present)
	# stakes in the infos, and the payloads say so.
	var verified_all := true
	for e in group:
		if (e.get("verified", {}) as Dictionary).is_empty():
			verified_all = false
	var stakes4 := {}
	var seats4 := {}
	for k in range(4):
		stakes4[ids[k]] = int(infos[k]["stake"])
		seats4[ids[k]] = k
	var room_id := _new_room("4p", ids, stakes4, seats4, verified_all)
	var payloads := matched_payloads_4p_verified(infos, breaker_seat, verified_all)
	for k in range(4):
		_send_to(ids[k], payloads[k])
	print("[Server] Match #%d (4p): %s (Lv %d) + %s (Lv %d) vs %s (Lv %d) + %s (Lv %d), table %d — seat %d breaks" % [
		room_id, infos[0]["name"], int(infos[0]["level"]), infos[2]["name"], int(infos[2]["level"]),
		infos[1]["name"], int(infos[1]["level"]), infos[3]["name"], int(infos[3]["level"]),
		int(group[0]["table"]), breaker_seat])

## The two "matched" payloads (pure function, unit-tested): each side gets
## the opponent's name, level and STAKE, so both clients can show the pot
## and pay it out. Stakes default to 0 when absent (old clients / tests).
static func matched_payloads(a: Dictionary, b: Dictionary, a_breaks: bool) -> Dictionary:
	return {
		"a": {"type": "matched", "opponent": String(b["name"]),
			"opp_level": int(b["level"]), "you_break": a_breaks,
			"opp_stake": int(b.get("stake", 0))},
		"b": {"type": "matched", "opponent": String(a["name"]),
			"opp_level": int(a["level"]), "you_break": not a_breaks,
			"opp_stake": int(a.get("stake", 0))},
	}

## 4p matched payloads (pure function, unit-tested): every player gets
## the full seat-ordered roster (name/level/stake/seat), their own seat
## and the breaker seat — so each client can show the teams, the pot and
## the turn order. Returns an Array of 4 payloads, one per seat.
static func matched_payloads_4p(infos: Array, breaker_seat: int) -> Array:
	var out: Array = []
	for k in range(4):
		var roster: Array = []
		for e in infos:
			roster.append({"name": String(e["name"]), "level": int(e["level"]),
				"stake": maxi(0, int(e.get("stake", 0))), "seat": int(e["seat"])})
		out.append({"type": "matched", "mode": "4p", "players": roster,
			"your_seat": k, "breaker_seat": breaker_seat,
			"you_break": k == breaker_seat})
	return out

## F13 Phase 2 — pure helpers (unit-tested, no network, no state).
## The server project is self-contained: these do NOT reference the
## client scripts (Stakes / Settlement live in the game project only),
## so the small formulas are mirrored here deliberately.

## Level from XP, mirroring the client's Save.level() (500 XP/level).
static func profile_level(xp: int) -> int:
	return maxi(1, xp / 500 + 1)

## Check a verified identity against its Supabase profile row.
## `token_sub` is the user id inside the verified access token;
## `profile` is the profiles row {id, coins, xp}; `claimed_stake`
## is the stake the client asked for. Returns {ok, level, balance,
## stake, error}. The stake is REJECTED when it is above the verified
## balance — that is the whole point of verification. Identity
## failures share one generic message (the client never learns which
## check failed); the stake failure is actionable, so it says so.
static func verify_profile(claimed_id: String, token_sub: String, profile: Dictionary, claimed_stake: int) -> Dictionary:
	if claimed_id == "" or token_sub == "":
		return {"ok": false, "level": 1, "balance": 0, "stake": 0, "error": "Account could not be verified."}
	if token_sub != claimed_id:
		return {"ok": false, "level": 1, "balance": 0, "stake": 0, "error": "Account could not be verified."}
	if String(profile.get("id", "")) != claimed_id:
		return {"ok": false, "level": 1, "balance": 0, "stake": 0, "error": "Account could not be verified."}
	var balance := maxi(0, int(profile.get("coins", 0)))
	var level := profile_level(int(profile.get("xp", 0)))
	if claimed_stake < 0 or claimed_stake > balance:
		return {"ok": false, "level": level, "balance": balance, "stake": 0,
			"error": "Stake is more than your coin balance."}
	return {"ok": true, "level": level, "balance": balance, "stake": claimed_stake, "error": ""}

## Effective entry for a matched payload: a verified entry plays for
## its VERIFIED level/stake; an unverified one for its claimed values.
static func _effective_entry(entry: Dictionary, ver: Dictionary) -> Dictionary:
	if ver.is_empty():
		return {"name": String(entry.get("name", "Player")),
			"level": int(entry.get("level", 1)),
			"stake": maxi(0, int(entry.get("stake", 0)))}
	return {"name": String(entry.get("name", "Player")),
		"level": int(ver.get("level", entry.get("level", 1))),
		"stake": maxi(0, int(ver.get("stake", 0)))}

## The two "matched" payloads with verified stakes (pure, unit-tested).
## Each side gets the opponent's VERIFIED name/level/stake, its OWN
## verified stake as "your_stake", and "verified_stakes": true only
## when BOTH sides verified (a half-verified match is not called
## verified — the clients then fall back to claimed stakes). Old
## clients ignore the extra fields. Unverified: identical stakes to
## matched_payloads, plus your_stake + verified_stakes:false.
static func matched_payloads_verified(a: Dictionary, b: Dictionary, a_breaks: bool, ver_a: Dictionary = {}, ver_b: Dictionary = {}) -> Dictionary:
	var ea := _effective_entry(a, ver_a)
	var eb := _effective_entry(b, ver_b)
	var verified := not ver_a.is_empty() and not ver_b.is_empty()
	return {
		"a": {"type": "matched", "opponent": String(eb["name"]),
			"opp_level": int(eb["level"]), "you_break": a_breaks,
			"opp_stake": int(eb["stake"]), "your_stake": int(ea["stake"]),
			"verified_stakes": verified},
		"b": {"type": "matched", "opponent": String(ea["name"]),
			"opp_level": int(ea["level"]), "you_break": not a_breaks,
			"opp_stake": int(ea["stake"]), "your_stake": int(eb["stake"]),
			"verified_stakes": verified},
	}

## 4p matched payloads with verified stakes (pure, unit-tested): the
## roster stakes are already the effective (verified, when present)
## ones; each payload adds its own verified stake as "your_stake" and
## the "verified_stakes" flag (true only when all four verified).
static func matched_payloads_4p_verified(infos: Array, breaker_seat: int, verified: bool = false) -> Array:
	var out: Array = []
	for k in range(4):
		var roster: Array = []
		for e in infos:
			roster.append({"name": String(e["name"]), "level": int(e["level"]),
				"stake": maxi(0, int(e.get("stake", 0))), "seat": int(e["seat"])})
		out.append({"type": "matched", "mode": "4p", "players": roster,
			"your_seat": k, "breaker_seat": breaker_seat,
			"you_break": k == breaker_seat,
			"your_stake": maxi(0, int(infos[k].get("stake", 0))),
			"verified_stakes": verified})
	return out

static func _valid_outcome(outcome: String) -> bool:
	return outcome == "win" or outcome == "loss" or outcome == "draw"

## Settle a 2p match from both players' reported outcomes. `reports`
## is {peer_id: "win"|"loss"|"draw"}; `stakes` is {peer_id: stake}.
## Returns {status, payouts, pot}:
##   "waiting"  — fewer than 2 valid reports (payouts empty).
##   "agreed"   — win+loss (winner takes the whole pot, loser gets
##                 nothing) or draw+draw (each stake refunded).
##   "conflict" — anything else (win+win, loss+loss, win+draw, …):
##                 each player's OWN stake refunded — nobody profits
##                 from a disputed match.
## Payouts are keyed by the same peer ids as the reports.
static func settle_reports_2p(reports: Dictionary, stakes: Dictionary) -> Dictionary:
	var valid: Dictionary = {}
	for pid in reports.keys():
		if _valid_outcome(String(reports[pid])) and stakes.has(pid):
			valid[pid] = String(reports[pid])
	if valid.size() < 2:
		return {"status": "waiting", "payouts": {}, "pot": 0}
	var ids: Array = valid.keys()
	var a: Variant = ids[0]
	var b: Variant = ids[1]
	var pot := int(stakes[a]) + int(stakes[b])
	var oa := String(valid[a])
	var ob := String(valid[b])
	if oa == "draw" and ob == "draw":
		return {"status": "agreed", "payouts": {a: int(stakes[a]), b: int(stakes[b])}, "pot": pot}
	if oa == "win" and ob == "loss":
		return {"status": "agreed", "payouts": {a: pot, b: 0}, "pot": pot}
	if oa == "loss" and ob == "win":
		return {"status": "agreed", "payouts": {a: 0, b: pot}, "pot": pot}
	return {"status": "conflict", "payouts": {a: int(stakes[a]), b: int(stakes[b])}, "pot": pot}

## Settle a 4p match. `reports_by_seat` is {seat: outcome} (seats
## 0..3); `stakes` is the seat-ordered Array of 4 stakes. Returns
## {status, payouts, pot} with payouts a seat-ordered Array of 4.
##   "waiting"  — fewer than 4 valid reports.
##   "agreed"   — one team reports win+win and the other loss+loss:
##                 the winning team splits the whole pot (odd leftover
##                 coin to the team's first seat); draw+draw+draw+draw
##                 refunds every stake.
##   "conflict" — anything else: every stake refunded.
static func settle_reports_4p(reports_by_seat: Dictionary, stakes: Array) -> Dictionary:
	if stakes.size() != 4:
		return {"status": "waiting", "payouts": [], "pot": 0}
	var valid := {}
	for seat in range(4):
		var o := String(reports_by_seat.get(seat, ""))
		if _valid_outcome(o):
			valid[seat] = o
	if valid.size() < 4:
		return {"status": "waiting", "payouts": [], "pot": 0}
	var pot := 0
	for s in stakes:
		pot += int(s)
	var all_draw := true
	for seat in range(4):
		if String(valid[seat]) != "draw":
			all_draw = false
	if all_draw:
		return {"status": "agreed", "payouts": [int(stakes[0]), int(stakes[1]), int(stakes[2]), int(stakes[3])], "pot": pot}
	for team in range(2):
		var s0 := team
		var s1 := team + 2
		var other := 1 - team
		if String(valid[s0]) == "win" and String(valid[s1]) == "win" and String(valid[other]) == "loss" and String(valid[other + 2]) == "loss":
			var share := pot / 2
			var payouts := [0, 0, 0, 0]
			payouts[s0] = share
			payouts[s1] = share
			if pot % 2 == 1:
				payouts[s0] += 1 # odd leftover coin to the team's first seat
			return {"status": "agreed", "payouts": payouts, "pot": pot}
	return {"status": "conflict", "payouts": [int(stakes[0]), int(stakes[1]), int(stakes[2]), int(stakes[3])], "pot": pot}

## Record one player's match outcome and settle when both sides have
## reported. One report per player (a second is ignored); reports for
## a dissolved room, an already-settled room, or an invalid outcome
## are ignored. The settlement goes to every player still in the room.
func _record_result(sender: int, data: Dictionary) -> void:
	var room_id: int = int(_peer_room.get(sender, -1))
	if room_id < 0:
		return
	var room: Dictionary = _rooms.get(room_id, {})
	if room.is_empty() or bool(room.get("settled", false)):
		return
	var outcome := String(data.get("outcome", ""))
	if not _valid_outcome(outcome):
		return
	var reports: Dictionary = room.get("reports", {})
	if reports.has(sender):
		return
	reports[sender] = outcome
	room["reports"] = reports
	_rooms[room_id] = room
	if String(room.get("mode", "2p")) == "4p":
		_maybe_settle_4p(room_id, room)
	else:
		_maybe_settle_2p(room_id, room)

func _maybe_settle_2p(room_id: int, room: Dictionary) -> void:
	var players: Array = room.get("players", [])
	var reports: Dictionary = room.get("reports", {})
	if players.size() != 2 or reports.size() < 2:
		return
	var res := settle_reports_2p(reports, room.get("stakes", {}))
	if String(res.get("status", "")) == "waiting":
		return
	room["settled"] = true
	_rooms[room_id] = room
	var payouts: Dictionary = res["payouts"]
	var pot := int(res["pot"])
	for pid in players:
		_send_to(int(pid), {"type": "settlement", "payout": int(payouts.get(int(pid), 0)),
			"pot": pot, "verified": bool(room.get("verified_stakes", false))})
	print("[Server] Room %d settled (%s): pot %d" % [room_id, String(res["status"]), pot])

func _maybe_settle_4p(room_id: int, room: Dictionary) -> void:
	var players: Array = room.get("players", [])
	var reports: Dictionary = room.get("reports", {})
	if players.size() != 4 or reports.size() < 4:
		return
	var seats: Dictionary = room.get("seats", {})
	var reports_by_seat := {}
	for pid in reports.keys():
		if seats.has(pid):
			reports_by_seat[int(seats[pid])] = String(reports[pid])
	# Seat order, not player order: rebuild the stakes array by seat.
	var ordered_stakes := [0, 0, 0, 0]
	for pid in players:
		if seats.has(pid):
			ordered_stakes[int(seats[pid])] = int((room.get("stakes", {}) as Dictionary).get(int(pid), 0))
	var res := settle_reports_4p(reports_by_seat, ordered_stakes)
	if String(res.get("status", "")) == "waiting":
		return
	room["settled"] = true
	_rooms[room_id] = room
	var payouts: Array = res["payouts"]
	var pot := int(res["pot"])
	for pid in players:
		var seat := int(seats.get(pid, 0))
		_send_to(int(pid), {"type": "settlement", "payout": int(payouts[seat]),
			"pot": pot, "verified": bool(room.get("verified_stakes", false))})
	print("[Server] Room %d settled (%s): pot %d" % [room_id, String(res["status"]), pot])

func _send_to(peer_id: int, data: Dictionary) -> void:
	rpc_id(peer_id, "_relay", JSON.stringify(data))
