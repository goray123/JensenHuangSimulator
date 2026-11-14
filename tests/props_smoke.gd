extends SceneTree

var failed := false


func _initialize() -> void:
	call_deferred("_run")


func _run() -> void:
	# Compare against the authored models before the furnishing script wraps them.
	var source := preload("res://map_props.tscn").instantiate()
	source.set_script(null)
	root.add_child(source)
	var original_bounds: Dictionary = {}
	for model: Node3D in get_nodes_in_group(&"throwable_props"):
		original_bounds[String(model.name)] = _mesh_bounds(model, Transform3D.IDENTITY)
	source.free()
	var apartment := preload("res://courtyard.tscn").instantiate()
	root.add_child(apartment)
	var player := apartment.get_node("Player") as CharacterBody3D
	var trajectory := player.get_node("ThrowTrajectory") as MeshInstance3D
	var power := apartment.get_node("HUD/ThrowPower") as ProgressBar
	var props := get_nodes_in_group(&"apartment_props")
	_check(props.size() == 18, "The TV and all 17 small props are throwable")
	_check(get_nodes_in_group(&"pickups").size() == 21, "All props and the three spheres share the pickup system")
	for body: RigidBody3D in props:
		var model := body.get_node("Model") as Node3D
		var actual := _mesh_bounds(model, Transform3D.IDENTITY)
		var original: AABB = original_bounds[String(body.name)]
		_check(actual.position.distance_to(original.position) < 0.001 and actual.size.distance_to(original.size) < 0.001, "%s keeps its authored size and position" % body.name)
		_check(body.scale.is_equal_approx(Vector3.ONE), "%s has an unscaled physics body" % body.name)
		var shape := (body.get_node("CollisionShape3D") as CollisionShape3D).shape as BoxShape3D
		var collider_bounds := AABB(-shape.size * 0.5, shape.size).grow(0.001)
		_check(collider_bounds.encloses(_mesh_bounds(model, body.global_transform.affine_inverse())), "%s has a collider enclosing its scaled meshes" % body.name)
	await _wait_for_physics(15)
	var ground_y := player.global_position.y
	var launch_position := Vector3(7.5, ground_y, -1.6)
	# Isolate selectable targets without changing any furniture or collision geometry.
	for pickup in get_nodes_in_group(&"pickups"):
		pickup.remove_from_group(&"pickups")
	for body: RigidBody3D in props:
		body.add_to_group(&"pickups")
		var model := body.get_node("Model") as Node3D
		var model_scale := model.scale
		var approach := Vector3.BACK
		if body.name == &"Television" or body.name == &"Plunger":
			approach = Vector3.LEFT
		elif body.name == &"BedsideLamp":
			approach = Vector3.FORWARD
		var distance := 0.9 if body.get_parent().name in [&"Kitchen", &"SecondBedroom"] else 0.75
		player.global_position = Vector3(body.global_position.x, ground_y, body.global_position.z) + approach * distance
		await _tap(KEY_E)
		_check(player.held_pickup == body, "%s can be picked up from standing height" % body.name)
		if player.held_pickup != body:
			body.remove_from_group(&"pickups")
			continue
		_check(body.freeze and body.collision_layer == 0, "%s is safe to carry" % body.name)
		player.global_position = launch_position
		player.rotation.y = 0.0
		_set_key(KEY_T, true)
		await _wait_for_physics(30)
		_check(trajectory.visible and trajectory.points.size() > 2, "%s shows an oriented throw trajectory" % body.name)
		var predicted: PackedVector3Array = trajectory.points.duplicate()
		var release_speed := power.value
		_set_key(KEY_T, false)
		_check(player.held_pickup == null and not body.freeze, "%s launches on release" % body.name)
		var horizontal_velocity := body.linear_velocity * Vector3(1, 0, 1)
		_check(absf(body.linear_velocity.length() - release_speed) < 0.002 and horizontal_velocity.normalized().dot(-player.global_basis.z) > 0.99, "%s launches forward at the speed shown when T is released" % body.name)
		_check(body.global_position.distance_to(predicted[0]) < 0.001, "%s uses the same lowered origin as its preview" % body.name)
		var collider := body.get_node("CollisionShape3D") as CollisionShape3D
		var bounds := collider.global_transform * collider.shape.get_debug_mesh().get_aabb()
		_check(bounds.position.y >= ground_y + 0.019, "%s starts above the floor after lowering the launch origin" % body.name)
		await _wait_for_physics(3)
		var error := INF
		for point: Vector3 in predicted:
			error = minf(error, body.global_position.distance_to(point))
		_check(error < 0.25, "%s follows its predicted flight" % body.name)
		await _wait_for_physics(90)
		_check(body.global_position.y > -0.05, "%s collides with the apartment floor" % body.name)
		_check(model.scale.is_equal_approx(model_scale), "%s retains its visual scale after a throw" % body.name)
		player.global_position = Vector3(body.global_position.x, ground_y, body.global_position.z + 0.7)
		await _tap(KEY_E)
		_check(player.held_pickup == body, "%s can be picked up again" % body.name)
		# Release in open space before testing the next item.
		player.global_position = launch_position
		player.rotation.y = 0.0
		await _tap(KEY_T)
		body.freeze = true
		body.collision_layer = 0
		body.collision_mask = 0
		body.remove_from_group(&"pickups")

	# A TV intersecting a wall must remain in the hand when T is released.
	var tv := apartment.get_node_or_null("Furnishings/LivingRoom/Television") as RigidBody3D
	if tv == null:
		# Thrown bodies are now children of the apartment.
		for body: RigidBody3D in props:
			if body.get_meta(&"pickup_name") == "TV":
				tv = body
	tv.global_position = launch_position + Vector3(0, 0.8, -0.6)
	tv.add_to_group(&"pickups")
	player.global_position = launch_position
	await _tap(KEY_E)
	_check(player.held_pickup == tv, "The TV is held before testing an obstructed release")
	# Keep the player fixed to deliberately put the held box inside the wall.
	player.set_physics_process(false)
	player.global_position = Vector3(6.5, ground_y, -0.33)
	player.rotation.y = PI
	var blocked := [false]
	player.throw_blocked.connect(func() -> void: blocked[0] = true, CONNECT_ONE_SHOT)
	await _tap(KEY_T)
	_check(player.held_pickup == tv and tv.freeze, "A blocked TV throw keeps the TV in hand")
	_check(blocked[0], "The player signals that the throw was blocked")
	_check(get_nodes_in_group(&"apartment_props").size() == 18, "Throw cycles preserve every prop without duplicating bodies")
	if not failed:
		print("Apartment props smoke test passed.")
	quit(int(failed))


func _mesh_bounds(model: Node3D, world_to_frame: Transform3D) -> AABB:
	var result := AABB()
	var initialized := false
	var meshes := model.find_children("*", "MeshInstance3D", true, false)
	if model is MeshInstance3D:
		meshes.append(model)
	for mesh: MeshInstance3D in meshes:
		var bounds := (world_to_frame * mesh.global_transform) * mesh.get_aabb()
		result = result.merge(bounds) if initialized else bounds
		initialized = true
	return result


func _check(condition: bool, message: String) -> void:
	if not condition:
		failed = true
		push_error(message)


func _tap(key: Key) -> void:
	_set_key(key, true)
	await _wait_for_physics(3)
	_set_key(key, false)
	await _wait_for_physics(2)


func _set_key(key: Key, pressed: bool) -> void:
	var event := InputEventKey.new()
	event.physical_keycode = key
	event.pressed = pressed
	Input.parse_input_event(event)
	Input.flush_buffered_events()


func _wait_for_physics(frames: int) -> void:
	for _frame in frames:
		await physics_frame
