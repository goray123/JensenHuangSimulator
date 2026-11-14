extends Node

enum State { IDLE, HOSTING, SEARCHING, CONNECTING, JOINED, TESTING, TUTORIAL }

const APARTMENT := preload("res://house.tscn")
const TEST_MODE := preload("res://test_mode.gd")
const GUIDED_TUTORIAL := preload("res://guided_tutorial.gd")
const INTRO := preload("res://intro_cutscene.gd")
const BGM := preload("res://bgm.gd")
const POST_MATCH_ACTIONS := preload("res://ui/post_match_actions.gd")
const REMATCH_NOTICE_SECONDS := 0.4
const TITLE_NOTICE_SECONDS := 0.65
const TITLE_ACK_TIMEOUT_SECONDS := 2.5
const GAME_PORT := 33443
const DISCOVERY_PORT := 33444
const TIMEOUT_MS := 4500
const SEARCH_INTERVAL_MS := 350
## START searches this long (randomized so two players pressing together rarely both host) before hosting.
const AUTO_SEARCH_MIN_MS := 1200
const AUTO_SEARCH_MAX_MS := 2000
const START_HOVER_SCALE := 1.15
const START_HOVER_TIME := 0.12
const READY_MESSAGE := ""
## The round music switches to the last-round track once this many seconds or fewer are left.
const FINAL_MUSIC_SECONDS := 20

## Off in automated tests so they enter the game without waiting for the comic intro.
@export var play_intro := true

var _state := State.IDLE
var _peer: ENetMultiplayerPeer
var _discovery := PacketPeerUDP.new()
var _query := "JensenHuangSimulator find 5".to_utf8_buffer()
var _reply := "JensenHuangSimulator room 5".to_utf8_buffer()
var _deadline := 0
var _next_search := 0
var _apartment: Node3D
var _intro: CanvasLayer
var _intro_done_peers: Array[int] = []
var _host_if_none := false
var _hover_tweens := {}
var _bgm: Node
## A generation identifies votes and delayed decisions across rounds on the same connection.
var _match_id := 0
## Never reset on disconnect: old timers must not match round 1 of a new session.
var _post_round_epoch := 0
var _post_round_menu: CanvasLayer
var _post_round_choices: Array[int] = []
var _post_round_resolution := 0
var _post_round_started_msec := 0
var _post_round_transitioning := false
var _title_notice_elapsed := false
var _title_guest_ready := false

@onready var _menu: Control = $Menu
@onready var _status: Label = %Status
@onready var _status_panel: Control = %StatusPanel
@onready var _start_button: TextureButton = %Start
@onready var _cancel_button: Button = %Cancel
@onready var _tutorial_button: TextureButton = %TutorialButton


func _ready() -> void:
	_bgm = BGM.new()
	_bgm.name = "Bgm"
	add_child(_bgm)
	_start_button.pressed.connect(_find_room.bind(true))
	_cancel_button.pressed.connect(_return_to_menu.bind(READY_MESSAGE))
	_tutorial_button.pressed.connect(_open_tutorial)
	for button: TextureButton in [_start_button, _tutorial_button]:
		button.mouse_entered.connect(_set_hover.bind(button, true))
		button.mouse_exited.connect(_set_hover.bind(button, false))
	multiplayer.peer_connected.connect(_on_peer_connected)
	multiplayer.peer_disconnected.connect(_on_peer_disconnected)
	multiplayer.connected_to_server.connect(_on_connected_to_host)
	multiplayer.connection_failed.connect(_on_connection_failed)
	multiplayer.server_disconnected.connect(_on_host_disconnected)
	_show_lobby(READY_MESSAGE)


func _exit_tree() -> void:
	_close_network()


func _unhandled_key_input(event: InputEvent) -> void:
	if _state != State.IDLE and event.is_action_pressed(&"ui_cancel"):
		_return_to_menu(READY_MESSAGE)
		get_viewport().set_input_as_handled()
	elif _state == State.IDLE and event is InputEventKey and event.pressed and not event.echo and event.physical_keycode == KEY_F2:
		_start_test_mode()
		get_viewport().set_input_as_handled()
	elif _state == State.TESTING and event.is_action_pressed(&"test_reset"):
		_restart_test_mode.call_deferred()
		get_viewport().set_input_as_handled()
	elif _state == State.TUTORIAL and event.is_action_pressed(&"test_reset"):
		_restart_tutorial.call_deferred()
		get_viewport().set_input_as_handled()


func _open_tutorial() -> void:
	if _state != State.IDLE or _apartment != null:
		return
	_close_network()
	_state = State.TUTORIAL
	_open_tutorial_apartment()


func _open_tutorial_apartment() -> void:
	_apartment = APARTMENT.instantiate()
	add_child(_apartment)
	var tutorial := GUIDED_TUTORIAL.new()
	tutorial.name = "GuidedTutorial"
	tutorial.menu_requested.connect(_return_to_menu.bind(READY_MESSAGE), CONNECT_DEFERRED)
	tutorial.replay_requested.connect(_restart_tutorial, CONNECT_DEFERRED)
	_apartment.add_child(tutorial)
	_menu.hide()


func _restart_tutorial() -> void:
	if _state != State.TUTORIAL:
		return
	_remove_apartment()
	_open_tutorial_apartment()


func _host_room() -> void:
	if _state != State.IDLE:
		return
	var peer := ENetMultiplayerPeer.new()
	peer.set_bind_ip("0.0.0.0")
	if peer.create_server(GAME_PORT, 1) != OK:
		_show_lobby("방을 열 수 없습니다. UDP %d 포트가 사용 중인지 확인해 주세요." % GAME_PORT)
		return
	if _discovery.bind(DISCOVERY_PORT, "0.0.0.0") != OK:
		peer.close()
		_show_lobby("방 검색을 시작할 수 없습니다. UDP %d 포트를 확인해 주세요." % DISCOVERY_PORT)
		return
	_state = State.HOSTING
	_peer = peer
	multiplayer.multiplayer_peer = _peer
	_show_lobby("방을 열었습니다. 상대를 기다리는 중입니다. (1/2)")


## Joins an open room on the LAN; with host_if_none, opens a room instead when none answers.
func _find_room(host_if_none := false) -> void:
	if _state != State.IDLE:
		return
	if _discovery.bind(0, "0.0.0.0") != OK:
		_show_lobby("방 검색을 시작할 수 없습니다. 다시 시도해 주세요.")
		return
	_discovery.set_broadcast_enabled(true)
	_state = State.SEARCHING
	_host_if_none = host_if_none
	_deadline = Time.get_ticks_msec() + (randi_range(AUTO_SEARCH_MIN_MS, AUTO_SEARCH_MAX_MS) if host_if_none else TIMEOUT_MS)
	_next_search = 0
	_bgm.play(&"brawl")
	_show_lobby("같은 네트워크에서 참여 가능한 방을 찾는 중입니다…")


func _process(_delta: float) -> void:
	match _state:
		State.HOSTING:
			_answer_searches()
		State.SEARCHING:
			_search_for_host()
		State.CONNECTING:
			if Time.get_ticks_msec() >= _deadline:
				_on_connection_failed()


func _answer_searches() -> void:
	if _discovery.get_available_packet_count() == 0:
		return
	var can_join := _apartment == null and multiplayer.get_peers().is_empty()
	for _packet in mini(32, _discovery.get_available_packet_count()):
		if _discovery.get_packet() == _query and can_join:
			_discovery.set_dest_address(_discovery.get_packet_ip(), _discovery.get_packet_port())
			_discovery.put_packet(_reply)


func _search_for_host() -> void:
	var now := Time.get_ticks_msec()
	if now >= _deadline:
		if _host_if_none:
			_discovery.close()
			_state = State.IDLE
			_host_room()
			return
		_return_to_menu("참여 가능한 방을 찾지 못했습니다. 호스트가 방을 열었는지 확인해 주세요.")
		return
	if now >= _next_search:
		_next_search = now + SEARCH_INTERVAL_MS
		for address in ["255.255.255.255", "127.0.0.1"]:
			_discovery.set_dest_address(address, DISCOVERY_PORT)
			_discovery.put_packet(_query)
	for _packet in mini(32, _discovery.get_available_packet_count()):
		if _discovery.get_packet() == _reply and _discovery.get_packet_port() == DISCOVERY_PORT:
			_connect_to_host(_discovery.get_packet_ip())
			return


func _connect_to_host(address: String) -> void:
	_discovery.close()
	var peer := ENetMultiplayerPeer.new()
	if peer.create_client(address, GAME_PORT) != OK:
		_return_to_menu("방에 연결하지 못했습니다. 다시 시도해 주세요.")
		return
	_state = State.CONNECTING
	_deadline = Time.get_ticks_msec() + TIMEOUT_MS
	_peer = peer
	multiplayer.multiplayer_peer = _peer
	_show_lobby("호스트에게 연결하는 중입니다…")


func _on_peer_connected(_peer_id: int) -> void:
	if _state == State.HOSTING and _apartment == null:
		_start_game()


func _on_peer_disconnected(_peer_id: int) -> void:
	if _state == State.HOSTING:
		if _post_round_resolution == 2:
			_return_to_menu.call_deferred(READY_MESSAGE)
			return
		_remove_apartment()
		_peer.refuse_new_connections = false
		_bgm.play(&"lobby")
		_show_lobby("상대의 연결이 끊겼습니다. 새 상대를 기다리는 중입니다. (1/2)")


func _on_connected_to_host() -> void:
	_state = State.JOINED
	_show_lobby("방에 들어왔습니다. 곧 게임이 시작됩니다. (2/2)")


func _on_connection_failed() -> void:
	_return_to_menu("방에 연결하지 못했습니다. 방이 열려 있는지 확인하고 다시 시도해 주세요.")


func _on_host_disconnected() -> void:
	_return_to_menu(READY_MESSAGE if _post_round_resolution == 2 else "호스트와의 연결이 끊겼습니다.")


func _start_game() -> void:
	if _state != State.HOSTING or _apartment != null:
		return
	var peers := multiplayer.get_peers()
	if peers.size() == 1:
		_peer.refuse_new_connections = true
		_intro_done_peers.clear()
		_play_match_intro.rpc(peers[0])


## Both players watch the intro; the host opens the map once both have finished it.
@rpc("authority", "call_local", "reliable")
func _play_match_intro(guest_id: int) -> void:
	if _apartment != null or _intro != null or (_state != State.HOSTING and multiplayer.get_unique_id() != guest_id):
		return
	_bgm.play(&"brawl")
	_run_intro(_on_match_intro_done)


func _on_match_intro_done() -> void:
	if _intro != null:
		_intro.show_waiting()
	if multiplayer.is_server():
		_report_intro_done()
	elif _state == State.JOINED:
		_report_intro_done.rpc_id(1)


@rpc("any_peer", "call_remote", "reliable")
func _report_intro_done() -> void:
	if not multiplayer.is_server() or _state != State.HOSTING or _apartment != null:
		return
	var sender := multiplayer.get_remote_sender_id()
	var peer_id := sender if sender != 0 else 1
	if peer_id not in _intro_done_peers:
		_intro_done_peers.append(peer_id)
	var peers := multiplayer.get_peers()
	if peers.size() == 1 and 1 in _intro_done_peers and peers[0] in _intro_done_peers:
		_open_apartment.rpc(peers[0], _match_id + 1)


@rpc("authority", "call_local", "reliable")
func _open_apartment(guest_id: int, match_id: int) -> void:
	if match_id <= _match_id or _apartment != null or (_state != State.HOSTING and multiplayer.get_unique_id() != guest_id):
		return
	_match_id = match_id
	_remove_intro()
	_apartment = APARTMENT.instantiate()
	_apartment.guest_peer_id = guest_id
	_connect_round_music()
	add_child(_apartment)
	_menu.hide()


func _start_test_mode() -> void:
	if _state != State.IDLE or _apartment != null:
		return
	_close_network()
	_state = State.TESTING
	_bgm.play(&"brawl")
	_run_intro(_on_test_intro_done)


func _on_test_intro_done() -> void:
	if _state == State.TESTING and _apartment == null:
		_open_test_apartment()


## Shows the comic intro over everything, then calls on_done.
func _run_intro(on_done: Callable) -> void:
	_menu.hide()
	if not play_intro:
		on_done.call_deferred()
		return
	_intro = INTRO.new()
	_intro.name = "Intro"
	_intro.finished.connect(on_done)
	add_child(_intro)


func _remove_intro() -> void:
	if _intro != null:
		_intro.queue_free()
		_intro = null


func _open_test_apartment() -> void:
	_remove_intro()
	_match_id += 1
	_apartment = APARTMENT.instantiate()
	_connect_round_music()
	add_child(_apartment)
	var test_mode := TEST_MODE.new()
	test_mode.name = "TestMode"
	_apartment.add_child(test_mode)
	_menu.hide()


func _restart_test_mode() -> void:
	if _state != State.TESTING or _apartment == null:
		return
	_remove_apartment()
	_open_test_apartment()


## Every new round (match, test, test restart) starts on the brawl track; the host's seconds pick the last-round track.
func _connect_round_music() -> void:
	_bgm.play(&"brawl")
	_apartment.round_seconds_changed.connect(_on_round_seconds_changed)
	_apartment.round_ended.connect(_bgm.stop)
	_apartment.round_ended.connect(_on_round_ended)


## Lives outside the frozen house and its ending. The guided tutorial has its own completion UI.
func _on_round_ended() -> void:
	if _post_round_menu != null or _state not in [State.HOSTING, State.JOINED, State.TESTING]:
		return
	_post_round_started_msec = Time.get_ticks_msec()
	_post_round_epoch += 1
	_post_round_choices.assign([0] if _state == State.TESTING else [0, 0])
	_post_round_resolution = 0
	_post_round_menu = POST_MATCH_ACTIONS.new()
	_post_round_menu.name = "PostMatchActions"
	_post_round_menu.rematch_requested.connect(_request_rematch)
	_post_round_menu.title_requested.connect(_request_title)
	add_child(_post_round_menu)
	_post_round_menu.setup(_post_round_choices.size(), 1 if _state == State.JOINED else 0)
	_post_round_menu.set_choices(_post_round_choices)


func _request_rematch() -> void:
	_request_post_round_choice(1)


func _request_title() -> void:
	_request_post_round_choice(2)


func _request_post_round_choice(choice: int) -> void:
	if not is_instance_valid(_post_round_menu) or not _post_round_menu.actions_visible:
		return
	if _state == State.JOINED:
		_receive_post_round_choice.rpc_id(1, _match_id, choice)
	else:
		_receive_post_round_choice(_match_id, choice)


## Only the host counts votes. A player can switch their rematch vote to title until restart commits.
@rpc("any_peer", "call_remote", "reliable")
func _receive_post_round_choice(match_id: int, choice: int) -> void:
	if not multiplayer.is_server() or not _post_round_is_current(match_id) or _post_round_transitioning or _post_round_resolution == 2:
		return
	if choice not in [1, 2] or Time.get_ticks_msec() - _post_round_started_msec < POST_MATCH_ACTIONS.SHOW_DELAY_SECONDS * 1000.0:
		return
	var sender := multiplayer.get_remote_sender_id()
	var index := 0
	if sender != 0:
		if _state != State.HOSTING or sender != _apartment.guest_peer_id:
			return
		index = 1
	if _post_round_choices[index] == choice:
		return
	var choices := _post_round_choices.duplicate()
	choices[index] = choice
	if _state == State.HOSTING:
		_sync_post_round_choices.rpc(match_id, choices)
	else:
		_sync_post_round_choices(match_id, choices)
	if _post_round_resolution == 1:
		get_tree().create_timer(REMATCH_NOTICE_SECONDS).timeout.connect(_finish_rematch.bind(match_id, _post_round_epoch))


@rpc("authority", "call_local", "reliable")
func _sync_post_round_choices(match_id: int, choices: Array[int]) -> void:
	if not _post_round_is_current(match_id) or choices.size() != _post_round_choices.size():
		return
	for choice in choices:
		if choice not in [0, 1, 2]:
			return
	_post_round_choices.assign(choices)
	_post_round_menu.set_choices(_post_round_choices)
	if 2 in _post_round_choices:
		if _post_round_resolution == 2:
			return
		_post_round_resolution = 2
		_post_round_menu.lock_actions()
		# Both peers show the X for this long before the guest acknowledges it.
		get_tree().create_timer(TITLE_NOTICE_SECONDS).timeout.connect(_after_title_notice.bind(match_id, _post_round_epoch))
		if multiplayer.is_server():
			get_tree().create_timer(TITLE_ACK_TIMEOUT_SECONDS).timeout.connect(_finish_title_fallback.bind(match_id, _post_round_epoch))
	elif _post_round_choices.all(func(choice: int) -> bool: return choice == 1):
		_post_round_resolution = 1


func _post_round_is_current(match_id: int) -> bool:
	return match_id == _match_id and is_instance_valid(_apartment) and _apartment._round_finished and is_instance_valid(_post_round_menu)


func _finish_rematch(match_id: int, epoch: int) -> void:
	if epoch != _post_round_epoch or not _post_round_is_current(match_id) or _post_round_resolution != 1 or _post_round_transitioning:
		return
	if _state == State.TESTING:
		_restart_test_mode.call_deferred()
	elif _state == State.HOSTING and multiplayer.get_peers().size() == 1:
		_begin_rematch.rpc(_apartment.guest_peer_id, match_id + 1)


@rpc("authority", "call_local", "reliable")
func _begin_rematch(guest_id: int, next_match_id: int) -> void:
	if next_match_id != _match_id + 1 or not _post_round_is_current(_match_id) or _post_round_resolution != 1 or _post_round_transitioning:
		return
	_post_round_transitioning = true
	_post_round_menu.lock_actions()
	_reload_match.call_deferred(guest_id, next_match_id, _post_round_epoch)


func _reload_match(guest_id: int, next_match_id: int, epoch: int) -> void:
	if epoch != _post_round_epoch or not _post_round_transitioning or _post_round_resolution != 1 or next_match_id != _match_id + 1:
		return
	_remove_apartment()
	_open_apartment(guest_id, next_match_id)


func _after_title_notice(match_id: int, epoch: int) -> void:
	if epoch != _post_round_epoch or not _post_round_is_current(match_id) or _post_round_resolution != 2:
		return
	_title_notice_elapsed = true
	if multiplayer.is_server():
		_try_complete_title_return(match_id)
	else:
		_ack_title_notice.rpc_id(1, match_id)


@rpc("any_peer", "call_remote", "reliable")
func _ack_title_notice(match_id: int) -> void:
	if not multiplayer.is_server() or not _post_round_is_current(match_id) or _post_round_resolution != 2:
		return
	if multiplayer.get_remote_sender_id() != _apartment.guest_peer_id:
		return
	_title_guest_ready = true
	_try_complete_title_return(match_id)


func _try_complete_title_return(match_id: int) -> void:
	if not _post_round_is_current(match_id) or _post_round_resolution != 2 or not _title_notice_elapsed or _post_round_transitioning:
		return
	if _state == State.TESTING:
		_return_to_menu.call_deferred(READY_MESSAGE)
	elif _state == State.HOSTING and _title_guest_ready:
		_post_round_transitioning = true
		# Keep the host connected until the guest receives this command and leaves.
		_complete_title_return.rpc_id(_apartment.guest_peer_id, match_id)


@rpc("authority", "call_remote", "reliable")
func _complete_title_return(match_id: int) -> void:
	if _post_round_is_current(match_id) and _post_round_resolution == 2 and _title_notice_elapsed:
		_return_to_menu.call_deferred(READY_MESSAGE)


func _finish_title_fallback(match_id: int, epoch: int) -> void:
	if epoch == _post_round_epoch and _post_round_is_current(match_id) and _post_round_resolution == 2:
		_return_to_menu(READY_MESSAGE)


func _clear_post_round() -> void:
	if is_instance_valid(_post_round_menu):
		remove_child(_post_round_menu)
		_post_round_menu.queue_free()
	_post_round_menu = null
	_post_round_choices.clear()
	_post_round_resolution = 0
	_post_round_started_msec = 0
	_post_round_transitioning = false
	_title_notice_elapsed = false
	_title_guest_ready = false


func _on_round_seconds_changed(seconds: int) -> void:
	if seconds <= FINAL_MUSIC_SECONDS:
		_bgm.play(&"final")


func _remove_apartment() -> void:
	_clear_post_round()
	_remove_intro()
	if _apartment != null:
		remove_child(_apartment)
		_apartment.queue_free()
		_apartment = null


func _return_to_menu(message: String) -> void:
	_state = State.IDLE
	_remove_apartment()
	_close_network()
	_show_lobby(message)


func _close_network() -> void:
	_match_id = 0
	_discovery.close()
	if _peer != null:
		_peer.close()
		_peer = null
		multiplayer.multiplayer_peer = OfflineMultiplayerPeer.new()


func _show_lobby(message: String) -> void:
	if _state == State.IDLE:
		_bgm.play(&"lobby")
	_status.text = message
	_start_button.visible = _state == State.IDLE
	_tutorial_button.visible = _state == State.IDLE
	_cancel_button.visible = _state != State.IDLE
	_status_panel.visible = _state != State.IDLE or not message.is_empty()
	for button: TextureButton in [_start_button, _tutorial_button]:
		if _hover_tweens.has(button):
			(_hover_tweens[button] as Tween).kill()
		button.scale = Vector2.ONE
	_menu.show()
	if _start_button.visible:
		_start_button.grab_focus()


## Each image button scales on its own tween, so moving between them never leaves one enlarged.
func _set_hover(button: TextureButton, hovered: bool) -> void:
	if _hover_tweens.has(button):
		(_hover_tweens[button] as Tween).kill()
	var tween := create_tween().set_trans(Tween.TRANS_BACK).set_ease(Tween.EASE_OUT)
	tween.tween_property(button, ^"scale", Vector2.ONE * (START_HOVER_SCALE if hovered else 1.0), START_HOVER_TIME)
	_hover_tweens[button] = tween
