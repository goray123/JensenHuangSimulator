extends SceneTree

var failed := false


func _initialize() -> void:
	call_deferred("_run")


func _run() -> void:
	create_timer(20.0).timeout.connect(func() -> void:
		push_error("Intro smoke test timed out.")
		quit(1)
	)
	var lobby := preload("res://lan_lobby.tscn").instantiate()
	root.add_child(lobby)
	await _frames(2)
	var start := lobby.get_node("%Start") as TextureButton
	_check(start.visible, "The title screen shows the START button")
	_check(not lobby.get_node("%StatusPanel").visible, "The idle title screen has no status panel")
	start.mouse_entered.emit()
	await create_timer(0.25).timeout
	_check(start.scale.x > 1.1 and start.pivot_offset == start.size / 2.0, "Hovering START enlarges it around its center")
	start.mouse_exited.emit()
	await create_timer(0.25).timeout
	_check(is_equal_approx(start.scale.x, 1.0), "Leaving START restores its size")
	start.pressed.emit()
	_check(not start.visible and lobby.get_node("%Cancel").visible, "START searches for a room and offers cancel")
	await create_timer(2.3).timeout
	_check(lobby._peer != null and lobby.multiplayer.is_server(), "START opens a room when no host answers")
	lobby.get_node("%Cancel").pressed.emit()
	_check(start.visible and lobby._peer == null, "Cancel closes the room and shows START again")
	await _tap(KEY_F2)
	var intro := lobby.get_node_or_null("Intro")
	_check(intro != null and lobby.get_node_or_null("Apartment") == null and not lobby.get_node("Menu").visible, "F2 starts the intro before the test map")
	var page: Control = intro._page
	_check(intro._steps[5] == page.get_child(0), "Toon6 is layered under every other Toon")
	_check(intro._step == 0 and intro._steps[0].position.y < 0.0, "Toon1 enters from above")
	await create_timer(1.3).timeout
	_check(intro._step == 1, "A Toon advances on its own 0.6 s after settling")
	_check(intro._steps[1].position.x < 0.0, "Toon2 enters from the left")
	await _click()
	_check(intro._step == 2 and intro._steps[1].position == Vector2.ZERO, "A click settles the current Toon and shows the next one")
	await _click()
	await _click()
	_check(intro._step == 4 and intro._steps[4].position.y > 0.0, "Toon5 enters from below")
	await _click()
	_check(intro._step == 5 and intro._steps[5].position.y < 0.0 and not intro._video.is_playing(), "Toon6 slides in before its video plays")
	await _click()
	_check(intro._video.is_playing(), "The Toon6 video plays once Toon6 has settled")
	await _click()
	_check(not intro._video.is_playing() and lobby.get_node_or_null("Apartment") == null, "A click skips the video, then the game waits 0.5 s")
	await create_timer(0.7).timeout
	_check(lobby.get_node_or_null("Apartment/TestMode") != null and not is_instance_valid(intro), "The test map opens after the intro")
	lobby.free()
	if not failed:
		print("Intro smoke test passed.")
	quit(int(failed))


func _check(condition: bool, message: String) -> void:
	if not condition:
		failed = true
		push_error(message)


func _click() -> void:
	for pressed in [true, false]:
		var event := InputEventMouseButton.new()
		event.button_index = MOUSE_BUTTON_LEFT
		event.pressed = pressed
		Input.parse_input_event(event)
	Input.flush_buffered_events()
	await _frames(2)


func _tap(key: Key) -> void:
	for pressed in [true, false]:
		var event := InputEventKey.new()
		event.keycode = key
		event.physical_keycode = key
		event.pressed = pressed
		Input.parse_input_event(event)
		Input.flush_buffered_events()
	await _frames(2)


func _frames(count: int) -> void:
	for _frame in count:
		await process_frame
