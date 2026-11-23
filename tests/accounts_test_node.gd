extends Node

## Accounts + friends pure-logic test (v7). Scene-based (not the -s
## runner) because accounts.gd / friends.gd reference the Save and
## Supabase autoload singletons, which do not exist in the -s runner's
## context — the scripts fail to compile there. Here the project loads
## normally with all autoloads, so the statics are callable.
## Covers: display-name / Gmail validation, last-write-wins profile
## resolve, uuid shape, invite group state machine, group players
## order, invite expiry. No network, no Supabase project needed.
## Run headless: godot --headless --path . res://tests/accounts_test.tscn
## Exit 0 = all pass, 1 = any fail.

var _passed := 0
var _failed := 0
var _failures: Array = []

func _ready() -> void:
	print("=== BMS Carrom accounts tests ===")
	_test_accounts_validation()
	_test_accounts_resolve()
	_test_accounts_uuid()
	_test_friends_groups()
	_test_friends_expiry()
	_test_accounts_local_profile_row()
	_test_accounts_sign_out_and_reregister()
	_test_supabase_bad_config()
	print("=== %d passed, %d failed ===" % [_passed, _failed])
	for f in _failures:
		print("FAIL: ", f)
	get_tree().quit(0 if _failed == 0 else 1)

func _check(name: String, cond: bool, detail: String = "") -> void:
	if cond:
		_passed += 1
		print("PASS: ", name)
	else:
		_failed += 1
		_failures.append(name + (" — " + detail if detail != "" else ""))
		print("FAIL: ", name, (" — " + detail if detail != "" else ""))

func _test_accounts_validation() -> void:
	_check("v7 acct: empty name rejected", Accounts.valid_display_name("") != "")
	_check("v7 acct: 1-char name rejected", Accounts.valid_display_name("A") != "")
	_check("v7 acct: 2-char name accepted", Accounts.valid_display_name("Bo") == "")
	_check("v7 acct: 21-char name rejected", Accounts.valid_display_name("ABCDEFGHIJKLMNOPQRSTU") != "")
	_check("v7 acct: normal name accepted", Accounts.valid_display_name("Nimal Perera") == "")
	_check("v7 acct: empty gmail rejected", Accounts.valid_gmail("") != "")
	_check("v7 acct: no @ rejected", Accounts.valid_gmail("nimal") != "")
	_check("v7 acct: non-gmail rejected", Accounts.valid_gmail("nimal@yahoo.com") != "")
	_check("v7 acct: gmail accepted", Accounts.valid_gmail("nimal@gmail.com") == "")
	_check("v7 acct: googlemail accepted", Accounts.valid_gmail("nimal@googlemail.com") == "")
	_check("v7 acct: gmail with spaces rejected", Accounts.valid_gmail("nimal @gmail.com") != "")
	_check("v7 acct: gmail upper-case accepted", Accounts.valid_gmail("Nimal@GMAIL.COM") == "")

func _test_accounts_resolve() -> void:
	var local := {"coins": 1200, "updated_at": "2026-11-22T10:00:00+00:00"}
	var cloud := {"coins": 900, "updated_at": "2026-11-22T12:00:00+00:00"}
	_check("v7 acct: newer cloud row wins", int(Accounts.resolve_profile(local, cloud).get("coins", 0)) == 900)
	var local_new := {"coins": 1200, "updated_at": "2026-11-22T12:00:00+00:00"}
	var cloud_old := {"coins": 900, "updated_at": "2026-11-22T10:00:00+00:00"}
	_check("v7 acct: newer local row wins", int(Accounts.resolve_profile(local_new, cloud_old).get("coins", 0)) == 1200)
	_check("v7 acct: empty local -> cloud", Accounts.resolve_profile({}, cloud) == cloud)
	_check("v7 acct: empty cloud -> local", Accounts.resolve_profile(local, {}) == local)
	_check("v7 acct: missing stamps -> cloud", int(Accounts.resolve_profile({"coins": 5}, {"coins": 7}).get("coins", 0)) == 7)
	_check("v7 acct: tie -> cloud", int(Accounts.resolve_profile(local, local).get("coins", 0)) == 1200)

func _test_accounts_uuid() -> void:
	var a: String = Accounts.generate_uuid()
	var b: String = Accounts.generate_uuid()
	_check("v7 acct: uuid is 36 chars", a.length() == 36)
	_check("v7 acct: uuid has dashes at 8/13/18/23", a[8] == "-" and a[13] == "-" and a[18] == "-" and a[23] == "-")
	_check("v7 acct: uuid version 4", a[14] == "4")
	_check("v7 acct: two uuids differ", a != b)

func _test_friends_groups() -> void:
	var waiting := [
		{"status": "pending"}, {"status": "pending"}, {"status": "pending"}]
	_check("v7 fr: all pending -> waiting", Friends.group_state(waiting) == "waiting")
	var ready := [
		{"status": "accepted"}, {"status": "accepted"}, {"status": "accepted"}]
	_check("v7 fr: all accepted -> ready", Friends.group_state(ready) == "ready")
	var mixed := [
		{"status": "accepted"}, {"status": "pending"}, {"status": "accepted"}]
	_check("v7 fr: one pending -> still waiting", Friends.group_state(mixed) == "waiting")
	var declined := [
		{"status": "accepted"}, {"status": "declined"}, {"status": "pending"}]
	_check("v7 fr: one declined -> failed", Friends.group_state(declined) == "failed")
	_check("v7 fr: empty group -> unknown", Friends.group_state([]) == "unknown")
	var players: Array = Friends.group_players(
		[{"to_id": "u2", "to_name": "Nimal"}, {"to_id": "u3", "to_name": "Saman"}],
		"u1", "Me")
	_check("v7 fr: group players — inviter first, then invitees", players.size() == 3 and String(players[0].get("name", "")) == "Me" and String(players[1].get("name", "")) == "Nimal" and String(players[2].get("name", "")) == "Saman")

func _test_friends_expiry() -> void:
	var now := Time.get_unix_time_from_system()
	var fresh := {"created_at": Time.get_datetime_string_from_unix_time(now - 3600, true).replace(" ", "T") + "+00:00"}
	_check("v7 fr: 1-hour-old invite is not expired", not Friends.is_expired(fresh))
	var old := {"created_at": Time.get_datetime_string_from_unix_time(now - 25 * 3600, true).replace(" ", "T") + "+00:00"}
	_check("v7 fr: 25-hour-old invite is expired", Friends.is_expired(old))
	_check("v7 fr: missing timestamp never expires (unknown)", not Friends.is_expired({}))
	var age: int = Friends.invite_age_seconds(fresh)
	_check("v7 fr: age is about 3600 s", age >= 3500 and age <= 3700)

func _test_accounts_local_profile_row() -> void:
	# F6: the local row's updated_at is an ISO string in the same shape
	# as the cloud's — never the old "YYYY-MM-DD HH:MM:SS" form that
	# always lost to the cloud's "T" form on the same day.
	# Reset ALL progress fields first: the save file may hold leftovers
	# from earlier test runs, and the "fresh defaults" check below must
	# start from real defaults, not whatever was on disk.
	Save.account_synced_at = 0
	Save.coins = 1000
	Save.xp = 0
	Save.matches_played = 0
	Save.matches_won = 0
	Save.solo_wins = 0
	Save.online_wins = 0
	Save.tour_wins = 0
	Save.queens_covered = 0
	Save.owned_boards = ["classic"]
	Save.owned_strikers = ["classic"]
	Save.equipped_board = "classic"
	Save.equipped_striker = "classic"
	Save.coins = 1500 # real progress, never synced
	Save.save()
	var row: Dictionary = Accounts.local_profile_row()
	var stamp := String(row.get("updated_at", ""))
	_check("v10 acct: local row carries an ISO updated_at", stamp.contains("T") and stamp.ends_with("+00:00"), stamp)
	_check("v10 acct: local row keeps the local coins", int(row.get("coins", 0)) == 1500)
	# Synced just now and nothing saved since -> no stamp (cloud wins).
	Save.account_synced_at = int(Time.get_unix_time_from_system())
	Save.save()
	var row2: Dictionary = Accounts.local_profile_row()
	_check("v10 acct: unchanged-since-sync local row has no stamp", String(row2.get("updated_at", "")) == "")
	# Same-day, later local stamp beats the cloud row — the exact F6
	# regression (the old space-vs-T comparison made this always lose).
	var local := {"coins": 1200, "updated_at": "2026-11-22T15:00:00+00:00"}
	var cloud := {"coins": 900, "updated_at": "2026-11-22T12:00:00+00:00"}
	_check("v10 acct: same-day newer local row wins", int(Accounts.resolve_profile(local, cloud).get("coins", 0)) == 1200)
	# Fresh-install defaults, never synced -> no stamp: a reinstall
	# must restore the cloud progress, not overwrite it with the
	# 1,000 starting coins.
	Save.account_synced_at = 0
	Save.coins = 1000
	Save.xp = 0
	Save.matches_played = 0
	Save.matches_won = 0
	Save.online_wins = 0
	Save.tour_wins = 0
	Save.queens_covered = 0
	Save.owned_boards = ["classic"]
	Save.owned_strikers = ["classic"]
	Save.save()
	var row3: Dictionary = Accounts.local_profile_row()
	_check("v10 acct: fresh-default local row has no stamp", String(row3.get("updated_at", "")) == "")

func _test_accounts_sign_out_and_reregister() -> void:
	# F7: seed a rich verified account, then prove register-over-it is
	# refused and sign-out resets everything to a fresh install.
	Save.player_name = "Rich Player"
	Save.account_gmail = "rich@gmail.com"
	Save.account_id = "user-rich"
	Save.account_verified = true
	Save.account_synced_at = int(Time.get_unix_time_from_system())
	Save.coins = 5000
	Save.xp = 2500
	Save.matches_played = 10
	Save.matches_won = 6
	Save.online_wins = 3
	Save.queens_covered = 2
	Save.owned_boards = ["classic", "bms"]
	Save.owned_strikers = ["classic", "gold"]
	Save.equipped_board = "bms"
	Save.equipped_striker = "gold"
	Save.daily_streak = 4
	Save.ad_count_today = 3
	Save.aim_assist_until = int(Time.get_unix_time_from_system()) + 3600
	Save.save()
	var refused: Dictionary = Accounts.register_player("Someone Else", "other@gmail.com")
	_check("v10 acct: register over a verified account is refused", not bool(refused.get("ok", false)))
	_check("v10 acct: refused register keeps the old account", Save.account_gmail == "rich@gmail.com" and Save.coins == 5000)
	Accounts.sign_out()
	_check("v10 acct: sign out clears the gmail + verified flag", not Accounts.has_account() and not Accounts.is_verified())
	_check("v10 acct: sign out resets coins to starting 1000", Save.coins == 1000)
	_check("v10 acct: sign out resets xp + stats", Save.xp == 0 and Save.matches_played == 0 and Save.matches_won == 0 and Save.online_wins == 0 and Save.queens_covered == 0)
	_check("v10 acct: sign out resets shop to classic only", (Save.owned_boards as Array) == ["classic"] and (Save.owned_strikers as Array) == ["classic"] and Save.equipped_board == "classic" and Save.equipped_striker == "classic")
	_check("v10 acct: sign out resets the name to Player", Save.player_name == "Player")
	_check("v10 acct: sign out resets daily + ads state", Save.daily_streak == 0 and Save.ad_count_today == 0 and Save.aim_assist_until == 0)
	# After sign-out, registering works again.
	var ok: Dictionary = Accounts.register_player("New Player", "new@gmail.com")
	_check("v10 acct: register works after sign-out", bool(ok.get("ok", false)) and Save.account_gmail == "new@gmail.com")
	# Leave a clean, signed-out state behind (same as a fresh install).
	Accounts.sign_out()

func _test_supabase_bad_config() -> void:
	# L8: a malformed backend_config.json falls back to local-only with
	# no script error (JSON.parse_string returns null on bad JSON, and
	# a JSON array is valid JSON but not a config object).
	var bad_path := "user://test_bad_config.json"
	var f := FileAccess.open(bad_path, FileAccess.WRITE)
	f.store_string("{not json,,,")
	f.close()
	Supabase.load_config(bad_path)
	_check("v10 supa: malformed config -> not configured, no crash", not Supabase.configured)
	var f2 := FileAccess.open(bad_path, FileAccess.WRITE)
	f2.store_string("[1, 2, 3]")
	f2.close()
	Supabase.load_config(bad_path)
	_check("v10 supa: JSON array config -> not configured, no crash", not Supabase.configured)
	# Restore the real config.
	DirAccess.remove_absolute(ProjectSettings.globalize_path(bad_path))
	Supabase.load_config()
	_check("v10 supa: real config reloads after the bad file", Supabase.configured)
