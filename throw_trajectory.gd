extends MeshInstance3D

const MAX_STEPS := 120
const DASH_START_WIDTH := 0.16
const DASH_END_WIDTH := 0.06
const DASH_START_LENGTH := 0.26
const DASH_END_LENGTH := 0.08
const DASH_GAP_RATIO := 0.22
const HEAD_LENGTH := 0.3
const HEAD_WIDTH := 0.36
const THROW_COLLISION_MASK := 3

var points := PackedVector3Array()
var _line := ImmediateMesh.new()
var _material := StandardMaterial3D.new()
var _lengths := PackedFloat32Array()
var _view_direction := Vector3.BACK
var _fallback_side := Vector3.RIGHT


func _ready() -> void:
	top_level = true
	global_transform = Transform3D.IDENTITY
	mesh = _line
	cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	_material.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	_material.cull_mode = BaseMaterial3D.CULL_DISABLED
	material_override = _material
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
	# Arc length at each point, so dashes keep their size along the curved path.
	_lengths.resize(points.size())
	_lengths[0] = 0.0
	for index in range(1, points.size()):
		_lengths[index] = _lengths[index - 1] + points[index].distance_to(points[index - 1])
	var total := _lengths[-1]
	if total <= 0.001:
		visible = false
		return
	var camera := get_viewport().get_camera_3d()
	_view_direction = camera.global_basis.z if camera != null else Vector3.BACK
	_fallback_side = camera.global_basis.x if camera != null else Vector3.RIGHT
	_line.surface_begin(Mesh.PRIMITIVE_TRIANGLES)
	# Arrow.png style: dashes that shrink toward a triangular head at the impact point.
	var head_length := minf(HEAD_LENGTH, total)
	var body_end := total - head_length - DASH_GAP_RATIO * DASH_END_LENGTH
	var distance := 0.0
	while distance < body_end:
		var progress := distance / body_end
		var dash := lerpf(DASH_START_LENGTH, DASH_END_LENGTH, progress)
		var dash_end := minf(distance + dash, body_end)
		_add_dash(distance, dash_end, body_end)
		distance = dash_end + dash * DASH_GAP_RATIO
	var base := _point_at(total - head_length)
	var tip := points[-1]
	var side := _side_direction(tip - base) * HEAD_WIDTH * 0.5
	_line.surface_add_vertex(base - side)
	_line.surface_add_vertex(base + side)
	_line.surface_add_vertex(tip)
	_line.surface_end()
	visible = true


func _add_dash(from: float, to: float, body_end: float) -> void:
	var distances := PackedFloat32Array([from])
	for index in points.size():
		if _lengths[index] > from and _lengths[index] < to:
			distances.append(_lengths[index])
	distances.append(to)
	for index in range(distances.size() - 1):
		var start_distance := distances[index]
		var end_distance := distances[index + 1]
		var start := _point_at(start_distance)
		var end := _point_at(end_distance)
		var side := _side_direction(end - start)
		var start_side := side * _dash_width(start_distance, body_end) * 0.5
		var end_side := side * _dash_width(end_distance, body_end) * 0.5
		_line.surface_add_vertex(start - start_side)
		_line.surface_add_vertex(start + start_side)
		_line.surface_add_vertex(end + end_side)
		_line.surface_add_vertex(start - start_side)
		_line.surface_add_vertex(end + end_side)
		_line.surface_add_vertex(end - end_side)


func _dash_width(distance: float, body_end: float) -> float:
	return lerpf(DASH_START_WIDTH, DASH_END_WIDTH, clampf(distance / body_end, 0.0, 1.0))


func _side_direction(direction: Vector3) -> Vector3:
	var side := direction.cross(_view_direction)
	return _fallback_side if side.is_zero_approx() else side.normalized()


func _point_at(distance: float) -> Vector3:
	for index in range(1, points.size()):
		if _lengths[index] >= distance:
			var segment := _lengths[index] - _lengths[index - 1]
			var weight := 0.0 if segment <= 0.0 else (distance - _lengths[index - 1]) / segment
			return points[index - 1].lerp(points[index], weight)
	return points[-1]
