extends CanvasLayer
## End-of-round choices. The lobby owns and synchronizes the actual decisions.

signal rematch_requested
signal title_requested

const SHOW_DELAY_SECONDS := 3.0
const INK := Color(0.19, 0.14, 0.21)
const MINT := Color(0.63, 0.95, 0.91)
const GOLD := Color(1.0, 0.88, 0.35)

var rematch_button: Button
var title_button: Button
var panel: Control
var indicators: Array[Control] = []
var actions_visible := false

var _root: Control
var _slots: Array[Control] = []
var _player_count := 2
var _local_player_index := 0
var _choices: Array[int] = [0, 0]
var _show_at_msec := 0
var _configured := false
var _locked := false


class ChoiceIndicator extends Control:

	var choice := 0:
		set(value):
			choice = value
			queue_redraw()


	func _draw() -> void:
		if choice == 0:
			return
		var center := size * 0.5
		var outline := Color(0.08, 0.05, 0.08, 0.9)
		if choice == 1:
			var points := PackedVector2Array([
				center + Vector2(-11, -1), center + Vector2(-3, 8), center + Vector2(12, -10),
			])
			draw_polyline(points, outline, 7.5, true)
			draw_polyline(points, Color(0.24, 0.94, 0.42), 4.5, true)
		elif choice == 2:
			for direction in [-1, 1]:
				var from := center + Vector2(-10, -10 * direction)
				var to := center + Vector2(10, 10 * direction)
				draw_line(from, to, outline, 7.5, true)
				draw_line(from, to, Color(0.98, 0.2, 0.25), 4.5, true)


func _ready() -> void:
	process_mode = Node.PROCESS_MODE_ALWAYS
	layer = 50
	_ensure_ui()
	get_viewport().size_changed.connect(_resize_actions)
	_resize_actions()


func setup(player_count: int, local_player_index: int) -> void:
	_ensure_ui()
	_player_count = clampi(player_count, 1, 2)
	_local_player_index = clampi(local_player_index, 0, _player_count - 1)
	_choices = [0, 0]
	_show_at_msec = Time.get_ticks_msec() + int(SHOW_DELAY_SECONDS * 1000.0)
	_configured = true
	_locked = false
	actions_visible = false
	panel.hide()
	_refresh_choices()


func set_choices(choices: Array[int]) -> void:
	_ensure_ui()
	for index in range(2):
		_choices[index] = clampi(choices[index], 0, 2) if index < choices.size() else 0
	_refresh_choices()


func lock_actions() -> void:
	_locked = true
	if is_instance_valid(rematch_button):
		_refresh_choices()


func _process(_delta: float) -> void:
	if not _configured or actions_visible:
		return
	if Time.get_ticks_msec() >= _show_at_msec:
		actions_visible = true
		panel.show()


func _refresh_choices() -> void:
	var title_pending := false
	for index in range(2):
		# Waiting players leave no visible slot; selected marks form an anonymous row.
		_slots[index].visible = index < _player_count and _choices[index] != 0
		indicators[index].choice = _choices[index]
		if index < _player_count:
			title_pending = title_pending or _choices[index] == 2
	rematch_button.disabled = _locked or title_pending or _choices[_local_player_index] == 1
	title_button.disabled = _locked or title_pending


func _ensure_ui() -> void:
	if is_instance_valid(_root):
		return
	_root = Control.new()
	_root.name = "PostMatchOverlay"
	_root.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	_root.mouse_filter = Control.MOUSE_FILTER_IGNORE
	add_child(_root)
	var theme := Theme.new()
	theme.default_font_size = 18
	for state in ["font_color", "font_hover_color", "font_pressed_color", "font_focus_color"]:
		theme.set_color(state, "Button", INK)
	theme.set_color("font_disabled_color", "Button", Color(0.46, 0.43, 0.46))
	_root.theme = theme

	var margin := MarginContainer.new()
	margin.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	margin.mouse_filter = Control.MOUSE_FILTER_IGNORE
	for side in ["left", "right", "top", "bottom"]:
		margin.add_theme_constant_override("margin_" + side, 18)
	_root.add_child(margin)
	var stack := _column(margin, 0)
	var spacer := Control.new()
	spacer.mouse_filter = Control.MOUSE_FILTER_IGNORE
	spacer.size_flags_vertical = Control.SIZE_EXPAND_FILL
	stack.add_child(spacer)
	var center := CenterContainer.new()
	center.mouse_filter = Control.MOUSE_FILTER_IGNORE
	stack.add_child(center)
	var actions := HBoxContainer.new()
	actions.name = "PostMatchActions"
	actions.add_theme_constant_override("separation", 14)
	actions.mouse_filter = Control.MOUSE_FILTER_IGNORE
	center.add_child(actions)
	panel = actions
	var rematch_column := _column(actions, 8)
	rematch_column.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	var slots_row := HBoxContainer.new()
	slots_row.alignment = BoxContainer.ALIGNMENT_CENTER
	slots_row.add_theme_constant_override("separation", 6)
	slots_row.custom_minimum_size.y = 36
	slots_row.mouse_filter = Control.MOUSE_FILTER_IGNORE
	rematch_column.add_child(slots_row)
	for index in range(2):
		var slot := HBoxContainer.new()
		slot.name = "Choice%d" % index
		slot.alignment = BoxContainer.ALIGNMENT_CENTER
		slot.mouse_filter = Control.MOUSE_FILTER_IGNORE
		slots_row.add_child(slot)
		_slots.append(slot)
		var indicator := ChoiceIndicator.new()
		indicator.name = "Choice"
		indicator.custom_minimum_size = Vector2(36, 36)
		indicator.mouse_filter = Control.MOUSE_FILTER_IGNORE
		slot.add_child(indicator)
		indicators.append(indicator)
	rematch_button = _button(rematch_column, "Rematch", "리매치", GOLD)
	rematch_button.pressed.connect(func() -> void:
		if actions_visible and not rematch_button.disabled:
			rematch_requested.emit()
	)
	var title_column := _column(actions, 8)
	title_column.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	var title_spacer := Control.new()
	title_spacer.custom_minimum_size.y = 36
	title_spacer.mouse_filter = Control.MOUSE_FILTER_IGNORE
	title_column.add_child(title_spacer)
	title_button = _button(title_column, "ReturnToTitle", "타이틀로 돌아가기", Color.WHITE)
	title_button.pressed.connect(func() -> void:
		if actions_visible and not title_button.disabled:
			title_requested.emit()
	)
	panel.hide()
	_refresh_choices()


func _resize_actions() -> void:
	if is_instance_valid(panel):
		panel.custom_minimum_size.x = minf(680.0, maxf(0.0, get_viewport().get_visible_rect().size.x - 36.0))


func _column(parent: Node, separation: int) -> VBoxContainer:
	var column := VBoxContainer.new()
	column.mouse_filter = Control.MOUSE_FILTER_IGNORE
	column.add_theme_constant_override("separation", separation)
	parent.add_child(column)
	return column


func _button(parent: Node, node_name: String, text: String, fill: Color) -> Button:
	var button := Button.new()
	button.name = node_name
	button.text = text
	button.custom_minimum_size.y = 48
	button.mouse_filter = Control.MOUSE_FILTER_STOP
	button.add_theme_font_size_override("font_size", 20)
	button.add_theme_stylebox_override("normal", _style(fill, 10, 2, 15, 8))
	button.add_theme_stylebox_override("hover", _style(MINT, 10, 2, 15, 8))
	button.add_theme_stylebox_override("pressed", _style(GOLD, 10, 2, 15, 8))
	button.add_theme_stylebox_override("focus", _style(Color(0, 0, 0, 0), 10, 3, 15, 8))
	button.add_theme_stylebox_override("disabled", _style(Color(0.86, 0.87, 0.82), 10, 1, 15, 8))
	parent.add_child(button)
	return button


func _style(fill: Color, radius: int, border: int, horizontal: int, vertical: int) -> StyleBoxFlat:
	var style := StyleBoxFlat.new()
	style.bg_color = fill
	style.border_color = INK
	style.set_border_width_all(border)
	style.set_corner_radius_all(radius)
	style.content_margin_left = horizontal
	style.content_margin_right = horizontal
	style.content_margin_top = vertical
	style.content_margin_bottom = vertical
	return style
