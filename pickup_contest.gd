extends Node

const PRESENTATION := preload("res://contest_presentation.gd")
const SIMULTANEOUS_WINDOW_MS := 250
const PRESS_ADVANTAGE_TO_WIN := 20
const LOSS_STUN_SECONDS := 2.5

var active := false
var progress := 0.5
var round_id := 0
var revision := 0
var item_index := -1
var holder_index := -1
var presentation: Node

var _apartment: Node3D
var _players: Array = []
var _pickups: Array = []
var _press_difference := 0
var _recent_claims: Dictionary = {}


func setup(apartment: Node3D, players: Array, pickups: Array) -> void:
	_apartment = apartment
	_pickups = pickups.duplicate()
	_players = players.duplicate()
	for player in _players:
		player.pickup_request_handler = request_interaction
		player.pickup_highlight_provider = get_interaction_target
	presentation = PRESENTATION.new()
	presentation.name = "Presentation"
	add_child(presentation)
	presentation.setup(_apartment, _players)
	set_physics_process(false)


func register_opponent(player: CharacterBody3D) -> void:
	if _players.size() != 1 or player == _players[0]:
		return
	_players.append(player)
	player.pickup_request_handler = request_interaction
	player.pickup_highlight_provider = get_interaction_target
	presentation.setup(_apartment, _players)


func request_interaction(player: CharacterBody3D) -> void:
	var player_index := _players.find(player)
	if player_index < 0:
		return
	var requested_item := item_index if active else _find_interaction_item(player_index)
	var requested_round := round_id if active else 0
	if multiplayer.is_server():
		_handle_interaction(player_index, requested_round, requested_item)
	elif player.reads_local_input:
		_request_interaction.rpc_id(1, requested_round, requested_item)


@rpc("any_peer", "call_remote", "reliable")
func _request_interaction(requested_round: int, requested_item: int) -> void:
	if multiplayer.is_server() and _players.size() == 2 and multiplayer.get_remote_sender_id() == _apartment.guest_peer_id:
		_handle_interaction(1, requested_round, requested_item)


func _find_interaction_item(player_index: int) -> int:
	return _pickups.find(get_interaction_target(_players[player_index]))


func get_interaction_target(player: CharacterBody3D) -> RigidBody3D:
	if active or player.held_pickup != null or player.is_stunned():
		return null
	var player_index := _players.find(player)
	if player_index < 0:
		return null
	if _players.size() == 2:
		var other: CharacterBody3D = _players[1 - player_index]
		if other.held_pickup != null and not other.is_stunned():
			if _within_reach(player, other.global_position):
				return other.held_pickup
			for index: int in _recent_claims:
				if other.held_pickup == _pickups[index] and _is_recent_claim_in_reach(player, index):
					return other.held_pickup
	return player.get_pickup_target()


func _handle_interaction(player_index: int, requested_round: int, requested_item: int) -> void:
	if not multiplayer.is_server() or player_index < 0 or player_index >= _players.size():
		return
	if active:
		if requested_round != round_id or requested_item != item_index:
			return
		_press_difference += 1 if player_index == 0 else -1
		progress = clampf(0.5 + float(_press_difference) / (2.0 * PRESS_ADVANTAGE_TO_WIN), 0.0, 1.0)
		presentation.set_progress(progress)
		if abs(_press_difference) >= PRESS_ADVANTAGE_TO_WIN:
			_finish_contest(0 if _press_difference > 0 else 1)
		elif _has_guest():
			_sync_progress.rpc_id(_apartment.guest_peer_id, round_id, progress)
		return
	var player: CharacterBody3D = _players[player_index]
	if requested_round != 0 or player.held_pickup != null or player.is_stunned():
		return
	if _players.size() == 2:
		var other_index := 1 - player_index
		var other: CharacterBody3D = _players[other_index]
		var held_index := _pickups.find(other.held_pickup)
		if held_index >= 0 and not other.is_stunned():
			var close_to_holder := _within_reach(player, other.global_position)
			# The guest may already have received the pickup snapshot, removing its
			# loose target before its E press reaches the server.
			var simultaneous := requested_item in [-1, held_index] and _is_recent_claim_in_reach(player, held_index)
			if close_to_holder or simultaneous:
				_start_contest(held_index, other_index)
				return
	if requested_item < 0 or requested_item >= _pickups.size():
		return
	var pickup: RigidBody3D = _pickups[requested_item]
	if not is_instance_valid(pickup) or not pickup.is_in_group(&"pickups") or not _within_reach(player, pickup.global_position):
		return
	_recent_claims[requested_item] = {"position": pickup.global_position, "time": Time.get_ticks_msec()}
	player.hold_pickup(pickup)


func _within_reach(player: CharacterBody3D, target: Vector3) -> bool:
	var position := player.global_position
	position.y = clampf(target.y, position.y, position.y + 1.8)
	return position.distance_squared_to(target) <= player.PICKUP_RANGE * player.PICKUP_RANGE


func _is_recent_claim_in_reach(player: CharacterBody3D, index: int) -> bool:
	if not _recent_claims.has(index):
		return false
	var claim: Dictionary = _recent_claims[index]
	return Time.get_ticks_msec() - int(claim["time"]) <= SIMULTANEOUS_WINDOW_MS and _within_reach(player, claim["position"])


func _start_contest(pickup_index: int, owner_index: int) -> void:
	round_id += 1
	revision += 1
	_begin_round(round_id, pickup_index, owner_index)
	if _has_guest():
		_sync_start.rpc_id(_apartment.guest_peer_id, round_id, item_index, holder_index, revision, [_players[0].transform, _players[1].transform])


func _begin_round(id: int, pickup_index: int, owner_index: int) -> void:
	round_id = id
	item_index = pickup_index
	holder_index = owner_index
	active = true
	progress = 0.5
	_press_difference = 0
	for player in _players:
		player.set_contest_active(true)
	presentation.start_contest(str(_pickups[item_index].get_meta(&"pickup_name", "구")))
	presentation.set_progress(progress)
	set_physics_process(true)


@rpc("authority", "call_remote", "reliable")
func _sync_start(id: int, pickup_index: int, owner_index: int, state_revision: int, poses: Array) -> void:
	if state_revision < revision or id <= round_id or _players.size() != 2 or pickup_index < 0 or pickup_index >= _pickups.size() or owner_index not in [0, 1] or poses.size() != 2:
		return
	revision = state_revision
	for index in 2:
		_players[index].transform = poses[index]
	_transfer_item(pickup_index, owner_index)
	_begin_round(id, pickup_index, owner_index)


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
	_recent_claims.erase(item_index)
	presentation.set_progress(progress)
	presentation.finish_contest(winner_index)
	set_physics_process(false)


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
	if state_revision < revision or id < round_id or pickup_index < 0 or pickup_index >= _pickups.size() or winner_index not in [0, 1] or _players.size() != 2:
		return
	revision = state_revision
	round_id = id
	item_index = pickup_index
	_complete_round(winner_index)


func _has_guest() -> bool:
	return _apartment.guest_peer_id != 0 and multiplayer.get_peers().has(_apartment.guest_peer_id)


func _physics_process(_delta: float) -> void:
	if not active:
		return
	var valid := is_instance_valid(_pickups[item_index])
	for player in _players:
		valid = valid and is_instance_valid(player) and not player.is_queued_for_deletion()
	if valid:
		valid = _players[holder_index].held_pickup == _pickups[item_index]
	if not valid and multiplayer.is_server():
		revision += 1
		_cancel_round()
		if _has_guest():
			_sync_cancel.rpc_id(_apartment.guest_peer_id, round_id, revision)


@rpc("authority", "call_remote", "reliable")
func _sync_cancel(id: int, state_revision: int) -> void:
	if id == round_id and state_revision >= revision:
		revision = state_revision
		_cancel_round()


func _cancel_round() -> void:
	active = false
	for player in _players:
		if is_instance_valid(player):
			player.set_contest_active(false)
	if is_instance_valid(presentation):
		presentation.cancel_contest()
	set_physics_process(false)


func _exit_tree() -> void:
	_cancel_round()
	for player in _players:
		if is_instance_valid(player):
			player.pickup_request_handler = Callable()
			player.pickup_highlight_provider = Callable()
