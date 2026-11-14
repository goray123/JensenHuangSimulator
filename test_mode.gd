extends Node3D

signal reset_requested

const PLAYER_SCENE := preload("res://player.tscn")
const TARGET_COLOR := Color(0.16, 0.65, 0.98)

var target: CharacterBody3D
var hit_count := 0
var _status := Label.new()
var _contest_bot := false
var _bot_tap_elapsed := 0.0

@onready var _apartment: Node3D = get_parent()
@onready var _player: CharacterBody3D = _apartment.get_node("Player")


func _ready() -> void:
	_player.global_position = Vector3(-2, 0.04, 3)
	_player.rotation.y = 0
	var positions := [Vector3(-2.7, 0.07666667, 3.05), Vector3(-1.3, 0.07666667, 3.1), Vector3(-2, 0.07666667, 2.1)]
	for index in 3:
		_apartment.get_node("Pickup%d" % (index + 1)).global_position = positions[index]
	target = PLAYER_SCENE.instantiate() as CharacterBody3D
	target.name = "TestTarget"
	target.reads_local_input = false
	target.position = Vector3(-2, 0.04, 0.8)
	var jacket := StandardMaterial3D.new()
	jacket.albedo_color = TARGET_COLOR
	jacket.roughness = 0.88
	for part in [&"Torso", &"LeftArm", &"RightArm"]:
		target.get_node(NodePath(part)).material_override = jacket
	add_child(target)
	_apartment._contest.register_opponent(target)
	target.hit_received.connect(_on_target_hit)
	var role := _apartment.get_node("HUD/LanRole") as Label
	role.text = "테스트 모드  ·  Esc 메뉴"
	role.show()
	_status.name = "TestStatus"
	_add_label(_status, 64.0)
	var help := Label.new()
	help.text = "파란 대상에 물건을 던져 피격 확인\nF  내 캐릭터 피격 테스트\nG  쟁탈전 테스트 (E 연타)\nR  물건·피격 상태 초기화"
	_add_label(help, 104.0)
	_update_status()


func _add_label(label: Label, top: float) -> void:
	label.anchor_left = 1.0
	label.anchor_right = 1.0
	label.offset_left = -440.0
	label.offset_right = -24.0
	label.offset_top = top
	label.horizontal_alignment = HORIZONTAL_ALIGNMENT_RIGHT
	label.mouse_filter = Control.MOUSE_FILTER_IGNORE
	label.add_theme_font_size_override(&"font_size", 16)
	_apartment.get_node("HUD").add_child(label)


func _process(_delta: float) -> void:
	_update_status()


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
	_player.global_position = Vector3(-2, 0.04, 3)
	target.global_position = Vector3(-2, 0.04, 2)
	for pickup: RigidBody3D in _apartment._pickups:
		if pickup.name == &"Pickup3":
			target.hold_pickup(pickup)
			break
	_player.pickup_nearest()
	_contest_bot = _apartment._contest.active
	_bot_tap_elapsed = 0.0


func _update_status() -> void:
	_status.text = "대상 피격: %d회  ·  %s" % [hit_count, "이동 불가" if target.is_stunned() else "대기 중"]


func _on_target_hit() -> void:
	hit_count += 1
	_update_status()


func _unhandled_input(event: InputEvent) -> void:
	if event.is_action_pressed(&"test_hit"):
		_player.receive_hit()
		get_viewport().set_input_as_handled()
	elif event.is_action_pressed(&"test_reset"):
		reset_requested.emit()
		get_viewport().set_input_as_handled()
	elif event is InputEventKey and event.pressed and not event.echo and event.physical_keycode == KEY_G:
		_start_contest_test()
		get_viewport().set_input_as_handled()
