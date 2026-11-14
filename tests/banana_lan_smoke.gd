extends SceneTree

# Run two instances together with -- host / -- guest. Other LAN tests use
# the same discovery and game ports, so run this pair on its own.
const LOBBY := preload("res://lan_lobby.tscn")
const Player := preload("res://player.gd")
const LAUNCH_POSITION := Vector3(6.5, 0.065, -1.6)
const SECOND_LAUNCH_POSITION := LAUNCH_POSITION + Vector3.RIGHT * 1.4
const WAIT_POSITION := Vector3(4.7, 0.065, -2.1)

class BananaBarrier:
	extends Node
	var stage := 0
	var guest_stage := 0
	var landing_pose := Transform3D.IDENTITY
	@rpc("authority", "call_remote", "reliable")
	func advance(value: int, pose: Transform3D) -> void:
		stage = maxi(stage, value)
		landing_pose = pose
	@rpc("any_peer", "call_remote", "reliable")
	func acknowledge(value: int) -> void:
		guest_stage = maxi(guest_stage, value)

var _lobby: Node
var _apartment: Node3D
var _host: Player
var _guest: Player
var _first: RigidBody3D
var _second: RigidBody3D
var _pickup_ids: Array[int]
var _barrier: BananaBarrier
var _failed := false


func _initialize() -> void:
	_run.call_deferred()


func _run() -> void:
	var args := OS.get_cmdline_user_args()
	if args.size() != 1 or args[0] not in ["host", "guest"]:
		push_error("Specify host or guest after --.")
		quit(1)
		return
	create_timer(25.0).timeout.connect(func() -> void:
		push_error("Banana LAN smoke test timed out (%s)." % args[0])
		quit(1)
	)
	var is_host := args[0] == "host"
	_barrier = BananaBarrier.new()
	_barrier.name = "BananaSmokeBarrier"
	root.add_child(_barrier)
	_lobby = LOBBY.instantiate()
	_lobby.play_intro = false
	# The house authors one banana. Add a second copy before the apartment's
	# ready hook builds its stable lists, to exercise throws from both peers.
	_lobby.child_entered_tree.connect(func(child: Node) -> void:
		if child.name != &"Apartment":
			return
		var items := child.get_node("Items")
		items.ready.connect(func() -> void:
			items._spawn("01-banana", SECOND_LAUNCH_POSITION, 0.0, 0.6)
			items.get_child(items.get_child_count() - 1).name = "SecondBanana"
		)
	)
	root.add_child(_lobby)
	if is_host:
		_lobby._host_room()
	else:
		_lobby._find_room()
	if not await _expect(func() -> bool: return _lobby.get_node_or_null("Apartment") != null, "Both peers load the apartment"):
		return
	await _wait_frames(8)
	_apartment = _lobby.get_node("Apartment")
	_host = _apartment.get_node("Player")
	_guest = _apartment.get_node("Guest")
	for pickup in _apartment._pickups:
		_pickup_ids.append(pickup.get_instance_id())
		if pickup.name == &"Item_01_banana":
			_first = pickup
		elif pickup.name == &"SecondBanana":
			_second = pickup
	_check(_first != null and _second != null and _apartment._pickups.size() == 44,
		"Both authored bananas have stable entries in the shared pickup list")
	if _failed:
		quit(1)
		return
	if is_host:
		await _test_host()
	else:
		await _test_guest()
	if not _failed:
		print("Banana LAN smoke test passed (%s)." % args[0])
	quit(int(_failed))


func _test_host() -> void:
	if not await _expect(func() -> bool: return _barrier.guest_stage >= 1, "The guest is ready before the host prepares the throw"):
		return
	for index in _apartment._physics_bodies.size():
		var body: RigidBody3D = _apartment._physics_bodies[index]
		body.freeze = true
		body.linear_velocity = Vector3.ZERO
		body.angular_velocity = Vector3.ZERO
		if body.has_method(&"disarm"):
			body.disarm()
		body.global_position = Vector3(50.0 + index * 4.0, 3.0, 0.0)
	_host.global_position = LAUNCH_POSITION
	_guest.global_position = WAIT_POSITION
	_host.rotation.y = 0.0
	_host.hold_pickup(_first)
	await _wait_frames(8)
	_barrier.advance.rpc_id(_apartment.guest_peer_id, 1, Transform3D.IDENTITY)
	if not await _expect(func() -> bool: return _barrier.guest_stage >= 2, "The guest observes the held banana before the host throws"):
		return
	await _charged_throw()
	if not await _expect(func() -> bool: return _is_peel(_first), "The host's thrown banana converts after landing on the real map floor"):
		return
	var first_pose := _first.global_transform
	await _verify_peel(_first, first_pose)
	_barrier.advance.rpc_id(_apartment.guest_peer_id, 2, first_pose)
	if not await _expect(func() -> bool: return _barrier.guest_stage >= 3, "The guest verifies the host's peel and rejects stale snapshots"):
		return
	_host.global_position = WAIT_POSITION
	_guest.global_position = SECOND_LAUNCH_POSITION
	_guest.rotation.y = 0.0
	_guest.hold_pickup(_second)
	await _wait_frames(8)
	_barrier.advance.rpc_id(_apartment.guest_peer_id, 3, Transform3D.IDENTITY)
	if not await _expect(func() -> bool: return _is_peel(_second), "The guest's T release reaches the host and converts the second banana on the floor"):
		return
	var second_pose := _second.global_transform
	await _verify_peel(_second, second_pose)
	_barrier.advance.rpc_id(_apartment.guest_peer_id, 4, second_pose)
	if not await _expect(func() -> bool: return _barrier.guest_stage >= 4, "The guest verifies the second reliable conversion"):
		return
	_verify_indices()
	_check(_first.global_transform.is_equal_approx(first_pose), "The first peel stays fixed while the second banana is thrown")
	# The thrower must also be affected by their own peel, and the guest must
	# observe the same two-second lock even though movement is server-owned.
	_host.global_position = first_pose.origin + Vector3(0.0, LAUNCH_POSITION.y - first_pose.origin.y, 1.1)
	_guest.global_position = WAIT_POSITION
	_host.velocity = Vector3.ZERO
	_guest.velocity = Vector3.ZERO
	await _wait_frames(8)
	_barrier.advance.rpc_id(_apartment.guest_peer_id, 5, first_pose)
	_key(KEY_W, true)
	await _verify_step_stun(_host, "host", _first, _second)
	_key(KEY_W, false)
	if not await _expect(func() -> bool: return _barrier.guest_stage >= 5, "The guest verifies the host's peel stun before the next walk"):
		return
	_host.global_position = WAIT_POSITION
	_guest.global_position = second_pose.origin + Vector3(0.0, LAUNCH_POSITION.y - second_pose.origin.y, 1.1)
	_host.velocity = Vector3.ZERO
	_guest.velocity = Vector3.ZERO
	await _wait_frames(8)
	_barrier.advance.rpc_id(_apartment.guest_peer_id, 6, second_pose)
	await _verify_step_stun(_guest, "guest", _second)
	if not await _expect(func() -> bool: return _barrier.guest_stage >= 6, "The guest verifies its own server-authoritative peel stun"):
		return
	_barrier.advance.rpc_id(_apartment.guest_peer_id, 7, second_pose)
	var first_reference: WeakRef = weakref(_first)
	var second_reference: WeakRef = weakref(_second)
	if not await _expect(func() -> bool: return _lobby.get_node_or_null("Apartment") == null, "The host returns to the lobby when the guest leaves"):
		return
	await process_frame
	_check(first_reference.get_ref() == null and second_reference.get_ref() == null, "Disconnect frees both converted bodies on the host")
	_check(_lobby.get_node("Menu").visible and not _lobby.get_node("%Start").visible
		and _lobby.get_node("%Cancel").visible, "The host can wait for another room participant after cleanup")


func _test_guest() -> void:
	_barrier.acknowledge.rpc_id(1, 1)
	if not await _expect(func() -> bool: return _barrier.stage >= 1 and _host.held_pickup == _first, "The host's held banana reaches the guest"):
		return
	_check(not _is_peel(_first), "Holding a banana alone does not convert it")
	_barrier.acknowledge.rpc_id(1, 2)
	if not await _expect(func() -> bool: return _barrier.stage >= 2 and _is_peel(_first), "The host's floor landing reliably becomes a peel on the guest"):
		return
	var first_pose := _barrier.landing_pose
	await _verify_peel(_first, first_pose)
	_verify_stale_snapshot(_first, 0)
	_barrier.acknowledge.rpc_id(1, 3)
	if not await _expect(func() -> bool: return _barrier.stage >= 3 and _guest.held_pickup == _second, "The guest receives the second banana in their hand"):
		return
	_check(not _is_peel(_second), "The client keeps the second held banana intact before throwing")
	await _charged_throw()
	if not await _expect(func() -> bool: return _barrier.stage >= 4 and _is_peel(_second), "The guest sees their own throw converted by the server"):
		return
	var second_pose := _barrier.landing_pose
	await _verify_peel(_second, second_pose)
	_verify_stale_snapshot(_second, 1)
	_check(_first.global_transform.is_equal_approx(first_pose), "Later snapshots keep the first peel at its original landing position")
	_verify_indices()
	_barrier.acknowledge.rpc_id(1, 4)
	if not await _expect(func() -> bool: return _barrier.stage >= 5, "The host prepares a real walk onto its own peel"):
		return
	await _verify_step_stun(_host, "host", _first, _second)
	_barrier.acknowledge.rpc_id(1, 5)
	if not await _expect(func() -> bool: return _barrier.stage >= 6, "The host prepares the guest to walk onto the second peel"):
		return
	_key(KEY_W, true)
	await _verify_step_stun(_guest, "guest", _second)
	_key(KEY_W, false)
	_barrier.acknowledge.rpc_id(1, 6)
	if not await _expect(func() -> bool: return _barrier.stage >= 7, "The host finishes both peel stun checks before cleanup"):
		return
	var first_reference: WeakRef = weakref(_first)
	var second_reference: WeakRef = weakref(_second)
	await _tap(KEY_ESCAPE)
	await process_frame
	_check(_lobby.get_node_or_null("Apartment") == null and _lobby.get_node("Menu").visible, "Esc returns the guest to the main menu")
	_check(first_reference.get_ref() == null and second_reference.get_ref() == null, "Leaving frees both converted bodies on the guest")
	_check(_lobby._peer == null, "Leaving closes the guest's network connection")


func _charged_throw() -> void:
	_mouse(MOUSE_BUTTON_LEFT, true)
	await _wait_frames(20)
	var local_player: Player = _apartment._local_player
	_check(local_player._is_aiming and local_player.get_node("ThrowTrajectory").visible, "The local player aims the banana with left click before release")
	_mouse(MOUSE_BUTTON_LEFT, false)
	await physics_frame


func _verify_step_stun(player: Player, label: String, spent: RigidBody3D, unspent: RigidBody3D = null) -> void:
	var collider: CollisionShape3D = player.get_node("CollisionShape3D")
	var collider_pose := collider.transform
	if not await _expect(func() -> bool: return player.is_stunned(), "Both peers see the %s step onto the peel" % label):
		return
	_check(player._stun_remaining >= 1.7, "The %s receives the full two-second peel stun on both peers" % label)
	var stopped_at := Vector2(player.global_position.x, player.global_position.z)
	if not await _expect(func() -> bool:
		return bool(spent.get("is_banana_peel_consumed")) and spent.get_node_or_null("BananaPeel") == null,
		"The stepped peel disappears on both peers immediately after stunning the %s" % label, 0.3):
		return
	_verify_consumed(spent)
	if unspent != null:
		_check(not bool(unspent.get("is_banana_peel_consumed")) and unspent.get_node("BananaPeel").is_visible_in_tree(),
			"Consuming the first peel leaves the other peel available and visible on both peers")
	await _wait_frames(20)
	_check(player.is_slipping() and player._model.basis.y.normalized().dot(Vector3.BACK) > 0.95,
		"The %s falls backward during the peel stun on both peers" % label)
	_check(collider.transform.is_equal_approx(collider_pose) and player.basis.y.normalized().dot(Vector3.UP) > 0.999,
		"The %s's backward fall leaves the movement body and collider upright on both peers" % label)
	await _wait_frames(88)
	var during_stun := Vector2(player.global_position.x, player.global_position.z)
	_check(player.is_stunned() and during_stun.distance_to(stopped_at) < 0.025,
		"The %s stays in place for 1.8 seconds despite held movement input" % label)
	if not await _expect(func() -> bool:
		return not player.is_stunned() and Vector2(player.global_position.x, player.global_position.z).distance_to(stopped_at) > 0.12,
		"The %s resumes walking after two seconds without continuously refreshing the stun" % label, 0.65):
		return
	_check(not player.is_slipping() and player._model.transform.is_equal_approx(player._model_rest_transform),
		"The %s returns to the standing model pose when the peel stun ends on both peers" % label)
	_verify_consumed(spent)
	_verify_stale_snapshot(spent, 0 if spent == _first else 1)
	var pickup_index: int = _apartment._pickups.find(spent)
	var duplicate_pose := spent.global_transform
	duplicate_pose.origin += Vector3(2.0, 1.0, 2.0)
	_apartment._apply_banana_peel(pickup_index, duplicate_pose)
	_apartment._apply_banana_peel_consumed(pickup_index)
	_apartment._apply_banana_peel_consumed(pickup_index)
	_verify_consumed(spent)
	_verify_indices()


func _verify_consumed(pickup: RigidBody3D) -> void:
	_check(is_instance_valid(pickup) and pickup.freeze and _is_peel(pickup)
		and bool(pickup.get("is_banana_peel_consumed")), "Consumption retains the frozen body's stable network identity")
	_check(not pickup.is_visible_in_tree() and pickup.get_node_or_null("BananaPeel") == null,
		"A consumed peel has no visible model or trigger left on either peer")
	_check(pickup.collision_layer == 0 and pickup.collision_mask == 0 and not pickup.is_in_group(&"pickups"),
		"A consumed peel cannot collide, be picked up, or stun another player")


func _verify_peel(pickup: RigidBody3D, expected_pose: Transform3D) -> void:
	_check(pickup.freeze and not pickup.is_in_group(&"pickups"), "A landed peel is frozen and cannot be picked up again")
	_check(_host.held_pickup != pickup and _guest.held_pickup != pickup, "Neither player remains attached to a converted peel")
	var peel := pickup.get_node_or_null("BananaPeel") as Node3D
	_check(peel != null and peel.is_visible_in_tree(), "The banana-peel model is visible after conversion")
	_check(pickup.global_transform.is_equal_approx(expected_pose), "Both peers use the server's fixed landing transform")
	await _wait_frames(12)
	_check(pickup.global_transform.is_equal_approx(expected_pose), "Physics and regular snapshots cannot move a fixed peel")


func _verify_stale_snapshot(pickup: RigidBody3D, old_holder: int) -> void:
	var fixed_pose := pickup.global_transform
	var transforms: Array[Transform3D] = [_host.transform, _guest.transform]
	for item in _apartment._pickups:
		transforms.append(item.global_transform)
	var pickup_index: int = _apartment._pickups.find(pickup)
	transforms[2 + pickup_index].origin += Vector3(3.0, 2.0, 3.0)
	var old_holding := Vector2i(pickup_index, -1) if old_holder == 0 else Vector2i(-1, pickup_index)
	_apartment._apply_snapshot(transforms, old_holding, _apartment._ownership_revision, 45)
	_check(_host.held_pickup != pickup and _guest.held_pickup != pickup,
		"An obsolete held index cannot reattach a converted banana to either hand")
	_check(_is_peel(pickup) and pickup.freeze and not pickup.is_in_group(&"pickups")
		and pickup.global_transform.is_equal_approx(fixed_pose), "An obsolete held snapshot preserves the fixed peel and its pickup eligibility")
	_apartment._apply_snapshot(transforms, Vector2i(-1, -1), _apartment._ownership_revision, 45)
	_check(pickup.global_transform.is_equal_approx(fixed_pose), "An obsolete world transform cannot rewind an unheld peel")


func _verify_indices() -> void:
	_check(_apartment._pickups.size() == _pickup_ids.size(), "Conversion preserves the size of the network pickup list")
	for index in _pickup_ids.size():
		_check(_apartment._pickups[index].get_instance_id() == _pickup_ids[index], "Conversion preserves every pickup's network index and body identity")
	_check(get_nodes_in_group(&"pickups").size() == 42, "Exactly the two converted bananas leave the available pickup group")


func _is_peel(pickup: RigidBody3D) -> bool:
	return bool(pickup.get("is_banana_peel"))


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


func _mouse(button: MouseButton, pressed: bool) -> void:
	var event := InputEventMouseButton.new()
	event.button_index = button
	event.pressed = pressed
	Input.parse_input_event(event)
	Input.flush_buffered_events()
