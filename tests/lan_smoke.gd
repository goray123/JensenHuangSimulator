extends SceneTree

# Run two headless instances with --script res://tests/lan_smoke.gd -- host / guest.
const LOBBY := preload("res://lan_lobby.tscn")
const Player := preload("res://player.gd")
const HOST_SPAWN := Vector3(4.7, 0.065, -2.1)
const GUEST_SPAWN := Vector3(7.5, 0.065, -3.7)
const TIME_LIMIT_MESSAGE := "시간 종료"

class StartBarrier:
	extends Node
	var started := false
	var hits_verified := false
	var tv_verified := false
	var tv_requested := false
	var deposit_verified := false
	var drop_verified := false
	@rpc("authority", "call_remote", "reliable")
	func begin() -> void:
		started = true
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
	var start := _lobby.get_node("%Start") as Button
	if is_host:
		_lobby.get_node("%Host").pressed.emit()
		_check(start.visible and start.disabled, "Only the host sees Start, disabled before joining")
		await _lobby.multiplayer.peer_connected
		await physics_frame
		_check(not start.disabled, "Joining enables the host's Start button")
		start.pressed.emit()
		await _lobby.child_entered_tree
	else:
		_lobby.get_node("%Join").pressed.emit()
		await _lobby.child_entered_tree
		_check(not start.visible, "The guest cannot start the game")

	await physics_frame
	var apartment := _lobby.get_node("Apartment")
	_host = apartment.get_node("Player")
	_guest = apartment.get_node("Guest")
	_pickup = apartment.get_node("Items/Item_06_egg")
	var banana: RigidBody3D = apartment.get_node("Items/Item_01_banana")
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
		_pickup.global_position = Vector3(7, 0.065, -2.4)
		banana.global_position = Vector3(5, 0.065, -3.5)
		barrier.begin.rpc_id(apartment.guest_peer_id)
		await _test_host(banana)
		timer.start(2.0)
	else:
		await _expect(func() -> bool: return barrier.started, "Both peers finish checking spawn positions before movement begins")
		await _test_guest()
	await _expect(func() -> bool: return clock.text == "00:02" or clock.text == "00:01", "The host's remaining time is displayed")
	await _expect(func() -> bool: return finish.visible, "Timeout ends the round on both peers")
	_check(clock.text == "00:00" and finish.get_node("Message").text.contains(TIME_LIMIT_MESSAGE)
		and apartment.process_mode == Node.PROCESS_MODE_DISABLED, "The finished round displays zero and freezes play")
	if is_host:
		await _expect(func() -> bool: return _lobby.get_node_or_null("Apartment") == null, "The host returns to the lobby when the guest leaves")
		_check(start.disabled, "Leaving frees the guest slot and disables Start")
	else:
		await _tap(KEY_ESCAPE)
		_check(_lobby.get_node_or_null("Apartment") == null and _lobby.get_node("%Join").visible, "Esc returns the guest to the main menu")
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
	_check(_guest.position.x < 7.25 and _guest.position.z > -2.6, "The host receives both axes of guest movement")
	_check(_guest.rotation.y > 1.0, "The host receives guest turning")
	_check(_host.position.distance_to(HOST_SPAWN) < 0.08 and _host.held_pickup == null, "Guest input affects only the guest")
	var from := _pickup.global_position
	await _expect(func() -> bool: return _guest.held_pickup == null and _pickup.global_position.distance_to(from) > 0.35,
		"Guest throw moves the shared pickup on the host")
	_check(guest_launch.has("velocity") and (guest_launch["velocity"] as Vector3).length() <= 10.001, "The host uses the guest's charged speed within zero to ten")
	if guest_launch.has("velocity"):
		var direction := (guest_launch["velocity"] as Vector3).normalized()
		_check(absf(rad_to_deg(asin(direction.y)) - 25.0) < 0.01, "The guest's throw uses the merged 25-degree angle")
	_key(KEY_W, true)
	await _expect(func() -> bool: return _host.position.z < -2.65, "Host can also walk toward a pickup")
	_key(KEY_W, false)
	_check(_host._highlighted_pickup == second and _guest._highlighted_pickup == null, "Only the host's own nearest grab target is highlighted on the host")
	await _hold_left(75)
	_check(_host.held_pickup == second, "Host can pick up the banana")
	_mouse(MOUSE_BUTTON_LEFT, true)
	await _wait_frames(20)
	_mouse(MOUSE_BUTTON_LEFT, false)
	var apartment := _lobby.get_node("Apartment")
	var tv: RigidBody3D = apartment._pickups.filter(func(item: RigidBody3D) -> bool: return item.get_meta(&"item_id", "") == "17-tv")[0]
	tv.global_position = _guest.global_position + Vector3.UP * 0.8
	await _expect(func() -> bool: return _guest.held_pickup == tv, "A guest can also pick up the shared TV")
	var tv_from := tv.global_position
	await _expect(func() -> bool: return _guest.held_pickup == null and tv.global_position.distance_to(tv_from) > 0.35, "A charged TV throw is simulated by the host")
	await _expect(func() -> bool: return root.get_node("SmokeBarrier").tv_verified, "The guest observes the TV flight before the hit fixture is reset")
	await _test_hits_host(apartment)
	await _expect(func() -> bool: return root.get_node("SmokeBarrier").tv_requested, "The guest is ready to test bagging")
	_guest.hold_pickup(tv)
	await _expect(func() -> bool: return apartment.get_node("HUD/HusbandBag/Items").get_child_count() == 1, "The host receives the guest's deposit")
	_check(not tv.visible and not tv.is_in_group(&"pickups"), "A guest deposit removes the same object on the host")
	_host.hold_pickup(second)
	_mouse(MOUSE_BUTTON_RIGHT, true)
	_mouse(MOUSE_BUTTON_RIGHT, false)
	await _expect(func() -> bool: return apartment.get_node("HUD/WifeProfile/WifeWallet/Gold").text == "000020", "The host's banana deposit awards 20 gold")
	await _expect(func() -> bool: return root.get_node("SmokeBarrier").deposit_verified, "The guest confirmed the deposit before the hit")
	# Use a power-four projectile to prove the host rolls bag loss and relays it to the guest.
	var pan: RigidBody3D = apartment.get_node("Items/Item_07_frying_pan")
	pan.arm(_host)
	pan._on_body_entered(_guest)
	await _expect(func() -> bool: return tv.visible and apartment.get_node("HUD/HusbandProfile/HusbandWallet/Gold").text == "000000", "The host restores the dropped TV and deducts 900 gold")
	await _expect(func() -> bool: return root.get_node("SmokeBarrier").drop_verified, "The guest confirmed the synchronized loss")


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
	await _expect(func() -> bool: return _host.held_pickup != null, "Guest sees the host move and pick up the banana")
	_check(_host.position.z < -2.65 and _guest.held_pickup == null, "Host input affects only the host")
	var host_pickup := _host.held_pickup
	var host_release := host_pickup.global_position
	await _expect(func() -> bool: return _host.held_pickup == null and host_pickup.global_position.distance_to(host_release) > 0.35,
		"Guest sees the host throw the shared sphere")
	var apartment := _lobby.get_node("Apartment")
	var tv: RigidBody3D = apartment._pickups.filter(func(item: RigidBody3D) -> bool: return item.get_meta(&"item_id", "") == "17-tv")[0]
	await _expect(func() -> bool: return tv.global_position.distance_to(_guest.global_position + Vector3.UP * 0.8) < 0.1, "Guest receives the shared TV transform")
	await _hold_left(96)
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
	var guest_gold: Label = apartment.get_node("HUD/HusbandProfile/HusbandWallet/Gold")
	await _expect(func() -> bool: return guest_gold.text == "000900", "The guest's TV deposit awards 900 gold")
	await _expect(func() -> bool: return apartment.get_node("HUD/WifeBag/Items").get_child_count() == 1, "The guest receives the host's deposit")
	_check(not tv.visible and not tv.is_in_group(&"pickups") and _guest.held_pickup == null, "Snapshots cannot bring a bagged object back to the guest's hand")
	root.get_node("SmokeBarrier").confirm_deposit.rpc_id(1)
	await _expect(func() -> bool: return tv.visible and guest_gold.text == "000000", "The guest sees the dropped TV and the gold deduction")
	_check(_guest.bag_weight == 0 and apartment.get_node("HUD/HusbandBag/Items").get_child_count() == 0 and tv.is_in_group(&"pickups"),
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
	var hit_position := _guest.global_position
	await _wait_frames(20)
	_check(_guest.is_stunned() and _guest.global_position.distance_to(hit_position) < 0.02, "The server blocks guest movement during the stun")
	await _wait_frames(20)
	_check(not _guest.is_stunned(), "The server releases the guest's movement after half a second")
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
