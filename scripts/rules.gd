class_name CarromRules
extends RefCounted

## Pure rules state machine (design doc 1.5–1.7, 6.1).
## No UI, no physics — unit-testable. One board per match.
##
## State dictionary:
##   turn: 0 or 1 (player index; player 0 is the breaker and plays white)
##   pocketed: [white_count, black_count] — coins pocketed by each player
##   queen: "board" | "pending" | "covered" | "returned"
##   queen_owner: player who pocketed the queen (-1 if none)
##   due: [n0, n1] — coins owed by each player (come back from next pocket)
##   over: bool, winner: -1/0/1, lose_reason: String

static func fresh_state(breaker: int = 0) -> Dictionary:
	return {
		"turn": breaker,
		"breaker": breaker,
		"pocketed": [0, 0],
		"queen": "board",
		"queen_owner": -1,
		"due": [0, 0],
		"over": false,
		"winner": -1,
		"lose_reason": "",
		"shots_taken": 0,
	}

static func own_color(state: Dictionary, player: int) -> String:
	return "white" if player == int(state["breaker"]) else "black"

static func opp_color(state: Dictionary, player: int) -> String:
	return "black" if player == int(state["breaker"]) else "white"

## Resolve one completed stroke.
## pocketed_kinds: kinds pocketed this stroke, e.g. ["white", "queen"].
## striker_pocketed: whether the striker went in.
## Returns {"events": [ {"type": ...}, ... ]} and mutates `state`.
static func resolve_shot(state: Dictionary, pocketed_kinds: Array, striker_pocketed: bool) -> Dictionary:
	var events: Array = []
	var shooter: int = state["turn"]
	var own := own_color(state, shooter)
	var opp := opp_color(state, shooter)
	var pocketed: Array = state["pocketed"]
	var due: Array = state["due"]

	var own_before: int = pocketed[shooter]
	var own_pocketed := 0
	var opp_pocketed := 0
	var queen_pocketed := false
	for k in pocketed_kinds:
		if k == own:
			own_pocketed += 1
		elif k == opp:
			opp_pocketed += 1
		elif k == "queen":
			queen_pocketed = true

	state["shots_taken"] = int(state["shots_taken"]) + 1

	# --- Queen pocketed this stroke -------------------------------------
	var queen_covered_this_shot := false
	if queen_pocketed:
		if state["queen"] == "board" or state["queen"] == "returned":
			if own_before <= 0 and own_pocketed <= 0:
				# Queen before your first coin: she returns to the centre.
				state["queen"] = "returned"
				state["queen_owner"] = -1
				events.append({"type": "queen_early", "player": shooter})
			else:
				state["queen"] = "pending"
				state["queen_owner"] = shooter
				events.append({"type": "queen_pocketed", "player": shooter})
				# Same-stroke cover: an own coin pocketed on the same stroke.
				if own_pocketed > 0:
					state["queen"] = "covered"
					queen_covered_this_shot = true
					events.append({"type": "queen_covered", "player": shooter})
	# --- Cover from a previous stroke -----------------------------------
	elif state["queen"] == "pending" and int(state["queen_owner"]) == shooter:
		if own_pocketed > 0:
			state["queen"] = "covered"
			queen_covered_this_shot = true
			events.append({"type": "queen_covered", "player": shooter})

	# --- Apply pocketed counts ------------------------------------------
	pocketed[shooter] = own_before + own_pocketed
	pocketed[1 - shooter] = int(pocketed[1 - shooter]) + opp_pocketed
	if own_pocketed > 0:
		events.append({"type": "own_pocketed", "player": shooter, "count": own_pocketed})
	if opp_pocketed > 0:
		events.append({"type": "opp_pocketed", "player": shooter, "count": opp_pocketed})

	# --- Foul: striker pocketed (ICF dues, simplified per doc 1.6) -------
	var foul_loses_turn := false
	if striker_pocketed:
		events.append({"type": "foul_striker", "player": shooter})
		if queen_pocketed and state["queen"] == "pending":
			# Striker + queen: queen back to centre, owe one, keep turn.
			state["queen"] = "returned"
			state["queen_owner"] = -1
			events.append({"type": "queen_returned", "player": shooter})
		if own_pocketed > 0:
			# Striker + own coins: those coins come back + one more due,
			# but the shooter KEEPS the turn.
			pocketed[shooter] = int(pocketed[shooter]) - own_pocketed
			due[shooter] = int(due[shooter]) + 1
			events.append({"type": "coins_returned", "player": shooter, "count": own_pocketed})
		else:
			# Striker alone (or with queen / opponent coin): lose turn + due.
			due[shooter] = int(due[shooter]) + 1
			foul_loses_turn = true
		# Settle dues immediately from coins already pocketed.
		while int(due[shooter]) > 0 and int(pocketed[shooter]) > 0:
			pocketed[shooter] = int(pocketed[shooter]) - 1
			due[shooter] = int(due[shooter]) - 1
			events.append({"type": "due_paid", "player": shooter})

	# --- Queen cover missed: the queen was pocketed on the shooter's
	#     previous stroke and this stroke (their very next one) pocketed no
	#     own coin, so she goes back to the centre.
	if state["queen"] == "pending" and int(state["queen_owner"]) == shooter and not queen_pocketed and not queen_covered_this_shot:
		state["queen"] = "returned"
		state["queen_owner"] = -1
		events.append({"type": "queen_returned", "player": shooter})

	# --- Settle any outstanding due from a fresh pocket ------------------
	# (due owed from an earlier foul, paid from the first coin pocketed).
	while int(due[shooter]) > 0 and int(pocketed[shooter]) > 0 and not striker_pocketed:
		pocketed[shooter] = int(pocketed[shooter]) - 1
		due[shooter] = int(due[shooter]) - 1
		events.append({"type": "due_paid", "player": shooter})

	# --- Losing conditions ----------------------------------------------
	# Pocketing the opponent's LAST coin loses the board.
	if int(pocketed[1 - shooter]) >= 9 and opp_pocketed > 0:
		state["over"] = true
		state["winner"] = 1 - shooter
		state["lose_reason"] = "pocketed_opponent_last"
		events.append({"type": "board_lost", "player": shooter, "reason": "pocketed_opponent_last"})
		return {"events": events}
	# Pocketing your last coin while the queen is still on the board
	# (uncovered) loses the board.
	if int(pocketed[shooter]) >= 9:
		if state["queen"] == "covered" and int(state["queen_owner"]) == shooter:
			state["over"] = true
			state["winner"] = shooter
			state["lose_reason"] = ""
			events.append({"type": "board_won", "player": shooter, "queen": true})
		elif state["queen"] == "board" or state["queen"] == "returned" or state["queen"] == "pending":
			state["over"] = true
			state["winner"] = 1 - shooter
			state["lose_reason"] = "last_coin_queen_on_board"
			events.append({"type": "board_lost", "player": shooter, "reason": "last_coin_queen_on_board"})
		else:
			# Queen covered by the opponent earlier: you cleared your coins
			# but the queen is theirs — you still win the board on coins;
			# queen points go to nobody (loser never gets queen points).
			state["over"] = true
			state["winner"] = shooter
			state["lose_reason"] = ""
			events.append({"type": "board_won", "player": shooter, "queen": false})
		return {"events": events}

	# --- Turn passing ----------------------------------------------------
	var keep_turn := false
	if striker_pocketed:
		keep_turn = own_pocketed > 0 # striker + own coins keeps the turn
	elif own_pocketed > 0:
		keep_turn = true
	elif queen_covered_this_shot:
		keep_turn = true
	elif queen_pocketed and (state["queen"] == "pending" or state["queen"] == "covered"):
		# Pocketed the queen: shoot again to cover her.
		keep_turn = true
	if foul_loses_turn:
		keep_turn = false
	if keep_turn:
		events.append({"type": "turn_kept", "player": shooter})
	else:
		state["turn"] = 1 - shooter
		events.append({"type": "turn_passed", "player": state["turn"]})
	return {"events": events}

## Board score for the winner: 1 per opponent coin left + 3 for a covered
## queen (doc 1.7). Kept for display; v1 matches are single-board.
static func board_score(state: Dictionary, winner: int) -> int:
	var score := 9 - int(state["pocketed"][1 - winner])
	if state["queen"] == "covered" and int(state["queen_owner"]) == winner:
		score += 3
	return score
