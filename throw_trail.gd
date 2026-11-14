extends MeshInstance3D
## Fading ribbon behind a flying pickup. It watches the body's own motion instead of the
## throw event, so it looks the same on the host and on a guest that only gets snapshots.
## It lives beside the pickup, not under it, so outline and mesh lookups never see it.

const TRAIL_SECONDS := 0.3
## Horizontal speed (m/s) that counts as flying; drops and falls stay well below it.
const MIN_SPEED := 2.5
## Keeps the trail alive between snapshots that arrive slower than frames.
const LINGER_SECONDS := 0.12
## Bigger jumps are teleports (drops, corrections), not flight.
const MAX_STEP := 1.5
const COLOR := Color(1.0, 1.0, 1.0, 0.9)

var body: RigidBody3D

var _center := Vector3.ZERO
var _width := 0.15
var _points := PackedVector3Array()
var _times := PackedFloat64Array()
var _last_position := Vector3.ZERO
var _last_move_time := 0.0
var _active_until := -1.0
var _line := ImmediateMesh.new()
var _drawn := false


func _ready() -> void:
	top_level = true
	global_transform = Transform3D.IDENTITY
	mesh = _line
	cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	var material := StandardMaterial3D.new()
	material.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	material.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
	material.cull_mode = BaseMaterial3D.CULL_DISABLED
	material.vertex_color_use_as_albedo = true
	material_override = material
	var collider := body.get_node_or_null("CollisionShape3D") as CollisionShape3D
	if collider != null and collider.shape != null:
		var bounds := collider.transform * collider.shape.get_debug_mesh().get_aabb()
		_center = bounds.get_center()
		_width = clampf(bounds.size.length() * 0.5, 0.14, 0.35)
	_last_position = body.global_transform * _center


func _process(_delta: float) -> void:
	if not is_instance_valid(body):
		queue_free()
		return
	var now := Time.get_ticks_msec() / 1000.0
	# Held and bagged pickups leave the group, so only loose bodies can trail.
	var loose := body.is_in_group(&"pickups") and body.is_visible_in_tree()
	var position := body.global_transform * _center
	if position != _last_position:
		var step := position - _last_position
		var elapsed := now - _last_move_time
		if step.length() > MAX_STEP:
			_points.clear()
			_times.clear()
		elif loose and elapsed > 0.0 and Vector2(step.x, step.z).length() / elapsed >= MIN_SPEED:
			_active_until = now + LINGER_SECONDS
		_last_position = position
		_last_move_time = now
		if loose and now < _active_until:
			_points.append(position)
			_times.append(now)
	if not loose:
		_points.clear()
		_times.clear()
	var expired := 0
	while expired < _times.size() and now - _times[expired] > TRAIL_SECONDS:
		expired += 1
	if expired > 0:
		_points = _points.slice(expired)
		_times = _times.slice(expired)
	_redraw(now)


func _redraw(now: float) -> void:
	if _drawn:
		_line.clear_surfaces()
		_drawn = false
	if _points.size() < 2:
		return
	var camera := get_viewport().get_camera_3d()
	var view_direction := camera.global_basis.z if camera != null else Vector3.BACK
	var vertices := PackedVector3Array()
	var colors := PackedColorArray()
	for index in _points.size():
		var previous := _points[maxi(index - 1, 0)]
		var next := _points[mini(index + 1, _points.size() - 1)]
		var side := (next - previous).cross(view_direction)
		if side.is_zero_approx():
			continue
		# Newest points are widest and most opaque; older ones taper and fade out.
		var freshness := clampf(1.0 - (now - _times[index]) / TRAIL_SECONDS, 0.0, 1.0)
		var half := side.normalized() * _width * 0.5 * freshness
		var color := COLOR
		color.a *= freshness
		vertices.append_array([_points[index] - half, _points[index] + half])
		colors.append_array([color, color])
	if vertices.size() < 4:
		return
	_line.surface_begin(Mesh.PRIMITIVE_TRIANGLE_STRIP)
	for index in vertices.size():
		_line.surface_set_color(colors[index])
		_line.surface_add_vertex(vertices[index])
	_line.surface_end()
	_drawn = true
