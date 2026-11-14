extends CanvasLayer
## Courtroom result screen. The settlement reveal counts both bags and the special evidence,
## then the gavel picks the outcome; each actor's 6-second clip plays once and holds the last pose.
## The 3D stage lives in its own World3D, so the house never shows through it.

signal verdict_reached(outcome: Outcome)

enum Outcome { DRAW, WIFE_WINS, HUSBAND_WINS }

const WIN_CLIP := &"celebrate_jump"
const LOSE_CLIP := &"defeat_kneel"
const PAINTED_VERTEX_SHADER := preload("res://assets/endings/painted_vertex_color.gdshader")
## English, so the HUD's IntelOneMono font (like the "WIFE" badge) can draw it.
const TITLES := { Outcome.DRAW: "DRAW", Outcome.WIFE_WINS: "WIFE WINS!", Outcome.HUSBAND_WINS: "HUSBAND WINS!" }
const REVEAL := preload("res://settlement_reveal.gd")
const SETTLEMENT := preload("res://settlement.gd")
const ITEM_ICONS := "res://assets/Sprites/Items/Item_%s.png"
const SKIP_GRACE_MSEC := 1000

var outcome := Outcome.DRAW
## Gold after special evidence (x = husband, y = wife); known as soon as the reveal starts.
var final_gold := Vector2i.ZERO
var verdict_shown := false
var reveal: Control
var _reveal_started_msec := 0

@onready var wife_animation: AnimationPlayer = _find_player($View/World/Wife)
@onready var husband_animation: AnimationPlayer = _find_player($View/World/Husband)
@onready var _result: Label = $Result


static func outcome_for(husband_gold: int, wife_gold: int) -> Outcome:
	if wife_gold == husband_gold:
		return Outcome.DRAW
	return Outcome.WIFE_WINS if wife_gold > husband_gold else Outcome.HUSBAND_WINS


func _ready() -> void:
	# Manifest camera: horizontal FOV, kept when the window aspect changes.
	$View/World/Camera3D.look_at_from_position(Vector3(0, 6, 24), Vector3(0, 1.77, -1.8))
	for actor: Node in [$View/World/Wife, $View/World/Husband]:
		use_vertex_colors(actor)
	REVEAL.badge_style(_result, 34)
	# Both actors wait in the neutral pose until the gavel.
	play(Outcome.DRAW)
	_result.text = ""
	if get_tree().current_scene == self:
		show_settlement(preview_rows())


## Rows from courtyard.gd (player0 host = husband, player1 guest = wife), in reveal order.
func show_settlement(rows: Array) -> void:
	if reveal != null:
		return
	reveal = REVEAL.new()
	reveal.name = "Reveal"
	add_child(reveal)
	# Below the result title, above the 3D view.
	move_child(reveal, _result.get_index())
	reveal.finished.connect(_show_verdict)
	_reveal_started_msec = Time.get_ticks_msec()
	reveal.start(rows)
	final_gold = reveal.final_gold


## Jumps straight to the verdict on this screen only (Space, Enter or a click after SKIP_GRACE).
func skip_reveal() -> void:
	if reveal != null and not verdict_shown:
		reveal.skip()


func _unhandled_input(event: InputEvent) -> void:
	# Players are often still mashing the throw button when time runs out.
	if reveal == null or verdict_shown or Time.get_ticks_msec() - _reveal_started_msec < SKIP_GRACE_MSEC:
		return
	var click: bool = event is InputEventMouseButton and event.pressed and event.button_index == MOUSE_BUTTON_LEFT
	if click or event.is_action_pressed(&"ui_accept"):
		skip_reveal()
		get_viewport().set_input_as_handled()


func _show_verdict(gold: Vector2i) -> void:
	if verdict_shown:
		return
	play(outcome_for(gold.x, gold.y))
	_result.text += "\nWIFE %d G   ·   HUSBAND %d G" % [gold.y, gold.x]
	verdict_shown = true
	verdict_reached.emit(outcome)


## Sample bags for running this scene on its own (F6): every kind of evidence, a close finish.
static func preview_rows() -> Array:
	var rows := []
	for item: Array in [
		[0, "Egg", "계란", 10], [1, "Banana", "바나나", 20], [0, "Shampoo", "샴푸", 80], [1, "Kimchi", "김치통", 120],
		[0, "Cake", "케이크", 150], [1, "Shoes", "신발", 180], [0, "FryingPan", "프라이팬", 200], [1, "Desk", "책상", 500],
		[1, "TV", "TV", 900], [0, "Computer", "컴퓨터", 1000],
	]:
		rows.append({player = item[0], icon = load(ITEM_ICONS % item[1]), name = item[2], face = item[3], gold = item[3], effect = SETTLEMENT.Effect.NONE, taken = 0})
	rows.append({player = 0, icon = load(ITEM_ICONS % "PiggyBank"), name = "저금통", face = 0, gold = 340, effect = SETTLEMENT.Effect.PIGGY, taken = 0})
	rows.append({player = 1, icon = load(ITEM_ICONS % "Ring"), name = "반지", face = 800, gold = 50, effect = SETTLEMENT.Effect.RING_FAKE, taken = 0})
	rows.append({player = 1, icon = load(ITEM_ICONS % "Letter"), name = "편지", face = 150, gold = 150, effect = SETTLEMENT.Effect.LETTER_AFFAIR, taken = 500})
	return rows


func play(result: Outcome) -> void:
	outcome = result
	_result.text = TITLES[result]
	if result == Outcome.DRAW:
		# Neutral: both stand in the clips' shared opening pose; nobody celebrates.
		_hold_start(wife_animation)
		_hold_start(husband_animation)
		return
	var wife_wins := result == Outcome.WIFE_WINS
	_play_once(wife_animation, WIN_CLIP if wife_wins else LOSE_CLIP)
	_play_once(husband_animation, LOSE_CLIP if wife_wins else WIN_CLIP)


func _play_once(player: AnimationPlayer, clip: StringName) -> void:
	player.get_animation(clip).loop_mode = Animation.LOOP_NONE
	player.stop()
	player.play(clip)


func _hold_start(player: AnimationPlayer) -> void:
	player.play(WIN_CLIP)
	player.seek(0.0, true)
	player.pause()


## Preserve linear glTF face paint in both Compatibility and linear rendering backends.
## Only per-instance materials change; imported materials and shared meshes stay untouched.
static func use_vertex_colors(actor: Node) -> void:
	for mesh_instance: MeshInstance3D in actor.find_children("*", "MeshInstance3D", true, false):
		var mesh := mesh_instance.mesh as ArrayMesh
		if mesh == null:
			continue
		for surface in mesh.get_surface_count():
			var original := mesh_instance.get_active_material(surface) as BaseMaterial3D
			if original == null or not mesh.surface_get_format(surface) & Mesh.ARRAY_FORMAT_COLOR:
				continue
			var material := ShaderMaterial.new()
			material.shader = PAINTED_VERTEX_SHADER
			material.set_shader_parameter(&"surface_roughness", original.roughness)
			material.set_shader_parameter(&"surface_specular", original.metallic_specular)
			mesh_instance.set_surface_override_material(surface, material)


func _find_player(actor: Node) -> AnimationPlayer:
	return actor.find_children("*", "AnimationPlayer", true, false)[0] as AnimationPlayer
