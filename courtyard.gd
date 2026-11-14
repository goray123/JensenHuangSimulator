extends Node3D

@onready var _pickup_status: Label = $HUD/PickupStatus
@onready var _throw_power: ProgressBar = $HUD/ThrowPower


func _ready() -> void:
	_use_solid_colliders()
	$Player.held_pickup_changed.connect(_update_pickup_status)
	$Player.throw_blocked.connect(_show_throw_blocked)
	$Player.aim_changed.connect(_update_aim_status)
	_update_pickup_status($Player.held_pickup != null)


func _use_solid_colliders() -> void:
	# Solid boxes let shape queries detect objects already overlapping a wall.
	for node in get_children():
		if not node is CSGBox3D or not node.use_collision:
			continue
		var body := StaticBody3D.new()
		body.name = "SolidCollision"
		body.collision_layer = node.collision_layer
		body.collision_mask = node.collision_mask
		var shape := BoxShape3D.new()
		shape.size = node.size
		var collider := CollisionShape3D.new()
		collider.shape = shape
		body.add_child(collider)
		node.use_collision = false
		node.add_child(body)


func _update_pickup_status(is_holding: bool) -> void:
	if is_holding:
		var item_name := str($Player.held_pickup.get_meta(&"pickup_name", "구"))
		_pickup_status.text = "손: %s (T 누르기: 조준 / 떼기: 던지기)" % item_name
	else:
		_pickup_status.text = "손: 비어 있음"


func _show_throw_blocked() -> void:
	_pickup_status.text = "던질 공간이 부족합니다. 벽이나 가구에서 떨어져 주세요."


func _update_aim_status(is_aiming: bool, speed: float) -> void:
	_throw_power.visible = is_aiming
	_throw_power.value = speed
	if is_aiming:
		_pickup_status.text = "던지기 속도: %.1f / 10 (T를 떼면 던지기)" % speed
	else:
		_update_pickup_status($Player.held_pickup != null)
