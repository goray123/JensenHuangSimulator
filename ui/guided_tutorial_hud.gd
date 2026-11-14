extends CanvasLayer
## A small, input-transparent instruction card. Lessons advance through gameplay.

signal retry_requested
signal menu_requested
signal replay_requested

const INK := Color(0.19, 0.14, 0.21)
const CREAM := Color(1.0, 0.98, 0.93)
const MINT := Color(0.63, 0.95, 0.91)
const YELLOW := Color(1.0, 0.88, 0.35)
const FONT := preload("res://assets/Fonts/IntelOneMono-Bold.otf")

var _root: Control
var _lesson_card: PanelContainer
var _stage: Label
var _title: Label
var _instruction: Label
var _hint: Label
var _progress: ProgressBar
var _completion: CenterContainer
var _completion_card: PanelContainer
var _scores: Label


func _ready() -> void:
	process_mode = Node.PROCESS_MODE_ALWAYS
	layer = 30
	_ensure_ui()
	get_viewport().size_changed.connect(_resize_cards)
	_resize_cards()


## index is zero based. The controller supplies one current, actionable lesson.
func set_lesson(index: int, total: int, title: String, instruction: String, hint: String) -> void:
	_ensure_ui()
	_lesson_card.show()
	_completion.hide()
	_stage.text = "%02d / %02d" % [index + 1, total]
	_title.text = title
	_instruction.text = instruction
	_hint.text = hint
	_hint.visible = not hint.is_empty()
	_progress.value = 0.0


## value is normalized from 0.0 to 1.0.
func set_progress(value: float) -> void:
	_ensure_ui()
	_progress.value = clampf(value, 0.0, 1.0)


func show_complete(player_gold: int, opponent_gold: int) -> void:
	_ensure_ui()
	_lesson_card.hide()
	_scores.text = "내 가방  $%d   ·   상대 가방  $%d" % [player_gold, opponent_gold]
	_completion.show()


func _ensure_ui() -> void:
	if is_instance_valid(_root):
		return
	_root = Control.new()
	_root.name = "Overlay"
	_root.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	_root.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_root.theme = _make_theme()
	add_child(_root)

	var margin := MarginContainer.new()
	margin.name = "ScreenMargin"
	margin.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	margin.mouse_filter = Control.MOUSE_FILTER_IGNORE
	for side in ["left", "right", "top", "bottom"]:
		margin.add_theme_constant_override("margin_" + side, 16)
	_root.add_child(margin)
	var layout := _column(margin, "Layout", 0)
	var spacer := Control.new()
	spacer.mouse_filter = Control.MOUSE_FILTER_IGNORE
	spacer.size_flags_vertical = Control.SIZE_EXPAND_FILL
	layout.add_child(spacer)
	var center := CenterContainer.new()
	center.mouse_filter = Control.MOUSE_FILTER_IGNORE
	layout.add_child(center)
	_lesson_card = _card(center, "LessonCard")
	var body := _column(_lesson_card, "Content", 9)
	var header := _row(body, "Header", 14)
	var badge := PanelContainer.new()
	badge.mouse_filter = Control.MOUSE_FILTER_IGNORE
	badge.add_theme_stylebox_override("panel", _style(MINT, 9, 0, 11, 5))
	header.add_child(badge)
	_stage = _label(badge, "Stage", "01 / 07", 16)
	_title = _label(header, "Title", "직접 해보는 튜토리얼", 22)
	_title.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	_button(header, "Retry", "다시 하기", false).pressed.connect(func() -> void: retry_requested.emit())
	_button(header, "Menu", "메뉴", false).pressed.connect(func() -> void: menu_requested.emit())
	_instruction = _label(body, "Instruction", "", 20)
	_instruction.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	_hint = _label(body, "Hint", "", 15)
	_hint.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	_hint.add_theme_color_override("font_color", Color(0.43, 0.36, 0.43))
	_progress = ProgressBar.new()
	_progress.name = "Progress"
	_progress.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_progress.custom_minimum_size.y = 7
	_progress.max_value = 1.0
	_progress.show_percentage = false
	_progress.add_theme_stylebox_override("background", _style(Color(0.87, 0.84, 0.81), 4))
	_progress.add_theme_stylebox_override("fill", _style(MINT, 4))
	body.add_child(_progress)

	_completion = CenterContainer.new()
	_completion.name = "Completion"
	_completion.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_completion.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	_root.add_child(_completion)
	_completion_card = _card(_completion, "CompletionCard")
	var result := _column(_completion_card, "Content", 20)
	var eyebrow := _label(result, "Eyebrow", "직접 해보는 튜토리얼", 16)
	eyebrow.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	var title := _label(result, "Title", "연습 완료!", 34)
	title.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	var message := _label(result, "Message", "물건을 챙기고 상대보다 많은 재산을 모아 보세요.", 19)
	message.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	message.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	_scores = _label(result, "Scores", "", 20)
	_scores.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	var actions := _row(result, "Actions", 14)
	actions.alignment = BoxContainer.ALIGNMENT_CENTER
	_button(actions, "Replay", "처음부터 다시", true).pressed.connect(func() -> void: replay_requested.emit())
	_button(actions, "Menu", "메인 메뉴", false).pressed.connect(func() -> void: menu_requested.emit())
	_completion.hide()


func _resize_cards() -> void:
	var width := get_viewport().get_visible_rect().size.x
	_lesson_card.custom_minimum_size.x = minf(940.0, maxf(0.0, width - 32.0))
	_completion_card.custom_minimum_size.x = minf(640.0, maxf(0.0, width - 32.0))


func _card(parent: Node, node_name: String) -> PanelContainer:
	var card := PanelContainer.new()
	card.name = node_name
	card.mouse_filter = Control.MOUSE_FILTER_IGNORE
	var style := _style(CREAM, 16, 3, 20, 14)
	style.shadow_color = Color(0.0, 0.0, 0.0, 0.25)
	style.shadow_size = 7
	style.shadow_offset = Vector2(0, 4)
	card.add_theme_stylebox_override("panel", style)
	parent.add_child(card)
	return card


func _column(parent: Node, node_name: String, separation: int) -> VBoxContainer:
	var column := VBoxContainer.new()
	column.name = node_name
	column.mouse_filter = Control.MOUSE_FILTER_IGNORE
	column.add_theme_constant_override("separation", separation)
	parent.add_child(column)
	return column


func _row(parent: Node, node_name: String, separation: int) -> HBoxContainer:
	var row := HBoxContainer.new()
	row.name = node_name
	row.mouse_filter = Control.MOUSE_FILTER_IGNORE
	row.add_theme_constant_override("separation", separation)
	parent.add_child(row)
	return row


func _label(parent: Node, node_name: String, text: String, font_size: int) -> Label:
	var label := Label.new()
	label.name = node_name
	label.mouse_filter = Control.MOUSE_FILTER_IGNORE
	label.text = text
	label.add_theme_font_size_override("font_size", font_size)
	parent.add_child(label)
	return label


func _button(parent: Node, node_name: String, text: String, accent: bool) -> Button:
	var button := Button.new()
	button.name = node_name
	button.text = text
	# Mouse buttons also control items; clicking the HUD must stay within the HUD.
	button.mouse_filter = Control.MOUSE_FILTER_STOP
	button.focus_mode = Control.FOCUS_NONE
	button.add_theme_font_size_override("font_size", 16)
	button.add_theme_stylebox_override("normal", _style(YELLOW if accent else Color.WHITE, 9, 2, 14, 8))
	button.add_theme_stylebox_override("hover", _style(MINT, 9, 2, 14, 8))
	button.add_theme_stylebox_override("pressed", _style(YELLOW, 9, 2, 14, 8))
	parent.add_child(button)
	return button


func _make_theme() -> Theme:
	var theme := Theme.new()
	theme.default_font = FONT
	theme.default_font_size = 18
	theme.set_color("font_color", "Label", INK)
	for state in ["font_color", "font_hover_color", "font_pressed_color", "font_focus_color"]:
		theme.set_color(state, "Button", INK)
	return theme


func _style(fill: Color, radius: int, border: int = 0, horizontal: int = 0, vertical: int = 0) -> StyleBoxFlat:
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
