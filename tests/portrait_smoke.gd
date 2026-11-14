extends SceneTree

var failed := false


func _initialize() -> void:
	call_deferred("_run")


func _run() -> void:
	_test_priorities()
	await _test_offline_events()
	if not failed:
		print("Portrait smoke test passed.")
	quit(int(failed))


func _test_priorities() -> void:
	var portrait := preload("res://ui/bust_portrait.tscn").instantiate()
	portrait.character = "man"
	portrait.set_process(false)
	root.add_child(portrait)
	portrait.set_process(false)
	_check(portrait.current_state == &"idle" and portrait.texture.atlas.resource_path.ends_with("man_idle.png"), "A portrait starts on its character's idle atlas")
	portrait.advance(0.5)
	_check(portrait.current_frame == 10 and portrait.texture.region == Rect2(512, 256, 256, 256), "Frames advance at 20 fps through the 8-column atlas")
	portrait.advance(3.0)
	_check(portrait.current_frame == 10, "The 60-frame clip loops every three seconds")
	portrait.play_reaction(&"idle")
	portrait.play_reaction(&"unknown")
	portrait.play_reaction(&"proud", NAN)
	_check(portrait.current_state == &"idle" and portrait._remaining.is_empty(), "Idle, unknown and invalid reactions are ignored")
	portrait.play_reaction(&"proud")
	_check(portrait.current_state == &"proud" and portrait.current_frame == 0 and portrait.texture.atlas.resource_path.ends_with("man_proud.png"), "A reaction switches to its own atlas from frame one")
	portrait.advance(1.0)
	portrait.play_reaction(&"proud")
	_check(portrait.current_frame == 20 and is_equal_approx(portrait._remaining[&"proud"], 3.0), "Repeating an event extends it without restarting the clip")
	portrait.play_reaction(&"angry", 1.0)
	_check(portrait.current_state == &"angry", "Angry outranks proud")
	portrait.play_reaction(&"proud")
	_check(portrait.current_state == &"angry", "A lower reaction cannot cover a higher one")
	portrait.play_reaction(&"sad", 2.0)
	portrait.play_reaction(&"fallen", 0.5)
	_check(portrait.current_state == &"fallen", "Fallen has the highest priority")
	portrait.advance(0.6)
	_check(portrait.current_state == &"sad", "When fallen expires the next active reaction (sad) shows")
	portrait.advance(1.5)
	_check(portrait.current_state == &"proud", "Expired sad and angry fall back to the still-running proud reaction")
	portrait.advance(1.0)
	_check(portrait.current_state == &"idle" and portrait._remaining.is_empty(), "Every reaction returns to idle when it expires")
	portrait.play_reaction(&"angry")
	portrait.clear_reactions()
	_check(portrait.current_state == &"idle", "clear_reactions restores idle")
	portrait.free()


func _test_offline_events() -> void:
	var lobby := preload("res://lan_lobby.tscn").instantiate()
	lobby.play_intro = false
	root.add_child(lobby)
	await _wait_for_physics(2)
	await _tap(KEY_F2)
	await _wait_for_physics(15)
	var apartment := lobby.get_node("Apartment")
	var hud := apartment.get_node("HUD")
	var wife: TextureRect = hud.portraits[0]
	var husband: TextureRect = hud.portraits[1]
	var player := apartment.get_node("Player") as CharacterBody3D
	var target: CharacterBody3D = apartment.get_node("TestMode").target
	var egg: RigidBody3D = apartment.get_node("Items/Item_06_egg")
	var ring: RigidBody3D = apartment.get_node("Items/Item_12_ring")
	var pan: RigidBody3D = apartment.get_node("Items/Item_07_frying_pan")
	_check(wife.character == "woman" and husband.character == "man" and wife.current_state == &"idle" and husband.current_state == &"idle",
		"The wife and husband cards start with their own idle portraits")
	_check(wife.get_parent().name == "WifeProfile" and husband.get_parent().name == "HusbandProfile" and not wife.get_parent().clip_contents,
		"Portraits sit on the original profile cards without clipping")
	_check(hud.proud_gold_threshold == 500 and ring.gold_value == 800 and egg.gold_value == 10, "The proud threshold uses the existing item prices")
	var connections: int = target.hit_received.get_connections().size()
	hud.bind_player(1, target)
	_check(target.hit_received.get_connections().size() == connections, "Binding a player twice adds no duplicate reactions")
	player.hold_pickup(egg)
	_check(wife.current_state == &"idle", "Picking up a 10-gold egg keeps the wife idle")
	player.release_pickup(false)
	hud.proud_gold_threshold = 900
	player.hold_pickup(ring)
	_check(wife.current_state == &"idle", "The HUD threshold decides what counts as expensive")
	player.release_pickup(false)
	hud.proud_gold_threshold = 500
	player.hold_pickup(ring)
	_check(wife.current_state == &"proud" and husband.current_state == &"idle", "Acquiring the 800-gold ring makes only the wife proud")
	pan.arm(player)
	pan._on_body_entered(target)
	_check(husband.current_state == &"fallen" and wife.current_state == &"proud", "A thrown hit on the test target shows the husband's fallen portrait")
	target.apply_status_effect(&"poison", 1.0)
	_check(husband.current_state == &"fallen", "A status effect cannot cover the fallen reaction")
	await _tap(KEY_F)
	_check(wife.current_state == &"fallen", "The F self-hit shows the wife's fallen portrait over proud")
	player.apply_status_effect(&"slip", 3.0)
	await create_timer(2.2).timeout
	_check(wife.current_state == &"sad" and husband.current_state == &"idle", "Sad follows fallen, and the husband's shorter status already returned to idle")
	await create_timer(1.0).timeout
	_check(wife.current_state == &"idle", "The wife returns to idle once every reaction expires")
	player.release_pickup(false)
	await _tap(KEY_G)
	_check(apartment._contest.active, "G starts the offline contest")
	for _press in 45:
		if not apartment._contest.active:
			break
		_mouse(MOUSE_BUTTON_LEFT, true)
		await _wait_for_physics(3)
		_mouse(MOUSE_BUTTON_LEFT, false)
		await _wait_for_physics(2)
	_check(not apartment._contest.active and target.is_stunned(), "The player wins the contest")
	_check(husband.current_state == &"angry" and wife.current_state == &"idle", "Losing the tug-of-war makes the test target angry, not fallen; a 20-gold banana keeps the winner idle")
	await _tap(KEY_ESCAPE)


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
