extends SceneTree

# This isolated loopback port does not overlap the lobby discovery tests.
const PORT := 33561
const COMIC := preload("res://comic_impact.gd")

class Barrier extends Node:
	var stage := 0
	var acknowledged := 0
	var at := Vector3.ZERO
	var chosen := -1
	@rpc("authority", "call_remote", "reliable")
	func advance(value: int, position: Vector3, variant: int) -> void:
		stage = value
		at = position
		chosen = variant
	@rpc("any_peer", "call_remote", "reliable")
	func ack(value: int) -> void:
		acknowledged = value

var failed := false
var events: Array[Dictionary] = []
var barrier := Barrier.new()


func _initialize() -> void:
	node_added.connect(func(node: Node) -> void:
		if node.get_script() == COMIC:
			events.append({"position": node.world_position, "variant": node.variant})
	)
	_run.call_deferred()


func _run() -> void:
	var args := OS.get_cmdline_user_args()
	if args.size() != 1 or args[0] not in ["host", "guest"]:
		push_error("Specify host or guest after --.")
		quit(1)
		return
	var hosting := args[0] == "host"
	create_timer(20.0).timeout.connect(func() -> void: push_error("Comic impact LAN test timed out (%s)" % args[0]); quit(1))
	barrier.name = "ComicImpactBarrier"
	root.add_child(barrier)
	var peer := ENetMultiplayerPeer.new()
	if hosting:
		peer.set_bind_ip("127.0.0.1")
		_check(peer.create_server(PORT, 1) == OK, "The comic test server starts")
	else:
		_check(peer.create_client("127.0.0.1", PORT) == OK, "The comic test client starts")
	var api := root.get_multiplayer()
	api.multiplayer_peer = peer
	if hosting:
		await api.peer_connected
	else:
		await api.connected_to_server
	var guest_id := api.get_peers()[0] if hosting else api.get_unique_id()
	var world := preload("res://house.tscn").instantiate()
	world.guest_peer_id = guest_id
	root.add_child(world)
	await _frames(12)
	world.get_node("RoundTimer").stop()
	var host: CharacterBody3D = world.get_node("Player")
	var guest: CharacterBody3D = world.get_node("Guest")
	host.set_physics_process(false)
	guest.set_physics_process(false)
	if hosting:
		await _host(world, host, guest_id)
	else:
		await _guest(world)
	world.free()
	peer.close()
	api.multiplayer_peer = OfflineMultiplayerPeer.new()
	await create_timer(0.3).timeout
	if not failed:
		print("Comic impact LAN smoke test passed (%s)." % args[0])
	quit(int(failed))


func _host(world: Node3D, host: CharacterBody3D, guest_id: int) -> void:
	if not await _expect(func() -> bool: return barrier.acknowledged == 1, "The guest loads the same impact scene"):
		return
	for index in world._physics_bodies.size():
		var body: RigidBody3D = world._physics_bodies[index]
		body.freeze = true
		if body.has_method(&"disarm"):
			body.disarm()
		body.collision_layer = 0
		body.collision_mask = 0
		body.position = Vector3(40 + index * 2, 4, -20)
	events.clear()
	barrier.advance.rpc_id(guest_id, 1, Vector3.ZERO, -1)
	if not await _expect(func() -> bool: return barrier.acknowledged == 2, "Both event counters are reset"):
		return
	var point := Vector3(6.5, 1.0, -2.3)
	world.broadcast_comic_impact(point, 0.8)
	_check(events.size() == 1, "The authority plays its local burst exactly once")
	if events.is_empty():
		return
	barrier.advance.rpc_id(guest_id, 2, point, events[0]["variant"])
	if not await _expect(func() -> bool: return barrier.acknowledged == 3, "The guest verifies the reliable contact event"):
		return
	_check(events.size() == 1, "A guest-local broadcast cannot add another host effect")
	events.clear()
	barrier.advance.rpc_id(guest_id, 3, Vector3.ZERO, -1)
	if not await _expect(func() -> bool: return barrier.acknowledged == 4, "Both peers prepare the real projectile test"):
		return
	var egg: RigidBody3D = world.get_node("Items/Item_06_egg")
	egg.global_position = Vector3(6.5, 1.4, -2.3)
	egg.collision_layer = 2
	egg.collision_mask = 3
	egg.freeze = false
	egg.sleeping = false
	egg.linear_velocity = Vector3.DOWN * 2.0
	egg.angular_velocity = Vector3.ZERO
	egg.arm(host)
	if not await _expect(func() -> bool: return not events.is_empty(), "The host's real floor collision creates a comic impact"):
		return
	egg.disarm()
	egg.freeze = true
	egg.collision_layer = 0
	egg.collision_mask = 0
	_check(events.size() == 1, "One authoritative projectile hit creates one local event")
	barrier.advance.rpc_id(guest_id, 4, events[0]["position"], events[0]["variant"])
	if not await _expect(func() -> bool: return barrier.acknowledged == 5, "The guest verifies the real projectile collision"):
		return
	await create_timer(COMIC.LIFETIME + 0.1).timeout
	_check(get_nodes_in_group(&"comic_impacts").is_empty(), "All host impacts expire after their animation")
	world.set_physics_process(false)
	barrier.advance.rpc_id(guest_id, 5, Vector3.ZERO, -1)
	if not await _expect(func() -> bool: return barrier.acknowledged == 6, "The guest also finishes cleanup"):
		return
	await _frames(3)


func _guest(world: Node3D) -> void:
	barrier.ack.rpc_id(1, 1)
	if not await _expect(func() -> bool: return barrier.stage == 1, "The server starts the contact test"):
		return
	events.clear()
	barrier.ack.rpc_id(1, 2)
	if not await _expect(func() -> bool: return barrier.stage == 2 and events.size() > 0, "The reliable contact event arrives"):
		return
	await _frames(4)
	_verify_one("A direct authority event")
	world.broadcast_comic_impact(Vector3(6.4, 1.0, -2.3), 1.0)
	await _frames(4)
	_check(events.size() == 1, "The guest cannot independently randomize or broadcast another burst")
	barrier.ack.rpc_id(1, 3)
	if not await _expect(func() -> bool: return barrier.stage == 3, "The server resets for a physical collision"):
		return
	events.clear()
	barrier.ack.rpc_id(1, 4)
	if not await _expect(func() -> bool: return barrier.stage == 4 and events.size() > 0, "The physical projectile contact arrives reliably"):
		return
	await _frames(4)
	_verify_one("A real projectile contact")
	_check(absf(barrier.at.y - 0.065) < 0.15, "The replicated burst is anchored at the real apartment floor")
	barrier.ack.rpc_id(1, 5)
	if not await _expect(func() -> bool: return barrier.stage == 5, "The server completes impact cleanup"):
		return
	_check(get_nodes_in_group(&"comic_impacts").is_empty(), "All guest impacts expire without a stale overlay")
	barrier.ack.rpc_id(1, 6)
	await _frames(3)


func _verify_one(label: String) -> void:
	_check(events.size() == 1, label + " appears exactly once on the guest")
	if events.is_empty():
		return
	_check((events[0]["position"] as Vector3).is_equal_approx(barrier.at) and events[0]["variant"] == barrier.chosen,
		label + " has exactly the authority's world position and random variation")


func _expect(condition: Callable, message: String) -> bool:
	for _frame in 480:
		if condition.call():
			return true
		await physics_frame
	_check(false, message)
	return false


func _check(condition: bool, message: String) -> void:
	if not condition:
		failed = true
		push_error(message)


func _frames(count: int) -> void:
	for _frame in count:
		await physics_frame
