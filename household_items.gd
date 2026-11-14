extends Node3D

const THROWABLE := preload("res://throwable.gd")
const ITEM_DIR := "res://assets/items/"
# Item list: weight, attack power, gold value, bag icon.
const GAMEPLAY := {
	"01-banana": [1, 1, 20, preload("res://assets/Sprites/Items/Item_Banana.png")],
	"04-kimchi": [3, 2, 120, preload("res://assets/Sprites/Items/Item_Kimchi.png")],
	"05-cake": [2, 1, 150, preload("res://assets/Sprites/Items/Item_Cake.png")],
	"06-egg": [1, 1, 10, preload("res://assets/Sprites/Items/Item_Egg.png")],
	"07-frying-pan": [3, 4, 200, preload("res://assets/Sprites/Items/Item_FryingPan.png")],
	"08-computer": [4, 4, 1000, preload("res://assets/Sprites/Items/Item_Computer.png")],
	"09-dumbbell": [4, 5, 200, preload("res://assets/Sprites/Items/Item_Dumbbell.png")],
	"10-tissue-box": [1, 1, 20, preload("res://assets/Sprites/Items/Item_TissueBox.png")],
	"11-bed": [5, 5, 800, preload("res://assets/Sprites/Items/Item_Bed.png")],
	"12-ring": [1, 1, 800, preload("res://assets/Sprites/Items/Item_Ring.png")],
	"13-photo-album": [2, 1, 300, preload("res://assets/Sprites/Items/Item_PhotoAlbum.png")],
	"14-letter": [1, 0, 150, preload("res://assets/Sprites/Items/Item_Letter.png")],
	"15-desk": [5, 5, 500, preload("res://assets/Sprites/Items/Item_Desk.png")],
	"16-piggy-bank": [3, 3, 0, preload("res://assets/Sprites/Items/Item_PiggyBank.png")],
	"17-tv": [4, 4, 900, preload("res://assets/Sprites/Items/Item_TV.png")],
	"18-folded-clothes": [2, 1, 120, preload("res://assets/Sprites/Items/Item_FoldedClothes.png")],
	"19-shoes": [2, 2, 180, preload("res://assets/Sprites/Items/Item_Shoes.png")],
	"20-coat": [2, 1, 250, preload("res://assets/Sprites/Items/Item_Coat.png")],
	"21-plunger": [2, 1, 40, preload("res://assets/Sprites/Items/Item_Plunger.png")],
	"22-bucket": [2, 2, 60, preload("res://assets/Sprites/Items/Item_Bucket.png")],
	"23-shampoo": [2, 1, 80, preload("res://assets/Sprites/Items/Item_Shampoo.png")],
}
const WARDROBE := "../Map/MasterBedroom/Wardrobe"
# The map's wardrobe body is one solid box; swap it for thin panels so it is open.
const WARDROBE_SOLID_PARTS := [
	"Master_Wardrobe_Frame", "Master_Wardrobe_Door_0", "Master_Wardrobe_Door_1",
	"Master_Wardrobe_Handle_0", "Master_Wardrobe_Handle_1",
	# Cut away like the map's walls, or the top hides the inside from the high camera.
	"Master_Wardrobe_Top",
]
const WARDROBE_COLOR := Color(0.62, 0.4, 0.17)
# [centre, size] of the back and side panels, matching the original frame bounds.
const WARDROBE_PANELS := [
	[Vector3(13.88, 0.9, -3.64), Vector3(0.06, 1.52, 1.58)],
	[Vector3(13.48, 0.9, -4.4), Vector3(0.86, 1.52, 0.06)],
	# The south side faces the camera, so it is cut away like the map's south walls.
	[Vector3(13.48, 0.2, -2.88), Vector3(0.86, 0.1, 0.06)],
]

# [item scene, bottom-centre position on its surface, yaw in degrees, uniform scale]
# Surface heights come from assets/maps/ownership_dispute/map_metadata.json.
const PLACEMENTS := [
	# Kitchen breakfast bar (plates and bar top). The worktop behind the bar is
	# out of the player's reach: the 0.47 m capsule cannot pass beside the bar.
	["01-banana", Vector3(1.32, 0.95, -4.98), 0.0, 0.6],
	["04-kimchi", Vector3(2.0, 0.93, -4.8), 0.0, 0.8],
	["05-cake", Vector3(2.84, 0.95, -4.98), 0.0, 0.6],
	["07-frying-pan", Vector3(3.55, 0.93, -4.8), 0.0, 0.6],
	["06-egg", Vector3(4.28, 0.95, -4.98), 0.0, 0.5],
	# Floor hazards on walkable floor
	["02-water-puddle", Vector3(5.2, 0.065, -3.95), 0.0, 0.8],
	["03-banana-peel", Vector3(1.6, 0.065, -0.6), 30.0, 0.6],
	# Small bedroom TV dresser and floor
	["08-computer", Vector3(9.5, 0.66, -7.0), 0.0, 0.6],
	["10-tissue-box", Vector3(7.85, 0.66, -7.0), 0.0, 0.8],
	["09-dumbbell", Vector3(7.7, 0.06, -5.9), 0.0, 0.8],
	# Master bedroom: vanity, floor and inside the open wardrobe
	["11-bed", Vector3(10.5, 0.06, -1.9), 0.0, 0.7],
	["12-ring", Vector3(10.75, 0.62, -4.3), 0.0, 0.4],
	["14-letter", Vector3(11.05, 0.62, -4.3), 0.0, 0.6],
	["20-coat", Vector3(13.4, 0.15, -3.95), -90.0, 0.9],
	["18-folded-clothes", Vector3(13.4, 0.15, -3.28), -90.0, 0.8],
	["19-shoes", Vector3(13.4, 0.15, -2.98), -90.0, 0.8],
	# Living room: wall bookshelf gap, coffee table, TV console and floor
	["13-photo-album", Vector3(6.56, 0.54, -4.57), 0.0, 0.6],
	["16-piggy-bank", Vector3(2.55, 0.6, -2.7), 90.0, 0.7],
	["17-tv", Vector3(9.15, 0.69, -1.15), -90.0, 0.6],
	["15-desk", Vector3(5.5, 0.06, -0.5), 0.0, 0.8],
	# Bathroom sink rim and floor, all within reach of the doorway: the player
	# capsule cannot squeeze past the sink further in.
	["23-shampoo", Vector3(11.59, 0.83, -5.84), 0.0, 0.7],
	["21-plunger", Vector3(12.95, 0.06, -5.25), 0.0, 0.7],
	["22-bucket", Vector3(12.45, 0.06, -5.9), 0.0, 0.7],
]


func _ready() -> void:
	_open_wardrobe()
	for placement: Array in PLACEMENTS:
		_spawn(placement[0], placement[1], placement[2], placement[3])


func _open_wardrobe() -> void:
	# Shows the clothes stored inside; the wardrobe's collision box is unchanged.
	var wardrobe := get_node(WARDROBE) as Node3D
	for part: String in WARDROBE_SOLID_PARTS:
		(wardrobe.get_node(part) as Node3D).hide()
	var material := StandardMaterial3D.new()
	material.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	material.albedo_color = WARDROBE_COLOR
	for panel: Array in WARDROBE_PANELS:
		var box := BoxMesh.new()
		box.size = panel[1]
		box.material = material
		var mesh := MeshInstance3D.new()
		mesh.name = "OpenWardrobePanel"
		mesh.mesh = box
		wardrobe.add_child(mesh)
		mesh.global_position = panel[0]


func _spawn(item_id: String, at: Vector3, yaw_degrees: float, item_scale: float) -> void:
	var item := (load(ITEM_DIR + item_id + ".tscn") as PackedScene).instantiate() as Node3D
	# Physics bodies stay unscaled; scale the mesh and bake the scale into the collider.
	for child in item.get_children():
		if child is Node3D:
			child.position *= item_scale
	(item.get_node("Visual") as Node3D).scale = Vector3.ONE * item_scale
	var collision := item.get_node("Collision") as CollisionShape3D
	var shape := collision.shape.duplicate() as Shape3D
	if shape is ConvexPolygonShape3D:
		shape.points = Transform3D.IDENTITY.scaled(Vector3.ONE * item_scale) * shape.points
	elif shape is BoxShape3D:
		shape.size *= item_scale
	collision.shape = shape
	item.position = at
	item.rotation.y = deg_to_rad(yaw_degrees)
	if item is RigidBody3D:
		_make_pickup(item as RigidBody3D, collision)
	else:
		# Floor hazards only detect players (layer 1); their effects are not implemented yet.
		(item as Area3D).collision_mask = 1
	add_child(item)


func _make_pickup(item: RigidBody3D, collision: CollisionShape3D) -> void:
	item.set_script(THROWABLE)
	var stats: Array = GAMEPLAY[item.get_meta(&"item_id")]
	item.weight = stats[0]
	item.attack_power = stats[1]
	item.gold_value = stats[2]
	item.bag_icon = stats[3]
	# player.gd and throw_trajectory.gd look the collider up by this name.
	collision.name = "CollisionShape3D"
	item.collision_layer = 2
	item.collision_mask = 3
	item.freeze = true
	item.linear_damp_mode = RigidBody3D.DAMP_MODE_REPLACE
	item.linear_damp = 0.0
	item.angular_damp = 1.0
	var bounds := collision.transform * collision.shape.get_debug_mesh().get_aabb()
	var size := bounds.size
	# Item origins are at the bottom, so centre the body in the hand like apartment props.
	item.set_meta(&"hold_offset", Vector3(0, maxf(size.y * 0.5 - 0.65, 0), -size.z * 0.5 - 0.12) - bounds.get_center())
	item.set_meta(&"pickup_name", item.get_meta(&"display_name"))
	item.add_to_group(&"pickups")
	item.add_to_group(&"household_items")
