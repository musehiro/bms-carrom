extends Node

## MatchState — autoload. The ONE place the current Supabase match lives.
##
## join_match (Net) validates a matches row with the pure statics below
## and stores it here; Main reads the stored match (via matched_payload)
## to open the lobby, so the match id + roster + seats survive the
## lobby popup, a scene clear, and the match screen build. No UI, no
## network — the row arrives from Supabase (GET matches?id=eq.<id> or a
## discovery poll) and is verified BEFORE it is stored.
##
## A match NEVER has status 'started': nothing in the SQL or the client
## ever sets it — a formed match sits at 'waiting' until the players
## connect, then 'playing'. Any code that waits for 'started' waits
## forever (the 2026-11-28 invite failure). JOINABLE_STATUSES is the
## whole joinable set, and validate_match_row rejects anything else.

## Statuses a matches row may be joined in (waiting -> ready -> playing).
const JOINABLE_STATUSES := ["waiting", "ready", "playing"]

var match_id := ""
var group_id := "" # the invites group_id for invite matches; "" for random
var mode := "2p" # "2p" | "4p"
var table := 0 # stake band (invite matches: 0)
var players: Array = [] # seat-ordered [{id, name, level, stake, seat}]
var player_ids: Array = [] # uuids, same order as players
var my_seat := -1 # my seat in players (-1 = no match stored)
var my_id := ""
var status := ""
var created_at := ""

func is_in_match() -> bool:
	return match_id != "" and my_seat >= 0

## String-or-empty for a possibly-null row value: String(null) is a
## runtime error in GDScript, and PostgREST returns JSON null for SQL
## NULL (random matches have group_id NULL) — a plain String() call on
## it aborts the whole validation, so every random match would fail
## validation for exactly this reason (caught by tests, 2026-11-28).
static func _str_or_empty(v: Variant) -> String:
	if v == null:
		return ""
	return String(v)

func clear() -> void:
	match_id = ""
	group_id = ""
	mode = "2p"
	table = 0
	players = []
	player_ids = []
	my_seat = -1
	my_id = ""
	status = ""
	created_at = ""

## Validate a matches row for joining. Returns {ok, reason, my_seat,
## mode, group_id}. Pure — unit-tested. Rejects: an empty row, a row
## with no id, a status outside JOINABLE_STATUSES (notably 'started',
## which nothing ever sets), a row that does not list me in player_ids,
## and a row with no players array. The seat comes from the players
## array when it names me, else from my position in player_ids.
static func validate_match_row(row: Dictionary, my_id: String) -> Dictionary:
	if row.is_empty():
		return {"ok": false, "reason": "empty match row", "my_seat": -1, "mode": "2p", "group_id": ""}
	var mid := String(row.get("id", ""))
	if mid == "":
		return {"ok": false, "reason": "match row has no id", "my_seat": -1, "mode": "2p", "group_id": ""}
	var st := String(row.get("status", ""))
	if st not in JOINABLE_STATUSES:
		return {"ok": false, "reason": "match status '%s' is not joinable (waiting/ready/playing only)" % st,
			"my_seat": -1, "mode": "2p", "group_id": ""}
	if my_id == "":
		return {"ok": false, "reason": "no player id to check the match against", "my_seat": -1, "mode": "2p", "group_id": ""}
	var ids: Array = row.get("player_ids", [])
	if not (ids is Array) or not ids.has(my_id):
		return {"ok": false, "reason": "you are not in this match", "my_seat": -1, "mode": "2p", "group_id": ""}
	var plist: Array = row.get("players", [])
	if not (plist is Array) or plist.is_empty():
		return {"ok": false, "reason": "match row has no players", "my_seat": -1, "mode": "2p", "group_id": ""}
	var seat := -1
	for p in plist:
		if p is Dictionary and String(p.get("id", "")) == my_id:
			seat = int(p.get("seat", -1))
			break
	if seat < 0:
		# The players array does not name me — fall back to my
		# position in player_ids (the SQL builds both in seat order).
		seat = ids.find(my_id)
	if seat < 0:
		return {"ok": false, "reason": "no seat for you in this match", "my_seat": -1, "mode": "2p", "group_id": ""}
	return {"ok": true, "reason": "", "my_seat": seat,
		"mode": String(row.get("mode", "2p")), "group_id": _str_or_empty(row.get("group_id", ""))}

## Pick the match row to join from a discovery poll (newest-first rows).
## Preference order (2026-11-28 fix plan): the row for the invite group
## when one is being waited on, else the newest row of the wanted mode,
## else the newest row at all. Never just the first row: a player can
## be in more than one waiting match (a stale one + a fresh one), and
## the first row in arrival order may be the stale one. Pure — tested.
static func pick_match_row(rows: Array, my_id: String, group_id: String = "", mode: String = "") -> Dictionary:
	var valid: Array = []
	for r in rows:
		if r is Dictionary and bool(validate_match_row(r, my_id).get("ok", false)):
			valid.append(r)
	if valid.is_empty():
		return {}
	# Newest by created_at (ISO strings sort lexicographically); rows
	# without a timestamp sort last.
	var newest := func(list: Array) -> Dictionary:
		var sorted := list.duplicate()
		sorted.sort_custom(func(a: Dictionary, b: Dictionary) -> bool:
			return String(a.get("created_at", "")) > String(b.get("created_at", "")))
		return sorted[0]
	if group_id != "":
		var grouped: Array = []
		for r in valid:
			if _str_or_empty(r.get("group_id", "")) == group_id:
				grouped.append(r)
		if not grouped.is_empty():
			return newest.call(grouped)
	if mode != "":
		var moded: Array = []
		for r in valid:
			if String(r.get("mode", "")) == mode:
				moded.append(r)
		if not moded.is_empty():
			return newest.call(moded)
	return newest.call(valid)

## Pick the NEWER match to migrate to while waiting for the peer
## (2026-11-28 split-brain fix): two cross-invites can form TWO
## matches with the same players, one per group, and each phone joins
## the one its own RPC made — then both wait forever in different
## channels. While the peer has not connected yet, the phone keeps
## polling; if a match appears with the SAME player set and a NEWER
## created_at, both phones converge on it (newest is a total order,
## so both sides pick the same row). Returns {} when there is no such
## row. Pure — tested.
static func pick_newer_match(rows: Array, my_id: String, current_match_id: String, current_created_at: String, current_player_ids: Array) -> Dictionary:
	var mine: Array = (current_player_ids as Array).duplicate()
	mine.sort()
	var best: Dictionary = {}
	var best_created := ""
	for r in rows:
		if not (r is Dictionary):
			continue
		if String(r.get("id", "")) == "" or String(r.get("id", "")) == current_match_id:
			continue
		if not bool(validate_match_row(r, my_id).get("ok", false)):
			continue
		var ids: Array = (r.get("player_ids", []) as Array).duplicate()
		ids.sort()
		if ids != mine:
			continue # a match with different players — never migrate to it
		var created := String(r.get("created_at", ""))
		if created == "" or created <= current_created_at:
			continue # not strictly newer — the current match stays
		if best.is_empty() or created > best_created:
			best = r
			best_created = created
	return best

## Store a validated row. Returns false (and stores nothing) when the
## row fails validation — the caller keeps polling instead of joining
## a match that is not theirs / not joinable.
func set_from_row(row: Dictionary, my_id: String) -> bool:
	var v := validate_match_row(row, my_id)
	if not bool(v.get("ok", false)):
		print("[MATCH] MatchState reject %s: %s" % [String(row.get("id", "?")), String(v.get("reason", ""))])
		return false
	match_id = String(row.get("id", ""))
	group_id = _str_or_empty(row.get("group_id", ""))
	mode = String(v.get("mode", "2p"))
	table = int(row.get("table", 0))
	players = (row.get("players", []) as Array).duplicate(true)
	player_ids = (row.get("player_ids", []) as Array).duplicate()
	my_seat = int(v.get("my_seat", -1))
	self.my_id = my_id
	status = String(row.get("status", ""))
	created_at = _str_or_empty(row.get("created_at", ""))
	print("[MATCH] MatchState stored match %s mode=%s seat=%d players=%d status=%s" % [
		match_id, mode, my_seat, players.size(), status])
	return true

## The `matched` payload Main (and the lobby) consume, built from the
## stored row — same shape NetClient.p2p_matched_payload builds from a
## find_match / create_match_from_invites return, so the lobby flow
## below is identical whichever way the match was found.
func matched_payload() -> Dictionary:
	if not is_in_match():
		return {}
	return NetClient.p2p_matched_payload(players, my_seat, match_id)
