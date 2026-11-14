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

	await _hold_key(KEY_A, 18)
	_check(player.rotation.y > 0.5, "A turns the player left")
	_check(player.global_position.distance_to(spawn) < 0.05, "Turning leaves the player in place")
	var forward := -player.global_transform.basis.z
	await _hold_key(KEY_W, 18)
	_check((player.global_position - spawn).distance_to(forward * 1.2) < 0.15, "W moves along the current heading")
	await _hold_key(KEY_S, 18)
	_check(player.global_position.distance_to(spawn) < 0.15, "S reverses along the current heading")
	await _hold_key(KEY_D, 18)
	_check(absf(player.rotation.y) < 0.1, "D turns back to the starting heading")

	for yaw: float in [0.0, PI / 2.0, PI, -PI / 2.0]:
		player.global_position = spawn
		player.rotation.y = yaw
		await _hold_key(KEY_W, 150)
		var heading := -player.global_transform.basis.z
		var wall_distance := absf(heading.x) * 7.53 + absf(heading.z) * 5.53
		var traveled := (player.global_position - spawn).dot(heading)
		_check(absf(traveled - wall_distance) < 0.15, "Wall blocks movement at yaw %s" % yaw)

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
