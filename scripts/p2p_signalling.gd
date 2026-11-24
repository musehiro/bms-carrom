class_name P2PSignalling
extends RefCounted

## P2P signalling (v11 plan §1.4) — the pure half of the WebRTC setup.
## Messages ride Supabase Realtime Broadcast on the ONE existing socket
## (channel "carrom-match-<match_id>"); this file only builds and
## validates the message dicts, so it is unit-testable with no socket.
## The socket half lives in scripts/supabase.gd (join_match_channel /
## send_broadcast / broadcast_received); the peer-connection half lives
## in scripts/net_client.gd.
##
## Roles are deterministic — no glare: the LOWER seat offers to the
## HIGHER seat (2p: seat 0 offers, seat 1 answers; 4p: each pair's
## lower seat offers). The breaker is derived deterministically from
## the match id (plan §1.5, simpler option) so both sides agree with
## no round-trip.
##
## Message shapes (JSON, {type, from, ...}):
##   {"type":"offer",  "from":<uuid>, "sdp":<string>}  — lower seat only
##   {"type":"answer", "from":<uuid>, "sdp":<string>}  — higher seat only
##   {"type":"ice",    "from":<uuid>, "mid":<string>, "index":<int>, "sdp":<string>}
##   {"type":"bye",    "from":<uuid>}                  — "I gave up before connect"

## Default ICE servers (plan §1.5): free Google STUN + the OpenRelay
## public demo TURN. The demo credentials are PUBLIC and shared with
## the world — they can be throttled or withdrawn without notice
## (plan §6.2); a v11.1 follow-up is dedicated credentials in
## backend_config.json. No TURN credentials are committed anywhere
## except these public demo ones, which the plan itself publishes.
const DEFAULT_ICE_SERVERS := [
	{"urls": ["stun:stun.l.google.com:19302"]},
	{"urls": ["turn:openrelay.metered.ca:80",
			"turn:openrelay.metered.ca:443",
			"turns:openrelay.metered.ca:443?transport=tcp"],
		"username": "openrelayproject", "credential": "openrelayproject"},
]

## The Broadcast channel for one match. The match UUID is unguessable,
## so a public broadcast channel is fine — no auth beyond the anon key.
static func channel_name(match_id: String) -> String:
	return "carrom-match-%s" % match_id

## Realtime topic for a channel (Phoenix: "realtime:<channel>").
static func channel_topic(match_id: String) -> String:
	return "realtime:%s" % channel_name(match_id)

static func offer_message(from_id: String, sdp: String) -> Dictionary:
	return {"type": "offer", "from": from_id, "sdp": sdp}

static func answer_message(from_id: String, sdp: String) -> Dictionary:
	return {"type": "answer", "from": from_id, "sdp": sdp}

static func ice_message(from_id: String, mid: String, index: int, sdp: String) -> Dictionary:
	return {"type": "ice", "from": from_id, "mid": mid, "index": index, "sdp": sdp}

static func bye_message(from_id: String) -> Dictionary:
	return {"type": "bye", "from": from_id}

## Validate an incoming signalling message. Returns the message with
## normalised types, or {} for anything malformed / from ourselves /
## of an unknown type. `my_id` is dropped so a client never acts on
## its own echo (Broadcast with self:true would echo; we join with
## self:false, but the check is free).
static func parse_message(msg: Variant, my_id: String) -> Dictionary:
	if not (msg is Dictionary):
		return {}
	var mtype := String(msg.get("type", ""))
	if mtype != "offer" and mtype != "answer" and mtype != "ice" and mtype != "bye":
		return {}
	var from_id := String(msg.get("from", ""))
	if from_id == "" or from_id == my_id:
		return {}
	if (mtype == "offer" or mtype == "answer") and String(msg.get("sdp", "")) == "":
		return {}
	if mtype == "ice" and String(msg.get("sdp", "")) == "":
		return {}
	return {
		"type": mtype,
		"from": from_id,
		"sdp": String(msg.get("sdp", "")),
		"mid": String(msg.get("mid", "")),
		"index": int(msg.get("index", 0)),
	}

## The breaker seat, derived deterministically from the match id so
## both sides agree without a round-trip (plan §1.5): first byte of
## md5(match_id) % player_count. Both clients already have the match
## id from the matches row, so both can build the matched payload
## locally. Pure — unit-tested (same id → same seat on both sides;
## both seats covered across ids; 4p covers all four seats).
static func breaker_seat_for_match(match_id: String, player_count: int) -> int:
	var n := maxi(2, player_count)
	if match_id == "":
		return 0
	var digest := match_id.md5_text()
	if digest == "":
		return 0
	return int(("0x" + digest.substr(0, 2)).hex_to_int()) % n

## Should `my_seat` create the offer to `other_seat`? Lower seat
## offers to higher seat — exactly one offer per pair, no glare.
static func should_offer(my_seat: int, other_seat: int) -> bool:
	return my_seat < other_seat

## Merge a config turn_servers list over the defaults: the config wins
## when it is a non-empty Array of dicts with "urls"; otherwise the
## defaults above. Pure — unit-tested. No credentials are ever logged.
static func ice_servers_from_config(configured: Variant) -> Array:
	if configured is Array and not (configured as Array).is_empty():
		var ok := true
		for entry in configured:
			if not (entry is Dictionary) or not entry.has("urls"):
				ok = false
				break
		if ok:
			return configured
	return DEFAULT_ICE_SERVERS.duplicate(true)

## The ICE-server dict passed to WebRTCPeerConnection.initialize().
static func ice_config(servers: Array) -> Dictionary:
	return {"ice_servers": servers}
