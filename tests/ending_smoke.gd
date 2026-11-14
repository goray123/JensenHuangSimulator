extends SceneTree
# godot --headless --path . --script res://tests/ending_smoke.gd

const Ending := preload("res://courtroom_ending.gd")

var failed := false


func _initialize() -> void:
	call_deferred("_run")


func _run() -> void:
	_check(Ending.outcome_for(10, 20) == Ending.Outcome.WIFE_WINS, "More wife gold means the wife wins")
	_check(Ending.outcome_for(900, 20) == Ending.Outcome.HUSBAND_WINS, "More husband gold means the husband wins")
	_check(Ending.outcome_for(0, 0) == Ending.Outcome.DRAW and Ending.outcome_for(50, 50) == Ending.Outcome.DRAW, "Equal totals are a draw")
	await _test_scene_motions()
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
		and ending.get_node("Result").text == "무승부", "A draw keeps both actors neutral")
	ending.queue_free()
	await process_frame


func _test_offline_rounds() -> void:
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
	(apartment.get_node("RoundTimer") as Timer).start(0.05)
	await _wait_frames(6)
	var ending: Node = apartment.get_node_or_null("Ending")
	_check(ending != null and apartment.process_mode == Node.PROCESS_MODE_DISABLED and apartment.get_node("HUD/RoundEnd").visible,
		"Timeout opens the ending on top of the frozen round")
	if ending == null:
		return
	_check(ending.outcome == Ending.Outcome.HUSBAND_WINS and ending.get_node("Result").text.contains("남편 %d G" % ring.gold_value),
		"The solo host (husband) wins with the exact bagged gold")
	var position: float = ending.husband_animation.current_animation_position
	await _wait_frames(10)
	_check(ending.husband_animation.current_animation_position > position, "The ending animates while the round is disabled")
	# Dummy: F3 bags two items for player1 (wife slot) while the host bag stays empty.
	await _restart(lobby, KEY_R)
	apartment = lobby.get_node("Apartment") as Node3D
	await _tap(KEY_F3)
	var dummy_gold: int = apartment.bag_gold().y
	_check(dummy_gold > 0 and apartment.bag_gold().x == 0, "F3 banks gold for the dummy slot")
	(apartment.get_node("RoundTimer") as Timer).start(0.05)
	await _wait_frames(6)
	ending = apartment.get_node("Ending")
	_check(ending.outcome == Ending.Outcome.WIFE_WINS and ending.get_node("Result").text.contains("아내 %d G" % dummy_gold), "The dummy's bag decides the wife slot")
	# Tie: nobody banks anything.
	await _restart(lobby, KEY_R)
	apartment = lobby.get_node("Apartment") as Node3D
	(apartment.get_node("RoundTimer") as Timer).start(0.05)
	await _wait_frames(6)
	ending = apartment.get_node("Ending")
	_check(ending.outcome == Ending.Outcome.DRAW and not ending.wife_animation.is_playing(), "Empty bags end in a neutral draw")
	await _restart(lobby, KEY_R)
	_check(lobby.get_node("Apartment").get_node_or_null("Ending") == null, "R replaces the ending with a fresh round")
	await _tap(KEY_ESCAPE)
	_check(lobby.get_node_or_null("Apartment") == null and lobby.get_node("Menu").visible, "Esc leaves the ending for the menu")


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
