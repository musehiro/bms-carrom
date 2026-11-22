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
