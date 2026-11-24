class_name CoinLoop
extends RefCounted

## Broke-player coin loop (v11, Buddhika's design).
##
## The loop: broke (0 coins) -> free bot match and/or rewarded ad ->
## ladder coins -> back to staked online / friend matches.
##
## Nothing here invents new economy values. The ONLY coin grant on the
## loop is the existing rewarded-ad ladder (Save.AD_LADDER: 1st +150,
## 2nd +200, 3rd +250, 4th +300, 5th+ +400; cap 2,500/day). Solo vs AI
## still pays zero; the bot game is free practice and fun while the
## player earns, and the solo win screen's own WATCH AD offer
## ("solo_win") already pays the ladder too. The daily bonus is also
## unchanged — it pays even when the ladder cap is reached, so it is
## the last recovery rung on a capped day.
##
## MIN_STAKE is NOT a new economy rule and does NOT change staking:
## Stakes.valid_stake(0, balance) is still true, so 0-stake friendly
## matches stay open to a broke player. MIN_STAKE is only the loop's
## definition of "back in staked play" — the smallest non-zero stake
## the stake picker offers in one tap (UiKit.stake_picker quick
## amounts: 0 / 50 / 100 / 500 / ALL IN). One first-rung ad (+150)
## always covers it, so a single ad is always enough to re-enter
## staked matchmaking on a fresh day.
##
## Pure logic: every function takes explicit state (balance, today's ad
## counters) and reads only Save's ladder constants — no Save mutation,
## no UI, no Ads calls — so it is unit-testable (tests/coin_loop_test.gd).

## Smallest non-zero quick-pick stake in the stake picker.
const MIN_STAKE := 50
## Rewarded-ad reason for an ad watched from the broke panel. It pays
## the normal ladder (main.gd handles it like "coins") and, unlike
## "coins", tells main.gd the player came from the broke flow so it can
## offer the return to matchmaking once the balance covers MIN_STAKE.
const BROKE_REASON := "broke_coins"

static func is_broke(balance: int) -> bool:
	return balance <= 0

## "Back in staked play": the balance covers the minimum stake.
static func can_stake(balance: int) -> bool:
	return balance >= MIN_STAKE

## Coins still needed to reach the minimum stake (0 when already there).
static func coins_needed(balance: int) -> int:
	return maxi(0, MIN_STAKE - balance)

static func ad_cap_reached(ad_coins_today: int) -> bool:
	return ad_coins_today >= Save.DAILY_AD_COIN_CAP

## Coins the NEXT rewarded ad pays (0 when the daily cap is reached).
## Pure mirror of Save.ad_next_reward, without the day-reset side effect
## (the caller passes today's counters).
static func next_ad_reward(ad_count_today: int, ad_coins_today: int) -> int:
	if ad_coins_today >= Save.DAILY_AD_COIN_CAP:
		return 0
	return Save.AD_LADDER[mini(maxi(ad_count_today, 0), Save.AD_LADDER.size() - 1)]

## How many ladder ads it takes, from this balance, to reach MIN_STAKE.
## 0 when the balance already covers it; -1 when the daily cap is hit
## first (no more ladder coins today — see recovery_plan for the daily
## bonus fallback). Simulates the ladder without touching Save.
static func ads_needed_to_stake(balance: int, ad_count_today: int, ad_coins_today: int) -> int:
	if can_stake(balance):
		return 0
	var coins := balance
	var count := ad_count_today
	var earned := ad_coins_today
	while earned < Save.DAILY_AD_COIN_CAP:
		var reward: int = Save.AD_LADDER[mini(maxi(count, 0), Save.AD_LADDER.size() - 1)]
		var room := Save.DAILY_AD_COIN_CAP - earned
		coins += mini(reward, room)
		earned += mini(reward, room)
		count += 1
		if coins >= MIN_STAKE:
			return count - ad_count_today
	return -1

## The full recovery picture for the broke panel / broke entry points.
## `can_claim_daily` / `daily_bonus` come from Save (can_claim_daily(),
## daily_bonus_amount()). Returns:
##   can_recover_today: an ad watched now can get the player to MIN_STAKE
##   ads_needed: ladder ads to reach MIN_STAKE (-1 when the ladder alone
##     cannot do it today)
##   via_daily_bonus: true when the ladder cannot do it but one daily-
##     bonus ad (which pays even at the cap) covers the gap
##   coins_after_ads: balance after those ladder ads (or after the daily
##     bonus when via_daily_bonus)
##   blocked_reason: "" when recoverable; otherwise the honest reason
##     the player cannot earn more ad coins today (free bot games and
##     0-stake friendly matches are still open — the loop never hard-
##     locks the player out of playing).
static func recovery_plan(balance: int, ad_count_today: int, ad_coins_today: int, can_claim_daily: bool, daily_bonus: int) -> Dictionary:
	if can_stake(balance):
		return {"can_recover_today": true, "ads_needed": 0, "via_daily_bonus": false,
			"coins_after_ads": balance, "blocked_reason": ""}
	var ads_needed := ads_needed_to_stake(balance, ad_count_today, ad_coins_today)
	if ads_needed >= 0:
		var after := balance
		var count := ad_count_today
		var earned := ad_coins_today
		for _i in range(ads_needed):
			var reward: int = Save.AD_LADDER[mini(maxi(count, 0), Save.AD_LADDER.size() - 1)]
			var room := Save.DAILY_AD_COIN_CAP - earned
			after += mini(reward, room)
			earned += mini(reward, room)
			count += 1
		return {"can_recover_today": true, "ads_needed": ads_needed, "via_daily_bonus": false,
			"coins_after_ads": after, "blocked_reason": ""}
	if can_claim_daily and balance + daily_bonus >= MIN_STAKE:
		return {"can_recover_today": true, "ads_needed": 1, "via_daily_bonus": true,
			"coins_after_ads": balance + daily_bonus, "blocked_reason": ""}
	return {"can_recover_today": false, "ads_needed": -1, "via_daily_bonus": false,
		"coins_after_ads": balance,
		"blocked_reason": "Daily ad limit reached — come back tomorrow for more ad coins. Free bot games and friendly 0-stake matches still work."}
