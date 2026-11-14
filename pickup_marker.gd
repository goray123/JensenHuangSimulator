extends MeshInstance3D
## A local selection cue that stays upright above a pickup, even when it tips over.

const HEIGHT := 0.18
const RADIUS := 0.105
const TIP_GAP := 0.16
const ROTATION_SPEED := deg_to_rad(100.0)

var body: RigidBody3D
var _spin := 0.0


func _ready() -> void:
	top_level = true
	cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	var pyramid := CylinderMesh.new()
	pyramid.top_radius = RADIUS
	pyramid.bottom_radius = 0.0
	pyramid.height = HEIGHT
	pyramid.radial_segments = 4
	pyramid.rings = 1
	mesh = pyramid
	var material := StandardMaterial3D.new()
	material.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	material.albedo_color = Color(0.04, 0.4, 1.0)
	material_override = material
	set_active(false)


func set_active(active: bool) -> void:
	visible = active
	set_process(active)
	if active:
		_update_transform()


func _process(delta: float) -> void:
	if not is_instance_valid(body) or not body.is_visible_in_tree() or not body.is_in_group(&"pickups"):
		set_active(false)
		return
	_spin = fposmod(_spin + ROTATION_SPEED * delta, TAU)
	_update_transform()


func _update_transform() -> void:
	if not is_instance_valid(body):
		set_active(false)
		return
	var collider := body.get_node_or_null("CollisionShape3D") as CollisionShape3D
	if collider == null or collider.shape == null:
		set_active(false)
		return
	# Bounds come from the real collider, so outlines and this cue cannot enlarge them.
	var bounds := collider.global_transform * collider.shape.get_debug_mesh().get_aabb()
	var center := bounds.get_center()
	var above := Vector3(center.x, bounds.end.y + TIP_GAP + HEIGHT * 0.5, center.z)
	global_transform = Transform3D(Basis(Vector3.UP, _spin), above)
