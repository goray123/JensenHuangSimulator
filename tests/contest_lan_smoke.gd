extends SceneTree

# Run two instances together, using -- host / -- guest after this script.
# The normal LAN smoke test uses the same room ports and must run separately.
const LOBBY := preload("res://lan_lobby.tscn")
const Player := preload("res://player.gd")

class ContestBarrier:
	extends Node
	var stage := 0
	var guest_stage := 0
	@rpc("authority", "call_remote", "reliable")
	func advance(value: int) -> void:
		stage = maxi(stage, value)
	@rpc("any_peer", "call_remote", "reliable")
	func acknowledge(value: int) -> void:
		guest_stage = maxi(guest_stage, value)

var _lobby: Node
var _apartment: Node3D
var _host: Player
var _guest: Player
var _pickup: RigidBody3D
var _contest: Node
var _camera: Camera3D
var _camera_transform := Transform3D.IDENTITY
var _camera_size := 15.0
var _barrier: ContestBarrier
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
		push_error("Contest LAN smoke test timed out (%s)." % args[0])
		quit(1)
	)
	var is_host := args[0] == "host"
	_barrier = ContestBarrier.new()
	_barrier.name = "ContestSmokeBarrier"
	root.add_child(_barrier)
	_lobby = LOBBY.instantiate()
	root.add_child(_lobby)
	if is_host:
		_lobby.get_node("%Host").pressed.emit()
		if not await _expect(func() -> bool: return not _lobby.get_node("%Start").disabled, "The guest joins the host's real LAN room"):
			return
		_lobby.get_node("%Start").pressed.emit()
	else:
		_lobby.get_node("%Join").pressed.emit()
	if not await _expect(func() -> bool: return _lobby.get_node_or_null("Apartment") != null, "Both peers load the apartment"):
		return
	await _wait_frames(8)
	_apartment = _lobby.get_node("Apartment")
	_host = _apartment.get_node("Player")
	_guest = _apartment.get_node("Guest")
	_pickup = _apartment.get_node("Pickup1")
	_contest = _apartment._contest
	_camera = _apartment.get_node("Overview")
	_camera_transform = _camera.global_transform
	_camera_size = _camera.size
	_check(_contest._players.size() == 2 and not _contest.active, "Both peers register the contest players without starting a round")
	if is_host:
		await _test_host()
	else:
		await _test_guest()
	if not _failed:
		print("Contest LAN smoke test passed (%s)." % args[0])
	quit(int(_failed))


func _test_host() -> void:
	if not await _expect(func() -> bool: return _barrier.guest_stage >= 1, "The guest is ready before changing the shared fixture"):
		return
	for item in _apartment._pickups:
		item.freeze = true
		item.disarm()
	_host.global_position = Vector3(-2.0, 0.01, 3.0)
	_guest.global_position = Vector3(-2.0, 0.01, 2.0)
	_host.rotation.y = 0.0
	_guest.rotation.y = 0.0
	_host.hold_pickup(_pickup)
	await _wait_frames(8)
	_barrier.advance.rpc_id(_apartment.guest_peer_id, 1)
	if not await _expect(func() -> bool: return _contest.active, "The guest's E starts a contest against the current holder"):
		return
	var first_round: int = _contest.round_id
	await _verify_active_round(0)
	if not await _expect(func() -> bool: return _barrier.guest_stage >= 2, "Both peers inspect the half-full gauge before mashing"):
		return
	_barrier.advance.rpc_id(_apartment.guest_peer_id, 2)
	if not await _expect(func() -> bool: return not _contest.active and _guest.held_pickup == _pickup, "Twenty guest E presses win the shared object"):
		return
	await _verify_result(1)
	if not await _expect(func() -> bool: return _barrier.guest_stage >= 3, "Both peers finish the first loss-stun timing check"):
		return
	await _tap(KEY_E)
	_check(_contest.active and _contest.round_id == first_round + 1, "The recovered host can challenge the guest holding the same object")
	await _verify_active_round(1)
	if not await _expect(func() -> bool: return _barrier.guest_stage >= 4, "The guest checks the new round and sends obsolete round taps"):
		return
	_check(is_equal_approx(_contest.progress, 0.5), "Delayed first-round RPC taps do not score in the second round")
	for _press in 20:
		await _tap(KEY_E)
	_check(not _contest.active and _host.held_pickup == _pickup, "Twenty host E presses win the object back")
	await _verify_result(0)
	if not await _expect(func() -> bool: return _barrier.guest_stage >= 5, "Both peers finish the second result and reject stale ownership"):
		return
	_barrier.advance.rpc_id(_apartment.guest_peer_id, 5)
	if not await _expect(func() -> bool: return _contest.active and _contest.round_id == first_round + 2, "The guest can start a third contest after recovering"):
		return
	await _wait_frames(28)
	_check(_camera.size < _camera_size, "The third round is zoomed in before testing disconnection")
	_barrier.advance.rpc_id(_apartment.guest_peer_id, 6)
	var camera_reference: WeakRef = weakref(_camera)
	var presentation_reference: WeakRef = weakref(_contest.presentation)
	if not await _expect(func() -> bool: return _lobby.get_node_or_null("Apartment") == null, "Leaving during a contest returns the host to the lobby"):
		return
	await process_frame
	_check(camera_reference.get_ref() == null and presentation_reference.get_ref() == null, "Disconnect frees the contest camera and presentation")
	_check(_lobby.get_node("Menu").visible and _lobby.get_node("%Start").disabled, "The host can wait for another player after contest cleanup")


func _test_guest() -> void:
	_barrier.acknowledge.rpc_id(1, 1)
	if not await _expect(func() -> bool: return _barrier.stage >= 1 and _host.held_pickup == _pickup, "The guest receives the server's held item and fixture"):
		return
	_check(_host.global_position.distance_to(Vector3(-2.0, 0.0, 3.0)) < 0.08 and _guest.global_position.distance_to(Vector3(-2.0, 0.0, 2.0)) < 0.08, "Both fixture positions reach the guest")
	await _tap(KEY_E)
	if not await _expect(func() -> bool: return _contest.active, "E near the other holder opens the guest's contest UI"):
		return
	var first_round: int = _contest.round_id
	await _verify_active_round(0)
	_barrier.acknowledge.rpc_id(1, 2)
	if not await _expect(func() -> bool: return _barrier.stage >= 2, "The server is ready to observe the guest's mash input"):
		return
	for _press in 20:
		await _tap(KEY_E)
	if not await _expect(func() -> bool: return not _contest.active and _guest.held_pickup == _pickup, "The reliable result attaches the won object to the guest"):
		return
	var first_revision: int = _contest.revision
	await _verify_result(1)
	_verify_stale_snapshot(0, first_revision - 1)
	_barrier.acknowledge.rpc_id(1, 3)
	if not await _expect(func() -> bool: return _contest.active and _contest.round_id == first_round + 1, "The guest receives the host's second-round challenge"):
		return
	await _verify_active_round(1)
	for _press in 3:
		_contest._request_interaction.rpc_id(1, first_round, _contest.item_index)
	_contest._sync_progress(first_round, 0.99)
	_check(is_equal_approx(_contest.progress, 0.5), "A delayed progress message cannot change the new round's gauge")
	_barrier.acknowledge.rpc_id(1, 4)
	if not await _expect(func() -> bool: return not _contest.active and _host.held_pickup == _pickup, "The host's winning result removes the item from the guest"):
		return
	await _verify_result(0)
	_verify_stale_snapshot(1, first_revision)
	_barrier.acknowledge.rpc_id(1, 5)
	if not await _expect(func() -> bool: return _barrier.stage >= 5, "The host finishes checking the second result before the next challenge"):
		return
	await _tap(KEY_E)
	if not await _expect(func() -> bool: return _contest.active and _contest.round_id == first_round + 2, "The recovered guest can challenge again"):
		return
	if not await _expect(func() -> bool: return _barrier.stage >= 6, "Both peers see the third closeup before leaving"):
		return
	_check(_camera.size < _camera_size and _contest.presentation.gauge.is_visible_in_tree(), "The guest leaves with the closeup and gauge active")
	var camera_reference: WeakRef = weakref(_camera)
	var presentation_reference: WeakRef = weakref(_contest.presentation)
	await _tap(KEY_ESCAPE)
	await process_frame
	_check(_lobby.get_node_or_null("Apartment") == null and _lobby.get_node("Menu").visible, "Esc during a contest restores the guest's main menu")
	_check(camera_reference.get_ref() == null and presentation_reference.get_ref() == null, "Guest cleanup frees the contest UI and camera")
	_check(_lobby.get_node("%Join").visible and _lobby._peer == null, "Contest cleanup closes the guest network connection")


func _verify_active_round(holder: int) -> void:
	_check(_contest.active and _contest.presentation.active, "The contest and its presentation are active together")
	_check(is_equal_approx(_contest.progress, 0.5) and is_equal_approx(_contest.presentation.progress, 0.5), "The two-color gauge begins exactly half full")
	_check(_contest.presentation.gauge.is_visible_in_tree(), "The bottom contest gauge is visible")
	_check(_host.contest_active and _guest.contest_active, "Both players are movement locked during the contest")
	var host_position := _host.global_position
	var guest_position := _guest.global_position
	_key(KEY_D, true)
	_key(KEY_T, true)
	await _wait_frames(16)
	_key(KEY_T, false)
	_key(KEY_D, false)
	_check(_host.global_position.distance_to(host_position) < 0.05 and _guest.global_position.distance_to(guest_position) < 0.05, "WASD cannot move either player during the closeup")
	_check(not _host._is_aiming and not _guest._is_aiming, "T cannot begin charging or throwing during the contest")
	_check((_host.held_pickup == _pickup) == (holder == 0) and (_guest.held_pickup == _pickup) == (holder == 1), "The object stays with its current holder until the contest ends")
	_check(_camera.size < _camera_size - 2.0, "The local camera smoothly closes in on both players")


func _verify_result(winner: int) -> void:
	var loser := _host if winner == 1 else _guest
	var observed_at := Time.get_ticks_msec()
	var loser_position := loser.global_position
	_check(not _contest.active and not _contest.presentation.active and not _host.contest_active and not _guest.contest_active, "Finishing releases both contest movement locks")
	_check(is_equal_approx(_contest.progress, 1.0 if winner == 0 else 0.0), "The winner's color fills the entire gauge")
	_check(loser.is_stunned() and loser._stun_remaining > 2.2, "The losing player receives the new 2.5-second stun")
	_check(_pickup.get_parent() == (_host if winner == 0 else _guest).get_node("RightArm/HandSocket"), "Only the winner's hand owns the item after the reliable result")
	if loser.reads_local_input:
		_key(KEY_D, true)
	await create_timer(0.45).timeout
	_check(_camera.global_transform.is_equal_approx(_camera_transform) and is_equal_approx(_camera.size, _camera_size), "The original camera transform and size return after the result")
	_check(not _contest.presentation.gauge.is_visible_in_tree(), "The result hides the contest gauge")
	while Time.get_ticks_msec() - observed_at < 2100:
		await physics_frame
	_check(loser.is_stunned() and loser.global_position.distance_to(loser_position) < 0.05, "The loser remains immobile beyond two seconds despite movement input")
	if loser.reads_local_input:
		_key(KEY_D, false)
	if not await _expect(func() -> bool: return not loser.is_stunned(), "The 2.5-second loss stun eventually expires", 1.0):
		return
	_check(Time.get_ticks_msec() - observed_at >= 2250, "The loss stun lasts substantially longer than the normal half-second hit stun")


func _verify_stale_snapshot(old_holder: int, old_revision: int) -> void:
	var host_transform := _host.transform
	var guest_transform := _guest.transform
	var transforms: Array[Transform3D] = [host_transform, guest_transform]
	for item in _apartment._pickups:
		transforms.append(item.global_transform)
	transforms[0].origin += Vector3(4.0, 0.0, 0.0)
	transforms[1].origin -= Vector3(4.0, 0.0, 0.0)
	var pickup_index: int = _apartment._pickups.find(_pickup)
	var old_holding := Vector2i(pickup_index, -1) if old_holder == 0 else Vector2i(-1, pickup_index)
	_apartment._apply_snapshot(transforms, old_holding, old_revision)
	_check(_host.transform.is_equal_approx(host_transform) and _guest.transform.is_equal_approx(guest_transform), "A stale ownership snapshot cannot rewind player transforms")
	_check((_host.held_pickup == _pickup) == (old_holder == 1) and (_guest.held_pickup == _pickup) == (old_holder == 0), "A stale previous-holder snapshot cannot undo the contest winner")


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
