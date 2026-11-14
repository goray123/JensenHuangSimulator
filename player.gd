extends CharacterBody3D

signal held_pickup_changed(is_holding: bool)
signal throw_blocked
signal aim_changed(is_aiming: bool, speed: float)

const MOVE_SPEED := 4.0
const TURN_SPEED := 6.0
const PICKUP_RANGE := 1.2
const MAX_THROW_SPEED := 10.0
const THROW_CYCLE_SECONDS := 2.0
const THROW_ANGLE := deg_to_rad(25.0)
const THROW_HEIGHT_DROP := 0.15

var held_pickup: RigidBody3D = null
var _is_aiming := false
var _aim_elapsed := 0.0

@onready var _hand_socket: Marker3D = $RightArm/HandSocket
@onready var _trajectory: MeshInstance3D = $ThrowTrajectory


func _unhandled_input(event: InputEvent) -> void:
	if event.is_action_pressed(&"pickup"):
		_pickup_nearest()
		get_viewport().set_input_as_handled()
	elif event.is_action_pressed(&"throw"):
		if not _is_aiming and held_pickup != null:
			_aim_elapsed = 0.0
			_is_aiming = true
			aim_changed.emit(true, 0.0)
		get_viewport().set_input_as_handled()
	elif event.is_action_released(&"throw"):
		var should_throw := _is_aiming
		var launch_velocity := _throw_velocity()
		_cancel_aim()
		if should_throw:
			_throw_held_pickup(launch_velocity)
		get_viewport().set_input_as_handled()


func _notification(what: int) -> void:
	if what == NOTIFICATION_APPLICATION_FOCUS_OUT:
		_cancel_aim()


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
	var forward := -global_transform.basis.z
	forward.y = 0.0
	var direction := forward.normalized() * cos(THROW_ANGLE) + Vector3.UP * sin(THROW_ANGLE)
	return direction * _throw_speed()


func _throw_transform() -> Transform3D:
	var launch_transform := held_pickup.global_transform
	var collider := held_pickup.get_node("CollisionShape3D") as CollisionShape3D
	var bounds := collider.global_transform * collider.shape.get_debug_mesh().get_aabb()
	# Tall props must keep their entire collider above the floor at release.
	var available_drop := maxf(bounds.position.y - global_position.y - 0.02, 0.0)
	launch_transform.origin.y -= minf(THROW_HEIGHT_DROP, available_drop)
	return launch_transform


func _pickup_nearest() -> void:
	if held_pickup != null:
		return
	var nearest: RigidBody3D = null
	var nearest_distance_squared := PICKUP_RANGE * PICKUP_RANGE
	for node in get_tree().get_nodes_in_group(&"pickups"):
		var pickup := node as RigidBody3D
		if pickup == null or pickup.is_queued_for_deletion():
			continue
		# Objects on counters are reachable along the player's standing height.
		var reach_position := global_position
		reach_position.y = clampf(pickup.global_position.y, global_position.y, global_position.y + 1.8)
		var distance_squared := reach_position.distance_squared_to(pickup.global_position)
		if distance_squared <= nearest_distance_squared:
			nearest = pickup
			nearest_distance_squared = distance_squared
	if nearest == null:
		return
	nearest.freeze = true
	nearest.linear_velocity = Vector3.ZERO
	nearest.angular_velocity = Vector3.ZERO
	nearest.collision_layer = 0
	nearest.collision_mask = 0
	nearest.add_collision_exception_with(self)
	nearest.remove_from_group(&"pickups")
	nearest.reparent(_hand_socket)
	nearest.transform = Transform3D.IDENTITY
	nearest.position = nearest.get_meta(&"hold_offset", Vector3.ZERO)
	held_pickup = nearest
	held_pickup_changed.emit(true)


func _throw_held_pickup(launch_velocity: Vector3) -> void:
	if held_pickup == null:
		return
	var collider := held_pickup.get_node("CollisionShape3D") as CollisionShape3D
	var launch_transform := _throw_transform()
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
	pickup.reparent(get_parent())
	pickup.global_transform = launch_transform
	pickup.collision_layer = 2
	pickup.collision_mask = 3
	pickup.freeze = false
	pickup.sleeping = false
	pickup.linear_velocity = launch_velocity
	pickup.angular_velocity = Vector3.ZERO
	pickup.add_to_group(&"pickups")
	held_pickup_changed.emit(false)


func _physics_process(delta: float) -> void:
	var input := Input.get_vector(&"move_left", &"move_right", &"move_forward", &"move_backward")
	# Keep movement independent of the character's changing heading.
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
	if _is_aiming and held_pickup != null and Input.is_action_pressed(&"throw"):
		_aim_elapsed = fmod(_aim_elapsed + delta, THROW_CYCLE_SECONDS)
		_trajectory.update_trajectory(self, held_pickup, _throw_velocity(), _throw_transform())
		aim_changed.emit(true, _throw_speed())
	else:
		_cancel_aim()
