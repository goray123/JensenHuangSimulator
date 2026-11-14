extends Node

signal active_changed(is_active: bool)

const PRESENTATION := preload("res://contest_presentation.gd")
const PRESS_ADVANTAGE_TO_WIN := 20
const LOSS_STUN_SECONDS := 2.5

var active := false:
	set(value):
		if active == value:
			return
		active = value
		active_changed.emit(active)
var progress := 0.5
var round_id := 0
var revision := 0
var item_index := -1
var presentation: Node

var _apartment: Node3D
var _players: Array = []
var _pickups: Array = []
var _press_difference := 0
var _grab_items := Vector2i(-1, -1)
var _grab_times := Vector2.ZERO


func setup(apartment: Node3D, players: Array, pickups: Array) -> void:
	_apartment = apartment
	_pickups = pickups.duplicate()
	_players = players.duplicate()
	for player in _players:
		player.pickup_request_handler = request_interaction
	presentation = PRESENTATION.new()
	presentation.name = "Presentation"
	add_child(presentation)
	presentation.setup(_apartment, _players)


func register_opponent(player: CharacterBody3D) -> void:
	if _players.size() != 1 or player == _players[0]:
		return
	_players.append(player)
	player.pickup_request_handler = request_interaction
	presentation.setup(_apartment, _players)


func request_interaction(player: CharacterBody3D, pressed := true, target: RigidBody3D = null) -> void:
	var player_index := _players.find(player)
	if player_index < 0:
		return
	if pressed and target == null:
		if active and multiplayer.is_server():
			_handle_interaction(player_index, round_id, item_index)
		elif active and player.reads_local_input:
			_request_interaction.rpc_id(1, round_id, item_index)
		return
	var pickup_index := _pickups.find(target) if pressed else -1
	if multiplayer.is_server():
		_set_grab(player_index, pickup_index)
	elif player.reads_local_input:
		_request_grab.rpc_id(1, pickup_index)


@rpc("any_peer", "call_remote", "reliable")
func _request_grab(pickup_index: int) -> void:
	if _apartment._is_guest_request():
		_set_grab(1, pickup_index)


@rpc("any_peer", "call_remote", "reliable")
func _request_interaction(requested_round: int, requested_item: int) -> void:
	if _apartment._is_guest_request():
		_handle_interaction(1, requested_round, requested_item)


func _set_grab(player_index: int, pickup_index: int) -> void:
	if not can_process():
		return
	if pickup_index == -1:
		_grab_items[player_index] = -1
		return
	if active or _grab_items[player_index] != -1 or pickup_index < 0 or pickup_index >= _pickups.size():
		return
	var pickup: RigidBody3D = _pickups[pickup_index]
	if not _players[player_index].can_grab(pickup):
		return
	var other_index := 1 - player_index
	if _players.size() == 2 and _grab_items[other_index] == pickup_index:
		if _players[other_index].can_grab(pickup):
			_start_contest(pickup_index)
			return
		_grab_items[other_index] = -1
	_grab_items[player_index] = pickup_index
	_grab_times[player_index] = 0.0


func _handle_interaction(player_index: int, requested_round: int, requested_item: int) -> void:
	if not can_process() or not multiplayer.is_server() or not active or requested_round != round_id or requested_item != item_index:
		return
	_press_difference += 1 if player_index == 0 else -1
	progress = clampf(0.5 + float(_press_difference) / (2.0 * PRESS_ADVANTAGE_TO_WIN), 0.0, 1.0)
	presentation.set_progress(progress)
	if abs(_press_difference) >= PRESS_ADVANTAGE_TO_WIN:
		_finish_contest(0 if _press_difference > 0 else 1)
	elif _has_guest():
		_sync_progress.rpc_id(_apartment.guest_peer_id, round_id, progress)


func _start_contest(pickup_index: int) -> void:
	round_id += 1
	revision += 1
	_begin_round(round_id, pickup_index)
	if _has_guest():
		var poses := [_players[0].transform, _players[1].transform, _pickups[item_index].global_transform]
		_sync_start.rpc_id(_apartment.guest_peer_id, round_id, item_index, revision, poses)


func _begin_round(id: int, pickup_index: int) -> void:
	round_id = id
	item_index = pickup_index
	active = true
	_grab_items = Vector2i(-1, -1)
	progress = 0.5
	_press_difference = 0
	var pickup: RigidBody3D = _pickups[item_index]
	pickup.freeze = true
	pickup.linear_velocity = Vector3.ZERO
	pickup.angular_velocity = Vector3.ZERO
	pickup.disarm()
	for player in _players:
		player.set_contest_active(true)
	presentation.start_contest(str(pickup.get_meta(&"pickup_name", "구")))
	presentation.set_progress(progress)


@rpc("authority", "call_remote", "reliable")
func _sync_start(id: int, pickup_index: int, state_revision: int, poses: Array) -> void:
	if not can_process() or state_revision < revision or id <= round_id or _players.size() != 2 or pickup_index < 0 or pickup_index >= _pickups.size() or poses.size() != 3:
		return
	for pose in poses:
		if not (pose is Transform3D and pose.is_finite()):
			return
	if not is_instance_valid(_pickups[pickup_index]) or _apartment._bagged_items.has(pickup_index):
		return
	revision = state_revision
	for index in 2:
		_players[index].release_pickup(false)
		_players[index].transform = poses[index]
	_pickups[pickup_index].global_transform = poses[2]
	_begin_round(id, pickup_index)


@rpc("authority", "call_remote", "reliable")
func _sync_progress(id: int, value: float) -> void:
	if active and id == round_id and is_finite(value):
		progress = clampf(value, 0.0, 1.0)
		presentation.set_progress(progress)


func _finish_contest(winner_index: int) -> void:
	revision += 1
	_complete_round(winner_index)
	if _has_guest():
		_sync_result.rpc_id(_apartment.guest_peer_id, round_id, item_index, winner_index, revision)


func _complete_round(winner_index: int) -> void:
	active = false
	progress = 1.0 if winner_index == 0 else 0.0
	for player in _players:
		player.set_contest_active(false)
	_transfer_item(item_index, winner_index)
	_players[1 - winner_index].apply_stun(LOSS_STUN_SECONDS)
	presentation.set_progress(progress)
	presentation.finish_contest(winner_index)


func _transfer_item(pickup_index: int, winner_index: int) -> void:
	var pickup: RigidBody3D = _pickups[pickup_index]
	for player in _players:
		# A reliable result can arrive before an ordinary throw/pickup snapshot.
		# Clear stale hand contents before applying authoritative ownership.
		if player.held_pickup != null and (player != _players[winner_index] or player.held_pickup != pickup):
			player.release_pickup(false)
	if _players[winner_index].held_pickup != pickup:
		_players[winner_index].hold_pickup(pickup)


@rpc("authority", "call_remote", "reliable")
func _sync_result(id: int, pickup_index: int, winner_index: int, state_revision: int) -> void:
	if not can_process() or state_revision < revision or id < round_id or pickup_index < 0 or pickup_index >= _pickups.size() or winner_index not in [0, 1] or _players.size() != 2:
		return
	if not is_instance_valid(_pickups[pickup_index]) or _apartment._bagged_items.has(pickup_index):
		return
	revision = state_revision
	round_id = id
	item_index = pickup_index
	_complete_round(winner_index)


func _has_guest() -> bool:
	return _apartment.guest_peer_id != 0 and multiplayer.get_peers().has(_apartment.guest_peer_id)


func _physics_process(delta: float) -> void:
	if not multiplayer.is_server():
		return
	if active:
		var pickup: RigidBody3D = _pickups[item_index]
		var valid := is_instance_valid(pickup) and pickup.is_in_group(&"pickups")
		for player in _players:
			valid = valid and is_instance_valid(player) and not player.is_queued_for_deletion()
		if not valid:
			revision += 1
			cancel_round()
			if _has_guest():
				_sync_cancel.rpc_id(_apartment.guest_peer_id, round_id, revision)
		return
	for index in _players.size():
		if _grab_items[index] < 0:
			continue
		var player: CharacterBody3D = _players[index]
		var pickup: RigidBody3D = _pickups[_grab_items[index]]
		if not is_instance_valid(player) or not player.can_grab(pickup):
			_grab_items[index] = -1
			continue
		_grab_times[index] += delta
		if _grab_times[index] >= player.GRAB_SECONDS or is_equal_approx(_grab_times[index], player.GRAB_SECONDS):
			_grab_items[index] = -1
			player.hold_pickup(pickup)


@rpc("authority", "call_remote", "reliable")
func _sync_cancel(id: int, state_revision: int) -> void:
	if id == round_id and state_revision >= revision:
		revision = state_revision
		cancel_round()


func cancel_round() -> void:
	active = false
	_grab_items = Vector2i(-1, -1)
	for player in _players:
		if is_instance_valid(player):
			player.set_contest_active(false)
	if is_instance_valid(presentation):
		presentation.cancel_contest()


func _exit_tree() -> void:
	cancel_round()
	for player in _players:
		if is_instance_valid(player):
			player.pickup_request_handler = Callable()
