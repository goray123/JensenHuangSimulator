extends RigidBody3D

const SFX := preload("res://sfx.gd")
const IMPACT_SOUNDS := {
	&"StewPan": &"hit_metal", &"MopAndBucket": &"hit_metal",
	&"CoffeeMug": &"hit_shatter", &"DeskMug": &"hit_shatter", &"DiningCoffee": &"hit_shatter",
	&"FruitPlate": &"hit_shatter", &"PreserveJar": &"hit_shatter",
	&"Cabbage": &"hit_soft", &"Carrot": &"hit_soft", &"Banana": &"hit_soft", &"SecondBanana": &"hit_soft",
	&"Cushion": &"hit_soft", &"07-frying-pan": &"hit_metal", &"09-dumbbell": &"hit_metal",
	&"12-ring": &"hit_metal", &"22-bucket": &"hit_metal", &"01-banana": &"hit_soft",
	&"05-cake": &"hit_soft", &"18-folded-clothes": &"hit_soft", &"19-shoes": &"hit_soft", &"20-coat": &"hit_soft",
	&"16-piggy-bank": &"hit_shatter",
}
const OUTLINE_MATERIAL := preload("res://pickup_outline.tres")
const PACKING_SECONDS := [1.0, 0.5, 0.7, 1.1, 1.4, 1.9]

var weight := 0
var attack_power := 1
var gold_value := 10
var bag_icon: Texture2D

var _armed := false
var _thrower_id := 0
var _hit_players: Array[int] = []
var _outline_meshes: Array[MeshInstance3D] = []
var _impact_played := false
var _last_impact_ms := -1000


func _ready() -> void:
	contact_monitor = true
	max_contacts_reported = 8
	body_entered.connect(_on_body_entered)
	sleeping_state_changed.connect(_on_sleeping_state_changed)


func packing_seconds() -> float:
	return PACKING_SECONDS[weight]


func set_pickup_highlighted(highlighted: bool) -> void:
	if highlighted and _outline_meshes.is_empty():
		# Imported props receive their models after _ready(), so build on demand.
		var meshes := find_children("*", "MeshInstance3D", true, false)
		for source: MeshInstance3D in meshes:
			if source.mesh == null:
				continue
			var outline := MeshInstance3D.new()
			outline.name = "PickupOutline"
			outline.mesh = source.mesh
			outline.material_override = OUTLINE_MATERIAL
			outline.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
			outline.extra_cull_margin = 0.05
			source.add_child(outline)
			_outline_meshes.append(outline)
	for outline in _outline_meshes:
		outline.visible = highlighted


func arm(thrower: PhysicsBody3D) -> void:
	_thrower_id = thrower.get_instance_id()
	_hit_players.clear()
	_armed = true
	_impact_played = false


func disarm() -> void:
	_armed = false
	_hit_players.clear()


func _on_body_entered(body: Node) -> void:
	if not _armed or not multiplayer.is_server():
		return
	if not body.has_method(&"receive_hit"):
		if not _impact_played:
			_impact_played = true
			var now := Time.get_ticks_msec()
			if now - _last_impact_ms >= 150:
				_last_impact_ms = now
				var sound := impact_sound()
				var stage := _stage()
				if stage != null:
					stage.broadcast_prop_impact(self, sound)
				else:
					SFX.play_at(self, sound)
		return
	var player_id := body.get_instance_id()
	if player_id == _thrower_id or player_id in _hit_players:
		return
	_hit_players.append(player_id)
	body.receive_hit()
	var stage := _stage()
	if stage != null and attack_power > 0:
		# Changing collision shapes and parents must wait for the physics callback to finish.
		stage.drop_hit_items.call_deferred(body, attack_power)
	var thrower := instance_from_id(_thrower_id) as Node3D
	if is_instance_valid(thrower):
		if stage != null:
			stage.reward_thrower(thrower)
		elif thrower.get("reads_local_input") == true:
			SFX.play_ui(thrower, &"pickup_coin", -6.0)


func _on_sleeping_state_changed() -> void:
	if sleeping:
		# Allow contacts from the same physics tick to finish before disarming.
		_disarm_if_sleeping.call_deferred()


func _disarm_if_sleeping() -> void:
	if sleeping:
		disarm()


func impact_sound() -> StringName:
	var key := StringName(get_meta(&"item_id", name))
	return IMPACT_SOUNDS.get(key, &"hit_soft" if "Cushion" in String(name) else &"hit_thud")


func _stage() -> Node:
	var node := get_parent()
	while node != null:
		if node.has_method(&"broadcast_prop_impact"):
			return node
		node = node.get_parent()
	return null
