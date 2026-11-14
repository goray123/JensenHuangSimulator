extends SceneTree

# Run two headless instances with --script res://tests/lan_smoke.gd -- host / guest.
const LOBBY := preload("res://lan_lobby.tscn")
const Player := preload("res://player.gd")
const HOST_SPAWN := Vector3(2.1, 0.04, 5.36)
const GUEST_SPAWN := Vector3(2.1, 0.04, 4.24)

class StartBarrier:
	extends Node
	var started := false
	var hits_verified := false
	@rpc("authority", "call_remote", "reliable")
	func begin() -> void:
		started = true
	@rpc("authority", "call_remote", "reliable")
	func finish_hits() -> void:
		hits_verified = true

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
	var barrier := StartBarrier.new()
	barrier.name = "SmokeBarrier"
	root.add_child(barrier)
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
	_check(apartment._pickups.size() == 21, "All spheres, TV, and small props have shared network indices")
	await _wait_frames(8)
	_check(not _lobby.get_node("Menu").visible, "Start opens the apartment for both players")
	_check(_host.position.distance_to(HOST_SPAWN) < 0.08, "Host spawns at the entry")
	_check(_guest.position.distance_to(GUEST_SPAWN) < 0.08, "Guest spawns separately at the entry")
	_check(_host.is_on_floor() and _guest.is_on_floor() if is_host else _guest.reads_local_input,
		"Both players stand on the entry floor and the guest can control their character")
	if is_host:
		barrier.begin.rpc_id(apartment.guest_peer_id)
		await _test_host(apartment.get_node("Pickup2"))
	else:
		await _expect(func() -> bool: return barrier.started, "Both peers finish checking spawn positions before movement begins")
		await _test_guest()
	if not _failed:
		print("LAN smoke test passed (%s)." % args[0])
	quit(int(_failed))


func _test_host(second: RigidBody3D) -> void:
	await _expect(func() -> bool: return _guest.held_pickup == _pickup, "Guest movement and pickup reach the host")
	var guest_launch: Dictionary = {}
	_guest.held_pickup_changed.connect(func(is_holding: bool) -> void:
		if not is_holding and guest_launch.is_empty():
			guest_launch["velocity"] = _pickup.linear_velocity
	)
	_check(_guest.position.x < 0.5 and _guest.position.z < 2.0, "The host receives both axes of guest movement")
	_check(_guest.rotation.y > 1.0, "The host receives guest turning")
	_check(_host.position.distance_to(HOST_SPAWN) < 0.08 and _status.text == "손: 비어 있음", "Guest input affects only the guest")
	var from := _pickup.global_position
	await _expect(func() -> bool: return _guest.held_pickup == null and _pickup.global_position.distance_to(from) > 0.35,
		"Guest throw moves the shared pickup on the host")
	_check(guest_launch.has("velocity") and (guest_launch["velocity"] as Vector3).length() <= 10.001, "The host uses the guest's charged speed within zero to ten")
	if guest_launch.has("velocity"):
		var direction := (guest_launch["velocity"] as Vector3).normalized()
		_check(absf(rad_to_deg(asin(direction.y)) - 25.0) < 0.01, "The guest's throw uses the merged 25-degree angle")
	_key(KEY_W, true)
	await _expect(func() -> bool: return _host.position.z < -1.05, "Host can also walk into the apartment")
	_key(KEY_W, false)
	await _tap(KEY_E)
	_check(_host.held_pickup == second and _status.text.contains("손: 구"), "Host can pick up a sphere and see their own HUD")
	_key(KEY_T, true)
	await _wait_frames(20)
	_key(KEY_T, false)
	var tv: RigidBody3D
	for item in _lobby.get_node("Apartment")._pickups:
		if item.get_meta(&"pickup_name", "") == "TV":
			tv = item
	tv.global_position = _guest.global_position + Vector3.UP * 0.8
	await _expect(func() -> bool: return _guest.held_pickup == tv, "A guest can also pick up the shared TV")
	var tv_from := tv.global_position
	await _expect(func() -> bool: return _guest.held_pickup == null and tv.global_position.distance_to(tv_from) > 0.35, "A charged TV throw is simulated by the host")
	await _test_hits_host(_lobby.get_node("Apartment"))
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
	_check(_status.text.contains("손: 구"), "Guest's HUD tracks their own holding state")
	_key(KEY_T, true)
	await _wait_frames(12)
	_check(_guest.get_node("ThrowTrajectory").visible, "Guest can aim before throwing")
	var from := _pickup.global_position
	var charged_speed: float = _lobby.get_node("Apartment/HUD/ThrowPower").value
	_check(charged_speed > 0.1 and charged_speed < 10.0, "Snapshots preserve the guest's charge timer")
	_key(KEY_T, false)
	await _expect(func() -> bool: return _guest.held_pickup == null and _pickup.global_position.distance_to(from) > 0.35,
		"Guest sees the shared throw after releasing T")
	await _expect(func() -> bool: return _host.held_pickup != null, "Guest sees the host move and pick up another sphere")
	_check(_host.position.z < -1.05 and _status.text == "손: 비어 있음", "Host input affects only the host")
	var host_pickup := _host.held_pickup
	var host_release := host_pickup.global_position
	await _expect(func() -> bool: return _host.held_pickup == null and host_pickup.global_position.distance_to(host_release) > 0.35,
		"Guest sees the host throw the shared sphere")
	var tv: RigidBody3D
	for item in _lobby.get_node("Apartment")._pickups:
		if item.get_meta(&"pickup_name", "") == "TV":
			tv = item
	await _expect(func() -> bool: return tv.global_position.distance_to(_guest.global_position + Vector3.UP * 0.8) < 0.1, "Guest receives the shared TV transform")
	await _tap(KEY_E)
	await _expect(func() -> bool: return _guest.held_pickup == tv, "Guest sees the TV attached with its prop-specific hand offset")
	_check(_status.text.contains("TV"), "The guest's HUD names the held TV")
	_key(KEY_T, true)
	await _wait_frames(60)
	_check(_lobby.get_node("Apartment/HUD/ThrowPower").value > 9.9, "Guest charging reaches ten despite regular snapshots")
	var tv_from := tv.global_position
	_key(KEY_T, false)
	await _expect(func() -> bool: return _guest.held_pickup == null and tv.global_position.distance_to(tv_from) > 0.35, "Guest sees the charged TV throw")
	await _test_hits_guest(_lobby.get_node("Apartment").get_node("Pickup1"))
	await _tap(KEY_ESCAPE)
	_check(_lobby.get_node_or_null("Apartment") == null and _lobby.get_node("%Join").visible, "Esc returns the guest to the main menu")


func _test_hits_host(apartment: Node3D) -> void:
	var sphere := apartment.get_node("Pickup1") as RigidBody3D
	# Earlier throw tests must not introduce unrelated hits during timing checks.
	for item in apartment._pickups:
		item.freeze = true
		item.disarm()
	_host.position = Vector3(-2, 0.01, 3)
	_host.rotation.y = 0
	_guest.position = Vector3(-2, 0.01, 1.2)
	_host.hold_pickup(sphere)
	_host.release_pickup(true, _host.throw_velocity_at_speed(8.0))
	await _expect(func() -> bool: return _guest.is_stunned(), "The host's projectile stuns the guest on the authoritative server")
	var hit_position := _guest.global_position
	await _wait_frames(20)
	_check(_guest.is_stunned() and _guest.global_position.distance_to(hit_position) < 0.02, "The server blocks guest movement during the stun")
	await _wait_frames(20)
	_check(not _guest.is_stunned(), "The server releases the guest's movement after half a second")
	_host.position = Vector3(-2, 0.01, 1.2)
	_guest.position = Vector3(-2, 0.01, 3)
	_guest.rotation.y = 0
	_guest.hold_pickup(sphere)
	await _expect(func() -> bool: return _host.is_stunned(), "The guest's projectile can also stun the host")
	await _wait_frames(40)
	_check(not _host.is_stunned(), "The host recovers after the same stun duration")
	root.get_node("SmokeBarrier").finish_hits.rpc_id(apartment.guest_peer_id)


func _test_hits_guest(sphere: RigidBody3D) -> void:
	await _expect(func() -> bool: return _guest.is_stunned(), "The guest receives the reliable hit event from the host")
	var torso := _guest.get_node("Torso") as MeshInstance3D
	var hit_position := _guest.global_position
	var saw_red := false
	_key(KEY_D, true)
	for _frame in 18:
		saw_red = saw_red or torso.material_overlay != null
		await physics_frame
	_check(saw_red and torso.material_overlay == null, "The guest sees the red blink and its end after 0.2 seconds")
	_check(_guest.is_stunned() and _guest.global_position.distance_to(hit_position) < 0.08, "Guest input cannot bypass the movement lock")
	await _expect(func() -> bool: return not _guest.is_stunned() and _guest.position.x > hit_position.x + 0.1, "Guest movement resumes when the hit expires")
	_key(KEY_D, false)
	await _expect(func() -> bool: return _guest.held_pickup == sphere and _guest.position.z > 2.9, "The next projectile is shared with the guest")
	_key(KEY_T, true)
	await _wait_frames(45)
	_key(KEY_T, false)
	await _expect(func() -> bool: return _host.is_stunned(), "A guest throw produces a synchronized hit on the host")
	_check(not _guest.is_stunned(), "Throwing does not stun the thrower")
	await _wait_frames(15)
	_check(_host.get_node("Torso").material_overlay == null, "The remote host's red flash restores its appearance")
	await _expect(func() -> bool: return not _host.is_stunned(), "The remote host's stun also expires")
	await _expect(func() -> bool: return root.get_node("SmokeBarrier").hits_verified, "The host finishes hit checks before the guest disconnects")


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
