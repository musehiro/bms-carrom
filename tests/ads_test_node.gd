extends Node

## Ads fallback test: on a non-Android build the AdMob plugin has no native
## singleton, so Ads.show_rewarded must take the simulated path and still
## emit rewarded_earned. Run headless:
##   godot --headless --path . res://tests/ads_test.tscn

var _wait := 0.0
var _done := false

func _ready() -> void:
	Ads.rewarded_earned.connect(_on_earned)
	Ads.rewarded_failed.connect(_on_failed)
	print("[AdsTest] requesting rewarded ad (reason=coins)…")
	Ads.show_rewarded("coins")

func _on_earned(reason: String, simulated: bool) -> void:
	print("[AdsTest] rewarded_earned reason=%s simulated=%s" % [reason, str(simulated)])
	_done = true
	get_tree().quit(0 if reason == "coins" and simulated else 1)

func _on_failed(reason: String) -> void:
	print("[AdsTest] rewarded_failed reason=%s" % reason)
	_done = true
	get_tree().quit(1)

func _process(delta: float) -> void:
	if _done:
		return
	_wait += delta
	if _wait > 10.0:
		print("[AdsTest] TIMEOUT waiting for ad result")
		_done = true
		get_tree().quit(1)
