extends Node

## Ads — autoload wrapper around the Poing GodotAdMob plugin (v4.3.1).
## TEST IDs ONLY (see ads_config.gd). Real IDs come from Nana later.
##
## On Android the real plugin loads/shows real test ads. Everywhere else
## (editor, desktop, headless tests) the native plugin singleton does not
## exist, so rewarded/interstitial requests fall back to a clearly-labelled
## SIMULATED test ad (1.2 s delay, then the reward is granted) — the reward
## flow stays testable and the game never hard-blocks on an ad.
## If a real ad fails to load/show, the caller gets a failure signal and the
## game continues gracefully (no reward, no crash, no retry loop).

signal rewarded_earned(reason: String, simulated: bool)
signal rewarded_failed(reason: String)
signal interstitial_closed()
signal interstitial_failed()

var _rewarded_ad: RewardedAd = null
var _interstitial_ad: InterstitialAd = null
var _banner_view: AdView = null
var _banner_listener := AdListener.new()
var _banner_shown := false
var _rewarded_reason := ""
var _rewarded_load_cb := RewardedAdLoadCallback.new()
var _rewarded_listener := OnUserEarnedRewardListener.new()
var _rewarded_content_cb := FullScreenContentCallback.new()
var _interstitial_load_cb := InterstitialAdLoadCallback.new()
var _interstitial_content_cb := FullScreenContentCallback.new()
var _rewarded_timer: Timer = null
var _load_timeout: Timer = null
var _simulated := false

func _ready() -> void:
	_simulated = not OS.has_feature("android")
	_rewarded_load_cb.on_ad_loaded = _on_rewarded_loaded
	_rewarded_load_cb.on_ad_failed_to_load = _on_rewarded_failed_to_load
	_rewarded_listener.on_user_earned_reward = _on_user_earned_reward
	_rewarded_content_cb.on_ad_dismissed_full_screen_content = _on_rewarded_dismissed
	_rewarded_content_cb.on_ad_failed_to_show_full_screen_content = _on_rewarded_show_failed
	_interstitial_load_cb.on_ad_loaded = _on_interstitial_loaded
	_interstitial_load_cb.on_ad_failed_to_load = _on_interstitial_failed_to_load
	_interstitial_content_cb.on_ad_dismissed_full_screen_content = _on_interstitial_dismissed
	_interstitial_content_cb.on_ad_failed_to_show_full_screen_content = _on_interstitial_show_failed
	_banner_listener.on_ad_loaded = func() -> void: print("[Ads] Home banner loaded.")
	_banner_listener.on_ad_failed_to_load = func(err: LoadAdError) -> void: print("[Ads] Home banner failed to load: ", err.message)
	if OS.has_feature("android"):
		MobileAds.initialize()
		_preload_interstitial()
	else:
		print("[Ads] Non-Android build: test ads will be simulated.")

func _is_plugin_live() -> bool:
	# The native singleton only exists inside a real Android export.
	return OS.has_feature("android")

# ------------------------------------------------------------------ banner
## Home-page banner (v5, Buddhika 2026-11-22): an anchored adaptive banner
## pinned to the very bottom of the home screen only. TEST unit ID for now;
## the real banner ID comes from Nana later, like the interstitials. The
## home screen reserves a ~96 px slot at the bottom with a subtle "AD"
## placeholder, so the layout is identical with or without a live banner.
## On non-Android builds this is a no-op (the placeholder proves the slot).

func show_home_banner() -> void:
	if not _is_plugin_live():
		print("[Ads] Home banner: non-Android, placeholder slot only.")
		return
	if _banner_view == null:
		var ad_size := AdSize.get_current_orientation_anchored_adaptive_banner_ad_size(AdSize.FULL_WIDTH)
		_banner_view = AdView.new(AdsConfig.BANNER_UNIT_ID, ad_size, AdPosition.Values.BOTTOM)
		_banner_view.ad_listener = _banner_listener
		_banner_view.load_ad(AdRequest.new())
	_banner_view.show()
	_banner_shown = true

func hide_home_banner() -> void:
	if _banner_view != null:
		_banner_view.hide()
	_banner_shown = false

# ---------------------------------------------------------------- rewarded

func show_rewarded(reason: String) -> void:
	_rewarded_reason = reason
	if _simulated or not _is_plugin_live():
		_simulate_rewarded()
		return
	RewardedAdLoader.new().load(AdsConfig.REWARDED_UNIT_ID, AdRequest.new(), _rewarded_load_cb)
	_arm_load_timeout("rewarded")

func _simulate_rewarded() -> void:
	print("[Ads] Simulated test ad (editor/desktop) for: ", _rewarded_reason)
	_rewarded_timer = Timer.new()
	_rewarded_timer.wait_time = 1.2
	_rewarded_timer.one_shot = true
	_rewarded_timer.timeout.connect(_on_simulated_rewarded_done)
	add_child(_rewarded_timer)
	_rewarded_timer.start()

func _on_simulated_rewarded_done() -> void:
	rewarded_earned.emit(_rewarded_reason, true)

func _on_rewarded_loaded(ad: RewardedAd) -> void:
	_disarm_timeout()
	_rewarded_ad = ad
	_rewarded_ad.full_screen_content_callback = _rewarded_content_cb
	_rewarded_ad.show(_rewarded_listener)

func _on_rewarded_failed_to_load(error: LoadAdError) -> void:
	_disarm_timeout()
	print("[Ads] Rewarded failed to load: ", error.message)
	rewarded_failed.emit(_rewarded_reason)

func _on_user_earned_reward(_item: RewardedItem) -> void:
	rewarded_earned.emit(_rewarded_reason, false)

func _on_rewarded_dismissed() -> void:
	if _rewarded_ad:
		_rewarded_ad.destroy()
		_rewarded_ad = null

func _on_rewarded_show_failed(_err: AdError) -> void:
	rewarded_failed.emit(_rewarded_reason)

# ------------------------------------------------------------ interstitial

func maybe_show_interstitial() -> bool:
	# Policy: only after every 3rd match. Caller checks the counter; this
	# loads + shows one interstitial. Returns true if an ad was attempted.
	if _simulated or not _is_plugin_live():
		print("[Ads] Simulated interstitial (editor/desktop).")
		_simulate_interstitial()
		return true
	if _interstitial_ad:
		_interstitial_ad.show()
		return true
	InterstitialAdLoader.new().load(AdsConfig.INTERSTITIAL_UNIT_ID, AdRequest.new(), _interstitial_load_cb)
	_arm_load_timeout("interstitial")
	return true

func _simulate_interstitial() -> void:
	var t := Timer.new()
	t.wait_time = 1.0
	t.one_shot = true
	t.timeout.connect(func() -> void: interstitial_closed.emit())
	add_child(t)
	t.start()

func _preload_interstitial() -> void:
	if not _is_plugin_live():
		return
	InterstitialAdLoader.new().load(AdsConfig.INTERSTITIAL_UNIT_ID, AdRequest.new(), _interstitial_load_cb)

func _on_interstitial_loaded(ad: InterstitialAd) -> void:
	_disarm_timeout()
	_interstitial_ad = ad
	_interstitial_ad.full_screen_content_callback = _interstitial_content_cb

func _on_interstitial_failed_to_load(error: LoadAdError) -> void:
	_disarm_timeout()
	print("[Ads] Interstitial failed to load: ", error.message)
	interstitial_failed.emit()

func _on_interstitial_dismissed() -> void:
	if _interstitial_ad:
		_interstitial_ad.destroy()
		_interstitial_ad = null
	interstitial_closed.emit()
	_preload_interstitial()

func _on_interstitial_show_failed(_err: AdError) -> void:
	interstitial_failed.emit()

# ------------------------------------------------------------------ timers

func _arm_load_timeout(kind: String) -> void:
	_disarm_timeout()
	_load_timeout = Timer.new()
	_load_timeout.wait_time = 10.0
	_load_timeout.one_shot = true
	_load_timeout.timeout.connect(func() -> void:
		print("[Ads] Load timed out: ", kind)
		if kind == "rewarded":
			rewarded_failed.emit(_rewarded_reason)
		else:
			interstitial_failed.emit())
	add_child(_load_timeout)
	_load_timeout.start()

func _disarm_timeout() -> void:
	if _load_timeout:
		_load_timeout.queue_free()
		_load_timeout = null
