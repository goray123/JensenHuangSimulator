class_name Sfx
extends RefCounted

const STREAMS := {
	&"throw_light": preload("res://assets/audio/sfx/throw_light.wav"),
	&"throw_heavy": preload("res://assets/audio/sfx/throw_heavy.wav"),
	&"throw_spin": preload("res://assets/audio/sfx/throw_spin.wav"),
	&"throw_cartoon": preload("res://assets/audio/sfx/throw_cartoon.wav"),
	&"hit_bonk": preload("res://assets/audio/sfx/hit_bonk.wav"),
	&"hit_boing": preload("res://assets/audio/sfx/hit_boing.wav"),
	&"hit_thud": preload("res://assets/audio/sfx/hit_thud.wav"),
	&"hit_soft": preload("res://assets/audio/sfx/hit_soft.wav"),
	&"hit_metal": preload("res://assets/audio/sfx/hit_metal.wav"),
	&"hit_shatter": preload("res://assets/audio/sfx/hit_shatter.wav"),
	&"pickup_grab": preload("res://assets/audio/sfx/pickup_grab.wav"),
	&"pickup_pop": preload("res://assets/audio/sfx/pickup_pop.wav"),
	&"pickup_coin": preload("res://assets/audio/sfx/pickup_coin.wav"),
	&"pickup_powerup": preload("res://assets/audio/sfx/pickup_powerup.wav"),
	&"pickup_sparkle": preload("res://assets/audio/sfx/pickup_sparkle.wav"),
	&"step_wood_1": preload("res://assets/audio/sfx/step_wood_1.wav"),
	&"step_wood_2": preload("res://assets/audio/sfx/step_wood_2.wav"),
	&"step_wood_3": preload("res://assets/audio/sfx/step_wood_3.wav"),
	&"step_wood_4": preload("res://assets/audio/sfx/step_wood_4.wav"),
	&"step_tile_1": preload("res://assets/audio/sfx/step_tile_1.wav"),
	&"step_tile_2": preload("res://assets/audio/sfx/step_tile_2.wav"),
	&"step_tile_3": preload("res://assets/audio/sfx/step_tile_3.wav"),
	&"step_tile_4": preload("res://assets/audio/sfx/step_tile_4.wav"),
	&"step_carpet_1": preload("res://assets/audio/sfx/step_carpet_1.wav"),
	&"step_carpet_2": preload("res://assets/audio/sfx/step_carpet_2.wav"),
	&"step_carpet_3": preload("res://assets/audio/sfx/step_carpet_3.wav"),
	&"step_carpet_4": preload("res://assets/audio/sfx/step_carpet_4.wav"),
	&"step_cartoon_1": preload("res://assets/audio/sfx/step_cartoon_1.wav"),
	&"step_cartoon_2": preload("res://assets/audio/sfx/step_cartoon_2.wav"),
	&"step_cartoon_3": preload("res://assets/audio/sfx/step_cartoon_3.wav"),
	&"step_cartoon_4": preload("res://assets/audio/sfx/step_cartoon_4.wav"),
}
const STEP_PREFIXES := [&"step_wood", &"step_tile", &"step_carpet", &"step_cartoon"]


static func _sound_name(sound: StringName) -> StringName:
	if sound in STEP_PREFIXES:
		return StringName("%s_%d" % [sound, randi_range(1, 4)])
	return sound


static func _parent(anchor: Node) -> Node:
	if not is_instance_valid(anchor) or not anchor.is_inside_tree():
		return null
	var scene := anchor.get_tree().current_scene
	return scene if is_instance_valid(scene) else anchor.get_parent()


static func _bus() -> StringName:
	return &"SFX" if AudioServer.get_bus_index(&"SFX") >= 0 else &"Master"


static func play_at(anchor: Node3D, sound: StringName, volume_db := 0.0, pitch_jitter := 0.05) -> void:
	var parent := _parent(anchor)
	var selected := _sound_name(sound)
	if parent == null or not STREAMS.has(selected):
		return
	var player := AudioStreamPlayer3D.new()
	player.stream = STREAMS[selected]
	player.bus = _bus()
	player.volume_db = volume_db
	player.pitch_scale = randf_range(1.0 - clampf(pitch_jitter, 0.0, 0.9), 1.0 + clampf(pitch_jitter, 0.0, 0.9))
	player.unit_size = 3.0
	player.max_distance = 25.0
	player.process_mode = Node.PROCESS_MODE_ALWAYS
	player.set_meta(&"sfx_name", selected)
	player.set_meta(&"sfx_event", sound)
	player.set_meta(&"sfx_source_id", anchor.get_instance_id())
	player.add_to_group(&"sfx_oneshots")
	player.finished.connect(player.queue_free)
	parent.add_child(player)
	player.global_position = anchor.global_position
	player.play()


static func play_ui(anchor: Node, sound: StringName, volume_db := 0.0) -> void:
	var parent := _parent(anchor)
	var selected := _sound_name(sound)
	if parent == null or not STREAMS.has(selected):
		return
	var player := AudioStreamPlayer.new()
	player.stream = STREAMS[selected]
	player.bus = _bus()
	player.volume_db = volume_db
	player.process_mode = Node.PROCESS_MODE_ALWAYS
	player.set_meta(&"sfx_name", selected)
	player.set_meta(&"sfx_event", sound)
	player.set_meta(&"sfx_source_id", anchor.get_instance_id())
	player.add_to_group(&"sfx_oneshots")
	player.finished.connect(player.queue_free)
	parent.add_child(player)
	player.play()
