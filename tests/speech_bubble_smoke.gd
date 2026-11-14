extends SceneTree

# Shout bubbles in the real solo test mode: the right line per event and speaker, a pill that grows with
# the line and sits above the speaker's head, one bubble per speaker, expiry, and clearing at round end.
const SPEECH := preload("res://ui/speech_bubbles.gd")

var failed := false


func _initialize() -> void:
	call_deferred("_run")


func _run() -> void:
	var lobby := preload("res://lan_lobby.tscn").instantiate()
	lobby.play_intro = false
	root.add_child(lobby)
	await _wait_for_physics(2)
	await _tap(KEY_F2)
	await _wait_for_physics(10)
	var apartment := lobby.get_node("Apartment") as Node3D
	var speech: Control = apartment.get_node("HUD").speech
	var player := apartment.get_node("Player") as CharacterBody3D
	var mode := apartment.get_node("TestMode")
	var target: CharacterBody3D = mode.target
	_check(speech != null and speech.bubble(0) == null and speech.bubble(1) == null, "Both speakers start silent")

	player.receive_hit()
	var first: PanelContainer = speech.bubble(0)
	_check(first != null and _text(first) == SPEECH.LINES[&"hit"][0][0], "A hit makes the husband shout his first hit line")
	await _wait_for_physics(12)
	var camera := root.get_camera_3d()
	var head := camera.unproject_position(player.get_node("Head").global_position)
	var rect: Rect2 = first.get_global_rect()
	_check(rect.end.y < head.y - 10.0 and absf(rect.get_center().x - head.x) < 2.0, "The bubble sits centered above the speaker's head (%s, head %s)" % [rect, head])
	var burst: TextureRect = speech.crunch_burst(0)
	var impact := camera.unproject_position((player.get_node("Model") as Node3D).global_position + SPEECH.CRUNCH_OFFSET)
	_check(burst != null and burst.texture == SPEECH.CRUNCH and burst.get_index() > first.get_index(), "A hit slams the 으드득!! burst on top of the bubbles")
	_check(burst != null and rect.end.y <= burst.position.y + 0.5, "The victim's hit line is lifted clear above the burst (%s vs burst top %.1f)" % [rect, burst.position.y if burst else 0.0])
	_check(burst != null and burst.size.x == SPEECH.CRUNCH_WIDTH and is_equal_approx(burst.scale.x, 1.0)
		and (burst.position + burst.size * 0.5).distance_to(impact) < 1.0, "After the pop the burst rests at full size, centred on the victim's head (%s vs %s)" % [burst.position + burst.size * 0.5 if burst else Vector2.ZERO, impact])
	player.receive_hit()
	_check(_text(speech.bubble(0)) == SPEECH.LINES[&"hit"][0][1] and speech.bubble(0) != first, "The next hit cycles to the next line and replaces the bubble")
	_check(speech.crunch_burst(0) != burst and speech.crunch_burst(0) != null, "A new hit restarts the burst")
	await process_frame
	var live := speech.get_children().filter(func(child: Node) -> bool: return not child.is_queued_for_deletion())
	_check(live.size() == 2 and live.filter(func(child: Node) -> bool: return child is PanelContainer).size() == 1, "Each speaker shows one bubble and one burst at a time")
	await create_timer(1.0).timeout
	_check(speech.crunch_burst(0) == null, "The burst fades out on its own within a second")
	var short_width: float = speech.bubble(0).size.x
	player.play_throw_motion()
	var throw_bubble: PanelContainer = speech.bubble(0)
	_check(_text(throw_bubble) == "이거나 먹어랏!!!" and throw_bubble.size.x > short_width + 60.0, "A throw shouts 이거나 먹어랏!!! in a pill wider than a short line")
	_check(throw_bubble.size.y < 70.0 and throw_bubble.size.x < 360.0, "Lines stay on one short pill (%s)" % throw_bubble.size)

	# The two hits above stunned the husband; he can move (and tug) again once it wears off.
	while player.is_stunned():
		await physics_frame
	var before: Vector2 = throw_bubble.get_global_rect().get_center()
	_set_key(KEY_D, true)
	await _wait_for_physics(20)
	_set_key(KEY_D, false)
	await process_frame
	_check(throw_bubble.get_global_rect().get_center().x > before.x + 20.0, "The bubble follows the moving speaker")

	mode._start_contest_test()
	await _wait_for_physics(2)
	_check(_text(speech.bubble(0)) == "내꺼야!!!" and _text(speech.bubble(1)) == "내꺼야!!!", "A tug-of-war makes both shout 내꺼야!!!")
	# Only the visual models step into the tug stance; the shouts must hang over them once the zoom settles.
	await create_timer(0.45).timeout
	var tug_camera := root.get_camera_3d()
	for index in 2:
		var model := ((player if index == 0 else target).get_node("Model") as Node3D)
		var over := tug_camera.unproject_position(model.global_position + SPEECH.HEAD_OFFSET)
		var shout: Rect2 = speech.bubble(index).get_global_rect()
		_check(absf(shout.get_center().x - over.x) < 1.5 and absf(shout.end.y - over.y) < 1.5, "Tug shout %d hangs over its stepped-in model (%s vs %s)" % [index, shout, over])
	apartment._contest._finish_contest(0)
	_check(_text(speech.bubble(1)) == SPEECH.LINES[&"lost"][1][0] and _text(speech.bubble(0)) == SPEECH.LINES[&"won"][0][0],
		"The loser complains and the winner gloats")
	await create_timer(SPEECH.POP_SECONDS + SPEECH.SHOW_SECONDS + SPEECH.FADE_SECONDS + 0.3).timeout
	_check(speech.bubble(0) == null and speech.bubble(1) == null and speech.get_child_count() == 0, "Bubbles fade out and free themselves")

	await create_timer(2.6).timeout
	target.receive_banana_peel()
	_check(_text(speech.bubble(1)) == SPEECH.LINES[&"slip"][1][0], "Stepping on a peel makes the wife shriek")
	_check(speech.crunch_burst(0) == null and speech.crunch_burst(1) == null, "Throws, tugs and slips never show the hit burst")
	var ring: RigidBody3D = apartment.get_node("Items/Item_12_ring")
	apartment.get_node("HUD").add_bag_item(1, apartment._pickups.find(ring), ring)
	_check(_text(speech.bubble(1)) == "위자료다!!", "Bagging an item gives the wife her bag line")

	# Peers see the same events in the same order, so a fresh instance replays the same words.
	var replay: Control = SPEECH.new()
	root.add_child(replay)
	replay.bind(0, player.get_node("Head"))
	replay.bind(1, target.get_node("Head"))
	var seen := []
	for event: StringName in [&"hit", &"hit", &"throw"]:
		seen.append(replay.say(0, event))
	_check(seen == [SPEECH.LINES[&"hit"][0][0], SPEECH.LINES[&"hit"][0][1], "이거나 먹어랏!!!"], "Line choice is deterministic for the same event order")
	_check(replay.say(0, &"unknown") == "" and replay.say(5, &"hit") == "", "Unknown events and unbound speakers stay silent")
	replay.free()

	player.receive_hit()
	apartment._end_round(PackedInt32Array())
	_check(speech.bubble(0) == null and speech.bubble(1) == null, "The round end clears every bubble")
	if not failed:
		print("Speech bubble smoke test passed.")
	quit(int(failed))


func _text(bubble: PanelContainer) -> String:
	return (bubble.get_child(0) as Label).text if bubble != null else ""


func _check(condition: bool, message: String) -> void:
	if not condition:
		failed = true
		push_error(message)


func _tap(key: Key) -> void:
	_set_key(key, true)
	await process_frame
	_set_key(key, false)
	await process_frame


func _set_key(key: Key, pressed: bool) -> void:
	var event := InputEventKey.new()
	event.physical_keycode = key
	event.pressed = pressed
	Input.parse_input_event(event)
	Input.flush_buffered_events()


func _wait_for_physics(frames: int) -> void:
	for _frame in frames:
		await physics_frame
