class_name Settlement
extends RefCounted

## F13 Phase 2 — client-side settlement rules (v11).
## Pure logic — no UI, no Save access, no network — so it is unit-testable.
##
## DESIGN (safe choices, see also server/net_server.gd header):
##   * The SERVER decides the payout. The client reports its match
##     outcome ("win" / "loss" / "draw") and the server answers with a
##     `settlement` message {payout, pot, verified}. The client credits
##     the server's payout, never its own local computation, whenever a
##     settlement has arrived (MatchScreen.apply_server_settlement).
##   * The server's stakes are authoritative. A `matched` payload with
##     verified_stakes=true carries your_stake (the VERIFIED own stake)
##     and opp_stake (the VERIFIED opponent stake); the client uses those
##     instead of its own claimed stake (apply_verified_stakes).
##   * Graceful degradation: with no live server (offline, LAN, bot,
##     tour, solo, or an old server that sends no settlement) there is
##     no settlement and no verified flag, and the client falls back to
##     the local Stakes math exactly as before. Local/bot play is
##     unaffected and never crashes offline.
##   * HONEST LIMIT (documented, not hidden): the coin credit itself
##     still happens client-side (Save + cloud upsert), exactly as in
##     v10. The server is authoritative over the payout DECISION; the
##     remaining step before internet play goes live is a server-side
##     coin ledger (the server PATCHing both profiles with the service
##     key after settlement) with reconciliation against the client's
##     cloud upsert, so a modified client cannot credit itself twice.
##     That step needs a live Supabase project + server to test and is
##     NOT in this patch — see the v11 stakes summary.
##   * Draws refund only the player's OWN stake back, so the draw path
##     never moves the opponent's coins and needs no settlement.
##   * Doubling (2 rewarded ads) doubles the SETTLED winnings — the
##     extra pot is paid by the ads, never by the opponent.

## Level from XP, mirroring Save.level() (500 XP/level) and the
## server's profile_level(). Pure — the client uses it only to
## display a verified level; matchmaking uses the server's value.
static func verified_level(xp: int) -> int:
	return maxi(1, xp / 500 + 1)

## Which stakes does this match play for? When the server verified
## them, the SERVER's stakes win — the claimed ones are discarded,
## even if they are larger. When nothing was verified (offline / LAN /
## old server), the claimed stakes stand. Returns
## {your_stake, opp_stake, verified}.
static func apply_verified_stakes(claimed_own: int, claimed_opp: int,
		server_own: int, server_opp: int, verified: bool) -> Dictionary:
	if verified:
		return {"your_stake": maxi(0, server_own), "opp_stake": maxi(0, server_opp),
			"verified": true}
	return {"your_stake": maxi(0, claimed_own), "opp_stake": maxi(0, claimed_opp),
		"verified": false}

## Coins to credit for a finished match. When the server settled the
## match (server_verified=true), its payout is used, clamped to
## 0..pot so a corrupt or stale settlement can never pay more than
## the pot (or a negative amount). Otherwise the local Stakes math
## applies (winner takes all, loser gets nothing, draw refunds).
static func credit_for_outcome(your_stake: int, opp_stake: int, outcome: String,
		server_payout: int, server_verified: bool) -> int:
	if server_verified:
		var pot := your_stake + opp_stake
		return clampi(server_payout, 0, pot)
	return Stakes.payout(your_stake, opp_stake, outcome)

## 4p version of credit_for_outcome. `server_share` is the server's
## settled share for the local seat (already the team's half-split);
## the local fallback is Stakes.payout_4p.
static func credit_for_outcome_4p(stakes: Array, your_seat: int, outcome: String,
		server_share: int, server_verified: bool) -> int:
	if server_verified:
		var pot := Stakes.pot_4p(stakes)
		return clampi(server_share, 0, pot)
	return Stakes.payout_4p(stakes, your_seat, outcome)

## Doubled winnings for the win screen: the settled base pot x2 once
## both doubling ads have been watched, else 0 (not doubled yet).
## Delegates to Stakes so there is exactly one doubling formula.
static func double_amount(base_pot: int, ads_watched: int) -> int:
	return Stakes.doubled_winnings(base_pot, ads_watched)

## Validate a `settlement` message from the server. Returns
## {ok, payout, pot, error}. A settlement is only usable when it
## names a payout inside 0..pot — anything else is rejected and the
## client keeps its local (held) pot instead of crediting garbage.
static func parse_settlement(data: Dictionary) -> Dictionary:
	if String(data.get("type", "")) != "settlement":
		return {"ok": false, "payout": 0, "pot": 0, "error": "Not a settlement message."}
	if typeof(data.get("payout", -1)) != TYPE_INT and typeof(data.get("payout", -1)) != TYPE_FLOAT:
		return {"ok": false, "payout": 0, "pot": 0, "error": "Settlement payout must be a number."}
	if typeof(data.get("pot", -1)) != TYPE_INT and typeof(data.get("pot", -1)) != TYPE_FLOAT:
		return {"ok": false, "payout": 0, "pot": 0, "error": "Settlement pot must be a number."}
	var payout := int(data["payout"])
	var pot := int(data["pot"])
	if payout < 0 or pot < 0:
		return {"ok": false, "payout": 0, "pot": 0, "error": "Settlement amounts cannot be negative."}
	if payout > pot:
		return {"ok": false, "payout": 0, "pot": 0, "error": "Settlement payout exceeds the pot."}
	return {"ok": true, "payout": payout, "pot": pot, "error": ""}

## Build the result report the client sends the server at match end.
## Returns {} for an outcome the server does not recognise — the
## client then sends nothing rather than a corrupt report.
static func result_message(outcome: String) -> Dictionary:
	if outcome != "win" and outcome != "loss" and outcome != "draw":
		return {}
	return {"type": "result", "outcome": outcome}

## Is this outcome string one the server accepts in a result report?
static func valid_outcome(outcome: String) -> bool:
	return outcome == "win" or outcome == "loss" or outcome == "draw"
