extends SceneTree

var failed := false


func _initialize() -> void:
	call_deferred("_run")


func _run() -> void:
	var apartment := preload("res://courtyard.tscn").instantiate()
	root.add_child(apartment)
	var player := apartment.get_node("Player") as CharacterBody3D
	var camera := apartment.get_node("Overview") as Camera3D
	var camera_transform := camera.global_transform
	# Check authored passages and walls independently of movable obstacles.
	# The room physics smoke test covers pushing, impacts, and furniture motion.
	for body: RigidBody3D in apartment.find_children("*", "RigidBody3D", true, false):
		body.freeze = true
		body.collision_layer = 0
		body.collision_mask = 0
	await _wait_for_physics(15)
	var spawn := player.global_position
	var spawn_marker := apartment.get_node("Map/Markers/Player1Spawn") as Marker3D
	_check(spawn.distance_to(spawn_marker.global_position) < 0.02 and player.is_on_floor(), "Player starts on the floor at the new map's spawn")

	player.global_position = Vector3(8.8, spawn.y, -0.8)
	await _hold_key(KEY_S, 120)
	_check(absf(player.global_position.z + 0.32) < 0.06 and player.is_on_floor(), "The play area boundary keeps the player from falling down the entry steps")

	for passage in [
		{"room": "kitchen", "start": Vector3(5.3, spawn.y, -4.2), "motion": Vector3.FORWARD * 1.8},
		{"room": "small bedroom", "start": Vector3(8.26, spawn.y, -4.2), "motion": Vector3.FORWARD * 2},
		{"room": "main bedroom", "start": Vector3(8.3, spawn.y, -4.28), "motion": Vector3.RIGHT * 1.6},
		{"room": "bathroom", "start": Vector3(12.4, spawn.y, -4.2), "motion": Vector3.FORWARD * 1.65},
	]:
		var start := Transform3D(Basis.IDENTITY, passage.start)
		_check(not player.test_move(start, passage.motion), "Player fits through the passage to %s" % passage.room)

	var sofa_approach := Transform3D(Basis.IDENTITY, Vector3(1.8, spawn.y, -1.2))
	var hit := KinematicCollision3D.new()
	var sofa := apartment.get_node("Map/LivingRoom/Sofa") as RigidBody3D
	sofa.collision_layer = 2
	_check(
		player.test_move(sofa_approach, Vector3.LEFT, hit)
		and hit.get_collider() == sofa,
		"The living room sofa has collision against the player"
	)
	sofa.collision_layer = 0

	var living_room := Vector3(6.4, spawn.y, -2.2)
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
		# Start at right angles to check that the old heading does not steer movement.
		var direction: Vector3 = movement_case.direction
		player.rotation.y = atan2(direction.x, direction.z) + PI / 2.0
		for key: Key in movement_case.keys:
			_set_key(key, true)
		await _wait_for_physics(24)
		for key: Key in movement_case.keys:
			_set_key(key, false)
		var displacement := player.global_position - living_room
		_check(displacement.distance_to(direction * player.MOVE_SPEED * 24.0 / 60.0) < 0.15, "Keys %s move steadily in the requested direction at a consistent speed" % [movement_case.keys])
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
		{"start": Vector3(6.4, spawn.y, -3.7), "key": KEY_W, "direction": Vector3.FORWARD, "distance": 0.78},
		{"start": Vector3(0.8, spawn.y, -3.5), "key": KEY_A, "direction": Vector3.LEFT, "distance": 0.48},
		{"start": living_room, "key": KEY_S, "direction": Vector3.BACK, "distance": 1.83},
		{"start": Vector3(13.2, spawn.y, -3.5), "key": KEY_D, "direction": Vector3.RIGHT, "distance": 0.48},
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
