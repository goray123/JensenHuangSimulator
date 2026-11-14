extends SceneTree

const BGM := preload("res://bgm.gd")
const LENGTHS := { &"lobby": 378000.0 / 44100.0, &"brawl": 6.4, &"final": 252000.0 / 44100.0 }

var failed := false
var _lobby: Node
var _bgm: Node
## Every frame of a running round: [whole seconds on the HUD, current track].
var _log: Array = []


func _initialize() -> void:
	_run.call_deferred()


func _run() -> void:
	create_timer(40.0).timeout.connect(func() -> void:
		push_error("BGM smoke test timed out.")
		quit(1)
	)
	for track: StringName in BGM.TRACKS:
		var stream := BGM.TRACKS[track] as AudioStreamWAV
		_check(stream != null and stream.loop_mode == AudioStreamWAV.LOOP_FORWARD and stream.loop_begin == 0
			and stream.loop_end == int(round(LENGTHS[track] * 44100.0)), "%s is an imported WAV that loops over the whole track" % track)
		_check(stream != null and absf(stream.get_length() - LENGTHS[track]) < 0.01 and stream.mix_rate == 44100,
			"%s keeps its rendered length (%.3f s)" % [track, stream.get_length() if stream else -1.0])

	_lobby = preload("res://lan_lobby.tscn").instantiate()
	_lobby.play_intro = false
	root.add_child(_lobby)
	await _frames(2)
	_bgm = _lobby.get_node("Bgm")
	var start := _lobby.get_node("%Start") as TextureButton
	_check(_bgm.current == &"lobby" and _live_players().size() == 1, "The lobby starts on 로비 대기")
	var lobby_player := _live_players()[0] as AudioStreamPlayer
	_check(lobby_player.playing and lobby_player.stream == BGM.TRACKS[&"lobby"] and lobby_player.bus == &"Master"
		and not lobby_player.is_in_group(&"sfx_oneshots"), "로비 대기 is a non-positional Master-bus player, separate from the SFX one-shots")
	await create_timer(0.8).timeout
	_check(lobby_player.volume_linear > 0.25 and absf(lobby_player.volume_db - BGM.VOLUME_DB) < 0.05, "The lobby track fades in to the music level")
	var position := lobby_player.get_playback_position()
	for _repeat in 30:
		_lobby._show_lobby("")
		_bgm.play(&"lobby")
		await process_frame
	_check(_live_players() == [lobby_player] and lobby_player.get_playback_position() >= position,
		"Repeated lobby requests keep the same player without rewinding (%.3f -> %.3f)" % [position, lobby_player.get_playback_position()])

	start.pressed.emit()
	_check(_bgm.current == &"brawl", "START switches to 집안 대난투 while searching for a room")
	await create_timer(BGM.FADE_TIME + 0.2).timeout
	_check(not is_instance_valid(lobby_player) and _live_players().size() == 1, "The lobby player fades out and is freed")
	await create_timer(1.8).timeout
	_check(_lobby._state == _lobby.State.HOSTING and _bgm.current == &"brawl", "Hosting after START keeps 집안 대난투")
	_lobby.get_node("%Cancel").pressed.emit()
	_check(_bgm.current == &"lobby", "Cancel returns to 로비 대기")
	_lobby._host_room()
	_check(_lobby._state == _lobby.State.HOSTING and _bgm.current == &"lobby", "Opening a room without START does not start the match music")
	_lobby._return_to_menu("")

	await _tap(KEY_F2)
	_check(_bgm.current == &"brawl", "F2 starts 집안 대난투 before the intro/test map")
	await _frames(3)
	var apartment := _lobby.get_node_or_null("Apartment")
	_check(apartment != null and apartment.get_node_or_null("TestMode") != null, "The test map opens")
	var timer := apartment.get_node("RoundTimer") as Timer
	var record := _record.bind(apartment)
	process_frame.connect(record)
	timer.start(20.45)
	await _expect(func() -> bool: return _clock(apartment) == 21, "The HUD shows 21 s")
	await _frames(3)
	_check(_bgm.current == &"brawl", "21 s left keeps 집안 대난투")
	await _expect(func() -> bool: return _clock(apartment) == 20, "The HUD reaches 20 s")
	_check(_bgm.current == &"final", "20 s left switches to 마지막 한 판")
	var final_player := _live_players().back() as AudioStreamPlayer
	await create_timer(0.3).timeout
	position = final_player.get_playback_position()
	await _frames(20)
	_check(_bgm.current == &"final" and _live_players().filter(func(p: Node) -> bool: return p.stream == BGM.TRACKS[&"final"]) == [final_player]
		and final_player.get_playback_position() >= position, "Per-frame 20 s updates keep one final player without rewinding")
	timer.paused = true
	await _frames(10)
	_check(_bgm.current == &"final", "A paused round timer keeps the last-round music")
	timer.paused = false
	process_frame.disconnect(record)
	_check(_log.all(func(entry: Array) -> bool: return (entry[0] <= 20) == (entry[1] == &"final")),
		"Every frame plays 마지막 한 판 exactly when 20 s or fewer are left")

	await _tap(KEY_R)
	await _frames(3)
	apartment = _lobby.get_node("Apartment")
	_check(_bgm.current == &"brawl" and apartment.get_node("RoundTimer").time_left > 50.0, "Restarting the test round resets to 집안 대난투")
	(apartment.get_node("RoundTimer") as Timer).start(0.2)
	await _expect(func() -> bool: return apartment.get_node("HUD/RoundEnd").visible, "The test round times out")
	_check(_bgm.current == &"", "Round end fades the music out for the result screen")
	await create_timer(BGM.FADE_TIME + 0.2).timeout
	_check(_live_players().is_empty(), "No music player is left after the round ends")
	await _tap(KEY_ESCAPE)
	_check(_lobby._state == _lobby.State.IDLE and _bgm.current == &"lobby", "Esc back to the menu restores 로비 대기")

	_lobby._open_tutorial()
	await _frames(10)
	_check(_lobby._state == _lobby.State.TUTORIAL and _bgm.current == &"lobby", "The tutorial (stopped timer, not START) keeps 로비 대기")
	_lobby._return_to_menu("")
	await _frames(2)
	_lobby.free()
	if not failed:
		print("BGM smoke test passed.")
	quit(int(failed))


func _record(apartment: Node) -> void:
	if is_instance_valid(apartment) and not apartment._round_finished:
		_log.append([_clock(apartment), _bgm.current])


func _clock(apartment: Node) -> int:
	var parts := (apartment.get_node("HUD/TimeLeft") as Label).text.split(":")
	return int(parts[0]) * 60 + int(parts[1])


func _live_players() -> Array:
	return _bgm.get_children().filter(func(node: Node) -> bool: return node is AudioStreamPlayer and not node.is_queued_for_deletion())


func _check(condition: bool, message: String) -> void:
	if not condition:
		failed = true
		push_error(message)


func _expect(condition: Callable, message: String) -> void:
	for _frame in 600:
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
