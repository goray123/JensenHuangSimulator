extends Node

const MASS := preload("res://physics_mass.gd")
const THROWABLE := preload("res://throwable.gd")
const MIN_SHAPE_THICKNESS := 0.01
# Map furniture that players can grab like items, keyed by path under the map.
# [pickup-time weight tier, attack power, gold value, display name]
const FURNITURE_PICKUPS := {
	"Kitchen/Refrigerator": [5, 5, 1200, "냉장고"],
	"Kitchen/Counter": [5, 5, 700, "싱크대"],
	"Kitchen/AirFryer": [3, 3, 250, "에어프라이어"],
	"Kitchen/Kettle": [2, 2, 80, "전기주전자"],
	"Kitchen/Stool00": [3, 3, 60, "스툴"],
	"Kitchen/Stool01": [3, 3, 60, "스툴"],
	"Kitchen/Stool02": [3, 3, 60, "스툴"],
	"LivingRoom/CoffeeTable": [4, 4, 300, "커피 테이블"],
	"LivingRoom/TVConsole": [4, 4, 350, "TV 콘솔"],
	"LivingRoom/Sofa": [5, 5, 900, "소파"],
	"LivingRoom/PottedPlant": [3, 2, 120, "화분"],
	"LivingRoom/CoatRack": [3, 3, 90, "옷걸이"],
	"MasterBedroom/Bed": [5, 5, 800, "침대"],
	"MasterBedroom/Vanity": [5, 4, 600, "화장대"],
	"MasterBedroom/VanityStool": [3, 3, 80, "화장대 의자"],
	"MasterBedroom/BedsideLamp": [3, 3, 150, "협탁"],
	"MasterBedroom/FloorPlant": [3, 2, 120, "화분"],
	"SmallBedroom/Bed": [5, 5, 600, "침대"],
	"SmallBedroom/Bookshelf": [5, 5, 400, "책장"],
	"SmallBedroom/Album": [2, 1, 300, "앨범"],
	"Bathroom/Sink": [5, 4, 400, "세면대"],
	"Bathroom/Toilet": [5, 5, 300, "변기"],
}

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
		var key := str(map.get_path_to(model))
		_split_loose_items(model)
		_make_body(model, true, key)
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


func _make_body(model: Node3D, is_furniture: bool, key := "") -> void:
	var frame := Transform3D(model.global_basis.orthonormalized(), model.global_position)
	var meshes: Array[MeshInstance3D] = []
	for mesh: MeshInstance3D in model.find_children("*", "MeshInstance3D", true, false):
		# Open wardrobe panels replace deliberately hidden solid geometry.
		if mesh.mesh != null and mesh.visible and not _is_painted_shadow(mesh):
			meshes.append(mesh)
	if meshes.is_empty():
		return
	var bounds := _bounds_in(frame, meshes)
	var pickup_stats: Array = FURNITURE_PICKUPS.get(key, [])
	# Held items keep the body's axes, so turn long furniture (the sofa) to be
	# carried across the body instead of poking metres ahead into the walls.
	if not pickup_stats.is_empty() and bounds.size.z > bounds.size.x:
		frame.basis = frame.basis * Basis(Vector3.UP, PI / 2)
		bounds = _bounds_in(frame, meshes)
	var body: RigidBody3D = THROWABLE.new() if not pickup_stats.is_empty() else RigidBody3D.new()
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
	for mesh in meshes:
		_add_mesh_collider(body, mesh)
	if not pickup_stats.is_empty():
		_make_pickup(body, bounds, key, pickup_stats)
		return
	body.add_to_group(&"dynamic_furniture")
	if is_furniture:
		body.add_to_group(&"map_furniture")
	bodies.append(body)


func _bounds_in(frame: Transform3D, meshes: Array[MeshInstance3D]) -> AABB:
	var inverse_frame := frame.affine_inverse()
	var bounds := (inverse_frame * meshes[0].global_transform) * meshes[0].get_aabb()
	for mesh in meshes:
		bounds = bounds.merge((inverse_frame * mesh.global_transform) * mesh.get_aabb())
	return bounds


func _make_pickup(body: RigidBody3D, bounds: AABB, key: String, stats: Array) -> void:
	# Pickups follow the item rules, so the courtyard syncs them by pickup index
	# instead of the furniture snapshot list.
	body.weight_tier = stats[0]
	body.weight = float(stats[0]) * MASS.ITEM_WEIGHT_SCALE
	body.attack_power = stats[1]
	body.gold_value = stats[2]
	body.mass = MASS.from_item_bounds(bounds)
	# Throw prediction ignores damping, like the other pickups.
	body.linear_damp = 0.0
	body.angular_damp = 1.0
	# player.gd and the throw queries read one shape named CollisionShape3D. The
	# per-part convex shapes still do the real colliding (books stay inside the
	# shelf), so this whole-object box only serves those queries.
	var query_box := BoxShape3D.new()
	query_box.size = bounds.size.max(Vector3.ONE * MIN_SHAPE_THICKNESS)
	var query_shape := CollisionShape3D.new()
	query_shape.name = "CollisionShape3D"
	query_shape.shape = query_box
	query_shape.disabled = true
	body.add_child(query_shape)
	var size := bounds.size
	body.set_meta(&"hold_offset", Vector3(0, maxf(size.y * 0.5 - 0.65, 0), -size.z * 0.5 - 0.12))
	# Extends the grab range to roughly the nearer side of big pieces like beds.
	body.set_meta(&"grab_reach", maxf(minf(size.x, size.z) * 0.5 - 0.3, 0.0))
	body.set_meta(&"pickup_name", stats[3])
	body.set_meta(&"item_id", key)
	body.add_to_group(&"pickups")
	body.add_to_group(&"furniture_pickups")


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
