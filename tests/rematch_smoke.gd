extends SceneTree

# godot --headless --path . --script res://tests/rematch_smoke.gd
const LOBBY := preload("res://lan_lobby.tscn")

var _lobby: Node
var _failed := false


func _initialize() -> void:
	_run.call_deferred()


func _run() -> void:
	create_timer(40.0).timeout.connect(func() -> void:
		push_error("Offline rematch smoke test timed out.")
		quit(1)
	)
	root.size = Vector2i(1280, 720)
	_lobby = LOBBY.instantiate()
	_lobby.play_intro = false
	root.add_child(_lobby)
	_lobby._start_test_mode()
	if not await _expect(func() -> bool: return _lobby.get_node_or_null("Apartment/TestMode") != null,
		"The solo test round opens"):
		return
	await _physics(4)
	var apartment: Node3D = _lobby._apartment
	var old_id := apartment.get_instance_id()
	var old_match: int = _lobby._match_id
	var player: CharacterBody3D = apartment.get_node("Player")
	var ring: RigidBody3D = apartment.get_node("Items/Item_12_ring")
	apartment._apply_bag_item(0, apartment._pickups.find(ring), apartment._ownership_revision + 1)
	player.hold_pickup(apartment.get_node("Items/Item_06_egg"))
	player.receive_banana_peel()
	var banana: RigidBody3D = apartment.get_node("Items/Item_01_banana")
	banana.become_banana_peel(Transform3D(Basis.IDENTITY, Vector3(30, 0, 30)))
	banana.consume_banana_peel()
	await _finish_round(apartment)
	var menu: CanvasLayer = _lobby._post_round_menu
	_check(menu != null and not menu.actions_visible and not menu.panel.visible,
		"The result buttons start hidden over the disabled house")
	_lobby._request_rematch()
	_check(_lobby._post_round_choices == [0] and _lobby._apartment == apartment,
		"A rematch request during the three-second grace period is ignored")
	await create_timer(1.0).timeout
	_check(not menu.actions_visible and not menu.panel.visible,
		"No result buttons appear after only one second")
	if not await _actions_ready():
		return
	_check(Time.get_ticks_msec() - _lobby._post_round_started_msec >= 2900,
		"The result buttons wait three seconds before becoming available")
	_check(menu.indicators[0].choice == 0 and not menu.indicators[1].get_parent().visible,
		"A solo round shows only one waiting player slot")
	await _click(menu.rematch_button)
	_check(menu.indicators[0].choice == 1 and _lobby._post_round_choices == [1],
		"The real rematch button shows one green check for the solo player")
	if not await _expect(func() -> bool:
		return _lobby._apartment != null and _lobby._apartment.get_instance_id() != old_id,
		"One solo vote starts a fresh test round"):
		return
	await _physics(4)
	apartment = _lobby._apartment
	_check(_lobby._match_id > old_match and not is_instance_id_valid(old_id)
		and _lobby._post_round_menu == null and _lobby._post_round_choices.is_empty(),
		"Restart replaces the entire round and clears result choices")
	_check(not apartment._round_finished and apartment.can_process()
		and apartment.get_node("HUD/TimeLeft").text == "01:00"
		and apartment.bag_gold() == Vector2i.ZERO,
		"A rematch restores the timer, active gameplay and empty bags")
	player = apartment.get_node("Player")
	banana = apartment.get_node("Items/Item_01_banana")
	_check(player.held_pickup == null and not player.is_stunned() and not player.is_slipping()
		and not banana.is_banana_peel and not banana.is_banana_peel_consumed
		and get_nodes_in_group(&"pickups").size() == 21,
		"A fresh match clears held objects, stun and consumed peels without duplicate props")
	# R may replace an ending before its delayed controls become visible.
	await _finish_round(apartment)
	var pending_menu_id: int = _lobby._post_round_menu.get_instance_id()
	await _tap(KEY_R)
	apartment = _lobby._apartment
	await create_timer(3.2).timeout
	_check(not is_instance_id_valid(pending_menu_id) and _lobby._post_round_menu == null
		and not apartment._round_finished,
		"A delayed menu from the old round cannot appear after a manual restart")
	await _tap(KEY_ESCAPE)
	_lobby._open_tutorial()
	await _physics(4)
	apartment = _lobby._apartment
	apartment._end_round(PackedInt32Array())
	await create_timer(3.2).timeout
	_check(_lobby._state == _lobby.State.TUTORIAL and _lobby._post_round_menu == null,
		"Tutorial endings keep their own replay UI without a rematch overlay")
	await _tap(KEY_ESCAPE)
	_lobby._start_test_mode()
	if not await _expect(func() -> bool: return _lobby.get_node_or_null("Apartment/TestMode") != null,
		"Solo testing can reopen after the tutorial"):
		return
	await _finish_round(_lobby._apartment)
	if not await _actions_ready():
		return
	menu = _lobby._post_round_menu
	var previous_session_match: int = _lobby._match_id
	var previous_session_epoch: int = _lobby._post_round_epoch
	await _click(menu.title_button)
	_check(menu.indicators[0].choice == 2 and menu.rematch_button.disabled and menu.title_button.disabled,
		"The title button replaces the player's check with a red X and locks both actions")
	_lobby._request_rematch()
	_check(_lobby._post_round_choices == [2] and _lobby._post_round_resolution == 2,
		"A rematch request cannot override a pending return to the title")
	if not await _expect(func() -> bool: return _lobby._state == _lobby.State.IDLE,
		"A solo title vote returns to the title"):
		return
	_check(_lobby._apartment == null and _lobby._post_round_menu == null and _lobby._peer == null
		and _lobby.get_node("Menu").visible and get_nodes_in_group(&"pickups").is_empty(),
		"Returning to the title removes the old result, game and network state")
	# Session match IDs restart at one, while delayed callbacks retain the old epoch.
	_lobby._start_test_mode()
	if not await _expect(func() -> bool: return _lobby._apartment != null,
		"A new solo session opens after returning to the title"):
		return
	await _finish_round(_lobby._apartment)
	if not await _actions_ready():
		return
	var new_session_id: int = _lobby._apartment.get_instance_id()
	_check(_lobby._match_id == previous_session_match and _lobby._post_round_epoch != previous_session_epoch,
		"The new session reuses a match ID while keeping a distinct callback epoch")
	_lobby._post_round_menu.title_button.pressed.emit()
	_lobby._after_title_notice(previous_session_match, previous_session_epoch)
	_lobby._finish_title_fallback(previous_session_match, previous_session_epoch)
	await _physics(3)
	_check(_lobby._state == _lobby.State.TESTING and _lobby._apartment.get_instance_id() == new_session_id
		and not _lobby._title_notice_elapsed,
		"Old session notice and fallback callbacks cannot close the new result with the same match ID")
	await _expect(func() -> bool: return _lobby._state == _lobby.State.IDLE,
		"The new session still finishes its own title return normally")
	_lobby.free()
	if not _failed:
		print("Offline rematch smoke test passed.")
	quit(int(_failed))


func _finish_round(apartment: Node3D) -> void:
	(apartment.get_node("RoundTimer") as Timer).start(0.05)
	await _expect(func() -> bool: return apartment._round_finished,
		"The normal timer finishes the round")
	await _physics(2)


func _actions_ready() -> bool:
	return await _expect(func() -> bool:
		return _lobby._post_round_menu != null and _lobby._post_round_menu.actions_visible,
		"The rematch and title buttons appear after the result delay", 5.0)


func _expect(condition: Callable, message: String, seconds := 4.0) -> bool:
	var deadline := Time.get_ticks_msec() + int(seconds * 1000.0)
	while true:
		if condition.call():
			return true
		# A synchronous scene load can finish after the deadline in one frame.
		# Observe its result before deciding whether the operation timed out.
		if Time.get_ticks_msec() >= deadline:
			break
		await process_frame
	_check(false, message)
	return false


func _check(condition: bool, message: String) -> void:
	if not condition:
		_failed = true
		push_error(message)


func _click(button: Button) -> void:
	await process_frame
	var point := button.get_global_rect().get_center()
	for pressed in [true, false]:
		var event := InputEventMouseButton.new()
		event.position = point
		event.global_position = point
		event.button_index = MOUSE_BUTTON_LEFT
		event.pressed = pressed
		Input.parse_input_event(event)
		Input.flush_buffered_events()
		await _physics(2)


func _tap(key: Key) -> void:
	for pressed in [true, false]:
		var event := InputEventKey.new()
		event.keycode = key
		event.physical_keycode = key
		event.pressed = pressed
		Input.parse_input_event(event)
		Input.flush_buffered_events()
		await _physics(2)


func _physics(frames: int) -> void:
	for frame in frames:
		await physics_frame
