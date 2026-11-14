extends Node

const GOLD := Color(0.91, 0.74, 0.29)
const BLUE := Color(0.36, 0.48, 0.94)
const CAMERA_TRANSITION_SECONDS := 0.35
const PLAYER := preload("res://player.gd")
const MOTION_MANIFEST := preload("res://assets/characters/motions/CHARACTER_MOTIONS_MANIFEST.json")
const TUG_SECONDS := {&"Tug_Fast": 1.6, &"Tug_Slow": 4.0}
# A press within this window keeps the fast pull; otherwise the slow strain plays.
const TUG_FAST_WINDOW := 0.6

var active := false
var progress := 0.5
var gauge: ColorRect
## "auto" follows the press rate; "fast"/"slow" force a tempo. Phase is kept across changes.
var tug_tempo: StringName = &"auto"
## Shared normalized tug phase; both characters and the contested object use it.
var tug_phase := 0.0
## Authoritative corrections applied on this peer (guests only).
var tug_syncs := 0

var _tug_pickup: Node3D
var _tug_pickup_rest := Transform3D.IDENTITY
var _tug_center := Vector3.ZERO
var _tug_axis := Vector3.RIGHT
var _tug_paths: Dictionary = {}
var _since_press := INF

var _players: Array[Node3D] = []
var _camera: Camera3D
var _original_transform := Transform3D.IDENTITY
var _original_size := 15.0
var _camera_saved := false
var _camera_tween: Tween
var _result_tween: Tween
var _ui: Control
var _contest_panel: PanelContainer
var _title: Label
var _result: Label


func setup(apartment: Node3D, players: Array) -> void:
	cancel_contest()
	_players.clear()
	for player in players:
		if player is Node3D:
			_players.append(player)
	_camera = apartment.get_node_or_null("Overview") as Camera3D
	var hud := apartment.get_node_or_null("HUD")
	if hud == null:
		return
	if is_instance_valid(_ui):
		_ui.queue_free()
	_build_ui(hud)
	if not get_viewport().size_changed.is_connected(_on_viewport_resized):
		get_viewport().size_changed.connect(_on_viewport_resized)
	_on_viewport_resized()


func start_contest(item_name: String, pickup: Node3D = null) -> void:
	if _players.size() != 2:
		return
	_begin_tug(pickup)
	if not is_instance_valid(_ui):
		return
	_stop_result_tween()
	_result.hide()
	_ui.modulate.a = 1.0
	if not _camera_saved and is_instance_valid(_camera):
		_original_transform = _camera.global_transform
		_original_size = _camera.size
		_camera_saved = true
	active = true
	_title.text = "%s 쟁탈전" % item_name
	_contest_panel.show()
	set_progress(0.5)
	_zoom_to_players()


func set_progress(value: float) -> void:
	if not is_equal_approx(value, progress):
		_since_press = 0.0
	progress = clampf(value, 0.0, 1.0)
	if is_instance_valid(gauge):
		(gauge.material as ShaderMaterial).set_shader_parameter(&"progress", progress)


func finish_contest(winner_index: int) -> void:
	# The winner already holds the item, so only the stance is cleared here.
	_end_tug(false)
	if not active:
		return
	active = false
	_contest_panel.hide()
	_restore_camera(true)
	_result.text = "%s 승리!" % ("남편" if winner_index == 0 else "아내")
	_result.add_theme_color_override(&"font_color", GOLD if winner_index == 0 else BLUE)
	_result.modulate.a = 1.0
	_result.show()
	_stop_result_tween()
	_result_tween = create_tween()
	_result_tween.tween_interval(1.8)
	_result_tween.tween_property(_result, "modulate:a", 0.0, 0.3)
	_result_tween.tween_callback(_result.hide)


func cancel_contest() -> void:
	_end_tug(true)
	active = false
	_stop_result_tween()
	_restore_camera(false)
	if is_instance_valid(_contest_panel):
		_contest_panel.hide()
	if is_instance_valid(_result):
		_result.hide()


func is_tug_fast() -> bool:
	return tug_tempo == &"fast" or (tug_tempo == &"auto" and _since_press < TUG_FAST_WINDOW)


## Applies the host's authoritative phase/tempo; ignored when no tug is running.
func apply_tug_sync(phase: float, fast: bool) -> void:
	if not is_instance_valid(_tug_pickup) or not is_finite(phase):
		return
	tug_syncs += 1
	tug_phase = fposmod(phase, 1.0)
	_since_press = 0.0 if fast else maxf(_since_press, TUG_FAST_WINDOW)
	_apply_tug()


func _begin_tug(pickup: Node3D) -> void:
	_end_tug(true)
	if not is_instance_valid(pickup):
		return
	for player in _players:
		if not is_instance_valid(player):
			return
	_tug_pickup = pickup
	_tug_pickup_rest = pickup.global_transform
	_tug_center = pickup.global_position
	_tug_center.y = (_players[0].global_position.y + _players[1].global_position.y) * 0.5
	var axis := _players[1].global_position - _players[0].global_position
	axis.y = 0.0
	_tug_axis = axis.normalized() if axis.length_squared() > 0.0001 else -_players[0].global_basis.z
	# One controller path for the shared object: player 0's character decides it.
	_tug_paths = MOTION_MANIFEST.data.assets[_players[0].motion_asset()].tug_controller_paths
	tug_phase = 0.0
	_since_press = INF
	for index in 2:
		_players[index].begin_tug(_tug_center, _tug_axis, index)
	_apply_tug()


func _end_tug(restore_pickup: bool) -> void:
	for player in _players:
		if is_instance_valid(player):
			player.end_tug()
	if restore_pickup and is_instance_valid(_tug_pickup) and _tug_pickup.is_in_group(&"pickups"):
		_tug_pickup.global_transform = _tug_pickup_rest
	_tug_pickup = null


func _process(delta: float) -> void:
	if _tug_pickup == null:
		return
	if not is_instance_valid(_tug_pickup):
		_end_tug(false)
		return
	_since_press += delta
	tug_phase = fposmod(tug_phase + delta / float(TUG_SECONDS[&"Tug_Fast" if is_tug_fast() else &"Tug_Slow"]), 1.0)
	_apply_tug()


func _apply_tug() -> void:
	var fast := is_tug_fast()
	for player in _players:
		player.update_tug(tug_phase, fast)
	var path: Array = _tug_paths.Fast if fast else _tug_paths.Slow
	var at := tug_phase * (path.size() - 1)
	var index := mini(floori(at), path.size() - 2)
	var a: Array = path[index].position_godot
	var b: Array = path[index + 1].position_godot
	# Stage x runs from side 0 to side 1; the few-mm stage z sway is not applied.
	var point := Vector2(a[0], a[1]).lerp(Vector2(b[0], b[1]), at - index) * PLAYER.MODEL_SCALE
	var pose := _tug_pickup_rest
	pose.origin = _tug_center + _tug_axis * point.x
	pose.origin.y = maxf(_tug_center.y + point.y, _tug_pickup_rest.origin.y)
	_tug_pickup.global_transform = pose


func _zoom_to_players() -> void:
	if not is_instance_valid(_camera) or _players.size() != 2:
		return
	for player in _players:
		if not is_instance_valid(player):
			return
	_stop_camera_tween()
	var center := (_players[0].global_position + _players[1].global_position) * 0.5 + Vector3.UP * 0.95
	var camera_basis := _original_transform.basis
	var target_transform := Transform3D(camera_basis, center + camera_basis.z * 16.0)
	var extent := Vector2.ZERO
	for player in _players:
		for x in [-0.6, 0.6]:
			for y in [0.0, 1.95]:
				for z in [-0.6, 0.6]:
					var relative: Vector3 = player.global_position + Vector3(x, y, z) - center
					extent.x = maxf(extent.x, absf(relative.dot(camera_basis.x)))
					extent.y = maxf(extent.y, absf(relative.dot(camera_basis.y)))
	var viewport_size := get_viewport().get_visible_rect().size
	var aspect := viewport_size.x / maxf(viewport_size.y, 1.0)
	var target_height := maxf(4.8, maxf(extent.y * 2.0 + 1.0, (extent.x * 2.0 + 1.2) / aspect))
	var target_size := target_height if _camera.keep_aspect == Camera3D.KEEP_HEIGHT else target_height * aspect
	_camera_tween = create_tween().set_parallel(true).set_trans(Tween.TRANS_CUBIC).set_ease(Tween.EASE_OUT)
	_camera_tween.tween_property(_camera, "global_transform", target_transform, CAMERA_TRANSITION_SECONDS)
	_camera_tween.tween_property(_camera, "size", target_size, CAMERA_TRANSITION_SECONDS)


func _restore_camera(smooth: bool) -> void:
	_stop_camera_tween()
	if not _camera_saved or not is_instance_valid(_camera):
		return
	if smooth and is_inside_tree():
		_camera_tween = create_tween().set_parallel(true).set_trans(Tween.TRANS_CUBIC).set_ease(Tween.EASE_IN_OUT)
		_camera_tween.tween_property(_camera, "global_transform", _original_transform, CAMERA_TRANSITION_SECONDS)
		_camera_tween.tween_property(_camera, "size", _original_size, CAMERA_TRANSITION_SECONDS)
		_camera_tween.chain().tween_callback(_finish_camera_restore)
	else:
		_finish_camera_restore()


func _finish_camera_restore() -> void:
	if is_instance_valid(_camera):
		_camera.global_transform = _original_transform
		_camera.size = _original_size
	_camera_saved = false


func _stop_camera_tween() -> void:
	if _camera_tween != null and _camera_tween.is_valid():
		_camera_tween.kill()
	_camera_tween = null


func _stop_result_tween() -> void:
	if _result_tween != null and _result_tween.is_valid():
		_result_tween.kill()
	_result_tween = null


func _build_ui(hud: Node) -> void:
	_ui = Control.new()
	_ui.name = "ContestPresentation"
	_ui.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	_ui.mouse_filter = Control.MOUSE_FILTER_IGNORE
	hud.add_child(_ui)
	_contest_panel = PanelContainer.new()
	_contest_panel.name = "ContestPanel"
	_contest_panel.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_contest_panel.set_anchors_and_offsets_preset(Control.PRESET_BOTTOM_WIDE)
	var background := StyleBoxFlat.new()
	background.bg_color = Color(0.035, 0.045, 0.065, 0.9)
	background.set_corner_radius_all(18)
	background.content_margin_left = 20.0
	background.content_margin_right = 20.0
	background.content_margin_top = 14.0
	background.content_margin_bottom = 14.0
	_contest_panel.add_theme_stylebox_override(&"panel", background)
	_ui.add_child(_contest_panel)
	var column := VBoxContainer.new()
	column.mouse_filter = Control.MOUSE_FILTER_IGNORE
	column.add_theme_constant_override(&"separation", 9)
	_contest_panel.add_child(column)
	_title = _make_label("", 20)
	_title.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	column.add_child(_title)
	var labels := HBoxContainer.new()
	labels.mouse_filter = Control.MOUSE_FILTER_IGNORE
	column.add_child(labels)
	var host_label := _make_label("남편", 17, GOLD)
	host_label.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	host_label.horizontal_alignment = HORIZONTAL_ALIGNMENT_LEFT
	labels.add_child(host_label)
	var guest_label := _make_label("아내", 17, BLUE)
	guest_label.horizontal_alignment = HORIZONTAL_ALIGNMENT_RIGHT
	labels.add_child(guest_label)
	gauge = ColorRect.new()
	gauge.name = "ContestGauge"
	gauge.mouse_filter = Control.MOUSE_FILTER_IGNORE
	gauge.custom_minimum_size = Vector2(0.0, 30.0)
	var shader := Shader.new()
	shader.code = """shader_type canvas_item;
uniform vec2 rect_size = vec2(600.0, 30.0);
uniform float progress : hint_range(0.0, 1.0) = 0.5;
uniform vec4 gold : source_color = vec4(0.91, 0.74, 0.29, 1.0);
uniform vec4 blue : source_color = vec4(0.36, 0.48, 0.94, 1.0);
void fragment() {
	vec2 point = UV * rect_size;
	float radius = rect_size.y * 0.5;
	vec2 q = abs(point - rect_size * 0.5) - vec2(rect_size.x * 0.5 - radius, 0.0);
	float distance_to_edge = length(max(q, vec2(0.0))) + min(max(q.x, q.y), 0.0) - radius;
	float coverage = 1.0 - smoothstep(-0.7, 0.7, distance_to_edge);
	float interior = 1.0 - smoothstep(-2.3, -1.3, distance_to_edge);
	vec3 fill = point.x < rect_size.x * progress ? gold.rgb : blue.rgb;
	float divider = (1.0 - smoothstep(0.6, 1.2, abs(point.x - rect_size.x * progress)));
	if (progress > 0.001 && progress < 0.999) {
		fill = mix(fill, vec3(0.04), divider);
	}
	COLOR = vec4(mix(vec3(0.035), fill, interior), coverage);
}"""
	var material := ShaderMaterial.new()
	material.shader = shader
	gauge.material = material
	gauge.resized.connect(_update_gauge_size)
	column.add_child(gauge)
	_result = _make_label("", 21)
	_result.name = "ContestResult"
	_result.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	_result.set_anchors_and_offsets_preset(Control.PRESET_BOTTOM_WIDE)
	_result.offset_left = 24.0
	_result.offset_right = -24.0
	_result.offset_top = -100.0
	_result.offset_bottom = -32.0
	_ui.add_child(_result)
	_contest_panel.hide()
	_result.hide()


func _make_label(text: String, font_size: int, color := Color(0.94, 0.96, 1.0)) -> Label:
	var label := Label.new()
	label.text = text
	label.mouse_filter = Control.MOUSE_FILTER_IGNORE
	label.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	label.vertical_alignment = VERTICAL_ALIGNMENT_CENTER
	label.add_theme_font_size_override(&"font_size", font_size)
	label.add_theme_color_override(&"font_color", color)
	label.add_theme_color_override(&"font_shadow_color", Color(0.01, 0.015, 0.025, 0.95))
	label.add_theme_constant_override(&"shadow_offset_x", 1)
	label.add_theme_constant_override(&"shadow_offset_y", 2)
	return label


func _on_viewport_resized() -> void:
	if not is_instance_valid(_contest_panel):
		return
	var width := get_viewport().get_visible_rect().size.x
	var panel_width := minf(740.0, maxf(width * 0.64, 320.0))
	panel_width = minf(panel_width, maxf(width - 32.0, 1.0))
	_contest_panel.offset_left = (width - panel_width) * 0.5
	_contest_panel.offset_right = -(width - panel_width) * 0.5
	_contest_panel.offset_top = -150.0
	_contest_panel.offset_bottom = -22.0
	if active:
		_zoom_to_players()


func _update_gauge_size() -> void:
	(gauge.material as ShaderMaterial).set_shader_parameter(&"rect_size", gauge.size)


func _exit_tree() -> void:
	cancel_contest()
	if is_instance_valid(_ui):
		_ui.queue_free()
