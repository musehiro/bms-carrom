extends Control

## Main — screen manager: Home, Solo/Online match, Shop, How to Play,
## Aim-Assist, matchmaking. Also routes AdMob rewarded-ad rewards and
## handles the --shot=... screenshot mode used for verification.

var _home: HomeScreen = null
var _mode: ModeChoiceScreen = null
var _nearby: NearbyScreen = null
var _match: MatchScreen = null
var _searching: Control = null
var _search_table := 0 # matchmaking band for the current search (Stakes.band_for_stake)
var _search_stake := 0 # chosen stake for the current search
var _search_players := 2 # 2 or 4 — how many players this search is for
var _search_elapsed := 0.0
var _searching_active := false
var _search_widened := false
var _search_mode := "" # "internet" | "host" | "join" — which search is running
var _search_bot_button: Button = null
var _search_status: Label = null
var _lan_hosts_box: VBoxContainer = null # join popup: found-host buttons
var _lan_found_buttons: Dictionary = {} # ip -> Button (no duplicates)
var _toast_label: Label = null
var _shot_mode := ""
var _shot_out := ""

func _ready() -> void:
	# Root Control must NOT swallow input: it covers the whole screen and
	# its default mouse_filter (STOP) used to eat every touch before the
	# match screen's _unhandled_input ever saw it (v1: drag did nothing).
	# IGNORE lets unhandled events fall through; Buttons/popups still get
	# their own input as children.
	mouse_filter = Control.MOUSE_FILTER_IGNORE
	Sfx.set_enabled(Save.sound_on)
	Ads.rewarded_earned.connect(_on_rewarded_earned)
	Ads.rewarded_failed.connect(_on_rewarded_failed)
	Net.matched.connect(_on_matched)
	Net.queue_failed.connect(_on_queue_failed)
	Net.connected_to_server.connect(_on_net_connected)
	Net.lan_host_found.connect(_on_lan_host_found)
	Net.lan_discovery_failed.connect(_on_lan_discovery_failed)
	var args := OS.get_cmdline_user_args()
	for a in args:
		if a.begins_with("--shot="):
			_shot_mode = a.trim_prefix("--shot=")
		elif a.begins_with("--shot-out="):
			_shot_out = a.trim_prefix("--shot-out=")
	if _shot_mode != "":
		_run_shot_mode()
	else:
		_show_home()

func _process(delta: float) -> void:
	if _searching_active:
		_search_elapsed += delta
		if _search_mode == "host":
			# Hosting: no level widening, no BOT fallback — just wait.
			if _search_status:
				_search_status.text = "Hosting on Wi-Fi… %ds\nWaiting for a nearby player…" % int(_search_elapsed)
			return
		if _search_mode == "join":
			# Discovering: no BOT fallback yet — it applies once a host
			# is chosen and _start_matchmaking takes over (mode internet).
			if _search_status:
				_search_status.text = "Listening for nearby hosts… %ds\nMake sure the other phone taps NEARBY → HOST." % int(_search_elapsed)
			return
		if _search_elapsed >= 30.0 and not _search_widened:
			_search_widened = true
			if _search_status:
				_search_status.text = "Searching… %ds\nNo match yet — widened to ±4 levels." % int(_search_elapsed)
		if _search_elapsed >= 12.0 and _search_bot_button:
			# Timeout fallback (v2): never a dead-end popup with only Cancel.
			_search_bot_button.visible = true
		if _search_status and not _search_widened:
			if _search_elapsed >= 12.0:
				if _search_players == 4:
					_search_status.text = "Searching… %ds\nNo players yet — play vs the computer instead." % int(_search_elapsed)
				else:
					_search_status.text = "Searching… %ds\nNo opponent yet — play vs the computer instead." % int(_search_elapsed)
			else:
				if _search_players == 4:
					_search_status.text = "Searching for 3 more players… %ds\nDoubles — matched within ±2 levels." % int(_search_elapsed)
				else:
					_search_status.text = "Searching for an opponent… %ds\nMatched within ±2 levels." % int(_search_elapsed)

# ------------------------------------------------------------------- screens

func _clear() -> void:
	Ads.hide_home_banner()
	for c in get_children():
		c.queue_free()
	_home = null
	_mode = null
	_nearby = null
	_match = null
	_searching = null
	_searching_active = false
	_search_mode = ""

func _show_home() -> void:
	_clear()
	_home = HomeScreen.new()
	add_child(_home)
	_home.play_solo.connect(_start_solo)
	_home.play_online.connect(_start_matchmaking)
	_home.open_mode_choice.connect(_open_mode_choice)
	_home.open_shop.connect(_open_shop)
	_home.open_howto.connect(_open_howto)
	_home.open_aim_assist.connect(_open_aim_assist)
	_home.watch_ad_coins.connect(_on_watch_ad_coins)
	_home.watch_ad_daily.connect(_on_watch_ad_daily)
	_home.refresh()
	Ads.show_home_banner()

func _start_solo(difficulty: int) -> void:
	_clear()
	_match = MatchScreen.new()
	add_child(_match)
	var names := ["Easy Bot", "Medium Bot", "Hard Bot"]
	_match.setup("solo", difficulty, 0, names[difficulty], difficulty + 1, null)
	_match.exit_to_home.connect(_show_home)
	_match.rematch_requested.connect(func() -> void: _start_solo(difficulty))

# ---------------------------------------------------------- mode choice (v3)

func _open_mode_choice() -> void:
	# Full-screen mode screen (like Shop), NOT a popup: the v2 PLAY popup's
	# buttons were dead on Buddhika's phone while the X worked, and the
	# home screen's own buttons work there — this screen is built the same
	# plain way. The difficulty/table popups below are the ones proven to
	# work on his phone (homepage SOLO -> EASY enters a match).
	_clear()
	_mode = ModeChoiceScreen.new()
	add_child(_mode)
	_mode.solo_chosen.connect(_show_solo_difficulty)
	_mode.online_chosen.connect(_show_online_stake)
	_mode.nearby_chosen.connect(_open_nearby)
	_mode.go_back.connect(_show_home)

func _show_solo_difficulty() -> void:
	var pop: Dictionary = UiKit.popup_window("SOLO — vs AI (offline)", Vector2(560, 460))
	add_child(pop["dim"])
	var box: VBoxContainer = pop["box"]
	box.add_child(UiKit.body_label("No internet needed. Free practice — no coins earned. Win coins in online matches or from ads.", 20))
	for i in range(3):
		var names := ["EASY", "MEDIUM", "HARD"]
		var descs := ["Relaxed — misses often, never chases the queen.", "A fair fight — sometimes chases the queen.", "Sharp — near-perfect aim, chases the queen."]
		var b := UiKit.gold_button(names[i], 26) if i == 1 else UiKit.dark_button(names[i], 26)
		box.add_child(b)
		var d := UiKit.muted_label(descs[i], 17)
		box.add_child(d)
		var diff := i
		b.pressed.connect(func() -> void:
			pop["dim"].queue_free()
			_start_solo(diff))
	pop["close"].pressed.connect(func() -> void: pop["dim"].queue_free())

## Stake picker (v5): before an online match the player chooses ANY
## stake up to their balance — no fixed tables any more. Then (v6) they
## choose 2 players (1 vs 1) or 4 players (doubles, 2 vs 2).
func _show_online_stake() -> void:
	_show_stake_picker(func(stake: int) -> void: _show_online_players(stake))

func _show_online_players(stake: int) -> void:
	var pop: Dictionary = UiKit.popup_window("ONLINE — HOW MANY PLAYERS?", Vector2(560, 520))
	add_child(pop["dim"])
	var box: VBoxContainer = pop["box"]
	box.add_child(UiKit.body_label("Your stake ◉ %d. The winning team splits the whole pot." % stake, 20))
	var b2 := UiKit.gold_button("2 PLAYERS — 1 vs 1", 26)
	b2.pressed.connect(func() -> void:
		pop["dim"].queue_free()
		_start_matchmaking(stake, "", 2))
	box.add_child(b2)
	box.add_child(UiKit.muted_label("Classic match — you vs one opponent. Winner takes both stakes.", 17))
	var b4 := UiKit.dark_button("4 PLAYERS — DOUBLES (2 vs 2)", 26)
	b4.pressed.connect(func() -> void:
		pop["dim"].queue_free()
		_start_matchmaking(stake, "", 4))
	box.add_child(b4)
	box.add_child(UiKit.muted_label("One player per side — opposite sides are partners. The winning TEAM splits all four stakes.", 17))
	pop["close"].pressed.connect(func() -> void: pop["dim"].queue_free())

## The same picker with a caller-chosen continuation + intro note, so
## the LAN flows (host/join) can reuse it with their own wording.
func _show_stake_picker(on_confirm: Callable, note: String = "") -> void:
	var parent: Control = _home if _home else self
	var pop := UiKit.stake_picker(Save.coins, on_confirm, note)
	parent.add_child(pop["dim"])

# ------------------------------------------------------- nearby (v6, LAN)

func _open_nearby() -> void:
	_clear()
	_nearby = NearbyScreen.new()
	add_child(_nearby)
	_nearby.host_chosen.connect(func() -> void: _show_stake_picker(func(s: int) -> void: _start_lan_host(s), "Same-Wi-Fi match — the other phone joins from the NEARBY screen. You choose your own stake — any amount up to your balance. Winner takes the pot (both stakes)."))
	_nearby.join_chosen.connect(func() -> void: _show_stake_picker(func(s: int) -> void: _start_lan_join(s), "Same-Wi-Fi match — find a phone on your Wi-Fi that is hosting. You choose your own stake — any amount up to your balance. Winner takes the pot (both stakes)."))
	_nearby.go_back.connect(_open_mode_choice)

func _start_lan_host(stake: int) -> void:
	if not Stakes.valid_stake(stake, Save.coins):
		_toast("Not enough coins for that stake — watch an ad to earn more.")
		return
	_search_stake = stake
	_search_table = Stakes.band_for_stake(stake)
	_search_elapsed = 0.0
	_search_widened = false
	_search_mode = "host"
	_searching_active = true
	_searching = Control.new()
	UiKit.full_rect(_searching)
	var dim := ColorRect.new()
	dim.color = Color(0, 0, 0, 0.75)
	UiKit.full_rect(dim)
	_searching.add_child(dim)
	var pop: Dictionary = UiKit.popup_window("HOSTING ON WI-FI", Vector2(560, 520))
	_searching.add_child(pop["dim"])
	var box: VBoxContainer = pop["box"]
	_search_status = UiKit.body_label("Hosting on Wi-Fi… 0s\nWaiting for a nearby player…", 22)
	box.add_child(_search_status)
	var ips := NetClient.lan_local_ips()
	var ip_text := ", ".join(ips) if not ips.is_empty() else "—"
	box.add_child(UiKit.body_label("Your Wi-Fi address: %s\nThe other phone taps NEARBY → JOIN." % ip_text, 18))
	box.add_child(UiKit.body_label("Your stake ◉ %d — winner takes the pot (your stake + opponent's stake)." % stake, 18))
	box.add_child(UiKit.muted_label("Both phones must be on the same Wi-Fi.", 17))
	_search_bot_button = null # no BOT fallback while hosting
	var cancel := UiKit.dark_button("CANCEL", 24)
	cancel.pressed.connect(_cancel_search)
	box.add_child(cancel)
	pop["close"].pressed.connect(_cancel_search)
	add_child(_searching)
	Net.start_host(Save.player_name, Save.level(), _search_table, stake)

func _start_lan_join(stake: int) -> void:
	if not Stakes.valid_stake(stake, Save.coins):
		_toast("Not enough coins for that stake — watch an ad to earn more.")
		return
	_search_stake = stake
	_search_table = Stakes.band_for_stake(stake)
	_search_elapsed = 0.0
	_search_widened = false
	_search_mode = "join"
	_searching_active = true
	_lan_found_buttons.clear()
	_searching = Control.new()
	UiKit.full_rect(_searching)
	var dim := ColorRect.new()
	dim.color = Color(0, 0, 0, 0.75)
	UiKit.full_rect(dim)
	_searching.add_child(dim)
	var pop: Dictionary = UiKit.popup_window("NEARBY PLAYERS", Vector2(560, 560))
	_searching.add_child(pop["dim"])
	var box: VBoxContainer = pop["box"]
	_search_status = UiKit.body_label("Listening for nearby hosts… 0s\nMake sure the other phone taps NEARBY → HOST.", 22)
	box.add_child(_search_status)
	_lan_hosts_box = VBoxContainer.new()
	_lan_hosts_box.add_theme_constant_override("separation", 8)
	box.add_child(_lan_hosts_box)
	box.add_child(UiKit.muted_label("Or type the host's Wi-Fi address:", 17))
	var row := HBoxContainer.new()
	row.add_theme_constant_override("separation", 10)
	box.add_child(row)
	var edit := LineEdit.new()
	edit.placeholder_text = "e.g. 192.168.1.5"
	edit.add_theme_font_size_override("font_size", 22)
	edit.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	edit.custom_minimum_size = Vector2(0, 56)
	row.add_child(edit)
	var go := UiKit.dark_button("CONNECT", 22)
	go.pressed.connect(func() -> void:
		var ip := edit.text.strip_edges()
		if ip != "":
			_join_lan_host(ip))
	row.add_child(go)
	_search_bot_button = null # no BOT fallback while discovering
	var cancel := UiKit.dark_button("CANCEL", 24)
	cancel.pressed.connect(_cancel_search)
	box.add_child(cancel)
	pop["close"].pressed.connect(_cancel_search)
	add_child(_searching)
	Net.start_discovery()

func _on_lan_host_found(host: Dictionary) -> void:
	if _searching == null or _search_mode != "join" or _lan_hosts_box == null:
		return
	var ip := String(host["ip"])
	if _lan_found_buttons.has(ip):
		return
	var b := UiKit.dark_button("%s — %s" % [String(host["name"]), ip], 22)
	_lan_hosts_box.add_child(b)
	_lan_found_buttons[ip] = b
	b.pressed.connect(func() -> void: _join_lan_host(ip))

func _on_lan_discovery_failed(message: String) -> void:
	_toast(message)

## Join a discovered (or manually typed) LAN host: stop discovering and
## run the normal search flow against that IP.
func _join_lan_host(ip: String) -> void:
	Net.stop_discovery()
	if _searching:
		_searching.queue_free()
		_searching = null
	_searching_active = false
	_search_mode = ""
	_start_matchmaking(_search_stake, ip)

func _open_shop() -> void:
	_clear()
	var shop := ShopScreen.new()
	add_child(shop)
	shop.closed.connect(_show_home)

func _open_howto() -> void:
	if _home:
		var h := HowToScreen.show_on(_home)
		h.closed.connect(func() -> void: _home.refresh())

func _open_aim_assist() -> void:
	var parent: Control = _home if _home else self
	var pop: Dictionary = UiKit.popup_window("AIM-ASSIST — EASY MODE", Vector2(580, 520))
	parent.add_child(pop["dim"])
	var box: VBoxContainer = pop["box"]
	if Save.aim_assist_active():
		var left := Save.aim_assist_remaining_sec()
		box.add_child(UiKit.body_label("ACTIVE — %02d:%02d left.\nExact aim line + pocket glow + 5 extra seconds per shot. Buying or watching again extends it (max 3 hours)." % [left / 60, left % 60], 22))
	else:
		box.add_child(UiKit.body_label("For 1 hour: a longer, exact aim line (with 1 cushion bounce), a glowing pocket when lined up, and +5 s per shot. It never auto-aims — you still take the shot.", 22))
	var buy := UiKit.gold_button("BUY 1 HOUR — ◉ 2,000", 24)
	buy.pressed.connect(func() -> void:
		if Save.spend_coins(AdsConfig.AIM_ASSIST_COINS_PRICE):
			Save.grant_aim_assist(1.0)
			_toast("Aim-Assist active for 1 hour!")
			pop["dim"].queue_free()
			if _home: _home.refresh()
		else:
			_toast("Not enough coins — win matches or watch ads."))
	box.add_child(buy)
	var ads := UiKit.dark_button("WATCH 2 ADS — 1 HOUR  (%d/2 watched)" % Save.aim_assist_ads_progress, 22)
	ads.pressed.connect(func() -> void:
		pop["dim"].queue_free()
		Ads.show_rewarded("aim_assist"))
	box.add_child(ads)
	box.add_child(UiKit.body_label("Allowed in online matches too — the line is capped at 1 bounce, so it stays fair.", 16))
	pop["close"].pressed.connect(func() -> void: pop["dim"].queue_free())

# -------------------------------------------------------------- matchmaking

func _start_matchmaking(stake: int, host_ip: String = "", players: int = 2) -> void:
	# The stake was validated in the picker; re-check defensively (the
	# balance can only have changed via a shop purchase meanwhile).
	if not Stakes.valid_stake(stake, Save.coins):
		_toast("Not enough coins for that stake — watch an ad to earn more.")
		return
	_search_stake = stake
	_search_players = players
	_search_table = Stakes.band_for_stake(stake)
	_search_elapsed = 0.0
	_search_widened = false
	_search_mode = "internet"
	_searching_active = true
	_searching = Control.new()
	UiKit.full_rect(_searching)
	var dim := ColorRect.new()
	dim.color = Color(0, 0, 0, 0.75)
	UiKit.full_rect(dim)
	_searching.add_child(dim)
	var pop: Dictionary = UiKit.popup_window("FINDING OPPONENT", Vector2(560, 460))
	_searching.add_child(pop["dim"])
	var box: VBoxContainer = pop["box"]
	if players == 4:
		_search_status = UiKit.body_label("Searching for 3 more players… 0s\nDoubles — matched within ±2 levels.", 22)
	else:
		_search_status = UiKit.body_label("Searching for an opponent… 0s\nMatched within ±2 levels.", 22)
	box.add_child(_search_status)
	var stake_label := UiKit.body_label("Your stake ◉ %d — winning TEAM splits the pot (all four stakes)." % stake, 18) if players == 4 else UiKit.body_label("Your stake ◉ %d — winner takes the pot (your stake + opponent's stake)." % stake, 18)
	box.add_child(stake_label)
	_search_bot_button = UiKit.dark_button("NO OPPONENT? PLAY vs COMPUTER INSTEAD", 20)
	_search_bot_button.visible = false
	_search_bot_button.pressed.connect(_on_play_bot_from_search)
	box.add_child(_search_bot_button)
	var cancel := UiKit.dark_button("CANCEL", 24)
	cancel.pressed.connect(_cancel_search)
	box.add_child(cancel)
	pop["close"].pressed.connect(_cancel_search)
	if _home:
		_home.add_child(_searching)
	else:
		add_child(_searching)
	if Net.is_connected_to_server():
		Net.queue_up(Save.player_name, Save.level(), _search_table, _search_stake, "4p" if _search_players == 4 else "2p")
	elif host_ip != "":
		# LAN join: connect to the discovered host, not the internet server.
		Net.connect_to_server(host_ip, NetClient.DEFAULT_PORT)
	else:
		Net.connect_to_server(Save.online_host, NetClient.DEFAULT_PORT)

func _on_net_connected() -> void:
	if _searching_active:
		Net.queue_up(Save.player_name, Save.level(), _search_table, _search_stake, "4p" if _search_players == 4 else "2p")

func _on_matched(data: Dictionary) -> void:
	if not _searching_active:
		return
	_searching_active = false
	_clear()
	_match = MatchScreen.new()
	add_child(_match)
	if String(data.get("mode", "2p")) == "4p" and data.has("players"):
		# 4p doubles: the server sends the full seat-ordered roster,
		# our seat and the breaker seat.
		var roster: Array = data["players"]
		var your_seat := int(data.get("your_seat", 0))
		var breaker_seat := int(data.get("breaker_seat", 0))
		_match.setup_4p(roster, your_seat, breaker_seat, Net)
	else:
		var opp_name := String(data.get("opponent", "Player"))
		var opp_level := int(data.get("opp_level", 1))
		var opp_stake := int(data.get("opp_stake", 0))
		var you_break := bool(data.get("you_break", true))
		_match.setup("online", 0, _search_table, opp_name, opp_level, Net, 0 if you_break else 1, _search_stake, opp_stake)
	_match.exit_to_home.connect(_show_home)
	# Rematch goes back to the stake picker — the player chooses a fresh
	# stake for every online match.
	_match.rematch_requested.connect(func() -> void: _show_online_stake())

func _on_play_bot_from_search() -> void:
	# Labelled BOT match — never a fake human (design doc 3.2).
	# Practice: free, zero coins (solo pays nothing in v5).
	_searching_active = false
	Net.disconnect_client()
	_clear()
	_match = MatchScreen.new()
	add_child(_match)
	_match.setup("solo", 1, 0, "BOT (Practice)", 1, null, -1, 0, 0, true)
	_match.exit_to_home.connect(_show_home)
	_match.rematch_requested.connect(func() -> void: _start_solo(1))
	_toast("Practice vs BOT — clearly labelled, no coins at stake.")

func _cancel_search() -> void:
	_searching_active = false
	_search_mode = ""
	Net.disconnect_client()
	if _searching:
		_searching.queue_free()
		_searching = null

func _on_queue_failed(message: String) -> void:
	if _searching_active:
		_searching_active = false
		_search_mode = ""
		if _searching:
			_searching.queue_free()
			_searching = null
	_toast(message)

# ---------------------------------------------------------------------- ads

## FREE COINS opens the ladder panel: the five tiers with the current one
## highlighted, today's progress, and the WATCH AD button. (The home
## strip shows the same ladder at a glance.)
func _on_watch_ad_coins() -> void:
	_show_ladder_panel()

func _show_ladder_panel() -> void:
	var parent: Control = _home if _home else self
	var pop: Dictionary = UiKit.popup_window("FREE COINS — AD LADDER", Vector2(580, 600))
	parent.add_child(pop["dim"])
	var box: VBoxContainer = pop["box"]
	box.add_child(UiKit.body_label("Every ad pays more than the last. Watch ads to climb the ladder — it resets each day.", 20))
	var tier_names := ["1st ad", "2nd ad", "3rd ad", "4th ad", "5th ad and beyond"]
	var current := Save.ad_current_tier()
	var capped := Save.ad_cap_reached()
	for i in range(5):
		var state := ""
		if capped or i + 1 < current:
			state = "  ✓ done"
		elif i + 1 == current:
			state = "  ◀ YOUR NEXT AD"
		var row := UiKit.body_label("%s — +%d coins%s" % [tier_names[i], Save.AD_LADDER[i], state], 22)
		if i + 1 == current and not capped:
			row.add_theme_color_override("font_color", UiKit.GOLD_LIGHT)
		box.add_child(row)
	box.add_child(UiKit.muted_label("Today: ◉ %d / %d coins from ads" % [Save.ad_coins_today, Save.DAILY_AD_COIN_CAP], 18))
	var watch := UiKit.gold_button("WATCH AD  (+%d COINS)" % Save.ad_next_reward() if not capped else "COME BACK TOMORROW", 24)
	if capped:
		watch.disabled = true
	watch.pressed.connect(func() -> void:
		pop["dim"].queue_free()
		Ads.show_rewarded("coins"))
	box.add_child(watch)
	box.add_child(UiKit.body_label("Ads are the main way to earn coins — solo practice pays none, online matches pay the pot.", 16))
	pop["close"].pressed.connect(func() -> void: pop["dim"].queue_free())

## Daily bonus: claimable ONLY by watching an ad (v5 — no free coin grant).
func _on_watch_ad_daily() -> void:
	if not Save.can_claim_daily():
		return
	Ads.show_rewarded("daily_bonus")

## Every rewarded ad pays the current ladder amount and advances the
## ladder; ads watched for Aim-Assist or the Daily Bonus pay the ladder
## amount too, on top of unlocking that reward. The daily cap (2,500)
## is the only limit.
func _on_rewarded_earned(reason: String, simulated: bool) -> void:
	var sim := " (test ad simulated)" if simulated else ""
	var ladder := Save.ad_next_reward()
	if ladder > 0:
		Save.add_coins(ladder)
		Save.record_ad_reward(ladder)
	else:
		Save.record_ad_reward(0)
	if reason == "coins":
		_toast("+%d coins from the ad ladder!%s" % [ladder, sim] if ladder > 0 else "Daily ad limit reached — no more ad coins today.%s" % sim)
	elif reason == "aim_assist":
		Save.aim_assist_ads_progress += 1
		if Save.aim_assist_ads_progress >= AdsConfig.AIM_ASSIST_ADS_NEEDED:
			Save.aim_assist_ads_progress = 0
			Save.grant_aim_assist(1.0)
			_toast("Aim-Assist active for 1 hour!%s%s" % [(" +%d coins" % ladder) if ladder > 0 else "", sim])
		else:
			_toast("Ad %d of 2 watched — one more for 1 hour of Aim-Assist.%s" % [Save.aim_assist_ads_progress, sim])
		Save.save()
	elif reason == "daily_bonus":
		var amount := Save.claim_daily()
		if amount > 0:
			_toast("Daily bonus +%d coins!%s%s" % [amount, (" (+%d ad coins)" % ladder) if ladder > 0 else "", sim])
		else:
			_toast("Daily bonus already claimed.")
		Save.save()
	elif reason == "double_win":
		# Win-screen doubling: the ladder payment above already applied
		# (each double ad pays the ladder too and advances it); the
		# match screen counts the ad toward the 2 needed to double.
		if _match:
			_match.on_double_ad_watched()
	if _home:
		_home.refresh()

func _on_rewarded_failed(reason: String) -> void:
	_toast("Ad didn't load — no reward. Try again later.")

# --------------------------------------------------------------------- toast

func _toast(text: String) -> void:
	if _toast_label:
		_toast_label.queue_free()
	_toast_label = Label.new()
	_toast_label.text = text
	_toast_label.add_theme_font_size_override("font_size", 22)
	_toast_label.add_theme_color_override("font_color", Color(1, 0.9, 0.5))
	_toast_label.add_theme_color_override("font_shadow_color", Color(0, 0, 0, 0.9))
	_toast_label.add_theme_constant_override("shadow_offset_x", 2)
	_toast_label.add_theme_constant_override("shadow_offset_y", 2)
	_toast_label.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	_toast_label.set_anchors_preset(Control.PRESET_CENTER_BOTTOM)
	_toast_label.offset_top = -120
	_toast_label.offset_bottom = -80
	_toast_label.offset_left = -340
	_toast_label.offset_right = 340
	add_child(_toast_label)
	var t := Timer.new()
	t.wait_time = 2.5
	t.one_shot = true
	t.timeout.connect(func() -> void:
		if _toast_label:
			_toast_label.queue_free()
			_toast_label = null)
	add_child(t)
	t.start()

# ------------------------------------------------------------ screenshot mode

func _run_shot_mode() -> void:
	match _shot_mode:
		"home":
			_show_home()
			_capture_after(1.5)
		"shop":
			_open_shop()
			_capture_after(1.5)
		"howto":
			_show_home()
			_open_howto()
			_capture_after(1.5)
		"match":
			_start_solo(1)
			_demo_shot_and_capture()
		"aim":
			# Aim guide preview: local turn, striker placed, aim state
			# forced on so the capture shows the dotted line, the orange
			# arrow and the striker halo.
			_start_solo(1)
			_demo_aim_and_capture()
		"playchoice":
			# v3: PLAY opens the full-screen mode-choice screen (no popup).
			_open_mode_choice()
			_capture_after(1.0)
		"search":
			# Search with the queue-failed handler disconnected so the popup
			# stays up (no server here); jump near the 12 s timeout so the
			# labelled-BOT fallback button is visible in the capture.
			_show_home()
			Net.queue_failed.disconnect(_on_queue_failed)
			_start_matchmaking(0)
			_search_elapsed = 11.5
			_capture_after(1.2)
		"ladder":
			# Home + the free-coins ladder panel (tiers + current highlight).
			_show_home()
			_show_ladder_panel()
			_capture_after(1.0)
		"stake":
			# Home + the online stake picker.
			_show_home()
			_show_online_stake()
			_capture_after(1.0)
		"nearby":
			# v6: the NEARBY (LAN) screen — HOST / JOIN + server address.
			_open_nearby()
			_capture_after(1.0)
		"lanhost":
			# v6: the HOSTING ON WI-FI popup (stake 100, from the home screen).
			_show_home()
			_start_lan_host(100)
			_capture_after(1.0)
		"search4p":
			# v6: 4-player doubles search — same as "search" but the 4p
			# wording (3 more players, team splits the pot).
			_show_home()
			Net.queue_failed.disconnect(_on_queue_failed)
			_start_matchmaking(100, "", 4)
			_search_elapsed = 11.5
			_capture_after(1.2)
		"win":
			# v6: the premium win screen — force an online win (stake
			# 100 + 100) on a solo match so the pot + DOUBLE offer show.
			_start_solo(1)
			_demo_win_and_capture()
		_:
			_show_home()
			_capture_after(1.5)

func _demo_win_and_capture() -> void:
	# Wait for the match to be live, then force an online win so the
	# premium win screen (pot + COLLECT + DOUBLE) shows for the capture.
	var waited := 0.0
	while waited < 9.0:
		await get_tree().create_timer(0.5).timeout
		waited += 0.5
		if _match == null:
			_capture()
			return
		if _match.phase == "place":
			break
	if _match and _match.phase == "place":
		_match.mode = "online"
		_match.your_stake = 100
		_match.opp_stake = 100
		_match.rules_state["over"] = true
		_match.rules_state["winner"] = 0
		_match._show_result()
		await get_tree().create_timer(0.8).timeout
	_capture()

func _capture_after(seconds: float) -> void:
	await get_tree().create_timer(seconds).timeout
	_capture()

func _demo_shot_and_capture() -> void:
	# Wait until it is the local player's turn (the AI may break first),
	# then take a real shot from the bottom baseline so the screenshot
	# shows a game in progress (coins scattered, not the setup).
	var waited := 0.0
	while waited < 9.0:
		await get_tree().create_timer(0.5).timeout
		waited += 0.5
		if _match == null:
			_capture()
			return
		if _match.phase == "place" and int(_match.rules_state["turn"]) == 0:
			break
	if _match and _match.phase == "place":
		_match._striker["pos"] = Vector2(360.0, CarromPhysics.baseline_y(0))
		var dir: Vector2 = (CarromPhysics.BOARD_CENTER - _match._striker["pos"]).normalized()
		_match._shoot(dir, 0.95, false)
		await get_tree().create_timer(2.6).timeout
	_capture()

func _demo_aim_and_capture() -> void:
	# Wait until it is the local player's turn (the AI may break first),
	# then place the striker and force the aim state on for the capture.
	var waited := 0.0
	while waited < 9.0:
		await get_tree().create_timer(0.5).timeout
		waited += 0.5
		if _match == null:
			_capture()
			return
		if _match.phase == "place" and int(_match.rules_state["turn"]) == 0:
			break
	if _match and _match.phase == "place":
		_match._striker["pos"] = Vector2(360.0, CarromPhysics.baseline_y(0))
		var dir: Vector2 = (CarromPhysics.BOARD_CENTER - _match._striker["pos"]).normalized()
		_match.board_view.aim_visible = true
		_match.board_view.aim_from = _match._striker["pos"]
		_match.board_view.aim_dir = dir
		_match.board_view.aim_power = 0.6
		_match.board_view.your_turn = true
		await get_tree().create_timer(0.4).timeout
	_capture()

func _capture() -> void:
	await get_tree().process_frame
	await get_tree().process_frame
	var img := get_viewport().get_texture().get_image()
	var path := _shot_out if _shot_out != "" else "user://shot.png"
	var err := img.save_png(path)
	print("SHOT_SAVED ", path, " err=", err, " size=", img.get_size())
	get_tree().quit()
