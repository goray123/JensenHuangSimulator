extends SceneTree

# Character motion state machine, socket and tug checks on the real GLB clips.
const ELDER := preload("res://assets/characters/motions/01_Elder.glb")
const MOTIONS := ["Idle", "Run", "Grab", "Pickup", "Carry", "RunCarry", "Aim", "Throw", "Tug_Fast", "Tug_Slow"]

var failed := false


func _initialize() -> void:
	call_deferred("_run")


func _run() -> void:
	_check_reset_imports()
	_check_clip_joints()
	var apartment := preload("res://tests/courtyard_fixture.tscn").instantiate()
	root.add_child(apartment)
	var player := apartment.get_node("Player") as CharacterBody3D
	var opponent := preload("res://player.tscn").instantiate() as CharacterBody3D
	opponent.name = "MotionOpponent"
	opponent.reads_local_input = false
	opponent.model_scene = ELDER
	apartment.add_child(opponent)
	player.add_collision_exception_with(opponent)
	opponent.add_collision_exception_with(player)
	var contest: Node = apartment._contest
	contest.register_opponent(opponent)
	apartment._players.append(opponent)
	await _wait_for_physics(15)
	var ground_y := player.global_position.y
	var sphere := apartment.get_node("Pickup1") as RigidBody3D
	for pickup in get_nodes_in_group(&"pickups"):
		if pickup != sphere:
			pickup.remove_from_group(&"pickups")
	var anim := player.get_node("Model").find_children("*", "AnimationPlayer", true, false)[0] as AnimationPlayer
	var opponent_anim := opponent.get_node("Model").find_children("*", "AnimationPlayer", true, false)[0] as AnimationPlayer
	_check(player.motion_asset() == "03_Young" and opponent.motion_asset() == "01_Elder", "Players load the new motion GLBs")
	_check_vertex_colors(player)

	# Idle is the default for a still player; Run scales from the 0.9 m/s source stride.
	player.global_position = Vector3(5.0, ground_y, -1.6)
	opponent.global_position = Vector3(9.0, ground_y, -1.6)
	await _wait_for_physics(3)
	_check(player.motion == &"Idle" and anim.current_animation.ends_with("__Idle"), "A still player breathes in Idle")
	_check(absf(1.0 / player.RUN_CLIP_SPEED - 2.47) < 0.01, "Run plays about 2.47x at 1 m/s")
	_set_key(KEY_D, true)
	await _wait_for_physics(20)
	_check(player.motion == &"Run" and absf(anim.speed_scale - player.MOVE_SPEED / player.RUN_CLIP_SPEED) < 0.15, "Moving plays Run at the stride-matched rate")
	_set_key(KEY_D, false)
	await _wait_for_physics(3)
	_check(player.motion == &"Idle", "Stopping returns to Idle")

	# Grab follows validated grab progress and holds still; release cancels it.
	player.rotation.y = 0.0
	sphere.global_position = player.global_position + Vector3(0, 0.08, -0.5)
	await _wait_for_physics(3)
	_mouse(true)
	await _wait_for_physics(30)
	var expected: float = player._grab_elapsed / sphere.packing_seconds() * anim.current_animation_length
	_check(player.motion == &"Grab" and is_zero_approx(anim.speed_scale) and absf(anim.current_animation_position - expected) < 0.05, "Grab is seeked by the real grab progress")
	_mouse(false)
	await _wait_for_physics(2)
	_check(player.motion == &"Idle" and player.held_pickup == null, "Releasing early cancels Grab back to Idle")
	_mouse(true)
	await _wait_for_physics(20)
	player.notification(Node.NOTIFICATION_APPLICATION_FOCUS_OUT)
	await _wait_for_physics(2)
	_check(player.motion == &"Idle", "Focus loss cancels Grab")
	_mouse(false)
	_mouse(true)
	await _wait_for_physics(20)
	player.global_position.x += 2.0
	await _wait_for_physics(2)
	_check(player.motion != &"Grab", "Leaving reach cancels Grab")
	_mouse(false)
	player.global_position.x -= 2.0
	await _wait_for_physics(2)

	# A completed grab plays Pickup from its first frame at 2x, then Carry and RunCarry.
	var pickup_start := []
	var record := func(is_holding: bool) -> void:
		if is_holding:
			var contact: Vector3 = player._bone_position(player._carry_bone)
			var gap: float = player.get_node("HandSocket").global_position.distance_to(contact)
			pickup_start.append([player.motion, anim.current_animation_position, anim.speed_scale, gap])
	player.held_pickup_changed.connect(record)
	_mouse(true)
	await _wait_for_physics(64)
	_mouse(false)
	await _wait_for_physics(1)
	player.held_pickup_changed.disconnect(record)
	_check(player.held_pickup == sphere and pickup_start.size() == 1 and pickup_start[0][0] == &"Pickup" and is_zero_approx(pickup_start[0][1]) and is_equal_approx(pickup_start[0][2], 2.0), "Ownership starts Pickup at 0 s and 2x")
	_check(pickup_start.size() == 1 and pickup_start[0][3] < 0.012, "Initial Pickup follows the hand without reserving unused throw height")
	await _wait_for_physics(66)
	_check(player.motion == &"Carry", "Pickup returns to Carry")
	var hand := player.get_node("HandSocket") as Marker3D
	_check(sphere.global_position.distance_to(hand.global_position) < 0.001 and hand.position.y < 0.47 - 0.05, "The held sphere sits at the carry contact, not the old fixed hand height")
	_set_key(KEY_W, true)
	await _wait_for_physics(12)
	_check(player.motion == &"RunCarry", "Moving with an item plays RunCarry")
	_set_key(KEY_W, false)
	await _wait_for_physics(3)

	# Aim winds up briskly with the item in the real throwing hand, then holds the ready pose,
	# which is the authored release contact. The predicted origin never depends on windup time.
	var trajectory := player.get_node("ThrowTrajectory") as MeshInstance3D
	var aim_length := anim.get_animation("03_Young__Aim").length
	var ready_frames := ceili(aim_length / player.AIM_PLAYBACK * Engine.physics_ticks_per_second) + 4
	var anchor: Array = player.MOTION_MANIFEST.data.assets["03_Young"].release_anchor_model_local
	_mouse(true)
	await _wait_for_physics(8)
	_check(player.motion == &"Aim" and is_equal_approx(anim.speed_scale, player.AIM_PLAYBACK), "Aiming plays the brisk Aim windup")
	_check(sphere.global_position.distance_to(_throw_hand(player)) < 0.002, "Mid-windup the held item sits in the real throwing hand")
	var windup_origin: Vector3 = trajectory.points[0]
	await _wait_for_physics(ready_frames)
	var release_point := (player.get_node("Model") as Node3D).global_transform * Vector3(anchor[0], anchor[1], anchor[2])
	_check(player.motion == &"Aim" and (not anim.is_playing() or is_equal_approx(anim.current_animation_position, aim_length)), "Aim holds its final ready pose")
	_check(sphere.global_position.distance_to(_throw_hand(player)) < 0.002 and sphere.global_position.distance_to(release_point) < 0.002, "The ready pose holds the item at the authored release contact")
	_check((trajectory.points[0] as Vector3).distance_to(windup_origin) < 0.001 and absf(sphere.global_position.y - (trajectory.points[0] as Vector3).y - player.THROW_HEIGHT_DROP) < 0.002, "The predicted origin is the lowered release contact throughout the windup")
	player.apply_stun(0.2)
	await _wait_for_physics(2)
	# Original gameplay keeps the charge while the button stays held; only the clip is cut.
	_check(player.motion == &"Carry" and player._is_aiming, "A stun interrupts the Aim clip but not the held charge")
	await _wait_for_physics(16)
	_check(player.motion == &"Aim", "Aim resumes after the stun while the button is held")

	# A blocked throw keeps the item and never plays Throw.
	var obstacle := StaticBody3D.new()
	var collider := CollisionShape3D.new()
	collider.shape = BoxShape3D.new()
	obstacle.add_child(collider)
	apartment.add_child(obstacle)
	obstacle.global_position = sphere.global_position
	await _wait_for_physics(2)
	_mouse(false)
	await _wait_for_physics(1)
	_check(player.held_pickup == sphere and player.motion != &"Throw", "An obstructed throw keeps the item without Throw")
	obstacle.free()
	await _wait_for_physics(2)

	# A real launch plays the one-hand Throw from 0 s, then returns to Idle.
	var launches: Array[RigidBody3D] = []
	player.pickup_launched.connect(func(item: RigidBody3D) -> void: launches.append(item))
	_mouse(true)
	await _wait_for_physics(10)
	var predicted_origin: Vector3 = trajectory.points[0]
	_mouse(false)
	_check(sphere.global_position.distance_to(predicted_origin) < 0.001, "An early release still launches from the predicted release contact")
	await _wait_for_physics(1)
	_check(player.held_pickup == null and player.motion == &"Throw" and anim.current_animation_position < 0.1 and launches == [sphere], "A validated launch starts Throw at its release pose")
	await _wait_for_physics(90)
	_check(player.motion == &"Idle", "Throw returns to Idle")

	# Ordinary drops never play Throw and cut a running Pickup.
	await _wait_for_physics(60)
	player.hold_pickup(sphere)
	await _wait_for_physics(2)
	player.release_pickup(false)
	await _wait_for_physics(2)
	_check(player.motion == &"Idle" and launches.size() == 1, "A plain drop interrupts Pickup without Throw or a launch event")

	# Server grab state is animated on players this peer does not control.
	sphere.freeze = true
	sphere.global_position = Vector3(7.0, ground_y + 0.12, -1.6)
	player.global_position = Vector3(5.0, ground_y, -1.6)
	opponent.global_position = Vector3(7.6, ground_y, -1.6)
	await _wait_for_physics(2)
	contest.request_interaction(opponent, true, sphere)
	await _wait_for_physics(20)
	_check(opponent.motion == &"Grab" and opponent_anim.current_animation_position > 0.1, "A remote grab plays Grab on the other player")
	contest.request_interaction(opponent, false)
	await _wait_for_physics(2)
	_check(opponent.motion == &"Idle", "The server grab end returns the remote player to Idle")

	# Tug-of-war: shared phase, facing stances, shared object path, tempo switch, cancel/finish.
	var player_model := player.get_node("Model") as Node3D
	var opponent_model := opponent.get_node("Model") as Node3D
	var player_rest := player_model.transform
	var opponent_rest := opponent_model.transform
	player.global_position = Vector3(6.4, ground_y, -1.6)
	sphere.global_position = Vector3(7.0, ground_y + 0.12, -1.6)
	var sphere_rest := sphere.global_transform
	await _wait_for_physics(2)
	contest.request_interaction(player, true, sphere)
	contest.request_interaction(opponent, true, sphere)
	await _wait_for_physics(1)
	if not _require(contest.active, "A shared grab starts the contest"):
		quit(1)
		return
	await _wait_for_process(2)
	var presentation: Node = contest.presentation
	_check(player.is_tugging() and opponent.is_tugging() and player.motion == &"Tug_Slow" and opponent.motion == &"Tug_Slow", "Both players tug in the slow tempo before any press")
	var spacing := Vector2(player_model.global_position.x, player_model.global_position.z).distance_to(Vector2(opponent_model.global_position.x, opponent_model.global_position.z))
	_check(absf(spacing - 2.4 * player.MODEL_SCALE) < 0.01, "Tug stances keep the authored 2.4 spacing")
	var toward := (opponent_model.global_position - player_model.global_position).normalized()
	_check(player_model.global_basis.z.normalized().dot(toward) > 0.99 and opponent_model.global_basis.z.normalized().dot(-toward) > 0.99, "Both characters face the contested object")
	_check(is_equal_approx(player_model.global_basis.get_scale().x, player.MODEL_SCALE), "Tug stances keep the model scale")
	await _wait_for_physics(30)
	var phase: float = presentation.tug_phase
	_check(absf(anim.current_animation_position - phase * 4.0) < 0.05, "Side 0 plays the shared phase")
	# The Elder clip is authored for side 0, so on side 1 it runs half a cycle later.
	_check(absf(opponent_anim.current_animation_position - fposmod(phase + 0.5, 1.0) * 4.0) < 0.05, "Side 1 plays the same phase mirrored")
	var path: Array = player.MOTION_MANIFEST.data.assets["03_Young"].tug_controller_paths.Slow
	_check(sphere.global_position.y > ground_y + 0.3 and absf(sphere.global_position.y - (ground_y + float(path[0].position_godot[1]) * player.MODEL_SCALE)) < 0.02, "The real object rides at the shared controller height")
	var before_press: float = presentation.tug_phase
	contest.request_interaction(opponent)
	await _wait_for_process(2)
	_check(player.motion == &"Tug_Fast" and opponent.motion == &"Tug_Fast", "Presses switch both players to the fast tempo")
	_check(absf(presentation.tug_phase - before_press) < 0.05, "The tempo change keeps the shared phase")
	presentation.tug_tempo = &"slow"
	await _wait_for_process(2)
	_check(player.motion == &"Tug_Slow", "The tempo can be forced through the API")
	presentation.tug_tempo = &"auto"
	# A guest snaps to the host's authoritative phase/tempo; packets from another revision are ignored.
	presentation.tug_phase = 0.9
	contest._sync_tug(contest.round_id, contest.item_index, apartment._ownership_revision, 0.2, false)
	_check(absf(presentation.tug_phase - 0.2) < 0.001 and player.motion == &"Tug_Slow" and absf(anim.current_animation_position - 0.8) < 0.01, "An authoritative tug packet corrects an offset phase")
	contest._sync_tug(contest.round_id, contest.item_index, apartment._ownership_revision - 1, 0.7, true)
	contest._sync_tug(contest.round_id, contest.item_index + 1, apartment._ownership_revision, 0.7, true)
	_check(absf(presentation.tug_phase - 0.2) < 0.001 and player.motion == &"Tug_Slow", "Tug packets with an old revision or another item are ignored")
	var cancelled_round: int = contest.round_id
	var cancelled_item: int = contest.item_index
	contest.cancel_round()
	await _wait_for_process(1)
	_check(not player.is_tugging() and player_model.transform.is_equal_approx(player_rest) and opponent_model.transform.is_equal_approx(opponent_rest), "Cancelling restores both model transforms")
	_check(sphere.global_transform.is_equal_approx(sphere_rest), "Cancelling returns the object to its rest pose")
	contest._sync_tug(cancelled_round, cancelled_item, apartment._ownership_revision, 0.4, true)
	await _wait_for_process(1)
	_check(not player.is_tugging() and not opponent.is_tugging() and sphere.global_transform.is_equal_approx(sphere_rest), "A late tug packet after cancellation neither restarts the tug nor moves the object")
	await _wait_for_physics(2)
	_check(player.motion == &"Idle" and opponent.motion == &"Idle", "Cancelled tug returns to Idle")

	contest.request_interaction(player, true, sphere)
	contest.request_interaction(opponent, true, sphere)
	await _wait_for_physics(1)
	_check(contest.active and player.is_tugging(), "A second contest starts the tug again")
	for press in contest.PRESS_ADVANTAGE_TO_WIN:
		contest.request_interaction(player)
	await _wait_for_physics(1)
	_check(not contest.active and player.held_pickup == sphere and player.motion == &"Pickup", "The winner lifts the won item with Pickup, not Throw")
	_check(player_model.transform.is_equal_approx(player_rest) and opponent_model.transform.is_equal_approx(opponent_rest), "Finishing restores both model transforms")
	_check(opponent.is_stunned() and opponent.motion == &"Idle", "The stunned loser returns to Idle")

	# Remote throw events: only a newer revision releases and plays Throw once.
	await _wait_for_physics(160)
	player.release_pickup(false)
	opponent.hold_pickup(sphere)
	var sphere_index: int = apartment._pickups.find(sphere)
	var revision: int = apartment._ownership_revision
	var transforms: Array = [player.transform, opponent.transform]
	for pickup in apartment._pickups:
		transforms.append(pickup.global_transform)
	apartment._apply_snapshot(transforms, Vector2i(-1, -1), revision, 40)
	await _wait_for_physics(1)
	_check(opponent.held_pickup == null and opponent.motion != &"Throw", "A snapshot release is not mistaken for a throw")
	opponent.hold_pickup(sphere)
	apartment._apply_throw(1, sphere_index, revision)
	_check(opponent.held_pickup == sphere, "A throw event without a newer revision is ignored")
	apartment._apply_throw(1, sphere_index, revision + 1)
	await _wait_for_physics(10)
	_check(opponent.held_pickup == null and opponent.motion == &"Throw", "The server throw event releases and plays the remote Throw")
	var throw_position := opponent_anim.current_animation_position
	apartment._apply_throw(1, sphere_index, revision + 1)
	_check(opponent_anim.current_animation_position >= throw_position, "A duplicate throw event does not restart Throw")
	apartment._apply_snapshot(transforms, Vector2i(-1, sphere_index), revision, 40)
	_check(opponent.held_pickup == null, "An older snapshot cannot re-attach the thrown item")

	# Hit flash still uses the overlay, separate from the painted surface overrides.
	player.receive_hit(&"hit_bonk")
	var overlay_set := false
	for mesh: MeshInstance3D in player.get_node("Model").find_children("*", "MeshInstance3D", true, false):
		overlay_set = overlay_set or mesh.material_overlay != null
	_check(overlay_set, "Hit flash still sets the material overlay")
	await _wait_for_physics(2)
	if not failed:
		print("Character motion smoke test passed.")
	quit(int(failed))


# A new clip must clear prior breathing scale and hair translations, including static keys.
# Compare the real imported scene after a peak inhale with a fresh/rested playback of each clip.
func _check_reset_imports() -> void:
	for name: String in ["01_Elder", "02_Woman", "03_Young"]:
		var model: Node3D = load("res://assets/characters/motions/" + name + ".glb").instantiate()
		root.add_child(model)
		var player: AnimationPlayer = model.find_children("*", "AnimationPlayer", true, false)[0]
		var skeleton: Skeleton3D = model.find_children("*", "Skeleton3D", true, false)[0]
		for label: String in MOTIONS:
			var clip := name + "__" + label
			var animation := player.get_animation(clip)
			_check(animation.get_track_count() == skeleton.get_bone_count() * 3, clip + " keeps all constant TRS reset tracks")
			player.stop()
			skeleton.reset_bone_poses()
			player.play(clip, 0.0)
			player.pause()
			player.seek(animation.length * 0.5, true)
			var baseline: Array[Transform3D] = []
			for index in skeleton.get_bone_count():
				baseline.append(skeleton.get_bone_global_pose(index))
			player.play(name + "__Idle", 0.0)
			player.pause()
			player.seek(1.6, true)
			player.play(clip, 0.0)
			player.pause()
			player.seek(animation.length * 0.5, true)
			var error := 0.0
			for index in skeleton.get_bone_count():
				var actual := skeleton.get_bone_global_pose(index)
				error = maxf(error, actual.origin.distance_to(baseline[index].origin))
				for axis in 3:
					error = maxf(error, actual.basis[axis].distance_to(baseline[index].basis[axis]))
			_check(error < 0.0001, clip + " clears the previous full-inhale pose")
		model.free()


func _check_clip_joints() -> void:
	for asset in ["01_Elder", "02_Woman", "03_Young"]:
		var model := (load("res://assets/characters/motions/%s.glb" % asset) as PackedScene).instantiate() as Node3D
		root.add_child(model)
		var anim := model.find_children("*", "AnimationPlayer", true, false)[0] as AnimationPlayer
		var skeleton := model.find_children("*", "Skeleton3D", true, false)[0] as Skeleton3D
		var idle := _pose(anim, skeleton, asset + "__Idle", 0.0)
		var hand_bone := skeleton.find_bone("socket_throw_ball.R")
		var aim_end := _pose(anim, skeleton, asset + "__Aim", anim.get_animation(asset + "__Aim").length)[hand_bone]
		var throw_start := _pose(anim, skeleton, asset + "__Throw", 0.0)[hand_bone]
		var anchor: Array = preload("res://player.gd").MOTION_MANIFEST.data.assets[asset].release_anchor_model_local
		var model_local := model.global_transform.affine_inverse() * (skeleton.global_transform * aim_end)
		_check(aim_end.distance_to(throw_start) < 0.001, "%s Aim ends on the Throw release contact" % asset)
		_check(model_local.distance_to(Vector3(anchor[0], anchor[1], anchor[2])) < 0.001, "%s release anchor matches the authored throwing hand" % asset)
		for clip in MOTIONS:
			var name: String = asset + "__" + clip
			_check(anim.has_animation(name), "%s exists" % name)
			if not anim.has_animation(name):
				continue
			var length := anim.get_animation(name).length
			var first := _pose(anim, skeleton, name, 0.0)
			var moved := 0.0
			for step in [0.25, 0.5, 0.75]:
				moved = maxf(moved, _difference(first, _pose(anim, skeleton, name, length * step)))
			if clip == "Carry":
				# Carry is the authored static held pose.
				_check(moved < 0.001 and _difference(first, idle) > 0.05, "%s is a stable held pose distinct from Idle" % name)
			else:
				_check(moved > 0.02, "%s moves its joints (%.3f)" % [name, moved])
		model.free()


func _throw_hand(player: Node3D) -> Vector3:
	var skeleton := player.get_node("Model").find_children("*", "Skeleton3D", true, false)[0] as Skeleton3D
	return skeleton.global_transform * skeleton.get_bone_global_pose(skeleton.find_bone("socket_throw_ball.R")).origin


func _pose(anim: AnimationPlayer, skeleton: Skeleton3D, clip: String, seconds: float) -> PackedVector3Array:
	anim.play(clip)
	anim.seek(seconds, true)
	var points := PackedVector3Array()
	for bone in skeleton.get_bone_count():
		points.append(skeleton.get_bone_global_pose(bone).origin)
	return points


func _difference(a: PackedVector3Array, b: PackedVector3Array) -> float:
	var largest := 0.0
	for index in a.size():
		largest = maxf(largest, a[index].distance_to(b[index]))
	return largest


func _check_vertex_colors(player: Node3D) -> void:
	var painted := 0
	for mesh: MeshInstance3D in player.get_node("Model").find_children("*", "MeshInstance3D", true, false):
		for surface in mesh.mesh.get_surface_count():
			var override := mesh.get_surface_override_material(surface)
			if mesh.mesh.surface_get_format(surface) & Mesh.ARRAY_FORMAT_COLOR:
				painted += 1
				_check(override is ShaderMaterial and (override as ShaderMaterial).shader.resource_path.ends_with("painted_vertex_color.gdshader"), "Painted surfaces use their vertex colours")
			else:
				_check(override == null, "Unpainted surfaces keep their own material")
	_check(painted > 0, "The face keeps its painted COLOR_0 surface")


func _check(condition: bool, message: String) -> void:
	if not condition:
		failed = true
		push_error(message)


func _require(condition: bool, message: String) -> bool:
	_check(condition, message)
	return condition


func _mouse(pressed: bool) -> void:
	var event := InputEventMouseButton.new()
	event.button_index = MOUSE_BUTTON_LEFT
	event.pressed = pressed
	Input.parse_input_event(event)
	Input.flush_buffered_events()


func _set_key(key: Key, pressed: bool) -> void:
	var event := InputEventKey.new()
	event.physical_keycode = key
	event.pressed = pressed
	Input.parse_input_event(event)
	Input.flush_buffered_events()


func _wait_for_process(frames: int) -> void:
	for _frame in frames:
		await process_frame


func _wait_for_physics(frames: int) -> void:
	for _frame in frames:
		await physics_frame
