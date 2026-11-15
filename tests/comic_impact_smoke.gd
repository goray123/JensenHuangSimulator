extends SceneTree

const COMIC := preload("res://comic_impact.gd")
const THROWABLE := preload("res://throwable.gd")
const PLAYER := preload("res://player.tscn")

class ImpactLab extends Node3D:
	var reports: Array[Dictionary] = []
	func broadcast_prop_impact(_pickup: RigidBody3D, _sound: StringName) -> void:
		pass
	func broadcast_comic_impact(at: Vector3, strength: float = 1.0) -> void:
		reports.append({"position": at, "strength": strength})
	func log_attack(_pickup: RigidBody3D, _victim: Node3D) -> void:
		pass
	func reward_thrower(_thrower: Node3D) -> void:
		pass
	func drop_hit_items(_victim: Node3D, _power: int) -> void:
		pass

class HitTarget extends StaticBody3D:
	var hits := 0
	func receive_hit() -> void:
		hits += 1

var failed := false


func _initialize() -> void:
	_run.call_deferred()


func _run() -> void:
	await _physical_contacts()
	await _player_collisions()
	await _stage_and_visuals()
	if not failed:
		print("Comic impact smoke test passed.")
	quit(int(failed))


func _physical_contacts() -> void:
	var lab := ImpactLab.new()
	lab.name = "ComicContactLab"
	root.add_child(lab)
	_box(lab, "Floor", Vector3(0, -0.25, 0), Vector3(40, 0.5, 40)).add_to_group(&"map_floor")
	var owner := PLAYER.instantiate() as CharacterBody3D
	owner.reads_local_input = false
	owner.position = Vector3(-8, 0.02, 8)
	lab.add_child(owner)
	await _frames(5)

	var ordinary := _sphere(lab, Vector3(0, 1.4, 0))
	await _frames(70)
	_check(lab.reports.is_empty(), "An ordinary falling or resting pickup does not create comic impacts")
	ordinary.free()

	var dropped_throw := _sphere(lab, Vector3(0, 1.4, 0))
	dropped_throw.arm(owner)
	await _expect(func() -> bool: return not lab.reports.is_empty(), "A thrown object creates an impact on a real floor contact")
	if not lab.reports.is_empty():
		_check(absf((lab.reports[0]["position"] as Vector3).y) < 0.15, "The floor burst uses the actual contact surface")
	dropped_throw.free()
	await _frames(2)
	lab.reports.clear()
	var banana := _sphere(lab, Vector3(0, 1.4, 0))
	banana.set_meta(&"item_id", "01-banana")
	banana.arm(owner)
	await _expect(func() -> bool: return banana.is_banana_peel, "A thrown banana still converts at its real floor contact")
	await _frames(2)
	_check(lab.reports.size() == 1, "A banana's immediate peel conversion retains exactly one floor burst")
	banana.free()
	await _frames(2)
	lab.reports.clear()

	var wall := _box(lab, "Wall", Vector3(4, 1, 0), Vector3(0.3, 2, 3))
	var wall_throw := _sphere(lab, Vector3(2, 1, 0), Vector3.RIGHT * 6.0)
	wall_throw.gravity_scale = 0.0
	wall_throw.arm(owner)
	await _expect(func() -> bool: return not lab.reports.is_empty(), "A thrown object creates an impact on a real wall contact")
	if not lab.reports.is_empty():
		_check(absf((lab.reports[0]["position"] as Vector3).x - 3.85) < 0.16, "The wall burst is placed at the wall face")
	wall_throw.free()
	wall.free()
	await _frames(2)
	lab.reports.clear()

	var prop := RigidBody3D.new()
	prop.mass = 8.0
	prop.gravity_scale = 0.0
	prop.collision_layer = 2
	prop.collision_mask = 3
	_shape(prop, Vector3.ONE)
	lab.add_child(prop)
	prop.position = Vector3(0, 1, -6)
	var prop_throw := _sphere(lab, Vector3(-2, 1, -6), Vector3.RIGHT * 6.0)
	prop_throw.gravity_scale = 0.0
	prop_throw.arm(owner)
	await _expect(func() -> bool: return not lab.reports.is_empty(), "A real thrown-object collision with a movable prop creates an impact")
	await _frames(3)
	_check(prop.linear_velocity.x > 0.02, "The comic effect preserves the collision's physical impulse")
	prop_throw.free()
	prop.free()
	await _frames(2)
	lab.reports.clear()

	var victim := HitTarget.new()
	_shape(victim, Vector3(0.6, 1.2, 0.6))
	lab.add_child(victim)
	victim.position = Vector3(0, 0.6, 6)
	var player_throw := _sphere(lab, Vector3(-2, 0.6, 6), Vector3.RIGHT * 6.0)
	player_throw.gravity_scale = 0.0
	player_throw.arm(owner)
	await _expect(func() -> bool: return victim.hits > 0, "The physical player hit retains its gameplay reaction")
	await _frames(2)
	_check(victim.hits == 1 and lab.reports.size() == 1, "One valid player hit creates exactly one comic burst")
	player_throw.free()
	victim.free()
	await _frames(2)
	lab.reports.clear()

	var returning := _sphere(lab, Vector3(-10, 0.6, 8), Vector3.RIGHT * 6.0)
	returning.gravity_scale = 0.0
	returning.arm(owner)
	var touched_owner := [false]
	returning.body_entered.connect(func(body: Node) -> void: touched_owner[0] = touched_owner[0] or body == owner)
	await _expect(func() -> bool: return touched_owner[0], "The returning projectile makes a real contact with its thrower")
	await _frames(2)
	_check(lab.reports.size() == 1 and not owner.is_stunned(), "A returning projectile shows its physical impact while retaining the thrower's damage immunity")
	lab.free()
	await process_frame


func _player_collisions() -> void:
	var lab := Node3D.new()
	root.add_child(lab)
	_box(lab, "Floor", Vector3(0, -0.25, 0), Vector3(40, 0.5, 40))
	_box(lab, "StrongWall", Vector3(12, 1, 0), Vector3(0.3, 2, 3))
	_box(lab, "GlancingWall", Vector3(16, 1, 0), Vector3(0.3, 2, 3))
	var player := PLAYER.instantiate() as CharacterBody3D
	player.reads_local_input = false
	player.position = Vector3(10.8, 0.02, 0)
	var reports: Array[Vector3] = []
	player.strong_collision.connect(func(at: Vector3, _strength: float) -> void: reports.append(at))
	lab.add_child(player)
	await _frames(8)
	_check(reports.is_empty(), "Standing on the floor does not count as a hard collision")
	player.remote_input = Vector2.RIGHT
	await _expect(func() -> bool: return reports.size() == 1, "Walking directly into a wall emits a strong player collision")
	await _frames(70)
	_check(reports.size() == 1, "Keeping movement held against a wall does not spam bursts")
	player.remote_input = Vector2.LEFT
	await _frames(40)
	player.remote_input = Vector2.RIGHT
	await _expect(func() -> bool: return reports.size() == 2, "Separating and hitting the wall again creates a fresh impact")
	player.remote_input = Vector2.ZERO
	player.position = Vector3(15.4, 0.02, -0.8)
	player.velocity = Vector3.ZERO
	await _frames(15)
	player.remote_input = Vector2(0.2, 1.0)
	await _frames(50)
	_check(player.get_slide_collision_count() > 0 and reports.size() == 2, "A gentle glancing slide along a wall does not trigger the hard-impact effect")
	lab.free()
	await process_frame


func _stage_and_visuals() -> void:
	var house := preload("res://house.tscn").instantiate()
	root.add_child(house)
	for body: RigidBody3D in house._physics_bodies:
		body.freeze = true
	house.get_node("Player").set_physics_process(false)
	house.get_node("RoundTimer").stop()
	await _frames(2)
	var point := Vector3(6.5, 1.0, -2.3)
	house.broadcast_comic_impact(point, 1.0)
	var effects := _effects(house)
	_check(effects.size() == 1, "The actual offline stage gateway creates one impact")
	if effects.is_empty():
		house.free()
		return
	var effect: CanvasLayer = effects[0]
	var drawing := effect.get_node("Burst") as Control
	_check(effect.world_position.is_equal_approx(point) and effect.scale_progress < 0.05, "A new effect starts at a point at the reported contact")
	_check(drawing.mouse_filter == Control.MOUSE_FILTER_IGNORE and drawing.focus_mode == Control.FOCUS_NONE, "The effect never captures gameplay input")
	await create_timer(COMIC.LIFETIME * 0.25).timeout
	_check(is_instance_valid(effect) and effect.scale_progress > 0.9 and effect.screen_visible, "The burst expands visibly from its contact point")
	if is_instance_valid(effect):
		var projected := root.get_camera_3d().unproject_position(point)
		_check(effect.screen_position.distance_to(projected) < 1.0, "The burst remains pinned to the contact through camera projection")
	await create_timer(COMIC.LIFETIME * 0.5).timeout
	_check(is_instance_valid(effect) and drawing.modulate.a > 0.0 and drawing.modulate.a < 0.95, "The expanded burst fades before expiring")
	await create_timer(COMIC.LIFETIME * 0.5).timeout
	_check(not is_instance_valid(effect) and _effects(house).is_empty(), "The burst frees itself completely after its short lifetime")

	var variants: Dictionary = {}
	for index in 12:
		house.broadcast_comic_impact(point + Vector3.RIGHT * index, 1.0)
	for burst in _effects(house):
		variants[burst.variant] = true
		_check(burst.variant >= 0 and burst.variant < COMIC.VARIANT_COUNT, "Stage-selected random variants stay in the supported range")
	_check(variants.size() > 1, "Repeated contacts randomly select more than one comic variation")
	for index in COMIC.MAX_ACTIVE + 8:
		COMIC.spawn(house, point, index, 1.0)
	await process_frame
	_check(_effects(house).size() <= COMIC.MAX_ACTIVE, "A collision pileup stays within the live-effect cap")
	house.free()
	await process_frame
	_check(get_nodes_in_group(&"comic_impacts").is_empty(), "Leaving the stage also removes every active impact")


func _sphere(parent: Node3D, at: Vector3, speed := Vector3.ZERO) -> RigidBody3D:
	var body := THROWABLE.new()
	body.collision_layer = 2
	body.collision_mask = 3
	body.mass = 0.2
	body.continuous_cd = true
	body.linear_damp_mode = RigidBody3D.DAMP_MODE_REPLACE
	body.linear_damp = 0.0
	var collider := CollisionShape3D.new()
	var shape := SphereShape3D.new()
	shape.radius = 0.12
	collider.shape = shape
	body.add_child(collider)
	parent.add_child(body)
	body.position = at
	body.linear_velocity = speed
	return body


func _box(parent: Node3D, node_name: String, at: Vector3, size: Vector3) -> StaticBody3D:
	var body := StaticBody3D.new()
	body.name = node_name
	_shape(body, size)
	parent.add_child(body)
	body.position = at
	return body


func _shape(body: PhysicsBody3D, size: Vector3) -> void:
	var collider := CollisionShape3D.new()
	var shape := BoxShape3D.new()
	shape.size = size
	collider.shape = shape
	body.add_child(collider)


func _effects(parent: Node) -> Array[Node]:
	return get_nodes_in_group(&"comic_impacts").filter(func(node: Node) -> bool: return node.get_parent() == parent and not node.is_queued_for_deletion())


func _expect(condition: Callable, message: String, frames := 100) -> void:
	for _frame in frames:
		if condition.call():
			return
		await physics_frame
	_check(false, message)


func _check(condition: bool, message: String) -> void:
	if not condition:
		failed = true
		push_error(message)


func _frames(count: int) -> void:
	for _frame in count:
		await physics_frame
