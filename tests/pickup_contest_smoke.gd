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
	await _tap(KEY_E)
	_check(player.held_pickup == sphere and not contest.active, "A normal E press still picks up an unclaimed nearby object")
	_set_key(KEY_T, true)
	await _wait_for_physics(3)
	_check(player._is_aiming, "The current holder can aim before an object is contested")
	# The guest may have seen the item leave the floor before sending E, while
	# still standing within reach of its original position on the opposite side.
	contest._handle_interaction(1, 0, -1)
	await _wait_for_physics(2)
	if not _require(contest.active, "Near-simultaneous E presses contest the old object position even when players stand 2 m apart"):
		quit(1)
		return
	var first_round: int = contest.round_id
	var first_item: int = contest.item_index
	_check(is_equal_approx(contest.progress, 0.5), "A new contest begins with an even split")
	_check(contest.presentation.active and contest.presentation.gauge.is_visible_in_tree(), "The contest shows its two-color gauge")
	_check(player.contest_active and opponent.contest_active, "Both participating players enter the contest state")
	_check(not player._is_aiming and not player.get_node("ThrowTrajectory").visible, "Starting a contest cancels an existing throw preview")
	_set_key(KEY_T, false)
	var player_start := player.global_position
	var opponent_start := opponent.global_position
	_set_key(KEY_D, true)
	opponent.remote_input = Vector2.LEFT
	await _wait_for_physics(20)
	_set_key(KEY_D, false)
	opponent.remote_input = Vector2.ZERO
	_check(player.global_position.distance_to(player_start) < 0.01 and opponent.global_position.distance_to(opponent_start) < 0.01, "WASD input cannot separate players during their contest")
	_check(player.held_pickup == sphere and not sphere.is_in_group(&"pickups"), "Releasing T during a contest cannot launch the contested object")
	_check(not camera.transform.is_equal_approx(original_camera) or not is_equal_approx(camera.size, original_size), "The camera closes in on the two contestants")
	var before_echo: float = contest.progress
	for _repeat in 8:
		_set_key(KEY_E, true, true)
	await _wait_for_physics(2)
	_set_key(KEY_E, false)
	_check(is_equal_approx(contest.progress, before_echo), "Keyboard auto-repeat does not count as repeated presses")
	await _tap(KEY_E)
	var after_player_press: float = contest.progress
	_check(not is_equal_approx(after_player_press, before_echo), "A genuine E press moves the gauge toward that player's color")
	contest.request_interaction(opponent)
	await _wait_for_physics(1)
	_check(is_equal_approx(contest.progress, before_echo), "An opposing E press cancels the same amount of advantage")
	await _win_with_player(contest)
	if not _require(not contest.active, "The gauge reaches an endpoint after enough player presses"):
		quit(1)
		return
	_check(player.held_pickup == sphere and opponent.held_pickup == null, "The original holder keeps the object when they win")
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

	# A nearby held item has priority over an even closer loose object.
	player.release_pickup(false)
	sphere.remove_from_group(&"pickups")
	player.hold_pickup(tv)
	player.global_position = Vector3(6.5, ground_y, -1.6)
	opponent.global_position = Vector3(6.5, ground_y, -2.5)
	loose.global_position = opponent.global_position + Vector3(0.1, 0.12, 0.0)
	loose.add_to_group(&"pickups")
	contest.request_interaction(opponent)
	await _wait_for_physics(2)
	if not _require(contest.active, "E beside an opponent holding an object starts a stealing contest"):
		quit(1)
		return
	_check(contest.round_id > first_round and apartment._pickups[contest.item_index] == tv, "A later round contests the held TV rather than the nearer loose sphere")
	var second_start: float = contest.progress
	contest._handle_interaction(0, first_round, first_item)
	_check(is_equal_approx(contest.progress, second_start), "A delayed first-round tap cannot change the second round")
	_set_key(KEY_T, true)
	await _wait_for_physics(2)
	_set_key(KEY_T, false)
	_check(not player._is_aiming and player.held_pickup == tv, "T cannot start an aim or throw while the holder is in a contest")
	await _win_with_opponent(contest, opponent)
	if not _require(not contest.active, "Enough opposing presses resolve the contest in the other direction"):
		quit(1)
		return
	_check(opponent.held_pickup == tv and player.held_pickup == null, "The challenger steals the TV when they win")
	_check(player.is_stunned() and not opponent.is_stunned(), "A losing original holder receives the same 2.5-second stun")
	_check(not tv.is_in_group(&"pickups") and tv.get_parent() == opponent.get_node("RightArm/HandSocket"), "The won object belongs to exactly one player's hand")
	await _wait_for_physics(165)
	_check(not player.is_stunned() and camera.transform.is_equal_approx(original_camera), "A second round also restores control and the overview camera")
	player.global_position = opponent.global_position + Vector3(0.0, 0.0, 0.9)
	contest.request_interaction(player)
	await _wait_for_physics(2)
	_check(contest.active, "Another contest can start after both players recover")
	var timer := apartment.get_node("RoundTimer") as Timer
	_check(timer.paused, "A repeated contest pauses the countdown again")
	var remaining := timer.time_left
	contest.cancel_round()
	await _wait_for_physics(5)
	_check(not timer.paused and timer.time_left < remaining, "Cancelling a contest resumes the countdown")
	contest.request_interaction(player)
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
		await _tap(KEY_E)


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


func _tap(key: Key) -> void:
	_set_key(key, true)
	await _wait_for_physics(2)
	_set_key(key, false)
	await _wait_for_physics(1)


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
