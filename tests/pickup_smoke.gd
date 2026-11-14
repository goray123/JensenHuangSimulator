extends SceneTree

var failed := false


func _initialize() -> void:
	call_deferred("_run")


func _run() -> void:
	var courtyard := preload("res://tests/courtyard_fixture.tscn").instantiate()
	root.add_child(courtyard)
	var player := courtyard.get_node("Player") as CharacterBody3D
	var hand := player.get_node("HandSocket") as Marker3D
	var trajectory := player.get_node("ThrowTrajectory") as MeshInstance3D
	var power := courtyard.get_node("HUD/ThrowPower") as ProgressBar
	var holding_changes: Array[bool] = []
	player.held_pickup_changed.connect(func(is_holding: bool) -> void: holding_changes.append(is_holding))
	var total_bodies := courtyard.find_children("*", "RigidBody3D", true, false).size()
	await _wait_for_physics(15)
	var ground_y := player.global_position.y
	var total_pickups := get_nodes_in_group(&"pickups").size()
	_check(total_pickups == 43, "The three spheres, 18 props and 22 furniture pieces remain pickup targets")
	var pickups: Array[Node] = [courtyard.get_node("Pickup1"), courtyard.get_node("Pickup2"), courtyard.get_node("Pickup3")]
	# The prop smoke test covers furniture selection separately.
	for prop in get_nodes_in_group(&"apartment_props") + get_nodes_in_group(&"furniture_pickups"):
		prop.remove_from_group(&"pickups")
	for pickup: RigidBody3D in pickups:
		var sphere := (pickup.get_node("Sphere") as MeshInstance3D).mesh as SphereMesh
		_check(is_equal_approx(sphere.radius, 0.23 / 3.0), "The original pickup radius is preserved with the new character")
		_check(is_equal_approx(sphere.height, sphere.radius * 2.0), "Pickup is a sphere")
		_check(absf(pickup.global_position.y - ground_y - sphere.radius) < 0.002, "Pickup rests above the floor")

	await _hold_left(3)
	_check(not trajectory.visible, "Empty hands do not show a throw preview")
	_check(get_nodes_in_group(&"pickups").size() == 3 and player.held_pickup == null, "Empty throws and distant pickup attempts leave all spheres in place")
	var first := pickups[0] as RigidBody3D
	player.global_position = Vector3(first.global_position.x, ground_y, first.global_position.z + 0.8)
	_set_key(KEY_W, true)
	await _wait_for_physics(3)
	_set_key(KEY_W, false)
	await _wait_for_physics(2)
	_check(get_nodes_in_group(&"pickups").size() == 3, "Walking near a pickup does not collect it automatically")
	await _hold_left(54)
	_check(player.held_pickup == null and not courtyard.get_node("HUD/GrabProgress").visible, "Releasing before one second cancels the grab")
	_mouse(true)
	await _wait_for_physics(30)
	player.notification(Node.NOTIFICATION_APPLICATION_FOCUS_OUT)
	await _wait_for_physics(35)
	_mouse(false)
	_check(player.held_pickup == null, "Losing focus cancels the grab even while the button is still down")
	_mouse(true)
	await _wait_for_physics(30)
	player.global_position.x += 2.0
	await _wait_for_physics(3)
	player.global_position = first.global_position + Vector3(0, ground_y - first.global_position.y, 0.8)
	await _wait_for_physics(35)
	_mouse(false)
	_check(player.held_pickup == null, "Leaving reach cancels the grab until the next press")
	await _hold_left(64)
	_check(player.held_pickup == first and first.get_parent() == hand, "Holding left click attaches the nearby sphere without throwing it on release")
	_check(first.freeze and first.global_position.distance_to(hand.global_position) < 0.001, "The held sphere stays fixed at the hand")
	_set_key(KEY_D, true)
	await _wait_for_physics(36)
	_set_key(KEY_D, false)
	await _wait_for_physics(2)
	_check(first.global_position.distance_to(hand.global_position) < 0.001, "The held sphere follows movement and turning")

	# A full hand must not delete another nearby sphere.
	var second := pickups[1] as RigidBody3D
	var third := pickups[2] as RigidBody3D
	second.global_position = player.global_position + Vector3(0, 0.08, 0.5)
	_mouse(true)
	await _wait_for_physics(3)
	_check(player.held_pickup == first and get_nodes_in_group(&"pickups").size() == 2, "Pressing left click with full hands aims without grabbing another sphere")
	player.notification(Node.NOTIFICATION_APPLICATION_FOCUS_OUT)
	_mouse(false)
	_check(holding_changes == [true], "Failed pickup attempts do not emit extra holding changes")
	var pickup_y := ground_y + 0.07666667
	second.global_position = Vector3(5.2, pickup_y, -3.5)
	third.global_position = Vector3(7.3, pickup_y, -1.5)

	# Leave room for the flight check before the first collision.
	player.global_position = Vector3(6.4, ground_y, -0.55)
	_mouse(true)
	await _wait_for_physics(3)
	_check(player.held_pickup == first and first.freeze, "Pressing left click keeps the sphere in hand")
	_check(trajectory.visible and trajectory.points.size() > 2 and trajectory.mesh.get_surface_count() == 1, "Holding left click draws the predicted path")
	var previous_endpoint: Vector3 = trajectory.points[-1]
	_set_key(KEY_T, true)
	_set_key(KEY_T, false)
	await _wait_for_physics(8)
	_check(player.held_pickup == first and trajectory.visible, "The old T key does not interrupt a mouse charge")
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
	_mouse(false)
	_check(player.held_pickup == null and first.get_parent() == courtyard and not first.freeze, "Releasing left click launches the sphere with physics enabled")
	_check(absf(first.linear_velocity.length() - release_speed) < 0.002, "Launch speed matches the aiming gauge at release")
	var horizontal_velocity := first.linear_velocity * Vector3(1, 0, 1)
	_check(horizontal_velocity.normalized().dot(heading) > 0.99, "Variable-speed throws still follow the current heading")
	_check(not trajectory.visible and trajectory.points.is_empty(), "Releasing left click clears the predicted path")
	_check(holding_changes == [true, false], "Pickup and release each emit a holding change once")
	await _wait_for_physics(4)
	_check((first.global_position - release_position).dot(heading) > 0.15, "The thrown sphere travels forward")
	var path_error := INF
	for point: Vector3 in predicted_points:
		path_error = minf(path_error, first.global_position.distance_to(point))
	_check(path_error < 0.2, "Actual flight follows the preview before impact")
	await _wait_for_physics(120)
	await _wait_settled(first)
	_check(not impacts.is_empty() and impacts[0].distance_to(expected_impact) < 0.35, "The preview ends at the first actual collision")
	_check(absf(first.global_position.y - pickup_y) < 0.07, "The thrown sphere lands on the floor")
	_check(courtyard.find_children("*", "RigidBody3D", true, false).size() == total_bodies, "Throwing and key repeat preserve all objects")
	player.global_position = Vector3(first.global_position.x, ground_y, first.global_position.z + 0.7)
	await _hold_left(64)
	_check(player.held_pickup == first and first.freeze, "A thrown sphere can be picked up again")

	# Test different headings next to each wall, including a diagonal throw.
	var room_bounds := Rect2(0, -7.5, 14, 7.5)
	var throws := [
		{"position": Vector3(7.9, ground_y, -5.9), "yaw": 0.0, "recover": Vector3.BACK},
		{"position": Vector3(12.9, ground_y, -1.25), "yaw": -PI / 2.0, "recover": Vector3.LEFT},
		{"position": Vector3(8.6, ground_y, -1), "yaw": PI, "recover": Vector3.FORWARD},
		{"position": Vector3(1.0, ground_y, -5.9), "yaw": PI / 2.0, "recover": Vector3.RIGHT},
		{"position": Vector3(7.1, ground_y, -2), "yaw": PI / 4.0, "recover": Vector3.BACK},
	]
	for throw_case in throws:
		player.global_position = throw_case.position
		player.rotation.y = throw_case.yaw
		heading = -player.global_transform.basis.z
		_mouse(true)
		await _wait_for_physics(60)
		_check(trajectory.visible and player.held_pickup == first, "The path remains visible near walls while aiming")
		var aimed_speed := power.value
		_mouse(false)
		# Read the launch velocity before physics advances or a nearby wall is hit.
		horizontal_velocity = first.linear_velocity * Vector3(1, 0, 1)
		_check(absf(first.linear_velocity.length() - aimed_speed) < 0.002 and horizontal_velocity.normalized().dot(heading) > 0.99, "Throw at %s uses the current heading and speed" % throw_case.position)
		await _wait_for_physics(120)
		await _wait_settled(first)
		_check(room_bounds.has_point(Vector2(first.global_position.x, first.global_position.z)), "Walls keep thrown spheres inside the apartment")
		_check(first.global_position.y >= ground_y and first.global_position.y < 2.0, "Sphere thrown at %s lands on the floor or furniture" % throw_case.position)
		player.global_position = _free_spot_near(player, first.global_position, ground_y, throw_case.recover, room_bounds)
		# Let the teleport settle on the floor before pressing, as a walking player would be.
		await _wait_for_physics(2)
		await _hold_left(64)
		_check(player.held_pickup == first, "Spheres remain reusable after wall collisions")

	# With empty hands, choose only the nearest of two eligible spheres.
	player.release_pickup(false)
	first.remove_from_group(&"pickups")
	player.global_position = Vector3(6.4, ground_y, -2.2)
	second.global_position = Vector3(6.9, pickup_y, -2.2)
	third.global_position = Vector3(7.4, pickup_y, -2.2)
	await _hold_left(64)
	_check(player.held_pickup == second and third.is_in_group(&"pickups"), "Empty hands pick only the nearest eligible sphere")
	_check(courtyard.find_children("*", "RigidBody3D", true, false).size() == total_bodies, "Repeated pickup and throw cycles never duplicate or delete objects")

	_mouse(true)
	await _wait_for_physics(2)
	player.notification(Node.NOTIFICATION_APPLICATION_FOCUS_OUT)
	_mouse(false)
	_check(player.held_pickup == second and not trajectory.visible, "Losing focus cancels aiming without throwing on release")
	player.release_pickup(false)
	second.remove_from_group(&"pickups")
	# Left click while empty must not throw the sphere grabbed during the same hold.
	player.global_position = Vector3(third.global_position.x, ground_y, third.global_position.z)
	await _hold_left(64)
	_check(player.held_pickup == third and not trajectory.visible, "A grab release leaves the newly acquired sphere in hand")
	if not failed:
		print("Pickup smoke test passed.")
	quit(int(failed))


func _check(condition: bool, message: String) -> void:
	if not condition:
		failed = true
		push_error(message)


# Where a sphere lands after wall bounces depends on each character's release hand, so it can
# rest on furniture; teleporting the player into that furniture would fling it, not test pickup.
func _free_spot_near(player: CharacterBody3D, target: Vector3, ground_y: float, preferred: Vector3, room: Rect2) -> Vector3:
	var body_shape := player.get_node("CollisionShape3D") as CollisionShape3D
	var query := PhysicsShapeQueryParameters3D.new()
	query.shape = body_shape.shape
	query.collision_mask = player.collision_mask
	query.exclude = [player.get_rid()]
	var directions: Array[Vector3] = [preferred]
	for step in 8:
		directions.append(Vector3.FORWARD.rotated(Vector3.UP, step * PI / 4.0))
	for distance: float in [0.6, 0.8, 1.0]:
		for direction in directions:
			var spot: Vector3 = Vector3(target.x, ground_y, target.z) + direction.normalized() * distance
			query.transform = Transform3D(Basis.IDENTITY, spot + body_shape.position + Vector3.UP * 0.03)
			var on_floor := room.grow(-0.35).has_point(Vector2(spot.x, spot.z))
			if on_floor and player.get_world_3d().direct_space_state.intersect_shape(query, 1).is_empty():
				return spot
	return Vector3(target.x, ground_y, target.z) + preferred * 0.6


func _hold_left(frames: int) -> void:
	_mouse(true)
	await _wait_for_physics(frames)
	_mouse(false)
	await _wait_for_physics(2)


func _mouse(pressed: bool) -> void:
	var event := InputEventMouseButton.new()
	event.button_index = MOUSE_BUTTON_LEFT
	event.pressed = pressed
	Input.parse_input_event(event)
	Input.flush_buffered_events()


func _set_key(key: Key, pressed: bool) -> void:
	var event := InputEventKey.new()
	event.physical_keycode = key
	event.pressed = pressed
	Input.parse_input_event(event)
	Input.flush_buffered_events()


func _wait_for_physics(frames: int) -> void:
	for _frame in frames:
		await physics_frame


# A release from the real throwing hand can keep a sphere bouncing past a fixed wait;
# recovery starts only after ten slow frames, and a sphere that never settles fails.
func _wait_settled(body: RigidBody3D) -> void:
	var stable := 0
	for _frame in 600:
		await physics_frame
		stable = stable + 1 if body.linear_velocity.length() < 0.10 else 0
		if stable >= 10:
			return
	_check(false, "Released sphere settles within ten seconds before recovery")
