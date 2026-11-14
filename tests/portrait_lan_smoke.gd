extends SceneTree

# Run two instances together, using -- host / -- guest after this script.
# The other LAN smoke tests use the same room ports and must run separately.
const LOBBY := preload("res://lan_lobby.tscn")

class PortraitBarrier:
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
var _host: CharacterBody3D
var _guest: CharacterBody3D
var _wife: TextureRect
var _husband: TextureRect
var _barrier: PortraitBarrier
var _failed := false


func _initialize() -> void:
	_run.call_deferred()


func _run() -> void:
	var args := OS.get_cmdline_user_args()
	if args.size() != 1 or args[0] not in ["host", "guest"]:
		push_error("Specify host or guest after --.")
		quit(1)
		return
	create_timer(40.0).timeout.connect(func() -> void:
		push_error("Portrait LAN smoke test timed out (%s)." % args[0])
		quit(1)
	)
	var is_host := args[0] == "host"
	_barrier = PortraitBarrier.new()
	_barrier.name = "PortraitSmokeBarrier"
	root.add_child(_barrier)
	_lobby = LOBBY.instantiate()
	_lobby.play_intro = false
	root.add_child(_lobby)
	if is_host:
		_lobby._host_room()
	else:
		_lobby._find_room()
	if not await _expect(func() -> bool: return _lobby.get_node_or_null("Apartment") != null, "Both peers load the apartment", 10.0):
		return
	await _wait_frames(8)
	_apartment = _lobby.get_node("Apartment")
	_host = _apartment.get_node("Player")
	_guest = _apartment.get_node("Guest")
	_wife = _apartment.get_node("HUD").portraits[0]
	_husband = _apartment.get_node("HUD").portraits[1]
	_check(_wife.current_state == &"idle" and _husband.current_state == &"idle", "Both cards start idle")
	if is_host:
		await _test_host()
	else:
		await _test_guest()
	if not _failed:
		print("Portrait LAN smoke test passed (%s)." % args[0])
	quit(int(_failed))


func _test_host() -> void:
	if not await _expect(func() -> bool: return _barrier.guest_stage >= 1, "The guest is ready"):
		return
	for item in _apartment._pickups:
		item.freeze = true
		item.disarm()
	var ring: RigidBody3D = _apartment.get_node("Items/Item_12_ring")
	var tv: RigidBody3D = _apartment._pickups.filter(func(item: RigidBody3D) -> bool: return item.get_meta(&"item_id", "") == "17-tv")[0]
	var pan: RigidBody3D = _apartment.get_node("Items/Item_07_frying_pan")
	# 1. The guest player holds the 800-gold ring; the guest only learns this from snapshots.
	_guest.hold_pickup(ring)
	_check(_husband.current_state == &"proud" and _wife.current_state == &"idle", "The host shows the proud husband card")
	_barrier.advance.rpc_id(_apartment.guest_peer_id, 1)
	if not await _expect(func() -> bool: return _barrier.guest_stage >= 2, "The guest checks the snapshot-driven proud reaction"):
		return
	# 2. Pick up and bag the TV within one frame, so no snapshot ever shows it held.
	_host.hold_pickup(tv)
	_apartment._bag_held_item(0, _apartment._pickups.find(tv))
	_check(_wife.current_state == &"proud" and not tv.visible, "The quick TV deposit makes the wife proud on the host")
	_barrier.advance.rpc_id(_apartment.guest_peer_id, 2)
	if not await _expect(func() -> bool: return _barrier.guest_stage >= 3, "The guest checks the bag-driven proud reaction"):
		return
	# 3. A real projectile hit on the guest player, simulated by the host.
	pan.arm(_host)
	pan._on_body_entered(_guest)
	_check(_husband.current_state == &"fallen", "The host shows the fallen husband card")
	_barrier.advance.rpc_id(_apartment.guest_peer_id, 3)
	if not await _expect(func() -> bool: return _barrier.guest_stage >= 4, "The guest sees the hit reaction"):
		return
	# 4. A host-side status effect on the host player is relayed to the guest.
	_host.apply_status_effect(&"poison", 2.0)
	_check(_wife.current_state == &"sad", "A status effect makes the wife sad over proud on the host")
	_barrier.advance.rpc_id(_apartment.guest_peer_id, 4)
	if not await _expect(func() -> bool: return _barrier.guest_stage >= 5, "The guest sees the relayed status effect"):
		return
	await _expect(func() -> bool: return _wife.current_state == &"idle" and _husband.current_state == &"idle", "Both host cards return to idle", 5.0)
	await _expect(func() -> bool: return _barrier.guest_stage >= 6, "The guest sees both cards return to idle", 8.0)


func _test_guest() -> void:
	_barrier.acknowledge.rpc_id(1, 1)
	if not await _expect(func() -> bool: return _barrier.stage >= 1, "The host holds the ring for the guest"):
		return
	if not await _expect(func() -> bool: return _guest.held_pickup != null and _husband.current_state == &"proud", "A held-item snapshot makes the husband card proud on the guest"):
		return
	var remaining: float = _husband._remaining[&"proud"]
	await _wait_frames(30)
	_check(_husband.current_state == &"proud" and _husband._remaining[&"proud"] < remaining - 0.3 and _husband.current_frame > 0,
		"Repeated snapshots neither restart the proud timer nor the clip")
	_check(_wife.current_state == &"idle", "The reaction stays on the husband card")
	_barrier.acknowledge.rpc_id(1, 2)
	if not await _expect(func() -> bool: return _barrier.stage >= 2, "The host deposits the TV"):
		return
	if not await _expect(func() -> bool: return _apartment.get_node("HUD/WifeBag/Items").get_child_count() == 1, "The reliable deposit reaches the guest"):
		return
	_check(_wife.current_state == &"proud", "A deposit without a held snapshot still makes the wife proud on the guest")
	_barrier.acknowledge.rpc_id(1, 3)
	if not await _expect(func() -> bool: return _barrier.stage >= 3, "The host throws a hit"):
		return
	if not await _expect(func() -> bool: return _husband.current_state == &"fallen", "The reliable hit makes the husband card fall on the guest"):
		return
	_barrier.acknowledge.rpc_id(1, 4)
	if not await _expect(func() -> bool: return _barrier.stage >= 4, "The host applies a status effect"):
		return
	if not await _expect(func() -> bool: return _wife.current_state == &"sad", "The relayed status effect makes the wife sad on the guest"):
		return
	_barrier.acknowledge.rpc_id(1, 5)
	if not await _expect(func() -> bool: return _wife.current_state == &"idle" and _husband.current_state == &"idle", "Both guest cards return to idle", 5.0):
		return
	_barrier.acknowledge.rpc_id(1, 6)
	await _wait_frames(10)


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
