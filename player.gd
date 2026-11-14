extends CharacterBody3D

signal held_pickup_changed(is_holding: bool)
signal pickup_action_requested(pick_up: bool)

const MOVE_SPEED := 4.0
const TURN_SPEED := 6.0
const PICKUP_RANGE := 1.2
const THROW_SPEED := 12.0
const THROW_LIFT := 1.0

var held_pickup: RigidBody3D = null
var reads_local_input := true
var simulates_movement := true
var remote_input := Vector2.ZERO
var _is_aiming := false

@onready var _hand_socket: Marker3D = $RightArm/HandSocket
@onready var _trajectory: MeshInstance3D = $ThrowTrajectory


func _unhandled_input(event: InputEvent) -> void:
	if not reads_local_input:
		return
	if event.is_action_pressed(&"pickup"):
		if simulates_movement:
			pickup_nearest()
		else:
			pickup_action_requested.emit(true)
		get_viewport().set_input_as_handled()
	elif event.is_action_pressed(&"throw"):
		_is_aiming = held_pickup != null
		get_viewport().set_input_as_handled()
	elif event.is_action_released(&"throw"):
		var should_throw := _is_aiming
		_cancel_aim()
		if should_throw:
			if simulates_movement:
				release_pickup(true)
			else:
				pickup_action_requested.emit(false)
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


func pickup_nearest() -> void:
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
	if nearest != null:
		hold_pickup(nearest)


func hold_pickup(pickup: RigidBody3D) -> void:
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
	held_pickup = pickup
	held_pickup_changed.emit(true)


func release_pickup(launch: bool) -> void:
	if held_pickup == null:
		return
	var pickup := held_pickup
	held_pickup = null
	_cancel_aim()
	pickup.reparent(get_parent())
	pickup.collision_layer = 2
	pickup.collision_mask = 3
	if launch:
		pickup.freeze = false
		pickup.sleeping = false
		pickup.linear_velocity = _throw_velocity()
		pickup.angular_velocity = Vector3.ZERO
	pickup.add_to_group(&"pickups")
	held_pickup_changed.emit(false)


static func read_movement() -> Vector2:
	return Input.get_vector(&"move_left", &"move_right", &"move_forward", &"move_backward")


func _physics_process(delta: float) -> void:
	if simulates_movement:
		_move(read_movement() if reads_local_input else remote_input, delta)
	if _is_aiming and held_pickup != null and Input.is_action_pressed(&"throw"):
		_trajectory.update_trajectory(self, held_pickup, _throw_velocity())
	elif _is_aiming:
		_cancel_aim()


func _move(input: Vector2, delta: float) -> void:
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
