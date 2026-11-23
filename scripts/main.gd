extends Control

## Main — screen manager: Home, Solo/Online match, Shop, How to Play,
## Aim-Assist, matchmaking. Also routes AdMob rewarded-ad rewards and
## handles the --shot=... screenshot mode used for verification.

var _home: HomeScreen = null
var _mode: ModeChoiceScreen = null
var _loading: LoadingScreen = null
var _nearby: NearbyScreen = null
var _match: MatchScreen = null
var _auth: AuthScreen = null
var _searching: Control = null
var _search_table := 0 # matchmaking band for the current search (Stakes.band_for_stake)
var _search_stake := 0 # chosen stake for the current search
var _search_players := 2 # 2 or 4 — how many players this search is for
var _search_elapsed := 0.0
var _searching_active := false
var _search_widened := false
var _search_mode := "" # "internet" | "host" | "join" | "invite" — which search is running
var _invite_group_id := "" # the Supabase invite group being joined
var _invite_is_inviter := false # I sent this invite (seat 0)
var _last_tour_stake := 0 # the stake of the last World Tour match (rematch reuses it)
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
	Net.connection_lost.connect(_on_connection_lost) # L4
	Net.connected_to_server.connect(_on_net_connected)
	Net.lan_host_found.connect(_on_lan_host_found)
	Net.lan_discovery_failed.connect(_on_lan_discovery_failed)
	Friends.invite_received.connect(_on_invite_received)
	Friends.group_ready.connect(_on_group_ready)
	Friends.group_failed.connect(_on_group_failed)
	var args := OS.get_cmdline_user_args()
	for a in args:
		if a.begins_with("--shot="):
			_shot_mode = a.trim_prefix("--shot=")
		elif a.begins_with("--shot-out="):
			_shot_out = a.trim_prefix("--shot-out=")
	if _shot_mode != "":
		_run_shot_mode()
	elif Accounts.has_account():
		# Returning player: straight to home; invites start listening.
		Friends.start_listening()
		_show_home()
	else:
		# First screen: register / sign in (mandatory — no guest mode).
		_show_auth()

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
		if _search_mode == "invite":
			# Invite room: waiting for the other player(s) to join the
			# game server. No BOT fallback — this is a match with a
			# named friend, not random matchmaking.
			# L4: the server drops an invite room after 180 s
			# (INVITE_ROOM_TIMEOUT), so the popup must time out at
			# the same point instead of spinning forever.
			if _search_elapsed >= 180.0:
				_close_search_popup()
				_toast("Not everyone joined in time — ask your friend to send the invite again.")
				return
			if _search_status:
				if _search_players == 4:
					_search_status.text = "Waiting for the other players… %ds\nThe match starts when everyone has joined." % int(_search_elapsed)
				else:
					_search_status.text = "Waiting for the other player… %ds\nThe match starts when they join." % int(_search_elapsed)
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
	_loading = null
	_nearby = null
	_match = null
	_auth = null
	_searching = null
	_toast_label = null # freed with the children above; never queue_free it again
	_searching_active = false
	_search_mode = ""

# ------------------------------------------------------- auth first (v7)
# Registration is mandatory — the game opens on the register/login
# screen until the player has an account. There is no guest mode.

func _show_auth() -> void:
	_clear()
	_auth = AuthScreen.new()
	add_child(_auth)
	_auth.registered.connect(_on_auth_done)
	_auth.signed_in.connect(_on_auth_done)

func _on_auth_done() -> void:
	Friends.start_listening()
	_show_home()

func _show_home() -> void:
	_clear()
	_home = HomeScreen.new()
	add_child(_home)
	_home.play_solo_direct.connect(_start_solo_direct)
	# L3: the home ONLINE tile used to call _start_matchmaking directly
	# (always 2 players). Route it through the same 2p/4p choice the
	# PLAY → ONLINE path uses, so a 4-player match can start from home.
	_home.play_online.connect(_show_online_players)
	_home.open_mode_choice.connect(_open_mode_choice)
	_home.open_shop.connect(_open_shop)
	_home.open_howto.connect(_open_howto)
	_home.open_aim_assist.connect(_open_aim_assist)
	_home.watch_ad_coins.connect(_on_watch_ad_coins)
	_home.watch_ad_daily.connect(_on_watch_ad_daily)
	_home.invite_accept_chosen.connect(_on_invite_accept_chosen)
	_home.invite_send_chosen.connect(_on_invite_send_chosen)
	_home.group_invite_send_chosen.connect(_on_group_invite_send_chosen)
	_home.refresh()
	Ads.show_home_banner()
	# v9: ads warm up only now (after login, on the home screen) — never
	# before registration.
	Ads.warm_up()
	# Keep the cloud profile up to date (coins/XP change after matches
	# and ads). Silent no-op when there is no session yet.
	Accounts.sync_to_cloud()

# ------------------------------------------------------ invites (v7)
# Accept -> choose YOUR OWN stake (each player stakes their own
# amount, v5/v6) -> join the game server's invite room for the group.
# The server starts the match when everyone has joined; stakes lock
# only at match start, so cancelling costs nothing.

func _on_invite_accept_chosen(invite: Dictionary) -> void:
	# F1: accept the Supabase row FIRST — until it flips to "accepted"
	# the inviter's group can never become ready and the match never
	# starts. Only join the server room on success. An already-accepted
	# invite (double tap / re-delivered row) skips the PATCH: the row
	# is already in the state we need, so it must not error the flow.
	if String(invite.get("status", "")) != "accepted":
		var res := await Friends.accept_invite(invite)
		if not bool(res.get("ok", false)):
			_toast(String(res.get("error", "Could not accept the invite.")))
			return
	_show_stake_picker(func(stake: int) -> void:
		_join_invite_room(String(invite.get("group_id", "")), String(invite.get("mode", "2p")), stake, false),
		"Accepting %s's invite — choose YOUR stake (any amount up to your balance). Winner takes the pot (both stakes)." % String(invite.get("from_name", "a friend")))

func _on_invite_send_chosen(player: Dictionary) -> void:
	_show_stake_picker(func(stake: int) -> void:
		var res := await Friends.send_invite(String(player.get("id", "")), String(player.get("display_name", "?")), stake)
		if bool(res.get("ok", false)):
			_toast("Invite sent to %s!" % String(player.get("display_name", "?")))
		else:
			_toast(String(res.get("error", "Could not send the invite."))),
		"Invite %s to a 1 vs 1 match — choose YOUR stake (any amount up to your balance). Winner takes the pot." % String(player.get("display_name", "?")))

func _on_group_invite_send_chosen(players: Array) -> void:
	_show_stake_picker(func(stake: int) -> void:
		var res := await Friends.send_group_invite(players, stake)
		if bool(res.get("ok", false)):
			_toast("4-player invite sent — the match starts when all accept!")
		else:
			_toast(String(res.get("error", "Could not send the invites."))),
		"Invite %d friends to a doubles match — choose YOUR stake (any amount up to your balance). The winning TEAM splits the pot." % players.size())

func _on_invite_received(invite: Dictionary) -> void:
	_toast("New invite from %s!" % String(invite.get("from_name", "a friend")))
	if _home:
		_home.refresh()

func _on_group_ready(group_id: String, invites: Array) -> void:
	# Everyone accepted my invite — I join the room as the inviter
	# (seat 0) with the stake I chose when I sent it.
	var stake := 0
	var mode := "2p"
	if not invites.is_empty():
		stake = int(invites[0].get("stake", 0))
		mode = String(invites[0].get("mode", "2p"))
	_toast("Everyone accepted — starting the match!")
	_join_invite_room(group_id, mode, stake, true)

func _on_group_failed(group_id: String, reason: String) -> void:
	_toast(reason)

func _join_invite_room(group_id: String, mode: String, stake: int, is_inviter: bool) -> void:
	if group_id == "":
		_toast("That invite has no group — ask your friend to send it again.")
		return
	if not Stakes.valid_stake(stake, Save.coins):
		_toast("Not enough coins for that stake — watch an ad to earn more.")
		return
	_invite_group_id = group_id
	_invite_is_inviter = is_inviter
	_search_stake = stake
	_search_players = 4 if mode == "4p" else 2
	_search_table = Stakes.band_for_stake(stake)
	_search_elapsed = 0.0
	_search_widened = false
	_search_mode = "invite"
	_searching_active = true
	_searching = Control.new()
	UiKit.full_rect(_searching)
	var dim := ColorRect.new()
	dim.color = Color(0, 0, 0, 0.75)
	UiKit.full_rect(dim)
	_searching.add_child(dim)
	var pop: Dictionary = UiKit.popup_window("WAITING FOR PLAYERS", Vector2(560, 460))
	_searching.add_child(pop["dim"])
	var box: VBoxContainer = pop["box"]
	if _search_players == 4:
		_search_status = UiKit.body_label("Waiting for the other players… 0s\nThe match starts when everyone has joined.", 22)
	else:
		_search_status = UiKit.body_label("Waiting for the other player… 0s\nThe match starts when they join.", 22)
	box.add_child(_search_status)
	box.add_child(UiKit.body_label("Your stake ◉ %d — it is only taken when the match starts." % stake, 18))
	_search_bot_button = null # no BOT fallback for a friend invite
	var cancel := UiKit.dark_button("CANCEL", 24)
	cancel.pressed.connect(_cancel_search)
	box.add_child(cancel)
	pop["close"].pressed.connect(_cancel_search)
	if _home:
		_home.add_child(_searching)
	else:
		add_child(_searching)
	if Net.is_connected_to_server():
		Net.join_invite_room(group_id, Save.player_name, Save.level(), stake, mode, _search_table, is_inviter)
	else:
		Net.connect_to_server(Save.online_host, NetClient.DEFAULT_PORT)

## Short loading screen (v10 direct play): tap -> this -> board.
## One big label, one sub-line, animated dots. No buttons, no choices —
## the player understands it at a glance (clean-UI rule).
class LoadingScreen:
	extends Control
	var _dots_label: Label
	var _dots := 0
	var _accum := 0.0

	func _init(title_text: String, sub_text: String) -> void:
		mouse_filter = Control.MOUSE_FILTER_IGNORE
		UiKit.full_rect(self)
		var bg := ColorRect.new()
		bg.color = Color(0.04, 0.45, 0.42)
		bg.mouse_filter = Control.MOUSE_FILTER_IGNORE
		UiKit.full_rect(bg)
		add_child(bg)
		var center := CenterContainer.new()
		center.mouse_filter = Control.MOUSE_FILTER_IGNORE
		UiKit.full_rect(center)
		add_child(center)
		var vb := VBoxContainer.new()
		vb.add_theme_constant_override("separation", 14)
		center.add_child(vb)
		var title := UiKit.title_label(title_text, 40)
		vb.add_child(title)
		var sub := UiKit.muted_label(sub_text, 20)
		sub.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
		sub.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
		vb.add_child(sub)
		_dots_label = UiKit.title_label("", 40)
		vb.add_child(_dots_label)

	func _process(delta: float) -> void:
		_accum += delta
		if _accum >= 0.4:
			_accum = 0.0
			_dots = (_dots + 1) % 4
			_dots_label.text = ".".repeat(_dots)

## Show the loading screen (no timer — the caller drives what happens
## next). The screenshot mode uses this to capture the screen itself.
func _show_loading(title_text: String, sub_text: String) -> void:
	_clear()
	_loading = LoadingScreen.new(title_text, sub_text)
	add_child(_loading)

## Show the loading screen, wait ~1.2 s, then run `then`. Tap ->
## loading -> board: a short pause, not a choice.
func _show_loading_then(title_text: String, sub_text: String, then: Callable) -> void:
	_show_loading(title_text, sub_text)
	var token := _loading
	await get_tree().create_timer(1.2).timeout
	if _loading != token or not is_instance_valid(token):
		return # the screen went away meanwhile — do not start the match
	_loading = null
	then.call()

func _start_solo(difficulty: int) -> void:
	_clear()
	# F2 layer 1: configure BEFORE add_child — _ready() reads
	# player_count/mode/_breaker_override, so setup() must run first.
	_match = MatchScreen.new()
	var names := ["Easy Bot", "Medium Bot", "Hard Bot"]
	_match.setup("solo", difficulty, 0, names[difficulty], difficulty + 1, null)
	add_child(_match)
	_match.exit_to_home.connect(_show_home)
	_match.rematch_requested.connect(_start_solo_direct)

## v10 direct Solo: no difficulty choice — a random bot (Easy / Medium /
## Hard), free, no coins, as before. Tap -> loading -> board.
func _start_solo_direct() -> void:
	_show_loading_then("GETTING READY", "Solo — free practice vs a random bot.", func() -> void:
		_start_solo(randi_range(0, 2)))

# ---------------------------------------------------------- mode choice (v3, v10 direct play)

func _open_mode_choice() -> void:
	# Full-screen mode screen (like Shop), NOT a popup: the v2 PLAY popup's
	# buttons were dead on Buddhika's phone while the X worked, and the
	# home screen's own buttons work there — this screen is built the same
	# plain way. The difficulty/table popups below are the ones proven to
	# work on his phone (homepage SOLO -> EASY enters a match).
	_clear()
	_mode = ModeChoiceScreen.new()
	add_child(_mode)
	_mode.solo_chosen.connect(_start_solo_direct)
	_mode.tour_chosen.connect(func() -> void:
		_show_stake_picker(func(stake: int) -> void: _start_tour_random(stake),
			"World Tour — a random advanced computer champion (BOT), near your level. Your stake is mirrored by the bot — winner takes the pot (both stakes).",
			"WORLD TOUR — CHOOSE YOUR STAKE"))
	_mode.online_chosen.connect(_show_online_stake)
	_mode.nearby_chosen.connect(_open_nearby)
	_mode.go_back.connect(_show_home)

## v10 direct World Tour: no bot list — a random advanced bot, weighted
## near the player's level. Stake picker first (unchanged), then
## loading, then the board. The bot is named in the match HUD (BOT).
func _start_tour_random(stake: int) -> void:
	if not Stakes.valid_stake(stake, Save.coins):
		_toast("Not enough coins for that stake — watch an ad to earn more.")
		return
	_last_tour_stake = stake
	_show_loading_then("FINDING A CHAMPION", "World Tour — a random computer champion, near your level.", func() -> void:
		_start_tour_match(WorldTour.random_bot_near_level(Save.level()), stake))

func _start_tour_match(bot: Dictionary, stake: int) -> void:
	if not Stakes.valid_stake(stake, Save.coins):
		_toast("Not enough coins for that stake — watch an ad to earn more.")
		return
	_last_tour_stake = stake
	_clear()
	# F2 layer 1: configure BEFORE add_child (see _start_solo).
	_match = MatchScreen.new()
	var opp_stake := WorldTour.mirror_stake(stake)
	_match.setup("tour", int(bot.get("skill", 3)), 0, "%s (BOT)" % String(bot.get("name", "?")), int(bot.get("level", 1)), null, -1, stake, opp_stake, false)
	add_child(_match)
	_match.exit_to_home.connect(_show_home)
	# Rematch: same stake, a NEW random bot — no roster, no picker.
	_match.rematch_requested.connect(func() -> void: _start_tour_random(_last_tour_stake))

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
## `title` overrides the picker's title (World Tour uses its own).
func _show_stake_picker(on_confirm: Callable, note: String = "", title: String = "") -> void:
	var parent: Control = _home if _home else self
	var pop := UiKit.stake_picker(Save.coins, on_confirm, note, title) if title != "" else UiKit.stake_picker(Save.coins, on_confirm, note)
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
		if _search_mode == "invite":
			Net.join_invite_room(_invite_group_id, Save.player_name, Save.level(), _search_stake, "4p" if _search_players == 4 else "2p", _search_table, _invite_is_inviter)
		else:
			Net.queue_up(Save.player_name, Save.level(), _search_table, _search_stake, "4p" if _search_players == 4 else "2p")

func _on_matched(data: Dictionary) -> void:
	if not _searching_active:
		return
	_searching_active = false
	_clear()
	# F2 layer 1 (+ F3): configure BEFORE add_child — _ready() builds
	# the rules state and HUD from player_count/mode and reads the
	# server-assigned breaker; with setup() after add_child a 4p match
	# got 2-player rules/HUD and each client rolled its own breaker.
	_match = MatchScreen.new()
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
	add_child(_match)
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
	# F2 layer 1: configure BEFORE add_child (see _start_solo).
	_match = MatchScreen.new()
	_match.setup("solo", 1, 0, "BOT (Practice)", 1, null, -1, 0, 0, true)
	add_child(_match)
	_match.exit_to_home.connect(_show_home)
	_match.rematch_requested.connect(_start_solo_direct)
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
		_close_search_popup()
	_toast(message)

## L4: the server connection dropped. Only a search in progress cares
## — a mid-match drop is MatchScreen's opponent_left path, and must
## not show a "search failed" toast over a live match.
func _on_connection_lost() -> void:
	if not _searching_active:
		return
	_close_search_popup()
	_toast("Connection to the matchmaking server was lost — check your connection and try again.")

## Shared search-popup teardown (queue_failed / connection_lost /
## invite timeout): clear the flags and free the popup.
func _close_search_popup() -> void:
	_searching_active = false
	_search_mode = ""
	if _searching:
		_searching.queue_free()
		_searching = null

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
	elif reason == "solo_win":
		# v8: a solo win's one ad — the ladder payment above already
		# applied. Tell the win screen so its EARN button shows EARNED.
		if _match:
			_match.on_solo_win_ad_watched()
		_toast("+%d coins from the ad!%s" % [ladder, sim] if ladder > 0 else "Daily ad limit reached — no more ad coins today.%s" % sim)
	if _home:
		_home.refresh()
		Accounts.sync_to_cloud()

func _on_rewarded_failed(reason: String) -> void:
	if reason == "solo_win" and _match:
		_match.on_solo_win_ad_failed()
	elif reason == "double_win" and _match:
		# F8: a failed double ad must re-enable the DOUBLE (and pot-0
		# EARN) button, mirroring the solo-win path above — otherwise
		# the offer is dead for the rest of the win screen. Dispatched
		# at runtime, not as a direct call, because on_double_ad_failed
		# lives in MatchScreen (match.gd): until that method exists
		# this branch is a safe no-op; once it lands (mirror of
		# on_solo_win_ad_failed) the button is re-enabled.
		if _match.has_method("on_double_ad_failed"):
			Callable(_match, "on_double_ad_failed").call()
	_toast("Ad didn't load — no reward. Try again later.")

# --------------------------------------------------------------------- toast

func _toast(text: String) -> void:
	# The old label may already be freed (e.g. _clear() freed it with
	# the screen) — `if _toast_label` alone does NOT catch a freed
	# instance, so check validity before queue_free (SCRIPT ERROR fix).
	if is_instance_valid(_toast_label):
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
	var label := _toast_label
	var t := Timer.new()
	t.wait_time = 2.5
	t.one_shot = true
	t.timeout.connect(func() -> void:
		# Capture the label itself: the shared _toast_label may
		# already point at a NEWER toast by the time this fires,
		# and freeing that one would eat the fresh message.
		if is_instance_valid(label):
			label.queue_free()
		if _toast_label == label:
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
		"login":
			# v7: the register / sign-in screen (mandatory — first screen).
			_show_auth()
			_capture_after(1.0)
		"invitebox":
			# v7: home with the invite box open (canned invites: one 2p,
			# one 4p incoming, one sent, two search results).
			_show_home()
			_demo_invite_box()
			_capture_after(1.2)
		"invite":
			# v7: accepting an invite — the invite box open with the
			# stake picker on top (choose YOUR stake, then join).
			_show_home()
			_demo_invite_box()
			_show_stake_picker(func(stake: int) -> void: pass,
				"Accepting Nimal's invite — choose YOUR stake (any amount up to your balance). Winner takes the pot (both stakes).")
			_capture_after(1.2)
		"invite4p":
			# v7: 4-player invite — two friends selected for 4P with the
			# SEND 4-PLAYER INVITE button showing.
			_show_home()
			_demo_invite_box_4p()
			_capture_after(1.2)
		"tour":
			# v10: the roster is gone — the loading screen instead.
			_show_loading("FINDING A CHAMPION", "World Tour — a random computer champion, near your level.")
			_capture_after(1.0)
		"loading":
			# v10: the solo loading screen (tap SOLO -> this -> board).
			_show_loading("GETTING READY", "Solo — free practice vs a random bot.")
			_capture_after(1.0)
		"tourwin0":
			# v10: a World Tour win with stake 0 — the earn offer, never ◉ 0.
			Save.coins = 1000
			_start_tour_match(WorldTour.BOTS[0], 0)
			_demo_tour_win_and_capture()
		"googlepending":
			# v10: the register screen with a Google sign-in pending over
			# 60 s — RETRY + the prominent paste-code row.
			Accounts.debug_begin_pending_return("google")
			_show_auth()
			_auth.show_recovery_ui()
			_capture_after(1.0)
		"tourmatch":
			# v8: a World Tour match in progress (Arjun, stake 100).
			Save.coins = 1000
			_start_tour_match(WorldTour.BOTS[0], 100)
			_demo_shot_and_capture()
		"tourwin":
			# v8: a World Tour win (stake 100 + 100) — pot + DOUBLE offer.
			Save.coins = 1000
			_start_tour_match(WorldTour.BOTS[0], 100)
			_demo_tour_win_and_capture()
		"solowin":
			# v8: a solo win — premium win screen with the WATCH AD offer.
			_start_solo(1)
			_demo_solo_win_and_capture()
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

func _demo_solo_win_and_capture() -> void:
	# Wait for the match to be live, then force a solo win so the
	# premium win screen (practice win + WATCH AD offer) shows.
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
		_match.rules_state["over"] = true
		_match.rules_state["winner"] = 0
		_match._show_result()
		await get_tree().create_timer(0.8).timeout
	_capture()

func _demo_tour_win_and_capture() -> void:
	# The tour match is already running (mode "tour", stakes 100 + 100
	# locked at start) — force the win so the pot + DOUBLE offer show.
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
		_match.rules_state["over"] = true
		_match.rules_state["winner"] = 0
		_match._show_result()
		await get_tree().create_timer(0.8).timeout
	_capture()

func _demo_invite_box() -> void:
	# Canned invite data for the screenshot only (no Supabase here):
	# one 2p invite, one 4p invite, one sent invite, two search results.
	Friends.incoming = [
		{"id": "inv-1", "group_id": "grp-1", "from_id": "p-nimal", "to_id": "me",
			"from_name": "Nimal", "to_name": "Player", "mode": "2p", "stake": 100,
			"status": "pending", "created_at": "2026-11-22T13:00:00+00:00"},
		{"id": "inv-2", "group_id": "grp-2", "from_id": "p-saman", "to_id": "me",
			"from_name": "Saman", "to_name": "Player", "mode": "4p", "stake": 200,
			"status": "pending", "created_at": "2026-11-22T13:05:00+00:00"},
	]
	Friends.outgoing = [
		{"id": "inv-3", "group_id": "grp-3", "from_id": "me", "to_id": "p-kasun",
			"from_name": "Player", "to_name": "Kasun", "mode": "2p", "stake": 50,
			"status": "pending", "created_at": "2026-11-22T12:55:00+00:00"},
	]
	if _home:
		_home._search_results = [
			{"id": "p-nimal", "display_name": "Nimal", "level": 3},
			{"id": "p-saman", "display_name": "Saman", "level": 5},
		]
		_home._toggle_invite_box()

func _demo_invite_box_4p() -> void:
	_demo_invite_box()
	if _home:
		_home._selected_4p = {
			"p-nimal": {"id": "p-nimal", "display_name": "Nimal", "level": 3},
			"p-saman": {"id": "p-saman", "display_name": "Saman", "level": 5},
		}
		_home._refresh_invite_box()

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
