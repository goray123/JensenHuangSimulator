extends SceneTree

# Run two headless instances with --script res://tests/lan_smoke.gd -- host / guest.
const LOBBY := preload("res://lan_lobby.tscn")
const Player := preload("res://player.gd")
const HOST_SPAWN := Vector3(2.1, 0.04, 5.36)
const GUEST_SPAWN := Vector3(2.1, 0.04, 4.24)

var _lobby: Node
var _host: Player
var _guest: Player
var _status: Label
var _pickup: RigidBody3D
var _failed := false


func _initialize() -> void:
	_run.call_deferred()


func _run() -> void:
	var args := OS.get_cmdline_user_args()
	if args.size() != 1 or args[0] not in ["host", "guest"]:
		push_error("Specify host or guest after --.")
		quit(1)
		return
	create_timer(20.0).timeout.connect(func() -> void:
		push_error("LAN smoke test timed out (%s)." % args[0])
		quit(1)
	)
	var is_host := args[0] == "host"
	_lobby = LOBBY.instantiate()
	root.add_child(_lobby)
	var start := _lobby.get_node("%Start") as Button
	if is_host:
		_lobby.get_node("%Host").pressed.emit()
		_check(start.visible and start.disabled, "Only the host sees Start, disabled before joining")
		await _lobby.multiplayer.peer_connected
		await physics_frame
		_check(not start.disabled, "Joining enables the host's Start button")
		start.pressed.emit()
	else:
		_lobby.get_node("%Join").pressed.emit()
		await _lobby.child_entered_tree
		_check(not start.visible, "The guest cannot start the game")

	await physics_frame
	var apartment := _lobby.get_node("Apartment")
	_host = apartment.get_node("Player")
	_guest = apartment.get_node("Guest")
	_status = apartment.get_node("HUD/PickupStatus")
	_pickup = apartment.get_node("Pickup3")
	await _wait_frames(8)
	_check(not _lobby.get_node("Menu").visible, "Start opens the apartment for both players")
	_check(_host.position.distance_to(HOST_SPAWN) < 0.08, "Host spawns at the entry")
	_check(_guest.position.distance_to(GUEST_SPAWN) < 0.08, "Guest spawns separately at the entry")
	_check(_host.is_on_floor() and _guest.is_on_floor() if is_host else _guest.reads_local_input,
		"Both players stand on the entry floor and the guest can control their character")
	if is_host:
		await _test_host(apartment.get_node("Pickup2"))
	else:
		await _test_guest()
	if not _failed:
		print("LAN smoke test passed (%s)." % args[0])
	quit(int(_failed))


func _test_host(second: RigidBody3D) -> void:
	await _expect(func() -> bool: return _guest.held_pickup == _pickup, "Guest movement and pickup reach the host")
	_check(_guest.position.x < 0.5 and _guest.position.z < 2.0, "The host receives both axes of guest movement")
	_check(_guest.rotation.y > 1.0, "The host receives guest turning")
	_check(_host.position.distance_to(HOST_SPAWN) < 0.08 and _status.text == "손: 비어 있음", "Guest input affects only the guest")
	var from := _pickup.global_position
	await _expect(func() -> bool: return _guest.held_pickup == null and _pickup.global_position.distance_to(from) > 0.35,
		"Guest throw moves the shared pickup on the host")
	_key(KEY_W, true)
	await _expect(func() -> bool: return _host.position.z < -1.05, "Host can also walk into the apartment")
	_key(KEY_W, false)
	await _tap(KEY_E)
	_check(_host.held_pickup == second and _status.text.contains("구를 들고 있음"), "Host can pick up a sphere and see their own HUD")
	_key(KEY_T, true)
	await _wait_frames(20)
	_key(KEY_T, false)
	await _expect(func() -> bool: return _lobby.get_node_or_null("Apartment") == null, "The host returns to the lobby when the guest leaves")
	_check(_lobby.get_node("%Start").disabled, "Leaving frees the guest slot and disables Start")


func _test_guest() -> void:
	_key(KEY_W, true)
	await _expect(func() -> bool: return _guest.position.z < 1.75, "Guest's forward input moves their character")
	_key(KEY_W, false)
	_key(KEY_A, true)
	await _expect(func() -> bool: return _guest.position.x < 0.35, "Guest's sideways input moves their character")
	_key(KEY_A, false)
	await _wait_frames(8)
	await _tap(KEY_E)
	await _expect(func() -> bool: return _guest.held_pickup == _pickup, "Guest sees the sphere attach to their hand")
	_check(_status.text.contains("구를 들고 있음"), "Guest's HUD tracks their own holding state")
	_key(KEY_T, true)
	await _wait_frames(12)
	_check(_guest.get_node("ThrowTrajectory").visible, "Guest can aim before throwing")
	var from := _pickup.global_position
	_key(KEY_T, false)
	await _expect(func() -> bool: return _guest.held_pickup == null and _pickup.global_position.distance_to(from) > 0.35,
		"Guest sees the shared throw after releasing T")
	await _expect(func() -> bool: return _host.held_pickup != null, "Guest sees the host move and pick up another sphere")
	_check(_host.position.z < -1.05 and _status.text == "손: 비어 있음", "Host input affects only the host")
	var host_pickup := _host.held_pickup
	var host_release := host_pickup.global_position
	await _expect(func() -> bool: return _host.held_pickup == null and host_pickup.global_position.distance_to(host_release) > 0.35,
		"Guest sees the host throw the shared sphere")
	await _tap(KEY_ESCAPE)
	_check(_lobby.get_node_or_null("Apartment") == null and _lobby.get_node("%Join").visible, "Esc returns the guest to the main menu")


func _expect(condition: Callable, message: String) -> void:
	for _frame in 360:
		if condition.call():
			return
		await physics_frame
	_check(false, message)


func _check(condition: bool, message: String) -> void:
	if not condition:
		_failed = true
		push_error(message)


func _wait_frames(frames: int) -> void:
	for _frame in frames:
		await physics_frame


func _tap(key: Key) -> void:
	_key(key, true)
	await _wait_frames(2)
	_key(key, false)


func _key(key: Key, pressed: bool) -> void:
	var event := InputEventKey.new()
	event.keycode = key
	event.physical_keycode = key
	event.pressed = pressed
	Input.parse_input_event(event)
	Input.flush_buffered_events()
