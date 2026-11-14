extends SceneTree

const PLAYER := preload("res://player.tscn")
const PICKUP := preload("res://tests/pickup_fixture.tscn")
const PEEL := preload("res://assets/household_items/scenes/03-banana-peel.tscn")
const CHARACTER_MODELS := [
	preload("res://assets/characters/thump/03_Young.glb"),
	preload("res://assets/characters/thump/02_Woman.glb"),
	preload("res://assets/characters/thump/01_Elder.glb"),
]

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
	var torso := player._body_meshes[0] as MeshInstance3D
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
	var stopped_basis := player.global_basis
	var collision_pose := player.get_node("CollisionShape3D").transform as Transform3D
	_check(steps.size() == 1 and steps[0] == player, "A converted banana notifies the affected player exactly once on entry")
	_check(player.is_slipping(), "A physically consumed converted peel starts the backward fall")
	await _wait_for_physics(2)
	_check(not banana.has_node("BananaPeel"), "The stepped-on banana peel disappears after being consumed")
	await _wait_for_physics(25)
	_check(_is_lying_backwards(player), "The consumed peel tips the character backwards relative to its facing direction")
	_check(player.global_basis.is_equal_approx(stopped_basis) and player.get_node("CollisionShape3D").transform.is_equal_approx(collision_pose), "The backward fall preserves the player heading and capsule transform")
	var nearby_item := PICKUP.instantiate() as RigidBody3D
	nearby_item.freeze = true
	lab.add_child(nearby_item)
	nearby_item.global_position = stopped_at + Vector3(0, 0.2, 0.5)
	var grab_requests: Array[int] = []
	player.pickup_request_handler = func(_actor, _begin = false, _pickup = null) -> void: grab_requests.append(1)
	player.reads_local_input = true
	_action(player, &"interact", true)
	_action(player, &"interact", false)
	_check(not player.can_grab(nearby_item) and player._grab_elapsed < 0.0 and grab_requests.is_empty(), "A fallen empty-handed player cannot begin picking up a reachable item")
	player.reads_local_input = false
	player.pickup_request_handler = Callable()
	nearby_item.queue_free()
	await _wait_for_physics(80)
	_check(player.is_stunned() and _horizontal_distance(player.global_position, stopped_at) < 0.01, "Held movement input leaves the player stationary for the first 1.75 seconds")
	_check(hits.is_empty() and torso.material_overlay == original_overlay, "Stepping on a peel does not cause a projectile hit or red flash")
	await _wait_for_physics(10)
	_check(player.is_stunned() and _horizontal_distance(player.global_position, stopped_at) < 0.01, "Movement remains blocked just before the two-second stun ends")
	await _wait_for_physics(45)
	_check(not player.is_stunned() and player.global_position.x > stopped_at.x + 1.0, "Movement resumes after the consumed peel's two-second stun")
	_check(not player.is_slipping() and player._model.transform.is_equal_approx(player._model_rest_transform), "The model returns to its normal standing transform when the peel stun ends")
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
	_check(other.is_slipping() and _is_lying_backwards(other), "A pre-existing longer stun keeps the character lying down beyond two seconds")
	await _wait_for_physics(40)
	_check(not other.is_stunned() and other.global_position.x > other_stopped_at.x + 0.1, "Movement also resumes when the longer existing stun expires")
	_check(not other.is_slipping() and other._model.transform.is_equal_approx(other._model_rest_transform), "The longer stun also restores the original standing pose")
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
	for model: PackedScene in CHARACTER_MODELS:
		await _check_character_slip(lab, model)
	lab.free()
	if not failed:
		print("Banana peel stun smoke test passed.")
	quit(int(failed))


func _check_character_slip(lab: Node3D, model: PackedScene) -> void:
	var label := model.resource_path.get_file()
	var player := _player(lab, Vector3(-6, 0.02, -6), model)
	player.rotation.y = 0.8
	await _wait_for_physics(5)
	var standing_root := player.global_transform
	var collider := player.get_node("CollisionShape3D") as CollisionShape3D
	var capsule_pose := collider.transform
	var capsule_shape := collider.shape
	var item := PICKUP.instantiate() as RigidBody3D
	lab.add_child(item)
	player.hold_pickup(item)
	player.reads_local_input = true
	Input.action_press(&"interact")
	_action(player, &"interact", true)
	await _wait_for_physics(3)
	_check(player._is_aiming and player.get_node("ThrowTrajectory").visible, label + ": aiming is active before stepping on a peel")
	var bag_requests: Array[int] = []
	var hit_events: Array[int] = []
	player.bag_requested.connect(func() -> void: bag_requests.append(1))
	player.hit_received.connect(func() -> void: hit_events.append(1))
	var peel := PEEL.instantiate() as Area3D
	peel.position = Vector3(-6, 0.005, -6)
	lab.add_child(peel)
	await _expect(func() -> bool: return player.is_slipping(), label + ": actual peel overlap starts a fall", 10)
	_check(player.is_stunned() and not player._is_aiming and not player.get_node("ThrowTrajectory").visible, label + ": slipping cancels aiming and its trajectory")
	_action(player, &"interact", false)
	_action(player, &"interact", true)
	_action(player, &"bag_item", true)
	_action(player, &"interact", false)
	_check(not player._is_aiming and bag_requests.is_empty() and player.held_pickup == item and item.get_parent() == player.get_node("HandSocket"), label + ": aiming, throwing, and bag input stay blocked while the held item is preserved")
	Input.action_release(&"interact")
	player.reads_local_input = false
	player.remote_input = Vector2.RIGHT
	await _wait_for_physics(25)
	_check(_is_lying_backwards(player), label + ": the character lies backwards while movement is blocked")
	_check(player.global_transform.is_equal_approx(standing_root) and collider.transform.is_equal_approx(capsule_pose) and collider.shape == capsule_shape, label + ": falling changes only the model, preserving the root and collision capsule")
	_check(hit_events.is_empty() and is_zero_approx(player._flash_remaining), label + ": a fall adds no projectile hit or red flash")
	await _wait_for_physics(105)
	_check(not player.is_slipping() and not player.is_stunned() and player._model.transform.is_equal_approx(player._model_rest_transform), label + ": the model stands up with its original transform after recovery")
	_check(player.global_position.x > standing_root.origin.x + 0.05, label + ": held movement resumes after the fall")
	_check(player.held_pickup == item, label + ": the original item remains held after recovery")
	player.free()
	await _wait_for_physics(2)


func _is_lying_backwards(player: CharacterBody3D) -> bool:
	return player._model.global_basis.y.normalized().dot(player.global_basis.z.normalized()) > 0.8


func _action(player: CharacterBody3D, action: StringName, pressed: bool) -> void:
	var event := InputEventAction.new()
	event.action = action
	event.pressed = pressed
	player._unhandled_input(event)


func _player(parent: Node3D, position: Vector3, model: PackedScene = null) -> CharacterBody3D:
	var player := PLAYER.instantiate() as CharacterBody3D
	if model != null:
		player.model_scene = model
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
