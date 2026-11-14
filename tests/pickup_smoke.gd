extends SceneTree

var failed := false


func _initialize() -> void:
	call_deferred("_run")


func _run() -> void:
	var courtyard := (load(ProjectSettings.get_setting("application/run/main_scene")) as PackedScene).instantiate()
	root.add_child(courtyard)
	var player := courtyard.get_node("Player") as CharacterBody3D
	var status := courtyard.get_node("HUD/PickupStatus") as Label
	var hand := player.get_node("RightArm/HandSocket") as Marker3D
	var holding_changes: Array[bool] = []
	player.held_pickup_changed.connect(func(is_holding: bool) -> void: holding_changes.append(is_holding))
	await _wait_for_physics(15)
	var ground_y := player.global_position.y
	var pickups := get_nodes_in_group(&"pickups")
	_check(pickups.size() == 3, "Three pickups spawn in the courtyard")
	var head := player.get_node("Head") as MeshInstance3D
	var head_mesh := head.mesh as SphereMesh
	for pickup: RigidBody3D in pickups:
		var sphere := (pickup.get_node("Sphere") as MeshInstance3D).mesh as SphereMesh
		_check(is_equal_approx(sphere.radius, head_mesh.radius / 3.0), "Pickup diameter is one third of the head diameter")
		_check(is_equal_approx(sphere.height, sphere.radius * 2.0), "Pickup is a sphere")
		_check(absf(pickup.global_position.y - sphere.radius) < 0.001, "Pickup rests above the floor")
	_check(status.text == "손: 비어 있음", "HUD starts with empty hands")

	await _tap(KEY_T)
	await _tap(KEY_E)
	_check(get_nodes_in_group(&"pickups").size() == 3 and player.held_pickup == null, "Empty throws and distant pickup attempts leave all spheres in place")
	var first := pickups[0] as RigidBody3D
	player.global_position = Vector3(first.global_position.x, ground_y, first.global_position.z + 0.8)
	_set_key(KEY_W, true)
	await _wait_for_physics(3)
	_set_key(KEY_W, false)
	await _wait_for_physics(2)
	_check(get_nodes_in_group(&"pickups").size() == 3, "Walking near a pickup does not collect it automatically")
	await _tap(KEY_E)
	_check(player.held_pickup == first and first.get_parent() == hand, "E attaches the nearby sphere to the hand instead of deleting it")
	_check(first.freeze and first.global_position.distance_to(hand.global_position) < 0.001, "The held sphere stays fixed at the hand")
	_check(status.text == "손: 구를 들고 있음 (T로 던지기)", "HUD shows the held sphere and throw control")
	_set_key(KEY_D, true)
	await _wait_for_physics(36)
	_set_key(KEY_D, false)
	await _wait_for_physics(2)
	_check(first.global_position.distance_to(hand.global_position) < 0.001, "The held sphere follows movement and turning")

	# A full hand must not delete another nearby sphere.
	var second := pickups[1] as RigidBody3D
	var third := pickups[2] as RigidBody3D
	second.global_position = player.global_position + Vector3(0, 0.08, 0.5)
	await _tap(KEY_E)
	_set_key(KEY_E, true, true)
	await _wait_for_physics(3)
	_set_key(KEY_E, false)
	_check(player.held_pickup == first and get_nodes_in_group(&"pickups").size() == 2, "E and key repeat cannot collect a second sphere while holding one")
	_check(holding_changes == [true], "Failed pickup attempts do not emit extra holding changes")
	second.global_position = Vector3(-4, 0.07666667, -3)
	third.global_position = Vector3(4, 0.07666667, 3)

	var release_position := first.global_position
	var heading := -player.global_transform.basis.z
	_set_key(KEY_T, true)
	await _wait_for_physics(3)
	_check(player.held_pickup == null and first.get_parent() == courtyard and not first.freeze, "T releases the sphere into the world with physics enabled")
	_check(first.linear_velocity.dot(heading) > 4.0, "Throw velocity follows the player's current facing")
	_check(status.text == "손: 비어 있음" and holding_changes == [true, false], "Throwing clears the hand and updates the HUD")
	_set_key(KEY_T, true, true)
	await _wait_for_physics(8)
	_set_key(KEY_T, false)
	_check((first.global_position - release_position).dot(heading) > 0.5, "The thrown sphere travels forward")
	await _wait_for_physics(120)
	_check(first.global_position.y > 0.04 and first.global_position.y < 0.15, "The thrown sphere lands on the floor")
	_check(courtyard.find_children("*", "RigidBody3D", true, false).size() == 3, "Throwing and key repeat preserve all three spheres")
	player.global_position = Vector3(first.global_position.x - 0.7, ground_y, first.global_position.z)
	await _tap(KEY_E)
	_check(player.held_pickup == first and first.freeze, "A thrown sphere can be picked up again")

	# Test different headings next to each wall, including a diagonal throw.
	var throws := [
		{"position": Vector3(0, ground_y, -5.4), "yaw": 0.0},
		{"position": Vector3(7.4, ground_y, 0), "yaw": -PI / 2.0},
		{"position": Vector3(0, ground_y, 5.4), "yaw": PI},
		{"position": Vector3(-7.4, ground_y, 0), "yaw": PI / 2.0},
		{"position": Vector3.ZERO + Vector3.UP * ground_y, "yaw": PI / 4.0},
	]
	for throw_case in throws:
		player.global_position = throw_case.position
		player.rotation.y = throw_case.yaw
		heading = -player.global_transform.basis.z
		_set_key(KEY_T, true)
		# Read the launch velocity before physics advances or a nearby wall is hit.
		_check(first.linear_velocity.dot(heading) > 5.9, "Each throw uses the current character heading")
		_set_key(KEY_T, false)
		await _wait_for_physics(120)
		_check(absf(first.global_position.x) < 8.0 and absf(first.global_position.z) < 6.0, "Walls keep thrown spheres inside the courtyard")
		_check(first.global_position.y > 0.04 and first.global_position.y < 0.15, "Thrown spheres settle above the floor")
		player.global_position = Vector3(first.global_position.x, ground_y, first.global_position.z)
		await _tap(KEY_E)
		_check(player.held_pickup == first, "Spheres remain reusable after wall collisions")

	# With empty hands, choose only the nearest of two eligible spheres.
	await _tap(KEY_T)
	player.global_position = Vector3(0, ground_y, 0)
	second.global_position = Vector3(0.5, 0.07666667, 0)
	third.global_position = Vector3(1.0, 0.07666667, 0)
	await _tap(KEY_E)
	_check(player.held_pickup == second and third.is_in_group(&"pickups"), "Empty hands pick only the nearest eligible sphere")
	_check(courtyard.find_children("*", "RigidBody3D", true, false).size() == 3, "Repeated pickup and throw cycles never duplicate or delete spheres")
	if not failed:
		print("Pickup smoke test passed.")
	quit(int(failed))


func _check(condition: bool, message: String) -> void:
	if not condition:
		failed = true
		push_error(message)


func _tap(key: Key) -> void:
	_set_key(key, true)
	await _wait_for_physics(3)
	_set_key(key, false)
	await _wait_for_physics(2)


func _set_key(key: Key, pressed: bool, echo: bool = false) -> void:
	var event := InputEventKey.new()
	event.physical_keycode = key
	event.pressed = pressed
	event.echo = echo
	Input.parse_input_event(event)
	Input.flush_buffered_events()


func _wait_for_physics(frames: int) -> void:
	for _frame in frames:
		await physics_frame
