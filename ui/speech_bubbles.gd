extends Control
## Short shout bubbles above each character, like "내꺼야!!!" in a white pill with a thick black outline.
## The pill grows with the line. Every peer runs the same game events in the same order, so lines are
## picked by a per-speaker counter instead of randomly: host and guest show the same words.
## Also draws the "으드득!!" crunch burst on a character hit by a thrown item, behind the bubbles.

## Index 0 is the husband and 1 the wife, matching the HUD cards. Edit freely; keep lines short.
const LINES := {
	&"contest": [["내꺼야!!!", "손 떼!!!", "놔라 좀!!"], ["내꺼야!!!", "놔!!!", "저리 비켜!!"]],
	&"throw": [["이거나 먹어랏!!!", "받아랏!!", "피해 보시지!!"], ["이거나 먹어랏!!!", "받아!!", "맛 좀 봐라!!"]],
	&"hit": [["아이고!!", "으악!!", "이 사람이!!"], ["아얏!!", "어머!!", "이 양반이!!"]],
	&"slip": [["어어어?!", "으아악!!"], ["꺄악!!", "미끄러!!"]],
	&"won": [["내 거라고!!", "이겼다!!"], ["내 거라니까!!", "흥!!"]],
	&"lost": [["치사해!!", "두고 봐!!"], ["치사해!!", "기억해 둬!!"]],
	&"bag": [["내 월급이야!!", "챙겼다!!"], ["위자료다!!", "이건 내 몫!!"]],
}
const SHOW_SECONDS := 1.6
const POP_SECONDS := 0.14
const FADE_SECONDS := 0.25
## Anchors are the players' visual Model (its origin is at the feet), which, unlike the body, steps
## into the tug stance. The bubble bottom sits this far above it, clear of the hair.
const HEAD_OFFSET := Vector3(0, 1.37, 0)
const FONT_SIZE := 28
const CRUNCH := preload("res://assets/Sprites/Effects/HitCrunch.png")
## About 15% of the 1280-wide screen, as in the concept art.
const CRUNCH_WIDTH := 200.0
## Centred on the victim's head so the burst reads as the point of impact.
const CRUNCH_OFFSET := Vector3(0, 0.85, 0)
const CRUNCH_HOLD_SECONDS := 0.45
const CRUNCH_SHAKE_SECONDS := 0.3
const CRUNCH_SHAKE_PIXELS := 7.0

var _anchors := {}
var _bubbles := {}
var _crunches := {}
var _crunch_ages := {}
var _counts := {}
var _font := SystemFont.new()
var _frame := StyleBoxFlat.new()


func _ready() -> void:
	set_anchors_preset(Control.PRESET_FULL_RECT)
	mouse_filter = Control.MOUSE_FILTER_IGNORE
	# shortcut: uses the OS heavy Korean gothic (Malgun Gothic Bold on Windows); bundle a font file to match exactly on every OS.
	_font.font_names = PackedStringArray(["Malgun Gothic", "Apple SD Gothic Neo", "Noto Sans CJK KR", "Noto Sans KR"])
	_font.font_weight = 800
	_frame.bg_color = Color.WHITE
	_frame.border_color = Color.BLACK
	_frame.set_border_width_all(4)
	_frame.set_corner_radius_all(999)
	_frame.content_margin_left = 24.0
	_frame.content_margin_right = 24.0
	_frame.content_margin_top = 4.0
	_frame.content_margin_bottom = 6.0
	set_process(false)


# _process runs before scene tweens (like the contest camera zoom), so placement is redone right before
# drawing; otherwise bubbles trail their heads by a frame while the camera moves.
func _enter_tree() -> void:
	RenderingServer.frame_pre_draw.connect(_place_all)


func _exit_tree() -> void:
	RenderingServer.frame_pre_draw.disconnect(_place_all)


## Follows this node (the player's visual Model) for the speaker at index.
func bind(index: int, anchor: Node3D) -> void:
	_anchors[index] = anchor


## Shows the next line for event above the speaker, replacing that speaker's current bubble.
func say(index: int, event: StringName) -> String:
	if not _anchors.has(index) or not LINES.has(event):
		return ""
	var pool: Array = LINES[event][index % 2]
	var key := Vector2i(index, LINES.keys().find(event))
	var count: int = _counts.get(key, 0)
	_counts[key] = count + 1
	var text: String = pool[count % pool.size()]
	_show(index, text)
	return text


func say_all(event: StringName) -> void:
	for index: int in _anchors:
		say(index, event)


## The bubble currently shown for index, or null.
func bubble(index: int) -> PanelContainer:
	var shown: PanelContainer = _bubbles.get(index)
	return shown if is_instance_valid(shown) and not shown.is_queued_for_deletion() else null


## The crunch burst currently shown on index, or null.
func crunch_burst(index: int) -> TextureRect:
	var shown: TextureRect = _crunches.get(index)
	return shown if is_instance_valid(shown) and not shown.is_queued_for_deletion() else null


## Slams a tilted "으드득!!" burst onto the speaker: overshoot pop, short shake, then a puff-out fade.
func crunch(index: int) -> void:
	if not _anchors.has(index):
		return
	_remove_crunch(index)
	var burst := TextureRect.new()
	burst.name = "Crunch%d" % index
	burst.texture = CRUNCH
	burst.expand_mode = TextureRect.EXPAND_IGNORE_SIZE
	burst.stretch_mode = TextureRect.STRETCH_KEEP_ASPECT_CENTERED
	burst.mouse_filter = Control.MOUSE_FILTER_IGNORE
	burst.size = Vector2(CRUNCH_WIDTH, CRUNCH_WIDTH * CRUNCH.get_height() / CRUNCH.get_width())
	burst.pivot_offset = burst.size * 0.5
	var hits: int = _counts.get(Vector2i(index, -1), 0)
	_counts[Vector2i(index, -1)] = hits + 1
	burst.rotation = deg_to_rad(-7.0 if hits % 2 == 0 else 6.0)
	burst.scale = Vector2.ONE * 0.2
	# On top of every bubble: the impact is the beat the player should notice first.
	add_child(burst)
	_crunches[index] = burst
	_crunch_ages[index] = 0.0
	_place(index)
	var tween := burst.create_tween()
	tween.tween_property(burst, ^"scale", Vector2.ONE * 1.25, 0.07).set_trans(Tween.TRANS_QUAD).set_ease(Tween.EASE_OUT)
	tween.tween_property(burst, ^"scale", Vector2.ONE, 0.12).set_trans(Tween.TRANS_BACK).set_ease(Tween.EASE_OUT)
	tween.tween_interval(CRUNCH_HOLD_SECONDS)
	tween.tween_property(burst, ^"modulate:a", 0.0, 0.22)
	tween.parallel().tween_property(burst, ^"scale", Vector2.ONE * 1.12, 0.22)
	tween.tween_callback(_remove_crunch.bind(index))
	set_process(true)


func clear() -> void:
	for index: int in _bubbles.keys():
		_remove(index)
	for index: int in _crunches.keys():
		_remove_crunch(index)
	set_process(false)


func _show(index: int, text: String) -> void:
	_remove(index)
	var shown := PanelContainer.new()
	shown.name = "Bubble%d" % index
	shown.mouse_filter = Control.MOUSE_FILTER_IGNORE
	shown.add_theme_stylebox_override(&"panel", _frame)
	var label := Label.new()
	label.text = text
	label.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	label.add_theme_font_override(&"font", _font)
	label.add_theme_font_size_override(&"font_size", FONT_SIZE)
	label.add_theme_color_override(&"font_color", Color.BLACK)
	shown.add_child(label)
	# A line said while the speaker is being crunched stays above the burst for its whole life (no jump).
	shown.set_meta(&"above_crunch", crunch_burst(index) != null)
	add_child(shown)
	move_child(shown, 0)
	shown.size = shown.get_combined_minimum_size()
	shown.pivot_offset = Vector2(shown.size.x * 0.5, shown.size.y)
	shown.scale = Vector2.ONE * 0.5
	_bubbles[index] = shown
	_place(index)
	var tween := shown.create_tween()
	tween.tween_property(shown, ^"scale", Vector2.ONE, POP_SECONDS).set_trans(Tween.TRANS_BACK).set_ease(Tween.EASE_OUT)
	tween.tween_interval(SHOW_SECONDS)
	tween.tween_property(shown, ^"modulate:a", 0.0, FADE_SECONDS)
	tween.tween_callback(_remove.bind(index))
	set_process(true)


func _remove(index: int) -> void:
	var shown: PanelContainer = _bubbles.get(index)
	_bubbles.erase(index)
	if is_instance_valid(shown):
		shown.queue_free()


func _remove_crunch(index: int) -> void:
	var shown: TextureRect = _crunches.get(index)
	_crunches.erase(index)
	_crunch_ages.erase(index)
	if is_instance_valid(shown):
		shown.queue_free()


func _process(delta: float) -> void:
	for index: int in _crunch_ages.keys():
		_crunch_ages[index] += delta
	_place_all()
	set_process(not (_bubbles.is_empty() and _crunches.is_empty()))


func _place_all() -> void:
	if _bubbles.is_empty() and _crunches.is_empty():
		return
	for index: int in _anchors:
		_place(index)


func _place(index: int) -> void:
	var anchor: Node3D = _anchors.get(index)
	var camera := get_viewport().get_camera_3d()
	if not is_instance_valid(anchor) or camera == null:
		return
	var shown := bubble(index)
	if shown != null:
		var head := anchor.global_position + HEAD_OFFSET
		var bottom := camera.unproject_position(head)
		if shown.get_meta(&"above_crunch", false):
			var crunch_top := camera.unproject_position(anchor.global_position + CRUNCH_OFFSET).y - CRUNCH_WIDTH * CRUNCH.get_height() / CRUNCH.get_width() * 0.5
			bottom.y = minf(bottom.y, crunch_top - 4.0)
		shown.visible = not camera.is_position_behind(head)
		shown.position = bottom - Vector2(shown.size.x * 0.5, shown.size.y)
	var burst := crunch_burst(index)
	if burst != null:
		var impact := anchor.global_position + CRUNCH_OFFSET
		# A decaying jitter right after the slam sells the impact without moving the camera.
		var age: float = _crunch_ages.get(index, 0.0)
		var strength := CRUNCH_SHAKE_PIXELS * maxf(0.0, 1.0 - age / CRUNCH_SHAKE_SECONDS)
		var shake := Vector2(sin(age * 95.0), cos(age * 71.0)) * strength
		burst.visible = not camera.is_position_behind(impact)
		burst.position = camera.unproject_position(impact) - burst.size * 0.5 + shake
