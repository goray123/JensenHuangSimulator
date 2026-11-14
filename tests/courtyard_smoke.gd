extends SceneTree

var failed := false


func _initialize() -> void:
	call_deferred("_run")


func _run() -> void:
	var courtyard := (load(ProjectSettings.get_setting("application/run/main_scene")) as PackedScene).instantiate()
	root.add_child(courtyard)
	var player := courtyard.get_node("Player") as CharacterBody3D
	var camera := courtyard.get_node("Overview") as Camera3D
	var camera_transform := camera.global_transform
	await _wait_for_physics(15)
	var spawn := player.global_position
	_check(player.is_on_floor(), "Player lands on the floor")

	var movement_cases := [
		{"keys": [KEY_W], "direction": Vector3.FORWARD},
		{"keys": [KEY_A], "direction": Vector3.LEFT},
		{"keys": [KEY_S], "direction": Vector3.BACK},
		{"keys": [KEY_D], "direction": Vector3.RIGHT},
		{"keys": [KEY_W, KEY_A], "direction": Vector3(-1, 0, -1).normalized()},
		{"keys": [KEY_W, KEY_D], "direction": Vector3(1, 0, -1).normalized()},
		{"keys": [KEY_S, KEY_A], "direction": Vector3(-1, 0, 1).normalized()},
		{"keys": [KEY_S, KEY_D], "direction": Vector3(1, 0, 1).normalized()},
	]
	for movement_case in movement_cases:
		player.global_position = spawn
		# Start facing away to verify that movement does not depend on the old heading.
		var direction: Vector3 = movement_case.direction
		player.rotation.y = atan2(direction.x, direction.z)
		for key: Key in movement_case.keys:
			_set_key(key, true)
		await _wait_for_physics(36)
		for key: Key in movement_case.keys:
			_set_key(key, false)
		var displacement := player.global_position - spawn
		_check(displacement.distance_to(direction * 2.4) < 0.15, "Keys %s move steadily in the requested direction at a consistent speed" % [movement_case.keys])
		_check((-player.global_transform.basis.z).dot(direction) > 0.99, "Keys %s turn the player toward movement" % [movement_case.keys])

	await _wait_for_physics(2)
	var stopped := player.global_position
	var stopped_yaw := player.rotation.y
	await _wait_for_physics(5)
	_check(player.global_position.distance_to(stopped) < 0.01, "Releasing the keys stops movement")
	_check(is_equal_approx(player.rotation.y, stopped_yaw), "Releasing the keys preserves the last heading")
	_set_key(KEY_A, true)
	await _hold_key(KEY_D, 18)
	_set_key(KEY_A, false)
	_check(player.global_position.distance_to(stopped) < 0.01, "Opposite keys cancel movement")
	_check(is_equal_approx(player.rotation.y, stopped_yaw), "Opposite keys preserve the heading")

	for movement_case in movement_cases.slice(0, 4):
		player.global_position = spawn
		await _hold_key(movement_case.keys[0], 150)
		var direction: Vector3 = movement_case.direction
		var wall_distance := absf(direction.x) * 7.53 + absf(direction.z) * 5.53
		var traveled := (player.global_position - spawn).dot(direction)
		_check(absf(traveled - wall_distance) < 0.15, "Wall blocks movement in direction %s" % direction)

	_check(camera.is_current() and camera.global_transform == camera_transform, "Camera stays fixed")
	if not failed:
		print("Courtyard smoke test passed.")
	quit(int(failed))


func _check(condition: bool, message: String) -> void:
	if not condition:
		failed = true
		push_error(message)


func _hold_key(key: Key, frames: int) -> void:
	_set_key(key, true)
	await _wait_for_physics(frames)
	_set_key(key, false)


func _set_key(key: Key, pressed: bool) -> void:
	var event := InputEventKey.new()
	event.physical_keycode = key
	event.pressed = pressed
	Input.parse_input_event(event)
	Input.flush_buffered_events()


func _wait_for_physics(frames: int) -> void:
	for _frame in frames:
		await physics_frame
