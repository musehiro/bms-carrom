extends Node

## Premium win-screen test (v6): force online wins on a solo match and
## check the pot hold, the COLLECT button, the WATCH 2 ADS -> DOUBLE
## offer (full path through Main + the ad ladder), and the exit-credits
## path. Run headless:
##   godot --headless --path . res://tests/win_double_test.tscn
## Exit 0 = all pass, 1 = any fail.

var _passed := 0
var _failed := 0
var _main = null
var _done := false
var _wait := 0.0
var _ad_earned := 0

func _ready() -> void:
	Ads.rewarded_earned.connect(func(_reason: String, _sim: bool) -> void: _ad_earned += 1)
	# v7: registration is mandatory — seed a test account so Main
	# reaches the home screen instead of the auth screen.
	Save.account_gmail = "test.player@gmail.com"
	Save.account_id = "test-account-id"
	Save.account_verified = true
	Save.player_name = "Test Player"
	Save.save()
	var main_scene: PackedScene = load("res://scenes/main.tscn")
	_main = main_scene.instantiate()
	add_child(_main)
	_run()

func _process(delta: float) -> void:
	if _done:
		return
	_wait += delta
	if _wait > 90.0:
		print("[WinDoubleTest] TIMEOUT")
		_finish()

func _frames(n: int) -> void:
	for i in range(n):
		await get_tree().process_frame

func _check(test_name: String, cond: bool, detail: String = "") -> void:
	if cond:
		_passed += 1
		print("PASS: ", test_name)
	else:
		_failed += 1
		print("FAIL: ", test_name, (" — " + detail if detail != "" else ""))

func _find_label(root: Node, text: String) -> Label:
	for n in root.get_children():
		if n is Label and (n as Label).text == text:
			return n
		var found := _find_label(n, text)
		if found:
			return found
	return null

func _find_button_with_label(root: Node, text: String) -> Button:
	for n in root.get_children():
		if n is Button:
			if _find_label(n, text) != null:
				return n
		var found := _find_button_with_label(n, text)
		if found:
			return found
	return null

func _find_button(root: Node, prefix: String) -> Button:
	for n in root.get_children():
		if n is Button and String((n as Button).text).begins_with(prefix):
			return n
		var found := _find_button(n, prefix)
		if found:
			return found
	return null

## Like _find_label, but matches a label CONTAINING the text (the loss
## screen joins several lines into one label).
func _find_label_containing(root: Node, text: String) -> Label:
	for n in root.get_children():
		if n is Label and (n as Label).text.contains(text):
			return n
		var found := _find_label_containing(n, text)
		if found:
			return found
	return null

## Force an online win on a fresh solo match (stakes your/opp).
func _force_online_win(your_stake: int, opp_stake: int) -> void:
	_main._start_solo(1)
	var waited := 0.0
	while waited < 9.0:
		await get_tree().create_timer(0.5).timeout
		waited += 0.5
		if _main._match != null and _main._match.phase == "place":
			break
	var m = _main._match
	if m == null:
		return
	Save.interstitial_counter = 0 # never auto-show an interstitial here
	m.mode = "online"
	m.your_stake = your_stake
	m.opp_stake = opp_stake
	m.rules_state["over"] = true
	m.rules_state["winner"] = 0
	m._show_result()
	await _frames(3)

func _run() -> void:
	await _frames(5)
	_check("home shown", _main._home != null)
	if _main._home == null:
		_finish()
		return
	# Reset the ad ladder for this run so the ladder math is
	# deterministic no matter how many times the suite ran today.
	var ad_count0 := Save.ad_count_today
	var ad_coins0 := Save.ad_coins_today
	var ad_date0 := Save.ad_date
	Save.ad_count_today = 0
	Save.ad_coins_today = 0
	Save.ad_date = Save.today_str()
	Save.save()
	var coins0 := Save.coins
	# --- Win 1: pot 200 held, then 2 double ads -> 400 + ladder ---
	await _force_online_win(100, 100)
	var m1 = _main._match
	_check("win1: match exists", m1 != null)
	if m1 == null:
		_finish()
		return
	_check("win1: pot held (not credited yet)", Save.coins == coins0 and m1._pot_pending == 200 and not m1._pot_credited)
	_check("win1: COLLECT shows ◉ 200 big", _find_label(_main, "◉ 200") != null)
	_check("win1: DOUBLE shows ◉ 400", _find_label(_main, "DOUBLE TO ◉ 400") != null)
	_check("win1: double button exists", m1._double_button != null)
	var ladder1 := Save.ad_next_reward()
	_ad_earned = 0
	Ads.show_rewarded("double_win")
	await _wait_for_ads(1)
	_check("win1: first double ad earned", _ad_earned == 1 and m1._double_ads == 1)
	_check("win1: pot still held after 1 ad", not m1._pot_credited and m1._pot_pending == 200)
	var ladder2 := Save.ad_next_reward()
	Ads.show_rewarded("double_win")
	await _wait_for_ads(1)
	_check("win1: second double ad earned", _ad_earned == 2 and m1._double_ads == 2)
	var expected := coins0 + ladder1 + ladder2 + 400
	_check("win1: doubled pot + ladder credited", Save.coins == expected, "coins=%d expected=%d" % [Save.coins, expected])
	_check("win1: collect disabled after double", m1._collect_button != null and m1._collect_button.disabled)
	_check("win1: double button disabled after double", m1._double_button.disabled)
	# --- Win 2: COLLECT pays the base pot, double disabled ---
	var coins1 := Save.coins
	await _force_online_win(50, 50)
	var m2 = _main._match
	_check("win2: match exists", m2 != null)
	if m2 == null:
		_finish()
		return
	_check("win2: pot held (100)", m2._pot_pending == 100 and Save.coins == coins1)
	var collect_btn := _find_button_with_label(_main, "◉ 100")
	_check("win2: COLLECT button found", collect_btn != null)
	if collect_btn:
		collect_btn.pressed.emit()
		await _frames(2)
	_check("win2: COLLECT credits the base pot", Save.coins == coins1 + 100, "coins=%d expected=%d" % [Save.coins, coins1 + 100])
	_check("win2: double disabled after collect", m2._double_button == null or m2._double_button.disabled)
	# --- Win 3: leaving without collecting still credits the base pot ---
	var coins2 := Save.coins
	await _force_online_win(50, 50)
	var m3 = _main._match
	_check("win3: match exists", m3 != null)
	if m3 == null:
		_finish()
		return
	var home_btn := _find_button(_main, "HOME")
	_check("win3: HOME button found", home_btn != null)
	if home_btn:
		home_btn.pressed.emit()
		await _frames(2)
	_check("win3: exit credits the base pot (never lost)", Save.coins == coins2 + 100, "coins=%d expected=%d" % [Save.coins, coins2 + 100])
	# --- Win 4 (v8 tour): a real World Tour match — stake locked at
	# start, pot held on the win, DOUBLE to 400 with 2 ads + ladder.
	var coins3 := Save.coins
	var tour0 := Save.tour_wins
	Save.interstitial_counter = 0
	_main._start_tour_match(WorldTour.BOTS[0], 100)
	await _wait_for_match()
	var m4 = _main._match
	_check("tour: match exists", m4 != null)
	if m4 == null:
		_finish()
		return
	_check("tour: stake locked at match start", Save.coins == coins3 - 100, "coins=%d expected=%d" % [Save.coins, coins3 - 100])
	_check("tour: mode is tour, opponent is a BOT", m4.mode == "tour" and String(m4.opponent_name).contains("(BOT)"), m4.opponent_name)
	m4.rules_state["over"] = true
	m4.rules_state["winner"] = 0
	m4._show_result()
	await _frames(3)
	_check("tour: pot held (200)", m4._pot_pending == 200 and not m4._pot_credited and Save.coins == coins3 - 100)
	_check("tour: COLLECT shows ◉ 200", _find_label(_main, "◉ 200") != null)
	_check("tour: DOUBLE shows ◉ 400", _find_label(_main, "DOUBLE TO ◉ 400") != null)
	_check("tour: win screen names the bot", _find_label(_main, "World Tour — you beat Arjun Mehta (BOT)") != null)
	_check("tour: tour_wins incremented", Save.tour_wins == tour0 + 1)
	var ladder3 := Save.ad_next_reward()
	_ad_earned = 0
	Ads.show_rewarded("double_win")
	await _wait_for_ads(1)
	_check("tour: first double ad earned", _ad_earned == 1 and m4._double_ads == 1)
	_check("tour: pot still held after 1 ad", not m4._pot_credited and m4._pot_pending == 200)
	var ladder4 := Save.ad_next_reward()
	Ads.show_rewarded("double_win")
	await _wait_for_ads(1)
	var expected4 := coins3 - 100 + ladder3 + ladder4 + 400
	_check("tour: doubled pot + ladder credited", Save.coins == expected4, "coins=%d expected=%d" % [Save.coins, expected4])
	_check("tour: collect disabled after double", m4._collect_button != null and m4._collect_button.disabled)
	# --- Loss (v8 tour): losing costs the stake; the loss screen names the bot.
	var coins4 := Save.coins
	var tour_wins_before := Save.tour_wins
	Save.interstitial_counter = 0
	_main._start_tour_match(WorldTour.BOTS[0], 100)
	await _wait_for_match()
	var m5 = _main._match
	_check("tour loss: match exists", m5 != null)
	if m5 == null:
		_finish()
		return
	_check("tour loss: stake locked at match start", Save.coins == coins4 - 100)
	m5.rules_state["over"] = true
	m5.rules_state["winner"] = 1
	m5._show_result()
	await _frames(3)
	_check("tour loss: stake stays lost (no refund)", Save.coins == coins4 - 100, "coins=%d expected=%d" % [Save.coins, coins4 - 100])
	_check("tour loss: loss screen names the bot", _find_label_containing(_main, "World Tour loss — Arjun Mehta (BOT) wins your stake ◉ 100") != null)
	_check("tour loss: tour_wins unchanged", Save.tour_wins == tour_wins_before)
	# --- Solo win (v8): zero coins without an ad; WATCH 1 AD earns the ladder.
	var coins5 := Save.coins
	var solo0 := Save.solo_wins
	Save.interstitial_counter = 0
	_main._start_solo(1)
	await _wait_for_match()
	var m6 = _main._match
	_check("solo: match exists", m6 != null)
	if m6 == null:
		_finish()
		return
	m6.rules_state["over"] = true
	m6.rules_state["winner"] = 0
	m6._show_result()
	await _frames(3)
	_check("solo: win pays zero coins without an ad", Save.coins == coins5, "coins=%d expected=%d" % [Save.coins, coins5])
	_check("solo: solo_wins incremented", Save.solo_wins == solo0 + 1)
	_check("solo: practice win note shown", _find_label(_main, "Practice win — no coins earned.") != null)
	var ladder5 := Save.ad_next_reward()
	_check("solo: WATCH 1 AD offer shown", _find_label(_main, "WATCH 1 AD") != null)
	_check("solo: EARN shows the ladder amount", _find_label(_main, "EARN ◉ %d" % ladder5) != null)
	_check("solo: earn button exists", m6._solo_earn_button != null)
	_ad_earned = 0
	if m6._solo_earn_button != null:
		m6._solo_earn_button.pressed.emit()
	await _wait_for_ads(1)
	_check("solo: ad earned the ladder amount", Save.coins == coins5 + ladder5, "coins=%d expected=%d" % [Save.coins, coins5 + ladder5])
	_check("solo: earn button disabled after the ad", m6._solo_earn_button != null and m6._solo_earn_button.disabled)
	# Restore the sandbox save so later runs start clean.
	Save.coins = coins0
	Save.ad_count_today = ad_count0
	Save.ad_coins_today = ad_coins0
	Save.ad_date = ad_date0
	Save.save()
	_finish()

## Wait until the current match exists and is in the "place" phase
## (up to 4 s — the AI may shoot first, the forced result still works).
func _wait_for_match() -> void:
	var waited := 0.0
	while waited < 4.0:
		await get_tree().create_timer(0.25).timeout
		waited += 0.25
		if _main._match != null and _main._match.phase == "place":
			return

func _wait_for_ads(count: int) -> void:
	var target := _ad_earned + count
	var waited := 0.0
	while _ad_earned < target and waited < 10.0:
		await get_tree().create_timer(0.2).timeout
		waited += 0.2

func _finish() -> void:
	_done = true
	print("=== win-double test: %d passed, %d failed ===" % [_passed, _failed])
	get_tree().quit(0 if _failed == 0 else 1)
