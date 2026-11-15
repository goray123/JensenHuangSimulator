extends CanvasLayer
## A short comic burst pinned to a contact in the 3D world. The stage owns it, so a
## rematch or a return to the title also clears every outstanding burst.

const VARIANT_COUNT := 6
const MAX_ACTIVE := 20
const SIZE_SCALE := 0.7
const LIFETIME := 0.3
const GROW_SECONDS := 0.07
const SETTLE_SECONDS := 0.135
const FADE_SECONDS := 0.1
const FONT := preload("res://assets/Fonts/IntelOneMono-Bold.otf")
const WORDS := ["POW!", "BAM!", "BONK!", "WHAM!", "ZAP!", ""]
const COLORS := [
	Color("fff454"), Color("ffab45"), Color("6be4ff"),
	Color("ff8ebd"), Color("fff5d1"), Color("fff454"),
]
const ANGLES := [-0.09, 0.08, -0.06, 0.11, -0.12, 0.03]

var world_position := Vector3.ZERO
var variant := 0
var strength := 1.0
var age := 0.0
var lifetime := LIFETIME
## Starts close to a point, briefly overshoots one, then settles before fading.
var scale_progress := 0.02
var screen_position := Vector2.ZERO
var screen_visible := false

var _drawing: BurstDrawing


static func spawn(anchor: Node, at: Vector3, chosen_variant: int = -1,
		intensity: float = 1.0) -> CanvasLayer:
	if not is_instance_valid(anchor) or not anchor.is_inside_tree() or not at.is_finite():
		return null
	# Limit this stage only; a preview or another viewport must not clear its peers.
	var siblings: Array[Node] = []
	for candidate in anchor.get_tree().get_nodes_in_group(&"comic_impacts"):
		if candidate.get_parent() == anchor and not candidate.is_queued_for_deletion():
			siblings.append(candidate)
	while siblings.size() >= MAX_ACTIVE:
		siblings.pop_front().queue_free()
	var effect := load("res://comic_impact.gd").new() as CanvasLayer
	effect.world_position = at
	effect.variant = randi_range(0, VARIANT_COUNT - 1) if chosen_variant < 0 else posmod(chosen_variant, VARIANT_COUNT)
	effect.strength = clampf(intensity, 0.6, 1.7) if is_finite(intensity) else 1.0
	anchor.add_child(effect)
	return effect


func _ready() -> void:
	layer = 0
	process_mode = Node.PROCESS_MODE_ALWAYS
	add_to_group(&"comic_impacts")
	_drawing = BurstDrawing.new()
	_drawing.name = "Burst"
	_drawing.variant = variant
	_drawing.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_drawing.focus_mode = Control.FOCUS_NONE
	_drawing.rotation = ANGLES[variant]
	add_child(_drawing)
	_update_projection()


func _process(delta: float) -> void:
	age += delta
	if age >= lifetime:
		queue_free()
		return
	if age < GROW_SECONDS:
		var t := clampf(age / GROW_SECONDS, 0.0, 1.0)
		scale_progress = lerpf(0.02, 1.15, 1.0 - pow(1.0 - t, 3.0))
	else:
		scale_progress = lerpf(1.15, 1.0, smoothstep(GROW_SECONDS, SETTLE_SECONDS, age))
	_drawing.modulate.a = 1.0 - smoothstep(lifetime - FADE_SECONDS, lifetime, age)
	_update_projection()


func _update_projection() -> void:
	var camera := get_viewport().get_camera_3d()
	screen_visible = camera != null and not camera.is_position_behind(world_position)
	_drawing.visible = screen_visible
	if not screen_visible:
		return
	screen_position = camera.unproject_position(world_position)
	_drawing.position = screen_position
	# Estimate a world-sized burst in pixels, with a readable minimum for the room's
	# overview camera. Projection also works for the close-up and ending cameras.
	var edge := camera.unproject_position(world_position + camera.global_basis.x * 1.35)
	var radius := clampf(edge.distance_to(screen_position), 68.0, 108.0)
	var pixel_scale := radius / 90.0 * sqrt(strength) * SIZE_SCALE
	_drawing.scale = Vector2.ONE * pixel_scale * scale_progress


class BurstDrawing extends Control:
	var variant := 0

	func _ready() -> void:
		queue_redraw()

	func _draw() -> void:
		var color: Color = COLORS[variant]
		# Only detached impact strokes and colored lettering draw over the scene.
		_draw_streak(Vector2(-100, -43), Vector2(-120, -55), color)
		_draw_streak(Vector2(96, 47), Vector2(117, 57), color)
		_draw_streak(Vector2(63, -75), Vector2(72, -93), color)
		var word: String = WORDS[variant]
		if not word.is_empty():
			var font_size := 34 if word.length() <= 4 else 30
			var width := FONT.get_string_size(word, HORIZONTAL_ALIGNMENT_LEFT, -1, font_size).x
			var text_at := Vector2(-width * 0.5, 11)
			draw_string_outline(FONT, text_at, word, HORIZONTAL_ALIGNMENT_LEFT, -1, font_size, 5, Color(1, 1, 1, 0.96))
			draw_string_outline(FONT, text_at, word, HORIZONTAL_ALIGNMENT_LEFT, -1, font_size, 3, Color("161016"))
			draw_string(FONT, text_at, word, HORIZONTAL_ALIGNMENT_LEFT, -1, font_size, color)

	func _draw_streak(start: Vector2, end: Vector2, color: Color) -> void:
		draw_line(start, end, Color("161016"), 6.0, true)
		draw_line(start + (end - start).normalized(), end, color, 2.2, true)
