extends RigidBody3D

signal banana_landed(landing_transform: Transform3D)
signal banana_peel_consumed

const OUTLINE_MATERIAL := preload("res://pickup_outline.tres")
const BANANA_PEEL := preload("res://assets/household_items/scenes/03-banana-peel.tscn")
const BANANA_ID := "01-banana"
const FLOOR_SUPPORT_DOT := 0.7
const PEEL_FLOOR_OFFSET := 0.005
const RELEASE_CLEARANCE := 0.02

var is_banana_peel := false
var is_banana_peel_consumed := false
var _armed := false
var _thrower_id := 0
var _hit_players: Array[int] = []
var _outline_meshes: Array[MeshInstance3D] = []
var _flight_generation := 0
var _banana_land_pending := false
var _banana_landing_yaw := 0.0


func _ready() -> void:
	contact_monitor = true
	max_contacts_reported = 8
	body_entered.connect(_on_body_entered)
	sleeping_state_changed.connect(_on_sleeping_state_changed)


func _physics_process(_delta: float) -> void:
	if freeze or not multiplayer.is_server():
		return
	var exceptions := get_collision_exceptions()
	if exceptions.is_empty():
		return
	var bounds := _world_collision_bounds(self)
	if not bounds.has_volume():
		return
	for body in exceptions:
		if not is_instance_valid(body):
			continue
		var other_bounds := _world_collision_bounds(body)
		if other_bounds.has_volume() and not bounds.intersects(other_bounds):
			# Keep launch protection until the shapes have actually separated.
			# This also runs while sleeping so walking away from a dropped item
			# restores its collision before the player returns to push it.
			remove_collision_exception_with(body)


func _world_collision_bounds(body: PhysicsBody3D) -> AABB:
	var bounds := AABB()
	var has_shape := false
	for child in body.get_children():
		if child is CollisionShape3D and child.shape != null and not child.disabled:
			var shape_bounds: AABB = child.global_transform * child.shape.get_debug_mesh().get_aabb()
			bounds = bounds.merge(shape_bounds) if has_shape else shape_bounds
			has_shape = true
	return bounds.grow(RELEASE_CLEARANCE) if has_shape else AABB()


func set_pickup_highlighted(highlighted: bool) -> void:
	if is_banana_peel:
		return
	if highlighted and _outline_meshes.is_empty():
		# Imported props receive their models after _ready(), so build on demand.
		var meshes := find_children("*", "MeshInstance3D", true, false)
		for source: MeshInstance3D in meshes:
			if source.mesh == null:
				continue
			var outline := MeshInstance3D.new()
			outline.name = "PickupOutline"
			outline.mesh = source.mesh
			outline.material_override = OUTLINE_MATERIAL
			outline.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
			outline.extra_cull_margin = 0.05
			source.add_child(outline)
			_outline_meshes.append(outline)
	for outline in _outline_meshes:
		outline.visible = highlighted


func arm(thrower: PhysicsBody3D) -> void:
	if is_banana_peel:
		return
	_flight_generation += 1
	_banana_land_pending = false
	_thrower_id = thrower.get_instance_id()
	_hit_players.clear()
	_armed = true
	var heading := Vector3(linear_velocity.x, 0, linear_velocity.z)
	if heading.is_zero_approx():
		heading = -global_basis.z
	_banana_landing_yaw = atan2(-heading.x, -heading.z)


func disarm() -> void:
	_flight_generation += 1
	_banana_land_pending = false
	_armed = false
	_hit_players.clear()


func _integrate_forces(state: PhysicsDirectBodyState3D) -> void:
	if not _armed or is_banana_peel or _banana_land_pending or not multiplayer.is_server():
		return
	if get_meta(&"item_id", "") != BANANA_ID:
		return
	for index in state.get_contact_count():
		var floor_body := state.get_contact_collider_object(index) as Node
		if floor_body == null or not floor_body.is_in_group(&"map_floor"):
			continue
		# Contact normals are in world coordinates, even for a tumbling banana.
		if state.get_contact_local_normal(index).dot(Vector3.UP) < FLOOR_SUPPORT_DOT:
			continue
		var landing_position := state.get_contact_collider_position(index)
		landing_position.y += PEEL_FLOOR_OFFSET
		var landing_transform := Transform3D(Basis(Vector3.UP, _banana_landing_yaw), landing_position)
		_banana_land_pending = true
		_finish_banana_landing.call_deferred(landing_transform, _flight_generation)
		return


func _finish_banana_landing(landing_transform: Transform3D, generation: int) -> void:
	# Picking the banana up again cancels an already queued landing conversion.
	if is_banana_peel or not _armed or not _banana_land_pending or generation != _flight_generation:
		return
	become_banana_peel(landing_transform)
	banana_landed.emit(landing_transform)


func become_banana_peel(landing_transform: Transform3D) -> void:
	if is_banana_peel:
		return
	set_pickup_highlighted(false)
	_outline_meshes.clear()
	is_banana_peel = true
	disarm()
	freeze = true
	linear_velocity = Vector3.ZERO
	angular_velocity = Vector3.ZERO
	collision_layer = 0
	collision_mask = 0
	remove_from_group(&"pickups")
	for child in get_children():
		if child is CollisionShape3D:
			child.disabled = true
		elif child is Node3D:
			child.visible = false
	global_transform = landing_transform
	var peel := BANANA_PEEL.instantiate() as Area3D
	peel.name = "BananaPeel"
	peel.collision_mask = 1
	# Converted bodies can have different parent paths on the two peers.
	# The apartment replicates consumption using their stable pickup index.
	peel.sync_consumption_directly = false
	peel.consumed.connect(consume_banana_peel)
	add_child(peel)
	set_meta(&"item_id", "03-banana-peel")
	set_meta(&"pickup_name", "바나나껍질")


func consume_banana_peel() -> void:
	if is_banana_peel_consumed:
		return
	is_banana_peel_consumed = true
	is_banana_peel = true
	disarm()
	freeze = true
	linear_velocity = Vector3.ZERO
	angular_velocity = Vector3.ZERO
	collision_layer = 0
	collision_mask = 0
	remove_from_group(&"pickups")
	hide()
	var peel := get_node_or_null("BananaPeel")
	if peel != null:
		peel.consume()
	banana_peel_consumed.emit()


func _on_body_entered(body: Node) -> void:
	if not _armed or not multiplayer.is_server() or not body.has_method(&"receive_hit"):
		return
	var player_id := body.get_instance_id()
	if player_id == _thrower_id or player_id in _hit_players:
		return
	_hit_players.append(player_id)
	body.receive_hit()


func _on_sleeping_state_changed() -> void:
	if sleeping:
		# Allow contacts from the same physics tick to finish before disarming.
		_disarm_if_sleeping.call_deferred()


func _disarm_if_sleeping() -> void:
	if sleeping and not _banana_land_pending:
		disarm()
