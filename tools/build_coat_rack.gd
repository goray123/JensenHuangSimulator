extends SceneTree
## Rebuild the standalone furnishing with: godot --headless --path . -s tools/build_coat_rack.gd

const OUTPUT := "res://assets/furniture/coat_rack.tscn"
const WOOD := Color("b67a32")
const BRASS := Color("d5ae60")
const DARK_WOOD := Color("754e20")
const SIDES := 8

var _model := Node3D.new()
var _material := StandardMaterial3D.new()


func _initialize() -> void:
	_model.name = "CoatRack"
	_model.add_to_group(&"map_furniture", true)
	_material.resource_name = "CoatRack_FacetedWood"
	_material.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	_material.vertex_color_use_as_albedo = true
	_material.vertex_color_is_srgb = true
	_material.roughness = 0.9
	_material.cull_mode = BaseMaterial3D.CULL_DISABLED
	# Four low, swept feet keep the tall stand stable and leave open floor between them.
	for index in 4:
		var direction := Vector3(cos(index * PI * 0.5 + PI * 0.25), 0, sin(index * PI * 0.5 + PI * 0.25))
		_branch("Foot%d" % index, [
			Vector3.UP * 0.22,
			direction * 0.15 + Vector3.UP * 0.18,
			direction * 0.28 + Vector3.UP * 0.07,
			direction * 0.35 + Vector3.UP * 0.035,
		], 0.047, 0.032, WOOD)
		_ball("FootCap%d" % index, direction * 0.35 + Vector3.UP * 0.035, 0.035, DARK_WOOD)
	_tube("FootHub", Vector3.UP * 0.13, Vector3.UP * 0.27, 0.085, 0.06, DARK_WOOD)
	_tube("LowerPost", Vector3.UP * 0.23, Vector3.UP * 0.97, 0.052, 0.04, WOOD)
	_tube("UpperPost", Vector3.UP * 0.97, Vector3.UP * 1.59, 0.04, 0.031, WOOD)
	_tube("LowerCollar", Vector3.UP * 0.28, Vector3.UP * 0.315, 0.058, 0.058, BRASS)
	_tube("MiddleCollar", Vector3.UP * 0.965, Vector3.UP * 1.005, 0.052, 0.052, BRASS)
	_tube("UpperCollar", Vector3.UP * 1.305, Vector3.UP * 1.345, 0.049, 0.049, BRASS)
	# Staggered tiers of upturned hooks read clearly from the game's high camera.
	for index in 3:
		var angle := index * TAU / 3.0
		var upper := Vector3(cos(angle), 0, sin(angle))
		_branch("UpperHook%d" % index, [
			Vector3.UP * 1.33,
			upper * 0.16 + Vector3.UP * 1.385,
			upper * 0.28 + Vector3.UP * 1.495,
			upper * 0.29 + Vector3.UP * 1.595,
		], 0.035, 0.025, WOOD)
		_ball("UpperHookCap%d" % index, upper * 0.29 + Vector3.UP * 1.595, 0.043, BRASS)
		var lower := Vector3(cos(angle + PI / 3.0), 0, sin(angle + PI / 3.0))
		_branch("LowerHook%d" % index, [
			Vector3.UP * 0.985,
			lower * 0.13 + Vector3.UP * 1.015,
			lower * 0.225 + Vector3.UP * 1.115,
			lower * 0.235 + Vector3.UP * 1.205,
		], 0.031, 0.023, WOOD)
		_ball("LowerHookCap%d" % index, lower * 0.235 + Vector3.UP * 1.205, 0.036, BRASS)
	_tube("FinialNeck", Vector3.UP * 1.56, Vector3.UP * 1.63, 0.043, 0.043, BRASS)
	_ball("Finial", Vector3.UP * 1.645, 0.061, WOOD)
	var packed := PackedScene.new()
	var error := packed.pack(_model)
	if error == OK:
		DirAccess.make_dir_recursive_absolute(ProjectSettings.globalize_path(OUTPUT.get_base_dir()))
		error = ResourceSaver.save(packed, OUTPUT)
	_model.free()
	if error != OK:
		push_error("Could not save coat rack: %s" % error_string(error))
	quit(error)


func _branch(label: String, points: Array, start_radius: float, end_radius: float, color: Color) -> void:
	for index in points.size() - 1:
		var start := float(index) / (points.size() - 1)
		var end := float(index + 1) / (points.size() - 1)
		_tube(label + "Part%d" % index, points[index], points[index + 1], lerpf(start_radius, end_radius, start), lerpf(start_radius, end_radius, end), color)


func _tube(label: String, from: Vector3, to: Vector3, start_radius: float, end_radius: float, color: Color) -> void:
	var axis := (to - from).normalized()
	var u := axis.cross(Vector3.FORWARD).normalized()
	var v := axis.cross(u)
	var surface := SurfaceTool.new()
	surface.begin(Mesh.PRIMITIVE_TRIANGLES)
	for index in SIDES:
		var a := TAU * index / SIDES
		var b := TAU * (index + 1) / SIDES
		var radial_a := u * cos(a) + v * sin(a)
		var radial_b := u * cos(b) + v * sin(b)
		var p0 := from + radial_a * start_radius
		var p1 := from + radial_b * start_radius
		var p2 := to + radial_b * end_radius
		var p3 := to + radial_a * end_radius
		var normal := (radial_a + radial_b).normalized()
		_triangle(surface, p0, p1, p2, normal, color)
		_triangle(surface, p0, p2, p3, normal, color)
		_triangle(surface, from, p1, p0, -axis, color)
		_triangle(surface, to, p3, p2, axis, color)
	_add_mesh(label, surface.commit())


func _ball(label: String, at: Vector3, radius: float, color: Color) -> void:
	var surface := SurfaceTool.new()
	surface.begin(Mesh.PRIMITIVE_TRIANGLES)
	var rings := 4
	for ring in rings:
		var latitude_a := PI * ring / rings
		var latitude_b := PI * (ring + 1) / rings
		for index in SIDES:
			var longitude_a := TAU * index / SIDES
			var longitude_b := TAU * (index + 1) / SIDES
			var p0 := at + _sphere_point(latitude_a, longitude_a) * radius
			var p1 := at + _sphere_point(latitude_a, longitude_b) * radius
			var p2 := at + _sphere_point(latitude_b, longitude_b) * radius
			var p3 := at + _sphere_point(latitude_b, longitude_a) * radius
			var normal := ((p0 + p1 + p2 + p3) * 0.25 - at).normalized()
			if ring > 0:
				_triangle(surface, p0, p1, p2, normal, color)
			if ring < rings - 1:
				_triangle(surface, p0, p2, p3, normal, color)
	_add_mesh(label, surface.commit())


func _sphere_point(latitude: float, longitude: float) -> Vector3:
	return Vector3(sin(latitude) * cos(longitude), cos(latitude), sin(latitude) * sin(longitude))


func _triangle(surface: SurfaceTool, a: Vector3, b: Vector3, c: Vector3, normal: Vector3, color: Color) -> void:
	var light := Vector3(-0.35, 0.85, 0.4).normalized()
	var shade := 0.77 + 0.29 * normal.dot(light)
	surface.set_color(Color(color.r * shade, color.g * shade, color.b * shade))
	surface.set_normal(normal)
	surface.add_vertex(a)
	surface.add_vertex(b)
	surface.add_vertex(c)


func _add_mesh(label: String, mesh: ArrayMesh) -> void:
	mesh.resource_name = "CoatRack_" + label
	mesh.surface_set_material(0, _material)
	var instance := MeshInstance3D.new()
	instance.name = "CoatRack_" + label
	instance.mesh = mesh
	_model.add_child(instance)
	instance.owner = _model
