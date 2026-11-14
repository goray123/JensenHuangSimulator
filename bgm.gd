extends Node
## Background music: one non-positional looping track at a time with a short crossfade.
## Requesting the track that is already playing does nothing, so callers may repeat it every frame.

const TRACKS := {
	&"lobby": preload("res://assets/audio/bgm/bgm_lobby_wait.wav"),
	&"brawl": preload("res://assets/audio/bgm/bgm_house_brawl.wav"),
	&"final": preload("res://assets/audio/bgm/bgm_last_round.wav"),
}
const VOLUME_DB := -10.0
const FADE_TIME := 0.6

var current := &""
var _player: AudioStreamPlayer


## Crossfades to track (a TRACKS key); &"" fades the music out.
func play(track: StringName) -> void:
	if track == current or (track != &"" and not TRACKS.has(track)):
		return
	current = track
	if _player != null:
		var old := _player
		var fade := old.create_tween()
		fade.tween_property(old, ^"volume_linear", 0.0, FADE_TIME)
		fade.tween_callback(old.queue_free)
		_player = null
	if track == &"":
		return
	_player = AudioStreamPlayer.new()
	_player.name = "Music_%s" % track
	_player.stream = TRACKS[track]
	_player.bus = &"Master"
	_player.volume_linear = 0.0
	_player.process_mode = Node.PROCESS_MODE_ALWAYS
	add_child(_player)
	_player.play()
	_player.create_tween().tween_property(_player, ^"volume_linear", db_to_linear(VOLUME_DB), FADE_TIME)


func stop() -> void:
	play(&"")
