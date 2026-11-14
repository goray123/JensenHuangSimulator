extends Node3D

const PLAYER_SCENE := preload("res://player.tscn")
const TARGET_COLOR := Color(0.16, 0.65, 0.98)
const PRACTICE_SPAWN := Vector3(6.6, 0.065, -0.9)

var target: CharacterBody3D
var _contest_bot := false
var _bot_tap_elapsed := 0.0

@onready var _apartment: Node3D = get_parent()
@onready var _player: CharacterBody3D = _apartment.get_node("Player")


func _ready() -> void:
	_player.position = PRACTICE_SPAWN
	_player.rotation.y = 0
	var positions := [Vector3(5.9, 0.13666667, -0.85), Vector3(7.3, 0.13666667, -0.8), Vector3(6.6, 0.13666667, -1.8)]
	for index in 3:
		_apartment.get_node("Pickup%d" % (index + 1)).global_position = positions[index]
	target = PLAYER_SCENE.instantiate() as CharacterBody3D
	target.name = "TestTarget"
	target.reads_local_input = false
	target.position = Vector3(6.6, 0.065, -4.0)
	var jacket := StandardMaterial3D.new()
	jacket.albedo_color = TARGET_COLOR
	jacket.roughness = 0.88
	for part in [&"Torso", &"LeftArm", &"RightArm"]:
		target.get_node(NodePath(part)).material_override = jacket
	add_child(target)
	_apartment._contest.register_opponent(target)


func _physics_process(delta: float) -> void:
	if not _contest_bot:
		return
	if not _apartment._contest.active:
		_contest_bot = false
		return
	_bot_tap_elapsed += delta
	if _bot_tap_elapsed >= 0.25:
		_bot_tap_elapsed -= 0.25
		_apartment._contest.request_interaction(target)


func _start_contest_test() -> void:
	if _apartment._contest.active or _player.is_stunned() or target.is_stunned():
		return
	_player.release_pickup(false)
	target.release_pickup(false)
	_player.position = PRACTICE_SPAWN
	target.position = PRACTICE_SPAWN + Vector3.FORWARD
	for pickup: RigidBody3D in _apartment._pickups:
		if pickup.name == &"Pickup3":
			target.hold_pickup(pickup)
			break
	_player.pickup_nearest()
	_contest_bot = _apartment._contest.active
	_bot_tap_elapsed = 0.0


func _unhandled_input(event: InputEvent) -> void:
	if event.is_action_pressed(&"test_hit"):
		_player.receive_hit()
		get_viewport().set_input_as_handled()
	elif event is InputEventKey and event.pressed and not event.echo and event.physical_keycode == KEY_G:
		_start_contest_test()
		get_viewport().set_input_as_handled()
