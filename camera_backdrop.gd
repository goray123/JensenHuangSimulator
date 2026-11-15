extends MeshInstance3D
## Screen-filling gradient drawn as an unshaded quad near the parent camera's far plane.
## Replaces Environment.BG_CANVAS, which flickers to the grey clear colour in the
## Compatibility renderer with MSAA. Resized every frame because the contest zooms the camera.

@export var texture: Texture2D

var _camera: Camera3D
var _quad := QuadMesh.new()


func _ready() -> void:
	_camera = get_parent() as Camera3D
	var material := StandardMaterial3D.new()
	material.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	material.albedo_texture = texture
	material.disable_receive_shadows = true
	_quad.material = material
	mesh = _quad
	cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	_fit()


func _process(_delta: float) -> void:
	_fit()


func _fit() -> void:
	if _camera == null:
		return
	var distance := _camera.far * 0.95
	position = Vector3(0.0, 0.0, -distance)
	var view := get_viewport().get_visible_rect().size
	var aspect := view.x / maxf(view.y, 1.0)
	var extent := _camera.size
	if _camera.projection == Camera3D.PROJECTION_PERSPECTIVE:
		extent = 2.0 * distance * tan(deg_to_rad(_camera.fov) * 0.5)
	var quad_size := Vector2(extent * aspect, extent) if _camera.keep_aspect == Camera3D.KEEP_HEIGHT else Vector2(extent, extent / aspect)
	# Slight overscan hides sub-pixel gaps at the screen edges.
	quad_size *= 1.02
	if not _quad.size.is_equal_approx(quad_size):
		_quad.size = quad_size
