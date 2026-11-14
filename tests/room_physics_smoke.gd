extends SceneTree

var failed := false


func _initialize() -> void:
	call_deferred("_run")


func _run() -> void:
	var source := preload("res://assets/ownership_dispute_map.tscn").instantiate()
	root.add_child(source)
	var authored: Dictionary = {}
	for mesh: MeshInstance3D in source.find_children("*", "MeshInstance3D", true, false):
		if not "shadow" in String(mesh.name).to_lower():
			# Repeated mesh names are excluded from this name-based comparison.
			authored[mesh.name] = null if authored.has(mesh.name) else mesh.global_transform
	source.free()
	var apartment := preload("res://tests/courtyard_fixture.tscn").instantiate()
	root.add_child(apartment)
	var player := apartment.get_node("Player") as CharacterBody3D
	player.reads_local_input = false
	var furniture := get_nodes_in_group(&"dynamic_furniture")
	_check(furniture.size() >= 26, "All 26 furniture objects have dynamic physics bodies")
	_check(get_nodes_in_group(&"pickups").size() == 21, "Existing E pickup targets are preserved")
	for mesh: MeshInstance3D in apartment.get_node("Map").find_children("*", "MeshInstance3D", true, false):
		if mesh.visible and authored.get(mesh.name) != null:
			_check(mesh.global_transform.is_equal_approx(authored[mesh.name]), "%s keeps its authored transform and scale" % mesh.name)
	var bodies: Array[RigidBody3D] = []
	bodies.assign(get_nodes_in_group(&"pickups"))
	for body: RigidBody3D in furniture:
		bodies.append(body)
		_check(not body.is_in_group(&"pickups"), "%s stays a movable furnishing rather than an E pickup" % body.name)
		_check(body.find_children("*", "StaticBody3D", true, false).is_empty(), "%s has no stale static collider" % body.name)
		_check(not body.find_children("*", "CollisionShape3D", true, false).is_empty(), "%s has a physical collider" % body.name)
	for body in bodies:
		_check(not body.freeze, "%s simulates physics before being picked up" % body.name)
		_check(body.collision_layer == 2 and body.collision_mask == 3, "%s collides with the room and other objects" % body.name)
		var volume: float = body.get_meta(&"physics_volume", -1.0)
		var weight_scale := 1.0 if body.is_in_group(&"dynamic_furniture") else 0.75
		_check(volume > 0 and is_equal_approx(body.mass, maxf(volume * 40.0, 0.02) * weight_scale * 0.5), "%s has half its previous physical mass" % body.name)
		_check(body.scale.is_equal_approx(Vector3.ONE), "%s has an unscaled physics body" % body.name)
	_check(player.collision_mask & 2 != 0, "Players collide with movable objects")
	var floors := get_nodes_in_group(&"map_floor")
	_check(not floors.is_empty(), "The apartment floor keeps its static collision")
	for floor_body in floors:
		_check(floor_body is StaticBody3D, "Floors stay fixed while furniture moves")
	await _wait_for_physics(120)
	for body in bodies:
		_check(body.global_position.is_finite() and body.linear_velocity.is_finite(), "%s remains numerically stable" % body.name)
		_check(body.global_position.y > -0.15, "%s does not fall through the floor" % body.name)
		_check(body.linear_velocity.length() < 15.0, "%s settles without an explosive impulse" % body.name)

	# Remove unrelated contacts from the following controlled physical interactions.
	for body in bodies:
		body.freeze = true
	player.global_position = Vector3(6.2, 0.065, -0.9)
	var dropped := apartment.get_node("Pickup1") as RigidBody3D
	player.hold_pickup(dropped)
	await _wait_for_physics(3)
	_check(dropped.freeze and dropped.collision_layer == 0, "An object held in the hand stays frozen and harmless")
	var drop_height := dropped.global_position.y
	player.release_pickup(false)
	_check(not dropped.freeze and player.held_pickup == null, "A non-thrown server release resumes dynamic physics")
	await _wait_for_physics(10)
	_check(dropped.global_position.y < drop_height - 0.02, "A released object falls under gravity")
	player.hold_pickup(dropped)
	player.release_pickup(false)
	dropped.gravity_scale = 0.0
	dropped.global_position = player.global_position + Vector3.UP
	dropped.linear_velocity = Vector3.ZERO
	dropped.sleeping = true
	await _wait_for_physics(6)
	_check(player in dropped.get_collision_exceptions(), "Release protection stays active while the object overlaps its owner")
	player.global_position += Vector3.RIGHT * 1.5
	await _wait_for_physics(3)
	_check(not player in dropped.get_collision_exceptions(), "A sleeping dropped object regains owner collision once separated")
	player.hold_pickup(dropped)
	player.release_pickup(true, player.throw_velocity_at_speed(8.0))
	await _wait_for_physics(8)
	_check(not player in dropped.get_collision_exceptions(), "A thrown object regains owner collision after leaving the hand")
	var owner_contacts: Array[bool] = []
	dropped.body_entered.connect(func(body: Node) -> void:
		if body == player:
			owner_contacts.append(true))
	dropped.global_position = player.global_position + Vector3(0, 1, -1)
	dropped.linear_velocity = Vector3.BACK * 8.0
	await _wait_for_physics(20)
	_check(not owner_contacts.is_empty() and not player.is_stunned(), "The thrower can collide with their returned projectile without taking a hit")
	dropped.gravity_scale = 1.0
	dropped.freeze = true
	dropped.collision_layer = 0
	dropped.collision_mask = 0
	var stool := apartment.get_node("Map/Kitchen/Stool00") as RigidBody3D
	var fridge := apartment.get_node("Map/Kitchen/Refrigerator") as RigidBody3D
	_check(fridge.mass > stool.mass * 2.0, "The refrigerator is heavier than a small stool")
	for body in [stool, fridge]:
		body.collision_layer = 0
		body.collision_mask = 0
		body.gravity_scale = 0
		body.freeze = false
		body.sleeping = false
		body.linear_velocity = Vector3.ZERO
		body.apply_central_impulse(Vector3.RIGHT * 2.0)
	await _wait_for_physics(2)
	_check(stool.linear_velocity.x > fridge.linear_velocity.x * 1.5, "The same impulse moves a small object faster than a large one")
	fridge.freeze = true
	fridge.gravity_scale = 1
	fridge.collision_layer = 2
	fridge.collision_mask = 3
	_reset_stool(stool, Vector3(6.2, 0, -2.15))
	player.global_position = Vector3(6.2, 0.065, -0.9)
	player.velocity = Vector3.ZERO
	player.rotation.y = 0
	await _wait_for_physics(6)
	var before_push := stool.global_position
	player.remote_input = Vector2.UP
	await _wait_for_physics(90)
	player.remote_input = Vector2.ZERO
	_check(stool.global_position.distance_to(before_push) > 0.08, "Walking into a stool physically pushes it")

	# An off-center impact from a real throwable must also impart angular motion.
	player.global_position = Vector3(7.5, 0.065, -2.0)
	player.velocity = Vector3.ZERO
	_reset_stool(stool, Vector3(6.0, 0, -2.4))
	await _wait_for_physics(6)
	var before_hit := stool.global_position
	var tv := apartment.get_node("Furnishings/LivingRoom/Television") as RigidBody3D
	tv.freeze = false
	tv.sleeping = false
	tv.global_transform = Transform3D(Basis.IDENTITY, stool.global_position + Vector3(0.15, 0.2, 1.3))
	tv.linear_velocity = Vector3.FORWARD * 8.0
	tv.angular_velocity = Vector3.ZERO
	tv.arm(player)
	var maximum_spin := 0.0
	for _frame in 45:
		await physics_frame
		maximum_spin = maxf(maximum_spin, stool.angular_velocity.length())
	_check(stool.global_position.distance_to(before_hit) > 0.03, "A thrown TV physically displaces furniture")
	_check(maximum_spin > 0.1, "An off-center thrown-object impact makes furniture rotate")
	if not failed:
		print("Room physics smoke test passed.")
	quit(int(failed))


func _reset_stool(stool: RigidBody3D, floor_position: Vector3) -> void:
	stool.freeze = true
	var size: Vector3 = stool.get_meta(&"physics_size")
	stool.global_transform = Transform3D(Basis.IDENTITY, floor_position + Vector3.UP * (0.065 + size.y * 0.5))
	stool.linear_velocity = Vector3.ZERO
	stool.angular_velocity = Vector3.ZERO
	stool.gravity_scale = 1
	stool.collision_layer = 2
	stool.collision_mask = 3
	stool.freeze = false
	stool.sleeping = false


func _check(condition: bool, message: String) -> void:
	if not condition:
		failed = true
		push_error(message)


func _wait_for_physics(frames: int) -> void:
	for _frame in frames:
		await physics_frame
