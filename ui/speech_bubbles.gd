extends Control
## Cartoon callouts over each character, drawn in screen space and pinned to the player's visual Model:
## - shout bubbles ("내꺼야!!!") in a white pill with a thick black outline that grows with the line;
## - the "으드득!!" crunch burst on a character hit by a thrown item;
## - one-shot marks: sparkle lines on a thrower who hit, anger veins on a victim hit again in a row,
##   "!!" on a thrower who missed twice or more in a row (decided on the host, relayed to the guest);
## - a spinning "loading" wheel while a slowed (heavily loaded) character is running.
## Every peer runs the same game events in the same order, so lines are picked by a per-speaker counter
## instead of randomly: host and guest show the same words.

## Index 0 is the husband and 1 the wife, matching the HUD cards. Edit freely; keep lines short.
const LINES := {
	&"contest": [["내꺼야!!!", "손 떼!!!", "놔라 좀!!"], ["내꺼야!!!", "놔!!!", "저리 비켜!!"]],
	&"throw": [["이거나 먹어랏!!!", "받아랏!!", "피해 보시지!!"], ["이거나 먹어랏!!!", "받아!!", "맛 좀 봐라!!"]],
	&"hit": [["아이고!!", "으악!!", "이 사람이!!"], ["아얏!!", "어머!!", "이 양반이!!"]],
	&"slip": [["어어어?!", "으아악!!"], ["꺄악!!", "미끄러!!"]],
	&"won": [["내 거라고!!", "이겼다!!"], ["내 거라니까!!", "흥!!"]],
	&"lost": [["치사해!!", "두고 봐!!"], ["치사해!!", "기억해 둬!!"]],
	&"bag": [["내 월급이야!!", "챙겼다!!"], ["위자료다!!", "이건 내 몫!!"]],
	# Item status effects (egg, cake, shampoo, coat guard), said when the HUD forwards status_effect_applied.
	&"slow": [["끈적끈적!!", "몸이 무거워!!"], ["으 끈적해!!", "내 머리!!"]],
	&"cake": [["앞이 안 보여!!", "크림 범벅!!"], ["내 화장!!", "앞이 안 보여!!"]],
	&"bubbles": [["눈 따가워!!", "퉤퉤!!"], ["눈 따가워!!", "거품!!"]],
	&"guard": [["어림없지!!", "코트 방패!!"], ["어림없지!!", "막았다!!"]],
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
## The small marks sit around the head: this world point plus a per-mark screen offset (base 1280x720 px).
const MARK_ANCHOR := Vector3(0, 0.95, 0)
const MARKS := {
	&"spark": {"texture": preload("res://assets/Sprites/Effects/HitSpark.png"), "width": 58.0, "offset": Vector2(48, -30)},
	&"angry": {"texture": preload("res://assets/Sprites/Effects/AngerVein.png"), "width": 56.0, "offset": Vector2(-48, -30)},
	&"miss": {"texture": preload("res://assets/Sprites/Effects/MissExclaim.png"), "width": 54.0, "offset": Vector2(48, -36)},
}
const SPINNER := preload("res://assets/Sprites/Effects/SlowSpinner.png")
const SPINNER_WIDTH := 32.0
const SPINNER_OFFSET := Vector2(44, 2)
## The wheel shows while running at or below this share of the full speed (about 15% slower).
const SLOW_SPEED_FACTOR := 0.85
## Twelve spokes, so the wheel ticks one spoke at a time like a loading indicator.
const SPINNER_TICKS_PER_SECOND := 12.0

var _players := {}
var _anchors := {}
var _bubbles := {}
var _crunches := {}
var _crunch_ages := {}
var _marks := {}
var _spinners := {}
var _spin_time := 0.0
var _counts := {}
var _font: Font = SystemFont.new()
var _frame := StyleBoxFlat.new()


func _ready() -> void:
	set_anchors_preset(Control.PRESET_FULL_RECT)
	mouse_filter = Control.MOUSE_FILTER_IGNORE
	# shortcut: uses the OS heavy Korean gothic (Malgun Gothic Bold on Windows); bundle a font file to match exactly on every OS.
	if OS.has_feature("web"):
		# Browsers expose no system fonts to Godot, so the web build draws the bundled Noto Sans KR at the same weight.
		var heavy := FontVariation.new()
		heavy.base_font = load("res://assets/Fonts/NotoSansKR.ttf")
		heavy.variation_opentype = {"wght": 800}
		_font = heavy
	else:
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


# _process runs before scene tweens (like the contest camera zoom), so placement is redone right before
# drawing; otherwise callouts trail their heads by a frame while the camera moves.
func _enter_tree() -> void:
	RenderingServer.frame_pre_draw.connect(_place_all)


func _exit_tree() -> void:
	RenderingServer.frame_pre_draw.disconnect(_place_all)


## Pins index's callouts to the player's visual Model (falls back to the node itself).
func bind(index: int, player: Node3D) -> void:
	_players[index] = player
	_anchors[index] = player.get_node_or_null("Model") as Node3D if player.has_node("Model") else player
	if not _spinners.has(index):
		var wheel := _sprite(SPINNER, SPINNER_WIDTH)
		wheel.name = "Spinner%d" % index
		wheel.modulate.a = 0.0
		wheel.visible = false
		add_child(wheel)
		_spinners[index] = wheel


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
	return _live(_bubbles.get(index)) as PanelContainer


## The crunch burst currently shown on index, or null.
func crunch_burst(index: int) -> TextureRect:
	return _live(_crunches.get(index)) as TextureRect


## The one-shot mark (spark, angry, miss) currently shown on index, or null.
func mark(index: int, kind: StringName) -> TextureRect:
	return _live(_marks.get(Vector2i(index, MARKS.keys().find(kind)))) as TextureRect


## The slow-down wheel of index (always present once bound; check is_visible()).
func spinner(index: int) -> TextureRect:
	return _spinners.get(index)


## Slams a tilted "으드득!!" burst onto the speaker: overshoot pop, short shake, then a puff-out fade.
func crunch(index: int) -> void:
	if not _anchors.has(index):
		return
	_free(_crunches, index)
	_crunch_ages.erase(index)
	var burst := _sprite(CRUNCH, CRUNCH_WIDTH)
	burst.name = "Crunch%d" % index
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
	tween.tween_callback(func() -> void:
		_free(_crunches, index)
		_crunch_ages.erase(index))


## Pops a one-shot mark beside the head: "spark" flashes, "angry" throbs, "miss" wobbles.
func fx(index: int, kind: StringName) -> void:
	if not _anchors.has(index) or not MARKS.has(kind):
		return
	var key := Vector2i(index, MARKS.keys().find(kind))
	_free(_marks, key)
	var spec: Dictionary = MARKS[kind]
	var icon := _sprite(spec.texture, spec.width)
	icon.name = "%s%d" % [String(kind).capitalize(), index]
	icon.set_meta(&"offset", spec.offset)
	icon.scale = Vector2.ONE * 0.3
	add_child(icon)
	_marks[key] = icon
	_place(index)
	var tween := icon.create_tween()
	tween.tween_property(icon, ^"scale", Vector2.ONE * 1.2, 0.08).set_trans(Tween.TRANS_QUAD).set_ease(Tween.EASE_OUT)
	tween.tween_property(icon, ^"scale", Vector2.ONE, 0.1).set_trans(Tween.TRANS_BACK).set_ease(Tween.EASE_OUT)
	match kind:
		&"angry":
			for _beat in 3:
				tween.tween_property(icon, ^"scale", Vector2.ONE * 1.22, 0.12).set_trans(Tween.TRANS_SINE)
				tween.tween_property(icon, ^"scale", Vector2.ONE, 0.14).set_trans(Tween.TRANS_SINE)
		&"miss":
			for tilt: float in [0.22, -0.18, 0.12, 0.0]:
				tween.tween_property(icon, ^"rotation", tilt, 0.09).set_trans(Tween.TRANS_SINE)
			tween.tween_interval(0.3)
		_:
			tween.tween_interval(0.45)
	tween.tween_property(icon, ^"modulate:a", 0.0, 0.2)
	tween.tween_callback(_free.bind(_marks, key))


func clear() -> void:
	for table: Dictionary in [_bubbles, _crunches, _marks]:
		for key: Variant in table.keys():
			_free(table, key)
	_crunch_ages.clear()
	for wheel: TextureRect in _spinners.values():
		wheel.modulate.a = 0.0
		wheel.visible = false


func _show(index: int, text: String) -> void:
	_free(_bubbles, index)
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
	# Bubbles stay under every burst and mark.
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
	tween.tween_callback(_free.bind(_bubbles, index))


func _sprite(texture: Texture2D, width: float) -> TextureRect:
	var sprite := TextureRect.new()
	sprite.texture = texture
	sprite.expand_mode = TextureRect.EXPAND_IGNORE_SIZE
	sprite.stretch_mode = TextureRect.STRETCH_KEEP_ASPECT_CENTERED
	sprite.mouse_filter = Control.MOUSE_FILTER_IGNORE
	sprite.size = Vector2(width, width * texture.get_height() / texture.get_width())
	sprite.pivot_offset = sprite.size * 0.5
	return sprite


func _live(node: Variant) -> Control:
	return node if is_instance_valid(node) and not (node as Node).is_queued_for_deletion() else null


func _free(table: Dictionary, key: Variant) -> void:
	var node: Variant = table.get(key)
	table.erase(key)
	if is_instance_valid(node):
		(node as Node).queue_free()


func _process(delta: float) -> void:
	for index: int in _crunch_ages.keys():
		_crunch_ages[index] += delta
	_spin_time += delta
	for index: int in _spinners:
		var wheel: TextureRect = _spinners[index]
		var player: Node3D = _players.get(index)
		# Heavy loads only show while running; a slowing status effect (egg) shows for its whole duration.
		var slowed: bool = is_instance_valid(player) and (
			(player.has_method(&"is_slowed") and player.is_slowed())
			or (player.has_method(&"move_speed_factor") and player.move_speed_factor() <= SLOW_SPEED_FACTOR
				and player.get(&"motion") in [&"Run", &"RunCarry"]))
		wheel.modulate.a = move_toward(wheel.modulate.a, 1.0 if slowed else 0.0, delta * 6.0)
		wheel.visible = wheel.modulate.a > 0.0
		wheel.rotation = floorf(fposmod(_spin_time * SPINNER_TICKS_PER_SECOND, 12.0)) * TAU / 12.0
	_place_all()


func _place_all() -> void:
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
	var head_point := anchor.global_position + MARK_ANCHOR
	if camera.is_position_behind(head_point):
		return
	var head_screen := camera.unproject_position(head_point)
	for kind: StringName in MARKS:
		var icon := mark(index, kind)
		if icon != null:
			icon.position = head_screen + (icon.get_meta(&"offset") as Vector2) - icon.size * 0.5
	var wheel: TextureRect = _spinners.get(index)
	if wheel != null and wheel.visible:
		wheel.position = head_screen + SPINNER_OFFSET - wheel.size * 0.5
