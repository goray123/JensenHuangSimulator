extends SceneTree

var failed := false


func _initialize() -> void:
	call_deferred("_run")


func _run() -> void:
	var apartment := (load(ProjectSettings.get_setting("application/run/main_scene")) as PackedScene).instantiate()
	root.add_child(apartment)
	var player := apartment.get_node("Player") as CharacterBody3D
	var camera := apartment.get_node("Overview") as Camera3D
	var camera_transform := camera.global_transform
	await _wait_for_physics(15)
	var spawn := player.global_position
	_check(spawn.distance_to(Vector3(2.1, 0, 5.36)) < 0.02 and player.is_on_floor(), "Player starts on the entry floor at the marked spot")

	await _hold_key(KEY_S, 30)
	_check(absf(player.global_position.z - 5.48) < 0.06 and player.is_on_floor(), "The closed front door blocks the player")
	player.global_position = spawn
	await _hold_key(KEY_W, 45)
	_check(player.global_position.z < 3.0 and player.is_on_floor(), "Player can walk into the living room from the entry")

	for passage in [
		{"room": "kitchen", "start": Vector3(-5.0, 0.04, -0.6), "motion": Vector3.FORWARD * 3},
		{"room": "bedroom 1", "start": Vector3(-0.8, 0.04, -1), "motion": Vector3.FORWARD * 3},
		{"room": "bedroom 2", "start": Vector3(1.2, 0.04, -1.825), "motion": Vector3.RIGHT * 3},
		{"room": "dressing room", "start": Vector3(7.35, 0.04, 1.3), "motion": Vector3.FORWARD * 3},
		{"room": "bathroom", "start": Vector3(7.35, 0.04, -1.45), "motion": Vector3.FORWARD * 3},
	]:
		var start := Transform3D(Basis.IDENTITY, passage.start)
		_check(not player.test_move(start, passage.motion), "Player fits through the passage to %s" % passage.room)

	var sofa_approach := Transform3D(Basis.IDENTITY, Vector3(-8.7, 0.04, -1.5))
	var hit := KinematicCollision3D.new()
	_check(
		player.test_move(sofa_approach, Vector3.BACK * 3, hit)
		and hit.get_collider() == apartment.get_node("Furnishings/LivingRoom/Sofa"),
		"The living room sofa blocks the player"
	)
	var mat_approach := Transform3D(Basis.IDENTITY, Vector3(-0.6, 0.04, 2.36))
	_check(not player.test_move(mat_approach, Vector3.RIGHT * 2), "The hall runner can be walked over")

	var living_room := Vector3(-2.0, spawn.y, 1.2)
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
		player.global_position = living_room
		# Start facing away to verify that movement does not depend on the old heading.
		var direction: Vector3 = movement_case.direction
		player.rotation.y = atan2(direction.x, direction.z)
		for key: Key in movement_case.keys:
			_set_key(key, true)
		await _wait_for_physics(36)
		for key: Key in movement_case.keys:
			_set_key(key, false)
		var displacement := player.global_position - living_room
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

	for wall_case in [
		{"start": Vector3(-0.8, spawn.y, -3.6), "key": KEY_W, "direction": Vector3.FORWARD, "distance": 1.83},
		{"start": Vector3(-6.5, spawn.y, -0.95), "key": KEY_A, "direction": Vector3.LEFT, "distance": 3.38},
		{"start": living_room, "key": KEY_S, "direction": Vector3.BACK, "distance": 2.98},
		{"start": living_room, "key": KEY_D, "direction": Vector3.RIGHT, "distance": 4.38},
	]:
		player.global_position = wall_case.start
		await _hold_key(wall_case.key, 150)
		var traveled := (player.global_position - (wall_case.start as Vector3)).dot(wall_case.direction)
		_check(absf(traveled - wall_case.distance) < 0.15, "Wall blocks movement in direction %s" % wall_case.direction)

	_check(camera.projection == Camera3D.PROJECTION_ORTHOGONAL and camera.global_basis.z.y > 0.5, "The orthographic camera looks down on the apartment")
	_check(camera.is_current() and camera.global_transform == camera_transform, "Camera stays fixed")
	if not failed:
		print("Apartment smoke test passed.")
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
