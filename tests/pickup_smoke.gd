extends SceneTree

var failed := false


func _initialize() -> void:
	call_deferred("_run")


func _run() -> void:
	var courtyard := preload("res://courtyard.tscn").instantiate()
	root.add_child(courtyard)
	var player := courtyard.get_node("Player") as CharacterBody3D
	var status := courtyard.get_node("HUD/PickupStatus") as Label
	var hand := player.get_node("RightArm/HandSocket") as Marker3D
	var trajectory := player.get_node("ThrowTrajectory") as MeshInstance3D
	var power := courtyard.get_node("HUD/ThrowPower") as ProgressBar
	var holding_changes: Array[bool] = []
	player.held_pickup_changed.connect(func(is_holding: bool) -> void: holding_changes.append(is_holding))
	await _wait_for_physics(15)
	var ground_y := player.global_position.y
	var total_pickups := get_nodes_in_group(&"pickups").size()
	var pickups: Array[Node] = [courtyard.get_node("Pickup1"), courtyard.get_node("Pickup2"), courtyard.get_node("Pickup3")]
	_check(pickups.size() == 3, "Three pickups spawn in the apartment")
	var head := player.get_node("Head") as MeshInstance3D
	var head_mesh := head.mesh as SphereMesh
	for pickup: RigidBody3D in pickups:
		var sphere := (pickup.get_node("Sphere") as MeshInstance3D).mesh as SphereMesh
		_check(is_equal_approx(sphere.radius, head_mesh.radius / 3.0), "Pickup diameter is one third of the head diameter")
		_check(is_equal_approx(sphere.height, sphere.radius * 2.0), "Pickup is a sphere")
		_check(absf(pickup.global_position.y - sphere.radius) < 0.001, "Pickup rests above the floor")
	_check(status.text == "손: 비어 있음", "HUD starts with empty hands")

	await _tap(KEY_T)
	_check(not trajectory.visible, "Empty hands do not show a throw preview")
	await _tap(KEY_E)
	_check(get_nodes_in_group(&"pickups").size() == total_pickups and player.held_pickup == null, "Empty throws and distant pickup attempts leave all objects in place")
	var first := pickups[0] as RigidBody3D
	player.global_position = Vector3(first.global_position.x, ground_y, first.global_position.z + 0.8)
	_set_key(KEY_W, true)
	await _wait_for_physics(3)
	_set_key(KEY_W, false)
	await _wait_for_physics(2)
	_check(get_nodes_in_group(&"pickups").size() == total_pickups, "Walking near a pickup does not collect it automatically")
	await _tap(KEY_E)
	_check(player.held_pickup == first and first.get_parent() == hand, "E attaches the nearby sphere to the hand instead of deleting it")
	_check(first.freeze and first.global_position.distance_to(hand.global_position) < 0.001, "The held sphere stays fixed at the hand")
	_check(status.text.contains("T 누르기: 조준 / 떼기: 던지기"), "HUD explains press-to-aim and release-to-throw")
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
	_check(player.held_pickup == first and get_nodes_in_group(&"pickups").size() == total_pickups - 1, "E and key repeat cannot collect a second sphere while holding one")
	_check(holding_changes == [true], "Failed pickup attempts do not emit extra holding changes")
	second.global_position = Vector3(-4, 0.07666667, -3)
	third.global_position = Vector3(4, 0.07666667, 3)

	# Leave room for the flight check before the first collision.
	player.global_position = Vector3(-0.8, ground_y, 2.0)
	_set_key(KEY_T, true)
	await _wait_for_physics(3)
	_check(player.held_pickup == first and first.freeze, "Pressing T keeps the sphere in hand")
	_check(trajectory.visible and trajectory.points.size() > 2 and trajectory.mesh.get_surface_count() == 1, "Holding T draws the predicted path")
	var previous_endpoint: Vector3 = trajectory.points[-1]
	_set_key(KEY_T, true, true)
	await _wait_for_physics(8)
	_check(player.held_pickup == first and trajectory.visible, "T key repeat keeps aiming without throwing")
	_set_key(KEY_W, true)
	await _wait_for_physics(18)
	_set_key(KEY_W, false)
	await _wait_for_physics(2)
	var heading := -player.global_transform.basis.z
	var path_heading: Vector3 = trajectory.points[1] - trajectory.points[0]
	path_heading.y = 0
	_check(path_heading.normalized().dot(heading) > 0.99, "Aiming follows movement and turning while T is held")
	_check((trajectory.points[-1] as Vector3).distance_to(previous_endpoint) > 1.0, "Turning updates the predicted impact point")
	var release_position: Vector3 = trajectory.points[0]
	var expected_impact: Vector3 = trajectory.points[-1]
	var predicted_points: PackedVector3Array = trajectory.points.duplicate()
	var release_speed := power.value
	var impacts: Array[Vector3] = []
	first.contact_monitor = true
	first.max_contacts_reported = 4
	first.body_entered.connect(func(_body: Node) -> void: impacts.append(first.global_position))
	_set_key(KEY_T, false)
	_check(player.held_pickup == null and first.get_parent() == courtyard and not first.freeze, "Releasing T launches the sphere with physics enabled")
	_check(absf(first.linear_velocity.length() - release_speed) < 0.002, "Launch speed matches the aiming gauge at release")
	var horizontal_velocity := first.linear_velocity * Vector3(1, 0, 1)
	_check(horizontal_velocity.normalized().dot(heading) > 0.99, "Variable-speed throws still follow the current heading")
	_check(not trajectory.visible and trajectory.points.is_empty(), "Releasing T clears the predicted path")
	_check(status.text == "손: 비어 있음" and holding_changes == [true, false], "Throwing clears the hand and updates the HUD")
	await _wait_for_physics(4)
	_check((first.global_position - release_position).dot(heading) > 0.15, "The thrown sphere travels forward")
	var path_error := INF
	for point: Vector3 in predicted_points:
		path_error = minf(path_error, first.global_position.distance_to(point))
	_check(path_error < 0.2, "Actual flight follows the preview before impact")
	await _wait_for_physics(120)
	_check(not impacts.is_empty() and impacts[0].distance_to(expected_impact) < 0.35, "The preview ends at the first actual collision")
	_check(first.global_position.y > 0.04 and first.global_position.y < 0.15, "The thrown sphere lands on the floor")
	_check(courtyard.find_children("*", "RigidBody3D", true, false).size() == total_pickups, "Throwing and key repeat preserve all objects")
	player.global_position = Vector3(first.global_position.x - 0.7, ground_y, first.global_position.z)
	await _tap(KEY_E)
	_check(player.held_pickup == first and first.freeze, "A thrown sphere can be picked up again")

	# Test different headings next to each wall, including a diagonal throw.
	var room_bounds := Rect2(Vector2(-10.35, -5.9), Vector2(20.7, 10.55))
	var throws := [
		{"position": Vector3(-0.8, ground_y, -5.4), "yaw": 0.0},
		{"position": Vector3(9.85, ground_y, 0.9), "yaw": -PI / 2.0},
		{"position": Vector3(-2, ground_y, 4.15), "yaw": PI},
		{"position": Vector3(-9.85, ground_y, -0.95), "yaw": PI / 2.0},
		{"position": Vector3(-2, ground_y, 1.2), "yaw": PI / 4.0},
	]
	for throw_case in throws:
		player.global_position = throw_case.position
		player.rotation.y = throw_case.yaw
		heading = -player.global_transform.basis.z
		_set_key(KEY_T, true)
		await _wait_for_physics(60)
		_check(trajectory.visible and player.held_pickup == first, "The path remains visible near walls while aiming")
		var aimed_speed := power.value
		_set_key(KEY_T, false)
		# Read the launch velocity before physics advances or a nearby wall is hit.
		horizontal_velocity = first.linear_velocity * Vector3(1, 0, 1)
		_check(absf(first.linear_velocity.length() - aimed_speed) < 0.002 and horizontal_velocity.normalized().dot(heading) > 0.99, "Throw at %s uses the current heading and speed" % throw_case.position)
		await _wait_for_physics(120)
		_check(room_bounds.has_point(Vector2(first.global_position.x, first.global_position.z)), "Walls keep thrown spheres inside the apartment")
		_check(first.global_position.y > 0.04 and first.global_position.y < 0.15, "Sphere thrown at %s settles above the floor" % throw_case.position)
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
	_check(courtyard.find_children("*", "RigidBody3D", true, false).size() == total_pickups, "Repeated pickup and throw cycles never duplicate or delete objects")

	_set_key(KEY_T, true)
	await _wait_for_physics(2)
	player.notification(Node.NOTIFICATION_APPLICATION_FOCUS_OUT)
	_set_key(KEY_T, false)
	_check(player.held_pickup == second and not trajectory.visible, "Losing focus cancels aiming without throwing on release")
	await _tap(KEY_T)
	# Pressing T empty must not arm a sphere picked up later during that hold.
	_set_key(KEY_T, true)
	player.global_position = Vector3(third.global_position.x, ground_y, third.global_position.z)
	await _tap(KEY_E)
	_set_key(KEY_T, false)
	_check(player.held_pickup == third and not trajectory.visible, "A T press with empty hands cannot throw a later pickup")
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
