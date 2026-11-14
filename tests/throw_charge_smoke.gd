extends SceneTree

var failed := false


func _initialize() -> void:
	call_deferred("_run")


func _run() -> void:
	var apartment := preload("res://courtyard.tscn").instantiate()
	root.add_child(apartment)
	var player := apartment.get_node("Player") as CharacterBody3D
	var sphere := apartment.get_node("Pickup1") as RigidBody3D
	var power := apartment.get_node("HUD/ThrowPower") as ProgressBar
	var trajectory := player.get_node("ThrowTrajectory") as MeshInstance3D
	for item in get_nodes_in_group(&"pickups"):
		if item != sphere:
			item.remove_from_group(&"pickups")
	await _wait_for_physics(15)
	var ground_y := player.global_position.y
	_prepare(player, sphere, ground_y)
	_set_key(KEY_T, true)
	_check(power.visible and is_zero_approx(power.value), "A fresh T press starts aiming at zero speed")
	await _wait_for_physics(30)
	_check(absf(power.value - 5.0) < 0.3, "Speed rises to five after half a second")
	_set_key(KEY_T, true, true)
	await _wait_for_physics(30)
	_check(power.value > 9.98 and power.value <= 10.0, "Speed peaks at ten after one second and key repeat does not reset it")
	await _wait_for_physics(30)
	_check(absf(power.value - 5.0) < 0.3, "Speed falls back through five after one and a half seconds")
	await _wait_for_physics(30)
	_check(power.value < 0.01, "Speed returns to zero after two seconds")
	_check(trajectory.visible and trajectory.mesh.get_surface_count() == 1, "Near-zero-speed drops still have a visible trajectory")
	var vertices: PackedVector3Array = trajectory.mesh.surface_get_arrays(0)[Mesh.ARRAY_VERTEX]
	var has_area := false
	for index in range(0, vertices.size(), 3):
		_check(vertices[index].is_finite(), "Trajectory vertices stay finite at zero speed")
		if (vertices[index + 1] - vertices[index]).cross(vertices[index + 2] - vertices[index]).length_squared() > 0.000000000001:
			has_area = true
	_check(has_area, "The vertical drop preview has visible ribbon width")
	await _wait_for_physics(60)
	_check(power.value > 9.98 and power.value <= 10.0, "The oscillation repeats and reaches ten again after three seconds")
	var displayed_speed := power.value
	var expected_heading := -player.global_basis.z * cos(deg_to_rad(25.0)) + Vector3.UP * sin(deg_to_rad(25.0))
	var expected_origin: Vector3 = trajectory.points[0]
	_check(absf(sphere.global_position.y - expected_origin.y - 0.15) < 0.001, "The preview starts 15 cm below the held sphere")
	_set_key(KEY_T, false)
	_check(player.held_pickup == null, "Releasing T launches the held object")
	_check(absf(sphere.linear_velocity.length() - displayed_speed) < 0.002, "Release preserves the displayed speed before resetting the timer")
	_check(sphere.linear_velocity.normalized().dot(expected_heading) > 0.999, "The launch angle remains stable as speed changes")
	_check(absf(rad_to_deg(asin(sphere.linear_velocity.normalized().y)) - 25.0) < 0.01, "Throws launch at 25 degrees above horizontal")
	_check(sphere.global_position.distance_to(expected_origin) < 0.001, "The actual throw starts at the lowered preview origin")
	_check(not power.visible and not trajectory.visible, "Release hides the gauge and trajectory")

	_prepare(player, sphere, ground_y)
	_set_key(KEY_T, true)
	_set_key(KEY_T, false)
	_check(sphere.linear_velocity.is_zero_approx(), "An immediate release launches with exactly zero initial velocity")
	await _wait_for_physics(20)
	_check(sphere.global_position.y < 0.5, "A zero-speed release drops naturally under gravity")

	_prepare(player, sphere, ground_y)
	_set_key(KEY_T, true)
	await _wait_for_physics(90)
	var falling_speed := power.value
	_check(absf(falling_speed - 5.0) < 0.3, "A later hold can release on the descending half of the cycle")
	_set_key(KEY_T, false)
	_check(absf(sphere.linear_velocity.length() - falling_speed) < 0.002, "Descending-cycle releases use the current speed")

	_prepare(player, sphere, ground_y)
	_set_key(KEY_T, true)
	await _wait_for_physics(30)
	player.notification(Node.NOTIFICATION_APPLICATION_FOCUS_OUT)
	_set_key(KEY_T, false)
	_check(player.held_pickup == sphere and not power.visible, "Focus loss cancels the charge without throwing")
	_set_key(KEY_T, true)
	_check(is_zero_approx(power.value), "A new aim after cancellation starts at zero")
	_set_key(KEY_T, false)
	_check(sphere.linear_velocity.is_zero_approx(), "Cancellation does not carry old speed into the next throw")
	if not failed:
		print("Throw charge smoke test passed.")
	quit(int(failed))


func _prepare(player: CharacterBody3D, sphere: RigidBody3D, ground_y: float) -> void:
	sphere.freeze = true
	sphere.linear_velocity = Vector3.ZERO
	sphere.angular_velocity = Vector3.ZERO
	sphere.global_position = Vector3(6.5, ground_y + 0.07666667, -2.0)
	player.global_position = Vector3(6.5, ground_y, -1.2)
	player.rotation.y = 0.0
	_set_key(KEY_E, true)
	_set_key(KEY_E, false)
	_check(player.held_pickup == sphere, "The test sphere is held before charging")


func _check(condition: bool, message: String) -> void:
	if not condition:
		failed = true
		push_error(message)


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
