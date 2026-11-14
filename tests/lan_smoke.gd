extends SceneTree

# Run two headless instances with --script res://tests/lan_smoke.gd -- host / guest.
const LOBBY := preload("res://lan_lobby.tscn")
const Player := preload("res://player.gd")
const HOST_SPAWN := Vector3(4.7, 0.065, -2.1)
const GUEST_SPAWN := Vector3(7.5, 0.065, -3.7)
const TV_PICKUP_OFFSET := Vector3(0.0, 0.8, 0.95)
const TIME_LIMIT_MESSAGE := "시간 종료"

class StartBarrier:
	extends Node
	var started := false
	var guest_ready := false
	var hit_input_released := false
	var hits_verified := false
	var tv_verified := false
	var tv_requested := false
	var deposit_verified := false
	var drop_verified := false
	@rpc("authority", "call_remote", "reliable")
	func begin() -> void:
		started = true
	@rpc("any_peer", "call_remote", "reliable")
	func ready_to_move() -> void:
		guest_ready = true
	@rpc("any_peer", "call_remote", "reliable")
	func finish_hit_movement() -> void:
		hit_input_released = true
	@rpc("authority", "call_remote", "reliable")
	func finish_hits() -> void:
		hits_verified = true
	@rpc("any_peer", "call_remote", "reliable")
	func confirm_tv() -> void:
		tv_verified = true
	@rpc("any_peer", "call_remote", "reliable")
	func request_tv() -> void:
		tv_requested = true
	@rpc("any_peer", "call_remote", "reliable")
	func confirm_deposit() -> void:
		deposit_verified = true
	@rpc("any_peer", "call_remote", "reliable")
	func confirm_drop() -> void:
		drop_verified = true

var _lobby: Node
var _host: Player
var _guest: Player
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
	create_timer(35.0).timeout.connect(func() -> void:
		push_error("LAN smoke test timed out (%s)." % args[0])
		quit(1)
	)
	var is_host := args[0] == "host"
	var barrier := StartBarrier.new()
	barrier.name = "SmokeBarrier"
	root.add_child(barrier)
	_lobby = LOBBY.instantiate()
	_lobby.play_intro = false
	root.add_child(_lobby)
	var start := _lobby.get_node("%Start") as TextureButton
	if is_host:
		_lobby._host_room()
		_check(not start.visible and _lobby.get_node("%Cancel").visible, "Hosting hides START and offers cancel while waiting")
		await _lobby.child_entered_tree
	else:
		_lobby._find_room()
		await _lobby.child_entered_tree
		_check(not start.visible, "START stays hidden once the guest joins")

	await physics_frame
	var apartment := _lobby.get_node("Apartment")
	_host = apartment.get_node("Player")
	_guest = apartment.get_node("Guest")
	_pickup = apartment.get_node("Items/Item_06_egg")
	var second: RigidBody3D = apartment.get_node("Items/Item_10_tissue_box")
	_check(apartment._pickups.size() == 21, "Only the 21 household items have pickup indices")
	await _wait_frames(8)
	_check(not _lobby.get_node("Menu").visible, "Start opens the new map for both players")
	_check(_host.position.distance_to(HOST_SPAWN) < 0.08, "Host uses the first map spawn")
	_check(_guest.position.distance_to(GUEST_SPAWN) < 0.08, "Guest uses the second map spawn")
	_check(_host.is_on_floor() and _guest.is_on_floor() if is_host else _guest.reads_local_input,
		"Both players stand on the floor and the guest can control their character")
	_check(_host.get_node("Head/PlayerPosPointer").visible == is_host
		and _guest.get_node("Head/PlayerPosPointer").visible == not is_host,
		"Each peer sees the pointer above their own player")
	var timer := apartment.get_node("RoundTimer") as Timer
	var clock := apartment.get_node("HUD/TimeLeft") as Label
	var finish := apartment.get_node("HUD/RoundEnd") as ColorRect
	_check(clock.text == "01:00" and timer.wait_time == 60.0 and timer.is_stopped() != is_host,
		"Both HUDs start at one minute and only the host timer runs")
	if is_host:
		await _expect(func() -> bool: return barrier.guest_ready,
			"The guest finishes spawn checks before the host clears the movement lane")
		_prepare_clear_lane(apartment)
		_pickup.global_position = Vector3(7, 0.065, -2.4)
		second.global_position = Vector3(5, 0.065, -3.5)
		await _wait_frames(12)
		barrier.begin.rpc_id(apartment.guest_peer_id)
		await _test_host(second)
		timer.start(2.0)
	else:
		barrier.ready_to_move.rpc_id(1)
		await _expect(func() -> bool: return barrier.started, "Both peers finish checking spawn positions before movement begins")
		await _test_guest()
	await _expect(func() -> bool: return clock.text == "00:02" or clock.text == "00:01", "The host's remaining time is displayed")
	await _expect(func() -> bool: return finish.visible, "Timeout ends the round on both peers")
	_check(clock.text == "00:00" and finish.get_node("Message").text.contains(TIME_LIMIT_MESSAGE)
		and apartment.process_mode == Node.PROCESS_MODE_DISABLED, "The finished round displays zero and freezes play")
	# The host's 20-gold tissue box stays bagged and the guest's TV was dropped, so both peers must agree.
	var ending := apartment.get_node_or_null("Ending")
	_check(ending != null and ending.outcome == preload("res://courtroom_ending.gd").Outcome.HUSBAND_WINS
		and ending.get_node("Result").text.ends_with("아내 0 G   ·   남편 20 G") and ending.husband_animation.current_animation == &"celebrate_jump",
		"Both peers show the host-decided husband win with the same bag totals")
	if is_host:
		await _expect(func() -> bool: return _lobby.get_node_or_null("Apartment") == null, "The host returns to the lobby when the guest leaves")
		_check(not start.visible and _lobby.get_node("%Cancel").visible, "Leaving frees the guest slot and the host waits again")
	else:
		await _tap(KEY_ESCAPE)
		_check(_lobby.get_node_or_null("Apartment") == null and start.visible, "Esc returns the guest to the main menu")
	if not _failed:
		print("LAN smoke test passed (%s)." % args[0])
	quit(int(_failed))


func _test_host(second: RigidBody3D) -> void:
	var saw_guest_grab := [false]
	await _expect(func() -> bool:
		saw_guest_grab[0] = saw_guest_grab[0] or _guest.motion == &"Grab"
		return _guest.held_pickup == _pickup, "Guest movement and pickup reach the host")
	_check(saw_guest_grab[0], "The host animates the guest's server-validated Grab")
	var guest_launch: Dictionary = {}
	_guest.held_pickup_changed.connect(func(is_holding: bool) -> void:
		if not is_holding and guest_launch.is_empty():
			guest_launch["velocity"] = _pickup.linear_velocity
			guest_launch["position"] = _pickup.global_position
	)
	# Contact with the target sphere can slide the guest slightly backward
	# during the sideways leg, after the client's S threshold already passed.
	_check(_guest.position.x < GUEST_SPAWN.x - 0.25 and _guest.position.z > GUEST_SPAWN.z + 0.9,
		"The host receives substantial movement on both guest input axes")
	_check(_guest.rotation.y > 1.0, "The host receives guest turning")
	_check(_host.position.distance_to(HOST_SPAWN) < 0.08 and _host.held_pickup == null, "Guest input affects only the guest")
	# Measure from the launch point: the hold frame now shows the real Pickup floor contact.
	var from := _pickup.global_position
	await _expect(func() -> bool: return _guest.held_pickup == null and _pickup.global_position.distance_to(guest_launch.get("position", from)) > 0.35,
		"Guest throw moves the shared pickup on the host")
	_check(_guest.motion == &"Throw", "The host plays the guest's one-hand Throw for the validated launch")
	_check(guest_launch.has("velocity") and (guest_launch["velocity"] as Vector3).length() <= 10.001, "The host uses the guest's charged speed within zero to ten")
	if guest_launch.has("velocity"):
		var direction := (guest_launch["velocity"] as Vector3).normalized()
		_check(absf(rad_to_deg(asin(direction.y)) - 25.0) < 0.01, "The guest's throw uses the merged 25-degree angle")
	_key(KEY_W, true)
	await _expect(func() -> bool: return _host.position.z < -2.65, "Host can also walk toward a pickup")
	_key(KEY_W, false)
	_check(_host._highlighted_pickup == second and _guest._highlighted_pickup == null, "Only the host's own nearest grab target is highlighted on the host")
	await _hold_left(75)
	_check(_host.held_pickup == second, "Host can pick up the tissue box")
	_mouse(MOUSE_BUTTON_LEFT, true)
	await _wait_frames(20)
	var second_release := second.global_position
	_mouse(MOUSE_BUTTON_LEFT, false)
	await _expect(func() -> bool: return _host.held_pickup == null and second.global_position.distance_to(second_release) > 0.35,
		"The host's tissue-box throw moves through physics before the TV fixture is prepared")
	_check(_host.motion == &"Throw", "The host's own launch plays the one-hand Throw")
	# Completed throws can land closer to the guest than the TV's safe, separate
	# collider. Clear those old targets so E still selects the intended TV.
	for index in 2:
		var thrown := _pickup if index == 0 else second
		thrown.freeze = true
		thrown.disarm()
		thrown.linear_velocity = Vector3.ZERO
		thrown.angular_velocity = Vector3.ZERO
		thrown.global_position = Vector3(44.0 + index * 4.0, 3.0, 0.0)
	var apartment := _lobby.get_node("Apartment")
	var tv := apartment.get_node("Items/Item_17_tv") as RigidBody3D
	# This test measures ownership and throws after a known teleport. Gravity
	# must not move the TV away before the guest observes that fixture pose.
	tv.freeze = true
	tv.linear_velocity = Vector3.ZERO
	tv.angular_velocity = Vector3.ZERO
	# Keep its collider beside the player rather than overlapping their capsule.
	tv.global_position = _guest.global_position + TV_PICKUP_OFFSET
	await _expect(func() -> bool: return _guest.held_pickup == tv, "A guest can also pick up the shared TV")
	var tv_from := tv.global_position
	await _expect(func() -> bool: return _guest.held_pickup == null and tv.global_position.distance_to(tv_from) > 0.35, "A charged TV throw is simulated by the host")
	await _expect(func() -> bool: return root.get_node("SmokeBarrier").tv_verified, "The guest observes the TV flight before the hit fixture is reset")
	await _test_hits_host(apartment)
	await _expect(func() -> bool: return root.get_node("SmokeBarrier").tv_requested, "The guest is ready to test bagging")
	_guest.hold_pickup(tv)
	await _expect(func() -> bool: return apartment.get_node("HUD/WifeBag/Items").get_child_count() == 1, "The host receives the guest's deposit")
	_check(not tv.visible and not tv.is_in_group(&"pickups"), "A guest deposit removes the same object on the host")
	_host.hold_pickup(second)
	_mouse(MOUSE_BUTTON_RIGHT, true)
	_mouse(MOUSE_BUTTON_RIGHT, false)
	await _expect(func() -> bool: return apartment.get_node("HUD/HusbandProfile/HusbandWallet/Gold").text == "000020", "The host's tissue-box deposit awards 20 gold")
	await _expect(func() -> bool: return root.get_node("SmokeBarrier").deposit_verified, "The guest confirmed the deposit before the hit")
	# Use a power-four projectile to prove the host rolls bag loss and relays it to the guest.
	var pan: RigidBody3D = apartment.get_node("Items/Item_07_frying_pan")
	pan.arm(_host)
	pan._on_body_entered(_guest)
	await _expect(func() -> bool: return tv.visible and apartment.get_node("HUD/WifeProfile/WifeWallet/Gold").text == "000000", "The host restores the dropped TV and deducts 900 gold")
	await _expect(func() -> bool: return root.get_node("SmokeBarrier").drop_verified, "The guest confirmed the synchronized loss")


func _prepare_clear_lane(apartment: Node3D) -> void:
	# Room furniture has its own contact/snapshot test. Keep this older movement,
	# pickup, and projectile lane clear while retaining every network body index.
	for index in apartment._physics_bodies.size():
		var body: RigidBody3D = apartment._physics_bodies[index]
		body.freeze = true
		body.linear_velocity = Vector3.ZERO
		body.angular_velocity = Vector3.ZERO
		if body.has_method(&"disarm"):
			body.disarm()
		body.global_position = Vector3(50.0 + index * 4.0, 3.0, 0.0)


func _test_guest() -> void:
	_key(KEY_S, true)
	await _expect(func() -> bool: return _guest.position.z > -2.6, "Guest's backward input moves their character")
	_key(KEY_S, false)
	_key(KEY_A, true)
	await _expect(func() -> bool: return _guest.position.x < 7.2, "Guest's sideways input moves their character")
	_key(KEY_A, false)
	await _wait_frames(8)
	_check(_guest._highlighted_pickup == _pickup and _host._highlighted_pickup == null, "Only the guest's own nearest grab target is highlighted on the client")
	await _hold_left(75)
	await _expect(func() -> bool: return _guest.held_pickup == _pickup, "Guest sees the egg attach to their hand")
	_mouse(MOUSE_BUTTON_LEFT, true)
	await _wait_frames(12)
	_check(_guest.get_node("ThrowTrajectory").visible, "Guest can aim before throwing")
	var from := _pickup.global_position
	var charged_speed: float = _lobby.get_node("Apartment/HUD/ThrowPower").value
	_check(charged_speed > 0.1 and charged_speed < 10.0, "Snapshots preserve the guest's charge timer")
	_mouse(MOUSE_BUTTON_LEFT, false)
	await _expect(func() -> bool: return _guest.held_pickup == null and _pickup.global_position.distance_to(from) > 0.35,
		"Guest sees the shared throw after releasing left click")
	_check(_guest.motion == &"Throw", "The server throw event plays the guest's own one-hand Throw")
	var saw_host_grab := [false]
	await _expect(func() -> bool:
		saw_host_grab[0] = saw_host_grab[0] or _host.motion == &"Grab"
		return _host.held_pickup != null, "Guest sees the host move and pick up the tissue box")
	_check(saw_host_grab[0], "The guest animates the host's server-validated Grab")
	_check(_host.position.z < -2.65 and _guest.held_pickup == null, "Host input affects only the host")
	var host_pickup := _host.held_pickup
	var host_release := host_pickup.global_position
	await _expect(func() -> bool: return _host.held_pickup == null and host_pickup.global_position.distance_to(host_release) > 0.35,
		"Guest sees the host throw the shared sphere")
	_check(_host.motion == &"Throw", "The guest plays the host's one-hand Throw from the server event")
	var apartment := _lobby.get_node("Apartment")
	var tv := apartment.get_node("Items/Item_17_tv") as RigidBody3D
	await _expect(func() -> bool: return tv.global_position.distance_to(_guest.global_position + TV_PICKUP_OFFSET) < 0.1, "Guest receives the shared TV transform")
	await _hold_left(130)
	await _expect(func() -> bool: return _guest.held_pickup == tv, "Guest sees the TV attached with its prop-specific hand offset")
	_mouse(MOUSE_BUTTON_LEFT, true)
	await _wait_frames(60)
	_check(_lobby.get_node("Apartment/HUD/ThrowPower").value > 9.9, "Guest charging reaches ten despite regular snapshots")
	var tv_from := tv.global_position
	_mouse(MOUSE_BUTTON_LEFT, false)
	await _expect(func() -> bool: return _guest.held_pickup == null and tv.global_position.distance_to(tv_from) > 0.35, "Guest sees the charged TV throw")
	root.get_node("SmokeBarrier").confirm_tv.rpc_id(1)
	await _test_hits_guest(apartment.get_node("Items/Item_12_ring"))
	await _expect(func() -> bool: return tv.global_position.distance_to(_guest.global_position) > 0.35, "The thrown TV is in the world before the deposit fixture")
	root.get_node("SmokeBarrier").request_tv.rpc_id(1)
	await _expect(func() -> bool: return _guest.held_pickup == tv, "Guest receives the TV again for the deposit check")
	_mouse(MOUSE_BUTTON_RIGHT, true)
	_mouse(MOUSE_BUTTON_RIGHT, false)
	var guest_gold: Label = apartment.get_node("HUD/WifeProfile/WifeWallet/Gold")
	await _expect(func() -> bool: return guest_gold.text == "000900", "The guest's TV deposit awards 900 gold")
	await _expect(func() -> bool: return apartment.get_node("HUD/HusbandBag/Items").get_child_count() == 1, "The guest receives the host's deposit")
	_check(not tv.visible and not tv.is_in_group(&"pickups") and _guest.held_pickup == null, "Snapshots cannot bring a bagged object back to the guest's hand")
	root.get_node("SmokeBarrier").confirm_deposit.rpc_id(1)
	await _expect(func() -> bool: return tv.visible and guest_gold.text == "000000", "The guest sees the dropped TV and the gold deduction")
	_check(_guest.bag_weight == 0 and apartment.get_node("HUD/WifeBag/Items").get_child_count() == 0 and tv.is_in_group(&"pickups"),
		"The drop restores selection and clears the guest's bag weight and icon")
	root.get_node("SmokeBarrier").confirm_drop.rpc_id(1)


func _test_hits_host(apartment: Node3D) -> void:
	var ring := apartment.get_node("Items/Item_12_ring") as RigidBody3D
	# Earlier throw tests must not introduce unrelated hits during timing checks.
	for item in apartment._pickups:
		item.freeze = true
		item.disarm()
	_host.position = Vector3(6.5, 0.065, -1.25)
	_host.rotation.y = 0
	_guest.position = Vector3(6.5, 0.065, -3.05)
	_host.hold_pickup(ring)
	_host.release_pickup(true, _host.throw_velocity_at_speed(8.0))
	await _expect(func() -> bool: return _guest.is_stunned(), "The host's projectile stuns the guest on the authoritative server")
	# The contact was real; remove the ring so this timing check measures input
	# lock without the capsule separating from its new physical projectile.
	ring.disarm()
	ring.freeze = true
	ring.global_position = Vector3(40.0, 3.0, 0.0)
	var hit_position := _guest.global_position
	await _wait_frames(20)
	_check(_guest.is_stunned() and _guest.global_position.distance_to(hit_position) < 0.02,
		"The server blocks guest movement during the stun (position %s -> %s, stun %.3f)" % [hit_position, _guest.global_position, _guest._stun_remaining])
	await _wait_frames(20)
	_check(not _guest.is_stunned(), "The server releases the guest's movement after half a second")
	# The guest holds D to verify movement resumes. Wait for that check and its
	# released input to reach the server before resetting the next throw's pose.
	await _expect(func() -> bool: return root.get_node("SmokeBarrier").hit_input_released and _guest.remote_input.is_zero_approx(),
		"The guest stops its movement check before the next projectile fixture")
	_host.position = Vector3(6.5, 0.065, -3.05)
	_guest.position = Vector3(6.5, 0.065, -1.25)
	_guest.rotation.y = 0
	_guest.hold_pickup(ring)
	await _expect(func() -> bool: return _host.is_stunned(), "The guest's projectile can also stun the host")
	await _wait_frames(40)
	_check(not _host.is_stunned(), "The host recovers after the same stun duration")
	root.get_node("SmokeBarrier").finish_hits.rpc_id(apartment.guest_peer_id)


func _test_hits_guest(ring: RigidBody3D) -> void:
	await _expect(func() -> bool: return _guest.is_stunned(), "The guest receives the reliable hit event from the host")
	var torso := _guest._body_meshes[0] as MeshInstance3D
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
	root.get_node("SmokeBarrier").finish_hit_movement.rpc_id(1)
	await _expect(func() -> bool: return _guest.held_pickup == ring and _guest.position.z > -1.4, "The next projectile is shared with the guest")
	_mouse(MOUSE_BUTTON_LEFT, true)
	await _wait_frames(45)
	_mouse(MOUSE_BUTTON_LEFT, false)
	await _expect(func() -> bool: return _host.is_stunned(), "A guest throw produces a synchronized hit on the host")
	_check(not _guest.is_stunned(), "Throwing does not stun the thrower")
	await _wait_frames(15)
	_check(_host._body_meshes[0].material_overlay == null, "The remote host's red flash restores its appearance")
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


func _hold_left(frames: int) -> void:
	_mouse(MOUSE_BUTTON_LEFT, true)
	await _wait_frames(frames)
	_mouse(MOUSE_BUTTON_LEFT, false)


func _mouse(button: MouseButton, pressed: bool) -> void:
	var event := InputEventMouseButton.new()
	event.button_index = button
	event.pressed = pressed
	Input.parse_input_event(event)
	Input.flush_buffered_events()


func _key(key: Key, pressed: bool) -> void:
	var event := InputEventKey.new()
	event.keycode = key
	event.physical_keycode = key
	event.pressed = pressed
	Input.parse_input_event(event)
	Input.flush_buffered_events()
