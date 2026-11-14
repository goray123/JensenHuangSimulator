extends Control
## Main-menu art: the wife and husband dance on either side while the logo bounces and tilts.
## The party dance is blended with the calm breathing idle and topped with a hop on every beat,
## so it reads as bouncy rather than frantic.

const CourtroomEnding := preload("res://courtroom_ending.gd")
## Party dance v14 (tools/export_title_dance.py) is 150 BPM: one beat every 0.4 s of clip time.
const DANCE_BEAT := 0.4
const DANCE_SPEED := 0.7
## 0 = idle only, 1 = full dance. Halving it halves the arm flaps, hip twists and head recoil.
const DANCE_WEIGHT := 0.5
## Hop height (model units at scale 1) and how much the body squashes as it lands, on every beat.
const BOUNCE_HEIGHT := 0.14
const BOUNCE_SQUASH := 0.07
## Logo tilts left and right on alternate landings and swells by this much on each one.
const WOBBLE_DEGREES := 4.0
const WOBBLE_SCALE := 0.06

var _dancers: Array[Node3D] = []
var _rest: Array[Transform3D] = []
var _trees: Array[AnimationTree] = []

@onready var _logo: TextureRect = $Logo


func _ready() -> void:
	for actor: Node3D in [$Dancers/World/Wife, $Dancers/World/Husband]:
		CourtroomEnding.use_vertex_colors(actor)
		_trees.append(_start_dance(actor))
		_dancers.append(actor)
		_rest.append(actor.transform)
	visibility_changed.connect(_pause_while_hidden)


## The lobby hides the menu during a match; the dancers and logo stop animating there.
func _pause_while_hidden() -> void:
	process_mode = Node.PROCESS_MODE_INHERIT if is_visible_in_tree() else Node.PROCESS_MODE_DISABLED


func _process(_delta: float) -> void:
	# Hop, squash and logo all read the dance's own clock, so they stay on its beat.
	var beats := float(_trees[0].get(&"parameters/Dance/current_position")) / DANCE_BEAT
	# 0 on each beat (feet down), 1 halfway between beats (top of the hop).
	var air := absf(sin(PI * beats))
	var squash := BOUNCE_SQUASH * pow(1.0 - air, 4.0)
	for index in _dancers.size():
		var rest := _rest[index]
		var size := rest.basis.get_scale().y
		_dancers[index].transform = Transform3D(
			rest.basis.scaled(Vector3(1.0 + squash / 2.0, 1.0 - squash, 1.0 + squash / 2.0)),
			rest.origin + Vector3.UP * BOUNCE_HEIGHT * size * air)
	var swing := cos(PI * beats)
	_logo.pivot_offset = _logo.size / 2.0
	_logo.rotation = deg_to_rad(WOBBLE_DEGREES) * swing
	_logo.scale = Vector2.ONE * (1.0 + WOBBLE_SCALE * absf(swing))


## Drives the GLB's AnimationPlayer through a tree: Idle and the slowed Dance mixed at DANCE_WEIGHT.
func _start_dance(actor: Node3D) -> AnimationTree:
	var player := actor.find_children("*", "AnimationPlayer", true, false)[0] as AnimationPlayer
	var prefix := String(player.get_animation_list()[0]).get_slice("__", 0) + "__"
	var graph := AnimationNodeBlendTree.new()
	for clip: StringName in [&"Dance", &"Idle"]:
		player.get_animation(prefix + clip).loop_mode = Animation.LOOP_LINEAR
		var node := AnimationNodeAnimation.new()
		node.animation = prefix + clip
		graph.add_node(clip, node)
	var mix := AnimationNodeBlend2.new()
	# Rest-relative blending swings the hands the long way between the two clips; hands stay on Idle.
	mix.filter_enabled = true
	var dance := player.get_animation(prefix + "Dance")
	for track in dance.get_track_count():
		var path := dance.track_get_path(track)
		if not path.get_concatenated_subnames().begins_with("hand."):
			mix.set_filter_path(path, true)
	graph.add_node(&"Speed", AnimationNodeTimeScale.new())
	graph.add_node(&"Mix", mix)
	graph.connect_node(&"Speed", 0, &"Dance")
	graph.connect_node(&"Mix", 0, &"Idle")
	graph.connect_node(&"Mix", 1, &"Speed")
	graph.connect_node(&"output", 0, &"Mix")
	var tree := AnimationTree.new()
	tree.name = "DanceMix"
	tree.tree_root = graph
	# A sibling shares the player's root node, so the clips' track paths resolve unchanged.
	player.add_sibling(tree)
	tree.anim_player = tree.get_path_to(player)
	tree.set(&"parameters/Mix/blend_amount", DANCE_WEIGHT)
	tree.set(&"parameters/Speed/scale", DANCE_SPEED)
	return tree
