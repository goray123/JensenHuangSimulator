extends SceneTree
# godot --headless --path . --script res://tests/ending_smoke.gd

const Ending := preload("res://courtroom_ending.gd")
const Reveal := preload("res://settlement_reveal.gd")

var failed := false


func _initialize() -> void:
	call_deferred("_run")


func _run() -> void:
	_check(Ending.outcome_for(10, 20) == Ending.Outcome.WIFE_WINS, "More wife gold means the wife wins")
	_check(Ending.outcome_for(900, 20) == Ending.Outcome.HUSBAND_WINS, "More husband gold means the husband wins")
	_check(Ending.outcome_for(0, 0) == Ending.Outcome.DRAW and Ending.outcome_for(50, 50) == Ending.Outcome.DRAW, "Equal totals are a draw")
	await _test_scene_motions()
	await _test_reveal()
	await _test_reveal_skips()
	await _test_offline_rounds()
	if not failed:
		print("Courtroom ending smoke test passed.")
	quit(int(failed))


func _test_scene_motions() -> void:
	var ending: Node = load("res://courtroom_ending.tscn").instantiate()
	root.add_child(ending)
	var viewport := ending.get_node("View/World") as SubViewport
	_check(viewport.own_world_3d and ending.get_node("View/World/Camera3D").current, "The ending renders its own world with its own camera")
	var sun_direction := -(ending.get_node("View/World/Sun") as DirectionalLight3D).global_basis.z
	_check(sun_direction.y < -0.5 and sun_direction.z < 0.0, "The sun shines down onto the stage, away from the camera")
	for actor in ["Wife", "Husband"]:
		_check_vertex_colors(ending.get_node("View/World/" + actor), actor)
	for winner in [Ending.Outcome.WIFE_WINS, Ending.Outcome.HUSBAND_WINS]:
		ending.play(winner)
		var wife: AnimationPlayer = ending.wife_animation
		var husband: AnimationPlayer = ending.husband_animation
		var wife_wins: bool = winner == Ending.Outcome.WIFE_WINS
		_check(wife.current_animation == (&"celebrate_jump" if wife_wins else &"defeat_kneel")
			and husband.current_animation == (&"defeat_kneel" if wife_wins else &"celebrate_jump"), "Outcome %d picks the matching clips" % winner)
		for player: AnimationPlayer in [wife, husband]:
			var clip := player.get_animation(player.current_animation)
			_check(is_equal_approx(clip.length, 6.0) and clip.loop_mode == Animation.LOOP_NONE, "Each clip is a 6-second one-shot")
		var skeleton := _skeleton(ending.get_node("View/World/Husband" if wife_wins else "View/World/Wife"))
		await _wait_frames(2)
		var opening := _pose(skeleton)
		await create_timer(6.4).timeout
		_check(not wife.is_playing() and not husband.is_playing(), "Both clips stop after six seconds")
		var held := _pose(skeleton)
		await _wait_frames(20)
		_check(_pose(skeleton) == held and not _same(held, opening), "The final pose is held without looping")
		var loser := husband if wife_wins else wife
		loser.seek(6.0, true)
		_check(_same(_pose(skeleton), held), "The held pose is the clip's last frame")
	ending.play(Ending.Outcome.DRAW)
	_check(not ending.wife_animation.is_playing() and not ending.husband_animation.is_playing()
		and ending.get_node("Result").text == "DRAW", "A draw keeps both actors neutral")
	ending.queue_free()
	await process_frame


func _test_offline_rounds() -> void:
	# A real window size, so screen clicks go through the same GUI layers as in play.
	root.size = Vector2i(1280, 720)
	var lobby: Node = load("res://lan_lobby.tscn").instantiate()
	lobby.play_intro = false
	root.add_child(lobby)
	await _wait_frames(2)
	# Solo: only the player banks gold, with the HUD counter still mid-tween at timeout.
	await _tap(KEY_F2)
	var apartment := lobby.get_node("Apartment") as Node3D
	await _wait_frames(5)
	var ring: RigidBody3D = apartment.get_node("Items/Item_12_ring")
	var ring_index: int = apartment._pickups.find(ring)
	apartment._apply_bag_item(0, ring_index, apartment._ownership_revision + 1)
	# Face value only: a fake ring roll must not change this check.
	apartment.settlement_surprises = false
	(apartment.get_node("RoundTimer") as Timer).start(0.05)
	await _wait_frames(6)
	var ending: Node = apartment.get_node_or_null("Ending")
	_check(ending != null and apartment.process_mode == Node.PROCESS_MODE_DISABLED and apartment.get_node("HUD/RoundEnd").visible,
		"Timeout opens the ending on top of the frozen round")
	if ending == null:
		return
	_check(ending.reveal != null and not ending.verdict_shown and not ending.husband_animation.is_playing()
		and ending.final_gold == Vector2i(ring.gold_value, 0) and apartment.final_gold == ending.final_gold,
		"The settlement reveal runs before any verdict, with the host's final totals")
	_check(ending.reveal.evidence_count == 0 and ending.reveal.phase == &"opening", "The reveal opens before any item is counted")
	await _click(Vector2(640, 360))
	_check(not ending.verdict_shown, "A screen click inside the grace period does not skip")
	ending._reveal_started_msec -= Ending.SKIP_GRACE_MSEC
	await _click(Vector2(640, 360))
	_check(ending.verdict_shown and ending.outcome == Ending.Outcome.HUSBAND_WINS
		and ending.get_node("Result").text.contains("HUSBAND %d G" % ring.gold_value),
		"A real screen click skips past the round-end overlay; the solo host (husband) wins with the exact bagged gold")
	var position: float = ending.husband_animation.current_animation_position
	await _wait_frames(10)
	_check(ending.husband_animation.current_animation_position > position, "The ending animates while the round is disabled")
	# Dummy: F3 bags two items for player1 (wife slot) while the host bag stays empty.
	await _restart(lobby, KEY_R)
	apartment = lobby.get_node("Apartment") as Node3D
	await _tap(KEY_F3)
	var dummy_gold: int = apartment.bag_gold().y
	_check(dummy_gold > 0 and apartment.bag_gold().x == 0, "F3 banks gold for the dummy slot")
	apartment.settlement_surprises = false
	(apartment.get_node("RoundTimer") as Timer).start(0.05)
	await _wait_frames(6)
	ending = apartment.get_node("Ending")
	ending.skip_reveal()
	_check(ending.outcome == Ending.Outcome.WIFE_WINS and ending.get_node("Result").text.contains("WIFE %d G" % dummy_gold), "The dummy's bag decides the wife slot")
	# Tie: nobody banks anything, and the empty reveal reaches the gavel on its own.
	await _restart(lobby, KEY_R)
	apartment = lobby.get_node("Apartment") as Node3D
	(apartment.get_node("RoundTimer") as Timer).start(0.05)
	await _wait_frames(6)
	ending = apartment.get_node("Ending")
	await _until(func() -> bool: return ending.verdict_shown, 6.0)
	_check(ending.verdict_shown and ending.outcome == Ending.Outcome.DRAW and not ending.wife_animation.is_playing(), "Empty bags end in a neutral draw")
	# Restarting mid-reveal drops the running sequence with the old round.
	await _restart(lobby, KEY_R)
	apartment = lobby.get_node("Apartment") as Node3D
	await _tap(KEY_F3)
	(apartment.get_node("RoundTimer") as Timer).start(0.05)
	await _wait_frames(40)
	_check(apartment.get_node("Ending").reveal.phase in [&"opening", &"items"], "The next restart happens mid-reveal")
	await _restart(lobby, KEY_R)
	_check(lobby.get_node("Apartment").get_node_or_null("Ending") == null, "R replaces the ending with a fresh round")
	await _tap(KEY_ESCAPE)
	_check(lobby.get_node_or_null("Apartment") == null and lobby.get_node("Menu").visible, "Esc leaves the ending for the menu")


## Plays a full settlement with every kind of evidence, sped up 5x.
func _test_reveal() -> void:
	var rows := Ending.preview_rows()
	var expected := Vector2i(1280, 2420)
	_check(Reveal.totals(rows) == expected, "Preview rows: piggy +340, fake ring 50, affair letter moves 500")
	var ending: Node = load("res://courtroom_ending.tscn").instantiate()
	root.add_child(ending)
	ending.show_settlement(rows)
	_check(ending.final_gold == expected and ending.get_node("Result").text == "" and not ending.wife_animation.is_playing(),
		"The verdict waits for the reveal")
	var reached: Array = []
	ending.verdict_reached.connect(func(outcome: int) -> void: reached.append(outcome))
	var reveal: Control = ending.reveal
	var phases: Array[StringName] = []
	var husband_peak := 0
	var saw_card := false
	var saw_transfer := false
	Engine.time_scale = 5.0
	var frames := 0
	while not ending.verdict_shown and frames < 2400:
		await process_frame
		frames += 1
		if phases.is_empty() or phases[-1] != reveal.phase:
			phases.append(reveal.phase)
		husband_peak = maxi(husband_peak, reveal.gold.x)
		saw_card = saw_card or (reveal.get_node("Evidence").visible and reveal._evidence_stamp.text != "")
		# Alimony leaves the husband's counter after it peaked.
		saw_transfer = saw_transfer or (reveal.evidence_count == 3 and reveal.gold.x < husband_peak)
	Engine.time_scale = 1.0
	_check(ending.verdict_shown and reached == [Ending.Outcome.WIFE_WINS], "The reveal ends in one verdict for the larger total")
	_check(phases == [&"opening", &"items", &"evidence", &"verdict", &"done"],
		"The reveal goes opening, items, evidence, verdict (got %s)" % [phases])
	_check(reveal.evidence_count == 3 and saw_card and saw_transfer, "Each special item gets a card and the letter moves alimony")
	_check(reveal.counter_text(0) == "1280 G" and reveal.counter_text(1) == "2420 G" and not reveal.get_node("Evidence").visible,
		"The counters finish on the final totals with the card closed")
	_check(ending.get_node("Result").text == "WIFE WINS!\nWIFE 2420 G   ·   HUSBAND 1280 G"
		and ending.wife_animation.current_animation == &"celebrate_jump", "The gavel shows the result and starts the motions")
	ending.queue_free()
	await process_frame


## Skipping mid-card, and the grace period that ignores late gameplay clicks.
func _test_reveal_skips() -> void:
	var ending: Node = load("res://courtroom_ending.tscn").instantiate()
	root.add_child(ending)
	ending.show_settlement(Ending.preview_rows())
	var click := InputEventMouseButton.new()
	click.button_index = MOUSE_BUTTON_LEFT
	click.pressed = true
	ending._unhandled_input(click)
	_check(not ending.verdict_shown, "A click right as the round ends does not skip the reveal")
	var verdicts: Array = []
	ending.verdict_reached.connect(func(outcome: int) -> void: verdicts.append(outcome))
	var reveal: Control = ending.reveal
	Engine.time_scale = 5.0
	# Right after the wife's fake-ring stamp, while her sad face is still running.
	await _until(func() -> bool: return reveal.evidence_count == 2 and reveal._evidence_stamp.text == "가짜!", 30.0)
	Engine.time_scale = 1.0
	_check(reveal.get_node("Evidence").visible and reveal._portraits[1].current_state == &"sad",
		"The skip happens while the fake-ring card and its sad face are showing")
	ending._reveal_started_msec -= Ending.SKIP_GRACE_MSEC
	ending._unhandled_input(click)
	_check(ending.verdict_shown and ending.outcome == Ending.Outcome.WIFE_WINS and not reveal.get_node("Evidence").visible
		and reveal.counter_text(0) == "1280 G" and reveal.counter_text(1) == "2420 G",
		"A later click jumps to the same verdict with every entry applied")
	_check(reveal._portraits[1].current_state == &"proud" and reveal._portraits[0].current_state == &"sad",
		"After a skip the winner looks proud and the loser sad, not the card's leftover face")
	# The dropped card steps were due ~3 s of game time later; run well past them.
	Engine.time_scale = 5.0
	await _until(func() -> bool: return false, 3.0)
	Engine.time_scale = 1.0
	_check(verdicts == [Ending.Outcome.WIFE_WINS] and reveal.counter_text(0) == "1280 G" and reveal.counter_text(1) == "2420 G"
		and reveal.evidence_count == 2, "Dropped reveal steps never resume after a skip (verdicts %s)" % [verdicts])
	ending.queue_free()
	await process_frame


func _until(condition: Callable, seconds: float) -> void:
	var deadline := Time.get_ticks_msec() + int(seconds * 1000.0)
	while not condition.call() and Time.get_ticks_msec() < deadline:
		await process_frame


func _restart(_lobby: Node, key: Key) -> void:
	await _tap(key)
	await _wait_frames(3)


## Vertex-colored surfaces use a color-space aware material without changing imported resources.
func _check_vertex_colors(actor: Node, label: String) -> void:
	var colored := 0
	for mesh_instance: MeshInstance3D in actor.find_children("*", "MeshInstance3D", true, false):
		var mesh := mesh_instance.mesh as ArrayMesh
		for surface in mesh.get_surface_count():
			var override := mesh_instance.get_surface_override_material(surface)
			var imported := mesh.surface_get_material(surface) as BaseMaterial3D
			if mesh.surface_get_arrays(surface)[Mesh.ARRAY_COLOR] == null:
				_check(override == null, "%s surfaces without vertex colors keep their imported material" % label)
				continue
			colored += 1
			var painted := override as ShaderMaterial
			_check(painted != null and painted != imported and painted.shader == Ending.PAINTED_VERTEX_SHADER,
				"%s %s uses the linear glTF paint shader through its own material" % [label, mesh_instance.name])
			if painted != null:
				_check(is_equal_approx(painted.get_shader_parameter(&"surface_roughness"), imported.roughness),
					"%s keeps the imported surface roughness" % label)
	_check(colored > 0, "%s has vertex-colored surfaces to check" % label)


func _skeleton(actor: Node) -> Skeleton3D:
	return actor.find_children("*", "Skeleton3D", true, false)[0] as Skeleton3D


func _pose(skeleton: Skeleton3D) -> Array[Transform3D]:
	var poses: Array[Transform3D] = []
	for bone in skeleton.get_bone_count():
		poses.append(skeleton.get_bone_global_pose(bone))
	return poses


func _same(a: Array[Transform3D], b: Array[Transform3D]) -> bool:
	for index in a.size():
		if not a[index].is_equal_approx(b[index]):
			return false
	return true


func _click(at: Vector2) -> void:
	for pressed in [true, false]:
		var event := InputEventMouseButton.new()
		event.button_index = MOUSE_BUTTON_LEFT
		event.pressed = pressed
		event.position = at
		event.global_position = at
		Input.parse_input_event(event)
		Input.flush_buffered_events()
		await _wait_frames(2)


func _tap(key: Key) -> void:
	for pressed in [true, false]:
		var event := InputEventKey.new()
		event.keycode = key
		event.physical_keycode = key
		event.pressed = pressed
		Input.parse_input_event(event)
		Input.flush_buffered_events()
		await _wait_frames(3)


func _wait_frames(frames: int) -> void:
	for _frame in frames:
		await physics_frame


func _check(condition: bool, message: String) -> void:
	if not condition:
		failed = true
		push_error(message)
