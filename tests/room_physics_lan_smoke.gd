extends SceneTree

# Run the host and guest together; other LAN tests use these same room ports.
const LOBBY := preload("res://lan_lobby.tscn")
const Player := preload("res://player.gd")
const STOOL_POSITION := Vector3(6.5, 0.065, -2.0)
const WAIT_POSITION := Vector3(4.7, 0.065, -1.0)

class PhysicsBarrier:
	extends Node
	var stage := 0
	var guest_stage := 0
	var pose := Transform3D.IDENTITY
	var body_paths: Array[String] = []
	@rpc("authority", "call_remote", "reliable")
	func advance(value: int, body_pose: Transform3D, paths: Array[String]) -> void:
		stage = maxi(stage, value)
		pose = body_pose
		body_paths = paths
	@rpc("any_peer", "call_remote", "reliable")
	func acknowledge(value: int) -> void:
		guest_stage = maxi(guest_stage, value)

var _lobby: Node
var _apartment: Node3D
var _host: Player
var _guest: Player
var _stool: RigidBody3D
var _barrier: PhysicsBarrier
var _paths: Array[String] = []
var _failed := false


func _initialize() -> void:
	_run.call_deferred()


func _run() -> void:
	var args := OS.get_cmdline_user_args()
	if args.size() != 1 or args[0] not in ["host", "guest"]:
		push_error("Specify host or guest after --.")
		quit(1)
		return
	create_timer(30.0).timeout.connect(func() -> void:
		push_error("Room physics LAN smoke test timed out (%s)." % args[0])
		quit(1)
	)
	var is_host := args[0] == "host"
	_barrier = PhysicsBarrier.new()
	_barrier.name = "RoomPhysicsSmokeBarrier"
	root.add_child(_barrier)
	_lobby = LOBBY.instantiate()
	_lobby.play_intro = false
	root.add_child(_lobby)
	if is_host:
		_lobby.get_node("%Host").pressed.emit()
		if not await _expect(func() -> bool: return not _lobby.get_node("%Start").disabled,
			"The guest joins the real LAN room"):
			return
		_lobby.get_node("%Start").pressed.emit()
	else:
		_lobby.get_node("%Join").pressed.emit()
	if not await _expect(func() -> bool: return _lobby.get_node_or_null("Apartment") != null,
		"Both peers load the apartment"):
		return
	await _wait_frames(8)
	_apartment = _lobby.get_node("Apartment")
	_host = _apartment.get_node("Player")
	_guest = _apartment.get_node("Guest")
	_verify_body_lists(is_host)
	if _failed:
		quit(1)
		return
	if is_host:
		await _test_host()
	else:
		await _test_guest()
	_key(KEY_W, false)
	if not _failed:
		print("Room physics LAN smoke test passed (%s)." % args[0])
	quit(int(_failed))


func _verify_body_lists(is_host: bool) -> void:
	var furniture: Array = _apartment._room_physics.bodies
	var all_bodies: Array = _apartment._physics_bodies
	_check(_apartment._pickups.size() == 21 and not furniture.is_empty(),
		"Furniture physics preserves all 21 original pickup ownership entries")
	_check(all_bodies.size() == 21 + furniture.size(),
		"Both peers register every pickup and furniture body for snapshots")
	for index in all_bodies.size():
		var body := all_bodies[index] as RigidBody3D
		_paths.append(str(_apartment.get_path_to(body)))
		if index < 21:
			_check(body == _apartment._pickups[index],
				"Pickup snapshot indices keep their original stable ordering")
		else:
			_check(body == furniture[index - 21] and body.is_in_group(&"dynamic_furniture")
				and not body.is_in_group(&"pickups"),
				"Furniture follows the pickup range without becoming E-pickable")
		var volume: float = body.get_meta(&"physics_volume", 0.0)
		_check(volume > 0.0 and is_equal_approx(body.mass, maxf(volume * 40.0, 0.02)),
			"Both peers use body-volume-proportional mass")
		_check(body.freeze != is_host,
			"Only the host simulates unheld bodies; the guest keeps snapshot bodies frozen")
		if body.name == &"Stool00":
			_stool = body
	_check(_stool != null, "Both peers expose the same authored stool as a dynamic body")
	var furniture_paths: Array[String] = []
	for body in furniture:
		furniture_paths.append(str(_apartment.get_path_to(body)))
	var sorted_paths := furniture_paths.duplicate()
	sorted_paths.sort()
	_check(furniture_paths == sorted_paths, "Furniture snapshot indices use stable authored path ordering")


func _test_host() -> void:
	if not await _expect(func() -> bool: return _barrier.guest_stage >= 1,
		"The guest validates its complete physics body list before fixture changes"):
		return
	# Isolate contact response from the rest of the naturally moving room.
	# All furniture remains registered, so every pose still passes through real snapshots.
	for index in _apartment._physics_bodies.size():
		var body: RigidBody3D = _apartment._physics_bodies[index]
		body.freeze = true
		body.linear_velocity = Vector3.ZERO
		body.angular_velocity = Vector3.ZERO
		if body.has_method(&"disarm"):
			body.disarm()
		body.global_position = Vector3(50.0 + index * 4.0, 3.0, 0.0)
	_prepare_push(_host, _guest)
	await _wait_frames(8)
	var initial_pose := _stool.global_transform
	_advance(1, initial_pose)
	if not await _expect(func() -> bool: return _barrier.guest_stage >= 2,
		"The guest sees the initial stool pose before the host walks into it"):
		return
	_key(KEY_W, true)
	await _wait_frames(100)
	_key(KEY_W, false)
	await _wait_frames(10)
	_stool.freeze = true
	var host_push_pose := _stool.global_transform
	_check(_horizontal_distance(host_push_pose.origin, initial_pose.origin) > 0.12,
		"The host pushes real furniture by walking into it with W")
	_advance(2, host_push_pose)
	if not await _expect(func() -> bool: return _barrier.guest_stage >= 3,
		"The guest receives and checks the host's pushed furniture pose"):
		return
	_prepare_push(_guest, _host)
	await _wait_frames(8)
	initial_pose = _stool.global_transform
	_advance(3, initial_pose)
	if not await _expect(func() -> bool: return _barrier.guest_stage >= 4,
		"The guest completes real keyboard movement into the stool"):
		return
	await _wait_frames(12)
	_stool.freeze = true
	var guest_push_pose := _stool.global_transform
	_check(_horizontal_distance(guest_push_pose.origin, initial_pose.origin) > 0.12,
		"The server applies the guest player's contact force to furniture")
	_advance(4, guest_push_pose)
	if not await _expect(func() -> bool: return _barrier.guest_stage >= 5,
		"The guest sees its own push reflected by authoritative snapshots"):
		return
	_place_stool()
	_host.global_position = WAIT_POSITION
	_guest.global_position = WAIT_POSITION + Vector3.RIGHT * 0.8
	await _wait_frames(8)
	initial_pose = _stool.global_transform
	_advance(5, initial_pose)
	if not await _expect(func() -> bool: return _barrier.guest_stage >= 6,
		"Both peers agree on the furniture pose before a turning impulse"):
		return
	_stool.freeze = false
	_stool.sleeping = false
	_stool.apply_impulse(Vector3(0.0, 0.0, -_stool.mass * 3.0), Vector3(0.35, 0.5, 0.0))
	await _wait_frames(18)
	_stool.freeze = true
	var rotated_pose := _stool.global_transform
	_check(initial_pose.basis.get_rotation_quaternion().angle_to(rotated_pose.basis.get_rotation_quaternion()) > 0.1,
		"An off-center collision impulse can rotate and topple furniture")
	_advance(6, rotated_pose)
	if not await _expect(func() -> bool: return _barrier.guest_stage >= 7,
		"The guest checks the rotated furniture pose after synchronization"):
		return
	_advance(7, rotated_pose)
	if not await _expect(func() -> bool: return _lobby.get_node_or_null("Apartment") == null,
		"The host cleans up the physics room when the guest leaves"):
		return
	_check(_lobby.get_node("Menu").visible and _lobby.get_node("%Start").disabled,
		"The host can accept a new room participant after physics cleanup")


func _test_guest() -> void:
	_barrier.acknowledge.rpc_id(1, 1)
	if not await _expect(func() -> bool: return _barrier.stage >= 1,
		"The host prepares the isolated stool fixture"):
		return
	_check(_paths == _barrier.body_paths, "Host and guest assign identical stable indices to all physics bodies")
	if not await _expect_stool_pose("The guest receives the prepared stool through regular snapshots"):
		return
	if not await _expect_parked_snapshot_poses():
		return
	var initial_pose := _barrier.pose
	_barrier.acknowledge.rpc_id(1, 2)
	if not await _expect(func() -> bool: return _barrier.stage >= 2,
		"The host completes its keyboard push"):
		return
	if not await _expect_stool_pose("The guest sees the host's final pushed stool position"):
		return
	_check(_horizontal_distance(_stool.global_position, initial_pose.origin) > 0.12,
		"The guest observes furniture displacement caused by the host")
	_barrier.acknowledge.rpc_id(1, 3)
	if not await _expect(func() -> bool: return _barrier.stage >= 3,
		"The host prepares the guest's push fixture"):
		return
	if not await _expect_stool_pose("The guest sees the reset stool before walking into it"):
		return
	initial_pose = _barrier.pose
	_key(KEY_W, true)
	await _wait_frames(100)
	_key(KEY_W, false)
	_barrier.acknowledge.rpc_id(1, 4)
	if not await _expect(func() -> bool: return _barrier.stage >= 4,
		"The server finishes applying the guest's contact push"):
		return
	if not await _expect_stool_pose("The guest's push uses the same authoritative final pose on both peers"):
		return
	_check(_horizontal_distance(_stool.global_position, initial_pose.origin) > 0.12,
		"Guest movement requests can displace server-owned furniture")
	_barrier.acknowledge.rpc_id(1, 5)
	if not await _expect(func() -> bool: return _barrier.stage >= 5,
		"The host prepares an off-center furniture impulse"):
		return
	if not await _expect_stool_pose("Both peers share the same initial orientation"):
		return
	initial_pose = _barrier.pose
	_barrier.acknowledge.rpc_id(1, 6)
	if not await _expect(func() -> bool: return _barrier.stage >= 6,
		"The host applies the furniture turning impulse"):
		return
	if not await _expect_stool_pose("Furniture rotation is synchronized, including its complete basis"):
		return
	_check(initial_pose.basis.get_rotation_quaternion().angle_to(_stool.global_basis.get_rotation_quaternion()) > 0.1,
		"The guest observes the furniture's rotation without simulating its own rigid body")
	if not await _expect_parked_snapshot_poses():
		return
	for body in _apartment._physics_bodies:
		_check(body.freeze, "Every guest world body remains frozen after pushes and rotation")
	_barrier.acknowledge.rpc_id(1, 7)
	if not await _expect(func() -> bool: return _barrier.stage >= 7,
		"The host completes pose checks before disconnecting"):
		return
	var body_reference: WeakRef = weakref(_stool)
	await _tap(KEY_ESCAPE)
	await process_frame
	_check(_lobby.get_node_or_null("Apartment") == null and _lobby.get_node("Menu").visible,
		"Esc restores the guest's menu after the furniture simulation")
	_check(body_reference.get_ref() == null and _lobby._peer == null,
		"Leaving frees furniture bodies and closes the guest connection")


func _prepare_push(pushing: Player, waiting: Player) -> void:
	_place_stool()
	pushing.global_position = Vector3(STOOL_POSITION.x, STOOL_POSITION.y, STOOL_POSITION.z + 1.3)
	pushing.velocity = Vector3.ZERO
	pushing.rotation.y = 0.0
	pushing.remote_input = Vector2.ZERO
	waiting.global_position = WAIT_POSITION
	waiting.velocity = Vector3.ZERO
	waiting.remote_input = Vector2.ZERO
	_stool.freeze = false
	_stool.sleeping = false


func _place_stool() -> void:
	_stool.freeze = true
	_stool.linear_velocity = Vector3.ZERO
	_stool.angular_velocity = Vector3.ZERO
	_stool.global_transform = Transform3D(Basis.IDENTITY, STOOL_POSITION)
	var lowest := INF
	for node in _stool.find_children("*", "CollisionShape3D", true, false):
		var collider := node as CollisionShape3D
		if collider.shape == null or collider.disabled:
			continue
		var bounds := collider.global_transform * collider.shape.get_debug_mesh().get_aabb()
		lowest = minf(lowest, bounds.position.y)
	_check(is_finite(lowest), "The dynamic stool retains usable collision geometry")
	if is_finite(lowest):
		_stool.global_position.y += STOOL_POSITION.y - lowest + 0.01


func _advance(stage: int, pose: Transform3D) -> void:
	_barrier.advance.rpc_id(_apartment.guest_peer_id, stage, pose, _paths)


func _expect_stool_pose(message: String) -> bool:
	return await _expect(func() -> bool:
		return _stool.global_position.distance_to(_barrier.pose.origin) < 0.04 \
			and _stool.global_basis.get_rotation_quaternion().angle_to(_barrier.pose.basis.get_rotation_quaternion()) < 0.025,
		message)


func _expect_parked_snapshot_poses() -> bool:
	return await _expect(func() -> bool:
		for index in _apartment._physics_bodies.size():
			var body: RigidBody3D = _apartment._physics_bodies[index]
			if body == _stool:
				continue
			var parked_position := Vector3(50.0 + index * 4.0, 3.0, 0.0)
			if body.global_position.distance_to(parked_position) > 0.03:
				return false
		return true,
		"Every pickup and furniture snapshot batch reaches the guest with the host's parked body poses")


func _horizontal_distance(a: Vector3, b: Vector3) -> float:
	return Vector2(a.x, a.z).distance_to(Vector2(b.x, b.z))


func _expect(condition: Callable, message: String, seconds := 5.0) -> bool:
	var deadline := Time.get_ticks_msec() + int(seconds * 1000.0)
	while Time.get_ticks_msec() < deadline:
		if condition.call():
			return true
		await physics_frame
	_check(false, message)
	quit(1)
	return false


func _check(condition: bool, message: String) -> void:
	if not condition:
		_failed = true
		push_error(message)


func _wait_frames(frames: int) -> void:
	for _frame in frames:
		await physics_frame


func _tap(key: Key) -> void:
	_key(key, true)
	await physics_frame
	_key(key, false)
	await physics_frame


func _key(key: Key, pressed: bool) -> void:
	var event := InputEventKey.new()
	event.keycode = key
	event.physical_keycode = key
	event.pressed = pressed
	Input.parse_input_event(event)
	Input.flush_buffered_events()
