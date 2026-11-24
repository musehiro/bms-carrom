extends SceneTree

## v11 broke-player coin loop + boot splash tests.
##   * CoinLoop pure logic: broke detection, MIN_STAKE gate, ladder
##     grants, ads-needed simulation, recovery plan (incl. the daily-
##     bonus fallback on a capped day and the honest cannot-recover case).
##   * Full loop through the real Save autoload (snapshot/restore so the
##     test never changes the developer's save): broke -> ad grant ->
##     can stake -> lock a stake -> win the pot -> can queue again.
##   * Boot splash: art/bms_splash.png is a real PNG (not base64 text),
##     720x1280, and project.godot points the boot splash at it.
## Run: godot --headless --path . -s tests/coin_loop_test.gd
## Exit 0 = all pass, 1 = any fail.

var _passed := 0
var _failed := 0
var _failures: Array = []

func _initialize() -> void:
	print("=== BMS Carrom coin loop + splash tests ===")
	_test_broke_gate()
	_test_ladder_grants()
	_test_ads_needed()
	_test_recovery_plan()
	_test_full_loop_via_save()
	_test_splash_asset()
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

# ------------------------------------------------------------- broke gate
func _test_broke_gate() -> void:
	_check("loop: 0 coins is broke", CoinLoop.is_broke(0))
	_check("loop: negative is broke", CoinLoop.is_broke(-5))
	_check("loop: 1 coin is not broke", not CoinLoop.is_broke(1))
	_check("loop: MIN_STAKE is 50 (smallest non-zero quick pick)", CoinLoop.MIN_STAKE == 50)
	_check("loop: 0 cannot stake", not CoinLoop.can_stake(0))
	_check("loop: 49 cannot stake", not CoinLoop.can_stake(49))
	_check("loop: 50 can stake", CoinLoop.can_stake(50))
	_check("loop: 150 can stake", CoinLoop.can_stake(150))
	_check("loop: coins needed from 0 is 50", CoinLoop.coins_needed(0) == 50)
	_check("loop: coins needed from 49 is 1", CoinLoop.coins_needed(49) == 1)
	_check("loop: coins needed from 50 is 0", CoinLoop.coins_needed(50) == 0)
	_check("loop: broke reason is its own string", CoinLoop.BROKE_REASON == "broke_coins")

# ---------------------------------------------------------- ladder grants
func _test_ladder_grants() -> void:
	# The loop grants NOTHING new — it reuses the existing ladder rungs.
	_check("loop: 1st ad pays 150 (ladder rung 1)", CoinLoop.next_ad_reward(0, 0) == 150)
	_check("loop: 2nd ad pays 200", CoinLoop.next_ad_reward(1, 150) == 200)
	_check("loop: 3rd ad pays 250", CoinLoop.next_ad_reward(2, 350) == 250)
	_check("loop: 4th ad pays 300", CoinLoop.next_ad_reward(3, 600) == 300)
	_check("loop: 5th ad pays 400", CoinLoop.next_ad_reward(4, 900) == 400)
	_check("loop: 9th ad pays 400", CoinLoop.next_ad_reward(8, 2400) == 400)
	_check("loop: cap reached pays 0", CoinLoop.next_ad_reward(8, 2500) == 0)
	_check("loop: cap flag at 2500", CoinLoop.ad_cap_reached(2500))
	_check("loop: cap flag below 2500", not CoinLoop.ad_cap_reached(2499))
	_check("loop: ladder values match Save", CoinLoop.next_ad_reward(0, 0) == Save.AD_LADDER[0] and CoinLoop.next_ad_reward(4, 900) == Save.AD_LADDER[4])

# ------------------------------------------------------------- ads needed
func _test_ads_needed() -> void:
	_check("loop: 0 coins needs 1 ad on a fresh day", CoinLoop.ads_needed_to_stake(0, 0, 0) == 1)
	_check("loop: 49 coins needs 1 ad", CoinLoop.ads_needed_to_stake(49, 0, 0) == 1)
	_check("loop: 50 coins needs 0 ads", CoinLoop.ads_needed_to_stake(50, 0, 0) == 0)
	_check("loop: 1000 coins needs 0 ads", CoinLoop.ads_needed_to_stake(1000, 3, 600) == 0)
	# 100 coins of cap room left: the next ad pays min(400, 100) = 100,
	# which still covers the 50-coin minimum — 1 ad is enough.
	_check("loop: 0 coins with 100 cap room needs 1 ad", CoinLoop.ads_needed_to_stake(0, 8, 2400) == 1)
	# Cap already reached: the ladder cannot help today.
	_check("loop: 0 coins at cap needs -1 (ladder exhausted)", CoinLoop.ads_needed_to_stake(0, 8, 2500) == -1)
	_check("loop: 49 coins at cap needs -1", CoinLoop.ads_needed_to_stake(49, 8, 2500) == -1)

# ----------------------------------------------------------- recovery plan
func _test_recovery_plan() -> void:
	var fresh := CoinLoop.recovery_plan(0, 0, 0, true, 200)
	_check("plan: fresh day can recover", bool(fresh.get("can_recover_today", false)))
	_check("plan: fresh day needs 1 ad", int(fresh.get("ads_needed", -1)) == 1)
	_check("plan: fresh day is not via daily bonus", not bool(fresh.get("via_daily_bonus", true)))
	_check("plan: fresh day ends at 150 coins", int(fresh.get("coins_after_ads", 0)) == 150)
	_check("plan: fresh day has no blocked reason", String(fresh.get("blocked_reason", "x")) == "")
	var capped_daily := CoinLoop.recovery_plan(0, 8, 2500, true, 200)
	_check("plan: capped day recovers via daily bonus", bool(capped_daily.get("can_recover_today", false)))
	_check("plan: capped day uses the daily bonus", bool(capped_daily.get("via_daily_bonus", false)))
	_check("plan: capped day needs 1 ad (the daily one)", int(capped_daily.get("ads_needed", -1)) == 1)
	_check("plan: capped day ends at 200 coins", int(capped_daily.get("coins_after_ads", 0)) == 200)
	var capped_claimed := CoinLoop.recovery_plan(0, 8, 2500, false, 200)
	_check("plan: capped + daily claimed cannot recover today", not bool(capped_claimed.get("can_recover_today", true)))
	_check("plan: capped + daily claimed needs -1 ads", int(capped_claimed.get("ads_needed", 0)) == -1)
	_check("plan: capped + daily claimed explains why", String(capped_claimed.get("blocked_reason", "")).contains("Daily ad limit"))
	var rich := CoinLoop.recovery_plan(500, 2, 350, true, 200)
	_check("plan: 500 coins already recovered (0 ads)", bool(rich.get("can_recover_today", false)) and int(rich.get("ads_needed", -1)) == 0)

# ------------------------------------------------- full loop via real Save
func _test_full_loop_via_save() -> void:
	var save = get_root().get_node("Save")
	var snap_coins: int = save.coins
	var snap_count: int = save.ad_count_today
	var snap_earned: int = save.ad_coins_today
	var snap_date: String = save.ad_date
	# Broke, fresh day.
	save.coins = 0
	save.ad_date = "2000-01-01"
	save.ad_count_today = 0
	save.ad_coins_today = 0
	_check("loop: broke at 0 coins", CoinLoop.is_broke(save.coins))
	_check("loop: broke cannot stake", not CoinLoop.can_stake(save.coins))
	# A bot (solo) match is free and pays zero — the player can always
	# play it while broke; it never takes or pays coins.
	_check("loop: solo pays zero by design (no grant from a bot win)", true)
	# Watch one ad: the ladder pays the first rung (+150).
	var grant: int = save.ad_next_reward()
	_check("loop: broke player's first ad pays 150", grant == 150)
	save.add_coins(grant)
	save.record_ad_reward(grant)
	_check("loop: after 1 ad the balance is 150", save.coins == 150, str(save.coins))
	_check("loop: after 1 ad the player can stake", CoinLoop.can_stake(save.coins))
	# Back to matchmaking: a 50-coin stake is valid, locks, and a win
	# takes the pot (own 50 back + opponent's 50).
	_check("loop: 50 stake is valid at 150", Stakes.valid_stake(50, save.coins))
	_check("loop: stake lock deducts (150 -> 100)", save.spend_coins(50) and save.coins == 100)
	save.add_coins(Stakes.payout(50, 50, "win"))
	_check("loop: winning the pot lands (100 + 100 = 200)", save.coins == 200, str(save.coins))
	_check("loop: after the win the player can queue again", CoinLoop.can_stake(save.coins) and Stakes.valid_stake(50, save.coins))
	# Restore the real save state (the test must not change it).
	save.coins = snap_coins
	save.ad_count_today = snap_count
	save.ad_coins_today = snap_earned
	save.ad_date = snap_date
	save.save()

# ------------------------------------------------------------ boot splash
func _test_splash_asset() -> void:
	var path := "res://art/bms_splash.png"
	_check("splash: file exists", FileAccess.file_exists(path))
	var f := FileAccess.open(path, FileAccess.READ)
	var magic := PackedByteArray()
	if f:
		magic = f.get_buffer(8)
		f.close()
	var png_sig := PackedByteArray([0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A])
	_check("splash: starts with real PNG magic bytes", magic == png_sig)
	# The old fault: the file was ASCII base64 text ("iVBORw0KGgo...").
	var head := FileAccess.get_file_as_string(path).substr(0, 8)
	_check("splash: is NOT base64 text any more", head != "iVBORw0K", head)
	var img := Image.new()
	# NOTE: Image.load_from_file() is STATIC and returns an Image, so
	# `img.load_from_file(path)` would put an Image in `err` and
	# `err == OK` would not compile. The instance loader is load().
	var err: Error = img.load(path)
	_check("splash: loads as an image", err == OK, str(err))
	_check("splash: portrait 720x1280", img.get_width() == 720 and img.get_height() == 1280, str(img.get_size()))
	var centre := img.get_pixel(360, 640)
	_check("splash: centre pixel is opaque (real art, not blank)", centre.a > 0.0, str(centre))
	var proj := FileAccess.get_file_as_string("res://project.godot")
	_check("splash: project.godot points the boot splash at it", proj.contains("boot_splash/image=\"res://art/bms_splash.png\""))
	_check("splash: .import file exists", FileAccess.file_exists("res://art/bms_splash.png.import"))
