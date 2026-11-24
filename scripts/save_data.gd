extends Node

## Save — autoload. Local persistence for coins, XP, level, shop items,
## settings, daily streak, aim-assist and match stats.
## File: user://bms_carrom_save.cfg (Godot ConfigFile).

const SAVE_PATH := "user://bms_carrom_save.cfg"

# Economy (v5, design doc 6.3 — Buddhika 2026-11-22):
# The ONLY coin sources are the rewarded-ad ladder and online-match
# stakes. Solo vs AI is free practice and pays ZERO coins, win or lose.
# No free grants anywhere: no comeback coins, no level-up coins, and the
# daily bonus is only claimable by watching an ad. At zero coins the only
# way back is watching ads (the ladder).
const STARTING_COINS := 1000
const XP_PER_MATCH := 100
const XP_PER_WIN := 50
const XP_PER_QUEEN := 25
const XP_PER_LEVEL := 500

# Rewarded-ad ladder: per-ad coin payout grows with each ad watched
# today — 1st +150, 2nd +200, 3rd +250, 4th +300, 5th and beyond +400.
# Resets at midnight (local day). Total rewarded-ad coins are capped at
# 2,500/day (exactly 8 ads: 150+200+250+300+400*4), so the ladder cannot
# be farmed without limit.
const AD_LADDER := [150, 200, 250, 300, 400]
const DAILY_AD_COIN_CAP := 2500

var coins: int = STARTING_COINS
var xp: int = 0
var matches_played: int = 0
var matches_won: int = 0
var solo_wins: int = 0
var online_wins: int = 0
var tour_wins: int = 0 # v8: World Tour (advanced bot) wins — staked, like online
var queens_covered: int = 0
var win_streak: int = 0 # Play Games "Hat-Trick": consecutive wins (reset on loss/draw)
var total_coins_pocketed: int = 0 # Play Games "Sharpshooter": coins pocketed across all matches
var match_points: int = 0 # v11: lifetime ONLINE match points (win +3, draw +1, loss +0)
var online_draws: int = 0 # v11: online draws (each pays +1 match point)
# F9 (match.gd): a win pot held on the win screen, persisted so killing
# the app there does not lose it; cleared once credited/collected.
var pending_pot: int = 0
var owned_boards: Array = ["classic"]
var owned_strikers: Array = ["classic"]
var equipped_board: String = "classic"
var equipped_striker: String = "classic"
var aim_guide: String = "full" # full | basic | off
var sound_on: bool = true
var player_name: String = "Player"
var daily_streak: int = 0
var last_daily_claim: String = "" # YYYY-MM-DD
var ad_count_today: int = 0 # rewarded ads watched today (ladder position)
var ad_coins_today: int = 0 # ladder coins earned today (capped)
var ad_date: String = "" # YYYY-MM-DD the ad counters belong to
var aim_assist_until: int = 0 # unix time; 0 = inactive
var aim_assist_ads_progress: int = 0 # 0..1 ads watched toward next hour
var interstitial_counter: int = 0 # matches since last interstitial
var online_host: String = "127.0.0.1" # LEGACY (v11): the old ENet matchmaking server host. Kept in the save for compatibility; ONLINE now plays over P2P/WebRTC and no longer reads this. The legacy path stays behind the transport switch in net_client.gd for one version (rollback).
var consumed_invite_groups: Array = [] # v11: invite group_ids whose
## group_ready already fired (the inviter joined). refresh() skips
## them — the rows stay "accepted" on the server forever, so without
## this every app restart would re-fire group_ready for every
## completed invite and re-join a dead room. Capped at 50 (trimmed
## on append); group_ids are UUIDs, never reused.
var ads_policy_version: int = 0 # ads policy applied (v9 = 9): < 9 -> the
# interstitial counter resets on first v9 launch, so a player who already
# played in v7/v8 does not get a full-screen ad after their first v9 match.
var google_pkce_verifier: String = "" # PKCE verifier of the pending Google
# sign-in — persisted so the exchange can still complete if the app is
# killed while the browser is open (deep-link cold start).
var google_pkce_deadline: int = 0 # unix time; 0 = no Google sign-in pending
# v10: ONE pending browser return, Google or OTP magic link (the unified
# return slot — see Accounts). google_pkce_* above is the v9 legacy
# slot, still read on resume for installs that started a Google
# sign-in under v9.
var pending_return_verifier: String = "" # PKCE verifier of the pending return
var pending_return_deadline: int = 0 # unix time; 0 = no return pending
var pending_return_kind: String = "" # "google" | "otp_link"

# Account (v7, mandatory registration — NO guest mode). A player cannot
# play without registering (display name + Gmail). The account id is the
# Supabase Auth user id once synced; before the first sync it is a local
# uuid placeholder. The cloud profile (coins, XP, stats, shop) is the
# restore source after a reinstall.
var account_gmail: String = ""
var account_id: String = ""
var account_verified: bool = false
var account_created_at: String = "" # YYYY-MM-DD
var account_synced_at: int = 0 # unix time of the last successful cloud sync

var _cfg := ConfigFile.new()

func _ready() -> void:
	load_save()

## Ads-policy migration (v9) — pure, unit-tested. A save written by an
## older policy version resets the interstitial counter, so a player who
## already played in v7/v8 does not get a full-screen ad after their
## first v9 match. Returns {"counter": ..., "policy_version": ...}.
const ADS_POLICY_VERSION := 9

static func migrated_ads_policy(policy_version: int, counter: int) -> Dictionary:
	if policy_version < ADS_POLICY_VERSION:
		return {"counter": 0, "policy_version": ADS_POLICY_VERSION}
	return {"counter": counter, "policy_version": policy_version}

func load_save() -> void:
	var err := _cfg.load(SAVE_PATH)
	if err != OK:
		return # fresh install: defaults stand
	coins = int(_cfg.get_value("player", "coins", STARTING_COINS))
	xp = int(_cfg.get_value("player", "xp", 0))
	matches_played = int(_cfg.get_value("player", "matches_played", 0))
	matches_won = int(_cfg.get_value("player", "matches_won", 0))
	solo_wins = int(_cfg.get_value("player", "solo_wins", 0))
	online_wins = int(_cfg.get_value("player", "online_wins", 0))
	tour_wins = int(_cfg.get_value("player", "tour_wins", 0))
	queens_covered = int(_cfg.get_value("player", "queens_covered", 0))
	win_streak = int(_cfg.get_value("player", "win_streak", 0))
	match_points = int(_cfg.get_value("player", "match_points", 0))
	online_draws = int(_cfg.get_value("player", "online_draws", 0))
	total_coins_pocketed = int(_cfg.get_value("player", "total_coins_pocketed", 0))
	pending_pot = int(_cfg.get_value("player", "pending_pot", 0))
	owned_boards = _cfg.get_value("shop", "owned_boards", ["classic"])
	owned_strikers = _cfg.get_value("shop", "owned_strikers", ["classic"])
	equipped_board = String(_cfg.get_value("shop", "equipped_board", "classic"))
	equipped_striker = String(_cfg.get_value("shop", "equipped_striker", "classic"))
	aim_guide = String(_cfg.get_value("settings", "aim_guide", "full"))
	sound_on = bool(_cfg.get_value("settings", "sound_on", true))
	player_name = String(_cfg.get_value("settings", "player_name", "Player"))
	daily_streak = int(_cfg.get_value("daily", "streak", 0))
	last_daily_claim = String(_cfg.get_value("daily", "last_claim", ""))
	ad_count_today = int(_cfg.get_value("ads", "ad_count_today", 0))
	ad_coins_today = int(_cfg.get_value("ads", "ad_coins_today", 0))
	ad_date = String(_cfg.get_value("ads", "ad_date", ""))
	aim_assist_until = int(_cfg.get_value("ads", "aim_assist_until", 0))
	aim_assist_ads_progress = int(_cfg.get_value("ads", "aim_assist_ads_progress", 0))
	interstitial_counter = int(_cfg.get_value("ads", "interstitial_counter", 0))
	ads_policy_version = int(_cfg.get_value("ads", "policy_version", 0))
	var mig := migrated_ads_policy(ads_policy_version, interstitial_counter)
	interstitial_counter = int(mig["counter"])
	ads_policy_version = int(mig["policy_version"])
	online_host = String(_cfg.get_value("online", "host", "127.0.0.1"))
	consumed_invite_groups = _cfg.get_value("online", "consumed_invite_groups", [])
	account_gmail = String(_cfg.get_value("account", "gmail", ""))
	account_id = String(_cfg.get_value("account", "id", ""))
	account_verified = bool(_cfg.get_value("account", "verified", false))
	account_created_at = String(_cfg.get_value("account", "created_at", ""))
	account_synced_at = int(_cfg.get_value("account", "synced_at", 0))
	google_pkce_verifier = String(_cfg.get_value("account", "google_pkce_verifier", ""))
	google_pkce_deadline = int(_cfg.get_value("account", "google_pkce_deadline", 0))
	pending_return_verifier = String(_cfg.get_value("account", "pending_return_verifier", ""))
	pending_return_deadline = int(_cfg.get_value("account", "pending_return_deadline", 0))
	pending_return_kind = String(_cfg.get_value("account", "pending_return_kind", ""))

func save() -> void:
	_cfg.set_value("player", "coins", coins)
	_cfg.set_value("player", "xp", xp)
	_cfg.set_value("player", "matches_played", matches_played)
	_cfg.set_value("player", "matches_won", matches_won)
	_cfg.set_value("player", "solo_wins", solo_wins)
	_cfg.set_value("player", "online_wins", online_wins)
	_cfg.set_value("player", "tour_wins", tour_wins)
	_cfg.set_value("player", "queens_covered", queens_covered)
	_cfg.set_value("player", "win_streak", win_streak)
	_cfg.set_value("player", "match_points", match_points)
	_cfg.set_value("player", "online_draws", online_draws)
	_cfg.set_value("player", "total_coins_pocketed", total_coins_pocketed)
	_cfg.set_value("player", "pending_pot", pending_pot)
	_cfg.set_value("shop", "owned_boards", owned_boards)
	_cfg.set_value("shop", "owned_strikers", owned_strikers)
	_cfg.set_value("shop", "equipped_board", equipped_board)
	_cfg.set_value("shop", "equipped_striker", equipped_striker)
	_cfg.set_value("settings", "aim_guide", aim_guide)
	_cfg.set_value("settings", "sound_on", sound_on)
	_cfg.set_value("settings", "player_name", player_name)
	_cfg.set_value("daily", "streak", daily_streak)
	_cfg.set_value("daily", "last_claim", last_daily_claim)
	_cfg.set_value("ads", "ad_count_today", ad_count_today)
	_cfg.set_value("ads", "ad_coins_today", ad_coins_today)
	_cfg.set_value("ads", "ad_date", ad_date)
	_cfg.set_value("ads", "aim_assist_until", aim_assist_until)
	_cfg.set_value("ads", "aim_assist_ads_progress", aim_assist_ads_progress)
	_cfg.set_value("ads", "interstitial_counter", interstitial_counter)
	_cfg.set_value("ads", "policy_version", ads_policy_version)
	_cfg.set_value("online", "host", online_host)
	_cfg.set_value("online", "consumed_invite_groups", consumed_invite_groups)
	_cfg.set_value("account", "gmail", account_gmail)
	_cfg.set_value("account", "id", account_id)
	_cfg.set_value("account", "verified", account_verified)
	_cfg.set_value("account", "created_at", account_created_at)
	_cfg.set_value("account", "synced_at", account_synced_at)
	_cfg.set_value("account", "google_pkce_verifier", google_pkce_verifier)
	_cfg.set_value("account", "google_pkce_deadline", google_pkce_deadline)
	_cfg.set_value("account", "pending_return_verifier", pending_return_verifier)
	_cfg.set_value("account", "pending_return_deadline", pending_return_deadline)
	_cfg.set_value("account", "pending_return_kind", pending_return_kind)
	_cfg.save(SAVE_PATH)

func level() -> int:
	return xp / XP_PER_LEVEL + 1

func xp_into_level() -> int:
	return xp % XP_PER_LEVEL

func rank_name(lv: int = -1) -> String:
	if lv < 0:
		lv = level()
	if lv <= 4:
		return "Rookie"
	if lv <= 9:
		return "Bronze"
	if lv <= 14:
		return "Silver"
	if lv <= 19:
		return "Gold"
	if lv <= 29:
		return "Platinum"
	return "Diamond"

func win_rate() -> float:
	if matches_played == 0:
		return 0.0
	return float(matches_won) / float(matches_played) * 100.0

func add_coins(n: int) -> void:
	coins += n
	save()

func spend_coins(n: int) -> bool:
	if coins < n:
		return false
	coins -= n
	save()
	return true

## Returns the new level when the player levels up (0 otherwise).
## v5: level-ups pay NO coins — rank only. (Paying coins here would let a
## zero-balance player farm coins from XP earned in free solo matches.)
func add_xp(n: int) -> int:
	var before := level()
	xp += n
	var after := level()
	save()
	return after if after > before else 0

func aim_assist_active() -> bool:
	return Time.get_unix_time_from_system() < aim_assist_until

func aim_assist_remaining_sec() -> int:
	var left := aim_assist_until - int(Time.get_unix_time_from_system())
	return maxi(0, left)

func grant_aim_assist(hours: float = 1.0) -> void:
	var now := int(Time.get_unix_time_from_system())
	var base := maxi(now, aim_assist_until)
	aim_assist_until = mini(base + int(hours * 3600.0), now + AdsConfig.AIM_ASSIST_MAX_BANKED_SEC)
	save()

func today_str() -> String:
	var d := Time.get_date_dict_from_system()
	return "%04d-%02d-%02d" % [d["year"], d["month"], d["day"]]

## --- Rewarded-ad ladder (v5) -----------------------------------------
## Every rewarded ad watched pays the current tier and advances the ladder;
## the cap (2,500 coins/day) is the only limit. Ads watched for Aim-Assist
## or the Daily Bonus pay the ladder amount too, on top of unlocking that
## reward — one rule for every rewarded ad, so the player always knows
## what an ad is worth.

func _ad_reset_if_new_day() -> void:
	if ad_date != today_str():
		ad_count_today = 0
		ad_coins_today = 0
		ad_date = today_str()
		save()

## Coins the NEXT rewarded ad pays (0 when the daily cap is reached).
func ad_next_reward() -> int:
	_ad_reset_if_new_day()
	if ad_coins_today >= DAILY_AD_COIN_CAP:
		return 0
	return ad_reward_at(ad_count_today)

## The ladder amount for the Nth ad watched today (0-based count).
## Pure — lets a caller price two ads ahead (the win screen's
## "WATCH 2 ADS -> EARN" offer) without advancing the ladder.
func ad_reward_at(count: int) -> int:
	return AD_LADDER[mini(maxi(count, 0), AD_LADDER.size() - 1)]

func ad_cap_reached() -> bool:
	_ad_reset_if_new_day()
	return ad_coins_today >= DAILY_AD_COIN_CAP

## Current tier number for the ladder UI (1-based; 5 = "5th ad and beyond").
func ad_current_tier() -> int:
	_ad_reset_if_new_day()
	return mini(ad_count_today + 1, AD_LADDER.size())

func record_ad_reward(reward: int) -> void:
	_ad_reset_if_new_day()
	ad_count_today += 1
	ad_coins_today += reward
	save()

## Daily login bonus: +200 day 1, +50/day up to +500 at day 7 streak.
## v5: the bonus is ONLY claimable by watching a rewarded ad (the claim
## button opens an ad first) — there is no free coin grant anywhere.
func daily_bonus_amount() -> int:
	return mini(200 + (maxi(daily_streak, 1) - 1) * 50, 500)

func can_claim_daily() -> bool:
	return last_daily_claim != today_str()

func claim_daily() -> int:
	if not can_claim_daily():
		return 0
	var yesterday := Time.get_date_dict_from_system()
	# Streak continues only if last claim was yesterday; simplified: if the
	# stored date is not today and streak tracking is by consecutive days,
	# reset when the gap is > 1 day.
	if last_daily_claim == "":
		daily_streak = 1
	else:
		var last := Time.get_unix_time_from_datetime_string(last_daily_claim + "T00:00:00")
		var today := Time.get_unix_time_from_datetime_string(today_str() + "T00:00:00")
		if today - last <= 86400 + 60:
			daily_streak += 1
		else:
			daily_streak = 1
	daily_streak = mini(daily_streak, 7)
	var amount := daily_bonus_amount()
	last_daily_claim = today_str()
	coins += amount
	save()
	return amount
