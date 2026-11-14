extends SceneTree

var failed := false


func _initialize() -> void:
	call_deferred("_run")


func _run() -> void:
	var apartment := preload("res://courtyard.tscn").instantiate()
	root.add_child(apartment)
	var thrower := apartment.get_node("Player") as CharacterBody3D
	var victim := preload("res://player.tscn").instantiate() as CharacterBody3D
	victim.name = "HitTarget"
	victim.reads_local_input = false
	var blue := StandardMaterial3D.new()
	blue.albedo_color = Color(0.16, 0.65, 0.98)
	victim.get_node("Torso").material_override = blue
	apartment.add_child(victim)
	await _wait_for_physics(15)
	var ground_y := thrower.global_position.y
	var torso := victim.get_node("Torso") as MeshInstance3D
	var original_overlay := torso.material_overlay
	var hit_positions: Array[Vector3] = []
	victim.hit_received.connect(func() -> void: hit_positions.append(victim.global_position))
	var sphere := apartment.get_node("Pickup1") as RigidBody3D
	_launch(thrower, victim, sphere, ground_y)
	await _expect(func() -> bool: return hit_positions.size() == 1, "A thrown sphere physically hits the other player")
	_check(victim.is_stunned(), "An impact immediately stuns the victim")
	_check(torso.material_overlay != original_overlay and torso.material_overlay.albedo_color.r > 0.9, "An impact immediately turns the victim red")
	_check(not thrower.is_stunned(), "The thrower is not hit by their own projectile")
	var hit_position := victim.global_position
	victim.remote_input = Vector2.RIGHT
	var saw_red := false
	var saw_original := false
	for _frame in 14:
		saw_red = saw_red or torso.material_overlay != original_overlay
		saw_original = saw_original or torso.material_overlay == original_overlay
		await physics_frame
	_check(saw_red and saw_original, "The victim blinks between red and the original material")
	_check(torso.material_overlay == original_overlay, "The red flash ends after 0.2 seconds")
	_check(torso.material_override == blue, "Flashing preserves the guest's blue outfit")
	_check(victim.is_stunned() and victim.global_position.distance_to(hit_position) < 0.01, "Movement stays locked after the red flash ends")
	await _wait_for_physics(12)
	_check(victim.is_stunned() and victim.global_position.distance_to(hit_position) < 0.01, "Held movement input cannot move the victim during the 0.5-second stun")
	await _wait_for_physics(8)
	_check(not victim.is_stunned() and victim.global_position.x > hit_position.x + 0.1, "Movement resumes after 0.5 seconds")

	var tv := apartment.get_node("Furnishings/LivingRoom/Television") as RigidBody3D
	victim.remote_input = Vector2.ZERO
	_launch(thrower, victim, tv, ground_y)
	await _expect(func() -> bool: return hit_positions.size() == 2, "A thrown TV also causes a hit")
	await _wait_for_physics(3)
	_launch(thrower, victim, sphere, ground_y)
	await _expect(func() -> bool: return hit_positions.size() == 3, "Picking up and throwing a sphere again can cause another hit")
	await _wait_for_physics(20)
	_check(victim.is_stunned(), "A new impact restarts the 0.5-second stun")
	await _wait_for_physics(14)
	_check(not victim.is_stunned() and torso.material_overlay == original_overlay, "Repeated hits eventually restore movement and appearance")

	# A dropped, unarmed object must not act like a thrown projectile.
	var harmless := apartment.get_node("Pickup2") as RigidBody3D
	harmless.freeze = false
	harmless.global_position = victim.global_position + Vector3(0, 1.0, 1.5)
	harmless.linear_velocity = Vector3.FORWARD * 8.0
	await _wait_for_physics(30)
	_check(hit_positions.size() == 3, "An object that was not thrown does not trigger a hit")
	if not failed:
		print("Projectile hit smoke test passed.")
	quit(int(failed))


func _launch(thrower: CharacterBody3D, victim: CharacterBody3D, item: RigidBody3D, ground_y: float) -> void:
	thrower.global_position = Vector3(6.5, ground_y, -1.25)
	thrower.rotation.y = 0
	victim.global_position = Vector3(6.5, ground_y, -3.05)
	thrower.hold_pickup(item)
	thrower.release_pickup(true, thrower.throw_velocity_at_speed(8.0))
	_check(thrower.held_pickup == null, "The projectile launches before testing impact")


func _expect(condition: Callable, message: String) -> void:
	for _frame in 90:
		if condition.call():
			return
		await physics_frame
	_check(false, message)


func _check(condition: bool, message: String) -> void:
	if not condition:
		failed = true
		push_error(message)


func _wait_for_physics(frames: int) -> void:
	for _frame in frames:
		await physics_frame
