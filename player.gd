extends CharacterBody3D

const MOVE_SPEED := 4.0
const TURN_SPEED := 6.0


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
