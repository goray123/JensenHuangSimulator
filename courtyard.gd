extends Node3D

@onready var _pickup_status: Label = $HUD/PickupStatus


func _ready() -> void:
	$Player.held_pickup_changed.connect(_update_pickup_status)
	_update_pickup_status($Player.held_pickup != null)


func _update_pickup_status(is_holding: bool) -> void:
	_pickup_status.text = "손: 구를 들고 있음 (T로 던지기)" if is_holding else "손: 비어 있음"
