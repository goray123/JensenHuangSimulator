extends SceneTree

const SFX := preload("res://sfx.gd")
var failed := false
var events: Array[Dictionary] = []


func _initialize() -> void:
	node_added.connect(_record_sound)
	_run.call_deferred()


func _record_sound(node: Node) -> void:
	if (node is AudioStreamPlayer3D or node is AudioStreamPlayer) and node.has_meta(&"sfx_event"):
		events.append({"event": node.get_meta(&"sfx_event"), "source": node.get_meta(&"sfx_source_id"), "spatial": node is AudioStreamPlayer3D})


func _count(prefix: String, source := 0) -> int:
	return events.filter(func(event: Dictionary) -> bool: return String(event.event).begins_with(prefix) and (source == 0 or event.source == source)).size()


func _run() -> void:
	_check(SFX.STREAMS.size() == 31, "All 31 authored WAV assets load")
	for sound: AudioStreamWAV in SFX.STREAMS.values():
		var source := FileAccess.get_file_as_bytes(sound.resource_path)
		_check(sound.mix_rate == 44100 and not sound.stereo and source.decode_u16(22) == 1 and source.decode_u32(24) == 44100 and source.decode_u16(34) == 16, "Every source preserves mono 44.1kHz 16-bit WAV; engine import compression is independent")
	var detached := Node3D.new()
	SFX.play_at(detached, &"hit_thud")
	SFX.play_ui(detached, &"pickup_grab")
	detached.free()
	_check(events.is_empty(), "Detached anchors create no players")
	var world := preload("res://tests/courtyard_fixture.tscn").instantiate()
	root.add_child(world)
	var player: CharacterBody3D = world.get_node("Player")
	await _frames(15)
	player.set_physics_process(false)
	var sphere: RigidBody3D = world.get_node("Pickup1")
	player.position = Vector3(6.5, 0.065, -1.5)
	player._update_animation(1.0 / 60.0)
	events.clear()
	SFX.play_at(player, &"hit_thud", -2.0, 0.0)
	var oneshots := get_nodes_in_group(&"sfx_oneshots")
	var last := oneshots[-1] as AudioStreamPlayer3D
	_check(last != null and last.unit_size == 3.0 and last.max_distance == 25.0 and last.bus == &"SFX", "Spatial players use the SFX bus and room attenuation")
	await create_timer(0.9).timeout
	_check(not is_instance_valid(last), "Finished audio nodes free themselves")
	events.clear()
	player.hold_pickup(sphere)
	_check(_count("pickup_grab") == 1, "One successful pickup plays one grab")
	player.release_pickup(false)
	_check(_count("throw_") == 0, "A drop or ownership transfer is silent")
	for trial in [{"speed": 1.0, "mass": 1.0, "sound": "throw_light"}, {"speed": 1.0, "mass": 3.0, "sound": "throw_heavy"}, {"speed": 8.0, "mass": 1.0, "sound": "throw_spin"}, {"speed": 10.0, "mass": 1.0, "sound": "throw_cartoon"}]:
		sphere.mass = trial.mass
		player.hold_pickup(sphere)
		events.clear()
		player.release_pickup(true, player.throw_velocity_at_speed(trial.speed))
		_check(player.held_pickup == null and _count(trial.sound) == 1 and _count("throw_") == 1, "Speed and mass select exactly one " + trial.sound)
	sphere.mass = 1.0
	player.hold_pickup(sphere)
	var obstacle := StaticBody3D.new()
	var collider := CollisionShape3D.new()
	var box := BoxShape3D.new()
	box.size = Vector3.ONE
	collider.shape = box
	obstacle.add_child(collider)
	world.add_child(obstacle)
	obstacle.global_position = sphere.global_position
	await _frames(2)
	events.clear()
	player.release_pickup(true, player.throw_velocity_at_speed(8.0))
	_check(player.held_pickup == sphere and _count("throw_") == 0, "An obstructed throw keeps the object and creates no throw sound")
	obstacle.queue_free()
	await _frames(2)
	player.release_pickup(false)
	events.clear()
	player._set_highlighted_pickup(sphere)
	player._set_highlighted_pickup(sphere)
	_check(_count("pickup_pop") == 1, "Unchanged highlights do not repeat the local pop")
	player._set_highlighted_pickup(null)
	player.reads_local_input = false
	player._set_highlighted_pickup(sphere)
	_check(_count("pickup_pop") == 1, "Remote players do not play UI selection feedback")
	player._set_highlighted_pickup(null)
	player.reads_local_input = true
	player.hold_pickup(sphere)
	events.clear()
	Input.action_press(&"interact")
	player._is_aiming = true
	player._aim_elapsed = 0.99
	player._physics_process(0.001)
	player._physics_process(0.001)
	_check(_count("pickup_powerup") == 1, "Maximum charge sounds once while the threshold stays crossed")
	player._aim_elapsed = 1.5
	player._physics_process(0.001)
	player._aim_elapsed = 0.99
	player._physics_process(0.001)
	_check(_count("pickup_powerup") == 2, "A later charge peak can sound again")
	Input.action_release(&"interact")
	player._cancel_aim()
	player.release_pickup(false)
	player._stun_remaining = 0.0
	player.simulates_movement = false
	player.velocity = Vector3.ZERO
	player.position = Vector3(5.5, 0.065, -0.6)
	player._step_position = player.global_position
	player._step_distance = 0.0
	events.clear()
	player.position.x += 0.6
	player._update_footsteps()
	_check(_count("step_") == 1 and player.velocity == Vector3.ZERO, "Snapshot movement produces one footstep without velocity")
	player._stun_remaining = 1.0
	player.position.x += 0.6
	player._update_footsteps()
	_check(_count("step_") == 1, "Stunned movement produces no step")
	player._stun_remaining = 0.0
	player.position.y = 4.0
	player.position.x += 0.6
	player._update_footsteps()
	_check(_count("step_") == 1, "Airborne movement produces no step")
	player.position = Vector3(5.5, 0.065, -0.6)
	player.hold_pickup(sphere)
	player._step_position = player.global_position
	player.position.x += 0.6
	player._update_footsteps()
	_check(_count("step_cartoon") == 1, "Carrying selects cartoon footsteps")
	player.release_pickup(false)
	for desired: StringName in [&"step_tile", &"step_carpet"]:
		var found := false
		for region in player._step_regions:
			if region.sound == desired:
				player.position.x = region.area.get_center().x
				player.position.z = region.area.get_center().y
				if player._footstep_surface() == desired:
					found = true
					break
		_check(found, "Cached map regions select " + desired)
	player.position = Vector3(6.5, 0.065, -1.5)
	player.reads_local_input = true
	player.simulates_movement = true
	var target := preload("res://player.tscn").instantiate()
	target.reads_local_input = false
	world.add_child(target)
	target.set_physics_process(false)
	events.clear()
	sphere.arm(player)
	sphere._on_body_entered(target)
	sphere._on_body_entered(target)
	_check(_count("hit_b", target.get_instance_id()) == 1 and _count("pickup_coin", player.get_instance_id()) == 1, "One hit plays one impact and one reward only for the thrower")
	var wall := StaticBody3D.new()
	world.add_child(wall)
	sphere.freeze = true
	sphere.collision_layer = 0
	sphere.collision_mask = 0
	events.clear()
	sphere.arm(player)
	sphere._on_body_entered(wall)
	sphere._on_body_entered(wall)
	_check(_count("hit_thud") == 1, "A throw sounds only its first non-player impact")
	sphere.arm(player)
	sphere._on_body_entered(wall)
	_check(_count("hit_thud") == 1, "The 150 ms impact cooldown survives rearming")
	await create_timer(0.17).timeout
	sphere.set_meta(&"item_id", "07-frying-pan")
	sphere.arm(player)
	sphere._on_body_entered(wall)
	_check(_count("hit_metal") == 1, "New household item metadata selects the metal impact")
	sphere.disarm()
	world.free()
	var lobby := preload("res://lan_lobby.tscn").instantiate()
	root.add_child(lobby)
	lobby.get_node("%TestMode").pressed.emit()
	await _frames(15)
	events.clear()
	lobby.get_node("Apartment/TestMode").target.receive_hit(&"hit_bonk")
	_check(_count("pickup_sparkle") == 1, "Offline target hits play one sparkle")
	lobby.free()
	await create_timer(1.0).timeout
	_check(get_nodes_in_group(&"sfx_oneshots").is_empty(), "Every remaining one-shot is cleaned up")
	if not failed:
		print("SFX smoke test passed.")
	quit(int(failed))


func _check(condition: bool, message: String) -> void:
	if not condition:
		failed = true
		push_error(message)


func _frames(count: int) -> void:
	for _frame in count:
		await physics_frame
