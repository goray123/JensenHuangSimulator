extends CharacterBody3D

signal held_pickup_changed(is_holding: bool)

const MOVE_SPEED := 4.0
const TURN_SPEED := 6.0
const PICKUP_RANGE := 1.2
const THROW_SPEED := 12.0
const THROW_LIFT := 1.0

var held_pickup: RigidBody3D = null
var _is_aiming := false

@onready var _hand_socket: Marker3D = $RightArm/HandSocket
@onready var _trajectory: MeshInstance3D = $ThrowTrajectory


func _unhandled_input(event: InputEvent) -> void:
	if event.is_action_pressed(&"pickup"):
		_pickup_nearest()
		get_viewport().set_input_as_handled()
	elif event.is_action_pressed(&"throw"):
		_is_aiming = held_pickup != null
		get_viewport().set_input_as_handled()
	elif event.is_action_released(&"throw"):
		var should_throw := _is_aiming
		_cancel_aim()
		if should_throw:
			_throw_held_pickup()
		get_viewport().set_input_as_handled()


func _notification(what: int) -> void:
	if what == NOTIFICATION_APPLICATION_FOCUS_OUT:
		_cancel_aim()


func _cancel_aim() -> void:
	_is_aiming = false
	if is_instance_valid(_trajectory):
		_trajectory.clear_trajectory()


func _throw_velocity() -> Vector3:
	return -global_transform.basis.z * THROW_SPEED + Vector3.UP * THROW_LIFT


func _pickup_nearest() -> void:
	if held_pickup != null:
		return
	var nearest: RigidBody3D = null
	var nearest_distance_squared := PICKUP_RANGE * PICKUP_RANGE
	for node in get_tree().get_nodes_in_group(&"pickups"):
		var pickup := node as RigidBody3D
		if pickup == null or pickup.is_queued_for_deletion():
			continue
		var distance_squared := global_position.distance_squared_to(pickup.global_position)
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
	held_pickup = nearest
	held_pickup_changed.emit(true)


func _throw_held_pickup() -> void:
	if held_pickup == null:
		return
	var pickup := held_pickup
	held_pickup = null
	pickup.reparent(get_parent())
	pickup.collision_layer = 2
	pickup.collision_mask = 3
	pickup.freeze = false
	pickup.sleeping = false
	pickup.linear_velocity = _throw_velocity()
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
		_trajectory.update_trajectory(self, held_pickup, _throw_velocity())
	else:
		_cancel_aim()
