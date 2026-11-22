extends SceneTree

## v5 staking + ad-ladder tests (Buddhika 2026-11-22).
##   * Ladder state machine via the real Save autoload (snapshot/restore
##     so the test never changes the developer's save).
##   * Local two-client staking simulation: two balances, stake lock,
##     win / loss / draw payouts — the same math the match result uses,
##     without needing a hosted server (live two-device staking is only
##     confirmable once the server is hosted).
##   * Server matched-payload stake exchange (pure function).
## Run: godot --headless --path . -s tests/stakes_test.gd
## Exit 0 = all pass, 1 = any fail.

var _passed := 0
var _failed := 0
var _failures: Array = []

func _initialize() -> void:
	print("=== BMS Carrom stakes + ladder tests ===")
	_test_ladder()
	_test_two_client_simulation()
	_test_server_payloads()
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

# ------------------------------------------------------------------- ladder
func _test_ladder() -> void:
	var save = get_root().get_node("Save")
	var snap_count: int = save.ad_count_today
	var snap_coins: int = save.ad_coins_today
	var snap_date: String = save.ad_date
	var snap_balance: int = save.coins
	# Force a fresh day so the ladder starts at tier 1.
	save.ad_date = "2000-01-01"
	save.ad_count_today = 0
	save.ad_coins_today = 0
	_check("ladder: 1st ad pays 150", save.ad_next_reward() == 150)
	_check("ladder: tier 1 at start", save.ad_current_tier() == 1)
	_check("ladder: cap not reached at start", not save.ad_cap_reached())
	save.record_ad_reward(150)
	_check("ladder: 2nd ad pays 200", save.ad_next_reward() == 200)
	_check("ladder: tier 2 after 1 ad", save.ad_current_tier() == 2)
	save.record_ad_reward(200)
	_check("ladder: 3rd ad pays 250", save.ad_next_reward() == 250)
	save.record_ad_reward(250)
	_check("ladder: 4th ad pays 300", save.ad_next_reward() == 300)
	save.record_ad_reward(300)
	_check("ladder: 5th ad pays 400", save.ad_next_reward() == 400)
	_check("ladder: tier 5 after 4 ads", save.ad_current_tier() == 5)
	save.record_ad_reward(400)
	_check("ladder: 6th ad still pays 400", save.ad_next_reward() == 400)
	save.record_ad_reward(400)
	save.record_ad_reward(400)
	_check("ladder: 8th ad pays 400 (2400 so far)", save.ad_next_reward() == 400)
	save.record_ad_reward(400)
	_check("ladder: cap 2500 reached after 8 ads", save.ad_coins_today == 2500 and save.ad_cap_reached())
	_check("ladder: 9th ad pays 0 (capped)", save.ad_next_reward() == 0)
	# Daily reset: a new day restarts the ladder at 150.
	save.ad_date = "2000-01-02"
	_check("ladder: new day resets to 150", save.ad_next_reward() == 150)
	_check("ladder: new day resets tier to 1", save.ad_current_tier() == 1)
	# Restore the real save state (the test must not change it).
	save.ad_count_today = snap_count
	save.ad_coins_today = snap_coins
	save.ad_date = snap_date
	save.coins = snap_balance
	save.save()

# ------------------------------------------------- two-client staking sim
func _test_two_client_simulation() -> void:
	# Alice: 1000 coins, stakes 200. Bob: 800 coins, stakes 350.
	var a_bal := 1000
	var b_bal := 800
	var a_stake := 200
	var b_stake := 350
	_check("sim: both stakes valid", Stakes.valid_stake(a_stake, a_bal) and Stakes.valid_stake(b_stake, b_bal))
	# Stake lock at match start (deducted, like match.gd does).
	a_bal -= a_stake
	b_bal -= b_stake
	_check("sim: lock deducts stakes", a_bal == 800 and b_bal == 450)
	# Alice wins: she takes the whole pot (her 200 back + Bob's 350).
	var a_win := a_bal + Stakes.payout(a_stake, b_stake, "win")
	var b_win := b_bal + Stakes.payout(b_stake, a_stake, "loss")
	_check("sim: winner takes the pot (800+550=1350)", a_win == 1350, str(a_win))
	_check("sim: loser keeps only the unlocked balance", b_win == 450, str(b_win))
	# Bob wins: the pot goes the other way.
	var a_lose := a_bal + Stakes.payout(a_stake, b_stake, "loss")
	var b_lose := b_bal + Stakes.payout(b_stake, a_stake, "win")
	_check("sim: Bob win pays 450+550=1000", b_lose == 1000, str(b_lose))
	_check("sim: Alice loss keeps 800", a_lose == 800, str(a_lose))
	# Draw: both stakes are returned.
	var a_draw := a_bal + Stakes.payout(a_stake, b_stake, "draw")
	var b_draw := b_bal + Stakes.payout(b_stake, a_stake, "draw")
	_check("sim: draw refunds Alice to 1000", a_draw == 1000, str(a_draw))
	_check("sim: draw refunds Bob to 800", b_draw == 800, str(b_draw))
	# Friendly 0-stake match: nothing moves whatever the result.
	_check("sim: 0-stake win pays 0", Stakes.payout(0, 0, "win") == 0)
	_check("sim: 0-stake draw refunds 0", Stakes.payout(0, 0, "draw") == 0)
	# Real Save round-trip: lock 200, win the pot, net +350.
	var save = get_root().get_node("Save")
	var snap: int = save.coins
	save.coins = 1000
	save.save()
	_check("sim: Save lock deducts", save.spend_coins(200) and save.coins == 800)
	save.add_coins(Stakes.payout(200, 350, "win"))
	_check("sim: Save payout lands (800+550=1350)", save.coins == 1350, str(save.coins))
	save.coins = snap
	save.save()

# ------------------------------------------------------ server stake exchange
func _test_server_payloads() -> void:
	var ServerScript: GDScript = load("res://server/net_server.gd")
	var a := {"name": "Alice", "level": 5, "stake": 200}
	var b := {"name": "Bob", "level": 6, "stake": 350}
	var payloads: Dictionary = ServerScript.matched_payloads(a, b, true)
	_check("server: A learns Bob's stake (350)", int(payloads["a"]["opp_stake"]) == 350)
	_check("server: A learns Bob's name/level", String(payloads["a"]["opponent"]) == "Bob" and int(payloads["a"]["opp_level"]) == 6)
	_check("server: B learns Alice's stake (200)", int(payloads["b"]["opp_stake"]) == 200)
	_check("server: breaker flags are opposite", bool(payloads["a"]["you_break"]) != bool(payloads["b"]["you_break"]))
	var old: Dictionary = ServerScript.matched_payloads({"name": "Alice", "level": 5}, {"name": "Bob", "level": 6}, false)
	_check("server: missing stake defaults to 0", int(old["a"]["opp_stake"]) == 0 and int(old["b"]["opp_stake"]) == 0)
