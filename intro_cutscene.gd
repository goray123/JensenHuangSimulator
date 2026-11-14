extends CanvasLayer
## Comic intro shown before entering the game.
## Toon1~5 slide in one by one on a black screen, then Toon6 slides in under them and plays its video.
## Each panel moves on after a click or 0.6 s after it settles; clicks also skip the video.

signal finished

## Every panel image shares this page size; Toon6's video covers VIDEO_RECT of it.
const PAGE_SIZE := Vector2(2360, 1640)
const VIDEO_RECT := Rect2(6, 32, 2360, 1573)
const SLIDE_DISTANCE := 40.0
const ENTER_TIME := 0.5
const HOLD_TIME := 0.6
const END_DELAY := 0.5
const PANELS: Array[Texture2D] = [
	preload("res://assets/Sprites/TitleScene/Cutscene/Toon1.png"),
	preload("res://assets/Sprites/TitleScene/Cutscene/Toon2.png"),
	preload("res://assets/Sprites/TitleScene/Cutscene/Toon3.png"),
	preload("res://assets/Sprites/TitleScene/Cutscene/Toon4.png"),
	preload("res://assets/Sprites/TitleScene/Cutscene/Toon5.png"),
]
## Direction each Toon comes from (Toon1~6).
const FROM: Array[Vector2] = [Vector2.UP, Vector2.LEFT, Vector2.UP, Vector2.UP, Vector2.DOWN, Vector2.UP]
const VIDEO := preload("res://assets/Sprites/TitleScene/Toon6_Anim.ogv")
const FIRST_FRAME := preload("res://assets/Sprites/TitleScene/Cutscene/Toon6_First.png")
const LAST_FRAME := preload("res://assets/Sprites/TitleScene/Cutscene/Toon6_Last.png")

var _page: Control
var _steps: Array[Control] = []
var _video: VideoStreamPlayer
var _poster: TextureRect
var _waiting: Label
var _step := -1
var _token := 0
var _tween: Tween
var _scale := 1.0
var _ending := false


func _ready() -> void:
	layer = 100
	var black := ColorRect.new()
	black.color = Color.BLACK
	black.set_anchors_preset(Control.PRESET_FULL_RECT)
	add_child(black)

	var view := get_viewport().get_visible_rect().size
	_scale = minf(view.x / VIDEO_RECT.size.x, view.y / VIDEO_RECT.size.y)
	_page = Control.new()
	_page.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_page.texture_filter = CanvasItem.TEXTURE_FILTER_LINEAR_WITH_MIPMAPS
	_page.size = PAGE_SIZE
	_page.scale = Vector2.ONE * _scale
	_page.position = (view - VIDEO_RECT.size * _scale) / 2.0 - VIDEO_RECT.position * _scale
	add_child(_page)

	# Toon6 is added first so it sits under every other Toon.
	var toon6 := Control.new()
	toon6.mouse_filter = Control.MOUSE_FILTER_IGNORE
	toon6.size = PAGE_SIZE
	_poster = _make_rect(FIRST_FRAME, VIDEO_RECT)
	toon6.add_child(_poster)
	_video = VideoStreamPlayer.new()
	_video.stream = VIDEO
	_video.expand = true
	_video.position = VIDEO_RECT.position
	_video.size = VIDEO_RECT.size
	_video.visible = false
	_video.finished.connect(_end_video)
	toon6.add_child(_video)
	_page.add_child(toon6)
	for texture in PANELS:
		_steps.append(_make_rect(texture, Rect2(Vector2.ZERO, PAGE_SIZE)))
		_page.add_child(_steps.back())
	_steps.append(toon6)
	for node in _steps:
		node.hide()

	_waiting = Label.new()
	_waiting.text = "상대를 기다리는 중…"
	_waiting.add_theme_font_size_override(&"font_size", 22)
	_waiting.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	_waiting.set_anchors_and_offsets_preset(Control.PRESET_CENTER_BOTTOM)
	_waiting.offset_left = -200.0
	_waiting.offset_right = 200.0
	_waiting.offset_top = -48.0
	_waiting.offset_bottom = -16.0
	_waiting.hide()
	add_child(_waiting)

	_next()


## Shown when this player finished the intro but the other player is still watching.
func show_waiting() -> void:
	_waiting.show()


func _make_rect(texture: Texture2D, rect: Rect2) -> TextureRect:
	var node := TextureRect.new()
	node.texture = texture
	node.expand_mode = TextureRect.EXPAND_IGNORE_SIZE
	node.mouse_filter = Control.MOUSE_FILTER_IGNORE
	node.position = rect.position
	node.size = rect.size
	return node


func _next() -> void:
	_step += 1
	_token += 1
	var node := _steps[_step]
	node.position = FROM[_step] * SLIDE_DISTANCE / _scale
	node.modulate.a = 0.0
	node.show()
	_tween = create_tween().set_parallel().set_trans(Tween.TRANS_CUBIC).set_ease(Tween.EASE_OUT)
	_tween.tween_property(node, ^"position", Vector2.ZERO, ENTER_TIME)
	_tween.tween_property(node, ^"modulate:a", 1.0, ENTER_TIME)
	_tween.finished.connect(_on_entered.bind(_token))


func _on_entered(token: int) -> void:
	if token != _token:
		return
	if _step == _steps.size() - 1:
		_play_video()
	else:
		get_tree().create_timer(HOLD_TIME).timeout.connect(_hold_done.bind(token))


func _hold_done(token: int) -> void:
	if token == _token:
		_next()


func _snap_current() -> void:
	if _tween != null and _tween.is_valid():
		_tween.kill()
	var node := _steps[_step]
	node.position = Vector2.ZERO
	node.modulate.a = 1.0


func _play_video() -> void:
	_token += 1
	_video.show()
	_video.play()


func _end_video() -> void:
	if _ending:
		return
	_ending = true
	_video.stop()
	_video.hide()
	_poster.texture = LAST_FRAME
	get_tree().create_timer(END_DELAY).timeout.connect(finished.emit)


func _input(event: InputEvent) -> void:
	if not (event is InputEventMouseButton or event is InputEventMouseMotion):
		return
	get_viewport().set_input_as_handled()
	if not (event is InputEventMouseButton and event.pressed and event.button_index == MOUSE_BUTTON_LEFT) or _ending:
		return
	if _video.is_playing():
		_end_video()
		return
	_snap_current()
	if _step == _steps.size() - 1:
		_play_video()
	else:
		_next()
