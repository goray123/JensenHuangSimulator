extends MeshInstance3D

const MAX_STEPS := 120
const LINE_WIDTH := 0.06
const THROW_COLLISION_MASK := 3

var points := PackedVector3Array()
var _line := ImmediateMesh.new()
var _impact := MeshInstance3D.new()
var _material := StandardMaterial3D.new()


func _ready() -> void:
	top_level = true
	global_transform = Transform3D.IDENTITY
	mesh = _line
	cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	_material.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	_material.cull_mode = BaseMaterial3D.CULL_DISABLED
	material_override = _material
	var marker := SphereMesh.new()
	marker.radius = 0.09
	marker.height = 0.18
	_impact.mesh = marker
	_impact.material_override = _material
	_impact.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	add_child(_impact)
	clear_trajectory()


func clear_trajectory() -> void:
	visible = false
	points.clear()
	_line.clear_surfaces()


func update_trajectory(player: CharacterBody3D, pickup: RigidBody3D, launch_velocity: Vector3, launch_transform: Transform3D) -> void:
	var step := 1.0 / Engine.physics_ticks_per_second
	var gravity := player.get_gravity() * pickup.gravity_scale
	var position := launch_transform.origin
	var flight_velocity := launch_velocity
	var query := PhysicsShapeQueryParameters3D.new()
	var collider := pickup.get_node("CollisionShape3D") as CollisionShape3D
	query.shape = collider.shape
	query.transform = launch_transform * collider.transform
	query.collision_mask = THROW_COLLISION_MASK
	query.exclude = [player.get_rid(), pickup.get_rid()]
	var space := get_world_3d().direct_space_state
	points.clear()
	points.append(position)
	var collider_offset := query.transform.origin - position
	if not space.intersect_shape(query, 1).is_empty():
		_material.albedo_color = Color(1.0, 0.3, 0.15)
		var indicator_direction := Vector3.UP if launch_velocity.is_zero_approx() else launch_velocity.normalized()
		points.append(position + indicator_direction * 0.15)
		_draw_trajectory()
		return
	_material.albedo_color = Color(0.2, 1.0, 0.9)
	for _step in MAX_STEPS:
		# Pickups use zero linear damping, matching this ballistic integration.
		flight_velocity += gravity * step
		var motion := flight_velocity * step
		query.transform.origin = position + collider_offset
		query.motion = motion
		var fractions := space.cast_motion(query)
		position += motion * fractions[0]
		points.append(position)
		if fractions[0] < 1.0:
			break
	_draw_trajectory()


func _draw_trajectory() -> void:
	_line.clear_surfaces()
	if points.size() < 2:
		visible = false
		return
	_line.surface_begin(Mesh.PRIMITIVE_TRIANGLES)
	var camera := get_viewport().get_camera_3d()
	var view_direction := camera.global_basis.z if camera != null else Vector3.FORWARD
	for index in range(points.size() - 1):
		var start := points[index]
		var end := points[index + 1]
		var side_direction := (end - start).cross(view_direction)
		if side_direction.is_zero_approx():
			side_direction = camera.global_basis.x if camera != null else Vector3.RIGHT
		var side := side_direction.normalized() * LINE_WIDTH * 0.5
		_line.surface_add_vertex(start - side)
		_line.surface_add_vertex(start + side)
		_line.surface_add_vertex(end + side)
		_line.surface_add_vertex(start - side)
		_line.surface_add_vertex(end + side)
		_line.surface_add_vertex(end - side)
	_line.surface_end()
	_impact.position = points[-1]
	visible = true
