extends SceneTree

# Run two headless instances with --script res://tests/bgm_lan_smoke.gd -- host / guest.
const LOBBY := preload("res://lan_lobby.tscn")

class Barrier:
	extends Node
	var guest_ready := false
	var guest_saw_final := false
	@rpc("any_peer", "call_remote", "reliable")
	func ready_for_clock() -> void:
		guest_ready = true
	@rpc("any_peer", "call_remote", "reliable")
	func saw_final() -> void:
		guest_saw_final = true

var _lobby: Node
var _bgm: Node
var _failed := false
## Every frame of the running round: [whole seconds on the HUD, current track].
var _log: Array = []


func _initialize() -> void:
	_run.call_deferred()


func _run() -> void:
	var args := OS.get_cmdline_user_args()
	if args.size() != 1 or args[0] not in ["host", "guest"]:
		push_error("Specify host or guest after --.")
		quit(1)
		return
	create_timer(40.0).timeout.connect(func() -> void:
		push_error("BGM LAN smoke test timed out (%s)." % args[0])
		quit(1)
	)
	var is_host := args[0] == "host"
	var barrier := Barrier.new()
	barrier.name = "BgmBarrier"
	root.add_child(barrier)
	_lobby = LOBBY.instantiate()
	_lobby.play_intro = false
	root.add_child(_lobby)
	_bgm = _lobby.get_node("Bgm")
	if is_host:
		_lobby._host_room()
		_check(_bgm.current == &"lobby", "A host waiting without START keeps 로비 대기")
	else:
		_lobby._find_room()
		_check(_bgm.current == &"brawl", "Joining a room starts 집안 대난투")
	await _expect(func() -> bool: return _lobby.get_node_or_null("Apartment") != null, "The match map opens")
	var apartment := _lobby.get_node("Apartment")
	var timer := apartment.get_node("RoundTimer") as Timer
	_check(_bgm.current == &"brawl", "Both peers play 집안 대난투 when the match starts")
	var record := func() -> void:
		if is_instance_valid(apartment) and not apartment._round_finished:
			_log.append([_clock(apartment), _bgm.current])
	process_frame.connect(record)
	if is_host:
		await _expect(func() -> bool: return barrier.guest_ready, "The guest finishes its idle-timer check")
		timer.start(20.45)
	else:
		await _frames(30)
		_check(timer.is_stopped() and is_zero_approx(timer.time_left) and _bgm.current == &"brawl",
			"The guest's unstarted local timer (0 s) does not trigger 마지막 한 판")
		barrier.ready_for_clock.rpc_id(1)
	await _expect(func() -> bool: return _clock(apartment) == 21, "The host's 21 s reaches this peer")
	await _frames(3)
	_check(_bgm.current == &"brawl", "21 s left on the host keeps 집안 대난투")
	await _expect(func() -> bool: return _clock(apartment) == 20, "The host's 20 s reaches this peer")
	_check(_bgm.current == &"final", "20 s left on the host switches to 마지막 한 판")
	var final_player := _live_players().back() as AudioStreamPlayer
	await _frames(20)
	_check(_live_players().filter(func(p: Node) -> bool: return p.stream == _bgm.TRACKS[&"final"]) == [final_player],
		"Repeated host updates keep a single final player")
	if is_host:
		await _expect(func() -> bool: return barrier.guest_saw_final, "The guest also switches to 마지막 한 판")
		timer.start(0.3)
	else:
		barrier.saw_final.rpc_id(1)
	await _expect(func() -> bool: return apartment._round_finished, "The round ends on both peers")
	process_frame.disconnect(record)
	_check(_bgm.current == &"", "Round end fades the music out on both peers")
	_check(_log.size() > 40 and _log.all(func(entry: Array) -> bool: return (entry[0] <= 20) == (entry[1] == &"final")),
		"Every round frame plays 마지막 한 판 exactly when the host has 20 s or fewer left")
	if is_host:
		await _expect(func() -> bool: return _lobby.get_node_or_null("Apartment") == null, "The host notices the guest leaving")
		_check(_bgm.current == &"lobby" and _lobby._state == _lobby.State.HOSTING, "A host whose guest disconnected waits on 로비 대기")
	else:
		await create_timer(0.5).timeout
		await _tap(KEY_ESCAPE)
		_check(_lobby._state == _lobby.State.IDLE and _bgm.current == &"lobby", "Esc returns the guest to 로비 대기")
		await create_timer(0.5).timeout
	if not _failed:
		print("BGM LAN smoke test passed (%s)." % args[0])
	quit(int(_failed))


func _clock(apartment: Node) -> int:
	var parts := (apartment.get_node("HUD/TimeLeft") as Label).text.split(":")
	return int(parts[0]) * 60 + int(parts[1])


func _live_players() -> Array:
	return _bgm.get_children().filter(func(node: Node) -> bool: return node is AudioStreamPlayer and not node.is_queued_for_deletion())


func _check(condition: bool, message: String) -> void:
	if not condition:
		_failed = true
		push_error(message)


func _expect(condition: Callable, message: String) -> void:
	for _frame in 900:
		if condition.call():
			return
		await process_frame
	_check(false, message)


func _tap(key: Key) -> void:
	for pressed in [true, false]:
		var event := InputEventKey.new()
		event.keycode = key
		event.physical_keycode = key
		event.pressed = pressed
		Input.parse_input_event(event)
		Input.flush_buffered_events()
	await _frames(2)


func _frames(count: int) -> void:
	for _frame in count:
		await process_frame
