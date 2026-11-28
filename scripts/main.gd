extends Control

## Main — screen manager: Home, Solo/Online match, Shop, How to Play,
## Aim-Assist, matchmaking. Also routes AdMob rewarded-ad rewards and
## handles the --shot=... screenshot mode used for verification.

var _home: HomeScreen = null
var _mode: PlayMenuScreen = null
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
var _search_strict := false # SAME-2-PLAYER search: same level only (p_strict)
var _search_mode := "" # "internet" | "host" | "join" | "invite" — which search is running
## Round 4 search-popup watchdog: a visible search popup with no
## active search (or a timer that stopped advancing) is ALWAYS an
## orphan from a stacked popup — it must never sit frozen on screen.
var _search_watchdog_accum := 0.0
var _search_watchdog_last_elapsed := -1.0
var _search_watchdog_still := 0.0
var _lobby: OnlineLobby = null # v11: the post-match lobby (waiting/ready) — null when no lobby is open
var _lobby_active := false
var _lobby_data := {} # the server `matched` payload the lobby was opened from
var _lobby_elapsed := 0.0
var _lobby_panel: Control = null
var _lobby_status: Label = null
var _lobby_countdown: Label = null
var _lobby_ready_button: Button = null
var _lobby_row_labels := {} # seat -> Label (refreshed on every ready/leave)
var _invite_group_id := "" # the Supabase invite group being joined
var _invite_is_inviter := false # I sent this invite (seat 0)
var _online_lobby: OnlinePlayerLobby = null # §11 lobby screen (player list) — null when closed
var _online_lobby_stake := 0 # stake chosen before the lobby opened; invites from it use this stake
var _invite_banner: Control = null # §11 instant invite banner (top) — null when hidden
var _invite_banner_invite := {} # the invite the banner is showing
var _last_tour_stake := 0 # the stake of the last World Tour match (rematch reuses it)
var _coin_loop_return := "" # v11 coin loop: "online" while a broke-panel
# ad is in flight — when it pays and the balance covers MIN_STAKE, the
# player is offered the return to matchmaking. "" otherwise.
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
	Net.lobby_ready_received.connect(_on_lobby_ready_received) # v11 lobby
	Net.opponent_left.connect(_on_lobby_opponent_left) # v11 lobby only — guarded on _lobby_active; mid-match drops stay with MatchScreen
	Net.queue_failed.connect(_on_queue_failed)
	Net.match_notice.connect(_toast) # non-fatal matchmaking notices (validation) — toast only, search keeps polling
	Net.connection_lost.connect(_on_connection_lost) # L4
	# F13 Phase 2 (v11): the server's authoritative payout, forwarded
	# to the match screen (ignored when no match is running).
	Net.settlement_received.connect(_on_settlement)
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
		# Returning player: show the loading screen (not a black
		# screen) while the saved session is restored — the restore
		# can take seconds on a slow network, and a black screen reads
		# as a hang. The bar moves at real step boundaries, from 0 to
		# a full 100 (held briefly) before home — never a half bar.
		_show_loading("LOADING GAME", "Starting…")
		_loading.set_progress(0.0)
		_loading.set_status("Restoring your sign-in…")
		# Restore the saved Supabase session FIRST (refresh token) —
		# Friends uses the Auth uid for Realtime and presence, and
		# without a session the lobby shows an empty list and this
		# phone never appears in anyone else's lobby. A failed
		# refresh clears the saved tokens; play still works locally
		# and the lobby says "sign in again" instead of an empty list.
		await Accounts.restore_session()
		_loading.set_progress(0.6)
		_loading.set_status("Loading your tables…")
		Friends.start_listening()
		_loading.set_progress(0.9)
		# Finish the bar: target 1.0, then WAIT until it has visibly
		# filled (the 1.5 s minimum pace) + a short hold, so the
		# player actually SEES 0 -> 100 before home — never a jump
		# straight to a full bar.
		_loading.set_progress(1.0)
		_loading.set_status("Ready!")
		if is_instance_valid(_loading):
			await _loading.await_full()
		await get_tree().create_timer(0.15).timeout
		_show_home()
	else:
		# First screen: register / sign in (mandatory — no guest mode).
		_show_auth()

func _process(delta: float) -> void:
	# Round 4 watchdog (runs FIRST, even while a lobby is open):
	# a search popup visible with no active search is an orphan —
	# close it before the player ever has to tap a dead CANCEL.
	_search_watchdog_accum += delta
	if _search_watchdog_accum >= 0.5:
		_search_watchdog_accum = 0.0
		_watchdog_search_popups()
	if _lobby_active:
		# v11 lobby countdown: the match auto-starts after
		# LOBBY_AUTO_START_SECONDS even if someone never taps READY,
		# so a lobby can never stall forever.
		_lobby_elapsed += delta
		if _lobby != null:
			if _lobby_countdown:
				if _lobby.state == OnlineLobby.STATE_WAITING:
					var remain := int(OnlineLobby.LOBBY_AUTO_START_SECONDS - _lobby_elapsed)
					_lobby_countdown.text = "Match starts automatically in %ds — tap READY when you are set." % maxi(0, remain)
				else:
					_lobby_countdown.text = "Starting the match…"
			if _lobby_status:
				_lobby_status.text = _lobby.status_text()
		if _lobby_elapsed >= OnlineLobby.LOBBY_AUTO_START_SECONDS:
			_toast("Starting the match — not everyone tapped READY.")
			_start_match_from_lobby()
		return
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
				# Stop Net's invite polling too: the popup closing
				# alone used to leave it running, and a match found
				# afterwards was dropped (or its own 180 s timeout
				# fired queue_failed over a dead search).
				Net.cancel_p2p_search()
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
	# v11: the lobby popup is a child too — never leave a dangling ref
	# to a freed panel (the lobby functions null these themselves, but
	# _clear can also run from paths that never touched the lobby).
	# _lobby_active MUST reset here too (2026-11-28): _clear frees the
	# lobby panel, so a flag left true would be stale — and a stale
	# true blocks every later _join_invite_room forever.
	if _lobby_active:
		print("[MATCH] LOBBY_ACTIVE false via _clear (stale flag reset — panel freed)")
		_lobby_active = false
		_lobby = null
		_lobby_data = {}
	_lobby_panel = null
	_lobby_status = null
	_lobby_countdown = null
	_lobby_ready_button = null
	_lobby_row_labels.clear()
	# §11: the lobby screen + invite banner are children too — never
	# leave dangling refs to freed panels.
	_online_lobby = null
	_invite_banner = null
	_invite_banner_invite = {}
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

## v11 re-sign-in entry (home SIGN OUT button): sign_out() clears the
## saved session AND the local progress (by design — F7: the next
## player must not inherit it); the cloud profile is untouched, and
## signing back in with the same Gmail restores it via last-write-
## wins. Then the auth screen shows again.
func _on_sign_out_requested() -> void:
	Accounts.sign_out()
	_show_auth()

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
	# v11 re-sign-in entry: sign out (saved session cleared) and show
	# the auth screen again, so the player can sign in again — with
	# the same Gmail (cloud profile restores) or a different one.
	_home.sign_out_requested.connect(_on_sign_out_requested)
	# v11 coin loop: the OUT OF COINS banner's free bot match.
	_home.play_broke_bot.connect(_start_solo_direct)
	_home.invite_accept_chosen.connect(_on_invite_accept_chosen)
	_home.invite_send_chosen.connect(_on_invite_send_chosen)
	_home.group_invite_send_chosen.connect(_on_group_invite_send_chosen)
	_home.refresh()
	Ads.show_home_banner()
	# §11 presence: back on home = "online" (heartbeat goes out now).
	Friends.set_presence_status("online")
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
	# §11: accepting from anywhere clears the banner (if it was showing).
	_hide_invite_banner()
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
	# STAKE_PICKER_OPEN_REQUEST (2026-11-28): the acceptor cannot reach
	# _join_invite_room until this picker confirms — log the request so
	# a stall here is visible instead of silent.
	print("[MATCH] STAKE_PICKER_OPEN_REQUEST flow=invite_accept from=%s group=%s" % [
		String(invite.get("from_name", "?")), String(invite.get("group_id", ""))])
	_show_stake_picker(func(stake: int) -> void:
		print("[MATCH] STAKE_PICKER_CONFIRMED flow=invite_accept group=%s stake=%s" % [
			String(invite.get("group_id", "")), str(stake)])
		_join_invite_room(String(invite.get("group_id", "")), String(invite.get("mode", "2p")), stake, false),
		"Accepting %s's invite — choose YOUR stake (any amount up to your balance). Winner takes the pot (both stakes)." % String(invite.get("from_name", "a friend")),
		"",
		func() -> void:
			print("[MATCH] STAKE_PICKER_CANCELLED flow=invite_accept group=%s" % String(invite.get("group_id", "")))
			_toast("Stake not chosen — the invite stays accepted; tap it again in the invite box to join."))

func _on_invite_send_chosen(player: Dictionary) -> void:
	print("[MATCH] STAKE_PICKER_OPEN_REQUEST flow=invite_send to=%s" % String(player.get("display_name", "?")))
	_show_stake_picker(func(stake: int) -> void:
		print("[MATCH] STAKE_PICKER_CONFIRMED flow=invite_send to=%s stake=%s" % [String(player.get("display_name", "?")), str(stake)])
		var res := await Friends.send_invite(String(player.get("id", "")), String(player.get("display_name", "?")), stake)
		if bool(res.get("ok", false)):
			_toast("Invite sent to %s!" % String(player.get("display_name", "?")))
			# B3: discover the match from here on — the acceptor may
			# form it before the 10 s group poll fires.
			Net.start_match_discovery(String(res.get("group_id", "")), "2p")
		else:
			_toast(String(res.get("error", "Could not send the invite."))),
		"Invite %s to a 1 vs 1 match — choose YOUR stake (any amount up to your balance). Winner takes the pot." % String(player.get("display_name", "?")),
		"",
		func() -> void:
			print("[MATCH] STAKE_PICKER_CANCELLED flow=invite_send to=%s" % String(player.get("display_name", "?"))))

func _on_group_invite_send_chosen(players: Array) -> void:
	# 3-player guard (v11): exactly 2 picks can never be a match.
	# The home UI disables the send button at 2 picks; this is the
	# last check before the stake picker, so a stale signal can never
	# send a 3-player group.
	if players.size() == 2:
		_toast("Matches are 2 players (invite 1 friend) or 4 players (invite 3 friends) — 3-player matches are not supported.")
		return
	print("[MATCH] STAKE_PICKER_OPEN_REQUEST flow=group_invite_send players=%d" % players.size())
	_show_stake_picker(func(stake: int) -> void:
		print("[MATCH] STAKE_PICKER_CONFIRMED flow=group_invite_send players=%d stake=%s" % [players.size(), str(stake)])
		var res := await Friends.send_group_invite(players, stake)
		if bool(res.get("ok", false)):
			_toast("4-player invite sent — the match starts when all accept!")
			# B3: discover the match from here on (see 2p above).
			Net.start_match_discovery(String(res.get("group_id", "")), "4p")
		else:
			_toast(String(res.get("error", "Could not send the invites."))),
		"Invite %d friends to a doubles match — choose YOUR stake (any amount up to your balance). The winning TEAM splits the pot." % players.size(),
		"",
		func() -> void:
			print("[MATCH] STAKE_PICKER_CANCELLED flow=group_invite_send players=%d" % players.size()))

func _on_invite_received(invite: Dictionary) -> void:
	_toast("New invite from %s!" % String(invite.get("from_name", "a friend")))
	if _home:
		_home.refresh()
	# §11 instant invite banner (top of screen): ACCEPT joins the
	# inviter's match directly. Shown only when no match is running —
	# mid-match invites stay in the invite box (the fallback).
	if _match == null and _invite_banner == null:
		_show_invite_banner(invite)

## §11: the instant invite banner at the TOP of the screen.
## "You have an invite — play together with <name>" + ACCEPT (joins
## directly via the normal accept flow) / LATER (dismisses; the invite
## stays in the invite box). One banner at a time; a newer invite
## replaces it.
func _show_invite_banner(invite: Dictionary) -> void:
	_hide_invite_banner()
	_invite_banner_invite = invite
	var banner := PanelContainer.new()
	banner.add_theme_stylebox_override("panel", UiKit.panel_style(UiKit.PANEL, UiKit.GOLD, 18, 2))
	banner.set_anchors_preset(Control.PRESET_TOP_WIDE)
	banner.offset_left = 16
	banner.offset_right = -16
	banner.offset_top = 12
	banner.offset_bottom = 168
	_invite_banner = banner
	var box := VBoxContainer.new()
	box.add_theme_constant_override("separation", 8)
	banner.add_child(box)
	var label := UiKit.body_label("You have an invite — play together with %s" % String(invite.get("from_name", "a friend")), 24)
	label.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	box.add_child(label)
	var row := HBoxContainer.new()
	row.add_theme_constant_override("separation", 10)
	box.add_child(row)
	var accept := UiKit.gold_button("ACCEPT", 26)
	accept.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	accept.custom_minimum_size = Vector2(0, 64)
	accept.pressed.connect(func() -> void:
		var inv: Dictionary = _invite_banner_invite
		_hide_invite_banner()
		_on_invite_accept_chosen(inv))
	row.add_child(accept)
	var later := UiKit.dark_button("LATER", 24)
	later.custom_minimum_size = Vector2(0, 64)
	later.pressed.connect(_hide_invite_banner)
	row.add_child(later)
	add_child(banner)

func _hide_invite_banner() -> void:
	if _invite_banner != null:
		_invite_banner.queue_free()
		_invite_banner = null
	_invite_banner_invite = {}

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
	# The group is dead — no match can form for it, so the discovery
	# poll started when the invite was sent must stop too, or it
	# would poll matches forever for a dead group.
	Net.stop_match_discovery()
	_toast(reason)

func _join_invite_room(group_id: String, mode: String, stake: int, is_inviter: bool) -> void:
	# JOIN_INVITE_ENTER (2026-11-28): log every entry with the guard
	# state — the single most useful line for the next phone test is
	# the acceptor's last [MATCH] line, and this is where the invite
	# flow either starts or silently dies.
	var _match_open := _match != null and is_instance_valid(_match)
	print("[MATCH] JOIN_INVITE_ENTER group=%s mode=%s stake=%s is_inviter=%s lobby_active=%s match_open=%s" % [
		group_id, mode, str(stake), str(is_inviter), str(_lobby_active), str(_match_open)])
	# Already in a lobby / match (e.g. discovery found this match
	# first): joining again would start a second resolution loop whose
	# 180 s timeout could kill the live lobby — do nothing. NEVER
	# silent (2026-11-28): the old bare `return` hid the stall.
	if _lobby_active or _match_open:
		# Stale-flag self-heal: the flag says a lobby is open but the
		# panel is gone (a _clear() freed it without resetting the
		# flag) — reset and continue instead of blocking every later
		# invite forever. A live lobby panel means the return is
		# benign (the lobby is already open for this match).
		if _lobby_active and (_lobby_panel == null or not is_instance_valid(_lobby_panel)):
			print("[MATCH] INVITE_BLOCKED stale lobby flag — no live panel, resetting and continuing")
			_close_lobby()
		else:
			print("[MATCH] INVITE_BLOCKED lobby_active=%s match_open=%s — already in a lobby/match, not starting a second resolution loop" % [str(_lobby_active), str(_match_open)])
			_toast("You're already in a lobby — finish or cancel it first.")
			return
	# The invite-resolution loop supersedes the sender-side discovery
	# poll (it polls the same matches rows, plus the RPC) — stop the
	# discovery so only one poll loop runs.
	Net.stop_match_discovery()
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
	# Round 4 single-popup invariant: close any popup from an
	# earlier search FIRST. Creating a second popup without closing
	# the first orphaned it — the visible one froze at "0s" and its
	# CANCEL/X freed the hidden one (incident 2026-11-28 05:18).
	# _close_search_popup clears _searching_active/_search_mode, so
	# set them again right after.
	_close_search_popup()
	_searching_active = true
	_search_mode = "invite"
	_searching = Control.new()
	UiKit.full_rect(_searching)
	_tag_search_popup(_searching)
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
	if Net.transport == NetClient.TRANSPORT_P2P and NetClient.webrtc_available():
		# v11 P2P: no server room — both sides resolve the match via
		# create_match_from_invites, then connect phone-to-phone.
		# Net emits `matched` when the mesh is up; the lobby runs as usual.
		print("[MATCH] INVITE_P2P_START group=%s mode=%s stake=%s is_inviter=%s" % [group_id, mode, str(stake), str(is_inviter)])
		Net.start_p2p_invite(group_id, Save.player_name, Save.level(), stake, mode, _search_table, is_inviter)
	elif Net.is_connected_to_server():
		# F13 Phase 2: send the Supabase identity with the invite join
		# so a verifying server can check the stake against the real
		# profile. Empty when not signed in (server falls back to
		# Phase 1 clamps / refuses when verification is enforced).
		Net.join_invite_room(group_id, Save.player_name, Save.level(), stake, mode, _search_table, is_inviter, Supabase.user_id, Supabase.access_token)
	else:
		# LEGACY ENet path (transport switch rollback): the frozen server.
		Net.connect_to_server(Save.online_host, NetClient.DEFAULT_PORT)

## Loading screen (2026-11-27, Buddhika's reference look): the same
## gold/red/wood artwork family as home and auth — wood photo
## background, the golden crown "BMS CARROM" logo, a mini carrom
## board in the middle, and at the bottom the title with a gold
## progress bar that fills with REAL progress. The bar ALWAYS
## animates: set_progress() only sets a TARGET; the displayed bar
## climbs toward it at a fixed pace — a full 0 -> 1 takes
## MIN_VISIBLE_S (1.5 s) — so the player SEES the bar fill and only
## then enters. The old behaviour (set_progress jumped the bar
## instantly, so on a fast load it went straight to 100 in one go)
## is the bug Buddhika reported. The old teal screen with animated
## dots is gone.
class LoadingScreen:
	extends Control
	var _bar: ProgressBar
	var _status: Label
	var _board_holder: Control
	var _mini: BoardView
	var _target := 1.0 # where the bar is heading (set_progress sets this)
	var _shown := 0.0 # where the bar visibly is (animated toward _target)
	const MIN_VISIBLE_S := 1.5 # a full 0 -> 100 takes at least this long

	func _init(title_text: String, sub_text: String) -> void:
		mouse_filter = Control.MOUSE_FILTER_IGNORE
		UiKit.full_rect(self)
		var bg := TextureRect.new()
		bg.texture = preload("res://art/bg_home_wood.jpg")
		bg.expand_mode = TextureRect.EXPAND_IGNORE_SIZE
		bg.stretch_mode = TextureRect.STRETCH_SCALE
		bg.mouse_filter = Control.MOUSE_FILTER_IGNORE
		UiKit.full_rect(bg)
		add_child(bg)
		var vb := VBoxContainer.new()
		vb.add_theme_constant_override("separation", 10)
		UiKit.full_rect(vb)
		vb.offset_left = 24
		vb.offset_right = -24
		vb.offset_top = 24
		vb.offset_bottom = -24
		vb.mouse_filter = Control.MOUSE_FILTER_IGNORE
		add_child(vb)
		# Logo (top): golden crown "BMS CARROM" + "PLAY & ENJOY".
		# 400x380 matches the logo's 1200x1140 aspect exactly.
		var logo := TextureRect.new()
		logo.texture = preload("res://art/logo_carrom_loading.png")
		logo.expand_mode = TextureRect.EXPAND_IGNORE_SIZE
		logo.stretch_mode = TextureRect.STRETCH_KEEP_ASPECT_CENTERED
		logo.custom_minimum_size = Vector2(400, 380)
		logo.size_flags_horizontal = Control.SIZE_SHRINK_CENTER
		logo.mouse_filter = Control.MOUSE_FILTER_IGNORE
		vb.add_child(logo)
		# Mini board (middle): the real board, classic, pieces set up —
		# the same embedding home.gd uses (BoardView at (-20,-250)*s,
		# scale s, no backdrop, no labels). _ready() resizes it to the
		# real viewport; 560 is the pre-tree default.
		var center := CenterContainer.new()
		center.size_flags_vertical = Control.SIZE_EXPAND_FILL
		center.mouse_filter = Control.MOUSE_FILTER_IGNORE
		vb.add_child(center)
		_board_holder = Control.new()
		_board_holder.custom_minimum_size = Vector2(560, 560)
		_board_holder.mouse_filter = Control.MOUSE_FILTER_IGNORE
		center.add_child(_board_holder)
		_mini = BoardView.new()
		_mini.board_id = Save.equipped_board
		_mini.striker_id = Save.equipped_striker
		_mini.draw_backdrop = false
		_mini.show_labels = false
		_mini.pieces = CarromPhysics.setup_pieces()
		_fit_board(560.0)
		_board_holder.add_child(_mini)
		# Title + gold progress bar + status (bottom).
		var title := UiKit.title_label(title_text, 30)
		vb.add_child(title)
		_bar = ProgressBar.new()
		_bar.min_value = 0
		_bar.max_value = 100
		_bar.value = 0
		_bar.show_percentage = false
		_bar.custom_minimum_size = Vector2(0, 26)
		_bar.mouse_filter = Control.MOUSE_FILTER_IGNORE
		var bar_bg := StyleBoxFlat.new()
		bar_bg.bg_color = Color(0.10, 0.05, 0.03, 0.95)
		bar_bg.set_corner_radius_all(13)
		bar_bg.border_color = UiKit.GOLD
		bar_bg.set_border_width_all(2)
		var bar_fill := StyleBoxFlat.new()
		bar_fill.bg_color = UiKit.GOLD_LIGHT
		bar_fill.set_corner_radius_all(11)
		_bar.add_theme_stylebox_override("background", bar_bg)
		_bar.add_theme_stylebox_override("fill", bar_fill)
		vb.add_child(_bar)
		_status = UiKit.muted_label(sub_text, 18)
		_status.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
		_status.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
		_status.add_theme_color_override("font_color", Color(0.96, 0.95, 0.92))
		vb.add_child(_status)

	## Resize the mini board to the real viewport (home.gd pattern):
	## as wide as fits after the logo + title + bar chrome.
	func _ready() -> void:
		var vp := get_viewport_rect().size
		if vp.x <= 0.0 or vp.y <= 0.0:
			return
		var chrome := 48.0 + 380.0 + 10.0 * 4.0 + 40.0 + 26.0 + 28.0
		var board_px := clampf(minf(vp.x - 40.0, vp.y - chrome), 280.0, 680.0)
		_board_holder.custom_minimum_size = Vector2(board_px, board_px)
		_fit_board(board_px)

	func _fit_board(board_px: float) -> void:
		var s := board_px / 680.0
		_mini.position = Vector2(-20, -250) * s
		_mini.scale = Vector2(s, s)

	## Real progress target: 0.0 empty, 1.0 full. Clamped — never
	## over/under. The bar does NOT jump to it: _process animates the
	## displayed bar toward the target at the 1.5 s pace, so even a
	## fast load shows the fill happening.
	func set_progress(f: float) -> void:
		_target = clampf(f, 0.0, 1.0)
		if _shown > _target:
			_shown = _target
			_bar.value = _shown * 100.0

	## Snap the bar to an exact value at once (screenshot mode only:
	## captures the loading screen at 25 / 60 / 90 %). Never used by
	## the game itself — the real bar only ever animates.
	func snap_progress(f: float) -> void:
		_target = clampf(f, 0.0, 1.0)
		_shown = _target
		_bar.value = _shown * 100.0

	## True once the bar has visibly filled to 100.
	func is_full() -> bool:
		return _shown >= 1.0

	## Wait until the bar has visibly filled to 100 (the 1.5 s
	## minimum pace) — callers must not enter home/the board before
	## this, or the player never sees the fill.
	func await_full() -> void:
		while is_instance_valid(self) and _shown < 1.0:
			await get_tree().process_frame

	func set_status(text: String) -> void:
		_status.text = text

	func _process(delta: float) -> void:
		if _shown < _target:
			_shown = minf(_target, _shown + delta / MIN_VISIBLE_S)
			_bar.value = _shown * 100.0

## Show the loading screen (no timer — the caller drives what happens
## next). The screenshot mode uses this to capture the screen itself.
func _show_loading(title_text: String, sub_text: String) -> void:
	_clear()
	_loading = LoadingScreen.new(title_text, sub_text)
	add_child(_loading)

## Show the loading screen, wait until the bar has visibly filled
## (~1.5 s), then run `then`. Tap -> loading -> board: a short
## pause, not a choice — and the player sees the fill, not a flash.
func _show_loading_then(title_text: String, sub_text: String, then: Callable) -> void:
	_show_loading(title_text, sub_text)
	var token := _loading
	await _loading.await_full()
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
	# 2026-11-28 Play-screen redesign (user): PLAY opens the
	# three-big-button menu (PlayMenuScreen) — bot, 2 players
	# (auto-connect 1 vs 1), 4 players (auto-connect doubles) —
	# instead of the v3/v10 four-tile mode screen. Same full-screen
	# plain-button layout (proven on Buddhika's phone), no popup
	# overlay. World Tour + NEARBY live on as smaller buttons on the
	# same screen, and SEARCH FRIEND opens the name-search / invite
	# flow, so no mode is removed.
	_clear()
	_mode = PlayMenuScreen.new()
	add_child(_mode)
	_mode.bot_chosen.connect(_start_solo_direct)
	_mode.two_players_chosen.connect(_on_play_two_players)
	_mode.same_two_players_chosen.connect(_on_play_same_two_players)
	_mode.four_players_chosen.connect(_on_play_four_players)
	_mode.search_friend_chosen.connect(_open_friends_invite)
	_mode.tour_chosen.connect(func() -> void:
		_show_stake_picker(func(stake: int) -> void: _start_tour_random(stake),
			"World Tour — a random advanced computer champion (BOT), near your level. Your stake is mirrored by the bot — winner takes the pot (both stakes).",
			"WORLD TOUR — CHOOSE YOUR STAKE"))
	_mode.nearby_chosen.connect(_open_nearby)
	_mode.go_back.connect(_show_home)

## 2026-11-28 Play-screen redesign (user): 2 PLAYERS / 4 PLAYERS
## auto-connect — tap and the player is queued straight into random
## matchmaking (find_match via _start_matchmaking: "FINDING
## OPPONENT" popup, CANCEL leaves the queue). No stake picker, no
## invites from these buttons. The stake is the lobby's standard 100;
## a player with fewer coins stakes their whole balance instead (as
## long as it covers MIN_STAKE); a broke player gets the broke panel,
## same as the old ONLINE path.
func _on_play_two_players() -> void:
	_start_auto_match(2)

func _on_play_four_players() -> void:
	_start_auto_match(4)

func _start_auto_match(players: int) -> void:
	if CoinLoop.is_broke(Save.coins):
		_show_broke_panel("online")
		return
	_start_matchmaking(mini(PlayMenuScreen.AUTO_STAKE, Save.coins), "", players)

## SEARCH FRIEND (Play screen, user 2026-11-28) — back home with the
## invite box open, so the player can search by name and send a 2p or
## 4p invite. The box is the invite flow (send -> accept -> group
## ready -> join room); this is only the route into it. The 2P/4P
## auto-connect buttons never touch this — only SEARCH FRIEND does.
func _open_friends_invite() -> void:
	_show_home()
	if _home:
		_home.open_invite_box()

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
	# v11 coin loop: a broke player tapping ONLINE is routed to the
	# broke panel (bot match + ad + friendly 0-stake) instead of a
	# stake picker they cannot use — the loop back to matchmaking.
	if CoinLoop.is_broke(Save.coins):
		_show_broke_panel("online")
		return
	_show_stake_picker(func(stake: int) -> void: _show_online_players(stake))

## v11 coin loop — the broke-state entry point. One panel, three ways
## back: a free bot match (solo pays zero, always open), a rewarded ad
## paying the normal ladder (first ad +150 — always covers MIN_STAKE),
## or a friendly 0-stake match. When the daily ad cap is already
## reached the ad button is replaced by the daily-bonus ad if it is
## still claimable (it pays even at the cap); otherwise the panel says
## so honestly and the free options stay open. `return_to` is where the
## player goes after the ad pays ("online" = back to the stake picker).
func _show_broke_panel(return_to: String) -> void:
	var parent: Control = _home if _home else self
	var plan := CoinLoop.recovery_plan(Save.coins, Save.ad_count_today, Save.ad_coins_today, Save.can_claim_daily(), Save.daily_bonus_amount())
	var pop: Dictionary = UiKit.popup_window("OUT OF COINS", Vector2(580, 620))
	parent.add_child(pop["dim"])
	var box: VBoxContainer = pop["box"]
	box.add_child(UiKit.body_label("You're out of coins — but you're never stuck. Play a free bot match, or watch a short ad to earn coins and get back into staked matches.", 20))
	if not bool(plan.get("can_recover_today", false)):
		box.add_child(UiKit.body_label(String(plan.get("blocked_reason", "")), 18))
	var bot := UiKit.gold_button("PLAY vs BOT — FREE", 24)
	bot.pressed.connect(func() -> void:
		pop["dim"].queue_free()
		_start_solo_direct())
	box.add_child(bot)
	box.add_child(UiKit.muted_label("Free practice vs a random bot — no coins needed. The win screen lets you watch an ad to earn coins.", 16))
	if bool(plan.get("via_daily_bonus", false)):
		var daily := UiKit.gold_button("DAILY BONUS +%d — WATCH AD" % Save.daily_bonus_amount(), 24)
		daily.pressed.connect(func() -> void:
			pop["dim"].queue_free()
			_coin_loop_return = return_to
			Ads.show_rewarded("daily_bonus"))
		box.add_child(daily)
	elif bool(plan.get("can_recover_today", false)):
		var reward := CoinLoop.next_ad_reward(Save.ad_count_today, Save.ad_coins_today)
		var watch := UiKit.gold_button("WATCH AD  (+%d COINS)" % reward, 24)
		watch.pressed.connect(func() -> void:
			pop["dim"].queue_free()
			_coin_loop_return = return_to
			Ads.show_rewarded(CoinLoop.BROKE_REASON))
		box.add_child(watch)
		box.add_child(UiKit.muted_label("Today: ◉ %d / %d coins from ads" % [Save.ad_coins_today, Save.DAILY_AD_COIN_CAP], 18))
	var friendly := UiKit.dark_button("FRIENDLY MATCH — 0 STAKE", 22)
	friendly.pressed.connect(func() -> void:
		pop["dim"].queue_free()
		_show_online_players(0))
	box.add_child(friendly)
	box.add_child(UiKit.muted_label("A friendly online match costs nothing — no coins won or lost.", 16))
	pop["close"].pressed.connect(func() -> void: pop["dim"].queue_free())

func _show_online_players(stake: int) -> void:
	# §11 online lobby: after the stake, the player sees who is online
	# (radar + live list) and either invites someone or taps a big
	# RANDOM button for worldwide queue matchmaking. The old 2P/4P
	# popup is replaced by this screen — its two RANDOM buttons keep
	# the same "2 PLAYERS" / "4 PLAYERS" labels, so the flow (stake →
	# choose → search popup) is unchanged for the player.
	_open_online_lobby(stake)

## §11: open the online lobby screen (radar + live player list +
## random buttons) as an overlay. The stake is already chosen; invites
## sent from here use it (no second stake picker).
func _open_online_lobby(stake: int) -> void:
	_close_online_lobby()
	_online_lobby_stake = stake
	_online_lobby = OnlinePlayerLobby.new(stake)
	_online_lobby.random_chosen.connect(_on_online_lobby_random)
	_online_lobby.invite_chosen.connect(_on_online_lobby_invite)
	_online_lobby.group_invite_chosen.connect(_on_online_lobby_group_invite)
	_online_lobby.refresh_requested.connect(_on_online_lobby_refresh)
	_online_lobby.go_back.connect(_close_online_lobby)
	add_child(_online_lobby)

func _close_online_lobby() -> void:
	if _online_lobby != null:
		_online_lobby.queue_free()
		_online_lobby = null

func _on_online_lobby_random(players: int) -> void:
	var stake := _online_lobby_stake
	_close_online_lobby()
	_start_matchmaking(stake, "", players)

## 2p invite from the lobby (one tap): the lobby stake is used, so
## there is no second stake picker — the invite goes out immediately.
func _on_online_lobby_invite(player: Dictionary) -> void:
	var res := await Friends.send_invite(String(player.get("id", "")), String(player.get("display_name", "?")), _online_lobby_stake)
	if bool(res.get("ok", false)):
		_toast("Invite sent to %s!" % String(player.get("display_name", "?")))
		# B3: discover the match from here on (see _on_invite_send_chosen).
		Net.start_match_discovery(String(res.get("group_id", "")), "2p")
	else:
		_toast(String(res.get("error", "Could not send the invite.")))

## 4p invite from the lobby: same stake, same 3-player guard as the
## home box (exactly 2 picks can never send — the lobby button is
## disabled at 2, this is the last check).
func _on_online_lobby_group_invite(players: Array) -> void:
	if players.size() == 2:
		_toast("Matches are 2 players (invite 1 friend) or 4 players (invite 3 friends) — 3-player matches are not supported.")
		return
	var res := await Friends.send_group_invite(players, _online_lobby_stake)
	if bool(res.get("ok", false)):
		_toast("4-player invite sent — the match starts when all accept!")
		# B3: discover the match from here on (see _on_invite_send_chosen).
		Net.start_match_discovery(String(res.get("group_id", "")), "4p")
	else:
		_toast(String(res.get("error", "Could not send the invites.")))

func _on_online_lobby_refresh() -> void:
	if _online_lobby == null:
		return
	# No signed-in session (tests / logged-out): the lobby shows the
	# empty state and the random buttons still work.
	if not Supabase.configured or Supabase.user_id == "":
		# A saved session that failed to refresh is NOT a silent empty
		# list — the lobby says "sign in again" (v11 session persistence).
		if Accounts.session_needs_sign_in():
			_online_lobby.set_session_expired()
		else:
			_online_lobby.set_players([])
		return
	var res := await Friends.list_online_players()
	if _online_lobby == null:
		return
	if bool(res.get("ok", false)):
		_online_lobby.set_players(res.get("players", []))
	else:
		_online_lobby.set_players(Friends.online_players)

## The same picker with a caller-chosen continuation + intro note, so
## the LAN flows (host/join) can reuse it with their own wording.
## `title` overrides the picker's title (World Tour uses its own).
func _show_stake_picker(on_confirm: Callable, note: String = "", title: String = "", on_cancel: Callable = Callable()) -> void:
	var parent: Control = _home if _home else self
	var pop := UiKit.stake_picker(Save.coins, on_confirm, note, title) if title != "" else UiKit.stake_picker(Save.coins, on_confirm, note)
	# STAKE_PICKER_CANCELLED (2026-11-28): the picker's X dismisses it
	# WITHOUT calling on_confirm — the old code never logged that, so
	# an abandoned picker looked exactly like a stalled join. The
	# close button's own handler (inside UiKit.stake_picker) frees the
	# popup; this second handler only logs + runs the caller's cancel.
	pop["close"].pressed.connect(func() -> void:
		print("[MATCH] STAKE_PICKER_CANCELLED")
		if on_cancel.is_valid():
			on_cancel.call())
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
	_tag_search_popup(_searching)
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
	_tag_search_popup(_searching)
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

func _start_matchmaking(stake: int, host_ip: String = "", players: int = 2, widen: bool = false, strict: bool = false) -> void:
	# The stake was validated in the picker; re-check defensively (the
	# balance can only have changed via a shop purchase meanwhile).
	if not Stakes.valid_stake(stake, Save.coins):
		_toast("Not enough coins for that stake — watch an ad to earn more.")
		return
	_search_stake = stake
	_search_players = players
	_search_table = Stakes.band_for_stake(stake)
	_search_elapsed = 0.0
	_search_widened = widen
	_search_strict = strict
	_search_mode = "internet"
	_searching_active = true
	# Round 4 single-popup invariant: close any popup from an
	# earlier search FIRST (same orphan bug as _join_invite_room —
	# a stacked popup froze at "0s" with a dead CANCEL).
	# _close_search_popup clears _searching_active/_search_mode, so
	# set them again right after.
	_close_search_popup()
	_searching_active = true
	_search_mode = "internet"
	_searching = Control.new()
	UiKit.full_rect(_searching)
	_tag_search_popup(_searching)
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
	if Net.transport == NetClient.TRANSPORT_P2P and NetClient.webrtc_available():
		# v11 P2P: no server — queue in Supabase, pair via find_match,
		# connect phone-to-phone. Net emits `matched` when the mesh is
		# up, and the lobby flow below runs unchanged.
		Net.start_p2p_search(Save.player_name, Save.level(), _search_table, _search_stake, "4p" if _search_players == 4 else "2p", _search_widened, _search_strict)
	elif Net.is_connected_to_server():
		# F13 Phase 2: Supabase identity rides with the queue request
		# (see _join_invite_room above). Empty when not signed in.
		Net.queue_up(Save.player_name, Save.level(), _search_table, _search_stake, "4p" if _search_players == 4 else "2p", Supabase.user_id, Supabase.access_token)
	elif host_ip != "":
		# LAN join: connect to the discovered host, not the internet server.
		Net.connect_to_server(host_ip, NetClient.DEFAULT_PORT)
	else:
		# LEGACY ENet path (transport switch rollback): the frozen server.
		Net.connect_to_server(Save.online_host, NetClient.DEFAULT_PORT)

func _on_net_connected() -> void:
	if _searching_active:
		if _search_mode == "invite":
			Net.join_invite_room(_invite_group_id, Save.player_name, Save.level(), _search_stake, "4p" if _search_players == 4 else "2p", _search_table, _invite_is_inviter, Supabase.user_id, Supabase.access_token)
		else:
			Net.queue_up(Save.player_name, Save.level(), _search_table, _search_stake, "4p" if _search_players == 4 else "2p", Supabase.user_id, Supabase.access_token)

## v11 random matchmaking — the ONE stable entry point the Play
## screen's "random" button calls (UI worker): pick a stake, then
## queue for a random opponent. `players` is 2 (singles) or 4
## (doubles). This is just _start_matchmaking with the random
## intent named — the server pairs two/four online players of a
## similar level (±2, ±4 after 30 s) on the same stake band; nobody
## picks a name, nobody picks an opponent.
func start_random_match(stake: int, players: int = 2) -> void:
	_start_matchmaking(stake, "", players)

## Random matchmaking entry API for the Play screen (B6, 2026-11-28) —
## THE function the UI agent wires buttons to, including the new
## SAME 2 PLAYER button. `mode` is "2p" or "4p"; `widen` starts the
## search in the ±4 window (default false = ±2, widening to ±4 after
## 30 s on its own); `strict` is the SAME-LEVEL search (p_strict —
## same level only, default false). The stake is the auto stake
## (the lobby's standard 100, capped at the balance); a broke player
## gets the broke panel, same as the old ONLINE path. Existing call
## sites (_start_auto_match, start_random_match) are unchanged — this
## is the new single entry point on top of them.
##   SAME 2 PLAYER button -> start_matchmaking("2p", false, true)
##   2 PLAYERS button     -> start_matchmaking("2p")
##   4 PLAYERS button     -> start_matchmaking("4p")
func start_matchmaking(mode: String, widen: bool = false, strict: bool = false) -> void:
	if CoinLoop.is_broke(Save.coins):
		_show_broke_panel("online")
		return
	var players := 4 if mode == "4p" else 2
	_start_matchmaking(mini(PlayMenuScreen.AUTO_STAKE, Save.coins), "", players, widen, strict)

## SAME 2 PLAYER button handler (B6): strict same-level 1 vs 1. The UI
## agent adds the button + its signal on the Play screen and connects
## that signal to this handler — no other wiring needed.
func _on_play_same_two_players() -> void:
	start_matchmaking("2p", false, true)

func _on_matched(data: Dictionary) -> void:
	# A match found by DISCOVERY (invite sender sitting on home, not
	# searching) arrives here with _searching_active false — it must
	# still open the lobby (2026-11-28: the sender never discovered
	# the match). Only ignore it when a match or lobby is already live.
	if not _searching_active and (_match != null or _lobby_active):
		return
	if not _searching_active:
		# Discovery case: my stake / band were never set by a search —
		# take them from the payload's own seat (the matches row
		# carries every player's stake), so the lobby + match use the
		# real stakes instead of a stale 0.
		_derive_search_stakes_from_payload(data)
	# v11: a match no longer starts the instant the server pairs
	# players — it opens the LOBBY first (roster + READY), and the
	# MatchScreen is built only from _start_match_from_lobby, which
	# keeps the F2/F3 setup-before-add_child contract.
	_open_lobby(data)

## Take my stake + band from a matched payload's players array (the
## row carries every player's stake). No-op when the payload has no
## players array naming me (legacy 2p server payloads) — the search
## stakes stand then.
func _derive_search_stakes_from_payload(data: Dictionary) -> void:
	if not data.has("players"):
		return
	var my_id := Supabase.user_id
	if my_id == "":
		return
	for p in (data["players"] as Array):
		if p is Dictionary and String(p.get("id", "")) == my_id:
			_search_stake = maxi(0, int(p.get("stake", 0)))
			_search_players = 4 if String(data.get("mode", "2p")) == "4p" else 2
			_search_table = Stakes.band_for_stake(_search_stake)
			return

## v11 lobby: show the matched roster and wait for READY taps.
## The search popup is gone; the home screen was cleared like the
## old _on_matched did, so cancelling the lobby goes back via
## _show_home().
func _open_lobby(data: Dictionary) -> void:
	_searching_active = false
	_clear()
	_lobby_data = data
	_lobby = OnlineLobby.from_matched(data, Save.player_name, Save.level(), _search_stake)
	_lobby_active = true
	print("[MATCH] LOBBY_ACTIVE true (lobby opened match=%s)" % String(data.get("match_id", "?")))
	_lobby_elapsed = 0.0
	_lobby_row_labels.clear()
	_lobby_panel = Control.new()
	UiKit.full_rect(_lobby_panel)
	var dim := ColorRect.new()
	dim.color = Color(0, 0, 0, 0.75)
	UiKit.full_rect(dim)
	_lobby_panel.add_child(dim)
	var pop: Dictionary = UiKit.popup_window("MATCH LOBBY", Vector2(560, 620))
	_lobby_panel.add_child(pop["dim"])
	var box: VBoxContainer = pop["box"]
	box.add_child(UiKit.body_label("A random match was found — check the players, then tap READY. The match starts when everyone is ready.", 20))
	_lobby_status = UiKit.body_label(_lobby.status_text(), 22)
	box.add_child(_lobby_status)
	for p in _lobby.players:
		var row := UiKit.body_label(OnlineLobby.row_text(p, _lobby.mode == "4p"), 22)
		_lobby_row_labels[int(p["seat"])] = row
		box.add_child(row)
	box.add_child(UiKit.body_label("Your match points: %d (%s) — 10 pts per coin you pocket, +25 for a covered queen, +%d win bonus." % [Save.match_points, MatchPoints.tier_name(Save.match_points), MatchPoints.WIN_BONUS], 18))
	_lobby_countdown = UiKit.body_label("", 18)
	box.add_child(_lobby_countdown)
	_lobby_ready_button = UiKit.gold_button("I'M READY", 28)
	_lobby_ready_button.pressed.connect(_on_lobby_ready_pressed)
	box.add_child(_lobby_ready_button)
	var cancel := UiKit.dark_button("CANCEL", 24)
	cancel.pressed.connect(_cancel_lobby)
	box.add_child(cancel)
	pop["close"].pressed.connect(_cancel_lobby)
	add_child(_lobby_panel)

func _refresh_lobby_rows() -> void:
	if _lobby == null:
		return
	for p in _lobby.players:
		var row: Label = _lobby_row_labels.get(int(p["seat"]))
		if row:
			row.text = OnlineLobby.row_text(p, _lobby.mode == "4p")
	if _lobby_status:
		_lobby_status.text = _lobby.status_text()

func _on_lobby_ready_pressed() -> void:
	if not _lobby_active or _lobby == null:
		return
	_lobby.mark_ready(_lobby.your_seat)
	Net.send_lobby_ready(_lobby.your_seat)
	if _lobby_ready_button:
		_lobby_ready_button.disabled = true
		_lobby_ready_button.text = "READY — WAITING FOR OTHERS"
	_refresh_lobby_rows()
	_maybe_start_from_lobby()

func _on_lobby_ready_received(data: Dictionary) -> void:
	if not _lobby_active or _lobby == null:
		return
	var seat := OnlineLobby.ready_seat(data)
	if seat < 0:
		return # malformed message — ignore, never an error
	if _lobby.mark_ready(seat):
		_refresh_lobby_rows()
		_maybe_start_from_lobby()

func _maybe_start_from_lobby() -> void:
	if _lobby != null and _lobby.all_ready() and _lobby.begin_start():
		_start_match_from_lobby()

## Build the MatchScreen from the stored `matched` payload — the
## exact body the old _on_matched ran, unchanged apart from reading
## `data` from _lobby_data. In particular the F2 layer 1 + F3
## contract is preserved: setup()/setup_4p() BEFORE add_child, so
## _ready() builds 4-player rules/HUD and reads the server-assigned
## breaker instead of rolling its own.
func _start_match_from_lobby() -> void:
	if not _lobby_active:
		return
	var data: Dictionary = _lobby_data
	_close_lobby()
	_clear()
	# §11 presence: a match is starting — I am "in_match" now.
	Friends.set_presence_status("in_match")
	_match = MatchScreen.new()
	if String(data.get("mode", "2p")) == "4p" and data.has("players"):
		# 4p doubles: the server sends the full seat-ordered roster,
		# our seat and the breaker seat. The roster stakes ARE the
		# server's stakes — setup_4p already plays for them.
		var roster: Array = data["players"]
		var your_seat := int(data.get("your_seat", 0))
		var breaker_seat := int(data.get("breaker_seat", 0))
		_match.setup_4p(roster, your_seat, breaker_seat, Net)
		_match.stakes_verified = bool(data.get("verified_stakes", false))
	else:
		var opp_name := String(data.get("opponent", "Player"))
		var opp_level := int(data.get("opp_level", 1))
		var opp_stake := int(data.get("opp_stake", 0))
		var you_break := bool(data.get("you_break", true))
		# F13 Phase 2: when the server verified the stakes, the
		# VERIFIED stakes win — the server-sent your_stake replaces
		# the claimed _search_stake (they differ when the claim was
		# wrong or the balance changed). Unverified: claimed stakes.
		var stakes := Settlement.apply_verified_stakes(_search_stake, opp_stake,
			int(data.get("your_stake", _search_stake)), opp_stake,
			bool(data.get("verified_stakes", false)))
		_match.setup("online", 0, _search_table, opp_name, opp_level, Net, 0 if you_break else 1, int(stakes["your_stake"]), int(stakes["opp_stake"]))
		_match.stakes_verified = bool(stakes["verified"])
	add_child(_match)
	_match.exit_to_home.connect(_show_home)
	# Rematch goes back to the stake picker — the player chooses a fresh
	# stake for every online match.
	_match.rematch_requested.connect(func() -> void: _show_online_stake())

## F13 Phase 2 (v11): the server settled the finished online match.
## Forwarded to the match screen, which re-prices the held pot (or
## stores it for the result screen). Ignored when no match is running
## or the match already credited the pot.
func _on_settlement(data: Dictionary) -> void:
	if _match:
		_match.apply_server_settlement(data)

## Leave the lobby before the match starts: tell the room (the
## server dissolves it; the rest get opponent_left), drop the
## connection like a cancelled search, and go home.
func _cancel_lobby() -> void:
	if not _lobby_active:
		return
	Net.send_lobby_leave()
	Net.disconnect_client()
	_close_lobby()
	_show_home()

## Free the lobby popup and clear lobby state (no navigation).
func _close_lobby() -> void:
	if _lobby_active:
		print("[MATCH] LOBBY_ACTIVE false (lobby closed)")
	_lobby_active = false
	_lobby = null
	_lobby_data = {}
	_lobby_elapsed = 0.0
	_lobby_status = null
	_lobby_countdown = null
	_lobby_ready_button = null
	_lobby_row_labels.clear()
	if _lobby_panel:
		_lobby_panel.queue_free()
		_lobby_panel = null

## A room-mate left the lobby (server dissolved the room): the match
## never starts. Guarded on _lobby_active — mid-match disconnects
## are MatchScreen's opponent_left path, never this one.
func _on_lobby_opponent_left() -> void:
	if not _lobby_active:
		return
	_close_lobby()
	_show_home()
	_toast("A player left the lobby — the match was cancelled.")

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
	# v11 P2P: cancelling deletes the queue row so a cancelled search
	# is never matched (Net.disconnect_client alone only clears the
	# local objects). No-op on the legacy path.
	if Net.is_p2p_searching():
		Net.cancel_p2p_search()
	Net.disconnect_client()
	# Round 4: sweep ALL search popups, not just _searching — an
	# orphaned popup from an earlier search would otherwise stay
	# visible and look like CANCEL did nothing.
	_free_all_search_popups()
	_searching = null

func _on_queue_failed(message: String) -> void:
	if _lobby_active:
		# The match was already found (lobby open) and then the
		# server failed — close the lobby and go home, then toast.
		_close_lobby()
		_show_home()
	if _searching_active:
		_close_search_popup()
	_toast(message)

## L4: the server connection dropped. Only a search in progress cares
## — a mid-match drop is MatchScreen's opponent_left path, and must
## not show a "search failed" toast over a live match.
func _on_connection_lost() -> void:
	if _lobby_active:
		_close_lobby()
		_show_home()
		_toast("Connection to the matchmaking server was lost — check your connection and try again.")
		return
	if not _searching_active:
		return
	_close_search_popup()
	_toast("Connection to the matchmaking server was lost — check your connection and try again.")

## Shared search-popup teardown (queue_failed / connection_lost /
## invite timeout): clear the flags and free the popup.
##
## ROUND 4 — SINGLE-POPUP INVARIANT (incident 2026-11-28 05:18):
## _join_invite_room and _start_matchmaking used to create a NEW
## search popup WITHOUT closing the old one, so TWO popups could be
## stacked (random search + invite search). _searching pointed at the
## NEW one, the VISIBLE (old) one was orphaned: its timer never
## advanced ("0s" frozen) and its CANCEL/X freed the hidden one, so
## the user perceived "CANCEL does nothing". Teardown therefore
## sweeps EVERY node tagged as a search popup, not just _searching.
## Every search popup is tagged with the "search_popup" meta at
## creation (see _tag_search_popup); the sweep frees them all.
func _close_search_popup() -> void:
	_searching_active = false
	_search_mode = ""
	_free_all_search_popups()
	_searching = null

## Tag a popup dim as a search popup so the sweep/watchdog can find
## it even after _searching has been reassigned or nulled.
func _tag_search_popup(dim: Control) -> void:
	dim.set_meta("search_popup", true)

func _collect_search_popups(node: Node, out: Array) -> void:
	if node is Control and bool(node.get_meta("search_popup", false)):
		out.append(node)
	for c in node.get_children():
		_collect_search_popups(c, out)

func _count_search_popups() -> int:
	var found: Array = []
	_collect_search_popups(self, found)
	return found.size()

func _free_all_search_popups() -> void:
	var found: Array = []
	_collect_search_popups(self, found)
	for p in found:
		if is_instance_valid(p):
			p.queue_free()

## Watchdog force-close (round 4): a search popup is visible but the
## search is dead or its timer has not advanced — close EVERYTHING
## (Net polling too) and tell the player plainly, instead of leaving
## a frozen popup they cannot dismiss. Called from _process.
func _force_close_stuck_search(reason: String) -> void:
	print("[MATCH] WATCHDOG force-closing stuck search popup: %s" % reason)
	if Net.is_p2p_searching():
		Net.cancel_p2p_search()
	Net.disconnect_client()
	_close_search_popup()
	_toast("That search window got stuck — closed it. Try searching again.")

## Watchdog (round 4, every 0.5 s): a visible search popup is only
## legal while a search is running AND its timer is advancing.
##  - popup visible + no active search = orphan (stacked popup from
##    an earlier search) → force-close immediately.
##  - popup visible + active search + timer frozen 5 s = the search
##    branch stopped ticking (e.g. a lobby opened without closing
##    the popup) → force-close with a toast.
## A healthy search advances _search_elapsed every frame, so the
## still-timer resets on every check and never false-fires.
func _watchdog_search_popups() -> void:
	var visible := _count_search_popups()
	if visible == 0:
		_search_watchdog_still = 0.0
		_search_watchdog_last_elapsed = -1.0
		return
	if not _searching_active:
		_force_close_stuck_search("orphan popup (%d visible, no active search)" % visible)
		_search_watchdog_still = 0.0
		_search_watchdog_last_elapsed = -1.0
		return
	if _search_elapsed == _search_watchdog_last_elapsed:
		_search_watchdog_still += 0.5
		if _search_watchdog_still >= 5.0:
			_force_close_stuck_search("timer frozen %.1fs with %d popup(s) visible" % [_search_watchdog_still, visible])
			_search_watchdog_still = 0.0
			_search_watchdog_last_elapsed = -1.0
	else:
		_search_watchdog_last_elapsed = _search_elapsed
		_search_watchdog_still = 0.0

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
	box.add_child(UiKit.body_label("Every tier pays more than the last — but each tier takes more ads. Watch all the ads a tier needs and its coins are yours, exactly as shown. The ladder resets each day.", 20))
	var tier_names := ["1st tier", "2nd tier", "3rd tier", "4th tier", "5th tier and beyond"]
	var current := Save.ad_current_tier()
	var capped := Save.ad_cap_reached()
	for i in range(5):
		var state := ""
		if capped or i + 1 < current:
			state = "  ✓ done"
		elif i + 1 == current:
			var prog := Save.ad_progress()
			if prog > 0:
				state = "  ◀ YOUR NEXT TIER — %d of %d ads watched" % [prog, Save.ad_ads_needed()]
			else:
				state = "  ◀ YOUR NEXT TIER"
		var row := UiKit.body_label("%s — +%d coins · %d ads%s" % [tier_names[i], Save.AD_LADDER[i], Save.AD_LADDER_ADS[i], state], 22)
		if i + 1 == current and not capped:
			row.add_theme_color_override("font_color", UiKit.GOLD_LIGHT)
		box.add_child(row)
	box.add_child(UiKit.muted_label("Today: ◉ %d / %d coins from ads" % [Save.ad_coins_today, Save.DAILY_AD_COIN_CAP], 18))
	# The button states the deal exactly: how many ads are left to watch
	# and the exact coins the tier pays (ad_claim_amount — the cap can
	# shrink it, so the number on the button is the number granted).
	var amount := Save.ad_claim_amount()
	var remaining := Save.ad_ads_remaining()
	var watch_text := "COME BACK TOMORROW"
	if not capped:
		if Save.ad_progress() > 0:
			watch_text = "WATCH %d MORE %s — +%d COINS" % [remaining, "AD" if remaining == 1 else "ADS", amount]
		else:
			watch_text = "WATCH %d %s — +%d COINS" % [remaining, "AD" if remaining == 1 else "ADS", amount]
	var watch := UiKit.gold_button(watch_text, 24)
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

## Every rewarded ad pays from the ladder; the daily cap (2,500) is the
## only limit. Two paths:
##  * "coins" (FREE COINS ladder): a tier pays out only after ALL its
##    ads are watched (2 for tier 1, 3 for tier 2, then 4, 5, 6).
##    Intermediate ads pay nothing; the last ad grants exactly the
##    amount the button showed (Save.ad_claim_amount()).
##  * Every other reason (Daily Bonus, Aim-Assist, broke-panel, solo-win,
##    win-double) pays one tier per ad, on top of unlocking its own
##    reward — unchanged.
func _on_rewarded_earned(reason: String, simulated: bool) -> void:
	var sim := " (test ad simulated)" if simulated else ""
	if reason == "coins":
		# FREE COINS ladder: count this ad toward the current tier.
		# Nothing is granted until the tier's last ad — then the exact
		# amount the button showed is paid, once.
		var needed := Save.ad_ads_needed()
		var amount := Save.ad_claim_amount()
		var progress := Save.record_ladder_ad_progress()
		if progress < needed:
			_toast("Ad %d of %d watched — %d more for +%d coins.%s" % [progress, needed, needed - progress, amount, sim])
		else:
			Save.reset_ladder_progress()
			if amount > 0:
				Save.add_coins(amount)
				Save.record_ad_reward(amount)
				_toast("+%d coins from the ad ladder!%s" % [amount, sim])
			else:
				Save.record_ad_reward(0)
				_toast("Daily ad limit reached — no more ad coins today.%s" % sim)
		if _home:
			_home.refresh()
			Accounts.sync_to_cloud()
		return
	var ladder := Save.ad_next_reward()
	if ladder > 0:
		Save.add_coins(ladder)
		Save.record_ad_reward(ladder)
	else:
		Save.record_ad_reward(0)
	if reason == "broke_coins":
		# v11 coin loop: the broke-panel ad pays the normal ladder, like
		# "coins" — the return to matchmaking is handled below.
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
	# v11 coin loop: the broke-panel ad paid — if the balance now covers
	# the minimum stake, take the player back to matchmaking. The flag
	# is only ever set by the broke panel, so a home-screen ad never
	# hijacks the player into a stake picker.
	if _coin_loop_return != "" and (reason == "broke_coins" or reason == "daily_bonus"):
		var dest := _coin_loop_return
		_coin_loop_return = ""
		if CoinLoop.can_stake(Save.coins):
			_toast("You're back in the game — ◉ %d coins!" % Save.coins)
			if dest == "online":
				_show_online_stake()

func _on_rewarded_failed(reason: String) -> void:
	if reason == "broke_coins":
		# v11 coin loop: the recovery ad failed — no return to queue;
		# the player stays broke and can retry from the broke panel.
		_coin_loop_return = ""
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
			# v11: PLAY opens the three-big-button menu (no popup).
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
		"loading25":
			# Loading screen frozen at 25 % (proof the bar fills).
			_show_loading("LOADING GAME", "Starting…")
			_loading.snap_progress(0.25)
			_capture_after(0.3)
		"loading60":
			# Loading screen frozen at 60 %.
			_show_loading("LOADING GAME", "Starting…")
			_loading.snap_progress(0.60)
			_capture_after(0.3)
		"loading90":
			# Loading screen frozen at 90 %.
			_show_loading("LOADING GAME", "Starting…")
			_loading.snap_progress(0.90)
			_capture_after(0.3)
		"loadinglive":
			# Loading screen mid-fill, live (no snap): captured 0.75 s
			# in, the bar must be about half full — proof the real
			# animation runs, not just the frozen values.
			_show_loading("LOADING GAME", "Starting…")
			_capture_after(0.75)
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
