extends Node3D

const THROWABLE := preload("res://throwable.gd")
const PHYSICS_MASS := preload("res://physics_mass.gd")

const ITEM_NAMES := {
	"Television": "TV", "Laptop": "노트북", "CoffeeMug": "머그컵",
	"DeskMug": "머그컵", "CoffeeTableBooks": "책", "BedsideLamp": "탁상등",
	"NightstandLamp": "탁상등", "CuttingBoard": "도마", "Cabbage": "양배추",
	"Carrot": "당근", "StewPan": "냄비", "FruitPlate": "접시",
	"Banana": "바나나", "SecondBanana": "바나나", "PreserveJar": "유리병",
	"DiningCoffee": "커피잔", "Plunger": "뚫어뻥", "MopAndBucket": "대걸레와 양동이",
}


func _ready() -> void:
	for node in get_tree().get_nodes_in_group(&"throwable_props"):
		if is_ancestor_of(node):
			_make_pickup(node as Node3D)


func _make_pickup(model: Node3D) -> void:
	# Bake imported mesh scale into the collider, keeping the physics body unscaled.
	var frame := Transform3D(model.global_basis.orthonormalized(), model.global_position)
	var inverse_frame := frame.affine_inverse()
	var bounds := AABB()
	var has_mesh := false
	var meshes := model.find_children("*", "MeshInstance3D", true, false)
	if model is MeshInstance3D:
		meshes.append(model)
	for mesh: MeshInstance3D in meshes:
		if mesh.mesh == null:
			continue
		var mesh_bounds := (inverse_frame * mesh.global_transform) * mesh.get_aabb()
		bounds = bounds.merge(mesh_bounds) if has_mesh else mesh_bounds
		has_mesh = true
	if not has_mesh:
		return
	var item_name := String(model.name)
	model.name = "Model"
	model.remove_from_group(&"throwable_props")
	var body := THROWABLE.new()
	body.name = item_name
	body.freeze = true
	body.collision_layer = 2
	body.collision_mask = 3
	body.continuous_cd = true
	body.linear_damp_mode = RigidBody3D.DAMP_MODE_REPLACE
	body.linear_damp = 0.0
	body.angular_damp = 1.0
	body.mass = PHYSICS_MASS.from_item_bounds(bounds)
	var material := PhysicsMaterial.new()
	material.friction = 0.8
	material.bounce = 0.2
	body.physics_material_override = material
	model.get_parent().add_child(body)
	body.global_transform = Transform3D(frame.basis, frame * bounds.get_center())
	model.reparent(body)
	var shape := BoxShape3D.new()
	shape.size = bounds.size.max(Vector3.ONE * 0.02)
	var collider := CollisionShape3D.new()
	collider.name = "CollisionShape3D"
	collider.shape = shape
	body.add_child(collider)
	body.set_meta(&"pickup_name", ITEM_NAMES.get(item_name, item_name))
	body.set_meta(&"physics_volume", bounds.get_volume())
	if item_name in ["Banana", "SecondBanana"]:
		body.set_meta(&"item_id", "01-banana")
	body.set_meta(&"hold_offset", Vector3(0, maxf(shape.size.y * 0.5 - 0.65, 0), -shape.size.z * 0.5 - 0.12))
	body.add_to_group(&"pickups")
	body.add_to_group(&"apartment_props")
	body.freeze = not multiplayer.is_server()
