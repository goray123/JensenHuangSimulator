extends Node3D

const SFX := preload("res://sfx.gd")
const Player := preload("res://player.gd")
const PLAYER_SCENE := preload("res://player.tscn")
const PICKUP_CONTEST := preload("res://pickup_contest.gd")
const GUEST_MODEL := preload("res://assets/characters/motions/02_Woman.glb")
const ENDING_SCENE := "res://courtroom_ending.tscn"
const INPUT_TIMEOUT_MS := 500
const HIT_DROP_COUNTS := [0, 1, 2, 2, 3, 3]
const HIT_EXTRA_DROP_CHANCES := [0.0, 0.0, 0.0, 0.3, 0.0, 0.5]
const ROOM_PHYSICS := preload("res://room_physics.gd")
const PHYSICS_MASS := preload("res://physics_mass.gd")
const FURNITURE_SNAPSHOT_BATCH := 16

var guest_peer_id := 0
var _last_guest_input := -1
var _guest: Player
var _local_player: Player
var _players: Array[Player]
var _pickups: Array[RigidBody3D]
var _bagged_items: Dictionary[int, int] = {}
var _ownership_revision := 0
var _physics_bodies: Array[RigidBody3D]
var _room_physics: Node
var _round_finished := false
var _contest: Node

@onready var _host: Player = $Player
@onready var _throw_power: ProgressBar = $HUD/ThrowPower
@onready var _grab_progress: ProgressBar = $HUD/GrabProgress
@onready var _round_timer: Timer = $RoundTimer
@onready var _time_left: Label = $HUD/TimeLeft


func _ready() -> void:
	_room_physics = ROOM_PHYSICS.new()
	_room_physics.name = "RoomPhysics"
	add_child(_room_physics)
	_room_physics.setup($Map)
	_pickups.assign(get_tree().get_nodes_in_group(&"pickups").filter(is_ancestor_of))
	# Reparenting held props must never change their network indices.
	_pickups.sort_custom(func(a: Node, b: Node) -> bool: return str(a.get_path()) < str(b.get_path()))
	for pickup in _pickups:
		if not pickup.has_meta(&"physics_volume"):
			var shape := pickup.get_node("CollisionShape3D") as CollisionShape3D
			var bounds := shape.transform * shape.shape.get_debug_mesh().get_aabb()
			pickup.mass = PHYSICS_MASS.from_item_bounds(bounds)
			pickup.set_meta(&"physics_volume", bounds.get_volume())
		pickup.freeze = not multiplayer.is_server()
	_physics_bodies.assign(_pickups)
	_physics_bodies.append_array(_room_physics.bodies)
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
				_players[index].status_effect_applied.connect(_broadcast_status_effect.bind(index))
				_players[index].banana_peel_stepped.connect(_broadcast_banana_peel_stun.bind(index))
				_players[index].pickup_launched.connect(_broadcast_throw.bind(index))
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
	for index in _players.size():
		$HUD.bind_player(index, _players[index])
	_contest = PICKUP_CONTEST.new()
	_contest.name = "PickupContest"
	add_child(_contest)
	_contest.active_changed.connect(_on_contest_active_changed)
	_contest.setup(self, _players, _pickups)
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
	_receive_snapshot.rpc_id(guest_peer_id, poses, Vector4i(holding.x, holding.y, _ownership_revision, seconds_left))
	# Keep each unreliable packet below the network MTU as the room fills up.
	var furniture: Array[RigidBody3D] = _room_physics.bodies
	for start in range(0, furniture.size(), FURNITURE_SNAPSHOT_BATCH):
		var furniture_poses: Array[Transform3D] = []
		for index in range(start, mini(start + FURNITURE_SNAPSHOT_BATCH, furniture.size())):
			furniture_poses.append(furniture[index].global_transform)
		_apply_furniture_snapshot.rpc_id(guest_peer_id, start, furniture_poses)


func _update_time_left(seconds: int) -> void:
	_time_left.text = "%02d:%02d" % [floori(seconds / 60.0), seconds % 60]


func _on_round_timeout() -> void:
	var gold := bag_gold()
	if guest_peer_id != 0:
		_end_round.rpc(gold)
	else:
		_end_round(gold)


## Final bag value per player index, summed from the host's bag ownership, not the HUD tween.
func bag_gold() -> Vector2i:
	var gold := Vector2i.ZERO
	for pickup_index in _bagged_items:
		gold[_bagged_items[pickup_index]] += _pickups[pickup_index].gold_value
	return gold


## gold.x = player0 (host, husband), gold.y = player1 (guest or test dummy, wife); decided by the host.
@rpc("authority", "call_local", "reliable")
func _end_round(gold: Vector2i) -> void:
	if _round_finished:
		return
	_round_finished = true
	_contest.cancel_round()
	_grab_progress.hide()
	_throw_power.hide()
	for body in _physics_bodies:
		body.freeze = true
	_update_time_left(0)
	$HUD/RoundEnd.show()
	process_mode = Node.PROCESS_MODE_DISABLED
	# shortcut: loads the ~30 MB ending synchronously (brief hitch at timeout); preload threaded if it shows.
	var ending: CanvasLayer = load(ENDING_SCENE).instantiate()
	ending.name = "Ending"
	ending.process_mode = Node.PROCESS_MODE_ALWAYS
	add_child(ending)
	ending.show_scores(gold.x, gold.y)


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


# A validated launch is an ownership change: bumping the revision makes the guest drop older
# snapshots (which could re-attach the item) until this reliable event plays the one-hand Throw.
func _broadcast_throw(pickup: RigidBody3D, player_index: int) -> void:
	if _round_finished or not multiplayer.is_server():
		return
	_ownership_revision += 1
	if multiplayer.get_peers().has(guest_peer_id):
		_apply_throw.rpc_id(guest_peer_id, player_index, _pickups.find(pickup), _ownership_revision)


@rpc("authority", "call_remote", "reliable")
func _apply_throw(player_index: int, pickup_index: int, revision: int) -> void:
	if _round_finished or revision <= _ownership_revision or player_index < 0 or player_index >= _players.size() or pickup_index < 0 or pickup_index >= _pickups.size():
		return
	_ownership_revision = revision
	var player := _players[player_index]
	if player.held_pickup == _pickups[pickup_index]:
		player.release_pickup(false)
	player.play_throw_motion()


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
	var revision := _ownership_revision + 1
	_apply_bag_item(player_index, pickup_index, revision)
	if guest_peer_id != 0:
		_apply_bag_item.rpc_id(guest_peer_id, player_index, pickup_index, revision)


@rpc("authority", "call_remote", "reliable")
func _apply_bag_item(player_index: int, pickup_index: int, revision: int) -> void:
	if _round_finished or revision <= _ownership_revision or player_index < 0 or player_index >= _players.size() or pickup_index < 0 or pickup_index >= _pickups.size() or _bagged_items.has(pickup_index):
		return
	var pickup := _pickups[pickup_index]
	if not is_instance_valid(pickup):
		return
	_ownership_revision = revision
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
	_bagged_items[pickup_index] = player_index
	_players[player_index].bag_weight += pickup.weight
	$HUD.add_bag_item(player_index, pickup_index, pickup)


func drop_hit_items(victim: Player, attack_power: int) -> void:
	if _round_finished or not multiplayer.is_server() or not is_instance_valid(victim) or attack_power <= 0:
		return
	var candidates: Array[int] = []
	var player_index := _players.find(victim)
	if player_index >= 0:
		for pickup_index in _bagged_items:
			if _bagged_items[pickup_index] == player_index:
				candidates.append(pickup_index)
	var held_index := _pickups.find(victim.held_pickup)
	if held_index >= 0:
		candidates.append(held_index)
	var count: int = HIT_DROP_COUNTS[attack_power]
	if HIT_EXTRA_DROP_CHANCES[attack_power] > 0.0 and randf() < HIT_EXTRA_DROP_CHANCES[attack_power]:
		count += 1
	candidates.shuffle()
	candidates.resize(mini(count, candidates.size()))
	if candidates.is_empty():
		return
	var poses: Array[Transform3D] = []
	for slot in candidates.size():
		poses.append(_drop_pose(_pickups[candidates[slot]], victim, slot))
	var revision := _ownership_revision + 1
	_apply_hit_drops(candidates, poses, revision)
	if guest_peer_id != 0:
		_apply_hit_drops.rpc_id(guest_peer_id, candidates, poses, revision)


func _drop_pose(pickup: RigidBody3D, victim: Player, slot: int) -> Transform3D:
	var collider := pickup.get_node("CollisionShape3D") as CollisionShape3D
	var bounds := collider.transform * collider.shape.get_debug_mesh().get_aabb()
	var center := victim.global_position + Vector3.UP * (0.25 + bounds.size.y * 0.5)
	var query := PhysicsShapeQueryParameters3D.new()
	query.shape = collider.shape
	query.collision_mask = 3
	query.exclude = [victim.get_rid(), pickup.get_rid()]
	var space := victim.get_world_3d().direct_space_state
	for attempt in 8:
		var angle := victim.rotation.y + (slot * 2 + attempt) * TAU / 8.0
		var offset := Vector3.FORWARD.rotated(Vector3.UP, angle) * 0.82
		var ray := PhysicsRayQueryParameters3D.create(center, center + offset, 1, query.exclude)
		if not space.intersect_ray(ray).is_empty():
			continue
		var pose := Transform3D(Basis.IDENTITY, center + offset - bounds.get_center())
		query.transform = pose * collider.transform
		if space.intersect_shape(query, 1).is_empty():
			return pose
	return Transform3D(Basis.IDENTITY, center - bounds.get_center() + Vector3.UP * (0.4 + slot * 0.2))


@rpc("authority", "call_remote", "reliable")
func _apply_hit_drops(pickup_indices: Array[int], poses: Array[Transform3D], revision: int) -> void:
	if _round_finished or revision <= _ownership_revision:
		return
	_ownership_revision = revision
	for slot in pickup_indices.size():
		var pickup_index := pickup_indices[slot]
		var pickup := _pickups[pickup_index]
		var holder := pickup.get_parent().get_parent() as Player
		if holder != null and holder.held_pickup == pickup:
			holder.release_pickup(false)
		if _bagged_items.has(pickup_index):
			var owner := _bagged_items[pickup_index]
			_bagged_items.erase(pickup_index)
			_players[owner].bag_weight -= pickup.weight
			$HUD.remove_bag_item(owner, pickup_index, pickup.gold_value)
		$HUD.add_drop_log(pickup)
		pickup.disarm()
		pickup.global_transform = poses[slot]
		pickup.add_to_group(&"pickups")
		pickup.show()
		pickup.collision_layer = 2
		pickup.collision_mask = 3
		pickup.freeze = not multiplayer.is_server()
		pickup.linear_velocity = Vector3.ZERO
		pickup.angular_velocity = Vector3.ZERO
		pickup.sleeping = false


func _is_guest_request() -> bool:
	return not _round_finished and _guest != null and multiplayer.is_server() and multiplayer.get_remote_sender_id() == guest_peer_id


func _broadcast_hit(player_index: int) -> void:
	_apply_hit.rpc_id(guest_peer_id, player_index, _players[player_index].last_hit_sound)


@rpc("authority", "call_remote", "reliable")
func _apply_hit(player_index: int, sound: StringName = &"") -> void:
	if not _round_finished and player_index >= 0 and player_index < _players.size():
		_players[player_index].receive_hit(sound)


func _broadcast_status_effect(effect: StringName, seconds: float, player_index: int) -> void:
	if not _round_finished:
		_apply_status_effect.rpc_id(guest_peer_id, player_index, effect, seconds)


@rpc("authority", "call_remote", "reliable")
func _apply_status_effect(player_index: int, effect: StringName, seconds: float) -> void:
	if not _round_finished and player_index >= 0 and player_index < _players.size():
		_players[player_index].apply_status_effect(effect, seconds)


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
func _receive_snapshot(poses: PackedFloat32Array, state: Vector4i) -> void:
	if poses.size() != (_players.size() + _pickups.size()) * 12:
		return
	var transforms: Array[Transform3D] = []
	for offset in range(0, poses.size(), 12):
		var basis := Basis(Vector3(poses[offset], poses[offset + 1], poses[offset + 2]), Vector3(poses[offset + 3], poses[offset + 4], poses[offset + 5]), Vector3(poses[offset + 6], poses[offset + 7], poses[offset + 8]))
		transforms.append(Transform3D(basis, Vector3(poses[offset + 9], poses[offset + 10], poses[offset + 11])))
	_apply_snapshot(transforms, Vector2i(state.x, state.y), state.z, state.w)


func _apply_snapshot(transforms: Array, holding: Vector2i, ownership_revision: int, seconds_left: int) -> void:
	# Wait for reliable ownership events before applying snapshots from the new state.
	if _round_finished or ownership_revision != _ownership_revision:
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
	# Bagged items and converted peels cannot be restored by an old held index.
	for index in _players.size():
		if _bagged_items.has(holding[index]) or (holding[index] >= 0 and (not is_instance_valid(_pickups[holding[index]]) or _pickups[holding[index]].is_banana_peel)):
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
		if index != holding.x and index != holding.y and not _bagged_items.has(index) and is_instance_valid(_pickups[index]) and not _pickups[index].is_banana_peel:
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


func log_attack(pickup: RigidBody3D, victim: Node3D) -> void:
	if not multiplayer.is_server() or _round_finished:
		return
	var pickup_index := _pickups.find(pickup)
	var victim_index := _players.find(victim)
	if pickup_index < 0 or victim_index < 0:
		return
	if guest_peer_id != 0:
		_show_attack_log.rpc(pickup_index, victim_index)
	else:
		_show_attack_log(pickup_index, victim_index)


@rpc("authority", "call_local", "reliable")
func _show_attack_log(pickup_index: int, victim_index: int) -> void:
	if not _round_finished and pickup_index >= 0 and pickup_index < _pickups.size() and victim_index >= 0 and victim_index < _players.size():
		$HUD.add_attack_log(_pickups[pickup_index], victim_index)


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
