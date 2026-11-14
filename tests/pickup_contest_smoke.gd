extends SceneTree

var failed := false


func _initialize() -> void:
	call_deferred("_run")


func _run() -> void:
	var apartment := preload("res://courtyard.tscn").instantiate()
	root.add_child(apartment)
	var player := apartment.get_node("Player") as CharacterBody3D
	var opponent := preload("res://player.tscn").instantiate() as CharacterBody3D
	opponent.name = "ContestOpponent"
	opponent.reads_local_input = false
	apartment.add_child(opponent)
	player.add_collision_exception_with(opponent)
	opponent.add_collision_exception_with(player)
	var contest: Node = apartment._contest
	contest.register_opponent(opponent)
	await _wait_for_physics(15)
	var ground_y := player.global_position.y
	var camera := apartment.get_node("Overview") as Camera3D
	var original_camera := camera.transform
	var original_size := camera.size
	var sphere := apartment.get_node("Pickup1") as RigidBody3D
	var loose := apartment.get_node("Pickup2") as RigidBody3D
	var tv := apartment.get_node("Furnishings/LivingRoom/Television") as RigidBody3D
	# Remove unrelated candidates so these checks exercise the intended interaction.
	for pickup in get_nodes_in_group(&"pickups"):
		if pickup != sphere:
			pickup.remove_from_group(&"pickups")
	player.global_position = Vector3(5.5, ground_y, -1.6)
	opponent.global_position = Vector3(7.5, ground_y, -1.6)
	sphere.global_position = Vector3(6.5, ground_y + 0.12, -1.6)
	_mouse(true)
	await _wait_for_physics(30)
	_check(player.held_pickup == null and not contest.active, "The first grab is still in progress after half a second")
	contest.request_interaction(opponent, true, sphere)
	await _wait_for_physics(2)
	if not _require(contest.active, "An overlapping grab on the same loose object starts a contest"):
		quit(1)
		return
	var first_round: int = contest.round_id
	var first_item: int = contest.item_index
	_check(is_equal_approx(contest.progress, 0.5), "A new contest begins with an even split")
	_check(contest.presentation.active and contest.presentation.gauge.is_visible_in_tree(), "The contest shows its two-color gauge")
	_check(player.contest_active and opponent.contest_active, "Both participating players enter the contest state")
	_check(not apartment.get_node("HUD/GrabProgress").visible, "Starting a contest clears the pending grab progress")
	_mouse(false)
	var player_start := player.global_position
	var opponent_start := opponent.global_position
	_set_key(KEY_D, true)
	opponent.remote_input = Vector2.LEFT
	await _wait_for_physics(20)
	_set_key(KEY_D, false)
	opponent.remote_input = Vector2.ZERO
	_check(player.global_position.distance_to(player_start) < 0.01 and opponent.global_position.distance_to(opponent_start) < 0.01, "WASD input cannot separate players during their contest")
	_check(player.held_pickup == null and opponent.held_pickup == null and sphere.freeze, "The contested object stays in place until a winner is decided")
	_check(not camera.transform.is_equal_approx(original_camera) or not is_equal_approx(camera.size, original_size), "The camera closes in on the two contestants")
	var before_press: float = contest.progress
	for _repeat in 8:
		_set_key(KEY_E, true, true)
	await _wait_for_physics(2)
	_set_key(KEY_E, false)
	_check(is_equal_approx(contest.progress, before_press), "The old E key no longer scores")
	await _tap_left()
	var after_player_press: float = contest.progress
	_check(after_player_press > before_press, "A left click moves the gauge toward that player's color")
	contest.request_interaction(opponent)
	await _wait_for_physics(1)
	_check(is_equal_approx(contest.progress, before_press), "An opposing click cancels the same amount of advantage")
	await _win_with_player(contest)
	if not _require(not contest.active, "The gauge reaches an endpoint after enough player presses"):
		quit(1)
		return
	_check(player.held_pickup == sphere and opponent.held_pickup == null, "The winner receives the contested object")
	_check(opponent.is_stunned() and not player.is_stunned(), "Only the losing player receives the contest stun")
	_check(not player.contest_active and not opponent.contest_active, "Resolving the contest releases both contest locks")
	contest._handle_interaction(1, first_round, first_item)
	_check(not contest.active and player.held_pickup == sphere, "A delayed tap from a finished round cannot restart or transfer the object")
	opponent.receive_hit()
	opponent.remote_input = Vector2.RIGHT
	var stunned_position := opponent.global_position
	await _wait_for_physics(30)
	_check(camera.transform.is_equal_approx(original_camera) and is_equal_approx(camera.size, original_size), "The original camera transform and zoom return after the result")
	_check(not contest.presentation.active and not contest.presentation.gauge.is_visible_in_tree(), "The contest gauge closes after the result")
	await _wait_for_physics(100)
	_check(opponent.is_stunned() and opponent.global_position.distance_to(stunned_position) < 0.01, "A projectile hit cannot shorten the loser's 2.5-second movement lock")
	await _wait_for_physics(32)
	opponent.remote_input = Vector2.ZERO
	_check(not opponent.is_stunned() and opponent.global_position.x > stunned_position.x + 0.1, "The loser can move again after the full contest stun")

	contest.request_interaction(opponent, true, sphere)
	_check(not contest.active and player.held_pickup == sphere, "A completed pickup can no longer be contested")
	player.release_pickup(false)
	sphere.remove_from_group(&"pickups")
	player.global_position = Vector3(6.5, ground_y, -1.6)
	opponent.global_position = Vector3(6.5, ground_y, -2.5)
	tv.global_position = Vector3(6.5, ground_y + 0.12, -2.0)
	tv.add_to_group(&"pickups")
	loose.global_position = opponent.global_position + Vector3(0.1, 0.12, 0.0)
	loose.add_to_group(&"pickups")
	_mouse(true)
	contest.request_interaction(opponent, true, loose)
	await _wait_for_physics(2)
	_check(not contest.active, "Concurrent grabs of different items can proceed independently")
	contest.request_interaction(opponent, false)
	loose.remove_from_group(&"pickups")
	contest.request_interaction(opponent, true, tv)
	_mouse(false)
	if not _require(contest.active, "The opponent can contest the same TV while the first grab is pending"):
		quit(1)
		return
	_check(contest.round_id > first_round and apartment._pickups[contest.item_index] == tv, "A later round contests the TV")
	var second_start: float = contest.progress
	contest._handle_interaction(0, first_round, first_item)
	_check(is_equal_approx(contest.progress, second_start), "A delayed first-round tap cannot change the second round")
	_mouse(true, MOUSE_BUTTON_RIGHT)
	_mouse(false, MOUSE_BUTTON_RIGHT)
	_check(not player._is_aiming and player.held_pickup == null and apartment._bagged_items.is_empty(), "The contested item cannot be thrown or bagged")
	await _win_with_opponent(contest, opponent)
	if not _require(not contest.active, "Enough opposing presses resolve the contest in the other direction"):
		quit(1)
		return
	_check(opponent.held_pickup == tv and player.held_pickup == null, "The second player takes the TV when they win")
	_check(player.is_stunned() and not opponent.is_stunned(), "The loser receives the same 2.5-second stun")
	_check(not tv.is_in_group(&"pickups") and tv.get_parent() == opponent.get_node("HandSocket"), "The won object belongs to exactly one player's hand")
	await _wait_for_physics(165)
	_check(not player.is_stunned() and camera.transform.is_equal_approx(original_camera), "A second round also restores control and the overview camera")
	opponent.release_pickup(false)
	tv.global_position = (player.global_position + opponent.global_position) * 0.5 + Vector3.UP * 0.2
	_mouse(true)
	contest.request_interaction(opponent, true, tv)
	_mouse(false)
	await _wait_for_physics(2)
	_check(contest.active, "Another contest can start after both players recover")
	var timer := apartment.get_node("RoundTimer") as Timer
	_check(timer.paused, "A repeated contest pauses the countdown again")
	var remaining := timer.time_left
	contest.cancel_round()
	await _wait_for_physics(5)
	_check(not timer.paused and timer.time_left < remaining, "Cancelling a contest resumes the countdown")
	_mouse(true)
	contest.request_interaction(opponent, true, tv)
	_mouse(false)
	_check(contest.active and timer.paused, "A contest can pause the countdown again after cancellation")
	apartment.queue_free()
	await _wait_for_physics(3)
	_check(not is_instance_valid(apartment), "Leaving while a contest is active safely removes its camera and UI")
	if not failed:
		print("Pickup contest smoke test passed.")
	quit(int(failed))


func _win_with_player(contest: Node) -> void:
	for _press in 40:
		if not contest.active:
			return
		await _tap_left()


func _win_with_opponent(contest: Node, opponent: CharacterBody3D) -> void:
	for _press in 40:
		if not contest.active:
			return
		contest.request_interaction(opponent)
		await _wait_for_physics(2)


func _require(condition: bool, message: String) -> bool:
	_check(condition, message)
	return condition


func _check(condition: bool, message: String) -> void:
	if not condition:
		failed = true
		push_error(message)


func _tap_left() -> void:
	_mouse(true)
	await _wait_for_physics(2)
	_mouse(false)
	await _wait_for_physics(1)


func _mouse(pressed: bool, button := MOUSE_BUTTON_LEFT) -> void:
	var event := InputEventMouseButton.new()
	event.button_index = button
	event.pressed = pressed
	Input.parse_input_event(event)
	Input.flush_buffered_events()


func _set_key(key: Key, pressed: bool, echo := false) -> void:
	var event := InputEventKey.new()
	event.keycode = key
	event.physical_keycode = key
	event.pressed = pressed
	event.echo = echo
	Input.parse_input_event(event)
	Input.flush_buffered_events()


func _wait_for_physics(frames: int) -> void:
	for _frame in frames:
		await physics_frame
