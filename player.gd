extends CharacterBody3D

const MOVE_SPEED := 4.0
const TURN_SPEED := 2.6


func _physics_process(delta: float) -> void:
	var turn := Input.get_axis(&"turn_right", &"turn_left")
	rotate_y(turn * TURN_SPEED * delta)

	var throttle := Input.get_axis(&"move_backward", &"move_forward")
	var motion := -transform.basis.z * throttle * MOVE_SPEED
	velocity.x = motion.x
	velocity.z = motion.z
	if not is_on_floor():
		velocity += get_gravity() * delta
	move_and_slide()
