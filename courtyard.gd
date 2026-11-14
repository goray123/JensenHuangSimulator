extends Node3D

const SFX := preload("res://sfx.gd")
const Player := preload("res://player.gd")
const PLAYER_SCENE := preload("res://player.tscn")
const PICKUP_CONTEST := preload("res://pickup_contest.gd")
const GUEST_MODEL := preload("res://assets/characters/thump/02_Woman.glb")
const INPUT_TIMEOUT_MS := 500

var guest_peer_id := 0
var _last_guest_input := -1
var _guest: Player
var _local_player: Player
var _players: Array[Player]
var _pickups: Array[RigidBody3D]
var _bagged_items: Array[int] = []
var _round_finished := false
var _contest: Node

@onready var _host: Player = $Player
@onready var _throw_power: ProgressBar = $HUD/ThrowPower
@onready var _grab_progress: ProgressBar = $HUD/GrabProgress
@onready var _round_timer: Timer = $RoundTimer
@onready var _time_left: Label = $HUD/TimeLeft


func _ready() -> void:
	_pickups.assign(get_tree().get_nodes_in_group(&"pickups").filter(is_ancestor_of))
	# Reparenting held props must never change their network indices.
	_pickups.sort_custom(func(a: Node, b: Node) -> bool: return str(a.get_path()) < str(b.get_path()))
	_local_player = _host
	_players = [_host]
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
		_guest.model_scene = GUEST_MODEL
		add_child(_guest)
		_guest.add_collision_exception_with(_host)
		_host.add_collision_exception_with(_guest)
		_players.append(_guest)
		if is_host:
			for index in _players.size():
				_players[index].hit_received.connect(_broadcast_hit.bind(index))
		process_physics_priority = 1
		if not is_host:
			_local_player = _guest
			_guest.throw_requested.connect(_send_throw)
	_local_player.get_node("Head/PlayerPosPointer").show()
	if guest_peer_id != 0:
		for index in _players.size():
			_players[index].shared_sfx_requested.connect(_broadcast_player_sound.bind(index))
	var listener := AudioListener3D.new()
	listener.position.y = 0.7
	_local_player.add_child(listener)
	listener.make_current()
	_local_player.aim_changed.connect(_update_throw_power)
	_local_player.grab_changed.connect(_update_grab_progress)
	_local_player.bag_requested.connect(_request_bag_item)
	_contest = PICKUP_CONTEST.new()
	_contest.name = "PickupContest"
	add_child(_contest)
	_contest.active_changed.connect(_on_contest_active_changed)
	_contest.setup(self, _players, _pickups)
	if guest_peer_id == 0 or multiplayer.is_server():
		_round_timer.timeout.connect(_on_round_timeout)
		_round_timer.start()


func _on_contest_active_changed(is_active: bool) -> void:
	if is_instance_valid(_round_timer):
		_round_timer.paused = is_active


func _update_throw_power(is_aiming: bool, speed: float) -> void:
	_throw_power.visible = is_aiming
	_throw_power.value = speed


func _update_grab_progress(is_grabbing: bool, progress: float) -> void:
	_grab_progress.visible = is_grabbing
	_grab_progress.value = progress


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
		_contest.request_interaction(_guest, false)
	var transforms: Array[Transform3D] = [_host.transform, _guest.transform]
	for pickup in _pickups:
		transforms.append(pickup.global_transform)
	var holding := Vector2i(_pickups.find(_host.held_pickup), _pickups.find(_guest.held_pickup))
	# Keep the same object order, using packed floats to fit one ENet packet.
	var poses := PackedFloat32Array()
	for pose in transforms:
		poses.append_array(PackedFloat32Array([pose.basis.x.x, pose.basis.x.y, pose.basis.x.z, pose.basis.y.x, pose.basis.y.y, pose.basis.y.z, pose.basis.z.x, pose.basis.z.y, pose.basis.z.z, pose.origin.x, pose.origin.y, pose.origin.z]))
	_receive_snapshot.rpc_id(guest_peer_id, poses, Vector4i(holding.x, holding.y, _contest.revision, seconds_left))


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
	_grab_progress.hide()
	_throw_power.hide()
	_update_time_left(0)
	$HUD/RoundEnd.show()
	process_mode = Node.PROCESS_MODE_DISABLED


@rpc("any_peer", "call_remote", "unreliable_ordered")
func _receive_movement(direction: Vector2) -> void:
	if _is_guest_request() and direction.is_finite():
		_guest.remote_input = direction.limit_length()
		_last_guest_input = Time.get_ticks_msec()


func _send_throw(speed: float) -> void:
	_receive_throw.rpc_id(1, _pickups.find(_guest.held_pickup), speed)


@rpc("any_peer", "call_remote", "reliable")
func _receive_throw(pickup_index: int, speed: float) -> void:
	if _is_guest_request() and _guest.held_pickup != null and _pickups.find(_guest.held_pickup) == pickup_index and is_finite(speed):
		_guest.release_pickup(true, _guest.throw_velocity_at_speed(speed))


func _request_bag_item() -> void:
	var pickup_index := _pickups.find(_local_player.held_pickup)
	if multiplayer.is_server():
		_bag_held_item(0, pickup_index)
	else:
		_receive_bag_request.rpc_id(1, pickup_index)


@rpc("any_peer", "call_remote", "reliable")
func _receive_bag_request(pickup_index: int) -> void:
	if _is_guest_request():
		_bag_held_item(1, pickup_index)


func _bag_held_item(player_index: int, pickup_index: int) -> void:
	var player := _players[player_index]
	if _round_finished or player.contest_active or player.held_pickup == null or pickup_index < 0 or _bagged_items.has(pickup_index) or _pickups.find(player.held_pickup) != pickup_index:
		return
	_apply_bag_item(player_index, pickup_index)
	if guest_peer_id != 0:
		_apply_bag_item.rpc_id(guest_peer_id, player_index, pickup_index)


@rpc("authority", "call_remote", "reliable")
func _apply_bag_item(player_index: int, pickup_index: int) -> void:
	if _round_finished or player_index < 0 or player_index >= _players.size() or pickup_index < 0 or pickup_index >= _pickups.size() or _bagged_items.has(pickup_index):
		return
	var pickup := _pickups[pickup_index]
	if not is_instance_valid(pickup):
		return
	_bagged_items.append(pickup_index)
	for player in _players:
		if player.held_pickup == pickup:
			player.release_pickup(false)
	# Keep the body at its network index for the rest of the round.
	if pickup.is_in_group(&"pickups"):
		pickup.remove_from_group(&"pickups")
	pickup.disarm()
	pickup.set_pickup_highlighted(false)
	pickup.hide()
	pickup.freeze = true
	pickup.collision_layer = 0
	pickup.collision_mask = 0
	$HUD.add_bag_item(player_index, str(pickup.get_meta(&"pickup_name", "구")))


func _is_guest_request() -> bool:
	return not _round_finished and _guest != null and multiplayer.is_server() and multiplayer.get_remote_sender_id() == guest_peer_id


func _broadcast_hit(player_index: int) -> void:
	_apply_hit.rpc_id(guest_peer_id, player_index, _players[player_index].last_hit_sound)


@rpc("authority", "call_remote", "reliable")
func _apply_hit(player_index: int, sound: StringName = &"") -> void:
	if not _round_finished and player_index >= 0 and player_index < _players.size():
		_players[player_index].receive_hit(sound)


@rpc("authority", "call_remote", "unreliable_ordered")
func _receive_snapshot(poses: PackedFloat32Array, state: Vector4i) -> void:
	if poses.size() != (_players.size() + _pickups.size()) * 12:
		return
	var transforms: Array[Transform3D] = []
	for offset in range(0, poses.size(), 12):
		var basis := Basis(Vector3(poses[offset], poses[offset + 1], poses[offset + 2]), Vector3(poses[offset + 3], poses[offset + 4], poses[offset + 5]), Vector3(poses[offset + 6], poses[offset + 7], poses[offset + 8]))
		transforms.append(Transform3D(basis, Vector3(poses[offset + 9], poses[offset + 10], poses[offset + 11])))
	_apply_snapshot(transforms, Vector2i(state.x, state.y), state.z, state.w)


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
	if _contest.active and ownership_revision > _contest.revision:
		return
	for pose in transforms:
		if not (pose is Transform3D and pose.is_finite()):
			return
	for index in _players.size():
		if _bagged_items.has(holding[index]) or (holding[index] >= 0 and not is_instance_valid(_pickups[holding[index]])):
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
		if index != holding.x and index != holding.y and not _bagged_items.has(index) and is_instance_valid(_pickups[index]):
			_pickups[index].global_transform = transforms[_players.size() + index]


func _broadcast_player_sound(sound: StringName, player_index: int) -> void:
	if multiplayer.is_server() and not _round_finished:
		_play_player_sound.rpc(player_index, sound)


@rpc("authority", "call_local", "reliable")
func _play_player_sound(player_index: int, sound: StringName) -> void:
	if player_index < 0 or player_index >= _players.size() or sound not in [&"pickup_grab", &"throw_light", &"throw_heavy", &"throw_spin", &"throw_cartoon"]:
		return
	SFX.play_at(_players[player_index], sound, -4.0 if sound == &"pickup_grab" else 0.0)


func broadcast_prop_impact(pickup: RigidBody3D, sound: StringName) -> void:
	if not multiplayer.is_server() or _round_finished:
		return
	var index := _pickups.find(pickup)
	if guest_peer_id != 0:
		_play_prop_impact.rpc(index, sound)
	else:
		_play_prop_impact(index, sound)


@rpc("authority", "call_local", "reliable")
func _play_prop_impact(pickup_index: int, sound: StringName) -> void:
	if pickup_index >= 0 and pickup_index < _pickups.size() and sound in [&"hit_thud", &"hit_soft", &"hit_metal", &"hit_shatter"]:
		SFX.play_at(_pickups[pickup_index], sound)


func reward_thrower(thrower: Node3D) -> void:
	if not multiplayer.is_server():
		return
	if thrower.reads_local_input:
		SFX.play_ui(thrower, &"pickup_coin", -6.0)
	elif guest_peer_id != 0 and thrower == _guest:
		_play_hit_reward.rpc_id(guest_peer_id)


@rpc("authority", "call_remote", "reliable")
func _play_hit_reward() -> void:
	if not _round_finished and is_instance_valid(_local_player):
		SFX.play_ui(_local_player, &"pickup_coin", -6.0)
