extends SceneTree

const PLAYER := preload("res://player.tscn")
const PICKUP := preload("res://pickup.tscn")
const PEEL := preload("res://assets/household_items/scenes/03-banana-peel.tscn")

var failed := false


func _initialize() -> void:
	call_deferred("_run")


func _run() -> void:
	var lab := Node3D.new()
	root.add_child(lab)
	var floor_body := StaticBody3D.new()
	var floor_collider := CollisionShape3D.new()
	var floor_shape := BoxShape3D.new()
	floor_shape.size = Vector3(30, 0.5, 30)
	floor_collider.shape = floor_shape
	floor_body.add_child(floor_collider)
	floor_body.position.y = -0.25
	lab.add_child(floor_body)
	var player := _player(lab, Vector3(-1.5, 0.02, 0))
	var other := _player(lab, Vector3(4, 0.02, 3))
	await _wait_for_physics(5)
	var torso := player.get_node("Torso") as MeshInstance3D
	var original_overlay := torso.material_overlay
	var hits: Array[int] = []
	player.hit_received.connect(func() -> void: hits.append(1))
	var banana := PICKUP.instantiate() as RigidBody3D
	lab.add_child(banana)
	var banana_id := banana.get_instance_id()
	var steps: Array[CharacterBody3D] = []
	player.banana_peel_stepped.connect(func() -> void: steps.append(player))
	banana.become_banana_peel(Transform3D(Basis.IDENTITY, Vector3(0, 0.005, 0)))
	var original_pose := banana.global_transform
	player.remote_input = Vector2.RIGHT
	await _expect(func() -> bool: return player.is_stunned(), "Walking onto a converted banana peel stuns the player", 45)
	var stopped_at := player.global_position
	_check(steps.size() == 1 and steps[0] == player, "A converted banana notifies the affected player exactly once on entry")
	await _wait_for_physics(2)
	_check(not banana.has_node("BananaPeel"), "The stepped-on banana peel disappears after being consumed")
	await _wait_for_physics(105)
	_check(player.is_stunned() and _horizontal_distance(player.global_position, stopped_at) < 0.01, "Held movement input leaves the player stationary for the first 1.75 seconds")
	_check(hits.is_empty() and torso.material_overlay == original_overlay, "Stepping on a peel does not cause a projectile hit or red flash")
	await _wait_for_physics(10)
	_check(player.is_stunned() and _horizontal_distance(player.global_position, stopped_at) < 0.01, "Movement remains blocked just before the two-second stun ends")
	await _wait_for_physics(45)
	_check(not player.is_stunned() and player.global_position.x > stopped_at.x + 1.0, "Movement resumes after the consumed peel's two-second stun")
	_check(steps.size() == 1, "A consumed peel does not keep renewing the stun")
	_check(is_instance_valid(banana) and banana.get_instance_id() == banana_id and banana.is_banana_peel and banana.global_transform.is_equal_approx(original_pose), "The converted rigid body's identity and pose remain stable for network snapshots")
	_check(not banana.is_in_group(&"pickups") and banana.collision_layer == 0 and banana.collision_mask == 0, "The invisible converted body remains unavailable for pickup or collisions")
	player.remote_input = Vector2.LEFT
	await _wait_for_physics(90)
	_check(steps.size() == 1 and not player.is_stunned() and player.global_position.x < stopped_at.x - 1.0, "Returning across the consumed peel does not trigger another stun")
	player.remote_input = Vector2.ZERO
	other.global_position = Vector3(0, 0.02, 0)
	await _wait_for_physics(5)
	_check(not other.is_stunned(), "Another player can cross the consumed peel without being stunned")
	other.global_position = Vector3(4, 0.02, 3)

	# The source asset works when placed directly, including players already over it.
	var direct_peel := PEEL.instantiate() as Area3D
	direct_peel.position = Vector3(4, 0.005, 3)
	var direct_steps: Array[CharacterBody3D] = []
	other.banana_peel_stepped.connect(func() -> void: direct_steps.append(other))
	other.apply_stun(2.5)
	lab.add_child(direct_peel)
	await _expect(func() -> bool: return not direct_steps.is_empty(), "A directly placed peel detects an already overlapping second player", 10)
	_check(direct_steps.size() == 1 and direct_steps[0] == other, "The hazard affects either player, independently of who threw it")
	await _wait_for_physics(2)
	_check(not is_instance_valid(direct_peel), "A directly placed peel also disappears after its first use")
	var other_stopped_at := other.global_position
	other.remote_input = Vector2.RIGHT
	await _wait_for_physics(125)
	_check(other.is_stunned() and _horizontal_distance(other.global_position, other_stopped_at) < 0.01, "A peel does not shorten an existing 2.5-second stun")
	await _wait_for_physics(40)
	_check(not other.is_stunned() and other.global_position.x > other_stopped_at.x + 0.1, "Movement also resumes when the longer existing stun expires")
	_check(direct_steps.size() == 1, "A directly placed peel triggers only once")
	other.remote_input = Vector2.ZERO

	# Two body-entered signals can arrive before deferred removal finishes.
	var first_racer := _player(lab, Vector3(8, 0.02, 0))
	var second_racer := _player(lab, Vector3(8, 0.02, 0))
	first_racer.add_collision_exception_with(second_racer)
	second_racer.add_collision_exception_with(first_racer)
	var simultaneous_steps: Array[CharacterBody3D] = []
	first_racer.banana_peel_stepped.connect(func() -> void: simultaneous_steps.append(first_racer))
	second_racer.banana_peel_stepped.connect(func() -> void: simultaneous_steps.append(second_racer))
	var shared_peel := PEEL.instantiate() as Area3D
	shared_peel.position = Vector3(8, 0.005, 0)
	lab.add_child(shared_peel)
	await _expect(func() -> bool: return not simultaneous_steps.is_empty(), "An overlapping player consumes a new peel", 10)
	await _wait_for_physics(3)
	_check(simultaneous_steps.size() == 1 and first_racer.is_stunned() != second_racer.is_stunned(), "A peel shared by two simultaneous entrants stuns exactly one player")
	_check(not is_instance_valid(shared_peel), "Simultaneous entry removes the shared peel")
	await _wait_for_physics(125)
	_check(simultaneous_steps.size() == 1 and not first_racer.is_stunned() and not second_racer.is_stunned(), "The single stun expires without affecting the other overlapping player")
	lab.free()
	if not failed:
		print("Banana peel stun smoke test passed.")
	quit(int(failed))


func _player(parent: Node3D, position: Vector3) -> CharacterBody3D:
	var player := PLAYER.instantiate() as CharacterBody3D
	player.reads_local_input = false
	player.position = position
	parent.add_child(player)
	return player


func _horizontal_distance(first: Vector3, second: Vector3) -> float:
	return Vector2(first.x, first.z).distance_to(Vector2(second.x, second.z))


func _expect(condition: Callable, message: String, max_frames: int) -> void:
	for _frame in max_frames:
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
