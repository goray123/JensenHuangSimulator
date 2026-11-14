extends Node3D

const SFX := preload("res://sfx.gd")

const PLAYER_SCENE := preload("res://player.tscn")
const TARGET_MODEL := preload("res://assets/characters/motions/02_Woman.glb")
const PRACTICE_SPAWN := Vector3(6.6, 0.065, -0.9)

var target: CharacterBody3D
var _contest_bot := false
var _bot_tap_elapsed := 0.0

@onready var _apartment: Node3D = get_parent()
@onready var _player: CharacterBody3D = _apartment.get_node("Player")
@onready var _practice_item: RigidBody3D = _apartment.get_node("Items/Item_01_banana")


func _ready() -> void:
	_player.position = PRACTICE_SPAWN
	_player.rotation.y = 0
	_practice_item.global_position = Vector3(6.6, 0.065, -1.8)
	(_apartment.get_node("Items/Item_06_egg") as RigidBody3D).global_position = Vector3(5.9, 0.065, -0.85)
	(_apartment.get_node("Items/Item_12_ring") as RigidBody3D).global_position = Vector3(7.3, 0.065, -0.8)
	target = PLAYER_SCENE.instantiate() as CharacterBody3D
	target.name = "TestTarget"
	target.reads_local_input = false
	target.position = Vector3(6.6, 0.065, -4.0)
	target.model_scene = TARGET_MODEL
	add_child(target)
	_apartment._contest.register_opponent(target)
	_apartment.get_node("HUD").bind_player(1, target)
	target.hit_received.connect(_on_target_hit)
	# Index 1 gives the dummy the guest (wife) bag, so hit drops can be tested offline.
	_apartment._players.append(target)


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
	if not _practice_item.is_in_group(&"pickups"):
		return
	_practice_item.freeze = true
	_practice_item.global_position = PRACTICE_SPAWN + Vector3.FORWARD * 0.5
	_apartment._contest.request_interaction(_player, true, _practice_item)
	_apartment._contest.request_interaction(target, true, _practice_item)
	_contest_bot = _apartment._contest.active
	_bot_tap_elapsed = 0.0


## Tops the dummy up to one item in hand and two in its bag.
func _load_target() -> void:
	if _apartment._contest.active:
		return
	var practice_items := [_practice_item, _apartment.get_node("Items/Item_06_egg"), _apartment.get_node("Items/Item_12_ring")]
	var owned := 1 if target.held_pickup != null else 0
	owned += _apartment._bagged_items.values().count(1)
	for pickup: RigidBody3D in _apartment._pickups:
		if owned >= 3:
			return
		if not pickup.is_in_group(&"pickups") or pickup in practice_items:
			continue
		if target.held_pickup == null:
			target.hold_pickup(pickup)
		else:
			_apartment._apply_bag_item(1, _apartment._pickups.find(pickup), _apartment._ownership_revision + 1)
		owned += 1


func _unhandled_input(event: InputEvent) -> void:
	if event.is_action_pressed(&"test_hit"):
		_player.receive_hit()
		get_viewport().set_input_as_handled()
	elif event is InputEventKey and event.pressed and not event.echo and event.physical_keycode == KEY_G:
		_start_contest_test()
		get_viewport().set_input_as_handled()
	elif event is InputEventKey and event.pressed and not event.echo and event.physical_keycode == KEY_F3:
		_load_target()
		get_viewport().set_input_as_handled()


func _on_target_hit() -> void:
	SFX.play_ui(self, &"pickup_sparkle")
