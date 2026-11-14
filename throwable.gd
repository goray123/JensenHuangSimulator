extends RigidBody3D

const OUTLINE_MATERIAL := preload("res://pickup_outline.tres")

var _armed := false
var _thrower_id := 0
var _hit_players: Array[int] = []
var _outline_meshes: Array[MeshInstance3D] = []


func _ready() -> void:
	contact_monitor = true
	max_contacts_reported = 8
	body_entered.connect(_on_body_entered)
	sleeping_state_changed.connect(_on_sleeping_state_changed)


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


func disarm() -> void:
	_armed = false
	_hit_players.clear()


func _on_body_entered(body: Node) -> void:
	if not _armed or not multiplayer.is_server() or not body.has_method(&"receive_hit"):
		return
	var player_id := body.get_instance_id()
	if player_id == _thrower_id or player_id in _hit_players:
		return
	_hit_players.append(player_id)
	body.receive_hit()


func _on_sleeping_state_changed() -> void:
	if sleeping:
		# Allow contacts from the same physics tick to finish before disarming.
		_disarm_if_sleeping.call_deferred()


func _disarm_if_sleeping() -> void:
	if sleeping:
		disarm()
