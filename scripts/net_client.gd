class_name NetClient
extends Node

## Online client for BMS Carrom (design doc 6.2, 6.5).
## Autoload "Net" — the node path (/root/Net) MUST match the server's relay
## node path, because Godot RPCs are addressed by node path. The server
## (server/ project) runs the same path with a server-side script.
##
## v11 P2P (plan §1.5): ONLINE now plays phone-to-phone over WebRTC
## (WebRTCMultiplayerPeer mesh + Supabase Realtime Broadcast signalling
## on the ONE existing socket — see scripts/p2p_signalling.gd and
## scripts/supabase.gd). The high-level RPC layer (_relay: shot / state /
## forfeit) is transport-agnostic and unchanged; only _send() addressing
## changed (2p: rpc_id(opponent); 4p: loop over the other peers).
## The transport switch below keeps the old ENet internet path behind
## TRANSPORT_LEGACY_ENET for one version (rollback); LAN hosting is
## untouched. Public interface UNCHANGED: same signals + methods.
##
## Connects to the BMS Carrom relay/matchmaking server (see
## docs/online-server.md) over ENet — LEGACY path only now; the server
## is frozen (docs/online-server.md). The server only matched players
## and relayed messages — both clients simulate the same physics from
## the same shot inputs, with a full state snapshot after every shot
## to resync.
##
## Protocol (JSON strings sent via the _relay RPC):
##   P2P (v11): matchmaking/signalling via Supabase (queue + matches
##     rows, Broadcast offer/answer/ICE); gameplay is the same _relay
##     messages below, addressed peer-to-peer instead of via peer 1.
##   C->S {"type":"queue","name":str,"level":int,"table":int,"stake":int}
##   S->C {"type":"matched","opponent":str,"opp_level":int,"you_break":bool,"opp_stake":int}
##   C->S {"type":"leave_queue"}           (cancel a search without disconnecting)
##   C->S {"type":"lobby_ready","seat":int} / S->C (relayed to the room)
##   C->S {"type":"lobby_leave"}           (leave the lobby; room dissolves)
##   C->S {"type":"shot","sx":float,"dx":float,"dy":float,"power":float}
##   S->C {"type":"shot", ...same...}            (relayed to the opponent)
##   C->S {"type":"state", ...}                  (snapshot after settling)
##   S->C {"type":"state", ...}                  (relayed)
##   C->S {"type":"forfeit"}  /  S->C {"type":"opponent_left"}
##   S->C {"type":"error","message":str}
## F13 Phase 2 (v11): when signed in, queue / invite_join ALSO carry
##   "account_id" (Supabase user id) + "access_token" (Supabase JWT).
##   A verifying server checks the token against Supabase, uses the
##   VERIFIED level/stake for matchmaking, and the matched payload then
##   carries "your_stake" + "verified_stakes":true — the client must use
##   those stakes, not its claimed ones (see Settlement). The fields
##   are omitted entirely when not signed in (LAN / offline / guest),
##   and are NEVER logged. At match end the client sends
##   C->S {"type":"result","outcome":"win"|"loss"|"draw"} and the server
##   answers S->C {"type":"settlement","payout":int,"pot":int} once both
##   sides agree — the server, not each client, decides the payout.
##   With no live server (or an old one) there is no settlement and the
##   client falls back to the local Stakes math as before.
## "table" is only the matchmaking BAND (from Stakes.band_for_stake) — the
## pot uses each player's own "stake", which the server exchanges in the
## matched message. Missing stake fields default to 0 (friendly match).

signal matched(opponent: Dictionary)
signal lobby_ready_received(data: Dictionary) # v11 lobby: a room-mate tapped READY
signal shot_received(data: Dictionary)
signal state_received(data: Dictionary)
signal opponent_left
signal queue_failed(message: String)
## F13 Phase 2 (v11): the server's authoritative payout for a finished
## online match — {type:"settlement", payout:int, pot:int,
## verified:true}. Main forwards it to MatchScreen, which credits the
## server's payout instead of its local computation. Never fires with
## no live server (offline / LAN / bot / tour / solo).
signal settlement_received(data: Dictionary)
signal connection_lost # L4: the server connection dropped. Main handles
	# it ONLY while searching; mid-match drops stay with MatchScreen's
	# opponent_left path (queue_failed must not fire there — it would
	# toast "search failed" over a live match).
signal connected_to_server
signal lan_host_found(host: Dictionary) # {name, ip, port}
signal lan_discovery_failed(message: String)

const DEFAULT_HOST := "127.0.0.1" # localhost for testing; set a real host in Settings
const DEFAULT_PORT := 8910
const LAN_BEACON_PORT := 8911 # UDP broadcast port for same-Wi-Fi discovery
const LAN_BEACON_INTERVAL := 1.0 # seconds between host beacons

## v11 transport switch (plan §5). LAN_HOST = same-Wi-Fi hosting (the
## _hosting flag — untouched). P2P = WebRTC mesh over the internet
## (default for ONLINE). LEGACY_ENET = the old ENet relay server path
## (kept for one version so a rollback is a one-line change: set
## transport = TRANSPORT_LEGACY_ENET, or call use_legacy_enet()).
## The switch only affects the INTERNET paths (queue / invite join);
## LAN host/join never consult it.
const TRANSPORT_LAN_HOST := 0
const TRANSPORT_P2P := 1
const TRANSPORT_LEGACY_ENET := 2
var transport := TRANSPORT_P2P
## P2P connection timeout (plan §1.4): 20 s from offer to CONNECTED.
const P2P_CONNECT_TIMEOUT := 20.0
## P2P search poll interval (plan §1.3): find_match every 2 s.
const P2P_POLL_INTERVAL := 2.0
## P2P invite wait (same as the old server room hold): 180 s.
const P2P_INVITE_TIMEOUT := 180.0

## True when the WebRTC classes loaded (webrtc-native plugin present).
## The startup guard: ONLINE degrades gracefully when false — Main
## falls back to the legacy path or shows "online is unavailable in
## this build", never a crash. Static + pure so tests can call it
## without an instance. Uses ClassDB (no direct class references) so
## this script still parses on a build where the classes are absent.
static func webrtc_available() -> bool:
	return ClassDB.class_exists("WebRTCPeerConnection") and ClassDB.class_exists("WebRTCMultiplayerPeer")

## Rollback helper: force the legacy ENet internet path for this run.
func use_legacy_enet() -> void:
	transport = TRANSPORT_LEGACY_ENET

## v11 breaker (plan §1.5, deterministic option): derived from the
## match id so both sides agree with no round-trip. Delegates to
## P2PSignalling (pure, unit-tested).
static func breaker_seat_for_match(match_id: String, player_count: int) -> int:
	return P2PSignalling.breaker_seat_for_match(match_id, player_count)

var _peer: ENetMultiplayerPeer = null
var _connected := false

## --- v11 P2P state ------------------------------------------------------
## WebRTC objects are held UNTYPED (Variant) on purpose: the classes
## only exist when the webrtc-native plugin loaded, and a typed var
## would fail to parse on a build without them. Every access is
## guarded by webrtc_available() / null checks.
var _mesh = null # WebRTCMultiplayerPeer (mesh) once a P2P match starts
var _p2p_conns := {} # peer_id (int) -> WebRTCPeerConnection
var _p2p_pending_ice := {} # peer_id -> Array of buffered ICE dicts
var _p2p_remote_desc_set := {} # peer_id -> bool (remote SDP applied)
var _p2p_connected_peers := {} # peer_id -> bool (mesh peer_connected)
var _p2p_all_connected := false
var _p2p_connect_elapsed := 0.0
var _p2p_searching := false # random queue search in progress (P2P)
var _p2p_search := {} # {name, level, table, stake, mode}
var _p2p_search_elapsed := 0.0
var _p2p_widened := false # ±4 window after 30 s (plan §1.3)
var _p2p_poll_accum := 0.0
var _p2p_poll_busy := false
var _p2p_invite_searching := false # invite match resolution in progress
var _p2p_invite := {} # {group_id, name, level, stake, mode, table, is_inviter}
var _p2p_invite_elapsed := 0.0
var _p2p_match_id := ""
var _p2p_players: Array = [] # seat-ordered [{id, name, level, stake, seat}]
var _p2p_my_seat := 0
var _p2p_my_id := ""
var _p2p_failed := false

## Peer ids of the other players in this P2P match (seat+1, plan §1.5).
func _p2p_opponent_peer_ids() -> Array:
	var ids: Array = []
	for p in _p2p_players:
		var seat := int(p.get("seat", 0))
		if seat != _p2p_my_seat:
			ids.append(seat + 1)
	return ids

## Seat of the player with this Supabase user id, or -1.
static func _seat_of(players: Array, user_id: String) -> int:
	for p in players:
		if String(p.get("id", "")) == user_id:
			return int(p.get("seat", -1))
	return -1


## The Supabase autoload, resolved dynamically (NOT by identifier):
## -s headless tests load this script without autoloads registered,
## so naming `Supabase` directly would fail compilation there (the
## same reason MatchScreen cannot load in -s mode). At runtime Net is
## an autoload, so /root/Supabase always exists; null only in tests.
func _sb() -> Node:
	if not is_inside_tree():
		return null
	var root := get_tree().root
	if root == null:
		return null
	return root.get_node_or_null("Supabase")

func is_p2p_connected() -> bool:
	return _p2p_all_connected

func is_p2p_searching() -> bool:
	return _p2p_searching or _p2p_invite_searching

## Seat of the player who last left a 4p match (-1 = unknown / 2p match).
## MatchScreen reads this on opponent_left to work out which team
## forfeited. Set from the server's opponent_left message (4p rooms
## include the leaver's seat); cleared on every new match.
var last_opponent_left_seat := -1

# --- LAN (same-Wi-Fi) hosting + discovery (v6) -------------------------
# No internet server exists yet (hosting needs an Oracle account + a
# card for verification — see docs/online-server.md), so two phones on
# the same Wi-Fi match directly: one phone HOSTS (runs the matchmaking
# server inside the game), the other JOINS by discovery or by IP.
# Same protocol as the internet server (queue/matched/shot/state/
# forfeit/opponent_left), so MatchScreen needs no changes.
# LAN matches are a direct challenge between two people, not random
# matchmaking — so there is no ±2 level gate and no stake band gate.
var _hosting := false
var _host_entry: Dictionary = {} # {name, level, table, stake}
var _host_partner := -1 # peer id of the joined opponent, -1 = none yet
var _beacon: PacketPeerUDP = null
var _beacon_timer := 0.0
var _discovery: PacketPeerUDP = null
var _discovering := false
var _found_hosts: Dictionary = {} # ip -> {name, ip, port}

func _process(delta: float) -> void:
	if _hosting and _beacon != null:
		_beacon_timer += delta
		if _beacon_timer >= LAN_BEACON_INTERVAL:
			_beacon_timer = 0.0
			_send_beacon()
	if _discovering and _discovery != null:
		_poll_discovery()
	if _p2p_searching:
		_p2p_search_elapsed += delta
		if _p2p_search_elapsed >= 30.0 and not _p2p_widened:
			_p2p_widened = true
		_p2p_poll_accum += delta
		if _p2p_poll_accum >= P2P_POLL_INTERVAL and not _p2p_poll_busy:
			_p2p_poll_accum = 0.0
			_p2p_poll_once()
	if _p2p_invite_searching:
		_p2p_invite_elapsed += delta
		if _p2p_invite_elapsed >= P2P_INVITE_TIMEOUT:
			_p2p_invite_searching = false
			_fail_p2p("Not everyone joined in time — ask your friend to send the invite again.")
			return
		_p2p_poll_accum += delta
		if _p2p_poll_accum >= P2P_POLL_INTERVAL and not _p2p_poll_busy:
			_p2p_poll_accum = 0.0
			_p2p_invite_poll_once()
	if _mesh != null and not _p2p_all_connected and not _p2p_failed:
		_p2p_poll_connections(delta)

func is_hosting() -> bool:
	return _hosting

func is_discovering() -> bool:
	return _discovering

## Start hosting a LAN match: this phone becomes the server (ENet,
## port 8910) and beacons on the Wi-Fi so the other phone can find it.
func start_host(player_name: String, level: int, table: int, stake: int) -> void:
	stop_all_net()
	_peer = ENetMultiplayerPeer.new()
	var err := _peer.create_server(DEFAULT_PORT, 2)
	if err != OK:
		_peer = null
		queue_failed.emit("Could not start Wi-Fi hosting on port %d (%s). Another app may be using it." % [DEFAULT_PORT, error_string(err)])
		return
	multiplayer.multiplayer_peer = _peer
	if not multiplayer.peer_connected.is_connected(_on_host_peer_connected):
		multiplayer.peer_connected.connect(_on_host_peer_connected)
	if not multiplayer.peer_disconnected.is_connected(_on_host_peer_disconnected):
		multiplayer.peer_disconnected.connect(_on_host_peer_disconnected)
	_hosting = true
	_host_partner = -1
	_host_entry = {"name": player_name, "level": level, "table": table, "stake": maxi(0, stake)}
	_beacon = PacketPeerUDP.new()
	_beacon.set_broadcast_enabled(true)
	_beacon.set_dest_address("255.255.255.255", LAN_BEACON_PORT)
	_beacon_timer = 0.0
	print("[Net] Hosting LAN match on port %d as %s (Lv %d, stake %d)" % [DEFAULT_PORT, player_name, level, stake])

func stop_host() -> void:
	if not _hosting:
		return
	_beacon = null
	_hosting = false
	_host_partner = -1
	_host_entry = {}
	if _peer:
		_peer.close()
		_peer = null
	multiplayer.multiplayer_peer = null

## Listen for LAN host beacons on the Wi-Fi. Found hosts arrive via
## lan_host_found (once per host; re-beacons refresh the entry).
func start_discovery() -> void:
	stop_discovery()
	_discovery = PacketPeerUDP.new()
	var err := _discovery.bind(LAN_BEACON_PORT)
	if err != OK:
		_discovery = null
		lan_discovery_failed.emit("Could not listen for nearby players (%s)." % error_string(err))
		return
	_discovering = true
	_found_hosts.clear()
	print("[Net] Listening for LAN hosts on port %d…" % LAN_BEACON_PORT)

func stop_discovery() -> void:
	if _discovery != null:
		_discovery.close()
		_discovery = null
	_discovering = false

func _send_beacon() -> void:
	if _beacon == null:
		return
	# put_packet returns an error code; UDP send can be blocked in
	# sandboxes — the beacon is best-effort, never fatal.
	_beacon.put_packet(lan_beacon_payload(String(_host_entry.get("name", "Player"))).to_utf8_buffer())

func _poll_discovery() -> void:
	while _discovery.get_available_packet_count() > 0:
		var pkt := _discovery.get_packet()
		var ip := _discovery.get_packet_ip()
		var host := lan_parse_beacon(pkt, ip)
		if host.is_empty():
			continue
		if _is_own_ip(ip):
			continue
		var known: Dictionary = _found_hosts.get(ip, {})
		_found_hosts[ip] = host
		if String(known.get("name", "")) != String(host["name"]):
			lan_host_found.emit(host)

func _is_own_ip(ip: String) -> bool:
	return ip in IP.get_local_addresses()

## Private LAN addresses of this device (for the host screen + manual
## IP entry). Loopback and public addresses are never listed.
static func lan_local_ips() -> Array:
	var out: Array = []
	for a in IP.get_local_addresses():
		if a == "127.0.0.1" or "::" in a:
			continue
		var parts := String(a).split(".")
		if parts.size() != 4:
			continue
		var o1 := int(parts[0])
		var o2 := int(parts[1])
		if String(a).begins_with("192.168.") or String(a).begins_with("10."):
			out.append(a)
		elif o1 == 172 and o2 >= 16 and o2 <= 31:
			out.append(a)
	return out

## Beacon payload (pure, unit-tested): the host advertises its name.
static func lan_beacon_payload(host_name: String) -> String:
	return JSON.stringify({"type": "carrom-host", "name": host_name, "port": DEFAULT_PORT})

## Parse one discovery packet. Returns {} for anything that is not a
## well-formed carrom-host beacon (wrong type, bad JSON, no name/ip).
static func lan_parse_beacon(pkt: PackedByteArray, sender_ip: String) -> Dictionary:
	if sender_ip == "":
		return {}
	var data: Dictionary = JSON.parse_string(pkt.get_string_from_utf8())
	if data.is_empty() or String(data.get("type", "")) != "carrom-host":
		return {}
	var host_name := String(data.get("name", "")).strip_edges()
	if host_name == "":
		return {}
	return {"name": host_name, "ip": sender_ip, "port": int(data.get("port", DEFAULT_PORT))}

func _on_host_peer_connected(id: int) -> void:
	print("[Net] LAN peer connected: %d (match starts on their queue message)" % id)

func _on_host_peer_disconnected(id: int) -> void:
	print("[Net] LAN peer disconnected: %d" % id)
	if id == _host_partner:
		_host_partner = -1
		opponent_left.emit()

## Host-side relay: this phone IS the server. Only the matched partner's
## shot/state/forfeit messages reach the local game; a queue message
## from anyone starts a match (LAN is a direct challenge — no level or
## band gate). Split into two pure-ish handlers so tests can drive them
## without real sockets.
func _relay_as_host(data: Dictionary) -> void:
	var sender := multiplayer.get_remote_sender_id()
	var mtype := String(data.get("type", ""))
	if _host_partner > 0:
		if sender == _host_partner:
			_handle_host_message(sender, data)
		return
	if mtype == "queue":
		_handle_host_queue(sender, data)

func _handle_host_queue(sender: int, data: Dictionary) -> void:
	if _host_partner > 0:
		return # already matched — one opponent per host
	var opp := {"name": String(data.get("name", "Player")), "level": int(data.get("level", 1)),
		"stake": maxi(0, int(data.get("stake", 0)))}
	_host_partner = sender
	_beacon = null # stop advertising: this host is busy now
	var you_break := randi() % 2 == 0
	var to_joiner := {"type": "matched", "opponent": String(_host_entry.get("name", "Player")),
		"opp_level": int(_host_entry.get("level", 1)), "you_break": not you_break,
		"opp_stake": int(_host_entry.get("stake", 0))}
	rpc_id(sender, "_relay", JSON.stringify(to_joiner))
	var to_host := {"type": "matched", "opponent": String(opp["name"]),
		"opp_level": int(opp["level"]), "you_break": you_break,
		"opp_stake": int(opp["stake"])}
	matched.emit(to_host)
	print("[Net] LAN match: %s vs %s — %s breaks" % [_host_entry.get("name"), opp["name"],
		_host_entry.get("name") if you_break else opp["name"]])

func _handle_host_message(sender: int, data: Dictionary) -> void:
	if sender != _host_partner:
		return
	match String(data.get("type", "")):
		"shot":
			shot_received.emit(data)
		"state":
			state_received.emit(data)
		"lobby_ready":
			lobby_ready_received.emit(data)
		"lobby_leave":
			_host_partner = -1
			opponent_left.emit()
		"forfeit":
			_host_partner = -1
			opponent_left.emit()

func is_connected_to_server() -> bool:
	return _connected

func connect_to_server(host: String, port: int) -> void:
	if _peer:
		disconnect_client()
	_peer = ENetMultiplayerPeer.new()
	var err := _peer.create_client(host, port)
	if err != OK:
		queue_failed.emit("Could not start network client (%s)" % error_string(err))
		return
	multiplayer.multiplayer_peer = _peer
	if not multiplayer.connected_to_server.is_connected(_on_connected):
		multiplayer.connected_to_server.connect(_on_connected)
	if not multiplayer.connection_failed.is_connected(_on_connection_failed):
		multiplayer.connection_failed.connect(_on_connection_failed)
	if not multiplayer.server_disconnected.is_connected(_on_server_disconnected):
		multiplayer.server_disconnected.connect(_on_server_disconnected)

func _on_connected() -> void:
	_connected = true
	print("[Net] Connected to server.")
	connected_to_server.emit()

func _on_connection_failed() -> void:
	queue_failed.emit("Could not reach the matchmaking server. Check your connection and the server address in Settings.")

func _on_server_disconnected() -> void:
	_connected = false
	opponent_left.emit()
	# L4: also tell Main — during a search nobody handles
	# opponent_left (no match exists yet), so without this the
	# FINDING OPPONENT popup would spin forever.
	connection_lost.emit()

# ------------------------------------------------------------ v11 P2P (plan §1)
# Random matchmaking + invites over Supabase (queue/matches rows +
# find_match / create_match_from_invites RPCs), signalling over the
# Realtime Broadcast channel on the ONE existing socket, gameplay
# over a WebRTCMultiplayerPeer mesh. The sandbox cannot prove the
# data channel (UDP blocked) — this is implemented + unit-tested
# headless; live proof is T1/T2 on two real phones (docs/p2p-online.md).
#
# Flow: start_p2p_search / start_p2p_invite -> (poll every 2 s) ->
# _begin_p2p_match(match_id, players) -> mesh + offers -> all peers
# CONNECTED -> matched.emit(payload) -> Main opens the lobby as usual.
# Any failure before the match starts -> queue_failed (Main closes the
# search popup); a disconnect mid-match -> opponent_left (MatchScreen).
#
# API note (Phase 0 spike — the ONLY correct 4.3 flow):
# WebRTCPeerConnection has only 3 signals (session_description_created,
# ice_candidate_created, data_channel_received); there is NO
# create_answer() — the answer is auto-created inside
# set_remote_description("offer", ...); poll get_connection_state()
# in _process. WebRTCDataChannel has no data_received signal — the
# mesh peer drives polling internally once it is the multiplayer peer.

## Random P2P search: queue + find_match polling. Requires a signed-in
## Supabase session (the queue row id IS the Auth user id). Main calls
## this from _start_matchmaking when transport == P2P and WebRTC loaded.
func start_p2p_search(player_name: String, level: int, table: int, stake: int = 0, mode: String = "2p") -> void:
	if _hosting:
		return
	if not webrtc_available():
		queue_failed.emit("Online play is unavailable in this build — the WebRTC plugin did not load. Solo and NEARBY still work.")
		return
	var sb := _sb()
	if sb == null or not sb.configured or sb.user_id == "":
		queue_failed.emit("Sign in to play online — random matches need your account.")
		return
	_p2p_my_id = sb.user_id
	_p2p_search = {"name": player_name, "level": level, "table": table, "stake": stake, "mode": mode}
	_p2p_search_elapsed = 0.0
	_p2p_widened = false
	_p2p_poll_accum = 0.0
	_p2p_poll_busy = false
	_p2p_searching = true
	# Queue insert is async — the poll loop below starts regardless;
	# find_match errors ("not in the queue") until the row lands, and
	# the first successful poll pairs us. A failed insert surfaces on
	# the next poll as a queue error instead of hanging silently.
	_queue_insert_async(player_name, level, table, stake, mode)

func _queue_insert_async(player_name: String, level: int, table: int, stake: int, mode: String) -> void:
	var row := {"id": _p2p_my_id, "display_name": player_name,
		"level": level, "table": table, "stake": maxi(0, stake), "mode": mode}
	var sb2 := _sb()
	if sb2 == null:
		return
	var res = await sb2.queue_insert(row)
	if not _p2p_searching:
		return # cancelled while the insert was in flight
	if not bool(res.get("ok", false)):
		_p2p_searching = false
		queue_failed.emit("Could not join the matchmaking queue (%s)." % String(res.get("error", "connection failed")))

## One poll tick of the random search: find_match, then (as the other
## side of a pairing) poll for a matches row containing me.
func _p2p_poll_once() -> void:
	if not _p2p_searching or _p2p_poll_busy:
		return
	_p2p_poll_busy = true
	var sb3 := _sb()
	if sb3 == null:
		_p2p_poll_busy = false
		return
	var res = await sb3.call_find_match(String(_p2p_search.get("mode", "2p")), _p2p_widened)
	_p2p_poll_busy = false
	if not _p2p_searching:
		return
	if bool(res.get("ok", false)):
		var data: Dictionary = res.get("data", {})
		if bool(data.get("matched", false)):
			_p2p_searching = false
			_begin_p2p_match(String(data.get("match_id", "")), data.get("players", []))
			return
	# Not paired by my own call — maybe the OTHER side paired us.
	var row = await sb3.poll_match_for_me(_p2p_my_id)
	if not _p2p_searching:
		return
	if not row.is_empty():
		_p2p_searching = false
		_begin_p2p_match(String(row.get("id", "")), row.get("players", []))

## Cancel a P2P search (Main CANCEL): delete the queue row (best-effort)
## so a cancelled search is never matched, then tear the P2P state down.
func cancel_p2p_search() -> void:
	_p2p_searching = false
	_p2p_invite_searching = false
	if _p2p_my_id != "":
		var sb4 := _sb()
		if sb4 != null:
			sb4.queue_delete(_p2p_my_id)
	_clear_p2p()

## P2P invite resolution: both sides call create_match_from_invites
## (idempotent — whoever gets the row first wins) and the invitee also
## polls matches by group_id. Main calls this from _join_invite_room
## when transport == P2P and WebRTC loaded.
func start_p2p_invite(group_id: String, player_name: String, level: int, stake: int = 0, mode: String = "2p", table: int = 0, is_inviter: bool = false) -> void:
	if _hosting:
		queue_failed.emit("Invite matches need the internet — use NEARBY to play together on the same Wi-Fi.")
		return
	if not webrtc_available():
		queue_failed.emit("Online play is unavailable in this build — the WebRTC plugin did not load. Solo and NEARBY still work.")
		return
	var sb5 := _sb()
	if sb5 == null or not sb5.configured or sb5.user_id == "":
		queue_failed.emit("Sign in to play online — invites need your account.")
		return
	_p2p_my_id = sb5.user_id
	_p2p_invite = {"group_id": group_id, "name": player_name, "level": level,
		"stake": stake, "mode": mode, "table": table, "is_inviter": is_inviter}
	_p2p_invite_elapsed = 0.0
	_p2p_poll_accum = 0.0
	_p2p_poll_busy = false
	_p2p_invite_searching = true

func _p2p_invite_poll_once() -> void:
	if not _p2p_invite_searching or _p2p_poll_busy:
		return
	_p2p_poll_busy = true
	var sb6 := _sb()
	if sb6 == null:
		_p2p_poll_busy = false
		return
	var res = await sb6.call_create_match_from_invites(String(_p2p_invite.get("group_id", "")))
	_p2p_poll_busy = false
	if not _p2p_invite_searching:
		return
	if bool(res.get("ok", false)):
		var data: Dictionary = res.get("data", {})
		if bool(data.get("ok", false)):
			_p2p_invite_searching = false
			_begin_p2p_match(String(data.get("match_id", "")), data.get("players", []))
			return
	var row = await sb6.poll_match_by_group(String(_p2p_invite.get("group_id", "")))
	if not _p2p_invite_searching:
		return
	if not row.is_empty():
		_p2p_invite_searching = false
		_begin_p2p_match(String(row.get("id", "")), row.get("players", []))

## Build the `matched` payload Main (and the lobby) consume, from the
## matches row's players array. 2p: opponent fields + you_break from
## the deterministic breaker; 4p: the full roster + seats. Pure —
## unit-tested (same shape the ENet server used to send).
static func p2p_matched_payload(players: Array, my_seat: int, match_id: String) -> Dictionary:
	var player_count := players.size()
	var breaker := P2PSignalling.breaker_seat_for_match(match_id, maxi(2, player_count))
	if player_count >= 4:
		return {"mode": "4p", "players": players, "your_seat": my_seat,
			"breaker_seat": breaker, "match_id": match_id}
	var opp := {}
	for p in players:
		if int(p.get("seat", 0)) != my_seat:
			opp = p
	return {"mode": "2p",
		"opponent": String(opp.get("name", "Player")),
		"opp_level": int(opp.get("level", 1)),
		"you_break": breaker == my_seat,
		"opp_stake": int(opp.get("stake", 0)),
		"match_id": match_id, "players": players}

## Start the mesh for a formed match: join the Broadcast channel,
## create the mesh (own id = seat+1), offer to every higher seat.
func _begin_p2p_match(match_id: String, players: Array) -> void:
	if match_id == "" or players.is_empty():
		_fail_p2p("The match could not start — no match was formed. Try searching again.")
		return
	if not webrtc_available():
		_fail_p2p("Online play is unavailable in this build — the WebRTC plugin did not load.")
		return
	_p2p_my_seat = _seat_of(players, _p2p_my_id)
	if _p2p_my_seat < 0:
		_fail_p2p("The match could not start — you are not in it. Try searching again.")
		return
	_p2p_match_id = match_id
	_p2p_players = players.duplicate(true)
	_p2p_connect_elapsed = 0.0
	_p2p_failed = false
	_p2p_all_connected = false
	# Signalling: listen for offers/answers/ICE on the match channel.
	var sb7 := _sb()
	if sb7 != null:
		if not sb7.broadcast_received.is_connected(_on_p2p_signal):
			sb7.broadcast_received.connect(_on_p2p_signal)
		sb7.join_match_channel(match_id)
	_mesh = ClassDB.instantiate("WebRTCMultiplayerPeer")
	if _mesh == null:
		_fail_p2p("Online play is unavailable in this build — the WebRTC plugin did not load.")
		return
	var err: int = _mesh.create_mesh(_p2p_my_seat + 1)
	if err != OK:
		_mesh = null
		_fail_p2p("Could not start the online connection (%s)." % error_string(err))
		return
	_mesh.peer_connected.connect(_on_p2p_peer_connected)
	_mesh.peer_disconnected.connect(_on_p2p_peer_disconnected)
	multiplayer.multiplayer_peer = _mesh
	for p in _p2p_players:
		var seat := int(p.get("seat", 0))
		if seat == _p2p_my_seat:
			continue
		if P2PSignalling.should_offer(_p2p_my_seat, seat):
			var conn = _p2p_create_conn(seat + 1)
			if conn == null:
				_fail_p2p("Could not start the online connection.")
				return
			# The offer goes out via session_description_created; the
			# mesh peer needs the connection registered first.
			_mesh.add_peer(conn, seat + 1)
			var oerr: int = conn.create_offer()
			if oerr != OK:
				_fail_p2p("Could not start the online connection (%s)." % error_string(oerr))
				return
	print("[Net] P2P match %s — seat %d of %d, offering to higher seats" % [match_id, _p2p_my_seat, _p2p_players.size()])

## Create one WebRTCPeerConnection for a remote peer (untyped — see
## the state comment above) and wire its 3 signals. Returns null when
## the class is unavailable.
func _p2p_create_conn(peer_id: int):
	var conn = ClassDB.instantiate("WebRTCPeerConnection")
	if conn == null:
		return null
	var sb8 := _sb()
	var servers: Array = sb8.ice_servers() if sb8 != null else P2PSignalling.DEFAULT_ICE_SERVERS
	conn.initialize(P2PSignalling.ice_config(servers))
	conn.session_description_created.connect(_on_p2p_session_created.bind(peer_id))
	conn.ice_candidate_created.connect(_on_p2p_ice_created.bind(peer_id))
	_p2p_conns[peer_id] = conn
	_p2p_pending_ice[peer_id] = []
	_p2p_remote_desc_set[peer_id] = false
	return conn

func _p2p_get_or_create_conn(peer_id: int):
	if _p2p_conns.has(peer_id):
		return _p2p_conns[peer_id]
	var conn = _p2p_create_conn(peer_id)
	if conn != null:
		_mesh.add_peer(conn, peer_id)
	return conn

## session_description_created(type, sdp) — bound peer_id last.
## Offer (we offered) or answer (auto-created when we set a remote
## offer — there is NO create_answer() in 4.3). Send it to the peer.
func _on_p2p_session_created(type: String, sdp: String, peer_id: int) -> void:
	if _p2p_failed:
		return
	var from_id := _p2p_my_id
	var sb9 := _sb()
	if sb9 == null:
		return
	if type == "offer":
		sb9.send_broadcast(P2PSignalling.offer_message(from_id, sdp))
	elif type == "answer":
		sb9.send_broadcast(P2PSignalling.answer_message(from_id, sdp))

## ice_candidate_created(mid, index, sdp) — bound peer_id last.
func _on_p2p_ice_created(mid: String, index: int, sdp: String, peer_id: int) -> void:
	if _p2p_failed:
		return
	var sb10 := _sb()
	if sb10 != null:
		sb10.send_broadcast(P2PSignalling.ice_message(_p2p_my_id, mid, index, sdp))

## One signalling message from a peer (already validated by Supabase).
func _on_p2p_signal(msg: Dictionary) -> void:
	if _p2p_match_id == "" or _p2p_failed:
		return
	var from_id := String(msg.get("from", ""))
	var seat := _seat_of(_p2p_players, from_id)
	if seat < 0 or seat == _p2p_my_seat:
		return
	var peer_id := seat + 1
	match String(msg.get("type", "")):
		"offer":
			# Lower seat offers; we are the higher seat. The answer
			# is auto-created inside set_remote_description.
			var conn = _p2p_get_or_create_conn(peer_id)
			if conn == null:
				return
			conn.set_remote_description("offer", String(msg.get("sdp", "")))
			_p2p_remote_desc_set[peer_id] = true
			_p2p_flush_ice(peer_id)
		"answer":
			var conn2 = _p2p_conns.get(peer_id)
			if conn2 == null:
				return
			conn2.set_remote_description("answer", String(msg.get("sdp", "")))
			_p2p_remote_desc_set[peer_id] = true
			_p2p_flush_ice(peer_id)
		"ice":
			var ice := {"mid": String(msg.get("mid", "")), "index": int(msg.get("index", 0)), "sdp": String(msg.get("sdp", ""))}
			if bool(_p2p_remote_desc_set.get(peer_id, false)):
				var conn3 = _p2p_conns.get(peer_id)
				if conn3 != null:
					conn3.add_ice_candidate(String(ice["mid"]), int(ice["index"]), String(ice["sdp"]))
			else:
				# ICE can arrive before the remote description — buffer
				# it (plan §1.4) and apply after set_remote_description.
				(_p2p_pending_ice.get(peer_id, []) as Array).append(ice)
		"bye":
			if _p2p_all_connected:
				opponent_left.emit()
			else:
				_fail_p2p("The other player left before connecting.")

## Apply buffered ICE candidates for a peer (after its remote
## description is set).
func _p2p_flush_ice(peer_id: int) -> void:
	var conn = _p2p_conns.get(peer_id)
	if conn == null:
		return
	for ice in _p2p_pending_ice.get(peer_id, []):
		conn.add_ice_candidate(String(ice.get("mid", "")), int(ice.get("index", 0)), String(ice.get("sdp", "")))
	_p2p_pending_ice[peer_id] = []

func _on_p2p_peer_connected(peer_id: int) -> void:
	print("[Net] P2P peer connected: %d" % peer_id)
	_p2p_connected_peers[peer_id] = true
	_p2p_maybe_connected()

func _on_p2p_peer_disconnected(peer_id: int) -> void:
	print("[Net] P2P peer disconnected: %d" % peer_id)
	_p2p_connected_peers.erase(peer_id)
	if _p2p_all_connected:
		# Mid-match: the other side left — MatchScreen forfeits them.
		opponent_left.emit()
	elif _mesh != null and not _p2p_failed:
		_fail_p2p("The other player disconnected before the match started.")

## All expected peers connected? Either the mesh says so, or every
## raw connection reports CONNECTED (backup — the sandbox never gets
## here, UDP blocked, so this is phone-proven only: T1/T2).
func _p2p_maybe_connected() -> void:
	if _p2p_all_connected or _p2p_failed or _mesh == null:
		return
	var expected := _p2p_opponent_peer_ids()
	var via_mesh := true
	for pid in expected:
		if not bool(_p2p_connected_peers.get(pid, false)):
			via_mesh = false
	var via_states := true
	for pid in expected:
		var conn = _p2p_conns.get(pid)
		# Only the connections WE created have a state to poll; a
		# peer that only answered has its connection too (created on
		# offer receipt), so this covers both directions.
		if conn == null or int(conn.get_connection_state()) != 2: # 2 = CONNECTED
			via_states = false
	if via_mesh or via_states:
		_p2p_all_connected = true
		print("[Net] P2P connected — all %d peers" % expected.size())
		matched.emit(p2p_matched_payload(_p2p_players, _p2p_my_seat, _p2p_match_id))

## Per-frame P2P connection watch: timeout + failure states. Polls
## get_connection_state() (there is no connection_state_changed
## signal in 4.3 — spike §12).
func _p2p_poll_connections(delta: float) -> void:
	_p2p_connect_elapsed += delta
	for pid in _p2p_conns.keys():
		var conn = _p2p_conns[pid]
		if conn == null:
			continue
		var st := int(conn.get_connection_state())
		if st == 4 or st == 5: # FAILED / CLOSED
			_fail_p2p("Could not connect to the other player — they may be behind a strict network. Try again, or play NEARBY on the same Wi-Fi.")
			return
	_p2p_maybe_connected()
	if not _p2p_all_connected and _p2p_connect_elapsed >= P2P_CONNECT_TIMEOUT:
		_fail_p2p("Could not connect to the other player in 20 seconds — try again, or play NEARBY on the same Wi-Fi.")

## Fail a P2P connection/search: tell the peer (best-effort bye),
## tear down, and surface ONE clear error through queue_failed
## (Main closes the search popup / lobby and toasts it). Never fires
## twice for one match.
func _fail_p2p(message: String) -> void:
	if _p2p_failed:
		return
	_p2p_failed = true
	_p2p_searching = false
	_p2p_invite_searching = false
	if _p2p_match_id != "" and _p2p_my_id != "":
		var sb11 := _sb()
		if sb11 != null:
			sb11.send_broadcast(P2PSignalling.bye_message(_p2p_my_id))
			sb11.expire_match(_p2p_match_id)
	_clear_p2p()
	queue_failed.emit(message)

## Tear down every P2P object (mesh, connections, channel, flags).
## Does NOT emit anything — the caller decides the user-facing error.
func _clear_p2p() -> void:
	var old_mesh = _mesh
	if old_mesh != null:
		if old_mesh.peer_connected.is_connected(_on_p2p_peer_connected):
			old_mesh.peer_connected.disconnect(_on_p2p_peer_connected)
		if old_mesh.peer_disconnected.is_connected(_on_p2p_peer_disconnected):
			old_mesh.peer_disconnected.disconnect(_on_p2p_peer_disconnected)
		old_mesh.close()
		_mesh = null
		if multiplayer.multiplayer_peer == old_mesh:
			multiplayer.multiplayer_peer = null
	for pid in _p2p_conns.keys():
		var conn = _p2p_conns[pid]
		if conn != null:
			conn.close()
	_p2p_conns.clear()
	_p2p_pending_ice.clear()
	_p2p_remote_desc_set.clear()
	_p2p_connected_peers.clear()
	_p2p_all_connected = false
	_p2p_connect_elapsed = 0.0
	_p2p_match_id = ""
	_p2p_players = []
	var sb12 := _sb()
	if sb12 != null:
		sb12.leave_match_channel()

func queue_up(player_name: String, level: int, table: int, stake: int = 0, mode: String = "2p", account_id: String = "", access_token: String = "") -> void:
	if _hosting:
		return # the host never queues — its entry is set by start_host
	if not _connected:
		queue_failed.emit("Not connected to the server yet.")
		return
	_send(queue_message(player_name, level, table, stake, mode, account_id, access_token))

## The queue message (pure, unit-tested). F13 Phase 2: the Supabase
## account_id + access token ride along ONLY when the player is signed
## in (both non-empty); otherwise they are omitted entirely — a
## verifying server then refuses the queue, an old / unverifying
## server plays exactly as before. The token is never logged.
static func queue_message(player_name: String, level: int, table: int, stake: int = 0, mode: String = "2p", account_id: String = "", access_token: String = "") -> Dictionary:
	var msg := {"type": "queue", "name": player_name, "level": level, "table": table, "stake": stake, "mode": mode}
	if account_id != "" and access_token != "":
		msg["account_id"] = account_id
		msg["access_token"] = access_token
	return msg

## v11 random matchmaking — the ONE clear entry point for the Play
## screen's "random" button (the UI worker calls Main.start_random_match,
## which ends up here): join the server queue to be paired with a
## random online player of a similar level (±2, ±4 after 30 s) on the
## same stake band. Same as queue_up — the alias exists so the
## random-match intent reads as such at the call site.
func queue_random(player_name: String, level: int, table: int, stake: int = 0, mode: String = "2p", account_id: String = "", access_token: String = "") -> void:
	queue_up(player_name, level, table, stake, mode, account_id, access_token)

## Leave the matchmaking queue without dropping the connection, so
## the player can re-queue immediately (the server removes the entry;
## cancelling via disconnect_client also works and is what Main's
## search CANCEL does today).
func leave_queue() -> void:
	if _hosting or not _connected:
		return
	_send({"type": "leave_queue"})

## v11 lobby: tell the room this player is READY to start the match.
## Relayed by the server to every other player in the room.
func send_lobby_ready(seat: int) -> void:
	_send(OnlineLobby.ready_message(seat))

## v11 lobby: leave before the match starts. The server dissolves
## the room and the rest get `opponent_left`.
func send_lobby_leave() -> void:
	_send({"type": "lobby_leave"})

## Join an invite room (v7): after accepting a friend invite (or when
## the group is ready, for the inviter), both sides send this to the
## game server with the same group_id. The server starts the match when
## every expected player has joined. The inviter is seat 0; invitees
## take seats 1.. in join order. Requires a connection to the internet
## game server (not LAN hosting) — invite matches do not run over
## NEARBY; NEARBY is the direct challenge instead.
func join_invite_room(group_id: String, player_name: String, level: int, stake: int = 0, mode: String = "2p", table: int = 0, is_inviter: bool = false, account_id: String = "", access_token: String = "") -> void:
	if _hosting:
		queue_failed.emit("Invite matches need the game server — use NEARBY to play together on the same Wi-Fi.")
		return
	if not _connected:
		queue_failed.emit("Not connected to the game server yet — the server is not online. Play NEARBY together for now.")
		return
	_send(invite_join_message(group_id, player_name, level, stake, mode, table, is_inviter, account_id, access_token))

## The invite_join message (pure, unit-tested). F13 Phase 2: same
## account_id + access_token rule as queue_message — sent only when
## the player is signed in, never logged.
static func invite_join_message(group_id: String, player_name: String, level: int, stake: int, mode: String, table: int, is_inviter: bool, account_id: String = "", access_token: String = "") -> Dictionary:
	var msg := {"type": "invite_join", "group_id": group_id, "name": player_name,
		"level": level, "stake": maxi(0, stake), "mode": mode, "table": table,
		"is_inviter": is_inviter}
	if account_id != "" and access_token != "":
		msg["account_id"] = account_id
		msg["access_token"] = access_token
	return msg

func send_shot(data: Dictionary) -> void:
	data["type"] = "shot"
	_send(data)

func send_state(data: Dictionary) -> void:
	data["type"] = "state"
	_send(data)

func send_forfeit() -> void:
	_send({"type": "forfeit"})

## F13 Phase 2 (v11): report this match's outcome to the server at
## match end ("win" / "loss" / "draw"). The server settles only when
## both sides' reports agree; an invalid outcome sends nothing.
## No-op offline / in LAN host mode the host never sees it (LAN has
## no settlement — local Stakes math applies, as before).
func send_result(outcome: String) -> void:
	var msg := Settlement.result_message(outcome)
	if msg.is_empty():
		return
	_send(msg)

func _send(data: Dictionary) -> void:
	if _peer == null and _mesh == null:
		return
	if _hosting:
		# Host mode: this phone IS the server — send straight to the
		# matched partner (never rpc_id(1), which would target itself).
		if _host_partner > 0:
			rpc_id(_host_partner, "_relay", JSON.stringify(data))
		return
	if _mesh != null:
		# v11 P2P: no server — address the peer(s) directly. 2p: the
		# one opponent (seat+1). 4p: every other peer in the mesh.
		# The _relay RPC is transport-agnostic, so nothing else changes.
		for pid in _p2p_opponent_peer_ids():
			rpc_id(pid, "_relay", JSON.stringify(data))
		return
	if _peer.get_connection_status() != ENetMultiplayerPeer.CONNECTION_CONNECTED:
		return
	# Server is peer id 1. The server relays to the opponent by calling
	# _relay on the opponent's /root/Net node.
	rpc_id(1, "_relay", JSON.stringify(data))

@rpc("any_peer", "reliable")
func _relay(payload: String) -> void:
	# Runs on the receiving client when the server relays a message.
	var data: Dictionary = JSON.parse_string(payload)
	if data.is_empty():
		return
	if _hosting:
		_relay_as_host(data)
		return
	match String(data.get("type", "")):
		"matched":
			matched.emit(data)
		"lobby_ready":
			lobby_ready_received.emit(data)
		"shot":
			shot_received.emit(data)
		"state":
			state_received.emit(data)
		"opponent_left":
			last_opponent_left_seat = int(data.get("seat", -1))
			opponent_left.emit()
		"settlement":
			# F13 Phase 2: the server's authoritative payout. Main
			# forwards it to the match screen; a settlement for a
			# match that already ended is ignored there.
			settlement_received.emit(data)
		"invite_failed":
			queue_failed.emit(String(data.get("error", "The invite match could not start.")))
		"error":
			queue_failed.emit(String(data.get("message", "Server error")))

## Tears down EVERYTHING: client peer, host server, beacon, discovery.
## Called by disconnect_client() and by start_host()/connect_to_server()
## before they take over the peer.
func stop_all_net() -> void:
	stop_discovery()
	_beacon = null
	_hosting = false
	_host_partner = -1
	_host_entry = {}
	# v11 P2P: a disconnect also ends any P2P search/match (mesh,
	# connections, Broadcast channel). The queue row is deleted by
	# cancel_p2p_search() (Main CANCEL); stop_all_net only clears the
	# local objects so start_host/connect_to_server can take over.
	_p2p_searching = false
	_p2p_invite_searching = false
	_p2p_failed = false
	_clear_p2p()
	if _peer:
		_peer.close()
		_peer = null
	multiplayer.multiplayer_peer = null
	_connected = false

func disconnect_client() -> void:
	stop_all_net()
