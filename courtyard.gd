extends Node3D

const Player := preload("res://player.gd")
const PLAYER_SCENE := preload("res://player.tscn")
const PICKUP_CONTEST := preload("res://pickup_contest.gd")
const ROOM_PHYSICS := preload("res://room_physics.gd")
const PHYSICS_MASS := preload("res://physics_mass.gd")
const GUEST_COLOR := Color(0.16, 0.65, 0.98)
const INPUT_TIMEOUT_MS := 500
const FURNITURE_SNAPSHOT_BATCH := 16

var guest_peer_id := 0
var _last_guest_input := -1
var _guest: Player
var _local_player: Player
var _players: Array[Player]
var _pickups: Array[RigidBody3D]
var _physics_bodies: Array[RigidBody3D]
var _room_physics: Node
var _round_finished := false
var _contest: Node

@onready var _host: Player = $Player
@onready var _throw_power: ProgressBar = $HUD/ThrowPower
@onready var _round_timer: Timer = $RoundTimer
@onready var _time_left: Label = $HUD/TimeLeft


func _ready() -> void:
	_room_physics = ROOM_PHYSICS.new()
	_room_physics.name = "RoomPhysics"
	add_child(_room_physics)
	_room_physics.setup($Map)
	_pickups.assign(get_tree().get_nodes_in_group(&"pickups"))
	# Reparenting held props must never change their network indices.
	_pickups.sort_custom(func(a: Node, b: Node) -> bool: return str(a.get_path()) < str(b.get_path()))
	for pickup in _pickups:
		if not pickup.has_meta(&"physics_volume"):
			var shape := pickup.get_node("CollisionShape3D") as CollisionShape3D
			var bounds := shape.transform * shape.shape.get_debug_mesh().get_aabb()
			pickup.mass = PHYSICS_MASS.from_bounds(bounds)
			pickup.set_meta(&"physics_volume", bounds.get_volume())
		pickup.freeze = not multiplayer.is_server()
	_physics_bodies.assign(_pickups)
	_physics_bodies.append_array(_room_physics.bodies)
	_local_player = _host
	_host.global_position = $Map/Markers/Player1Spawn.global_position
	if guest_peer_id != 0:
		var is_host := multiplayer.is_server()
		_host.reads_local_input = is_host
		_host.simulates_movement = is_host
		_guest = PLAYER_SCENE.instantiate() as Player
		_guest.name = "Guest"
		_guest.position = to_local($Map/Markers/Player2Spawn.global_position)
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
		if is_host:
			for index in _players.size():
				_players[index].hit_received.connect(_broadcast_hit.bind(index))
				_players[index].banana_peel_stepped.connect(_broadcast_banana_peel_stun.bind(index))
		process_physics_priority = 1
		if not is_host:
			_local_player = _guest
			_guest.pickup_action_requested.connect(_send_pickup_action)
	_local_player.get_node("Head/PlayerPosPointer").show()
	_local_player.aim_changed.connect(_update_throw_power)
	_contest = PICKUP_CONTEST.new()
	_contest.name = "PickupContest"
	add_child(_contest)
	_contest.active_changed.connect(_on_contest_active_changed)
	_contest.setup(self, _players if guest_peer_id != 0 else [_host], _pickups)
	if guest_peer_id == 0 or multiplayer.is_server():
		for index in _pickups.size():
			_pickups[index].banana_landed.connect(_broadcast_banana_peel.bind(index))
			_pickups[index].banana_peel_consumed.connect(_broadcast_banana_peel_consumed.bind(index))
		_round_timer.timeout.connect(_on_round_timeout)
		_round_timer.start()


func _on_contest_active_changed(is_active: bool) -> void:
	if is_instance_valid(_round_timer):
		_round_timer.paused = is_active


func _update_throw_power(is_aiming: bool, speed: float) -> void:
	_throw_power.visible = is_aiming
	_throw_power.value = speed


func _physics_process(_delta: float) -> void:
	if guest_peer_id != 0 and not multiplayer.is_server():
		_receive_movement.rpc_id(1, Player.read_movement())
		return
	var seconds_left := ceili(_round_timer.time_left)
	_update_time_left(seconds_left)
	# The first input also signals that the guest has loaded this scene.
	if guest_peer_id == 0 or _last_guest_input < 0:
		return
	if Time.get_ticks_msec() - _last_guest_input > INPUT_TIMEOUT_MS:
		_guest.remote_input = Vector2.ZERO
	var transforms: Array[Transform3D] = [_host.transform, _guest.transform]
	for pickup in _pickups:
		transforms.append(pickup.global_transform)
	var holding := Vector2i(_pickups.find(_host.held_pickup), _pickups.find(_guest.held_pickup))
	_apply_snapshot.rpc_id(guest_peer_id, transforms, holding, _contest.revision, seconds_left)
	# Keep each unreliable packet below the network MTU as the room fills up.
	var furniture: Array[RigidBody3D] = _room_physics.bodies
	for start in range(0, furniture.size(), FURNITURE_SNAPSHOT_BATCH):
		var poses: Array[Transform3D] = []
		for index in range(start, mini(start + FURNITURE_SNAPSHOT_BATCH, furniture.size())):
			poses.append(furniture[index].global_transform)
		_apply_furniture_snapshot.rpc_id(guest_peer_id, start, poses)


func _update_time_left(seconds: int) -> void:
	_time_left.text = "%02d:%02d" % [floori(seconds / 60.0), seconds % 60]


func _on_round_timeout() -> void:
	if guest_peer_id != 0:
		_end_round.rpc()
	else:
		_end_round()


@rpc("authority", "call_local", "reliable")
func _end_round() -> void:
	_round_finished = true
	_contest.cancel_round()
	for body in _physics_bodies:
		body.freeze = true
	_update_time_left(0)
	$HUD/RoundEnd.show()
	process_mode = Node.PROCESS_MODE_DISABLED


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
	return not _round_finished and _guest != null and multiplayer.is_server() and multiplayer.get_remote_sender_id() == guest_peer_id


func _broadcast_hit(player_index: int) -> void:
	_apply_hit.rpc_id(guest_peer_id, player_index)


@rpc("authority", "call_remote", "reliable")
func _apply_hit(player_index: int) -> void:
	if not _round_finished and player_index >= 0 and player_index < _players.size():
		_players[player_index].receive_hit()


func _broadcast_banana_peel_stun(player_index: int) -> void:
	_apply_banana_peel_stun.rpc_id(guest_peer_id, player_index)


@rpc("authority", "call_remote", "reliable")
func _apply_banana_peel_stun(player_index: int) -> void:
	if not _round_finished and player_index >= 0 and player_index < _players.size():
		_players[player_index].receive_banana_peel()


func _broadcast_banana_peel(landing_transform: Transform3D, pickup_index: int) -> void:
	if guest_peer_id != 0 and multiplayer.get_peers().has(guest_peer_id):
		_apply_banana_peel.rpc_id(guest_peer_id, pickup_index, landing_transform)


@rpc("authority", "call_remote", "reliable")
func _apply_banana_peel(pickup_index: int, landing_transform: Transform3D) -> void:
	if pickup_index < 0 or pickup_index >= _pickups.size() or not landing_transform.is_finite():
		return
	var pickup := _pickups[pickup_index]
	if pickup.is_banana_peel:
		return
	# Landing may arrive before the snapshot that releases the thrower's hand.
	for player in _players:
		if player.held_pickup == pickup:
			player.release_pickup(false)
	pickup.become_banana_peel(landing_transform)


func _broadcast_banana_peel_consumed(pickup_index: int) -> void:
	if guest_peer_id != 0 and multiplayer.get_peers().has(guest_peer_id):
		_apply_banana_peel_consumed.rpc_id(guest_peer_id, pickup_index)


@rpc("authority", "call_remote", "reliable")
func _apply_banana_peel_consumed(pickup_index: int) -> void:
	if pickup_index < 0 or pickup_index >= _pickups.size():
		return
	var pickup := _pickups[pickup_index]
	for player in _players:
		if player.held_pickup == pickup:
			player.release_pickup(false)
	pickup.consume_banana_peel()


@rpc("authority", "call_remote", "unreliable_ordered")
func _apply_snapshot(transforms: Array, holding: Vector2i, ownership_revision: int, seconds_left: int) -> void:
	if _round_finished or ownership_revision < _contest.revision:
		return
	if transforms.size() != _players.size() + _pickups.size():
		return
	if mini(holding.x, holding.y) < -1 or maxi(holding.x, holding.y) >= _pickups.size():
		return
	if holding.x >= 0 and holding.x == holding.y:
		return
	for pose in transforms:
		if not (pose is Transform3D and pose.is_finite()):
			return
	# Conversion is permanent: older in-flight snapshots cannot restore a banana.
	for index in 2:
		if holding[index] >= 0 and _pickups[holding[index]].is_banana_peel:
			holding[index] = -1
	_update_time_left(seconds_left)
	# Release old holders first, including when an intermediate throw was missed.
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
		if index != holding.x and index != holding.y and not _pickups[index].is_banana_peel:
			_pickups[index].global_transform = transforms[_players.size() + index]


@rpc("authority", "call_remote", "unreliable_ordered")
func _apply_furniture_snapshot(start: int, poses: Array[Transform3D]) -> void:
	if _round_finished or start < 0 or poses.size() > FURNITURE_SNAPSHOT_BATCH:
		return
	var furniture: Array[RigidBody3D] = _room_physics.bodies
	if start + poses.size() > furniture.size():
		return
	for pose in poses:
		if not pose.is_finite():
			return
	for index in poses.size():
		furniture[start + index].global_transform = poses[index]
