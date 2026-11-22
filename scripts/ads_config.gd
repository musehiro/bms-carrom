class_name AdsConfig
extends RefCounted

## AdMob configuration — TEST IDs ONLY.
## Real unit IDs come from Nana (she holds the AdMob account).
## Never put a real ID here without her supplying it.

const APP_ID := "ca-app-pub-3940256099942544~3347511713"
const REWARDED_UNIT_ID := "ca-app-pub-3940256099942544/5224354917"
const INTERSTITIAL_UNIT_ID := "ca-app-pub-3940256099942544/1033173712"

# Policy (design doc section 6.8): interstitial ONLY on the match-result
# screen, only after every 3rd match, skippable after 5s, never mid-game.
const INTERSTITIAL_EVERY_N_MATCHES := 3
# Rewarded: +150 coins, max 5/day; 2 ads = 1 hour of aim-assist.
const REWARDED_COINS := 150
const REWARDED_COINS_MAX_PER_DAY := 5
const AIM_ASSIST_ADS_NEEDED := 2
const AIM_ASSIST_COINS_PRICE := 2000
const AIM_ASSIST_DURATION_SEC := 3600
const AIM_ASSIST_MAX_BANKED_SEC := 3 * 3600
