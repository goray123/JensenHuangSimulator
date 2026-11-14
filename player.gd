extends CharacterBody3D

signal held_pickup_changed(is_holding: bool)
signal throw_blocked
signal aim_changed(is_aiming: bool, speed: float)
signal grab_changed(is_grabbing: bool, progress: float)
signal throw_requested(speed: float)
signal bag_requested
signal hit_received

const MOVE_SPEED := 4.0
const TURN_SPEED := 6.0
const PICKUP_RANGE := 1.2
const GRAB_SECONDS := 1.0
const MAX_THROW_SPEED := 10.0
const THROW_CYCLE_SECONDS := 2.0
const THROW_ANGLE := deg_to_rad(25.0)
const THROW_HEIGHT_DROP := 0.15
const HIT_FLASH_DURATION := 0.2
const HIT_STUN_DURATION := 0.5
const HIT_FLASH_INTERVAL := 0.05

var held_pickup: RigidBody3D = null
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

@onready var _hand_socket: Marker3D = $RightArm/HandSocket
@onready var _trajectory: MeshInstance3D = $ThrowTrajectory


func _ready() -> void:
	_hit_material.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	_hit_material.albedo_color = Color(1, 0.04, 0.04)
	for node in get_children():
		if node is MeshInstance3D and node != _trajectory:
			_body_meshes.append(node)
			_original_overlays.append(node.material_overlay)


func receive_hit() -> void:
	apply_stun(HIT_STUN_DURATION)
	_flash_remaining = HIT_FLASH_DURATION
	_set_hit_flash(true)
	hit_received.emit()


func apply_stun(duration: float) -> void:
	_stun_remaining = maxf(_stun_remaining, duration)
	_cancel_grab()
	velocity.x = 0.0
	velocity.z = 0.0


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
	if _highlighted_pickup != pickup and is_instance_valid(_highlighted_pickup):
		_highlighted_pickup.set_pickup_highlighted(false)
	_highlighted_pickup = pickup
	if is_instance_valid(_highlighted_pickup):
		_highlighted_pickup.set_pickup_highlighted(true)


func _exit_tree() -> void:
	_set_highlighted_pickup(null)


func hold_pickup(pickup: RigidBody3D) -> void:
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
	var pickup := held_pickup
	held_pickup = null
	_cancel_aim()
	pickup.reparent(get_parent())
	pickup.global_transform = launch_transform
	pickup.collision_layer = 2
	pickup.collision_mask = 3
	pickup.freeze = not launch
	pickup.linear_velocity = launch_velocity if launch else Vector3.ZERO
	pickup.angular_velocity = Vector3.ZERO
	if launch:
		pickup.sleeping = false
		if pickup.has_method(&"arm"):
			pickup.arm(self)
	pickup.add_to_group(&"pickups")
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
			_grab_elapsed = minf(_grab_elapsed + delta, GRAB_SECONDS)
			grab_changed.emit(true, _grab_elapsed / GRAB_SECONDS)
	_update_pickup_highlight()
	if reads_local_input and _is_aiming and held_pickup != null and Input.is_action_pressed(&"interact"):
		_aim_elapsed = fmod(_aim_elapsed + delta, THROW_CYCLE_SECONDS)
		_trajectory.update_trajectory(self, held_pickup, _throw_velocity(), _throw_transform())
		aim_changed.emit(true, _throw_speed())
	elif _is_aiming:
		_cancel_aim()


func _move(input: Vector2, delta: float) -> void:
	var direction := Vector3(input.x, 0.0, input.y)
	var motion := direction * MOVE_SPEED
	if not direction.is_zero_approx():
		var target_yaw := atan2(-direction.x, -direction.z)
		rotation.y = rotate_toward(rotation.y, target_yaw, TURN_SPEED * delta)
	velocity.x = motion.x
	velocity.z = motion.z
	if not is_on_floor():
		velocity += get_gravity() * delta
	move_and_slide()
