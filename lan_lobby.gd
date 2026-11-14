extends Node

enum State { IDLE, HOSTING, SEARCHING, CONNECTING, JOINED, TESTING }

const APARTMENT := preload("res://courtyard.tscn")
const TEST_MODE := preload("res://test_mode.gd")
const GAME_PORT := 33443
const DISCOVERY_PORT := 33444
const TIMEOUT_MS := 4500
const SEARCH_INTERVAL_MS := 350
const READY_MESSAGE := "혼자 테스트하거나, 같은 네트워크에서 2명이 함께 플레이합니다."

var _state := State.IDLE
var _peer: ENetMultiplayerPeer
var _discovery := PacketPeerUDP.new()
var _query := "JensenHuangSimulator find 3".to_utf8_buffer()
var _reply := "JensenHuangSimulator room 3".to_utf8_buffer()
var _deadline := 0
var _next_search := 0
var _apartment: Node3D

@onready var _menu: Control = $Menu
@onready var _status: Label = %Status
@onready var _host_button: Button = %Host
@onready var _join_button: Button = %Join
@onready var _start_button: Button = %Start
@onready var _test_button: Button = %TestMode
@onready var _back_hint: Label = %BackHint


func _ready() -> void:
	_host_button.pressed.connect(_host_room)
	_join_button.pressed.connect(_find_room)
	_start_button.pressed.connect(_start_game)
	_test_button.pressed.connect(_start_test_mode)
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
	elif _state == State.TESTING and event.is_action_pressed(&"test_reset"):
		_restart_test_mode.call_deferred()
		get_viewport().set_input_as_handled()


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
	_show_lobby("방을 열었습니다. 참여자를 기다리는 중입니다. (1/2)")


func _find_room() -> void:
	if _state != State.IDLE:
		return
	if _discovery.bind(0, "0.0.0.0") != OK:
		_show_lobby("방 검색을 시작할 수 없습니다. 다시 시도해 주세요.")
		return
	_discovery.set_broadcast_enabled(true)
	_state = State.SEARCHING
	_deadline = Time.get_ticks_msec() + TIMEOUT_MS
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
		_show_lobby("2명이 모였습니다. 게임을 시작할 수 있습니다. (2/2)")


func _on_peer_disconnected(_peer_id: int) -> void:
	if _state == State.HOSTING:
		_remove_apartment()
		_peer.refuse_new_connections = false
		_show_lobby("참여자의 연결이 끊겼습니다. 새 참여자를 기다리는 중입니다. (1/2)")


func _on_connected_to_host() -> void:
	_state = State.JOINED
	_show_lobby("방에 들어왔습니다. 호스트가 게임을 시작할 때까지 기다려 주세요. (2/2)")


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
		_open_apartment.rpc(peers[0])


@rpc("authority", "call_local", "reliable")
func _open_apartment(guest_id: int) -> void:
	if _apartment != null or (_state != State.HOSTING and multiplayer.get_unique_id() != guest_id):
		return
	_apartment = APARTMENT.instantiate()
	_apartment.guest_peer_id = guest_id
	add_child(_apartment)
	_menu.hide()


func _start_test_mode() -> void:
	if _state != State.IDLE or _apartment != null:
		return
	_close_network()
	_state = State.TESTING
	_open_test_apartment()


func _open_test_apartment() -> void:
	_apartment = APARTMENT.instantiate()
	add_child(_apartment)
	var test_mode := TEST_MODE.new()
	test_mode.name = "TestMode"
	_apartment.add_child(test_mode)
	_menu.hide()


func _restart_test_mode() -> void:
	if _state != State.TESTING:
		return
	_remove_apartment()
	_open_test_apartment()


func _remove_apartment() -> void:
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
		multiplayer.multiplayer_peer = null


func _show_lobby(message: String) -> void:
	_status.text = message
	_host_button.visible = _state == State.IDLE
	_join_button.visible = _state == State.IDLE
	_test_button.visible = _state == State.IDLE
	_start_button.visible = _state == State.HOSTING
	_start_button.disabled = _state != State.HOSTING or multiplayer.get_peers().is_empty()
	_back_hint.visible = _state != State.IDLE
	_menu.show()
	if _host_button.visible:
		_host_button.grab_focus()
	elif _start_button.visible and not _start_button.disabled:
		_start_button.grab_focus()
