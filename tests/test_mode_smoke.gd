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
	var wife_bag := hud.get_node("WifeBag/Items") as GridContainer
	var husband_bag := hud.get_node("HusbandBag/Items") as GridContainer
	var gold := hud.get_node("WifeProfile/WifeWallet/Gold") as Label
	var logs := hud.get_node("AcquisitionLogs") as VBoxContainer
	_check(wife_bag.columns == 2 and wife_bag.get_child_count() == 0 and gold.text == "000000" and logs.get_child_count() == 0,
		"Test Mode starts with an empty two-column bag, zero gold, and no acquisition log")
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
	_mouse(MOUSE_BUTTON_LEFT, true)
	await _wait_for_physics(30)
	var grab := hud.get_node("GrabProgress") as ProgressBar
	_check(player.held_pickup == null and grab.visible and absf(grab.value - 0.5) < 0.08, "The one-second grab shows progress and waits for the full hold")
	await _wait_for_physics(34)
	_mouse(MOUSE_BUTTON_LEFT, false)
	_check(player.held_pickup != null and not grab.visible, "Holding left click acquires the nearby sphere")
	_mouse(MOUSE_BUTTON_LEFT, true)
	await _wait_for_physics(30)
	_check(player.get_node("ThrowTrajectory").visible and apartment.get_node("HUD/ThrowPower").visible, "A second left hold shows the trajectory and speed gauge")
	_mouse(MOUSE_BUTTON_LEFT, false)
	await _expect(func() -> bool: return target.is_stunned(), "A real throw can hit and stun the test target")
	await _wait_for_physics(35)
	_check(not target.is_stunned() and target.get_node("Torso").material_overlay == null, "The target recovers and returns to blue")
	var thrown_item: RigidBody3D = apartment.get_node("Pickup3")

	var before_hit := player.global_position
	_set_key(KEY_D, true)
	await _tap(KEY_F)
	await _wait_for_physics(18)
	_check(player.is_stunned() and player.global_position.distance_to(before_hit) < 0.01, "F tests the player's movement lock while a movement key is held")
	await _wait_for_physics(20)
	_set_key(KEY_D, false)
	_check(not player.is_stunned() and player.global_position.x > before_hit.x + 0.1, "Movement resumes after the self-hit test")
	await _expect(func() -> bool: return clock.text.begins_with("00:"), "The display counts down during practice")
	var bagged := apartment.get_node("Pickup1") as RigidBody3D
	var item_index: int = apartment._pickups.find(bagged)
	player.hold_pickup(bagged)
	_mouse(MOUSE_BUTTON_LEFT, true)
	await _wait_for_physics(3)
	_mouse(MOUSE_BUTTON_RIGHT, true)
	_mouse(MOUSE_BUTTON_RIGHT, false)
	_mouse(MOUSE_BUTTON_LEFT, false)
	_check(player.held_pickup == null and not bagged.visible and not bagged.is_in_group(&"pickups")
		and bagged.freeze and bagged.collision_layer == 0 and not player.get_node("ThrowTrajectory").visible,
		"A right click during aim bags the item and removes it from physics and selection")
	_check(wife_bag.get_child_count() == 1 and wife_bag.get_child(0).texture.resource_path.ends_with("Item_Ring.png")
		and husband_bag.get_child_count() == 0 and logs.get_child_count() == 1,
		"Bagging adds the ring icon and acquisition log only once")
	apartment._apply_bag_item(0, item_index)
	_check(wife_bag.get_child_count() == 1, "Duplicate deposit events cannot award the item twice")
	for value in range(1, 11):
		await _expect(func() -> bool: return int(gold.text) >= value, "Gold reaches the next integer")
		_check(int(gold.text) == value, "Gold rises by one at a time")
	for item: RigidBody3D in [apartment.get_node("Pickup2"), thrown_item]:
		player.hold_pickup(item)
		_mouse(MOUSE_BUTTON_RIGHT, true)
		_mouse(MOUSE_BUTTON_RIGHT, false)
	await process_frame
	await process_frame
	var first_icon := wife_bag.get_child(0) as TextureRect
	var second_icon := wife_bag.get_child(1) as TextureRect
	var third_icon := wife_bag.get_child(2) as TextureRect
	_check(second_icon.position.y == first_icon.position.y and third_icon.position.y > first_icon.position.y
		and third_icon.position.x == first_icon.position.x, "The third icon wraps into a second row")
	_check(logs.get_child_count() == 2, "The acquisition log shows the two latest deposits")
	await _expect(func() -> bool: return int(gold.text) == 30, "Rapid deposits add ten gold per item")
	var old_apartment := apartment
	await _tap(KEY_R)
	apartment = lobby.get_node("Apartment") as Node3D
	mode = apartment.get_node("TestMode")
	player = apartment.get_node("Player") as CharacterBody3D
	_check(apartment != old_apartment and not is_instance_valid(old_apartment), "R replaces the test stage safely")
	_check(apartment.get_node("HUD/TimeLeft").text == "01:00", "R resets the countdown to one minute")
	_check(apartment.get_node("HUD/WifeBag/Items").get_child_count() == 0
		and apartment.get_node("HUD/WifeProfile/WifeWallet/Gold").text == "000000", "A new test round resets bags and gold")
	_check(player.held_pickup == null and not player.is_stunned(), "Reset clears held objects and player state")
	_check(get_nodes_in_group(&"pickups").size() == 21 and get_nodes_in_group(&"apartment_props").size() == 18, "Reset restores every prop without duplicates")
	timer = apartment.get_node("RoundTimer") as Timer
	clock = apartment.get_node("HUD/TimeLeft") as Label
	await _tap(KEY_G)
	_check(apartment._contest.active and player.contest_active and mode.target.held_pickup == null, "G starts an offline contest against the test target")
	var paused_time := timer.time_left
	var paused_display := clock.text
	await _wait_for_physics(15)
	_check(timer.paused and is_equal_approx(timer.time_left, paused_time) and clock.text == paused_display, "The countdown and its display stay frozen during a contest")
	var contested := apartment.get_node("Pickup3") as RigidBody3D
	for _press in 45:
		if not apartment._contest.active:
			break
		_mouse(MOUSE_BUTTON_LEFT, true)
		await _wait_for_physics(3)
		_mouse(MOUSE_BUTTON_LEFT, false)
		await _wait_for_physics(2)
	_check(not apartment._contest.active and player.held_pickup == contested and mode.target.is_stunned(), "Left click mashing can beat the offline opponent and take the object")
	_check(not timer.paused and timer.time_left > paused_time - 0.2, "The result resumes the saved countdown without subtracting contest time")
	await _wait_for_physics(15)
	_check(timer.time_left < paused_time - 0.2, "The countdown continues after the contest")
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


func _mouse(button: MouseButton, pressed: bool) -> void:
	var event := InputEventMouseButton.new()
	event.button_index = button
	event.pressed = pressed
	Input.parse_input_event(event)
	Input.flush_buffered_events()


func _wait_for_physics(frames: int) -> void:
	for _frame in frames:
		await physics_frame
