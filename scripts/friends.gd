extends Node

## Friends + invites (v7). Friend search runs on Supabase
## (search_players RPC — display name only, never Gmail). Invites live
## in the `invites` table and arrive live over Realtime, with a poll
## every 10 s as a backstop (a missed Realtime event still shows up).
##
## Invite flow (2-player):
##   A searches B by name -> SEND INVITE (mode 2p, A's stake) -> B sees
##   it in the invite box -> B taps ACCEPT -> both sides join the game
##   server's invite room (group_id) -> the server starts the match
##   when both have joined. Stakes lock only at match start, as in v6.
##   DECLINE marks the invite declined; it disappears from the box.
##   Ignored invites stay pending until they expire (24 h) — and are
##   then marked "expired" on the server (L11), so they can never
##   block a group forever. Expired/cancelled rows fail their group.
##
## 4-player: the inviter picks up to 3 friends; one group_id covers all
##   three invites. The match starts when all three have accepted (the
##   inviter is the fourth seat). If anyone declines, the group is dead
##   — the inviter is told and can start over. Invitees join the room
##   as soon as they accept; the inviter joins when the group is ready.
##   The server holds the room up to 3 minutes for the last joiner.
##
## When Supabase is NOT configured, invites fall back to NEARBY
## (same-Wi-Fi, v6) — the invite box says so instead of showing an
## empty list. Invite state never depends on the game server being up.

signal invites_changed
signal invite_received(invite: Dictionary)
signal invite_accepted(invite: Dictionary)
signal group_ready(group_id: String, invites: Array)
signal group_failed(group_id: String, reason: String)

const INVITE_EXPIRY_SECONDS := 24 * 3600
const GROUP_POLL_SECONDS := 10.0
const MAX_GROUP_TARGETS := 3

var incoming: Array = [] # pending invites addressed to me
var outgoing: Array = [] # pending invites I sent
var groups: Dictionary = {} # group_id -> {mode, invites: Array, state}

var _poll_timer := 0.0
var _listening := false

func _ready() -> void:
	Supabase.realtime_invite_changed.connect(_on_realtime_invite)

func _process(delta: float) -> void:
	if not _listening or not Supabase.configured:
		return
	_poll_timer += delta
	if _poll_timer < GROUP_POLL_SECONDS:
		return
	_poll_timer = 0.0
	_poll_outgoing_groups()

## Start listening for invites (after login). Connects Realtime and
## loads the current pending invites once.
func start_listening() -> void:
	_listening = true
	if Supabase.configured and Save.account_id != "":
		Supabase.connect_realtime(Save.account_id)
		refresh()

func stop_listening() -> void:
	_listening = false
	Supabase.disconnect_realtime()
	incoming.clear()
	outgoing.clear()
	groups.clear()

func pending_count() -> int:
	var n := 0
	for inv in incoming:
		if not is_expired(inv):
			n += 1
	return n

# ----------------------------------------------------------------- search

## Search players by display name. Returns {ok, results, error} —
## results are [{id, display_name, level}]. Never returns Gmail.
func search(query: String) -> Dictionary:
	var q := query.strip_edges()
	if q.length() < 2:
		return {"ok": false, "results": [], "error": "Type at least 2 letters to search."}
	if not Supabase.configured:
		return {"ok": false, "results": [], "error": "Friend search is not connected yet."}
	var res := await Supabase.search_players(q, Save.account_id)
	if not bool(res.get("ok", false)):
		return {"ok": false, "results": [], "error": String(res.get("error", "Search failed."))}
	return {"ok": true, "results": res.get("data", []), "error": ""}

# ---------------------------------------------------------------- invites

## Send a 2-player invite. Returns {ok, group_id, error}.
func send_invite(to_id: String, to_name: String, stake: int) -> Dictionary:
	if to_id == Save.account_id:
		return {"ok": false, "group_id": "", "error": "You cannot invite yourself."}
	if not Supabase.configured:
		return {"ok": false, "group_id": "", "error": "Invites are not connected yet — use NEARBY to play together on the same Wi-Fi."}
	var group_id := Accounts.generate_uuid()
	var row := Supabase.invite_row(group_id, Save.account_id, to_id, Save.player_name, to_name, "2p", stake)
	var res := await Supabase.send_invite(row)
	if not bool(res.get("ok", false)):
		return {"ok": false, "group_id": "", "error": String(res.get("error", "Could not send the invite."))}
	var created: Dictionary = res.get("data", row)
	_track_outgoing(created, "2p")
	return {"ok": true, "group_id": group_id, "error": ""}

## Send a 4-player invite to up to 3 friends (targets: [{id, name}]).
## Returns {ok, group_id, error}.
## L1: every target is validated BEFORE any row is sent, and any rows
## already sent are rolled back (cancelled) if a later POST fails — so
## a half-created group can never leave invitees waiting forever.
func send_group_invite(targets: Array, stake: int) -> Dictionary:
	if targets.is_empty() or targets.size() > MAX_GROUP_TARGETS:
		return {"ok": false, "group_id": "", "error": "Pick 1 to 3 friends for a 4-player game."}
	if not Supabase.configured:
		return {"ok": false, "group_id": "", "error": "Invites are not connected yet — use NEARBY to play together on the same Wi-Fi."}
	for t in targets:
		var to_id := String(t.get("id", ""))
		if to_id == "":
			return {"ok": false, "group_id": "", "error": "One of the friends has no player id — pick them again."}
		if to_id == Save.account_id:
			return {"ok": false, "group_id": "", "error": "You cannot invite yourself."}
	var group_id := Accounts.generate_uuid()
	var sent: Array = []
	for t in targets:
		var to_id := String(t.get("id", ""))
		var row := Supabase.invite_row(group_id, Save.account_id, to_id, Save.player_name, String(t.get("name", "")), "4p", stake)
		var res := await Supabase.send_invite(row)
		if not bool(res.get("ok", false)):
			var rollback_failed := false
			for s in sent:
				var cancel := await Supabase.update_invite(String(s.get("id", "")), "cancelled")
				if not bool(cancel.get("ok", false)):
					rollback_failed = true
			_remove_outgoing_group(group_id)
			invites_changed.emit()
			var err := String(res.get("error", "Could not send one of the invites."))
			if rollback_failed:
				err += " One invite may still be waiting — cancel it from the invite box."
			return {"ok": false, "group_id": group_id, "error": err}
		var created: Dictionary = res.get("data", row)
		sent.append(created)
		_track_outgoing(created, "4p")
	return {"ok": true, "group_id": group_id, "error": ""}

## Accept an incoming invite. Returns {ok, invite, error}. The caller
## (Main) then joins the game server's invite room for the group.
func accept_invite(invite: Dictionary) -> Dictionary:
	var res := await Supabase.update_invite(String(invite.get("id", "")), "accepted")
	if not bool(res.get("ok", false)):
		return {"ok": false, "invite": invite, "error": String(res.get("error", "Could not accept the invite."))}
	_remove_incoming(String(invite.get("id", "")))
	var updated: Dictionary = res.get("data", invite)
	updated["status"] = "accepted"
	invite_accepted.emit(updated)
	invites_changed.emit()
	return {"ok": true, "invite": updated, "error": ""}

## Decline an incoming invite. Returns {ok, error}.
func decline_invite(invite: Dictionary) -> Dictionary:
	var res := await Supabase.update_invite(String(invite.get("id", "")), "declined")
	if not bool(res.get("ok", false)):
		return {"ok": false, "error": String(res.get("error", "Could not decline the invite."))}
	_remove_incoming(String(invite.get("id", "")))
	invites_changed.emit()
	return {"ok": true, "error": ""}

## Reload pending incoming invites from the server (the Realtime
## backstop). Also restores sent invites / groups (L2) so a restart
## does not lose tracking of invites sent before it. Returns {ok, error}.
func refresh() -> Dictionary:
	if not Supabase.configured:
		return {"ok": false, "error": "Invites are not connected yet."}
	var res := await Supabase.list_incoming_invites(Save.account_id)
	if not bool(res.get("ok", false)):
		return {"ok": false, "error": String(res.get("error", "Could not load invites."))}
	incoming.clear()
	for inv in res.get("data", []):
		if is_expired(inv):
			# L11: mark it expired on the server instead of only
			# hiding it — a stale pending row would keep blocking
			# any group it belongs to.
			await _expire_invite(inv)
		else:
			incoming.append(inv)
	# L2: rebuild outgoing + groups from the server. The accepted half
	# matters (list_outgoing_invites returns pending AND accepted):
	# a half-accepted group can only become "ready" if its accepted
	# rows are tracked too. Expired rows are marked, not re-tracked.
	var out := await Supabase.list_outgoing_invites(Save.account_id)
	if bool(out.get("ok", false)):
		outgoing.clear()
		groups.clear()
		for row in out.get("data", []):
			if is_expired(row):
				await _expire_invite(row)
			else:
				_track_outgoing(row, String(row.get("mode", "2p")))
	invites_changed.emit()
	return {"ok": true, "error": ""}

## L11: mark an expired invite "expired" on the server. Best-effort —
## a failed PATCH leaves the row pending, still filtered from the UI.
func _expire_invite(inv: Dictionary) -> void:
	var inv_id := String(inv.get("id", ""))
	if inv_id == "":
		return
	await Supabase.update_invite(inv_id, "expired")

## The players of a ready group, inviter first (seat 0), then invitees
## in invite order — [{id, name}]. Used to build the match.
static func group_players(invites: Array, inviter_id: String, inviter_name: String) -> Array:
	var players: Array = [{"id": inviter_id, "name": inviter_name}]
	for inv in invites:
		players.append({"id": String(inv.get("to_id", "")), "name": String(inv.get("to_name", ""))})
	return players

## Group state from its invite rows: "ready" (all accepted), "failed"
## (any declined, expired or cancelled — L11: an expired/cancelled row
## fails the group instead of leaving the inviter waiting on it
## forever), "waiting" (otherwise). Pure — unit-tested.
static func group_state(invites: Array) -> String:
	if invites.is_empty():
		return "unknown"
	var any_dead := false
	var all_accepted := true
	for inv in invites:
		var st := String(inv.get("status", "pending"))
		if st == "declined" or st == "expired" or st == "cancelled":
			any_dead = true
		if st != "accepted":
			all_accepted = false
	if any_dead:
		return "failed"
	if all_accepted:
		return "ready"
	return "waiting"

## Seconds since an invite was created (from its created_at ISO
## string). -1 when the timestamp cannot be parsed.
static func invite_age_seconds(invite: Dictionary) -> int:
	var created := String(invite.get("created_at", ""))
	if created == "":
		return -1
	# Supabase returns "2026-11-22T13:00:00+00:00" — strip the zone.
	var core := created.split("+", false, 1)[0]
	core = core.split("Z", false, 1)[0]
	core = core.replace("T", " ")
	var stamp := Time.get_unix_time_from_datetime_string(core)
	if stamp <= 0:
		return -1
	return int(Time.get_unix_time_from_system()) - int(stamp)

static func is_expired(invite: Dictionary) -> bool:
	var age := invite_age_seconds(invite)
	return age >= 0 and age > INVITE_EXPIRY_SECONDS

# ------------------------------------------------------------- realtime in

func _on_realtime_invite(record: Dictionary) -> void:
	var to_id := String(record.get("to_id", ""))
	var from_id := String(record.get("from_id", ""))
	var status := String(record.get("status", ""))
	if to_id == Save.account_id and status == "pending" and is_expired(record):
		# L11: an invite that arrived already expired — mark it on
		# the server (fire-and-forget; the UI never shows it).
		_expire_invite(record)
	elif to_id == Save.account_id and status == "pending" and not is_expired(record):
		# A new invite for me.
		var known := false
		for inv in incoming:
			if String(inv.get("id", "")) == String(record.get("id", "")):
				known = true
		if not known:
			incoming.append(record)
			invite_received.emit(record)
			invites_changed.emit()
	elif from_id == Save.account_id:
		# One of my sent invites changed: update the group state.
		_update_outgoing(record)
		_check_group(String(record.get("group_id", "")))

# -------------------------------------------------------------- group poll

func _poll_outgoing_groups() -> void:
	var seen := {}
	for inv in outgoing:
		var gid := String(inv.get("group_id", ""))
		if gid != "" and not seen.has(gid):
			seen[gid] = true
			_poll_group(gid)

func _poll_group(group_id: String) -> void:
	var res := await Supabase.list_group_invites(group_id)
	if not bool(res.get("ok", false)):
		return
	var rows: Array = res.get("data", [])
	for row in rows:
		if is_expired(row):
			# L11: mark it on the server, and mirror the status
			# locally so group_state fails the group instead of
			# waiting on a dead invite forever.
			await _expire_invite(row)
			row["status"] = "expired"
		_update_outgoing(row)
	_check_group(group_id)

func _check_group(group_id: String) -> void:
	if group_id == "" or not groups.has(group_id):
		return
	var g: Dictionary = groups[group_id]
	var state := group_state(g.get("invites", []))
	if state == "ready":
		groups.erase(group_id)
		group_ready.emit(group_id, g.get("invites", []))
	elif state == "failed":
		groups.erase(group_id)
		group_failed.emit(group_id, "An invite expired or was declined — the group cannot start.")

# ------------------------------------------------------------------ internals

func _track_outgoing(row: Dictionary, mode: String) -> void:
	outgoing.append(row)
	var gid := String(row.get("group_id", ""))
	if not groups.has(gid):
		groups[gid] = {"mode": mode, "invites": []}
	(groups[gid]["invites"] as Array).append(row)
	invites_changed.emit()

func _update_outgoing(record: Dictionary) -> void:
	var gid := String(record.get("group_id", ""))
	for i in range(outgoing.size()):
		if String(outgoing[i].get("id", "")) == String(record.get("id", "")):
			outgoing[i] = record
	if groups.has(gid):
		var rows: Array = groups[gid]["invites"]
		for i in range(rows.size()):
			if String(rows[i].get("id", "")) == String(record.get("id", "")):
				rows[i] = record

func _remove_incoming(invite_id: String) -> void:
	for i in range(incoming.size() - 1, -1, -1):
		if String(incoming[i].get("id", "")) == invite_id:
			incoming.remove_at(i)

## L1: drop every tracked row of a group (used when a group invite is
## rolled back after a mid-loop failure).
func _remove_outgoing_group(group_id: String) -> void:
	for i in range(outgoing.size() - 1, -1, -1):
		if String(outgoing[i].get("group_id", "")) == group_id:
			outgoing.remove_at(i)
	groups.erase(group_id)
