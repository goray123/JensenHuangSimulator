extends SceneTree

# Run this pair alone: --script res://tests/rematch_lan_smoke.gd -- host / guest.
# It shares the normal discovery and ENet ports with the other LAN smoke tests.
const LOBBY := preload("res://lan_lobby.tscn")

class RematchBarrier:
	extends Node
	var stage := 0
	var guest_stage := 0
	@rpc("authority", "call_remote", "reliable")
	func advance(value: int) -> void:
		stage = maxi(stage, value)
	@rpc("any_peer", "call_remote", "reliable")
	func acknowledge(value: int) -> void:
		guest_stage = maxi(guest_stage, value)

var _lobby: Node
var _barrier: RematchBarrier
var _is_host := false
var _failed := false


func _initialize() -> void:
	_run.call_deferred()


func _run() -> void:
	var args := OS.get_cmdline_user_args()
	if args.size() != 1 or args[0] not in ["host", "guest"]:
		push_error("Specify host or guest after --.")
		quit(1)
		return
	_is_host = args[0] == "host"
	create_timer(80.0).timeout.connect(func() -> void:
		push_error("Rematch LAN smoke test timed out (%s)." % args[0])
		quit(1)
	)
	_barrier = RematchBarrier.new()
	_barrier.name = "RematchBarrier"
	root.add_child(_barrier)
	_lobby = LOBBY.instantiate()
	_lobby.play_intro = false
	root.add_child(_lobby)
	if not await _connect_match():
		return
	var first_match: int = _lobby._match_id
	var first_id: int = _lobby._apartment.get_instance_id()
	if not await _finish_round(10):
		return
	if _is_host:
		await _expect(func() -> bool: return _barrier.guest_stage >= 13,
			"The guest's duplicate and invalid requests finish before the host votes")
		_check(_lobby._post_round_choices == [0, 1],
			"Duplicate guest votes count once and invalid/stale requests add no votes")
		_check(_lobby._apartment.get_instance_id() == first_id,
			"One of two votes keeps the ended round in place")
		_vote_rematch()
	else:
		_lobby._receive_post_round_choice.rpc_id(1, first_match, 0)
		_lobby._receive_post_round_choice.rpc_id(1, first_match, -1)
		_lobby._receive_post_round_choice.rpc_id(1, first_match, 3)
		_lobby._receive_post_round_choice.rpc_id(1, first_match - 1, 2)
		_lobby._receive_post_round_choice.rpc_id(1, first_match + 1, 2)
		_vote_rematch()
		_lobby._receive_post_round_choice.rpc_id(1, first_match, 1)
		_lobby._receive_post_round_choice.rpc_id(1, first_match, 1)
		await _expect(func() -> bool: return _lobby._post_round_choices == [0, 1],
			"The guest observes their single synchronized green check")
		_check(_lobby._post_round_menu.indicators[1].choice == 1
			and _lobby._post_round_menu.indicators[0].choice == 0,
			"The guest check belongs to the wife slot on the result menu")
		_barrier.acknowledge.rpc_id(1, 13)
	if not await _fresh_match(first_id, first_match):
		return
	# Old reliable requests must not affect the next apartment at the same NodePath.
	if not _is_host:
		_lobby._receive_post_round_choice.rpc_id(1, first_match, 2)
	await _physics(10)
	_check(_lobby._post_round_menu == null and not _lobby._apartment._round_finished,
		"A previous round's title request cannot close the new match")
	var second_match: int = _lobby._match_id
	var second_id: int = _lobby._apartment.get_instance_id()
	if not await _finish_round(20):
		return
	if _is_host:
		_vote_rematch()
		_barrier.advance.rpc_id(_lobby._apartment.guest_peer_id, 23)
	else:
		await _expect(func() -> bool: return _barrier.stage >= 23,
			"The host casts the first vote in the second match")
		await _expect(func() -> bool: return _lobby._post_round_choices == [1, 0],
			"The next match starts with an empty guest slot and one host check")
		_vote_rematch()
	if not await _fresh_match(second_id, second_match):
		return
	# Either player can replace their own green check with a title X.
	if not await _finish_round(30):
		return
	if _is_host:
		_vote_rematch()
		_barrier.advance.rpc_id(_lobby._apartment.guest_peer_id, 33)
		await _expect(func() -> bool:
			return _barrier.guest_stage >= 33 and _lobby._post_round_choices == [1, 1],
			"Both votes are ready before the host overrides the pending rematch")
		_check(_lobby._post_round_resolution == 1,
			"Two votes schedule the rematch notice before a title decision arrives")
		_lobby._post_round_menu.title_button.pressed.emit()
	else:
		await _expect(func() -> bool:
			return _barrier.stage >= 33 and _lobby._post_round_choices == [1, 0],
			"The host casts the first vote before the guest completes readiness")
		_vote_rematch()
		_barrier.acknowledge.rpc_id(1, 33)
	if not await _title_result(0):
		return
	# Both title screens can create/join a completely new session.
	await create_timer(0.2).timeout
	if not await _connect_match():
		return
	if not await _finish_round(40):
		return
	if not _is_host:
		_vote_rematch()
		await _expect(func() -> bool: return _lobby._post_round_choices == [0, 1],
			"The reconnected guest can cast a fresh rematch vote")
		_lobby._post_round_menu.title_button.pressed.emit()
	if not await _title_result(1):
		return
	_lobby.free()
	if not _failed:
		print("Rematch LAN smoke test passed (%s)." % args[0])
	quit(int(_failed))


func _connect_match() -> bool:
	if _is_host:
		_lobby._host_room()
	else:
		_lobby._find_room()
	if not await _expect(func() -> bool: return _lobby._apartment != null,
		"Both players open the same fresh match", 7.0):
		return false
	await _physics(8)
	_check(not _lobby._apartment._round_finished and _lobby._post_round_menu == null,
		"Connecting starts gameplay without a stale result overlay")
	return true


func _finish_round(stage: int) -> bool:
	var apartment: Node3D = _lobby._apartment
	if _is_host:
		if not await _expect(func() -> bool: return _barrier.guest_stage >= stage,
			"The guest is ready before the host ends this round"):
			return false
		(apartment.get_node("RoundTimer") as Timer).start(0.05)
	else:
		_barrier.acknowledge.rpc_id(1, stage)
	if not await _expect(func() -> bool:
		return apartment._round_finished and _lobby._post_round_menu != null,
		"Timeout opens synchronized result menus"):
		return false
	var menu: CanvasLayer = _lobby._post_round_menu
	_check(not menu.actions_visible and not menu.panel.visible,
		"Neither peer sees the buttons immediately at timeout")
	if _is_host:
		_lobby._request_rematch()
	else:
		# Deliberately bypass the local UI gate to exercise server-side validation.
		_lobby._receive_post_round_choice.rpc_id(1, _lobby._match_id, 1)
	await create_timer(0.2).timeout
	_check(_lobby._post_round_choices == [0, 0],
		"The host rejects rematch requests during the three-second delay")
	if not await _expect(func() -> bool: return menu.actions_visible,
		"Both result menus become interactive after three seconds", 5.0):
		return false
	if _is_host:
		if not await _expect(func() -> bool: return _barrier.guest_stage >= stage + 1,
			"The guest result buttons are ready"):
			return false
		_barrier.advance.rpc_id(apartment.guest_peer_id, stage + 2)
	else:
		_barrier.acknowledge.rpc_id(1, stage + 1)
		if not await _expect(func() -> bool: return _barrier.stage >= stage + 2,
			"Both peers finish checking the result delay before voting"):
			return false
	return true


func _vote_rematch() -> void:
	_lobby._post_round_menu.rematch_button.pressed.emit()


func _fresh_match(previous_id: int, previous_match: int) -> bool:
	if not await _expect(func() -> bool: return _lobby._post_round_choices == [1, 1],
		"Both peers display exactly two synchronized rematch checks"):
		return false
	_check(_lobby._post_round_menu.indicators[0].choice == 1
		and _lobby._post_round_menu.indicators[1].choice == 1,
		"The two ready players appear as green checks before the restart")
	if not await _expect(func() -> bool:
		return _lobby._apartment != null and _lobby._apartment.get_instance_id() != previous_id,
		"Two votes restart the match on both peers"):
		return false
	await _physics(4)
	var apartment: Node3D = _lobby._apartment
	_check(_lobby._match_id > previous_match and not is_instance_id_valid(previous_id)
		and not apartment._round_finished and _lobby._post_round_menu == null,
		"A repeated rematch replaces the old apartment and clears result state")
	_check(apartment.bag_gold() == Vector2i.ZERO and apartment.get_node("HUD/TimeLeft").text == "01:00"
		and apartment.get_node("Player").held_pickup == null and apartment.get_node("Guest").held_pickup == null
		and get_nodes_in_group(&"pickups").size() == 21,
		"Both fresh rounds restore the countdown, players, empty bags and all props")
	return true


func _title_result(player_index: int) -> bool:
	if not await _expect(func() -> bool:
		return _lobby._post_round_choices.size() == 2 and _lobby._post_round_choices[player_index] == 2,
		"One title vote reaches both result menus"):
		return false
	var menu: CanvasLayer = _lobby._post_round_menu
	_check(menu.indicators[player_index].choice == 2
		and menu.rematch_button.disabled and menu.title_button.disabled,
		"The chosen player's check becomes a red X and both actions lock")
	_lobby._request_rematch()
	_check(_lobby._post_round_resolution == 2,
		"A competing rematch cannot replace the shared title decision")
	if not await _expect(func() -> bool: return _lobby._state == _lobby.State.IDLE,
		"A title vote from either player returns both peers to the title", 5.0):
		return false
	_check(_lobby._apartment == null and _lobby._post_round_menu == null and _lobby._peer == null
		and _lobby.get_node("Menu").visible and get_nodes_in_group(&"pickups").is_empty(),
		"Returning both players to the title cleans up the old world and connection")
	return true


func _expect(condition: Callable, message: String, seconds := 4.0) -> bool:
	var deadline := Time.get_ticks_msec() + int(seconds * 1000.0)
	while Time.get_ticks_msec() < deadline:
		if condition.call():
			return true
		await process_frame
	_check(false, message)
	return false


func _check(condition: bool, message: String) -> void:
	if not condition:
		_failed = true
		push_error(message)


func _physics(frames: int) -> void:
	for frame in frames:
		await physics_frame
