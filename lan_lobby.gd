extends Node

enum State { IDLE, HOSTING, SEARCHING, CONNECTING, JOINED, TESTING, TUTORIAL }

const APARTMENT := preload("res://house.tscn")
const TEST_MODE := preload("res://test_mode.gd")
const GUIDED_TUTORIAL := preload("res://guided_tutorial.gd")
const INTRO := preload("res://intro_cutscene.gd")
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
var _hover_tween: Tween

@onready var _menu: Control = $Menu
@onready var _status: Label = %Status
@onready var _status_panel: Control = %StatusPanel
@onready var _start_button: TextureButton = %Start
@onready var _cancel_button: Button = %Cancel
@onready var _tutorial_button: Button = %TutorialButton


func _ready() -> void:
	_start_button.pressed.connect(_find_room.bind(true))
	_start_button.mouse_entered.connect(_set_start_hover.bind(true))
	_start_button.mouse_exited.connect(_set_start_hover.bind(false))
	_cancel_button.pressed.connect(_return_to_menu.bind(READY_MESSAGE))
	_tutorial_button.pressed.connect(_open_tutorial)
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
		_remove_apartment()
		_peer.refuse_new_connections = false
		_show_lobby("상대의 연결이 끊겼습니다. 새 상대를 기다리는 중입니다. (1/2)")


func _on_connected_to_host() -> void:
	_state = State.JOINED
	_show_lobby("방에 들어왔습니다. 곧 게임이 시작됩니다. (2/2)")


func _on_connection_failed() -> void:
	_return_to_menu("방에 연결하지 못했습니다. 방이 열려 있는지 확인하고 다시 시도해 주세요.")


func _on_host_disconnected() -> void:
	_return_to_menu("호스트와의 연결이 끊겼습니다.")


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
		_open_apartment.rpc(peers[0])


@rpc("authority", "call_local", "reliable")
func _open_apartment(guest_id: int) -> void:
	if _apartment != null or (_state != State.HOSTING and multiplayer.get_unique_id() != guest_id):
		return
	_remove_intro()
	_apartment = APARTMENT.instantiate()
	_apartment.guest_peer_id = guest_id
	add_child(_apartment)
	_menu.hide()


func _start_test_mode() -> void:
	if _state != State.IDLE or _apartment != null:
		return
	_close_network()
	_state = State.TESTING
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
	_apartment = APARTMENT.instantiate()
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


func _remove_apartment() -> void:
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
	_discovery.close()
	if _peer != null:
		_peer.close()
		_peer = null
		multiplayer.multiplayer_peer = OfflineMultiplayerPeer.new()


func _show_lobby(message: String) -> void:
	_status.text = message
	_start_button.visible = _state == State.IDLE
	_tutorial_button.visible = _state == State.IDLE
	_cancel_button.visible = _state != State.IDLE
	_status_panel.visible = _state != State.IDLE or not message.is_empty()
	if _hover_tween != null:
		_hover_tween.kill()
	_start_button.scale = Vector2.ONE
	_menu.show()
	if _start_button.visible:
		_start_button.grab_focus()


func _set_start_hover(hovered: bool) -> void:
	if _hover_tween != null:
		_hover_tween.kill()
	_hover_tween = create_tween().set_trans(Tween.TRANS_BACK).set_ease(Tween.EASE_OUT)
	_hover_tween.tween_property(_start_button, ^"scale", Vector2.ONE * (START_HOVER_SCALE if hovered else 1.0), START_HOVER_TIME)
