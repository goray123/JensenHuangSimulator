extends SceneTree
# Exercise real keyboard/mouse input, never lesson advancement or fake rewards.

var failed := false


func _initialize() -> void:
	call_deferred("_run")


func _run() -> void:
	create_timer(90.0).timeout.connect(func() -> void:
		push_error("Guided tutorial smoke test timed out.")
		quit(1)
	)
	root.size = Vector2i(1280, 720)
	var lobby: Node = load("res://lan_lobby.tscn").instantiate()
	lobby.play_intro = true
	root.add_child(lobby)
	await _frames(3)
	var entry := lobby.get_node_or_null("%TutorialButton") as Button
	_check(entry != null and entry.is_visible_in_tree(), "The menu offers an interactive tutorial")
	if entry == null:
		quit(1)
		return
	await _click(entry.get_global_rect().get_center())
	if not await _expect(func() -> bool: return lobby.get_node_or_null("Apartment/GuidedTutorial") != null,
		"The tutorial opens a playable lesson without the intro"):
		lobby.free()
		quit(1)
		return
	var apartment: Node3D = lobby.get_node("Apartment")
	var lesson: Node = apartment.get_node("GuidedTutorial")
	var player: CharacterBody3D = lesson._player
	var timer := apartment.get_node("RoundTimer") as Timer
	_check(lobby._state == lobby.State.TUTORIAL and lobby._peer == null
		and not lobby._discovery.is_bound() and lobby.multiplayer.get_peers().is_empty(),
		"The tutorial runs offline without matchmaking")
	_check(lobby.get_node_or_null("Intro") == null and not lobby.get_node("Menu").visible
		and apartment.get_node_or_null("TestMode") == null,
		"Guided play has its own controller and skips the comic")
	_check(lesson.step == lesson.Step.MOVE, "The first lesson teaches movement")
	await _physics(25)
	_check(lesson.step == lesson.Step.MOVE and not apartment._round_finished,
		"Waiting does not complete movement or start an ending")
	_mouse(MOUSE_BUTTON_RIGHT, true)
	_mouse(MOUSE_BUTTON_RIGHT, false)
	_mouse(MOUSE_BUTTON_LEFT, true)
	await _physics(8)
	_mouse(MOUSE_BUTTON_LEFT, false)
	_check(lesson.step == lesson.Step.MOVE, "Unrelated mouse actions cannot skip movement")
	var old_apartment := apartment
	await _tap(KEY_R)
	await _physics(3)
	apartment = lobby.get_node("Apartment")
	lesson = apartment.get_node("GuidedTutorial")
	player = lesson._player
	timer = apartment.get_node("RoundTimer") as Timer
	_check(apartment != old_apartment and not is_instance_valid(old_apartment)
		and lesson.step == lesson.Step.MOVE and apartment.bag_gold() == Vector2i.ZERO,
		"R restarts the whole tutorial and clears score")
	await _walk_to(lesson._move_goal, player, lesson)
	if not await _expect(func() -> bool: return lesson.step == lesson.Step.GRAB,
		"Real WASD movement to the marker unlocks grabbing"):
		lobby.free()
		quit(1)
		return
	var cake: RigidBody3D = lesson._first_item
	_place_near(player, cake)
	await _physics(3)
	_mouse(MOUSE_BUTTON_LEFT, true)
	await _physics(8)
	_check(player.held_pickup == null and lesson.step == lesson.Step.GRAB,
		"A brief press cannot complete a hold pickup")
	_mouse(MOUSE_BUTTON_LEFT, false)
	var retry_button := lesson.hud.find_child("Retry", true, false) as Button
	await _click(retry_button.get_global_rect().get_center())
	await _physics(3)
	_check(lesson.step == lesson.Step.GRAB and player.held_pickup == null and player._grab_elapsed < 0.0,
		"The HUD retry resets this lesson without clicking through into a pickup")
	_place_near(player, cake)
	_mouse(MOUSE_BUTTON_LEFT, true)
	if not await _expect(func() -> bool: return player.held_pickup == cake,
		"Holding left mouse really picks up the cake", 150):
		_mouse(MOUSE_BUTTON_LEFT, false)
		lobby.free()
		quit(1)
		return
	_mouse(MOUSE_BUTTON_LEFT, false)
	await _physics(3)
	_check(lesson.step == lesson.Step.BAG and apartment.bag_gold() == Vector2i.ZERO,
		"A held item gives no score and opens the bag lesson")
	await _physics(20)
	_check(lesson.step == lesson.Step.BAG, "Bagging waits for a real deposit")
	# A learner may throw the cake instead of bagging it. Recover through the
	# public controls rather than manually awarding or restoring the item.
	_mouse(MOUSE_BUTTON_LEFT, true)
	await _physics(4)
	_mouse(MOUSE_BUTTON_LEFT, false)
	_check(player.held_pickup == null, "An accidental cake throw uses the real release action")
	if not await _expect(func() -> bool: return lesson.step == lesson.Step.GRAB,
		"Throwing the cake returns to its pickup lesson instead of trapping the learner", 180):
		lobby.free()
		quit(1)
		return
	_check(apartment.bag_gold() == Vector2i.ZERO and cake.is_in_group(&"pickups"),
		"A recovered cake remains unscored and available to pick up")
	_place_near(player, cake)
	await _physics(3)
	await _grab(player, cake)
	_check(lesson.step == lesson.Step.BAG, "Picking up the recovered cake resumes bagging")
	_mouse(MOUSE_BUTTON_RIGHT, true)
	_mouse(MOUSE_BUTTON_RIGHT, false)
	if not await _expect(func() -> bool: return lesson.step == lesson.Step.AIM,
		"Right mouse deposits the cake before teaching aim"):
		lobby.free()
		quit(1)
		return
	_check(player.held_pickup == null and not cake.visible
		and apartment.bag_gold() == Vector2i(cake.gold_value, 0),
		"Actual bag ownership awards exactly the cake value")
	var tissue: RigidBody3D = lesson._throw_item
	await _physics(12)
	_check(lesson.step == lesson.Step.AIM, "Aim waits for another pickup and a real hold")
	await _physics(3)
	await _grab(player, tissue)
	_check(lesson.step == lesson.Step.AIM, "Picking up the throwing item does not skip aiming")
	_mouse(MOUSE_BUTTON_LEFT, true)
	await _physics(8)
	_mouse(MOUSE_BUTTON_LEFT, false)
	_check(lesson.step == lesson.Step.AIM and player.held_pickup == null,
		"An early aim release throws without skipping the aiming requirement")
	if not await _expect(func() -> bool: return not lesson._aim_ready and tissue.freeze,
		"An early release restores the tissue and allows another aiming attempt", 240):
		lobby.free()
		quit(1)
		return
	await _grab(player, tissue)
	_face_target(player, lesson.target)
	_mouse(MOUSE_BUTTON_LEFT, true)
	await _physics(12)
	_check(lesson.step == lesson.Step.AIM and player.get_node("ThrowTrajectory").visible,
		"The real trajectory appears before a sustained hold completes aiming")
	await _physics(20)
	_check(lesson.step == lesson.Step.THROW and player.held_pickup == tissue
		and player.get_node("ThrowTrajectory").visible,
		"A sustained aim unlocks throwing without launching early")
	# An actual miss must give the learner another attempt rather than advance.
	player.rotation.y += PI
	await _physics(1)
	_mouse(MOUSE_BUTTON_LEFT, false)
	if not await _expect(func() -> bool: return lesson.step == lesson.Step.AIM,
		"A missed shot restores the aiming lesson for another actual attempt", 240):
		lobby.free()
		quit(1)
		return
	_check(not lesson._target_hit and player.held_pickup == null and tissue.is_in_group(&"pickups"),
		"Missing cannot complete the attack lesson or lose its practice item")
	await _physics(3)
	await _grab(player, tissue)
	_face_target(player, lesson.target)
	_mouse(MOUSE_BUTTON_LEFT, true)
	await _physics(32)
	_mouse(MOUSE_BUTTON_LEFT, false)
	_check(player.held_pickup == null, "Releasing the mouse launches the actual item")
	if await _expect(func() -> bool: return lesson._target_hit,
		"The projectile physically hits the teaching target", 120):
		_check(lesson.target.is_stunned(), "The teaching throw uses the real hit and stun")
	if not await _expect(func() -> bool: return lesson.step == lesson.Step.CONTEST,
		"A real hit on the target completes throwing", 180):
		lobby.free()
		quit(1)
		return
	var ring: RigidBody3D = lesson._contest_item
	await _physics(40)
	_check(lesson.step == lesson.Step.CONTEST and not apartment._contest.active,
		"The contest waits for the learner's pickup attempt")
	_place_near(player, ring)
	await _physics(3)
	_mouse(MOUSE_BUTTON_LEFT, true)
	await _physics(3)
	_mouse(MOUSE_BUTTON_LEFT, false)
	if not await _expect(func() -> bool: return apartment._contest.active,
		"Trying to grab the ring starts a real simultaneous-grab contest"):
		lobby.free()
		quit(1)
		return
	_check(player.contest_active and lesson.target.contest_active and timer.paused,
		"A contest locks both players and pauses the round timer")
	for _press in 35:
		if not apartment._contest.active:
			break
		_mouse(MOUSE_BUTTON_LEFT, true)
		await _physics(2)
		_mouse(MOUSE_BUTTON_LEFT, false)
		await _physics(1)
	if not await _expect(func() -> bool: return lesson.step == lesson.Step.SCORE,
		"Real mouse presses beat the opponent and unlock scoring"):
		lobby.free()
		quit(1)
		return
	_check(player.held_pickup == ring and lesson.target.is_stunned()
		and not apartment._contest.active,
		"Winning awards the actual ring and stuns the loser")
	await _physics(30)
	_check(lesson.step == lesson.Step.SCORE and not apartment._round_finished
		and apartment.bag_gold().x == cake.gold_value,
		"The final lesson requires bagging the won ring instead of counting hand contents")
	_mouse(MOUSE_BUTTON_RIGHT, true)
	_mouse(MOUSE_BUTTON_RIGHT, false)
	_check(apartment.bag_gold() == Vector2i(cake.gold_value + ring.gold_value, lesson._opponent_item.gold_value),
		"The final deposit updates authoritative bag totals")
	if await _expect(func() -> bool: return lesson.step == lesson.Step.COMPLETE,
		"The real final countdown and victory animation finish before completion", 720):
		_check(apartment._round_finished and apartment.get_node_or_null("Ending") != null,
			"Completion uses the real 3D ending and winner calculation")
		var replay := lesson.hud.get_node("Overlay/Completion/CompletionCard/Content/Actions/Replay") as Button
		old_apartment = apartment
		await _click(replay.get_global_rect().get_center())
		await _physics(3)
		apartment = lobby.get_node("Apartment")
		lesson = apartment.get_node("GuidedTutorial")
		_check(apartment != old_apartment and not is_instance_valid(old_apartment)
			and lesson.step == lesson.Step.MOVE and not apartment._round_finished
			and apartment.bag_gold() == Vector2i.ZERO,
			"The completion replay button rebuilds a fresh interactive lesson")
	var menu := lesson.hud.find_child("Menu", true, false) as Button
	await _click(menu.get_global_rect().get_center())
	await _physics(3)
	_check(lobby._state == lobby.State.IDLE and lobby.get_node_or_null("Apartment") == null
		and lobby.get_node("Menu").visible and entry.is_visible_in_tree(),
		"The HUD menu button returns to the title and frees the lesson")
	lobby.play_intro = false
	await _tap(KEY_F2)
	_check(lobby._state == lobby.State.TESTING and lobby.get_node_or_null("Apartment/TestMode") != null
		and lobby.get_node_or_null("Apartment/GuidedTutorial") == null,
		"F2 retains the original unrestricted solo test mode")
	await _tap(KEY_ESCAPE)
	await _click(entry.get_global_rect().get_center())
	await _physics(3)
	_check(lobby.get_node_or_null("Apartment/GuidedTutorial") != null,
		"The guided tutorial can be entered again")
	await _tap(KEY_ESCAPE)
	_check(lobby.get_node_or_null("Apartment") == null and get_nodes_in_group(&"pickups").is_empty(),
		"Leaving a lesson frees all tutorial props")
	lobby.free()
	if not failed:
		print("Guided tutorial smoke test passed.")
	quit(int(failed))


func _walk_to(goal: Vector3, player: CharacterBody3D, lesson: Node) -> void:
	for _frame in 240:
		if lesson.step != lesson.Step.MOVE:
			break
		var offset := goal - player.global_position
		_set_key(KEY_A, offset.x < -0.08)
		_set_key(KEY_D, offset.x > 0.08)
		_set_key(KEY_W, offset.z < -0.08)
		_set_key(KEY_S, offset.z > 0.08)
		await physics_frame
	for key in [KEY_A, KEY_D, KEY_W, KEY_S]:
		_set_key(key, false)


func _place_near(player: CharacterBody3D, item: RigidBody3D) -> void:
	player.global_position = Vector3(item.global_position.x, player.global_position.y, item.global_position.z + 0.8)
	player.velocity = Vector3.ZERO
	player.rotation.y = 0.0


func _face_target(player: CharacterBody3D, target: CharacterBody3D) -> void:
	var offset := target.global_position - player.global_position
	player.rotation.y = atan2(-offset.x, -offset.z)


func _grab(player: CharacterBody3D, item: RigidBody3D) -> void:
	_mouse(MOUSE_BUTTON_LEFT, true)
	await _expect(func() -> bool: return player.held_pickup == item,
		"The next item can be picked up with the taught hold", 150)
	_mouse(MOUSE_BUTTON_LEFT, false)
	await _physics(3)


func _check(condition: bool, message: String) -> void:
	if not condition:
		failed = true
		push_error(message)


func _expect(condition: Callable, message: String, frames := 120) -> bool:
	for _frame in frames:
		if condition.call():
			return true
		await physics_frame
	_check(false, message)
	return false


func _click(position: Vector2) -> void:
	var motion := InputEventMouseMotion.new()
	motion.position = position
	motion.global_position = position
	Input.parse_input_event(motion)
	Input.flush_buffered_events()
	await _frames(1)
	for pressed in [true, false]:
		var event := InputEventMouseButton.new()
		event.button_index = MOUSE_BUTTON_LEFT
		event.position = position
		event.global_position = position
		event.pressed = pressed
		Input.parse_input_event(event)
		Input.flush_buffered_events()
		await _frames(1)
	await _frames(2)


func _mouse(button: MouseButton, pressed: bool) -> void:
	var event := InputEventMouseButton.new()
	event.button_index = button
	event.pressed = pressed
	Input.parse_input_event(event)
	Input.flush_buffered_events()


func _tap(key: Key) -> void:
	_set_key(key, true)
	await _physics(3)
	_set_key(key, false)
	await _physics(3)


func _set_key(key: Key, pressed: bool) -> void:
	var event := InputEventKey.new()
	event.keycode = key
	event.physical_keycode = key
	event.pressed = pressed
	Input.parse_input_event(event)
	Input.flush_buffered_events()


func _frames(count: int) -> void:
	for _frame in count:
		await process_frame


func _physics(count: int) -> void:
	for _frame in count:
		await physics_frame
