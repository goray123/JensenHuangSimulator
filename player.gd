extends CharacterBody3D

signal held_pickup_changed(is_holding: bool)
signal throw_blocked
signal aim_changed(is_aiming: bool, speed: float)
signal grab_changed(is_grabbing: bool, progress: float)
signal throw_requested(speed: float)
signal bag_requested
signal hit_received
## Emitted when this player loses a pickup tug-of-war (the loss stun has a different cause than a hit).
signal contest_lost
## Emitted by apply_status_effect(); no status-effect gameplay exists yet.
signal status_effect_applied(effect: StringName, seconds: float)
signal shared_sfx_requested(sound: StringName)
signal banana_peel_stepped

const SFX := preload("res://sfx.gd")

const MOVE_SPEED := 1.5
const TURN_SPEED := 6.0
const PICKUP_RANGE := 1.2
const MAX_THROW_SPEED := 10.0
const THROW_CYCLE_SECONDS := 2.0
const THROW_ANGLE := deg_to_rad(25.0)
const THROW_HEIGHT_DROP := 0.15
const HIT_FLASH_DURATION := 0.2
const HIT_STUN_DURATION := 0.5
const HIT_FLASH_INTERVAL := 0.05
const PEEL_STUN_DURATION := 2.0
const PUSH_MASS := 60.0
const PUSH_RESPONSE := 5.0
const DEFAULT_MODEL := preload("res://assets/characters/thump/03_Young.glb")
const MODEL_SCALE := 0.45
# The in-place Run clip covers ~0.46 m/s at the GLB's own scale (rig-report.json).
const RUN_CLIP_SPEED := 0.46 * MODEL_SCALE
# Covers MOVE_SPEED / RUN_CLIP_SPEED (~7.2x); the short-stepped clip needs fast playback.
const MAX_RUN_PLAYBACK := 8.0
const MIN_HAND_HEIGHT := 0.47
const LOOPING_CLIPS := ["Idle", "Walk", "Run", "Carry"]
const ONE_SHOT_CLIPS := ["Pickup", "Throw"]

## Rigged character from assets/characters/thump; set before adding the player to the tree.
@export var model_scene: PackedScene = DEFAULT_MODEL

var held_pickup: RigidBody3D = null
var bag_weight := 0
var reads_local_input := true
var simulates_movement := true
var remote_input := Vector2.ZERO
var contest_active := false
var pickup_request_handler: Callable
var _grab_target: RigidBody3D
var _grab_elapsed := -1.0
var _is_aiming := false
var _aim_elapsed := 0.0
var _stun_remaining := 0.0
var _flash_remaining := 0.0
var _body_meshes: Array[MeshInstance3D]
var _original_overlays: Array[Material]
var _hit_material := StandardMaterial3D.new()
var _highlighted_pickup: RigidBody3D

var _anim: AnimationPlayer
var _clip_prefix := ""
var _grip: BoneAttachment3D
var _last_position := Vector3.ZERO
var last_hit_sound: StringName = &"hit_bonk"
var _peak_sound_played := false
var _step_position := Vector3.ZERO
var _step_distance := 0.0
var _step_regions: Array[Dictionary] = []
var _step_ray := PhysicsRayQueryParameters3D.new()

@onready var _hand_socket: Marker3D = $HandSocket
@onready var _trajectory: MeshInstance3D = $ThrowTrajectory


func _ready() -> void:
	collision_mask |= 2
	_hit_material.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	_hit_material.albedo_color = Color(1, 0.04, 0.04)
	var model := _setup_model()
	_step_position = global_position
	_cache_step_regions()
	_step_ray.collision_mask = 1
	_step_ray.exclude = [get_rid()]
	for node: MeshInstance3D in model.find_children("*", "MeshInstance3D", true, false):
		_body_meshes.append(node)
		_original_overlays.append(node.material_overlay)


func _setup_model() -> Node3D:
	var model := model_scene.instantiate() as Node3D
	model.name = "Model"
	model.scale = Vector3.ONE * MODEL_SCALE
	# The exported characters face +Z; the player faces -Z.
	model.rotation.y = PI
	add_child(model)
	_anim = model.find_children("*", "AnimationPlayer", true, false)[0] as AnimationPlayer
	_clip_prefix = _anim.get_animation_list()[0].get_slice("__", 0) + "__"
	for clip: String in LOOPING_CLIPS:
		_anim.get_animation(_clip_prefix + clip).loop_mode = Animation.LOOP_LINEAR
	_grip = BoneAttachment3D.new()
	_grip.bone_name = "socket_grip.R"
	model.find_children("*", "Skeleton3D", true, false)[0].add_child(_grip)
	_last_position = global_position
	_play(&"Idle", 1.0)
	return model


func _update_animation(delta: float) -> void:
	var moved := global_position - _last_position
	_last_position = global_position
	# Follow the grip bone's position only, so held items keep the player's heading and size.
	# Crouching clips lower the hand to the floor; held items would then block every throw.
	var hand := _grip.global_position
	var minimum_height := MIN_HAND_HEIGHT
	if held_pickup != null:
		var collider := held_pickup.get_node("CollisionShape3D") as CollisionShape3D
		var local_bounds := (held_pickup.transform * collider.transform) * collider.shape.get_debug_mesh().get_aabb()
		minimum_height = maxf(minimum_height, THROW_HEIGHT_DROP + 0.021 - local_bounds.position.y)
	hand.y = maxf(hand.y, global_position.y + minimum_height)
	_hand_socket.global_position = hand
	if _anim.is_playing() and _anim.current_animation.trim_prefix(_clip_prefix) in ONE_SHOT_CLIPS:
		return
	var ground_speed := Vector2(moved.x, moved.z).length() / delta
	if ground_speed > 0.001:
		_play(&"Run", minf(ground_speed / RUN_CLIP_SPEED, MAX_RUN_PLAYBACK))
	else:
		_play(&"Carry" if held_pickup != null else &"Idle", 1.0)


func _play(clip: StringName, speed: float) -> void:
	var animation_name := _clip_prefix + clip
	if _anim.current_animation != animation_name:
		_anim.play(animation_name, 0.15)
	_anim.speed_scale = speed


func _play_once(clip: StringName, from_seconds: float, speed: float) -> void:
	_anim.play(_clip_prefix + clip, 0.1)
	_anim.seek(from_seconds, true)
	_anim.speed_scale = speed


func receive_hit(sound: StringName = &"") -> void:
	last_hit_sound = sound if sound in [&"hit_bonk", &"hit_boing"] else (&"hit_bonk" if randf() < 0.7 else &"hit_boing")
	SFX.play_at(self, last_hit_sound)
	apply_stun(HIT_STUN_DURATION)
	_flash_remaining = HIT_FLASH_DURATION
	_set_hit_flash(true)
	hit_received.emit()


func apply_stun(duration: float) -> void:
	_stun_remaining = maxf(_stun_remaining, duration)
	_cancel_grab()
	velocity.x = 0.0
	velocity.z = 0.0


## Entry point for future status effects (poison, slipping, ...). It only reports the
## effect for UI reactions; the gameplay effect itself is not implemented yet.
## In LAN games call it on the host: courtyard.gd relays it to the guest like hits.
func apply_status_effect(effect: StringName, seconds: float) -> void:
	if is_finite(seconds) and seconds > 0.0:
		status_effect_applied.emit(effect, seconds)


func receive_banana_peel() -> void:
	apply_stun(PEEL_STUN_DURATION)
	banana_peel_stepped.emit()


func set_contest_active(value: bool) -> void:
	contest_active = value
	if value:
		_cancel_grab()
		_cancel_aim()
		_set_highlighted_pickup(null)
		velocity.x = 0.0
		velocity.z = 0.0


func is_stunned() -> bool:
	return _stun_remaining > 0.0


func _update_hit_effects(delta: float) -> void:
	_stun_remaining = move_toward(_stun_remaining, 0.0, delta)
	if _flash_remaining > 0.0:
		_flash_remaining = move_toward(_flash_remaining, 0.0, delta)
		var flash_step := int((HIT_FLASH_DURATION - _flash_remaining) / HIT_FLASH_INTERVAL)
		_set_hit_flash(_flash_remaining > 0.0 and flash_step % 2 == 0)


func _set_hit_flash(red: bool) -> void:
	for index in _body_meshes.size():
		_body_meshes[index].material_overlay = _hit_material if red else _original_overlays[index]


func _unhandled_input(event: InputEvent) -> void:
	if not reads_local_input:
		return
	if event is InputEventKey and event.echo:
		return
	if event.is_action_pressed(&"interact"):
		if contest_active:
			if pickup_request_handler.is_valid():
				pickup_request_handler.call(self)
		elif held_pickup == null:
			_begin_grab()
		elif not _is_aiming:
			_aim_elapsed = 0.0
			_is_aiming = true
			aim_changed.emit(true, 0.0)
		get_viewport().set_input_as_handled()
	elif event.is_action_released(&"interact"):
		_cancel_grab()
		if _is_aiming:
			var launch_velocity := _throw_velocity()
			_cancel_aim()
			if simulates_movement:
				release_pickup(true, launch_velocity)
			else:
				throw_requested.emit(launch_velocity.length())
		get_viewport().set_input_as_handled()
	elif event.is_action_pressed(&"bag_item") and not contest_active and held_pickup != null:
		_cancel_aim()
		bag_requested.emit()
		get_viewport().set_input_as_handled()


func _notification(what: int) -> void:
	if what == NOTIFICATION_APPLICATION_FOCUS_OUT:
		_cancel_grab()
		_cancel_aim()


func _begin_grab() -> void:
	if _grab_elapsed >= 0.0 or not pickup_request_handler.is_valid():
		return
	_grab_target = get_pickup_target()
	if _grab_target != null:
		_grab_elapsed = 0.0
		grab_changed.emit(true, 0.0)
		pickup_request_handler.call(self, true, _grab_target)


func _cancel_grab() -> void:
	if _grab_elapsed < 0.0:
		return
	_grab_target = null
	_grab_elapsed = -1.0
	grab_changed.emit(false, 0.0)
	if pickup_request_handler.is_valid():
		pickup_request_handler.call(self, false)


func _cancel_aim() -> void:
	var was_aiming := _is_aiming
	_is_aiming = false
	_aim_elapsed = 0.0
	_peak_sound_played = false
	if is_instance_valid(_trajectory):
		_trajectory.clear_trajectory()
	if was_aiming:
		aim_changed.emit(false, 0.0)


func _throw_speed() -> float:
	var phase := TAU * _aim_elapsed / THROW_CYCLE_SECONDS
	return clampf(MAX_THROW_SPEED * 0.5 * (1.0 - cos(phase)), 0.0, MAX_THROW_SPEED)


func _throw_velocity() -> Vector3:
	return throw_velocity_at_speed(_throw_speed())


func throw_velocity_at_speed(speed: float) -> Vector3:
	var forward := -global_transform.basis.z
	forward.y = 0.0
	var direction := forward.normalized() * cos(THROW_ANGLE) + Vector3.UP * sin(THROW_ANGLE)
	return direction * clampf(speed, 0.0, MAX_THROW_SPEED)


func _throw_transform() -> Transform3D:
	var launch_transform := held_pickup.global_transform
	var collider := held_pickup.get_node("CollisionShape3D") as CollisionShape3D
	var bounds := collider.global_transform * collider.shape.get_debug_mesh().get_aabb()
	var available_drop := maxf(bounds.position.y - global_position.y - 0.02, 0.0)
	launch_transform.origin.y -= minf(THROW_HEIGHT_DROP, available_drop)
	return launch_transform


func _pickup_distance_squared(pickup: RigidBody3D) -> float:
	var reach_position := global_position
	reach_position.y = clampf(pickup.global_position.y, global_position.y, global_position.y + 1.8)
	return reach_position.distance_squared_to(pickup.global_position)


func can_grab(pickup: RigidBody3D) -> bool:
	return (held_pickup == null and not contest_active and not is_stunned()
		and is_instance_valid(pickup) and not pickup.is_queued_for_deletion() and pickup.is_in_group(&"pickups")
		and _pickup_distance_squared(pickup) <= PICKUP_RANGE * PICKUP_RANGE)


func get_pickup_target() -> RigidBody3D:
	if held_pickup != null or contest_active or is_stunned():
		return null
	var nearest: RigidBody3D = null
	var nearest_distance_squared := PICKUP_RANGE * PICKUP_RANGE
	for node in get_tree().get_nodes_in_group(&"pickups"):
		var pickup := node as RigidBody3D
		if pickup == null or pickup.is_queued_for_deletion() or pickup.get_world_3d() != get_world_3d():
			continue
		var distance_squared := _pickup_distance_squared(pickup)
		if distance_squared <= nearest_distance_squared:
			nearest = pickup
			nearest_distance_squared = distance_squared
	return nearest


func _update_pickup_highlight() -> void:
	var target: RigidBody3D = null
	if reads_local_input:
		target = _grab_target if is_instance_valid(_grab_target) else get_pickup_target()
	_set_highlighted_pickup(target)


func _set_highlighted_pickup(pickup: RigidBody3D) -> void:
	var changed := _highlighted_pickup != pickup
	if _highlighted_pickup != pickup and is_instance_valid(_highlighted_pickup):
		_highlighted_pickup.set_pickup_highlighted(false)
	_highlighted_pickup = pickup
	if is_instance_valid(_highlighted_pickup):
		_highlighted_pickup.set_pickup_highlighted(true)
		if changed and reads_local_input:
			SFX.play_ui(self, &"pickup_pop", -14.0)


func _exit_tree() -> void:
	_set_highlighted_pickup(null)


func hold_pickup(pickup: RigidBody3D) -> void:
	if pickup.is_banana_peel:
		return
	pickup.set_pickup_highlighted(false)
	_set_highlighted_pickup(null)
	if pickup.has_method(&"disarm"):
		pickup.disarm()
	pickup.freeze = true
	pickup.linear_velocity = Vector3.ZERO
	pickup.angular_velocity = Vector3.ZERO
	pickup.collision_layer = 0
	pickup.collision_mask = 0
	for body in pickup.get_collision_exceptions():
		pickup.remove_collision_exception_with(body)
	pickup.add_collision_exception_with(self)
	pickup.remove_from_group(&"pickups")
	pickup.reparent(_hand_socket)
	pickup.transform = Transform3D.IDENTITY
	pickup.position = pickup.get_meta(&"hold_offset", Vector3.ZERO)
	held_pickup = pickup
	_cancel_grab()
	_play_once(&"Pickup", 0.45, 2.0)
	_shared_sound(&"pickup_grab")
	held_pickup_changed.emit(true)


func release_pickup(launch: bool, launch_velocity := Vector3.ZERO) -> void:
	if held_pickup == null or (launch and contest_active):
		return
	var launch_transform := held_pickup.global_transform
	if launch:
		launch_transform = _throw_transform()
		var collider := held_pickup.get_node("CollisionShape3D") as CollisionShape3D
		var query := PhysicsShapeQueryParameters3D.new()
		query.shape = collider.shape
		query.transform = launch_transform * collider.transform
		query.collision_mask = 3
		query.exclude = [get_rid(), held_pickup.get_rid()]
		if not get_world_3d().direct_space_state.intersect_shape(query, 1).is_empty():
			throw_blocked.emit()
			return
	if launch:
		var speed := launch_velocity.length()
		var sound: StringName = &"throw_cartoon" if speed >= 9.5 else (&"throw_spin" if speed >= 6.0 else (&"throw_heavy" if held_pickup.mass >= 2.0 else &"throw_light"))
		_shared_sound(sound)
	var pickup := held_pickup
	held_pickup = null
	_cancel_aim()
	pickup.reparent(get_parent())
	pickup.global_transform = launch_transform
	pickup.collision_layer = 2
	pickup.collision_mask = 3
	pickup.freeze = not multiplayer.is_server()
	pickup.linear_velocity = launch_velocity if launch else Vector3.ZERO
	pickup.angular_velocity = Vector3.ZERO
	pickup.sleeping = false
	if launch:
		if pickup.has_method(&"arm"):
			pickup.arm(self)
	pickup.add_to_group(&"pickups")
	_play_once(&"Throw", 0.45, 1.5)
	held_pickup_changed.emit(false)


static func read_movement() -> Vector2:
	return Input.get_vector(&"move_left", &"move_right", &"move_forward", &"move_backward")


func _physics_process(delta: float) -> void:
	if simulates_movement:
		var input := read_movement() if reads_local_input else remote_input
		_move(Vector2.ZERO if is_stunned() or contest_active else input, delta)
	_update_hit_effects(delta)
	if _grab_elapsed >= 0.0:
		if not reads_local_input or not Input.is_action_pressed(&"interact") or not is_instance_valid(_grab_target) or not can_grab(_grab_target):
			_cancel_grab()
		else:
			var seconds: float = _grab_target.packing_seconds()
			_grab_elapsed = minf(_grab_elapsed + delta, seconds)
			grab_changed.emit(true, _grab_elapsed / seconds)
	_update_pickup_highlight()
	_update_animation(delta)
	_update_footsteps()
	if reads_local_input and _is_aiming and held_pickup != null and Input.is_action_pressed(&"interact"):
		_aim_elapsed = fmod(_aim_elapsed + delta, THROW_CYCLE_SECONDS)
		_trajectory.update_trajectory(self, held_pickup, _throw_velocity(), _throw_transform())
		var speed := _throw_speed()
		if speed >= MAX_THROW_SPEED * 0.97 and not _peak_sound_played:
			SFX.play_ui(self, &"pickup_powerup", -8.0)
			_peak_sound_played = true
		elif speed < MAX_THROW_SPEED * 0.97:
			_peak_sound_played = false
		aim_changed.emit(true, speed)
	elif _is_aiming:
		_cancel_aim()


func _move(input: Vector2, delta: float) -> void:
	var direction := Vector3(input.x, 0.0, input.y)
	var hand_weight: int = held_pickup.weight if held_pickup != null else 0
	var motion := direction * (MOVE_SPEED / pow(1.0 + 0.03 * (bag_weight + hand_weight), 1.5))
	if not direction.is_zero_approx():
		var target_yaw := atan2(-direction.x, -direction.z)
		rotation.y = rotate_toward(rotation.y, target_yaw, TURN_SPEED * delta)
	velocity.x = motion.x
	velocity.z = motion.z
	if not is_on_floor():
		velocity += get_gravity() * delta
	move_and_slide()
	if not direction.is_zero_approx():
		_push_colliding_bodies(motion, delta)


func _push_colliding_bodies(motion: Vector3, delta: float) -> void:
	for index in get_slide_collision_count():
		var collision := get_slide_collision(index)
		var body := collision.get_collider() as RigidBody3D
		if body == null or body.freeze:
			continue
		var push := -collision.get_normal()
		push.y = 0.0
		if push.is_zero_approx():
			continue
		push = push.normalized()
		var closing_speed := maxf((motion - body.linear_velocity).dot(push), 0.0)
		if closing_speed <= 0.0:
			continue
		# Contact height provides torque, so narrow furniture can also tip over.
		var effective_mass := PUSH_MASS * body.mass / (PUSH_MASS + body.mass)
		var impulse := push * closing_speed * effective_mass * PUSH_RESPONSE * delta
		body.sleeping = false
		body.apply_impulse(impulse, collision.get_position() - body.global_position)


func _shared_sound(sound: StringName) -> void:
	# LAN sends real interaction events reliably; ownership snapshots may skip a
	# brief hold or release an item for a contest rather than a throw.
	if not shared_sfx_requested.get_connections().is_empty():
		if simulates_movement:
			shared_sfx_requested.emit(sound)
	else:
		SFX.play_at(self, sound, -4.0 if sound == &"pickup_grab" else 0.0)


func _cache_step_regions() -> void:
	var world := get_parent()
	while world.get_parent() != null and not world.has_method(&"_apply_snapshot"):
		world = world.get_parent()
	for node in world.find_children("*", "Node3D", true, false):
		var label := String(node.name).to_lower()
		var sound: StringName = &""
		if "rug" in label or "carpet" in label or label.ends_with("mat"):
			sound = &"step_carpet"
		elif "tile" in label or "checkers" in label or label == "entryfloor" or label == "entrance_pink_floor":
			sound = &"step_tile"
		if sound.is_empty():
			continue
		var meshes: Array[Node] = []
		if node is MeshInstance3D or node is CSGBox3D:
			meshes.append(node)
		else:
			meshes.assign(node.find_children("*", "MeshInstance3D", true, false))
		for mesh in meshes:
			var local_box: AABB
			if mesh is MeshInstance3D:
				local_box = mesh.get_aabb()
			elif mesh is CSGBox3D:
				local_box = AABB(-mesh.size * 0.5, mesh.size)
			else:
				continue
			var box: AABB = mesh.global_transform * local_box
			_step_regions.append({"area": Rect2(Vector2(box.position.x, box.position.z), Vector2(box.size.x, box.size.z)), "sound": sound})


func _footstep_surface() -> StringName:
	if held_pickup != null:
		return &"step_cartoon"
	var position_xz := Vector2(global_position.x, global_position.z)
	var result: StringName = &"step_wood"
	for region in _step_regions:
		if (region.area as Rect2).has_point(position_xz):
			if region.sound == &"step_carpet":
				return &"step_carpet"
			result = region.sound
	return result


func _grounded_for_steps() -> bool:
	if simulates_movement:
		return is_on_floor()
	# Replicas never call move_and_slide, so is_on_floor/velocity are stale.
	_step_ray.from = global_position + Vector3.UP * 0.12
	_step_ray.to = global_position + Vector3.DOWN * 0.18
	return not get_world_3d().direct_space_state.intersect_ray(_step_ray).is_empty()


func _update_footsteps() -> void:
	var distance := Vector2(global_position.x - _step_position.x, global_position.z - _step_position.z).length()
	_step_position = global_position
	if distance > 0.8 or is_stunned() or contest_active or not _grounded_for_steps():
		_step_distance = 0.0
		return
	_step_distance += distance
	while _step_distance >= 0.55:
		_step_distance -= 0.55
		SFX.play_at(self, _footstep_surface(), -10.0, 0.08)
