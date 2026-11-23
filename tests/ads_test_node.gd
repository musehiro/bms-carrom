extends Node

## Ads gate test (v9): ZERO ads before registration, and the
## interstitial only after 3 completed matches.
## Phases:
##   1. No account -> show_rewarded fails (gate), maybe_show_interstitial
##      returns false, show_home_banner does nothing.
##   2. Account set -> show_rewarded earns (simulated), interstitial
##      blocked at counter 1 and 2, allowed at counter 3.
##   3. Migration: a save with policy_version 0 + counter 5 loads as
##      counter 0 + version 9 (save file backed up + restored).
## Run headless: godot --headless --path . res://tests/ads_test.tscn

const SAVE_PATH := "user://bms_carrom_save.cfg"

var _passed := 0
var _failed := 0
var _failures: Array = []
var _earned := false
var _failed_sig := false
var _saved_cfg := ""
var _had_save := false
var _done := false

func _ready() -> void:
	Ads.rewarded_earned.connect(_on_earned)
	Ads.rewarded_failed.connect(_on_failed)
	_run()

func _check(test_name: String, cond: bool, detail: String = "") -> void:
	if cond:
		_passed += 1
		print("PASS: ", test_name)
	else:
		_failed += 1
		_failures.append(test_name)
		print("FAIL: ", test_name, (" — " + detail if detail != "" else ""))

func _on_earned(_reason: String, _simulated: bool) -> void:
	_earned = true

func _on_failed(_reason: String) -> void:
	_failed_sig = true

func _wait_for_condition(cond: Callable, timeout_sec: float) -> bool:
	var deadline := Time.get_unix_time_from_system() + timeout_sec
	while Time.get_unix_time_from_system() < deadline:
		if bool(cond.call()):
			return true
		await get_tree().create_timer(0.1).timeout
	return bool(cond.call())

func _run() -> void:
	print("=== BMS Carrom ads gate tests (v9) ===")
	# Back up the real save file.
	_had_save = FileAccess.file_exists(SAVE_PATH)
	if _had_save:
		_saved_cfg = FileAccess.get_file_as_string(SAVE_PATH)
	# --- Phase 1: no account ---
	Save.account_gmail = ""
	Save.save()
	_earned = false
	_failed_sig = false
	Ads.show_rewarded("coins")
	await get_tree().create_timer(0.2).timeout
	_check("v9 ads: rewarded blocked before registration", _failed_sig and not _earned)
	_check("v9 ads: interstitial blocked before registration", not Ads.maybe_show_interstitial())
	Ads.show_home_banner()
	_check("v9 ads: banner not shown before registration", not Ads._banner_shown)
	# --- Phase 2: account set ---
	Save.account_gmail = "test.player@gmail.com"
	Save.save()
	_earned = false
	_failed_sig = false
	Ads.show_rewarded("coins")
	var got := await _wait_for_condition(func() -> bool: return _earned or _failed_sig, 5.0)
	_check("v9 ads: rewarded earns after registration", got and _earned and not _failed_sig)
	Save.interstitial_counter = 1
	_check("v9 ads: interstitial blocked at counter 1", not Ads.maybe_show_interstitial())
	Save.interstitial_counter = 2
	_check("v9 ads: interstitial blocked at counter 2", not Ads.maybe_show_interstitial())
	Save.interstitial_counter = 3
	_check("v9 ads: interstitial allowed at counter 3", Ads.maybe_show_interstitial())
	# --- Phase 3: migration ---
	var cfg := ConfigFile.new()
	cfg.set_value("ads", "interstitial_counter", 5)
	cfg.set_value("ads", "policy_version", 0)
	cfg.save(SAVE_PATH)
	Save.load_save()
	_check("v9 ads: old save migrates counter to 0", Save.interstitial_counter == 0)
	_check("v9 ads: old save migrates policy to 9", Save.ads_policy_version == 9)
	_finish()

func _finish() -> void:
	# Restore the real save file (the test mutated coins/account/counter).
	if _had_save:
		var f := FileAccess.open(SAVE_PATH, FileAccess.WRITE)
		if f:
			f.store_string(_saved_cfg)
			f.close()
		Save.load_save()
	elif FileAccess.file_exists(SAVE_PATH):
		DirAccess.remove_absolute(SAVE_PATH)
		Save.load_save()
	_done = true
	print("=== ads gate tests: %d passed, %d failed ===" % [_passed, _failed])
	for f in _failures:
		print("FAIL: ", f)
	get_tree().quit(0 if _failed == 0 else 1)
