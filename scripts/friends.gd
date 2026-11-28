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
##   The inviter can CANCEL a sent invite from the home "WAITING FOR…"
##   list — the whole group is cancelled, so the invitees' invites
##   disappear too. Ignored invites stay pending until they expire
##   (24 h) — then marked "expired" on the server (L11), so they can never
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
## Incoming-invite poll (2026-11-28, B4): pending invites addressed to
## me, every 2 s while listening (see _poll_incoming). The receiving
## phone never SHOWED an invite because incoming invites were only
## loaded at login (refresh) and otherwise relied on Realtime alone.
const INCOMING_POLL_SECONDS := 2.0
const MAX_GROUP_TARGETS := 3
## §11 online lobby presence: heartbeat every ~30 s on the ONE existing
## socket (presence rows are PostgREST, not a second socket); rows older
## than ~90 s are treated as offline. Status is "online" | "in_match".
const PRESENCE_HEARTBEAT_SECONDS := 30.0
const PRESENCE_OFFLINE_SECONDS := 90
## 3-player guard (v11): matches are 2-player or 4-player doubles ONLY.
## validate_group_targets() (below) rejects exactly-2-target groups.

var incoming: Array = [] # pending invites addressed to me
var outgoing: Array = [] # pending invites I sent
var groups: Dictionary = {} # group_id -> {mode, invites: Array, state}
var online_players: Array = [] # §11: last fetched live-player list
var _presence_status := "online"
var _presence_timer := 0.0
var _presence_busy := false
## Heartbeat failure logging (v11): the last heartbeat's outcome, so a
## failure is logged on transition only — a dead network would
## otherwise spam the log every 30 s. True at start (no failure yet).
var _presence_last_ok := true

var _poll_timer := 0.0
var _incoming_timer := 0.0
var _incoming_busy := false
var _listening := false

func _ready() -> void:
	Supabase.realtime_invite_changed.connect(_on_realtime_invite)

func _process(delta: float) -> void:
	if not _listening or not Supabase.configured:
		return
	# §11 presence heartbeat (~30 s, same cadence as the Realtime
	# heartbeat in supabase.gd — the row carries no socket of its own).
	# Runs on every frame, NOT behind the group-poll early-return.
	_presence_timer += delta
	if _presence_timer >= PRESENCE_HEARTBEAT_SECONDS and not _presence_busy:
		_presence_timer = 0.0
		_heartbeat_presence_async()
	# B4 incoming-invite poll (2 s): new invites surface even when a
	# Realtime event was missed or the channel join was rejected.
	# Runs on every frame, NOT behind the group-poll early-return.
	_incoming_timer += delta
	if _incoming_timer >= INCOMING_POLL_SECONDS and not _incoming_busy:
		_incoming_timer = 0.0
		_poll_incoming()
	_poll_timer += delta
	if _poll_timer < GROUP_POLL_SECONDS:
		return
	_poll_timer = 0.0
	_poll_outgoing_groups()

## Start listening for invites (after login). Connects Realtime and
## loads the current pending invites once.
func start_listening() -> void:
	_listening = true
	_incoming_timer = INCOMING_POLL_SECONDS # first incoming poll on the next frame
	if Supabase.configured and Save.account_id != "":
		Supabase.connect_realtime(Save.account_id)
		refresh()

func stop_listening() -> void:
	_listening = false
	Supabase.disconnect_realtime()
	# §11: going offline — drop my presence row (best-effort).
	if Save.account_id != "":
		Supabase.delete_presence(Save.account_id)
	incoming.clear()
	outgoing.clear()
	groups.clear()
	online_players.clear()

func pending_count() -> int:
	var n := 0
	for inv in incoming:
		if not is_expired(inv):
			n += 1
	return n

# ------------------------------------------------------------ §11 presence
# Live-player list for the online lobby: display name + level + status
# ONLY (never Gmail, never coins — the presence table holds nothing else).

## My current presence status ("online" | "in_match"). Main sets
## "in_match" when a match starts and "online" on returning home.
## Heartbeats immediately so the lobby list updates without waiting
## for the next 30 s tick.
func set_presence_status(status: String) -> void:
	if status != "online" and status != "in_match":
		return
	_presence_status = status
	_presence_timer = 0.0
	if _listening and Supabase.configured and Save.account_id != "":
		_heartbeat_presence_async()

func _heartbeat_presence_async() -> void:
	if _presence_busy or Save.account_id == "":
		return
	_presence_busy = true
	var res := await Supabase.heartbeat_presence(Save.account_id, Save.player_name, Save.level(), _presence_status)
	_presence_busy = false
	# Surface heartbeat failures in the log (v11): when this fails the
	# lobby silently empties — e.g. the session is gone and the write
	# runs as `anon`, so RLS denies it and this phone never appears in
	# anyone else's lobby. Transition-only: a dead network must not
	# spam the log every 30 s.
	var ok := bool(res.get("ok", false))
	if not ok and _presence_last_ok:
		push_warning("Presence heartbeat failed (%s) — this phone will not appear in other players' lobbies." % String(res.get("error", "unknown error")))
	elif ok and not _presence_last_ok:
		print("Presence heartbeat recovered.")
	_presence_last_ok = ok

## Fetch the live-player list (presence rows, newest first), filtered
## to rows younger than PRESENCE_OFFLINE_SECONDS and excluding me.
## Returns {ok, players, error} — players are [{id, display_name,
## level, status}]. Pure filter helper below is unit-tested.
func list_online_players() -> Dictionary:
	if not Supabase.configured:
		return {"ok": false, "players": [], "error": "Online lobby is not connected yet."}
	var res := await Supabase.list_presence()
	if not bool(res.get("ok", false)):
		return {"ok": false, "players": [], "error": String(res.get("error", "Could not load online players."))}
	online_players = filter_online_players(res.get("data", []), Save.account_id)
	return {"ok": true, "players": online_players, "error": ""}

## Pure filter: drop my own row, drop stale rows (>90 s), keep only
## well-formed rows (name + level + status). Unit-tested.
static func filter_online_players(rows: Array, my_id: String) -> Array:
	var out: Array = []
	for row in rows:
		if String(row.get("id", "")) == "" or String(row.get("id", "")) == my_id:
			continue
		var age := SupabaseClient.iso_age_seconds(String(row.get("updated_at", "")))
		if age < 0 or age > PRESENCE_OFFLINE_SECONDS:
			continue
		var status := String(row.get("status", "online"))
		if status != "online" and status != "in_match":
			status = "online"
		out.append({"id": String(row.get("id", "")),
			"display_name": String(row.get("display_name", "Player")),
			"level": maxi(1, int(row.get("level", 1))),
			"status": status})
	return out

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

## 3-player guard (v11 plan decision log, Buddhika 2026-11-23 12:33):
## matches are 2-player or 4-player doubles ONLY — there is no
## 3-player mode. Exactly 2 targets (3 players total) is rejected
## here, at send time, before any row is written. The UI offers only
## 1-or-3 picks (home invite box) and Main re-checks before sending.
## Pure — unit-tested in tests/p2p_test.gd.
static func validate_group_targets(targets: Array, my_id: String) -> Dictionary:
	if targets.is_empty() or targets.size() > MAX_GROUP_TARGETS:
		return {"ok": false, "error": "Pick 1 to 3 friends for a 4-player game."}
	if targets.size() == 2:
		return {"ok": false, "error": "Matches are 2 players (invite 1 friend) or 4 players (invite 3 friends) — 3-player matches are not supported."}
	for t in targets:
		var to_id := String(t.get("id", ""))
		if to_id == "":
			return {"ok": false, "error": "One of the friends has no player id — pick them again."}
		if to_id == my_id:
			return {"ok": false, "error": "You cannot invite yourself."}
	return {"ok": true, "error": ""}

## Send a 4-player invite to up to 3 friends (targets: [{id, name}]).
## Returns {ok, group_id, error}.
## L1: every target is validated BEFORE any row is sent, and any rows
## already sent are rolled back (cancelled) if a later POST fails — so
## a half-created group can never leave invitees waiting forever.
func send_group_invite(targets: Array, stake: int) -> Dictionary:
	var valid := validate_group_targets(targets, Save.account_id)
	if not bool(valid.get("ok", false)):
		return {"ok": false, "group_id": "", "error": String(valid.get("error", "Could not send the invites."))}
	if not Supabase.configured:
		return {"ok": false, "group_id": "", "error": "Invites are not connected yet — use NEARBY to play together on the same Wi-Fi."}
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

## Cancel an invite I sent (inviter side, from the invite box's
## "WAITING FOR…" list). Cancels the WHOLE group, not just one row:
## a 4-player group with one friend un-invited can never become a
## 4-player match (there is no 3-player mode), so the other rows are
## cancelled too and the invitees' invites disappear. Each row is
## PATCHed to "cancelled" (the L1 rollback status); the group is then
## dropped locally so it can never fire group_ready. Returns
## {ok, error} — best-effort: a row whose PATCH fails is reported in
## the error instead of claiming a clean cancel.
func cancel_invite(invite: Dictionary) -> Dictionary:
	var group_id := String(invite.get("group_id", ""))
	if group_id == "":
		return {"ok": false, "error": "That invite has no group to cancel."}
	var rows: Array = []
	for inv in outgoing:
		if String(inv.get("group_id", "")) == group_id:
			rows.append(inv)
	if rows.is_empty():
		return {"ok": false, "error": "That invite is already gone."}
	var failed := 0
	# Drop the group locally FIRST: the PATCH broadcasts arrive live
	# (Realtime) while the later rows are still being cancelled, and
	# without this the broadcast's _check_group would fail the group
	# and toast "an invite expired or was declined" for a cancel the
	# inviter chose themself. A row whose PATCH fails stays pending on
	# the server — the error below says so, and the next refresh()
	# re-tracks it, so it can be cancelled again from the box.
	_remove_outgoing_group(group_id)
	# The sender was discovering this group's match (B3) — stop it,
	# or the discovery poll would run forever on a dead group.
	var net := _net()
	if net != null and net.has_method("stop_match_discovery"):
		net.stop_match_discovery()
	for row in rows:
		var res := await Supabase.update_invite(String(row.get("id", "")), "cancelled")
		if not bool(res.get("ok", false)):
			failed += 1
	invites_changed.emit()
	if failed > 0:
		return {"ok": false, "error": "Cancelled, but %d invite(s) could not be updated — they may still show as waiting for the other player." % failed}
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
		# Group the rows first: the match-exists check (round 4)
		# is per GROUP, not per invite row.
		var by_group := {}
		for row in out.get("data", []):
			if is_expired(row):
				await _expire_invite(row)
				continue
			var gid2 := String(row.get("group_id", ""))
			if not by_group.has(gid2):
				by_group[gid2] = []
			(by_group[gid2] as Array).append(row)
		for gid2 in by_group.keys():
			if Save.consumed_invite_groups.has(gid2):
				# v11: this group already fired group_ready (the
				# inviter joined) — do not re-track it, or the next
				# poll would re-fire group_ready for a dead room.
				continue
			var grows: Array = by_group[gid2]
			if group_state(grows) == "ready":
				# Round 4 (incident 2026-11-28 05:18): a group that
				# became ready while the app was closed — or was
				# never consumed ON THIS PHONE (the other phone
				# drove the accept) — is re-tracked here and the
				# 10 s group poll re-fires _on_group_ready for it,
				# even though its match ALREADY exists. The re-fire
				# starts a second resolution loop over a live
				# match. A ready group with a live match row is
				# already handled — consume it and do not track it;
				# the match is found by the discovery poll instead.
				var mrows: Array = await Supabase.poll_matches_by_group(gid2)
				if not mrows.is_empty():
					print("[MATCH] refresh: group %s already has a match — consuming, not re-tracking" % gid2)
					_mark_group_consumed(gid2)
					continue
			for row in grows:
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
	elif to_id == Save.account_id and (status == "cancelled" or status == "declined" or status == "expired"):
		# v11: the inviter cancelled the invite (or it expired) — drop
		# it from my inbox live instead of leaving it there until the
		# next refresh/restart.
		var before := incoming.size()
		_remove_incoming(String(record.get("id", "")))
		if incoming.size() != before:
			invites_changed.emit()
	elif from_id == Save.account_id:
		# One of my sent invites changed: update the group state.
		_update_outgoing(record)
		_check_group(String(record.get("group_id", "")))

# -------------------------------------------------------------- group poll

## B4: poll pending invites addressed to me every 2 s while listening.
## Incoming invites used to be loaded only at login (refresh) and
## otherwise relied on Realtime alone — a missed or rejected Realtime
## event meant the receiving phone NEVER showed the invite (no banner,
## no badge, nothing). This poll is the backstop: genuinely new rows
## surface through invite_received (Main shows the banner + toast, the
## home badge updates via invites_changed); rows that vanished
## server-side (cancelled / expired) drop silently; already-expired
## rows are marked expired on the server (L11) instead of reappearing.
## Cheap indexed query (to_id + status=pending). Never re-emits a row
## already known — a re-delivered row must not re-show the banner.
func _poll_incoming() -> void:
	if _incoming_busy or Save.account_id == "":
		return
	_incoming_busy = true
	var res := await Supabase.list_incoming_invites(Save.account_id)
	_incoming_busy = false
	if not _listening:
		return
	if not bool(res.get("ok", false)):
		return
	var fresh: Array = res.get("data", [])
	var fresh_ids := {}
	for inv in fresh:
		fresh_ids[String(inv.get("id", ""))] = true
	var changed := false
	for i in range(incoming.size() - 1, -1, -1):
		if not fresh_ids.has(String(incoming[i].get("id", ""))):
			incoming.remove_at(i)
			changed = true
	for inv in fresh:
		if is_expired(inv):
			# L11: mark it expired on the server (fire-and-forget)
			# instead of only hiding it.
			_expire_invite(inv)
			continue
		var known := false
		for old in incoming:
			if String(old.get("id", "")) == String(inv.get("id", "")):
				known = true
				break
		if not known:
			incoming.append(inv)
			changed = true
			invite_received.emit(inv)
	if changed:
		invites_changed.emit()

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
	# Round 4: a ready group whose match ALREADY exists must not
	# fire group_ready — its match is already handled (the other
	# phone formed it, or an earlier session did). Consume it here
	# so the poll never re-fires it; the sender's discovery poll
	# finds the match and joins it. At first-ready time no match
	# exists yet (the RPC has not run), so the normal flow is
	# unaffected — this only bites on the re-fire case.
	if groups.has(group_id) and group_state((groups[group_id] as Dictionary).get("invites", [])) == "ready":
		var mrows: Array = await Supabase.poll_matches_by_group(group_id)
		if not mrows.is_empty():
			print("[MATCH] group %s already has a match — consuming, not firing group_ready" % group_id)
			_mark_group_consumed(group_id)
			groups.erase(group_id)
			return
	_check_group(group_id)

func _check_group(group_id: String) -> void:
	if group_id == "" or not groups.has(group_id):
		return
	var g: Dictionary = groups[group_id]
	var state := group_state(g.get("invites", []))
	if state == "ready":
		# Round 4: re-check the consumed set immediately before
		# emitting — a group consumed between the poll and this
		# check must not fire twice.
		if Save.consumed_invite_groups.has(group_id):
			groups.erase(group_id)
			return
		# v11: consume the group BEFORE emitting — the rows stay
		# "accepted" on the server forever, so a later refresh()
		# must not re-track (and re-fire) this group. A group that
		# became ready while the app was closed is NOT consumed yet,
		# so refresh() still restores it and it fires exactly once.
		_mark_group_consumed(group_id)
		groups.erase(group_id)
		group_ready.emit(group_id, g.get("invites", []))
	elif state == "failed":
		groups.erase(group_id)
		group_failed.emit(group_id, "An invite expired or was declined — the group cannot start.")

## v11: remember that a group already fired group_ready (persisted in
## the save so it survives restarts). refresh() skips consumed groups.
func _mark_group_consumed(group_id: String) -> void:
	if group_id == "" or Save.consumed_invite_groups.has(group_id):
		return
	Save.consumed_invite_groups.append(group_id)
	while Save.consumed_invite_groups.size() > 50:
		Save.consumed_invite_groups.remove_at(0)
	Save.save()

# ------------------------------------------------------------------ internals

## The Net autoload, resolved dynamically (NOT by identifier): -s
## headless tests load this script without autoloads registered (the
## same reason Net uses _sb() for Supabase). Null only in tests.
func _net() -> Node:
	if not is_inside_tree():
		return null
	var root := get_tree().root
	if root == null:
		return null
	return root.get_node_or_null("Net")

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
