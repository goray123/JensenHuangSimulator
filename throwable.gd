extends RigidBody3D

var _armed := false
var _thrower_id := 0
var _hit_players: Array[int] = []


func _ready() -> void:
	contact_monitor = true
	max_contacts_reported = 8
	body_entered.connect(_on_body_entered)
	sleeping_state_changed.connect(_on_sleeping_state_changed)


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
