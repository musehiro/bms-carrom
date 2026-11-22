class_name Stakes
extends RefCounted

## Virtual-coin staking for online matches (v5, Buddhika 2026-11-22).
## Pure logic — no UI, no Save access — so it is unit-testable.
##
## Rules (NO real money anywhere — stakes come only from coins earned
## in the game: ad ladder + online pots):
##   * Before an online match each player chooses their own stake — any
##     amount from 0 up to their coin balance. No fixed amount, no forced
##     match of the opponent's stake.
##   * The pot = both stakes. The winner takes the whole pot (their stake
##     back + the loser's stake). On a draw both stakes are returned.
##   * The stake is LOCKED (deducted) when the match starts, never during
##     the search — cancelling the search costs nothing, and the practice
##     BOT fallback never takes a stake (solo pays zero anyway).
##   * Matchmaking bands exist only to find an opponent of a similar
##     stake size; the pot still uses each player's own stake.
##   * Solo vs AI has no staking (free practice, zero coins).

## Stake bands for matchmaking only: <250 -> 0, <1000 -> 1, else 2.
const BAND_LIMITS := [250, 1000]

static func band_for_stake(stake: int) -> int:
	if stake < BAND_LIMITS[0]:
		return 0
	if stake < BAND_LIMITS[1]:
		return 1
	return 2

## A stake is valid when it is between 0 and the player's balance.
static func valid_stake(stake: int, balance: int) -> bool:
	return stake >= 0 and stake <= balance

static func pot(your_stake: int, opp_stake: int) -> int:
	return your_stake + opp_stake

## Coins to ADD to the player's balance at match end. The stake was
## already deducted (locked) at match start, so:
##   "win"  -> the whole pot (own stake back + opponent's stake)
##   "loss" -> 0 (stake is gone)
##   "draw" -> own stake back (refund)
static func payout(your_stake: int, opp_stake: int, outcome: String) -> int:
	match outcome:
		"win":
			return your_stake + opp_stake
		"draw":
			return your_stake
		_:
			return 0
