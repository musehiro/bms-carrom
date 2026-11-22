extends Node

## Save — autoload. Local persistence for coins, XP, level, shop items,
## settings, daily streak, aim-assist and match stats.
## File: user://bms_carrom_save.cfg (Godot ConfigFile).

const SAVE_PATH := "user://bms_carrom_save.cfg"

# Economy (design doc 6.3).
const STARTING_COINS := 1000
const SOLO_WIN_COINS := {0: 50, 1: 100, 2: 200} # Easy / Medium / Hard
const SOLO_LOSS_COINS := 10
const ONLINE_ENTRY := {0: 100, 1: 500, 2: 2000} # Low / Mid / High
const QUEEN_BONUS_COINS := 50
const LEVEL_UP_COINS := 500
const COMEBACK_COINS := 500
const XP_PER_MATCH := 100
const XP_PER_WIN := 50
const XP_PER_QUEEN := 25
const XP_PER_LEVEL := 500
const GUIDE_OFF_WIN_BONUS := 50

var coins: int = STARTING_COINS
var xp: int = 0
var matches_played: int = 0
var matches_won: int = 0
var solo_wins: int = 0
var online_wins: int = 0
var queens_covered: int = 0
var owned_boards: Array = ["classic"]
var owned_strikers: Array = ["classic"]
var equipped_board: String = "classic"
var equipped_striker: String = "classic"
var aim_guide: String = "full" # full | basic | off
var sound_on: bool = true
var player_name: String = "Player"
var daily_streak: int = 0
var last_daily_claim: String = "" # YYYY-MM-DD
var rewarded_ads_today: int = 0
var rewarded_ads_date: String = ""
var aim_assist_until: int = 0 # unix time; 0 = inactive
var aim_assist_ads_progress: int = 0 # 0..1 ads watched toward next hour
var last_comeback_date: String = ""
var interstitial_counter: int = 0 # matches since last interstitial
var online_host: String = "127.0.0.1" # matchmaking server; set a real host in Settings

var _cfg := ConfigFile.new()

func _ready() -> void:
	load_save()

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
	queens_covered = int(_cfg.get_value("player", "queens_covered", 0))
	owned_boards = _cfg.get_value("shop", "owned_boards", ["classic"])
	owned_strikers = _cfg.get_value("shop", "owned_strikers", ["classic"])
	equipped_board = String(_cfg.get_value("shop", "equipped_board", "classic"))
	equipped_striker = String(_cfg.get_value("shop", "equipped_striker", "classic"))
	aim_guide = String(_cfg.get_value("settings", "aim_guide", "full"))
	sound_on = bool(_cfg.get_value("settings", "sound_on", true))
	player_name = String(_cfg.get_value("settings", "player_name", "Player"))
	daily_streak = int(_cfg.get_value("daily", "streak", 0))
	last_daily_claim = String(_cfg.get_value("daily", "last_claim", ""))
	rewarded_ads_today = int(_cfg.get_value("ads", "rewarded_today", 0))
	rewarded_ads_date = String(_cfg.get_value("ads", "rewarded_date", ""))
	aim_assist_until = int(_cfg.get_value("ads", "aim_assist_until", 0))
	aim_assist_ads_progress = int(_cfg.get_value("ads", "aim_assist_ads_progress", 0))
	last_comeback_date = String(_cfg.get_value("player", "last_comeback", ""))
	interstitial_counter = int(_cfg.get_value("ads", "interstitial_counter", 0))
	online_host = String(_cfg.get_value("online", "host", "127.0.0.1"))

func save() -> void:
	_cfg.set_value("player", "coins", coins)
	_cfg.set_value("player", "xp", xp)
	_cfg.set_value("player", "matches_played", matches_played)
	_cfg.set_value("player", "matches_won", matches_won)
	_cfg.set_value("player", "solo_wins", solo_wins)
	_cfg.set_value("player", "online_wins", online_wins)
	_cfg.set_value("player", "queens_covered", queens_covered)
	_cfg.set_value("player", "last_comeback", last_comeback_date)
	_cfg.set_value("shop", "owned_boards", owned_boards)
	_cfg.set_value("shop", "owned_strikers", owned_strikers)
	_cfg.set_value("shop", "equipped_board", equipped_board)
	_cfg.set_value("shop", "equipped_striker", equipped_striker)
	_cfg.set_value("settings", "aim_guide", aim_guide)
	_cfg.set_value("settings", "sound_on", sound_on)
	_cfg.set_value("settings", "player_name", player_name)
	_cfg.set_value("daily", "streak", daily_streak)
	_cfg.set_value("daily", "last_claim", last_daily_claim)
	_cfg.set_value("ads", "rewarded_today", rewarded_ads_today)
	_cfg.set_value("ads", "rewarded_date", rewarded_ads_date)
	_cfg.set_value("ads", "aim_assist_until", aim_assist_until)
	_cfg.set_value("ads", "aim_assist_ads_progress", aim_assist_ads_progress)
	_cfg.set_value("ads", "interstitial_counter", interstitial_counter)
	_cfg.set_value("online", "host", online_host)
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

## Returns coins earned from levelling up (0 if no level-up).
func add_xp(n: int) -> int:
	var before := level()
	xp += n
	var after := level()
	var bonus := 0
	if after > before:
		bonus = LEVEL_UP_COINS * (after - before)
		coins += bonus
	save()
	return bonus

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

func rewarded_ads_left_today() -> int:
	if rewarded_ads_date != today_str():
		rewarded_ads_today = 0
		rewarded_ads_date = today_str()
		save()
	return maxi(0, AdsConfig.REWARDED_COINS_MAX_PER_DAY - rewarded_ads_today)

func record_rewarded_ad_watched() -> void:
	if rewarded_ads_date != today_str():
		rewarded_ads_today = 0
		rewarded_ads_date = today_str()
	rewarded_ads_today += 1
	save()

## Daily login bonus: +200 day 1, +50/day up to +500 at day 7 streak.
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

## Anti-broke rule: below the lowest entry fee (100) the player gets a free
## 500-coin top-up once per day.
func maybe_comeback_coins() -> int:
	if coins >= 100:
		return 0
	if last_comeback_date == today_str():
		return 0
	last_comeback_date = today_str()
	coins += COMEBACK_COINS
	save()
	return COMEBACK_COINS
