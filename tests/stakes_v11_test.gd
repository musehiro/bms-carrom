extends SceneTree

## v11 stakes + F13 Phase 2 tests (Buddhika's design).
##   * Winner takes ALL staked coins; loser gets NOTHING; draw refunds.
##   * Winner can DOUBLE online winnings by watching 2 rewarded ads.
##   * Verified stakes: the server rejects a stake above the verified
##     coin balance, and the server-sent stakes override the claimed
##     ones (matched payloads + settlement).
##   * JWT / verification paths with MOCK tokens and profile rows —
##     no live Supabase, no real tokens, no network anywhere here.
##   * Server-authoritative settlement: the server settles only when
##     both sides' outcome reports agree; conflicts refund own stakes.
## Run: godot --headless --path . -s tests/stakes_v11_test.gd
## Exit 0 = all pass, 1 = any fail.

var _passed := 0
var _failed := 0
var _failures: Array = []

func _initialize() -> void:
	print("=== BMS Carrom v11 stakes + verified settlement tests ===")
	_test_winner_takes_all()
	_test_double_via_two_ads()
	_test_verified_stake_rejection()
	_test_server_stakes_override_claimed()
	_test_jwt_verification_mocks()
	_test_settlement_messages()
	_test_server_settlement_2p()
	_test_server_settlement_4p()
	_test_match_screen_stores_settlement()
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

# ------------------------------------------------------- winner takes all
func _test_winner_takes_all() -> void:
	# Alice stakes 200, Bob stakes 350. Pot 550.
	_check("v11 win: winner takes the whole pot", Stakes.payout(200, 350, "win") == 550)
	_check("v11 win: server settlement agrees (550)", Settlement.credit_for_outcome(200, 350, "win", 550, true) == 550)
	_check("v11 loss: loser gets NOTHING", Stakes.payout(350, 200, "loss") == 0)
	_check("v11 loss: server settlement pays loser 0", Settlement.credit_for_outcome(350, 200, "loss", 0, true) == 0)
	_check("v11 draw: own stake refunded", Stakes.payout(200, 350, "draw") == 200)
	_check("v11 draw: server settlement refunds own stake", Settlement.credit_for_outcome(200, 350, "draw", 200, true) == 200)
	# The server's word wins even when it differs from the local math
	# (e.g. verified stakes were smaller than claimed): a server
	# payout of 400 on a 550 local pot credits 400, never 550.
	_check("v11 settle: server payout overrides local math", Settlement.credit_for_outcome(200, 350, "win", 400, true) == 400)
	# A corrupt settlement can never pay more than the pot (or < 0).
	_check("v11 settle: payout above pot clamps to pot", Settlement.credit_for_outcome(200, 350, "win", 9999, true) == 550)
	_check("v11 settle: negative payout clamps to 0", Settlement.credit_for_outcome(200, 350, "win", -50, true) == 0)
	# 4p: winning team splits the pot; losing team gets nothing.
	_check("v11 4p: winning team splits pot (700 -> 350 each)", Stakes.payout_4p([100, 150, 200, 250], 0, "win") == 350)
	_check("v11 4p: losing team gets nothing", Stakes.payout_4p([100, 150, 200, 250], 1, "loss") == 0)
	_check("v11 4p: server share overrides local split", Settlement.credit_for_outcome_4p([100, 150, 200, 250], 0, "win", 300, true) == 300)
	_check("v11 4p: server share clamps to pot", Settlement.credit_for_outcome_4p([100, 150, 200, 250], 0, "win", 9999, true) == 700)

# --------------------------------------------------- double via 2 ads
func _test_double_via_two_ads() -> void:
	# Online win, pot 550. Two rewarded ads double it to 1100.
	_check("v11 double: 2 ads double the pot (550 -> 1100)", Stakes.doubled_winnings(550, 2) == 1100)
	_check("v11 double: 1 ad doubles nothing yet", Stakes.doubled_winnings(550, 1) == 0)
	_check("v11 double: 0 ads doubles nothing", Stakes.doubled_winnings(550, 0) == 0)
	_check("v11 double: 0 pot doubles to 0", Stakes.doubled_winnings(0, 2) == 0)
	_check("v11 double: Settlement uses the same formula", Settlement.double_amount(550, 2) == 1100)
	# Doubling applies to the SETTLED winnings: server settled 400
	# (verified stakes smaller than claimed) -> doubled to 800.
	_check("v11 double: settled 400 doubles to 800", Settlement.double_amount(Settlement.credit_for_outcome(200, 350, "win", 400, true), 2) == 800)
	# The extra pot comes from the ads, never from the opponent: the
	# doubled amount is exactly 2x the base, no more.
	_check("v11 double: doubled is exactly 2x base", Stakes.doubled_winnings(350, 2) == 700)

# ------------------------------------------- verified stake rejection
func _test_verified_stake_rejection() -> void:
	var ServerScript: GDScript = load("res://server/net_server.gd")
	var profile := {"id": "user-1", "coins": 1000, "xp": 2500} # Lv 6
	var ok: Dictionary = ServerScript.verify_profile("user-1", "user-1", profile, 200)
	_check("v11 verify: stake inside balance accepted", bool(ok.get("ok", false)))
	_check("v11 verify: level comes from profile XP (2500 -> Lv 6)", int(ok.get("level", 0)) == 6)
	_check("v11 verify: balance comes from profile coins", int(ok.get("balance", 0)) == 1000)
	_check("v11 verify: stake kept as asked", int(ok.get("stake", 0)) == 200)
	var over: Dictionary = ServerScript.verify_profile("user-1", "user-1", profile, 1001)
	_check("v11 verify: stake above balance REJECTED", not bool(over.get("ok", true)))
	_check("v11 verify: rejection says balance", String(over.get("error", "")).contains("balance"))
	var exact: Dictionary = ServerScript.verify_profile("user-1", "user-1", profile, 1000)
	_check("v11 verify: stake equal to balance accepted", bool(exact.get("ok", false)))
	var zero: Dictionary = ServerScript.verify_profile("user-1", "user-1", profile, 0)
	_check("v11 verify: 0 stake accepted (friendly match)", bool(zero.get("ok", false)))
	var neg: Dictionary = ServerScript.verify_profile("user-1", "user-1", profile, -50)
	_check("v11 verify: negative stake rejected", not bool(neg.get("ok", true)))
	var wrong_sub: Dictionary = ServerScript.verify_profile("user-1", "user-2", profile, 200)
	_check("v11 verify: token for another account rejected", not bool(wrong_sub.get("ok", true)))
	var no_sub: Dictionary = ServerScript.verify_profile("user-1", "", profile, 200)
	_check("v11 verify: empty token rejected", not bool(no_sub.get("ok", true)))
	var wrong_row: Dictionary = ServerScript.verify_profile("user-1", "user-1", {"id": "user-9", "coins": 1000, "xp": 0}, 200)
	_check("v11 verify: profile row for another id rejected", not bool(wrong_row.get("ok", true)))
	_check("v11 verify: level 1 at 0 XP", ServerScript.profile_level(0) == 1)
	_check("v11 verify: level 1 at 499 XP", ServerScript.profile_level(499) == 1)
	_check("v11 verify: level 2 at 500 XP", ServerScript.profile_level(500) == 2)
	_check("v11 verify: client level formula matches server", Settlement.verified_level(2500) == 6)

# ----------------------------------- server stakes override claimed
func _test_server_stakes_override_claimed() -> void:
	var ServerScript: GDScript = load("res://server/net_server.gd")
	# Claimed: I stake 200, opponent claims 999. Verified: I stake
	# 150, opponent stakes 300. Verified wins, even though smaller.
	var applied := Settlement.apply_verified_stakes(200, 999, 150, 300, true)
	_check("v11 override: verified own stake wins (150, not 200)", int(applied["your_stake"]) == 150)
	_check("v11 override: verified opp stake wins (300, not 999)", int(applied["opp_stake"]) == 300)
	_check("v11 override: verified flag set", bool(applied["verified"]))
	var unapplied := Settlement.apply_verified_stakes(200, 999, 150, 300, false)
	_check("v11 override: unverified keeps claimed stakes", int(unapplied["your_stake"]) == 200 and int(unapplied["opp_stake"]) == 999)
	_check("v11 override: unverified flag clear", not bool(unapplied["verified"]))
	# Matched payloads carry the verified stakes both ways.
	var payloads: Dictionary = ServerScript.matched_payloads_verified(
		{"name": "Alice", "level": 5, "stake": 200},
		{"name": "Bob", "level": 6, "stake": 350}, true,
		{"level": 4, "stake": 150, "balance": 1000},
		{"level": 6, "stake": 300, "balance": 800})
	_check("v11 payload: A gets verified opp stake 300", int(payloads["a"]["opp_stake"]) == 300)
	_check("v11 payload: A gets verified opp level 6", int(payloads["a"]["opp_level"]) == 6)
	_check("v11 payload: A gets own verified stake 150", int(payloads["a"]["your_stake"]) == 150)
	_check("v11 payload: B gets own verified stake 300", int(payloads["b"]["your_stake"]) == 300)
	_check("v11 payload: B gets verified opp stake 150", int(payloads["b"]["opp_stake"]) == 150)
	_check("v11 payload: verified_stakes true when both verified", bool(payloads["a"]["verified_stakes"]) and bool(payloads["b"]["verified_stakes"]))
	# Unverified payloads: claimed stakes, your_stake echoed, flag false.
	var plain: Dictionary = ServerScript.matched_payloads_verified(
		{"name": "Alice", "level": 5, "stake": 200},
		{"name": "Bob", "level": 6, "stake": 350}, true)
	_check("v11 payload: unverified keeps claimed stakes", int(plain["a"]["opp_stake"]) == 350 and int(plain["a"]["your_stake"]) == 200)
	_check("v11 payload: unverified flag false", not bool(plain["a"]["verified_stakes"]))
	# Half-verified is NOT called verified.
	var half: Dictionary = ServerScript.matched_payloads_verified(
		{"name": "Alice", "level": 5, "stake": 200},
		{"name": "Bob", "level": 6, "stake": 350}, true,
		{"level": 4, "stake": 150, "balance": 1000}, {})
	_check("v11 payload: half-verified flag false", not bool(half["a"]["verified_stakes"]))
	# 4p verified payloads: roster stakes + own stake per seat.
	var infos := [
		{"name": "A", "level": 5, "stake": 100, "seat": 0},
		{"name": "B", "level": 5, "stake": 150, "seat": 1},
		{"name": "C", "level": 6, "stake": 200, "seat": 2},
		{"name": "D", "level": 6, "stake": 250, "seat": 3}]
	var p4: Array = ServerScript.matched_payloads_4p_verified(infos, 2, true)
	_check("v11 payload 4p: seat 1 gets own verified stake 150", int(p4[1]["your_stake"]) == 150)
	_check("v11 payload 4p: verified flag set", bool(p4[0]["verified_stakes"]))
	_check("v11 payload 4p: roster carries all stakes", int((p4[0]["players"] as Array)[3]["stake"]) == 250)

# ------------------------------------------------ JWT / verification
func _test_jwt_verification_mocks() -> void:
	var ServerScript: GDScript = load("res://server/net_server.gd")
	# MOCK JWT: header.payload.signature, payload {"sub": "user-1"}.
	# No real token, no network — just the shape the server checks.
	var payload_b64 := Marshalls.raw_to_base64("{\"sub\":\"user-1\"}".to_utf8_buffer())
	payload_b64 = payload_b64.replace("+", "-").replace("/", "_").trim_suffix("=")
	var header_b64 := Marshalls.raw_to_base64("{\"alg\":\"none\"}".to_utf8_buffer())
	header_b64 = header_b64.replace("+", "-").replace("/", "_").trim_suffix("=")
	var token := "%s.%s.%s" % [header_b64, payload_b64, "mock-signature"]
	var sub := SupabaseClient.jwt_sub(token)
	_check("v11 jwt: sub extracted from mock token", sub == "user-1", sub)
	_check("v11 jwt: garbage token has no sub", SupabaseClient.jwt_sub("not-a-jwt") == "")
	_check("v11 jwt: empty token has no sub", SupabaseClient.jwt_sub("") == "")
	_check("v11 jwt: two-part token has no sub", SupabaseClient.jwt_sub("aaa.bbb") == "")
	# The extracted sub drives verification: matching sub + profile
	# row + affordable stake verifies; a sub for another account does not.
	var profile := {"id": "user-1", "coins": 500, "xp": 0}
	var good: Dictionary = ServerScript.verify_profile("user-1", sub, profile, 100)
	_check("v11 jwt: mock token verifies its owner", bool(good.get("ok", false)))
	var bad: Dictionary = ServerScript.verify_profile("user-1", SupabaseClient.jwt_sub("aaa.bbb"), profile, 100)
	_check("v11 jwt: undecodable token never verifies", not bool(bad.get("ok", true)))
	# The client only sends identity when signed in: both fields or neither.
	var with_auth: Dictionary = NetClient.queue_message("Alice", 5, 0, 100, "2p", "user-1", token)
	_check("v11 auth: queue carries account_id when signed in", String(with_auth.get("account_id", "")) == "user-1")
	_check("v11 auth: queue carries access_token when signed in", String(with_auth.get("access_token", "")) == token)
	var anon: Dictionary = NetClient.queue_message("Alice", 5, 0, 100, "2p")
	_check("v11 auth: queue omits identity when not signed in", not anon.has("account_id") and not anon.has("access_token"))
	var half_auth: Dictionary = NetClient.queue_message("Alice", 5, 0, 100, "2p", "user-1", "")
	_check("v11 auth: token without id (or vice versa) sends neither", not half_auth.has("account_id") and not half_auth.has("access_token"))
	var inv_auth: Dictionary = NetClient.invite_join_message("grp-1", "Alice", 5, 100, "2p", 0, false, "user-1", token)
	_check("v11 auth: invite_join carries identity when signed in", String(inv_auth.get("account_id", "")) == "user-1" and String(inv_auth.get("access_token", "")) == token)
	var inv_anon: Dictionary = NetClient.invite_join_message("grp-1", "Alice", 5, 100, "2p", 0, false)
	_check("v11 auth: invite_join omits identity when not signed in", not inv_anon.has("account_id") and not inv_anon.has("access_token"))

# ------------------------------------------------- settlement messages
func _test_settlement_messages() -> void:
	var good := Settlement.parse_settlement({"type": "settlement", "payout": 550, "pot": 550})
	_check("v11 msg: valid settlement parses", bool(good.get("ok", false)) and int(good.get("payout", 0)) == 550)
	_check("v11 msg: payout above pot rejected", not bool(Settlement.parse_settlement({"type": "settlement", "payout": 551, "pot": 550}).get("ok", true)))
	_check("v11 msg: negative payout rejected", not bool(Settlement.parse_settlement({"type": "settlement", "payout": -1, "pot": 550}).get("ok", true)))
	_check("v11 msg: negative pot rejected", not bool(Settlement.parse_settlement({"type": "settlement", "payout": 0, "pot": -5}).get("ok", true)))
	_check("v11 msg: wrong type rejected", not bool(Settlement.parse_settlement({"type": "matched", "payout": 550, "pot": 550}).get("ok", true)))
	_check("v11 msg: non-numeric payout rejected", not bool(Settlement.parse_settlement({"type": "settlement", "payout": "lots", "pot": 550}).get("ok", true)))
	_check("v11 msg: zero payout is a valid (loser) settlement", bool(Settlement.parse_settlement({"type": "settlement", "payout": 0, "pot": 550}).get("ok", false)))
	_check("v11 msg: result win message built", Settlement.result_message("win") == {"type": "result", "outcome": "win"})
	_check("v11 msg: result loss message built", Settlement.result_message("loss") == {"type": "result", "outcome": "loss"})
	_check("v11 msg: result draw message built", Settlement.result_message("draw") == {"type": "result", "outcome": "draw"})
	_check("v11 msg: bogus outcome sends nothing", Settlement.result_message("cheat").is_empty())
	_check("v11 msg: valid outcomes recognised", Settlement.valid_outcome("win") and Settlement.valid_outcome("loss") and Settlement.valid_outcome("draw") and not Settlement.valid_outcome("cheat"))

# --------------------------------------------- server settlement 2p
func _test_server_settlement_2p() -> void:
	var ServerScript: GDScript = load("res://server/net_server.gd")
	var stakes := {11: 200, 22: 350} # pot 550
	var agreed: Dictionary = ServerScript.settle_reports_2p({11: "win", 22: "loss"}, stakes)
	_check("v11 settle2p: win+loss agreed, winner takes pot", String(agreed.get("status", "")) == "agreed" and int((agreed["payouts"] as Dictionary).get(11, 0)) == 550)
	_check("v11 settle2p: win+loss agreed, loser gets 0", int((agreed["payouts"] as Dictionary).get(22, -1)) == 0)
	var agreed2: Dictionary = ServerScript.settle_reports_2p({11: "loss", 22: "win"}, stakes)
	_check("v11 settle2p: loss+win pays the other side", int((agreed2["payouts"] as Dictionary).get(22, 0)) == 550 and int((agreed2["payouts"] as Dictionary).get(11, -1)) == 0)
	var draw: Dictionary = ServerScript.settle_reports_2p({11: "draw", 22: "draw"}, stakes)
	_check("v11 settle2p: draw+draw refunds both stakes", String(draw.get("status", "")) == "agreed" and int((draw["payouts"] as Dictionary).get(11, 0)) == 200 and int((draw["payouts"] as Dictionary).get(22, 0)) == 350)
	var conflict: Dictionary = ServerScript.settle_reports_2p({11: "win", 22: "win"}, stakes)
	_check("v11 settle2p: win+win is a conflict", String(conflict.get("status", "")) == "conflict")
	_check("v11 settle2p: conflict refunds own stakes", int((conflict["payouts"] as Dictionary).get(11, 0)) == 200 and int((conflict["payouts"] as Dictionary).get(22, 0)) == 350)
	var conflict2: Dictionary = ServerScript.settle_reports_2p({11: "win", 22: "draw"}, stakes)
	_check("v11 settle2p: win+draw is a conflict", String(conflict2.get("status", "")) == "conflict")
	var waiting: Dictionary = ServerScript.settle_reports_2p({11: "win"}, stakes)
	_check("v11 settle2p: one report waits for the other", String(waiting.get("status", "")) == "waiting")
	var bogus: Dictionary = ServerScript.settle_reports_2p({11: "win", 22: "cheat"}, stakes)
	_check("v11 settle2p: bogus outcome ignored, still waiting", String(bogus.get("status", "")) == "waiting")

# --------------------------------------------- server settlement 4p
func _test_server_settlement_4p() -> void:
	var ServerScript: GDScript = load("res://server/net_server.gd")
	var stakes := [100, 150, 200, 250] # pot 700
	var t0: Dictionary = ServerScript.settle_reports_4p({0: "win", 1: "loss", 2: "win", 3: "loss"}, stakes)
	_check("v11 settle4p: team 0 wins agreed", String(t0.get("status", "")) == "agreed")
	_check("v11 settle4p: team 0 splits pot 350/350", (t0["payouts"] as Array) == [350, 0, 350, 0], str(t0["payouts"]))
	var t1: Dictionary = ServerScript.settle_reports_4p({0: "loss", 1: "win", 2: "loss", 3: "win"}, stakes)
	_check("v11 settle4p: team 1 splits pot 350/350", (t1["payouts"] as Array) == [0, 350, 0, 350], str(t1["payouts"]))
	var odd: Dictionary = ServerScript.settle_reports_4p({0: "win", 1: "loss", 2: "win", 3: "loss"}, [101, 150, 200, 250])
	_check("v11 settle4p: odd pot leftover coin to first seat (351/350)", (odd["payouts"] as Array) == [351, 0, 350, 0], str(odd["payouts"]))
	var draw: Dictionary = ServerScript.settle_reports_4p({0: "draw", 1: "draw", 2: "draw", 3: "draw"}, stakes)
	_check("v11 settle4p: all draw refunds every stake", String(draw.get("status", "")) == "agreed" and (draw["payouts"] as Array) == [100, 150, 200, 250])
	var conflict: Dictionary = ServerScript.settle_reports_4p({0: "win", 1: "loss", 2: "loss", 3: "loss"}, stakes)
	_check("v11 settle4p: split team is a conflict", String(conflict.get("status", "")) == "conflict")
	_check("v11 settle4p: conflict refunds every stake", (conflict["payouts"] as Array) == [100, 150, 200, 250])
	var waiting: Dictionary = ServerScript.settle_reports_4p({0: "win", 1: "loss", 2: "win"}, stakes)
	_check("v11 settle4p: three reports wait for the fourth", String(waiting.get("status", "")) == "waiting")

# ---------------------------------- match screen stores a settlement
func _test_match_screen_stores_settlement() -> void:
	# No tree, no HUD: only the pre-result branch of
	# apply_server_settlement is exercised here (store + ignore bad
	# input). The live re-price of a held pot needs a real match.
	# NOTE: match.gd is loaded at RUNTIME, not referenced by class
	# name at parse time — a standalone -s test compiles before the
	# autoload singletons (Save, …) are registered as identifiers,
	# so a static MatchScreen reference makes match.gd fail to parse
	# here (flaky "Identifier not found: Save"). The scene-based
	# multiplayer tests do not have this problem.
	var MatchScript: GDScript = load("res://scripts/match.gd")
	_check("v11 screen: match.gd loads under test", MatchScript != null)
	if MatchScript == null:
		return
	var m: Node = MatchScript.new()
	m.mode = "online"
	m.apply_server_settlement({"type": "settlement", "payout": 550, "pot": 550})
	_check("v11 screen: settlement stored before result", m.get("_server_settlement") == 550 and m.get("_server_settlement_pot") == 550)
	var m2: Node = MatchScript.new()
	m2.mode = "online"
	m2.apply_server_settlement({"type": "settlement", "payout": 9999, "pot": 550})
	_check("v11 screen: payout above pot ignored", m2.get("_server_settlement") == -1)
	var m3: Node = MatchScript.new()
	m3.mode = "solo"
	m3.apply_server_settlement({"type": "settlement", "payout": 550, "pot": 550})
	_check("v11 screen: solo match ignores settlements", m3.get("_server_settlement") == -1)
	var m4: Node = MatchScript.new()
	m4.mode = "online"
	m4.apply_server_settlement({"type": "matched", "payout": 550, "pot": 550})
	_check("v11 screen: non-settlement message ignored", m4.get("_server_settlement") == -1)
	m.queue_free()
	m2.queue_free()
	m3.queue_free()
	m4.queue_free()
