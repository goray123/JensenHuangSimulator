extends Node3D

const Player := preload("res://player.gd")
const PLAYER_SCENE := preload("res://player.tscn")
const GUEST_COLOR := Color(0.16, 0.65, 0.98)
const INPUT_TIMEOUT_MS := 500

var guest_peer_id := 0
var _last_guest_input := -1
var _guest: Player
var _local_player: Player
var _players: Array[Player]
var _pickups: Array[RigidBody3D]

@onready var _host: Player = $Player
@onready var _pickup_status: Label = $HUD/PickupStatus
@onready var _throw_power: ProgressBar = $HUD/ThrowPower


func _ready() -> void:
	_use_solid_colliders()
	_pickups.assign(get_tree().get_nodes_in_group(&"pickups"))
	# Reparenting held props must never change their network indices.
	_pickups.sort_custom(func(a: Node, b: Node) -> bool: return str(a.get_path()) < str(b.get_path()))
	_local_player = _host
	set_physics_process(guest_peer_id != 0)
	if guest_peer_id != 0:
		var is_host := multiplayer.is_server()
		_host.reads_local_input = is_host
		_host.simulates_movement = is_host
		_guest = PLAYER_SCENE.instantiate() as Player
		_guest.name = "Guest"
		_guest.transform = $GuestSpawn.transform
		_guest.reads_local_input = not is_host
		_guest.simulates_movement = is_host
		var jacket := StandardMaterial3D.new()
		jacket.albedo_color = GUEST_COLOR
		jacket.roughness = 0.88
		for part in [&"Torso", &"LeftArm", &"RightArm"]:
			(_guest.get_node(NodePath(part)) as MeshInstance3D).material_override = jacket
		add_child(_guest)
		_guest.add_collision_exception_with(_host)
		_host.add_collision_exception_with(_guest)
		_players = [_host, _guest]
		process_physics_priority = 1
		if not is_host:
			_local_player = _guest
			_guest.pickup_action_requested.connect(_send_pickup_action)
		$HUD/LanRole.text = "내 캐릭터: 주황색   ·   Esc 나가기" if is_host else "내 캐릭터: 파란색   ·   Esc 나가기"
		$HUD/LanRole.show()
	_local_player.held_pickup_changed.connect(_update_pickup_status)
	_local_player.throw_blocked.connect(_show_throw_blocked)
	_local_player.aim_changed.connect(_update_aim_status)
	_update_pickup_status(_local_player.held_pickup != null)


func _use_solid_colliders() -> void:
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
		var item_name := str(_local_player.held_pickup.get_meta(&"pickup_name", "구"))
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
		_update_pickup_status(_local_player.held_pickup != null)


func _physics_process(_delta: float) -> void:
	if not multiplayer.is_server():
		_receive_movement.rpc_id(1, Player.read_movement())
		return
	if _last_guest_input < 0:
		return
	if Time.get_ticks_msec() - _last_guest_input > INPUT_TIMEOUT_MS:
		_guest.remote_input = Vector2.ZERO
	var transforms: Array[Transform3D] = [_host.transform, _guest.transform]
	for pickup in _pickups:
		transforms.append(pickup.global_transform)
	var holding := Vector2i(_pickups.find(_host.held_pickup), _pickups.find(_guest.held_pickup))
	_apply_snapshot.rpc_id(guest_peer_id, transforms, holding)


@rpc("any_peer", "call_remote", "unreliable_ordered")
func _receive_movement(direction: Vector2) -> void:
	if _is_guest_request() and direction.is_finite():
		_guest.remote_input = direction.limit_length()
		_last_guest_input = Time.get_ticks_msec()


func _send_pickup_action(pick_up: bool, speed: float) -> void:
	_receive_pickup_action.rpc_id(1, pick_up, speed)


@rpc("any_peer", "call_remote", "reliable")
func _receive_pickup_action(pick_up: bool, speed: float) -> void:
	if not _is_guest_request() or not is_finite(speed):
		return
	if pick_up:
		_guest.pickup_nearest()
	else:
		_guest.release_pickup(true, _guest.throw_velocity_at_speed(speed))


func _is_guest_request() -> bool:
	return _guest != null and multiplayer.is_server() and multiplayer.get_remote_sender_id() == guest_peer_id


@rpc("authority", "call_remote", "unreliable_ordered")
func _apply_snapshot(transforms: Array, holding: Vector2i) -> void:
	if transforms.size() != _players.size() + _pickups.size():
		return
	if mini(holding.x, holding.y) < -1 or maxi(holding.x, holding.y) >= _pickups.size():
		return
	if holding.x >= 0 and holding.x == holding.y:
		return
	for pose in transforms:
		if not (pose is Transform3D and pose.is_finite()):
			return
	for index in _players.size():
		var player := _players[index]
		player.transform = transforms[index]
		if _pickups.find(player.held_pickup) != holding[index]:
			player.release_pickup(false)
	for index in _players.size():
		var pickup_index := holding[index]
		if pickup_index >= 0 and _players[index].held_pickup == null:
			_players[index].hold_pickup(_pickups[pickup_index])
	for index in _pickups.size():
		if index != holding.x and index != holding.y:
			_pickups[index].global_transform = transforms[_players.size() + index]
