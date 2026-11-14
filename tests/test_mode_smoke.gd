extends SceneTree

var failed := false


func _initialize() -> void:
	call_deferred("_run")


func _run() -> void:
	var lobby := preload("res://lan_lobby.tscn").instantiate()
	root.add_child(lobby)
	var button := lobby.get_node("%TestMode") as Button
	await _wait_for_physics(2)
	_check(button.visible and not button.disabled and button.size.y >= 50, "The main menu has an accessible Test Mode button")
	button.pressed.emit()
	await _wait_for_physics(15)
	var apartment := lobby.get_node("Apartment") as Node3D
	var mode := apartment.get_node("TestMode")
	var player := apartment.get_node("Player") as CharacterBody3D
	var target: CharacterBody3D = mode.target
	_check(lobby._peer == null and not lobby._discovery.is_bound() and lobby.multiplayer.get_peers().is_empty(), "Test Mode opens without hosting, discovery, or another peer")
	_check(not lobby.get_node("Menu").visible and apartment.guest_peer_id == 0, "Test Mode opens the offline apartment directly")
	_check(target.is_on_floor() and not target.reads_local_input and player.is_on_floor(), "The player and the blue test target stand on the floor")
	_check(get_nodes_in_group(&"pickups").size() == 21, "All spheres and apartment props remain available")
	var start := player.global_position
	_set_key(KEY_W, true)
	await _wait_for_physics(18)
	_set_key(KEY_W, false)
	_check(player.global_position.z < start.z - 1.0 and target.global_position.z < 1.0, "WASD moves only the controllable player")
	await _tap(KEY_E)
	_check(player.held_pickup != null, "Nearby test spheres can be picked up with E")
	_set_key(KEY_T, true)
	await _wait_for_physics(30)
	_check(player.get_node("ThrowTrajectory").visible and apartment.get_node("HUD/ThrowPower").visible, "Holding T shows the trajectory and speed gauge offline")
	_set_key(KEY_T, false)
	await _expect(func() -> bool: return mode.hit_count > 0, "A real throw can hit the test target")
	_check(target.is_stunned() and apartment.get_node("HUD/TestStatus").text.contains("1회"), "The target's hit count and movement lock are visible")
	await _wait_for_physics(35)
	_check(not target.is_stunned() and target.get_node("Torso").material_overlay == null, "The target recovers and returns to blue")

	var before_hit := player.global_position
	_set_key(KEY_D, true)
	await _tap(KEY_F)
	await _wait_for_physics(18)
	_check(player.is_stunned() and player.global_position.distance_to(before_hit) < 0.01, "F tests the player's movement lock while a movement key is held")
	await _wait_for_physics(20)
	_set_key(KEY_D, false)
	_check(not player.is_stunned() and player.global_position.x > before_hit.x + 0.1, "Movement resumes after the self-hit test")
	player.hold_pickup(apartment.get_node("Pickup1"))
	var old_apartment := apartment
	await _tap(KEY_R)
	apartment = lobby.get_node("Apartment") as Node3D
	mode = apartment.get_node("TestMode")
	player = apartment.get_node("Player") as CharacterBody3D
	_check(apartment != old_apartment and not is_instance_valid(old_apartment), "R replaces the test stage safely")
	_check(mode.hit_count == 0 and player.held_pickup == null and not player.is_stunned(), "Reset clears hit counts, held objects, and player state")
	_check(get_nodes_in_group(&"pickups").size() == 21 and get_nodes_in_group(&"apartment_props").size() == 18, "Reset restores every prop without duplicates")
	await _tap(KEY_ESCAPE)
	_check(lobby.get_node_or_null("Apartment") == null and button.visible and lobby.get_node("Menu").visible, "Esc returns to the main menu")
	_check(get_nodes_in_group(&"pickups").is_empty() and lobby._peer == null, "Leaving removes the test world and keeps networking closed")
	button.pressed.emit()
	await _wait_for_physics(2)
	_check(lobby.get_node_or_null("Apartment/TestMode") != null, "Test Mode can be entered again")
	await _tap(KEY_ESCAPE)
	_check(lobby.get_node("%Host").visible and lobby.get_node("%Join").visible, "Host and Join remain available after offline testing")
	if not failed:
		print("Offline test mode smoke test passed.")
	quit(int(failed))


func _expect(condition: Callable, message: String) -> void:
	for _frame in 90:
		if condition.call():
			return
		await physics_frame
	_check(false, message)


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
	event.keycode = key
	event.physical_keycode = key
	event.pressed = pressed
	Input.parse_input_event(event)
	Input.flush_buffered_events()


func _wait_for_physics(frames: int) -> void:
	for _frame in frames:
		await physics_frame
