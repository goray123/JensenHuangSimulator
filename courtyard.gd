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
const SETTLEMENT := preload("res://settlement.gd")
const FURNITURE_SNAPSHOT_BATCH := 16
## Movement speed multiplier for the final LAST_SPURT_SECONDS of a round.
const LAST_SPURT_SECONDS := 10
const LAST_SPURT_SPEED := 1.2
const COMIC_IMPACT := preload("res://comic_impact.gd")
const COMIC_IMPACT_MERGE_MSEC := 70
const COMIC_IMPACT_MERGE_DISTANCE := 0.3

## Host-decided whole seconds left (the guest receives them in snapshots); not emitted after the round ends.
signal round_seconds_changed(seconds: int)
signal round_ended

var guest_peer_id := 0
## Peer that plays the husband: 1 when the server itself plays him (LAN host), a client id on a
## dedicated server (`-- --server`), where the server only referees.
var host_peer_id := 1
## Off in the tutorial so its scripted win cannot be reversed by a fake ring or a letter.
var settlement_surprises := true
var settlement_rng := RandomNumberGenerator.new()
## Gold after special evidence, set when the round ends (x = husband/host, y = wife/guest).
var final_gold := Vector2i.ZERO
## Last input time per player index from its remote client; -1 until that client has loaded the scene.
var _last_input: Array[int] = [-1, -1]
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
## Host-only throw streaks for the cartoon effects, keyed by player index.
var _miss_streaks := {}
var _hit_streaks := {}
var _last_hit_msec := {}
var _recent_comic_impacts: Array[Dictionary] = []

## A second hit within this window counts as "hit again in a row" (anger veins).
const HIT_STREAK_WINDOW_MSEC := 5000
## Clients ease every snapshot pose in over a few ticks: 30 Hz WebSocket snapshots and network jitter
## then read as smooth motion, and the run animation (which measures per-tick movement) stops flickering.
const POSE_SMOOTHING := 25.0
## Farther than this is a teleport (respawn, drop, rematch): jump instead of sliding across the room.
const POSE_SNAP_DISTANCE := 1.5
## A predicted own player is pulled to the server pose once input has been idle this long...
const PREDICT_SETTLE_MSEC := 200
## ...or at any time once it has drifted this far (the server trails by about speed x latency, ~0.4 m).
const PREDICT_DRIFT := 0.6
var _last_move_input_msec := 0
## Server: last time each furniture batch went out; resting batches are resent only once a second.
var _furniture_sent := {}

## Client: latest server pose (global) per moving body, eased toward every physics tick.
var _pose_targets := {}
const NET_STATS := preload("res://ui/net_stats.gd")
## Client lag readout, only when asked for (see net_stats.gd).
var _net_stats: Label
## Server `-- --netstats`: prints the worst real-time gap between physics ticks every 2 s.
var _server_stats := false
var _last_tick_usec := 0
var _worst_tick_usec := 0
var _next_tick_report := 0


func _log_server_tick() -> void:
	var now := Time.get_ticks_usec()
	if _last_tick_usec > 0:
		_worst_tick_usec = maxi(_worst_tick_usec, now - _last_tick_usec)
	_last_tick_usec = now
	if now >= _next_tick_report:
		print("server: worst tick gap %d ms, fps %d" % [_worst_tick_usec / 1000, Engine.get_frames_per_second()])
		_worst_tick_usec = 0
		_next_tick_report = now + 2000000

@onready var _host: Player = $Player
@onready var _throw_power: ProgressBar = $HUD/ThrowPower
@onready var _grab_progress: ProgressBar = $HUD/GrabProgress
@onready var _round_timer: Timer = $RoundTimer
@onready var _time_left: Label = $HUD/TimeLeft


func _ready() -> void:
	settlement_rng.randomize()
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
		var my_id := multiplayer.get_unique_id()
		_host.reads_local_input = my_id == host_peer_id
		_host.simulates_movement = is_host
		_guest = PLAYER_SCENE.instantiate() as Player
		_guest.name = "Guest"
		_guest.position = to_local($Map/Markers/Player2Spawn.global_position)
		_guest.reads_local_input = my_id == guest_peer_id
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
			_local_player = _host if my_id == host_peer_id else _guest
			_local_player.throw_requested.connect(_send_throw)
			# Over the internet, wait-for-the-server walking feels like lag; walk at once and reconcile.
			_local_player.predicts_movement = _smooths_snapshots()
	# A dedicated server plays nobody: no "you" marker on its spectator screen.
	if _local_player.reads_local_input:
		_local_player.get_node("Head/PlayerPosPointer").show()
	if OS.has_feature("web"):
		# Browsers (often laptop GPUs) render the room without the directional shadow pass.
		$Sun.shadow_enabled = false
	_server_stats = guest_peer_id != 0 and multiplayer.is_server() and OS.get_cmdline_user_args().has("--netstats")
	if guest_peer_id != 0 and not multiplayer.is_server() and NET_STATS.wanted():
		_net_stats = NET_STATS.new()
		_net_stats.name = "NetStats"
		$HUD.add_child(_net_stats)
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
	_local_player.status_effect_applied.connect($HUD.show_hit_splat)
	round_seconds_changed.connect($HUD.on_round_seconds_changed)
	for index in _players.size():
		$HUD.bind_player(index, _players[index])
	_contest = PICKUP_CONTEST.new()
	_contest.name = "PickupContest"
	add_child(_contest)
	_contest.active_changed.connect(_on_contest_active_changed)
	_contest.setup(self, _players, _pickups)
	if guest_peer_id == 0 or multiplayer.is_server():
		for player in _players:
			player.strong_collision.connect(broadcast_comic_impact)
		for index in _pickups.size():
			_pickups[index].banana_landed.connect(_broadcast_banana_peel.bind(index))
			_pickups[index].banana_peel_consumed.connect(_broadcast_banana_peel_consumed.bind(index))
		_round_timer.timeout.connect(_on_round_timeout)
		_round_timer.start()


func _on_contest_active_changed(is_active: bool) -> void:
	if is_instance_valid(_round_timer):
		_round_timer.paused = is_active
	if is_active:
		$HUD.speech.say_all(&"contest")


func _update_throw_power(is_aiming: bool, speed: float) -> void:
	_throw_power.visible = is_aiming
	_throw_power.value = speed


func _update_grab_progress(is_grabbing: bool, progress: float) -> void:
	_grab_progress.visible = is_grabbing
	_grab_progress.value = progress


func _physics_process(_delta: float) -> void:
	if guest_peer_id != 0 and not multiplayer.is_server():
		if _smooths_snapshots():
			_ease_poses(_delta)
		var input := Player.read_movement()
		_receive_movement.rpc_id(1, input, _local_player.local_aim_yaw())
		if _net_stats != null:
			var server_pose: Transform3D = _pose_targets.get(_local_player, _local_player.global_transform)
			_net_stats.on_tick(input, server_pose.origin, _local_player.global_position)
		return
	if _server_stats:
		_log_server_tick()
	var seconds_left := ceili(_round_timer.time_left)
	_update_time_left(seconds_left)
	# Last spurt: everyone runs faster for the final seconds (the host simulates both players).
	var spurt := LAST_SPURT_SPEED if not _round_timer.is_stopped() and seconds_left <= LAST_SPURT_SECONDS else 1.0
	for player in _players:
		player.speed_multiplier = spurt
	if guest_peer_id == 0:
		return
	# A browser client rides one TCP WebSocket through the demo tunnel: 30 snapshots a second keep it
	# from backing up, and a late TCP retransmit must not read as "let go".
	var on_web_socket := multiplayer.multiplayer_peer is WebSocketMultiplayerPeer
	var timeout_ms := INPUT_TIMEOUT_MS * 3 if on_web_socket else INPUT_TIMEOUT_MS
	var now := Time.get_ticks_msec()
	var ready_peers: Array[int] = []
	for index in _players.size():
		var peer := peer_for(index)
		# The first input also signals that this client has loaded the scene.
		if peer <= 1 or _last_input[index] < 0:
			continue
		if now - _last_input[index] > timeout_ms:
			_players[index].remote_input = Vector2.ZERO
			_players[index].remote_aim_yaw = NAN
			_contest.request_interaction(_players[index], false)
		if multiplayer.get_peers().has(peer):
			ready_peers.append(peer)
	if ready_peers.is_empty() or (on_web_socket and Engine.get_physics_frames() % 2 == 1):
		return
	var transforms: Array[Transform3D] = [_host.transform, _guest.transform]
	for pickup in _pickups:
		transforms.append(pickup.global_transform)
	var holding := Vector2i(_pickups.find(_host.held_pickup), _pickups.find(_guest.held_pickup))
	# Keep the same object order, using packed floats to fit one ENet packet.
	var poses := PackedFloat32Array()
	for pose in transforms:
		poses.append_array(PackedFloat32Array([pose.basis.x.x, pose.basis.x.y, pose.basis.x.z, pose.basis.y.x, pose.basis.y.y, pose.basis.y.z, pose.basis.z.x, pose.basis.z.y, pose.basis.z.z, pose.origin.x, pose.origin.y, pose.origin.z]))
	for peer in ready_peers:
		_receive_snapshot.rpc_id(peer, poses, Vector4i(holding.x, holding.y, _ownership_revision, seconds_left))
	# Keep each unreliable packet below the network MTU as the room fills up.
	var furniture: Array[RigidBody3D] = _room_physics.bodies
	for start in range(0, furniture.size(), FURNITURE_SNAPSHOT_BATCH):
		var furniture_poses: Array[Transform3D] = []
		var awake := false
		for index in range(start, mini(start + FURNITURE_SNAPSHOT_BATCH, furniture.size())):
			furniture_poses.append(furniture[index].global_transform)
			awake = awake or not furniture[index].sleeping
		# Over WebSocket, resting furniture is resent once a second instead of 30 times.
		if on_web_socket and not awake and now - int(_furniture_sent.get(start, -100000)) < 1000:
			continue
		_furniture_sent[start] = now
		for peer in ready_peers:
			_apply_furniture_snapshot.rpc_id(peer, start, furniture_poses)


## Only WebSocket clients get 30 Hz snapshots; LAN (ENet, 60 Hz) keeps placing poses exactly as before.
func _smooths_snapshots() -> bool:
	return multiplayer.multiplayer_peer is WebSocketMultiplayerPeer


## Snapshot pose for a client body: eased in over WebSocket, placed at once on LAN.
func _place(body: Node3D, pose: Transform3D) -> void:
	if _smooths_snapshots():
		_pose_targets[body] = pose
	else:
		body.global_transform = pose


func _ease_poses(delta: float) -> void:
	var weight := 1.0 - exp(-POSE_SMOOTHING * delta)
	var now := Time.get_ticks_msec()
	if Player.read_movement().length() >= 0.1:
		_last_move_input_msec = now
	for body: Node3D in _pose_targets.keys():
		if not is_instance_valid(body):
			_pose_targets.erase(body)
			continue
		var target: Transform3D = _pose_targets[body]
		if body == _local_player and _local_player.predicts_movement:
			_correct_prediction(target.origin, weight, now - _last_move_input_msec > PREDICT_SETTLE_MSEC)
			continue
		var current := body.global_transform
		body.global_transform = target if current.origin.distance_to(target.origin) > POSE_SNAP_DISTANCE else current.interpolate_with(target, weight)


## The own player walks locally; it is pulled to the server only when settled or clearly off.
func _correct_prediction(server_position: Vector3, weight: float, settled: bool) -> void:
	var error := server_position - _local_player.global_position
	if error.length() > POSE_SNAP_DISTANCE:
		_local_player.global_position = server_position
	elif settled or error.length() > PREDICT_DRIFT:
		_local_player.global_position += error * weight


## Peer id that plays the given player index (1 = this server plays the husband itself).
func peer_for(player_index: int) -> int:
	return host_peer_id if player_index == 0 else guest_peer_id


## Connected remote clients that play in this match: the guest, plus the husband's client on a dedicated server.
func client_peers() -> Array[int]:
	var peers: Array[int] = []
	for peer in [host_peer_id, guest_peer_id]:
		if peer > 1 and multiplayer.get_peers().has(peer):
			peers.append(peer)
	return peers


## Sends an authority RPC of this node to every client in client_peers().
func _rpc_players(method: StringName, args: Array = []) -> void:
	for peer in client_peers():
		callv(&"rpc_id", [peer, method] + args)


## Player index (0 husband, 1 wife) of the remote client that sent the current RPC, or -1.
func sender_index() -> int:
	if _round_finished or _guest == null or not multiplayer.is_server():
		return -1
	var sender := multiplayer.get_remote_sender_id()
	if sender == guest_peer_id:
		return 1
	if sender == host_peer_id and host_peer_id > 1:
		return 0
	return -1


func _update_time_left(seconds: int) -> void:
	_time_left.text = "%02d:%02d" % [floori(seconds / 60.0), seconds % 60]
	if not _round_finished:
		round_seconds_changed.emit(seconds)


func _on_round_timeout() -> void:
	var entries := settlement()
	if guest_peer_id != 0:
		_end_round.rpc(entries)
	else:
		_end_round(entries)


## Face value of each bag per player index, summed from the host's bag ownership, not the HUD tween.
## Special evidence is only rolled at the end; see settlement() and final_gold.
func bag_gold() -> Vector2i:
	var gold := Vector2i.ZERO
	for pickup_index in _bagged_items:
		gold[_bagged_items[pickup_index]] += _pickups[pickup_index].gold_value
	return gold


## Host-rolled settlement of the current bags, in reveal order (layout in settlement.gd).
func settlement() -> PackedInt32Array:
	var items: Array = []
	for pickup_index in _bagged_items:
		var pickup := _pickups[pickup_index]
		items.append([_bagged_items[pickup_index], pickup_index, str(pickup.get_meta(&"item_id", "")), pickup.gold_value])
	return SETTLEMENT.build(items, settlement_rng, settlement_surprises)


## Entries come from the host: player0 = host/husband, player1 = guest or test dummy/wife.
@rpc("authority", "call_local", "reliable")
func _end_round(entries: PackedInt32Array) -> void:
	if _round_finished:
		return
	if not SETTLEMENT.is_valid(entries, _pickups.size()):
		push_warning("Ignoring an invalid settlement list from the host.")
		entries = PackedInt32Array()
	_round_finished = true
	_pose_targets.clear()
	final_gold = SETTLEMENT.totals(entries)
	_contest.cancel_round()
	_grab_progress.hide()
	_throw_power.hide()
	$HUD.speech.clear()
	$HUD.clear_round_warnings()
	for body in _physics_bodies:
		body.freeze = true
	_update_time_left(0)
	$HUD/RoundEnd.show()
	round_ended.emit()
	process_mode = Node.PROCESS_MODE_DISABLED
	# shortcut: loads the ~30 MB ending synchronously (brief hitch at timeout); preload threaded if it shows.
	var ending: CanvasLayer = load(ENDING_SCENE).instantiate()
	ending.name = "Ending"
	ending.process_mode = Node.PROCESS_MODE_ALWAYS
	add_child(ending)
	ending.show_settlement(_settlement_rows(entries))


## What the ending needs per entry; icons and names come from this peer's copy of the pickup.
func _settlement_rows(entries: PackedInt32Array) -> Array[Dictionary]:
	var rows: Array[Dictionary] = []
	for offset in range(0, entries.size(), SETTLEMENT.STRIDE):
		var pickup := _pickups[entries[offset + 1]]
		rows.append({
			player = entries[offset], icon = pickup.bag_icon if pickup.bag_icon != null else $HUD.FALLBACK_ICON,
			name = $HUD.item_name(pickup), face = pickup.gold_value,
			gold = entries[offset + 2], effect = entries[offset + 3], taken = entries[offset + 4],
		})
	return rows


@rpc("any_peer", "call_remote", "unreliable_ordered")
func _receive_movement(direction: Vector2, aim_yaw: float) -> void:
	var index := sender_index()
	if index >= 0 and direction.is_finite() and not is_inf(aim_yaw):
		var player := _players[index]
		player.remote_input = direction.limit_length()
		player.remote_aim_yaw = aim_yaw if player.held_pickup != null else NAN
		_last_input[index] = Time.get_ticks_msec()


func _send_throw(speed: float, yaw: float) -> void:
	_receive_throw.rpc_id(1, _pickups.find(_local_player.held_pickup), speed, yaw)


@rpc("any_peer", "call_remote", "reliable")
func _receive_throw(pickup_index: int, speed: float, yaw: float) -> void:
	var index := sender_index()
	if index < 0:
		return
	var player := _players[index]
	if player.held_pickup != null and _pickups.find(player.held_pickup) == pickup_index and is_finite(speed) and is_finite(yaw):
		# Throw towards the client's mouse as seen at release, not the last unreliable aim packet.
		player.rotation.y = yaw
		player.remote_aim_yaw = NAN
		player.release_pickup(true, player.throw_velocity_at_speed(speed))


# A validated launch is an ownership change: bumping the revision makes the guest drop older
# snapshots (which could re-attach the item) until this reliable event plays the one-hand Throw.
func _broadcast_throw(pickup: RigidBody3D, player_index: int) -> void:
	if _round_finished or not multiplayer.is_server():
		return
	_ownership_revision += 1
	_rpc_players(&"_apply_throw", [player_index, _pickups.find(pickup), _ownership_revision])


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
	var index := sender_index()
	if index >= 0:
		_bag_held_item(index, pickup_index)


func _bag_held_item(player_index: int, pickup_index: int) -> void:
	var player := _players[player_index]
	if _round_finished or player.contest_active or player.is_slipping() or player.held_pickup == null or pickup_index < 0 or _bagged_items.has(pickup_index) or _pickups.find(player.held_pickup) != pickup_index:
		return
	var revision := _ownership_revision + 1
	_apply_bag_item(player_index, pickup_index, revision)
	_rpc_players(&"_apply_bag_item", [player_index, pickup_index, revision])


@rpc("authority", "call_remote", "reliable")
func _apply_bag_item(player_index: int, pickup_index: int, revision: int) -> void:
	if _round_finished or revision <= _ownership_revision or player_index < 0 or player_index >= _players.size() or pickup_index < 0 or pickup_index >= _pickups.size() or _bagged_items.has(pickup_index):
		return
	var pickup := _pickups[pickup_index]
	if not is_instance_valid(pickup):
		return
	_ownership_revision = revision
	_pose_targets.erase(pickup)
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
	_rpc_players(&"_apply_hit_drops", [candidates, poses, revision])


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
		_place(pickup, poses[slot])
		pickup.add_to_group(&"pickups")
		pickup.show()
		pickup.collision_layer = 2
		pickup.collision_mask = 3
		pickup.freeze = not multiplayer.is_server()
		pickup.linear_velocity = Vector3.ZERO
		pickup.angular_velocity = Vector3.ZERO
		pickup.sleeping = false


func _broadcast_hit(player_index: int) -> void:
	_rpc_players(&"_apply_hit", [player_index, _players[player_index].last_hit_sound])


@rpc("authority", "call_remote", "reliable")
func _apply_hit(player_index: int, sound: StringName = &"") -> void:
	if not _round_finished and player_index >= 0 and player_index < _players.size():
		_players[player_index].receive_hit(sound)


func _broadcast_status_effect(effect: StringName, seconds: float, player_index: int) -> void:
	if not _round_finished:
		_rpc_players(&"_apply_status_effect", [player_index, effect, seconds])


@rpc("authority", "call_remote", "reliable")
func _apply_status_effect(player_index: int, effect: StringName, seconds: float) -> void:
	if not _round_finished and player_index >= 0 and player_index < _players.size():
		_players[player_index].apply_status_effect(effect, seconds)


func _broadcast_banana_peel_stun(player_index: int) -> void:
	_rpc_players(&"_apply_banana_peel_stun", [player_index])


@rpc("authority", "call_remote", "reliable")
func _apply_banana_peel_stun(player_index: int) -> void:
	if not _round_finished and player_index >= 0 and player_index < _players.size():
		_players[player_index].receive_banana_peel()


func _broadcast_banana_peel(landing_transform: Transform3D, pickup_index: int) -> void:
	_rpc_players(&"_apply_banana_peel", [pickup_index, landing_transform])


@rpc("authority", "call_remote", "reliable")
func _apply_banana_peel(pickup_index: int, landing_transform: Transform3D) -> void:
	if pickup_index < 0 or pickup_index >= _pickups.size() or not landing_transform.is_finite():
		return
	var pickup := _pickups[pickup_index]
	if pickup.is_banana_peel:
		return
	_pose_targets.erase(pickup)
	# Landing may arrive before the snapshot that releases the thrower's hand.
	for player in _players:
		if player.held_pickup == pickup:
			player.release_pickup(false)
	pickup.become_banana_peel(landing_transform)


func _broadcast_banana_peel_consumed(pickup_index: int) -> void:
	_rpc_players(&"_apply_banana_peel_consumed", [pickup_index])


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
	if _net_stats != null:
		_net_stats.on_snapshot()
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
		_place(player, global_transform * (transforms[index] as Transform3D))
		if _pickups.find(player.held_pickup) != holding[index]:
			player.release_pickup(false)
	for index in _players.size():
		var pickup_index := holding[index]
		if pickup_index >= 0 and _players[index].held_pickup == null:
			_players[index].hold_pickup(_pickups[pickup_index])
	for index in _pickups.size():
		if index != holding.x and index != holding.y and not _bagged_items.has(index) and is_instance_valid(_pickups[index]) and not _pickups[index].is_banana_peel:
			_place(_pickups[index], transforms[_players.size() + index])
		else:
			# Held, bagged or a peel: the hand, the bag or the peel event places it, never a stale pose.
			_pose_targets.erase(_pickups[index])


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


## The authority chooses the variation once so every peer sees the same contact burst.
func broadcast_comic_impact(world_position: Vector3, strength: float = 1.0) -> void:
	if not multiplayer.is_server() or _round_finished or not world_position.is_finite() or not is_finite(strength):
		return
	var now := Time.get_ticks_msec()
	_recent_comic_impacts = _recent_comic_impacts.filter(func(event: Dictionary) -> bool: return now - int(event.time) < COMIC_IMPACT_MERGE_MSEC)
	for event in _recent_comic_impacts:
		if world_position.distance_to(event.position) < COMIC_IMPACT_MERGE_DISTANCE:
			return
	_recent_comic_impacts.append({time = now, position = world_position})
	var variant := randi_range(0, COMIC_IMPACT.VARIANT_COUNT - 1)
	var intensity := clampf(strength, 0.35, 1.4)
	if guest_peer_id != 0:
		_play_comic_impact.rpc(world_position, variant, intensity)
	else:
		_play_comic_impact(world_position, variant, intensity)


@rpc("authority", "call_local", "reliable")
func _play_comic_impact(world_position: Vector3, variant: int, strength: float) -> void:
	if _round_finished or not world_position.is_finite() or not is_finite(strength) or variant < 0 or variant >= COMIC_IMPACT.VARIANT_COUNT:
		return
	COMIC_IMPACT.spawn(self, world_position, variant, clampf(strength, 0.35, 1.4))


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
	elif guest_peer_id != 0:
		var peer := peer_for(_players.find(thrower))
		if peer in client_peers():
			_play_hit_reward.rpc_id(peer)


@rpc("authority", "call_remote", "reliable")
func _play_hit_reward() -> void:
	if not _round_finished and is_instance_valid(_local_player):
		SFX.play_ui(_local_player, &"pickup_coin", -6.0)


## Host: a thrown item hit another player. The thrower sparkles; a victim hit again within the
## streak window fumes. Landing a hit also ends the thrower's miss streak.
func record_throw_hit(thrower: Node3D, victim: Node3D) -> void:
	if not multiplayer.is_server() or _round_finished:
		return
	var thrower_index := _players.find(thrower)
	var victim_index := _players.find(victim)
	if thrower_index >= 0:
		_miss_streaks[thrower_index] = 0
		_cartoon_fx(thrower_index, &"spark")
	if victim_index >= 0:
		var now := Time.get_ticks_msec()
		var recent: bool = now - int(_last_hit_msec.get(victim_index, -HIT_STREAK_WINDOW_MSEC - 1)) <= HIT_STREAK_WINDOW_MSEC
		_hit_streaks[victim_index] = int(_hit_streaks.get(victim_index, 0)) + 1 if recent else 1
		_last_hit_msec[victim_index] = now
		if _hit_streaks[victim_index] >= 2:
			_cartoon_fx(victim_index, &"angry")


## Host: a thrown item came to rest without hitting anyone. Two or more misses in a row show "!!".
func record_throw_miss(thrower: Node3D) -> void:
	if not multiplayer.is_server() or _round_finished:
		return
	var thrower_index := _players.find(thrower)
	if thrower_index < 0:
		return
	_miss_streaks[thrower_index] = int(_miss_streaks.get(thrower_index, 0)) + 1
	if _miss_streaks[thrower_index] >= 2:
		_cartoon_fx(thrower_index, &"miss")


func _cartoon_fx(player_index: int, kind: StringName) -> void:
	$HUD.speech.fx(player_index, kind)
	_rpc_players(&"_apply_cartoon_fx", [player_index, kind])


@rpc("authority", "call_remote", "reliable")
func _apply_cartoon_fx(player_index: int, kind: StringName) -> void:
	if not _round_finished and player_index >= 0 and player_index < _players.size():
		$HUD.speech.fx(player_index, kind)


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
		_place(furniture[start + index], poses[index])
