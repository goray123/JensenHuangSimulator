extends SceneTree

const THROWABLE := preload("res://throwable.gd")
const PLAYER := preload("res://player.tscn")

var failed := false


func _initialize() -> void:
	call_deferred("_run")


func _run() -> void:
	var lab := Node3D.new()
	lab.name = "BananaPhysicsLab"
	root.add_child(lab)
	var floor_body := _box(lab, "Floor", Vector3(0, -0.25, 0), Vector3(40, 0.5, 40))
	floor_body.add_to_group(&"map_floor")
	var table := _box(lab, "Table", Vector3(8, 0.5, 0), Vector3(3, 1, 3))
	var wall := _box(lab, "Wall", Vector3(-8, 2, -1.5), Vector3(3, 4, 0.25))
	wall.add_to_group(&"map_floor")
	var player := PLAYER.instantiate() as CharacterBody3D
	player.reads_local_input = false
	player.position = Vector3(0, 0.02, 4)
	lab.add_child(player)
	await _wait_for_physics(5)

	# Ordinary gravity and resting on a floor are not enough to turn a banana into a peel.
	var unthrown := _banana(lab, Vector3(4, 1, 0))
	unthrown.freeze = false
	await _wait_for_physics(90)
	_check(not unthrown.is_banana_peel and unthrown.is_in_group(&"pickups"), "An unthrown banana remains a pickup after falling onto the floor")
	unthrown.freeze = true

	# Only actual floor contacts count: neither a side wall nor a tabletop is a floor.
	var table_banana := _banana(lab, Vector3(8, 1.7, 0))
	var touched_table := [false]
	table_banana.body_entered.connect(func(body: Node) -> void: touched_table[0] = touched_table[0] or body == table)
	table_banana.freeze = false
	table_banana.arm(player)
	await _wait_for_physics(90)
	_check(touched_table[0] and not table_banana.is_banana_peel, "A thrown banana can rest on an untagged table without becoming a peel")
	table_banana.freeze = true

	var wall_banana := _banana(lab, Vector3(-8, 2, 0))
	wall_banana.rotation.x = PI * 0.5
	var touched_wall := [false]
	wall_banana.body_entered.connect(func(body: Node) -> void: touched_wall[0] = touched_wall[0] or body == wall)
	wall_banana.freeze = false
	wall_banana.linear_velocity = Vector3(0, 0, -5)
	wall_banana.arm(player)
	await _expect(func() -> bool: return touched_wall[0], "The wall fixture receives a real banana collision", 45)
	_check(not wall_banana.is_banana_peel, "Hitting the side of a wall does not turn a banana into a peel")
	wall_banana.disarm()
	wall_banana.freeze = true

	var banana := _banana(lab, Vector3(0, 1, 3))
	var original_model := banana.get_node("Model") as MeshInstance3D
	var landings: Array[Transform3D] = []
	banana.banana_landed.connect(func(pose: Transform3D) -> void: landings.append(pose))
	player.hold_pickup(banana)
	player.release_pickup(true, player.throw_velocity_at_speed(5.0))
	_check(player.held_pickup == null and not banana.freeze, "The player really releases the banana through the normal throw action")
	banana.rotation.x = PI * 0.5
	banana.angular_velocity = Vector3(2, 3, 4)
	await _expect(func() -> bool: return banana.is_banana_peel, "A thrown banana becomes a peel after an actual floor collision", 180)
	_check(landings.size() == 1, "A floor landing is announced exactly once")
	_check(not original_model.visible, "The original banana model disappears when the peel appears")
	var peel := banana.get_node_or_null("BananaPeel") as Area3D
	_check(peel != null and peel.visible, "Conversion displays the imported banana peel asset")
	_check(banana.freeze and banana.linear_velocity.is_zero_approx() and banana.angular_velocity.is_zero_approx(), "The landed peel is fixed in place without remaining motion")
	_check(banana.collision_layer == 0 and banana.collision_mask == 0 and not banana.is_in_group(&"pickups"), "A fixed peel no longer behaves as a throwable pickup")
	if peel != null:
		_check(absf(peel.global_position.y - 0.005) < 0.015 and peel.global_basis.y.normalized().dot(Vector3.UP) > 0.999, "The peel lies upright at the actual floor surface")
	var landing_pose := banana.global_transform
	banana.become_banana_peel(landing_pose)
	_check(banana.find_children("BananaPeel", "Area3D", true, false).size() == 1 and not original_model.visible, "Repeated conversion does not duplicate the peel or restore the banana")
	await _wait_for_physics(60)
	_check(banana.global_transform.is_equal_approx(landing_pose) and landings.size() == 1, "The peel stays fixed and does not announce another landing")
	for pickup in get_nodes_in_group(&"pickups"):
		pickup.remove_from_group(&"pickups")
	player.global_position = banana.global_position + Vector3(0, 0.02, 0.5)
	_check(player.get_pickup_target() == null and player.held_pickup == null, "An anchored peel cannot be selected for pickup")

	# A pickup can win the race with a floor contact already queued for deferred handling.
	var caught := _banana(lab, Vector3(0, 1, 4))
	caught.arm(player)
	caught.set("_banana_land_pending", true)
	var generation := int(caught.get("_flight_generation"))
	caught.call_deferred("_finish_banana_landing", Transform3D(Basis.IDENTITY, Vector3(0, 0.005, 4)), generation)
	player.hold_pickup(caught)
	await _wait_for_physics(3)
	_check(player.held_pickup == caught and not caught.is_banana_peel and caught.get_node_or_null("BananaPeel") == null, "Picking up a banana cancels a queued landing from its previous flight")
	lab.free()
	await process_frame
	await _check_apartment_integration()
	if not failed:
		print("Banana floor conversion smoke test passed.")
	quit(int(failed))


func _check_apartment_integration() -> void:
	var apartment := preload("res://house.tscn").instantiate()
	root.add_child(apartment)
	var player := apartment.get_node("Player") as CharacterBody3D
	player.reads_local_input = false
	await _wait_for_physics(10)
	var bananas: Array[RigidBody3D] = []
	for item in get_nodes_in_group(&"household_items"):
		if item.get_meta(&"item_id", "") == "01-banana":
			bananas.append(item)
	_check(bananas.size() == 1, "The authored house banana is marked for floor conversion")
	_check(not get_nodes_in_group(&"map_floor").is_empty(), "The apartment supplies tagged physical floor colliders")
	if bananas.is_empty():
		apartment.free()
		return
	var banana := bananas[0]
	var count_before := get_nodes_in_group(&"household_items").size()
	var original_body_id := banana.get_instance_id()
	var ground_y := player.global_position.y
	player.global_position = Vector3(6.5, ground_y, -1.6)
	player.rotation.y = 0.0
	player.hold_pickup(banana)
	player.release_pickup(true, Vector3.ZERO)
	_check(player.held_pickup == null, "A real map banana can be released at zero charge")
	await _expect(func() -> bool: return banana.is_banana_peel, "A real apartment banana becomes a peel on the real apartment floor", 120)
	_check(absf(banana.global_position.y - ground_y - 0.005) < 0.02, "The apartment peel uses the map's raised floor height")
	_check(banana.get_instance_id() == original_body_id and get_nodes_in_group(&"household_items").size() == count_before, "Conversion preserves the original body and stable household item count")
	apartment.free()


func _banana(parent: Node3D, position: Vector3) -> RigidBody3D:
	var body := THROWABLE.new()
	body.name = "Banana"
	body.freeze = true
	body.collision_layer = 2
	body.collision_mask = 3
	body.continuous_cd = true
	body.linear_damp_mode = RigidBody3D.DAMP_MODE_REPLACE
	body.linear_damp = 0.0
	body.set_meta(&"item_id", "01-banana")
	var shape := BoxShape3D.new()
	shape.size = Vector3(0.35, 0.15, 0.15)
	var collider := CollisionShape3D.new()
	collider.name = "CollisionShape3D"
	collider.shape = shape
	body.add_child(collider)
	var model := MeshInstance3D.new()
	model.name = "Model"
	var mesh := BoxMesh.new()
	mesh.size = shape.size
	model.mesh = mesh
	body.add_child(model)
	parent.add_child(body)
	body.global_position = position
	body.add_to_group(&"pickups")
	return body


func _box(parent: Node3D, node_name: String, position: Vector3, size: Vector3) -> StaticBody3D:
	var body := StaticBody3D.new()
	body.name = node_name
	var collider := CollisionShape3D.new()
	var shape := BoxShape3D.new()
	shape.size = size
	collider.shape = shape
	body.add_child(collider)
	parent.add_child(body)
	body.position = position
	return body


func _expect(condition: Callable, message: String, max_frames: int) -> void:
	for _frame in max_frames:
		if condition.call():
			return
		await physics_frame
	_check(false, message)


func _check(condition: bool, message: String) -> void:
	if not condition:
		failed = true
		push_error(message)


func _wait_for_physics(frames: int) -> void:
	for _frame in frames:
		await physics_frame
