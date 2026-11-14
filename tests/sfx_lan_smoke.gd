extends SceneTree

const HOUSE := preload("res://house.tscn")
const PORT := 33559
class Barrier:
	extends Node
	var stage := 0
	var acknowledged := 0
	@rpc("authority", "call_remote", "reliable")
	func advance(value: int) -> void:
		stage = value
	@rpc("any_peer", "call_remote", "reliable")
	func ack(value: int) -> void:
		acknowledged = value

var failed := false
var events: Array[StringName] = []
var barrier := Barrier.new()


func _initialize() -> void:
	node_added.connect(func(node: Node) -> void:
		if (node is AudioStreamPlayer3D or node is AudioStreamPlayer) and node.has_meta(&"sfx_event"):
			events.append(node.get_meta(&"sfx_event"))
	)
	_run.call_deferred()


func _run() -> void:
	var role := OS.get_cmdline_user_args()[0]
	var hosting := role == "host"
	create_timer(18.0).timeout.connect(func() -> void: push_error("SFX LAN timed out"); quit(1))
	barrier.name = "SfxBarrier"
	root.add_child(barrier)
	var peer := ENetMultiplayerPeer.new()
	if hosting:
		peer.set_bind_ip("127.0.0.1")
		_check(peer.create_server(PORT, 1) == OK, "The isolated audio test server starts")
	else:
		_check(peer.create_client("127.0.0.1", PORT) == OK, "The audio test client starts")
	var api := root.get_multiplayer()
	api.multiplayer_peer = peer
	if hosting:
		await api.peer_connected
	else:
		await api.connected_to_server
	var guest_id := api.get_peers()[0] if hosting else api.get_unique_id()
	var world := HOUSE.instantiate()
	world.guest_peer_id = guest_id
	root.add_child(world)
	await _frames(15)
	var host: CharacterBody3D = world.get_node("Player")
	var guest: CharacterBody3D = world.get_node("Guest")
	host.set_physics_process(false)
	guest.set_physics_process(false)
	var egg: RigidBody3D = world.get_node("Items/Item_06_egg")
	if hosting:
		if not await _expect(func() -> bool: return barrier.acknowledged == 1, "The guest loaded the test scene"): return
		events.clear()
		barrier.advance.rpc_id(guest_id, 1)
		if not await _expect(func() -> bool: return barrier.acknowledged == 2, "Both audio counters are reset"): return
		# A hold and throw in one tick can be absent from the lossy snapshot.
		host.hold_pickup(egg)
		host.release_pickup(true, host.throw_velocity_at_speed(8.0))
		egg.disarm()
		egg.freeze = true
		egg.collision_layer = 0
		egg.collision_mask = 0
		world.broadcast_prop_impact(egg, &"hit_metal")
		guest.receive_hit(&"hit_bonk")
		world.reward_thrower(guest)
		if not await _expect(func() -> bool: return barrier.acknowledged == 3, "The guest verified first-event counts"): return
		_verify_first(false)
		events.clear()
		barrier.advance.rpc_id(guest_id, 2)
		if not await _expect(func() -> bool: return barrier.acknowledged == 4, "The guest is ready for ownership transfer"): return
		host.hold_pickup(egg)
		host.release_pickup(false)
		guest.hold_pickup(egg)
		if not await _expect(func() -> bool: return barrier.acknowledged == 5, "The guest verified transfer counts"): return
		_check(_count("pickup_grab") == 2 and _count("throw_") == 0, "Ownership transfers play grabs without a false throw")
		world.set_physics_process(false)
		barrier.advance.rpc_id(guest_id, 3)
		await _frames(4)
	else:
		barrier.ack.rpc_id(1, 1)
		if not await _expect(func() -> bool: return barrier.stage == 1, "The server starts the audio event test"): return
		events.clear()
		barrier.ack.rpc_id(1, 2)
		if not await _expect(func() -> bool: return _count("pickup_coin") == 1, "The guest alone receives their hit reward"): return
		await _frames(8)
		_verify_first(true)
		barrier.ack.rpc_id(1, 3)
		if not await _expect(func() -> bool: return barrier.stage == 2, "The server starts the transfer test"): return
		events.clear()
		barrier.ack.rpc_id(1, 4)
		if not await _expect(func() -> bool: return _count("pickup_grab") == 2, "Both replicated grabs arrive"): return
		await _frames(8)
		_check(_count("pickup_grab") == 2 and _count("throw_") == 0, "Snapshots do not duplicate grabs or play transfer throws")
		barrier.ack.rpc_id(1, 5)
		if not await _expect(func() -> bool: return barrier.stage == 3, "The server completes audio checks"): return
	print("SFX LAN events ", role, ": ", events)
	world.free()
	peer.close()
	api.multiplayer_peer = OfflineMultiplayerPeer.new()
	await create_timer(0.8).timeout
	if not failed:
		print("SFX LAN smoke test passed (", role, ").")
	quit(int(failed))


func _verify_first(is_guest: bool) -> void:
	_check(_count("pickup_grab") == 1, "A brief pickup is heard exactly once even when absent from snapshots")
	_check(_count("throw_spin") == 1 and _count("throw_") == 1, "Both peers hear the same throw variant exactly once")
	_check(_count("hit_metal") == 1, "Both peers hear the material impact exactly once")
	_check(_count("hit_bonk") == 1 and _count("hit_boing") == 0, "Both peers hear the authoritative hit variant exactly once")
	_check(_count("pickup_coin") == (1 if is_guest else 0), "The hit reward is exclusive to its thrower")


func _count(prefix: String) -> int:
	return events.filter(func(sound: StringName) -> bool: return String(sound).begins_with(prefix)).size()


func _expect(condition: Callable, message: String) -> bool:
	for _frame in 480:
		if condition.call(): return true
		await physics_frame
	_check(false, message)
	quit(1)
	return false


func _check(condition: bool, message: String) -> void:
	if not condition:
		failed = true
		push_error(message)


func _frames(count: int) -> void:
	for _frame in count:
		await physics_frame
