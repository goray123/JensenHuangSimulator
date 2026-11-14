extends Node

const MASS := preload("res://physics_mass.gd")
const MIN_SHAPE_THICKNESS := 0.01

var bodies: Array[RigidBody3D] = []


func setup(map: Node3D) -> void:
	# These dark polygons are painted floor shadows. Moving them with a table
	# would leave a black sheet floating in the air; the lights supply real shadows.
	for mesh: MeshInstance3D in map.find_children("*", "MeshInstance3D", true, false):
		if _is_painted_shadow(mesh):
			mesh.hide()
	var furniture: Array[Node] = []
	for node in get_tree().get_nodes_in_group(&"map_furniture"):
		if map.is_ancestor_of(node) and not node is RigidBody3D:
			furniture.append(node)
	furniture.sort_custom(func(a: Node, b: Node) -> bool: return str(a.get_path()) < str(b.get_path()))
	for model: Node3D in furniture:
		for old_body: StaticBody3D in model.find_children("*", "StaticBody3D", true, false):
			old_body.free()
		_split_loose_items(model)
		_make_body(model, true)
	bodies.sort_custom(func(a: Node, b: Node) -> bool: return str(a.get_path()) < str(b.get_path()))
	# A single authority simulates furniture; guests display the host's snapshots.
	for body in bodies:
		body.freeze = not multiplayer.is_server()


func _is_painted_shadow(mesh: MeshInstance3D) -> bool:
	return "hard_shadow" in String(mesh.name).to_lower()


func _split_loose_items(model: Node3D) -> void:
	var parts: Dictionary = {}
	for child in model.get_children():
		if not child is MeshInstance3D:
			continue
		var item_name := _loose_item_name(String(child.name))
		if item_name.is_empty():
			continue
		if not parts.has(item_name):
			parts[item_name] = []
		parts[item_name].append(child)
	for item_name: String in parts:
		var item := Node3D.new()
		item.name = item_name
		model.get_parent().add_child(item)
		item.global_transform = Transform3D(model.global_basis.orthonormalized(), model.global_position)
		for mesh: MeshInstance3D in parts[item_name]:
			mesh.reparent(item)
		_make_body(item, false)


func _loose_item_name(mesh_name: String) -> String:
	if mesh_name.begins_with("Coffee_Cup_"):
		return mesh_name
	if mesh_name.begins_with("Bar_Plate_"):
		return mesh_name
	if mesh_name.begins_with("CoffeeTable_Magazine"):
		return "CoffeeTable_Magazine_" + mesh_name.get_slice("_", 2)
	if mesh_name.begins_with("CoffeeTable_Remote"):
		return "CoffeeTable_Remote"
	if mesh_name.begins_with("SmallBedroom_Bookshelf_Book_"):
		return mesh_name
	if mesh_name.begins_with("SmallBedroom_TV_"):
		return "SmallBedroom_Television"
	if mesh_name.begins_with("Master_Vanity_Perfume"):
		return "Master_Vanity_Perfume_" + mesh_name.get_slice("_", 3)
	if mesh_name.begins_with("Master_Vanity_Book_"):
		return "Master_Vanity_Book"
	if mesh_name == "Purple_Media_Player" or mesh_name.begins_with("TV_Speaker_"):
		return mesh_name
	return ""


func _make_body(model: Node3D, is_furniture: bool) -> void:
	var frame := Transform3D(model.global_basis.orthonormalized(), model.global_position)
	var inverse_frame := frame.affine_inverse()
	var meshes: Array[MeshInstance3D] = []
	var bounds := AABB()
	for mesh: MeshInstance3D in model.find_children("*", "MeshInstance3D", true, false):
		# Open wardrobe panels replace deliberately hidden solid geometry.
		if mesh.mesh == null or not mesh.visible or _is_painted_shadow(mesh):
			continue
		var mesh_bounds := (inverse_frame * mesh.global_transform) * mesh.get_aabb()
		bounds = mesh_bounds if meshes.is_empty() else bounds.merge(mesh_bounds)
		meshes.append(mesh)
	if meshes.is_empty():
		return
	var body := RigidBody3D.new()
	var original_name := model.name
	model.name = "Model"
	if is_furniture:
		model.remove_from_group(&"map_furniture")
	body.name = original_name
	body.freeze = true
	body.collision_layer = 2
	body.collision_mask = 3
	body.mass = MASS.from_bounds(bounds)
	body.continuous_cd = true
	body.can_sleep = true
	body.linear_damp_mode = RigidBody3D.DAMP_MODE_REPLACE
	body.linear_damp = 0.1
	body.angular_damp_mode = RigidBody3D.DAMP_MODE_REPLACE
	body.angular_damp = 0.5
	var material := PhysicsMaterial.new()
	material.friction = 0.7
	material.bounce = 0.02
	body.physics_material_override = material
	model.get_parent().add_child(body)
	body.global_transform = Transform3D(frame.basis, frame * bounds.get_center())
	model.reparent(body)
	body.set_meta(&"physics_volume", bounds.get_volume())
	body.set_meta(&"physics_size", bounds.size)
	body.add_to_group(&"dynamic_furniture")
	if is_furniture:
		body.add_to_group(&"map_furniture")
	for mesh in meshes:
		_add_mesh_collider(body, mesh)
	bodies.append(body)


func _add_mesh_collider(body: RigidBody3D, mesh: MeshInstance3D) -> void:
	# A separate convex part for each leg/top preserves the space under tables.
	# Baking world scale into points also keeps every physics transform unscaled.
	var relative := body.global_transform.affine_inverse() * mesh.global_transform
	var mesh_bounds := relative * mesh.get_aabb()
	var collider := CollisionShape3D.new()
	collider.name = String(mesh.name) + "Shape"
	if minf(mesh_bounds.size.x, minf(mesh_bounds.size.y, mesh_bounds.size.z)) < MIN_SHAPE_THICKNESS:
		var box := BoxShape3D.new()
		box.size = mesh_bounds.size.max(Vector3.ONE * MIN_SHAPE_THICKNESS)
		box.margin = 0.002
		collider.shape = box
		collider.position = mesh_bounds.get_center()
	else:
		var points := mesh.mesh.get_faces()
		for index in points.size():
			points[index] = relative * points[index]
		if points.size() < 4:
			collider.free()
			return
		var convex := ConvexPolygonShape3D.new()
		convex.points = points
		convex.margin = 0.002
		collider.shape = convex
	body.add_child(collider)
