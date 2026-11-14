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
## Emitted on the simulating peer after a validated launch (never for drops or transfers).
signal pickup_launched(pickup: RigidBody3D)

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
const SLIP_FALL_SECONDS := 0.28
const SLIP_RECOVER_SECONDS := 0.32
const SLIP_FALL_ANGLE := PI * 0.5
# Sustained contact must overcome floor friction, including on large furniture.
const PUSH_MASS := 120.0
const PUSH_RESPONSE := 20.0
const DEFAULT_MODEL := preload("res://assets/characters/motions/03_Young.glb")
const MOTION_MANIFEST := preload("res://assets/characters/motions/CHARACTER_MOTIONS_MANIFEST.json")
const PAINTED_VERTEX_COLOR := preload("res://assets/characters/motions/painted_vertex_color.gdshader")
const MODEL_SCALE := 0.45
# The in-place Run clip covers 0.9 m/s at the GLB's own scale (motion manifest), ~2.47x at 1 m/s.
const RUN_CLIP_SPEED := 0.9 * MODEL_SCALE
# Covers MOVE_SPEED / RUN_CLIP_SPEED (~3.7x).
const MAX_RUN_PLAYBACK := 4.0
const PICKUP_PLAYBACK := 2.0
const THROW_PLAYBACK := 1.5
# Brisk windup: the 1.2 s Aim reaches its ready pose (= Throw release contact) after 0.48 s.
const AIM_PLAYBACK := 2.5
const LOOPING_CLIPS := ["Idle", "Run", "Carry", "RunCarry", "Tug_Fast", "Tug_Slow"]
const ONE_SHOT_CLIPS := [&"Pickup", &"Throw"]
# A remote grab whose end event was skipped (e.g. hold then instant bag) stops on its own.
const REMOTE_GRAB_GRACE := 1.0
const SOCKET_BLEND_RATE := 10.0

## Rigged character from assets/characters/motions; set before adding the player to the tree.
@export var model_scene: PackedScene = DEFAULT_MODEL

var held_pickup: RigidBody3D = null
var bag_weight := 0.0
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
var _model: Node3D
var _model_rest_transform := Transform3D.IDENTITY
var _model_bounds := AABB()
var _slip_active := false
var _slip_elapsed := 0.0
var _clip_prefix := ""
var _skeleton: Skeleton3D
var _carry_bone := -1
var _throw_bone := -1
# Model-local authored release contact (Aim end = Throw frame 0): the one launch point.
var _aim_anchor := Vector3.ZERO
# Held here so it outlives the meshes on free (the renderer reads it while they detach).
var _painted_material := ShaderMaterial.new()
var _socket_blend := 0.0
## The clip the state machine last chose (without prefix); seeked clips use speed 0.
var motion: StringName = &""
var _remote_grab_target: RigidBody3D
var _remote_grab_elapsed := -1.0
var _tug_side := -1
var _tug_phase_offset := 0.0
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
		var bounds := (model.global_transform.affine_inverse() * node.global_transform) * node.get_aabb()
		_model_bounds = bounds if _body_meshes.size() == 1 else _model_bounds.merge(bounds)


func _setup_model() -> Node3D:
	var model := model_scene.instantiate() as Node3D
	model.name = "Model"
	model.scale = Vector3.ONE * MODEL_SCALE
	# The exported characters face +Z; the player faces -Z.
	model.rotation.y = PI
	add_child(model)
	_model = model
	_model_rest_transform = model.transform
	_anim = model.find_children("*", "AnimationPlayer", true, false)[0] as AnimationPlayer
	_clip_prefix = _anim.get_animation_list()[0].get_slice("__", 0) + "__"
	# Advanced from _update_animation, so the hand socket reads this frame's pose (no lag).
	_anim.callback_mode_process = AnimationMixer.ANIMATION_CALLBACK_MODE_PROCESS_MANUAL
	for clip: String in LOOPING_CLIPS:
		_anim.get_animation(_clip_prefix + clip).loop_mode = Animation.LOOP_LINEAR
	_skeleton = model.find_children("*", "Skeleton3D", true, false)[0] as Skeleton3D
	var sockets: Dictionary = MOTION_MANIFEST.data.sockets
	_carry_bone = _skeleton.find_bone(sockets.carry)
	_throw_bone = _skeleton.find_bone(sockets.throw)
	var anchor: Array = MOTION_MANIFEST.data.assets[motion_asset()].release_anchor_model_local
	_aim_anchor = Vector3(anchor[0], anchor[1], anchor[2])
	_restore_vertex_colors(model)
	_last_position = global_position
	_play(&"Idle", 1.0, 0.0)
	return model


# Painted faces keep COLOR_0, which the imported StandardMaterial3D ignores; only those
# surfaces get a per-instance override, so every other surface keeps its own colour.
func _restore_vertex_colors(model: Node3D) -> void:
	_painted_material.shader = PAINTED_VERTEX_COLOR
	for mesh_instance: MeshInstance3D in model.find_children("*", "MeshInstance3D", true, false):
		for surface in mesh_instance.mesh.get_surface_count():
			if mesh_instance.mesh.surface_get_format(surface) & Mesh.ARRAY_FORMAT_COLOR:
				mesh_instance.set_surface_override_material(surface, _painted_material)


func _bone_position(bone: int) -> Vector3:
	return _skeleton.global_transform * _skeleton.get_bone_global_pose(bone).origin


## Name of this character's motion asset, e.g. "03_Young".
func motion_asset() -> String:
	return _clip_prefix.trim_suffix("__")


func _update_animation(delta: float) -> void:
	var moved := global_position - _last_position
	_last_position = global_position
	if _remote_grab_elapsed >= 0.0:
		_remote_grab_elapsed += delta
	if is_slipping():
		_update_hand_socket(delta)
		return
	_update_motion(Vector2(moved.x, moved.z).length() / delta)
	_anim.advance(delta)
	_update_hand_socket(delta)


## Motion priority: slip > tug > grab > aim > unfinished Pickup/Throw > Run(Carry) > Carry/Idle.
## Stuns cut grabs, aims and one-shots; a still player falls back to the breathing Idle.
func _update_motion(ground_speed: float) -> void:
	if _tug_side >= 0:
		return
	var grab_progress := grab_motion_progress()
	if grab_progress >= 0.0:
		_seek(&"Grab", grab_progress * _clip_length(&"Grab"))
		return
	if _is_aiming and held_pickup != null and not is_stunned():
		# Windup while aiming, then the non-looping clip holds its ready pose.
		_play(&"Aim", AIM_PLAYBACK, 0.1)
		return
	if motion in ONE_SHOT_CLIPS and _anim.is_playing() and not is_stunned():
		return
	if ground_speed > 0.001 and not is_stunned():
		_play(&"RunCarry" if held_pickup != null else &"Run", minf(ground_speed / RUN_CLIP_SPEED, MAX_RUN_PLAYBACK))
	else:
		_play(&"Carry" if held_pickup != null else &"Idle", 1.0)


# Follow the real contact bone by position only, so held items keep the player's heading and
# size: the carry contact normally, the throwing hand during Aim/Throw.
func _update_hand_socket(delta: float) -> void:
	var throwing := 1.0 if motion == &"Aim" or motion == &"Throw" else 0.0
	_socket_blend = move_toward(_socket_blend, throwing, SOCKET_BLEND_RATE * delta)
	_hand_socket.global_position = _clear_of_floor(_bone_position(_carry_bone).lerp(_bone_position(_throw_bone), _socket_blend))


# Held objects only need floor clearance. Reserve the extra drop height for a launch,
# so an early Pickup does not float above the authored hand contact.
func _clear_of_floor(hand: Vector3, for_launch := false) -> Vector3:
	if held_pickup != null:
		var collider := held_pickup.get_node("CollisionShape3D") as CollisionShape3D
		var local_bounds := (held_pickup.transform * collider.transform) * collider.shape.get_debug_mesh().get_aabb()
		var drop_margin := THROW_HEIGHT_DROP if for_launch else 0.0
		hand.y = maxf(hand.y, global_position.y + drop_margin + 0.021 - local_bounds.position.y)
	return hand


func _clip_length(clip: StringName) -> float:
	return _anim.get_animation(_clip_prefix + clip).length


func _play(clip: StringName, speed: float, blend := 0.15) -> void:
	if motion != clip:
		motion = clip
		_anim.play(_clip_prefix + clip, blend)
	_anim.speed_scale = speed


## Starts a non-looping clip from its first frame; the state machine resumes when it ends.
func _play_once(clip: StringName, speed: float) -> void:
	if is_slipping():
		return
	motion = clip
	_anim.play(_clip_prefix + clip, 0.1)
	_anim.seek(0.0, true)
	_anim.speed_scale = speed


# Seek-driven clips stay paused at the requested time (grab progress, shared tug phase).
func _seek(clip: StringName, seconds: float) -> void:
	if motion != clip:
		motion = clip
		_anim.play(_clip_prefix + clip, 0.0)
	_anim.speed_scale = 0.0
	_anim.seek(seconds, true)


## Grab progress shown by the model: the local validated grab, or a server-reported one; -1 if none.
func grab_motion_progress() -> float:
	if contest_active or held_pickup != null or is_stunned():
		return -1.0
	if _grab_elapsed >= 0.0 and is_instance_valid(_grab_target):
		return clampf(_grab_elapsed / _grab_target.packing_seconds(), 0.0, 1.0)
	if _remote_grab_elapsed >= 0.0 and is_instance_valid(_remote_grab_target):
		var seconds: float = _remote_grab_target.packing_seconds()
		if _remote_grab_elapsed <= seconds + REMOTE_GRAB_GRACE:
			return clampf(_remote_grab_elapsed / seconds, 0.0, 1.0)
	return -1.0


## Shows a server-validated grab on a player this peer does not control (null ends it).
func show_remote_grab(target: RigidBody3D) -> void:
	if reads_local_input:
		return
	_remote_grab_target = target
	_remote_grab_elapsed = 0.0 if target != null else -1.0


## Plays the one-hand Throw from its release pose; call only for a validated launch.
func play_throw_motion() -> void:
	if _tug_side < 0:
		_play_once(&"Throw", THROW_PLAYBACK)


## Moves the visual model into the authored tug stance around the shared contest object.
## Side 0 stands at -axis facing +axis; side 1 mirrors it. The body itself never moves.
func begin_tug(center: Vector3, axis: Vector3, side: int) -> void:
	if is_slipping():
		return
	var asset: Dictionary = MOTION_MANIFEST.data.assets[motion_asset()]
	var facing := axis if side == 0 else -axis
	var stance := center - facing * float(asset.tug_body_spacing) * 0.5 * MODEL_SCALE
	stance.y = global_position.y
	_model.global_transform = Transform3D(Basis.looking_at(-facing).scaled(Vector3.ONE * MODEL_SCALE), stance)
	# Clips are authored for one side; the other side is the same pull half a cycle later.
	_tug_phase_offset = 0.0 if int(asset.tug_model_side) == side else 0.5
	_tug_side = side


## Poses the tug clip at the shared normalized phase; a tempo change keeps the phase.
func update_tug(phase: float, fast: bool) -> void:
	if _tug_side < 0 or is_slipping():
		return
	var clip := &"Tug_Fast" if fast else &"Tug_Slow"
	_seek(clip, fposmod(phase + _tug_phase_offset, 1.0) * _clip_length(clip))


## Restores the model's original transform; the state machine picks the next clip.
func end_tug() -> void:
	if _tug_side < 0:
		return
	_tug_side = -1
	if not is_slipping():
		_model.transform = _model_rest_transform
	motion = &""


func is_tugging() -> bool:
	return _tug_side >= 0


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
	_cancel_aim()
	_set_highlighted_pickup(null)
	if not _slip_active:
		_slip_active = true
		_slip_elapsed = 0.0
		# Hold a neutral skeletal pose while the visual model falls as one body.
		motion = &""
		_anim.play(_clip_prefix + "Idle", 0.0)
		_anim.speed_scale = 1.0
		_anim.advance(0.0)
		_anim.pause()
	banana_peel_stepped.emit()


func is_slipping() -> bool:
	return _slip_active


func _update_slip(delta: float) -> void:
	if not _slip_active:
		return
	if not is_stunned():
		_slip_active = false
		_model.transform = _model_rest_transform
		_anim.stop()
		motion = &""
		_play(&"Carry" if held_pickup != null else &"Idle", 1.0)
		return
	_slip_elapsed += delta
	var fall := smoothstep(0.0, SLIP_FALL_SECONDS, _slip_elapsed)
	var recovery := smoothstep(0.0, SLIP_RECOVER_SECONDS, _stun_remaining)
	var angle := SLIP_FALL_ANGLE * minf(fall, recovery)
	# Rotate in player space: +Z is backward even though the model itself faces +Z.
	var pose := _model_rest_transform
	pose.basis = Basis(Vector3.RIGHT, angle) * pose.basis
	# Lift the visible body just enough to keep its back above the floor.
	var standing_bounds := _model_rest_transform * _model_bounds
	var fallen_bounds := pose * _model_bounds
	pose.origin.y += maxf(standing_bounds.position.y - fallen_bounds.position.y, 0.0)
	_model.transform = pose


func set_contest_active(value: bool) -> void:
	contest_active = value
	show_remote_grab(null)
	if not value:
		end_tug()
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
	if is_slipping():
		if event.is_action(&"interact") or event.is_action(&"bag_item"):
			get_viewport().set_input_as_handled()
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
	# Launch from the authored release contact whatever pose the model shows (e.g. a remote
	# player still mid-Pickup on the host); a held Aim ready pose is exactly this point.
	launch_transform.origin += _clear_of_floor(_model.global_transform * _aim_anchor, true) - _hand_socket.global_position
	var collider := held_pickup.get_node("CollisionShape3D") as CollisionShape3D
	var bounds := (launch_transform * collider.transform) * collider.shape.get_debug_mesh().get_aabb()
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
	show_remote_grab(null)
	# Ownership is confirmed: contact-to-carry lift from its first frame, then Carry/RunCarry.
	_play_once(&"Pickup", PICKUP_PLAYBACK)
	# Place the item at the contact pose now, not where the last clip left the empty socket.
	_socket_blend = 0.0
	_update_hand_socket(0.0)
	_shared_sound(&"pickup_grab")
	held_pickup_changed.emit(true)


func release_pickup(launch: bool, launch_velocity := Vector3.ZERO) -> void:
	if held_pickup == null or (launch and (contest_active or is_slipping())):
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
	if launch:
		play_throw_motion()
		pickup_launched.emit(pickup)
	elif motion in ONE_SHOT_CLIPS:
		# Drops, transfers and bagging never play Throw; an interrupted lift returns to Idle/Run.
		motion = &""
	held_pickup_changed.emit(false)


static func read_movement() -> Vector2:
	return Input.get_vector(&"move_left", &"move_right", &"move_forward", &"move_backward")


func _physics_process(delta: float) -> void:
	if simulates_movement:
		var input := read_movement() if reads_local_input else remote_input
		_move(Vector2.ZERO if is_stunned() or contest_active else input, delta)
	_update_hit_effects(delta)
	_update_slip(delta)
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
	var hand_weight: float = held_pickup.weight if held_pickup != null else 0.0
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
