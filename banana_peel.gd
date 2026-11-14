extends Area3D

signal consumed

var sync_consumption_directly := true
var _consumed := false


func _ready() -> void:
	body_entered.connect(_on_body_entered)


func _on_body_entered(body: Node3D) -> void:
	# Claim the trap before applying the effect, including simultaneous entries.
	if _consumed or not multiplayer.is_server() or not can_process():
		return
	if body is CharacterBody3D and body.can_process() and body.has_method(&"receive_banana_peel"):
		if sync_consumption_directly and not multiplayer.get_peers().is_empty():
			consume.rpc()
		else:
			consume()
		body.receive_banana_peel()


@rpc("authority", "call_local", "reliable")
func consume() -> void:
	if _consumed:
		return
	_consumed = true
	hide()
	remove_from_group(&"floor_hazard")
	set_deferred(&"monitoring", false)
	set_deferred(&"monitorable", false)
	consumed.emit()
	queue_free()
