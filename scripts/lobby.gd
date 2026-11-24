class_name OnlineLobby
extends RefCounted

## Online match lobby (v11): the waiting room between "matched" and
## the first shot. The server has already paired the players (random
## queue or invite room) and sent the `matched` payload; the lobby
## shows the roster, each player taps READY, and the match starts
## when everybody is ready — or after LOBBY_AUTO_START_SECONDS, when
## silent players are treated as ready so a lobby can never stall
## forever (Main drives that countdown).
##
## States: "waiting" -> "ready" (everyone ready) -> "starting".
## "cancelled" when a player leaves before the start (the server
## dissolves the room and the rest get `opponent_left`).
##
## Transport is the EXISTING ENet relay, not WebRTC: a ready tap
## sends {"type": "lobby_ready", "seat": n} through NetClient
## (send_lobby_ready), the server relays it to the room exactly like
## a shot/state message, and the other clients mark that seat ready.
## No Supabase signalling is needed — the room already exists by the
## time the lobby opens. Pure state machine, no UI, no Save access —
## unit-tested in tests/matchmaking_test.gd. Main builds the popup
## UI on top of this and owns the countdown.

const LOBBY_AUTO_START_SECONDS := 30.0

const STATE_WAITING := "waiting"
const STATE_READY := "ready"
const STATE_STARTING := "starting"
const STATE_CANCELLED := "cancelled"

var mode := "2p" # "2p" | "4p"
var expected := 2 # players needed to start (2 or 4)
var your_seat := 0
var breaker_seat := 0
## Seat-ordered roster: [{name, level, stake, seat, is_local, ready}].
var players: Array = []
var state := STATE_WAITING

## Build a lobby from a server `matched` payload plus the local
## player's identity. 2p payload: {opponent, opp_level, you_break,
## opp_stake}. 4p payload: {players: [{name, level, stake, seat}…],
## your_seat, breaker_seat}. The local seat in 2p is 0 when we break,
## else 1 (same seat rule Main passes into MatchScreen.setup).
static func from_matched(data: Dictionary, local_name: String, local_level: int, local_stake: int) -> OnlineLobby:
	var lobby := OnlineLobby.new()
	if String(data.get("mode", "2p")) == "4p" and data.has("players"):
		lobby.mode = "4p"
		lobby.expected = 4
		lobby.your_seat = int(data.get("your_seat", 0))
		lobby.breaker_seat = int(data.get("breaker_seat", 0))
		for p in (data["players"] as Array):
			var seat := int(p.get("seat", lobby.players.size()))
			lobby.players.append({
				"name": String(p.get("name", "Player")),
				"level": int(p.get("level", 1)),
				"stake": maxi(0, int(p.get("stake", 0))),
				"seat": seat,
				"is_local": seat == lobby.your_seat,
				"ready": false,
			})
	else:
		lobby.mode = "2p"
		lobby.expected = 2
		var you_break := bool(data.get("you_break", true))
		lobby.your_seat = 0 if you_break else 1
		lobby.breaker_seat = lobby.your_seat
		var opp_seat := 1 - lobby.your_seat
		lobby.players = [
			{"name": "", "level": 0, "stake": 0, "seat": 0, "is_local": false, "ready": false},
			{"name": "", "level": 0, "stake": 0, "seat": 1, "is_local": false, "ready": false},
		]
		lobby.players[lobby.your_seat] = {"name": local_name, "level": local_level,
			"stake": maxi(0, local_stake), "seat": lobby.your_seat, "is_local": true, "ready": false}
		lobby.players[opp_seat] = {"name": String(data.get("opponent", "Player")),
			"level": int(data.get("opp_level", 1)),
			"stake": maxi(0, int(data.get("opp_stake", 0))),
			"seat": opp_seat, "is_local": false, "ready": false}
	return lobby

## The lobby_ready message a client sends when its player taps READY.
## Pure, unit-tested — NetClient.send_lobby_ready sends this dict.
static func ready_message(seat: int) -> Dictionary:
	return {"type": "lobby_ready", "seat": seat}

## Seat carried by a received lobby_ready message, or -1 when the
## message is malformed / has no usable seat.
static func ready_seat(data: Dictionary) -> int:
	if String(data.get("type", "")) != "lobby_ready":
		return -1
	if not data.has("seat"):
		return -1
	var seat := int(data.get("seat", -1))
	if seat < 0 or seat >= 4:
		return -1
	return seat

## Mark a seat ready. Returns false when the seat is not in the
## roster (stale/foreign message — ignored, never an error). When
## the last player becomes ready the state moves to "ready".
func mark_ready(seat: int) -> bool:
	if state == STATE_CANCELLED or state == STATE_STARTING:
		return false
	for p in players:
		if int(p["seat"]) == seat:
			p["ready"] = true
			if all_ready():
				state = STATE_READY
			return true
	return false

## A player left before the start: drop them from the roster and
## cancel the lobby (the server dissolves the room; the match never
## starts). Returns false when the seat is not in the roster.
func player_left(seat: int) -> bool:
	for i in range(players.size()):
		if int(players[i]["seat"]) == seat:
			players.remove_at(i)
			state = STATE_CANCELLED
			return true
	return false

func ready_count() -> int:
	var n := 0
	for p in players:
		if bool(p.get("ready", false)):
			n += 1
	return n

## Startable only with a full roster and every player ready.
func all_ready() -> bool:
	return players.size() == expected and ready_count() == expected

func can_start() -> bool:
	return state == STATE_READY and all_ready()

## Move to "starting" (Main calls this right before it builds the
## MatchScreen). Returns false unless the lobby is ready to start.
func begin_start() -> bool:
	if not can_start():
		return false
	state = STATE_STARTING
	return true

## One-line status for the lobby popup, e.g. "Waiting… 1/2 ready".
func status_text() -> String:
	if state == STATE_CANCELLED:
		return "A player left — the match was cancelled."
	if state == STATE_READY or state == STATE_STARTING:
		return "Everyone is ready — starting the match…"
	return "Waiting for players… %d/%d ready" % [ready_count(), expected]

## Display row for one roster entry (Main's popup uses this so the
## 4p team labels stay consistent: seats 0,2 are one team, 1,3 the
## other). `you` marks the local player.
static func row_text(p: Dictionary, is_4p: bool) -> String:
	var label := "%s  •  Lv %d" % [String(p.get("name", "Player")), int(p.get("level", 1))]
	if is_4p:
		label += "  •  %s" % ("Team A" if int(p.get("seat", 0)) % 2 == 0 else "Team B")
	if bool(p.get("is_local", false)):
		label += "  (YOU)"
	label += "  —  %s" % ("READY" if bool(p.get("ready", false)) else "waiting…")
	return label
