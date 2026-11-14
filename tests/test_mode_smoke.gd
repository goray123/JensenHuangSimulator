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
	var apartment := lobby.get_node("Apartment") as Node3D
	var timer := apartment.get_node("RoundTimer") as Timer
	var clock := apartment.get_node("HUD/TimeLeft") as Label
	_check(timer.wait_time == 60.0 and not timer.is_stopped() and clock.visible and clock.text == "01:00", "Test Mode starts with a visible one-minute countdown")
	await _wait_for_physics(15)
	var hud := apartment.get_node("HUD")
	_check(hud.find_children("*", "Label", false, false) == [clock] and not hud.has_node("LogBackground"),
		"The regular game HUD has only the timer as text and no bottom log")
	var mode := apartment.get_node("TestMode")
	var player := apartment.get_node("Player") as CharacterBody3D
	var target: CharacterBody3D = mode.target
	_check(lobby._peer == null and not lobby._discovery.is_bound() and lobby.multiplayer.get_peers().is_empty(), "Test Mode opens without hosting, discovery, or another peer")
	_check(not lobby.get_node("Menu").visible and apartment.guest_peer_id == 0, "Test Mode opens the offline apartment directly")
	_check(target.is_on_floor() and not target.reads_local_input and player.is_on_floor(), "The player and the blue test target stand on the floor")
	_check(get_nodes_in_group(&"pickups").size() == 21, "All spheres and apartment props remain available")
	var start := player.global_position
	var target_start := target.global_position
	var pointer := player.get_node("Head/PlayerPosPointer") as Sprite3D
	var pointer_start := pointer.global_position
	_set_key(KEY_W, true)
	await _wait_for_physics(18)
	_set_key(KEY_W, false)
	_check(player.global_position.z < start.z - 1.0 and target.global_position.distance_to(target_start) < 0.02, "WASD moves only the controllable player")
	_check(pointer.visible and not target.get_node("Head/PlayerPosPointer").visible and pointer_start.y > start.y + 1.85
		and (pointer.global_position - pointer_start).is_equal_approx(player.global_position - start),
		"Only the controllable player has a pointer, and it follows their movement above their head")
	await _tap(KEY_E)
	_check(player.held_pickup != null, "Nearby test spheres can be picked up with E")
	_set_key(KEY_T, true)
	await _wait_for_physics(30)
	_check(player.get_node("ThrowTrajectory").visible and apartment.get_node("HUD/ThrowPower").visible, "Holding T shows the trajectory and speed gauge offline")
	_set_key(KEY_T, false)
	await _expect(func() -> bool: return target.is_stunned(), "A real throw can hit and stun the test target")
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
	await _expect(func() -> bool: return clock.text.begins_with("00:"), "The display counts down during practice")
	player.hold_pickup(apartment.get_node("Pickup1"))
	var old_apartment := apartment
	await _tap(KEY_R)
	apartment = lobby.get_node("Apartment") as Node3D
	mode = apartment.get_node("TestMode")
	player = apartment.get_node("Player") as CharacterBody3D
	_check(apartment != old_apartment and not is_instance_valid(old_apartment), "R replaces the test stage safely")
	_check(apartment.get_node("HUD/TimeLeft").text == "01:00", "R resets the countdown to one minute")
	_check(player.held_pickup == null and not player.is_stunned(), "Reset clears held objects and player state")
	_check(get_nodes_in_group(&"pickups").size() == 21 and get_nodes_in_group(&"apartment_props").size() == 18, "Reset restores every prop without duplicates")
	await _tap(KEY_G)
	_check(apartment._contest.active and player.contest_active and mode.target.held_pickup != null, "G starts an offline contest against the test target")
	var contested: RigidBody3D = mode.target.held_pickup
	for _press in 45:
		if not apartment._contest.active:
			break
		await _tap(KEY_E)
	_check(not apartment._contest.active and player.held_pickup == contested and mode.target.is_stunned(), "E mashing can beat the offline opponent and take its object")
	await _tap(KEY_R)
	apartment = lobby.get_node("Apartment") as Node3D
	_check(not apartment._contest.active and apartment.get_node("Player").held_pickup == null, "Reset clears the contest and restores the test stage")
	timer = apartment.get_node("RoundTimer") as Timer
	clock = apartment.get_node("HUD/TimeLeft") as Label
	var finish := apartment.get_node("HUD/RoundEnd") as ColorRect
	timer.start(0.2)
	await _expect(func() -> bool: return finish.visible, "Test Mode shows the round-end overlay when time expires")
	_check(clock.text == "00:00" and not apartment.can_process(), "The countdown ends at zero and freezes the test round")
	await _tap(KEY_R)
	var restarted := lobby.get_node("Apartment") as Node3D
	_check(restarted != apartment and restarted.can_process() and restarted.get_node("HUD/TimeLeft").text == "01:00", "R starts another one-minute test round from the timeout screen")
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
