extends Node3D
## Offline lessons use the same input, pickups, combat, contest and scoring as a match.

signal menu_requested
signal replay_requested

enum Step { MOVE, GRAB, BAG, AIM, THROW, CONTEST, SCORE, COMPLETE }

const PLAYER_SCENE := preload("res://player.tscn")
const TARGET_MODEL := preload("res://assets/characters/motions/02_Woman.glb")
const GUIDE_HUD := preload("res://ui/guided_tutorial_hud.gd")
const FONT := preload("res://assets/Fonts/IntelOneMono-Bold.otf")
const HOME := Vector3(6.6, 0.065, -0.9)
const MOVE_GOAL := HOME + Vector3.FORWARD * 1.5
const LESSON_COUNT := 7
const AIM_SECONDS := 0.5
const FINISH_SECONDS := 3.0

var step := Step.MOVE
var target: CharacterBody3D
var hud: CanvasLayer
var _move_goal := MOVE_GOAL
var _marker: Node3D
var _marker_label: Label3D
var _aim_elapsed := 0.0
var _step_elapsed := 0.0
var _throw_elapsed := 0.0
var _transitioning := false
var _target_hit := false
var _aim_ready := false
var _contest_started := false
var _bot_elapsed := 0.0
var _loss_elapsed := 0.0
var _finishing := false
var _ending_elapsed := 0.0

@onready var _apartment: Node3D = get_parent()
@onready var _player: CharacterBody3D = _apartment.get_node("Player")
@onready var _first_item: RigidBody3D = _apartment.get_node("Items/Item_05_cake")
@onready var _throw_item: RigidBody3D = _apartment.get_node("Items/Item_10_tissue_box")
@onready var _contest_item: RigidBody3D = _apartment.get_node("Items/Item_12_ring")
@onready var _opponent_item: RigidBody3D = _apartment.get_node("Items/Item_17_tv")
@onready var _timer: Timer = _apartment.get_node("RoundTimer")


func _ready() -> void:
	# The normal ending disables the house; the guide must still show its completion UI.
	process_mode = Node.PROCESS_MODE_ALWAYS
	# The lesson's ring must stay genuine so the scripted comeback always wins.
	_apartment.settlement_surprises = false
	_timer.stop()
	_apartment.get_node("HUD/TimeLeft").hide()
	for body: RigidBody3D in _apartment._physics_bodies:
		_hide_item(body)
	for hazard: Area3D in _apartment.get_node("Items").find_children("*", "Area3D", true, false):
		hazard.collision_mask = 0
		hazard.hide()
	_player.global_position = HOME
	_player.rotation.y = 0.0
	_player.velocity = Vector3.ZERO
	target = PLAYER_SCENE.instantiate() as CharacterBody3D
	target.name = "TutorialOpponent"
	target.model_scene = TARGET_MODEL
	target.reads_local_input = false
	target.position = HOME + Vector3.FORWARD * 3.0
	add_child(target)
	_player.add_collision_exception_with(target)
	target.add_collision_exception_with(_player)
	_apartment._players.append(target)
	_apartment._contest.register_opponent(target)
	_apartment.get_node("HUD").bind_player(1, target)
	target.hit_received.connect(_on_target_hit)
	_player.grab_changed.connect(_on_grab_changed)
	_marker = _make_marker()
	hud = GUIDE_HUD.new()
	hud.name = "GuidedHUD"
	add_child(hud)
	hud.retry_requested.connect(retry_step)
	hud.menu_requested.connect(func() -> void: menu_requested.emit())
	hud.replay_requested.connect(func() -> void: replay_requested.emit())
	var camera := _apartment.get_node("Overview") as Camera3D
	camera.size = 8.5
	camera.look_at_from_position(Vector3(9.3, 7.2, 7.5), Vector3(6.6, 0.45, -2.0))
	_enter_step(Step.MOVE)


func _physics_process(delta: float) -> void:
	if _transitioning or step == Step.COMPLETE:
		return
	_step_elapsed += delta
	match step:
		Step.MOVE:
			var distance := Vector2(_player.global_position.x - _move_goal.x, _player.global_position.z - _move_goal.z).length()
			hud.set_progress(clampf(1.0 - distance / HOME.distance_to(_move_goal), 0.0, 1.0))
			if distance < 0.35:
				_next(Step.GRAB)
		Step.GRAB:
			if _player.held_pickup == _first_item or _bag_owner(_first_item) == 0:
				_next(Step.BAG)
		Step.BAG:
			if _bag_owner(_first_item) == 0:
				_next(Step.AIM)
			elif _player.held_pickup != _first_item:
				_throw_elapsed += delta
				if _throw_elapsed > 2.0:
					_next(Step.GRAB)
		Step.AIM:
			if _player.held_pickup == _throw_item:
				if not _aim_ready:
					_aim_ready = true
					hud.set_lesson(step, LESSON_COUNT, "궤도와 힘 확인하기", "클릭을 놓았다가, 왼쪽 버튼을 다시 꾹 누르세요.", "힘은 반복해서 오르내립니다. 누른 채로 궤도를 확인하세요.")
				_aim_elapsed = _aim_elapsed + delta if _player._is_aiming else 0.0
				hud.set_progress(minf(_aim_elapsed / AIM_SECONDS, 1.0))
				if _aim_elapsed >= AIM_SECONDS:
					_next(Step.THROW)
			elif _bag_owner(_throw_item) == 0:
				_next(Step.AIM)
			elif _aim_ready or _throw_item._armed:
				# Releasing before the aim lesson completes is still a real throw.
				_throw_elapsed += delta
				if _throw_elapsed > 3.0:
					_next(Step.AIM)
		Step.THROW:
			if _target_hit:
				hud.set_progress(1.0)
				_throw_elapsed += delta
				if _throw_elapsed > 0.7:
					_next(Step.CONTEST)
			elif _player.held_pickup != _throw_item:
				_throw_elapsed += delta
				if _throw_elapsed > 3.0:
					_next(Step.AIM)
		Step.CONTEST:
			_process_contest(delta)
		Step.SCORE:
			_process_score(delta)
	if step in [Step.GRAB, Step.BAG, Step.AIM, Step.CONTEST] and _player.held_pickup == null and _marker.visible:
		var item := _lesson_item()
		if item != null and item.visible:
			_marker.global_position = Vector3(item.global_position.x, 0.07, item.global_position.z)


func _next(next_step: Step) -> void:
	if _transitioning:
		return
	_transitioning = true
	_enter_step.call_deferred(next_step)


func _enter_step(next_step: Step) -> void:
	_transitioning = false
	step = next_step
	_step_elapsed = 0.0
	_aim_elapsed = 0.0
	_throw_elapsed = 0.0
	_aim_ready = false
	_marker.show()
	hud.set_progress(0.0)
	match step:
		Step.MOVE:
			_place_player(HOME)
			_marker.global_position = _move_goal
			_marker_label.text = "여기로 이동"
			hud.set_lesson(step, LESSON_COUNT, "움직여 보기", "WASD로 이동해 초록색 원 안에 들어가세요.", "이동하는 방향으로 캐릭터의 보는 방향도 바뀝니다. R: 처음부터 / Esc: 메뉴")
		Step.GRAB:
			_restore_item(_first_item, _move_goal + Vector3.LEFT * 0.8)
			_marker.global_position = _first_item.global_position
			_marker_label.text = "케이크 줍기"
			hud.set_lesson(step, LESSON_COUNT, "물건 집기", "케이크 가까이에서 왼쪽 마우스 버튼을 꾹 누르세요.", "파란 테두리가 보이면 집을 수 있습니다. 게이지가 끝까지 차야 손에 듭니다.")
		Step.BAG:
			_marker.hide()
			if _player.held_pickup != _first_item and _bag_owner(_first_item) != 0:
				_restore_item(_first_item, _player.global_position + Vector3.FORWARD * 0.6)
				_player.hold_pickup(_first_item)
			hud.set_lesson(step, LESSON_COUNT, "가방에 넣기", "오른쪽 마우스 버튼을 눌러 케이크를 가방에 넣으세요.", "손에 들고만 있으면 점수가 아닙니다. 가방 금액이 늘어나는지 확인하세요.")
		Step.AIM:
			_place_player(HOME)
			target.global_position = HOME + Vector3.FORWARD * 2.4
			target.velocity = Vector3.ZERO
			target.rotation.y = PI
			_target_hit = false
			_restore_item(_throw_item, HOME + Vector3.RIGHT * 0.8)
			_marker.global_position = _throw_item.global_position
			_marker_label.text = "휴지 상자 줍기"
			hud.set_lesson(step, LESSON_COUNT, "궤도와 힘 확인하기", "휴지 상자를 집은 뒤, 왼쪽 버튼을 다시 꾹 누르세요.", "예상 궤도와 힘 게이지가 나타날 때까지 누르고 있으세요.")
		Step.THROW:
			_marker.global_position = target.global_position
			_marker_label.text = "연습 상대 맞히기"
			hud.set_lesson(step, LESSON_COUNT, "던져서 맞히기", "상대를 향해 왼쪽 버튼을 놓아 휴지 상자를 던지세요.", "WASD로 방향을 맞추세요. 힘 게이지 중간쯤이 좋습니다. 빗나가면 다시 시도할 수 있어요.")
		Step.CONTEST:
			_prepare_contest()
		Step.SCORE:
			_marker.hide()
			_hide_item(_throw_item)
			_finishing = false
			_ending_elapsed = 0.0
			_player._cancel_aim()
			if _player.held_pickup != _contest_item and _bag_owner(_contest_item) != 0:
				_restore_item(_contest_item, HOME + Vector3.FORWARD * 0.7)
				_player.hold_pickup(_contest_item)
			# The final object must turn a losing bag total into a winning one.
			_apartment._apply_bag_item(1, _apartment._pickups.find(_opponent_item), _apartment._ownership_revision + 1)
			hud.set_lesson(step, LESSON_COUNT, "가방 금액으로 역전하기", "오른쪽 클릭으로 반지를 가방에 넣어 상대의 금액을 넘으세요.", "실제 경기는 60초! 이번에는 넣은 뒤 3초 후 종료해 승리 판정을 확인합니다. 동점은 무승부입니다.")
		Step.COMPLETE:
			_marker.hide()
			_player.simulates_movement = false
			target.simulates_movement = false
			var gold: Vector2i = _apartment.final_gold
			hud.show_complete(gold.x, gold.y)


func _prepare_contest() -> void:
	_apartment._contest.cancel_round()
	_player.release_pickup(false)
	target.release_pickup(false)
	_player._stun_remaining = 0.0
	target._stun_remaining = 0.0
	_hide_item(_throw_item)
	_place_player(HOME)
	target.global_position = HOME + Vector3.FORWARD * 1.6
	target.velocity = Vector3.ZERO
	_restore_item(_contest_item, HOME + Vector3.FORWARD * 0.8)
	_marker.global_position = _contest_item.global_position
	_marker_label.text = "둘이 같은 반지 줍기"
	_contest_started = false
	_bot_elapsed = 0.0
	_loss_elapsed = 0.0
	hud.set_lesson(step, LESSON_COUNT, "쟁탈전에서 이기기", "반지 가까이에서 왼쪽 버튼을 꾹 누르세요. 상대도 함께 집습니다!", "쟁탈전이 시작되면 왼쪽 클릭을 연타해 내 색 게이지를 끝까지 채우세요.")


func _process_contest(delta: float) -> void:
	var contest: Node = _apartment._contest
	if contest.active:
		if not _contest_started:
			_contest_started = true
			_marker.hide()
			hud.set_lesson(step, LESSON_COUNT, "왼쪽 클릭 연타!", "왼쪽 마우스 버튼을 빠르게 여러 번 누르세요!", "쟁탈전 중에는 경기 시간이 멈춥니다. 패자는 2.5초 동안 움직이지 못합니다.")
		hud.set_progress(contest.progress)
		_bot_elapsed += delta
		if _bot_elapsed >= 0.6:
			_bot_elapsed -= 0.6
			contest.request_interaction(target)
	elif _contest_started:
		if contest.progress >= 1.0:
			_next(Step.SCORE)
		else:
			_loss_elapsed += delta
			if _loss_elapsed < delta * 2.0:
				hud.set_lesson(step, LESSON_COUNT, "한 번 더 도전해요", "이번에는 상대가 가져갔어요. 잠시 뒤 다시 시작합니다.", "꾹 누르는 대신 왼쪽 클릭을 여러 번 해야 게이지가 내 쪽으로 찹니다.")
			if _loss_elapsed > 2.7:
				_next(Step.CONTEST)


func _process_score(delta: float) -> void:
	if not _finishing and _bag_owner(_contest_item) == 0:
		_finishing = true
		_timer.paused = false
		_timer.start(FINISH_SECONDS)
		_apartment.get_node("HUD/TimeLeft").show()
		var gold: Vector2i = _apartment.bag_gold()
		hud.set_lesson(step, LESSON_COUNT, "금액 역전 성공!", "%d G : %d G — 시간이 끝나면 더 많은 쪽이 승리합니다." % [gold.x, gold.y], "가방 속 물건을 하나씩 정산하고, 반지 같은 특수 증거물은 따로 감정합니다.")
	elif not _finishing and _player.held_pickup != _contest_item:
		_throw_elapsed += delta
		if _throw_elapsed > 3.0:
			_next(Step.SCORE)
	if _finishing:
		hud.set_progress(1.0 - _timer.time_left / FINISH_SECONDS)
		var ending := _apartment.get_node_or_null("Ending")
		# The settlement reveal runs first; the lesson waits for the gavel.
		if ending != null and ending.verdict_shown:
			if _ending_elapsed == 0.0:
				hud.set_lesson(step, LESSON_COUNT, "승리!", "가방 금액으로 역전해 승리했습니다!", "실제 경기도 60초가 끝났을 때 가방 속 총금액으로 승패를 정합니다.")
			_ending_elapsed += delta
			if _ending_elapsed >= 6.2:
				_next(Step.COMPLETE)


func _on_grab_changed(is_grabbing: bool, progress: float) -> void:
	if step in [Step.GRAB, Step.AIM]:
		hud.set_progress(progress if is_grabbing else 0.0)
	if step == Step.CONTEST and is_grabbing and not _apartment._contest.active and _player._grab_target == _contest_item:
		_apartment._contest.request_interaction(target, true, _contest_item)


func _on_target_hit() -> void:
	if step == Step.THROW and _throw_item._armed:
		_target_hit = true
		hud.set_lesson(step, LESSON_COUNT, "명중!", "상대를 맞혔습니다. 잠깐 멈추는 모습을 확인하세요.", "실제 경기에서는 손이나 가방의 물건을 떨어뜨리게 할 수도 있습니다.")


func retry_step() -> void:
	if _finishing or step == Step.COMPLETE:
		replay_requested.emit()
		return
	var retry := Step.AIM if step == Step.THROW else step
	_next(retry)


func _bag_owner(item: RigidBody3D) -> int:
	return _apartment._bagged_items.get(_apartment._pickups.find(item), -1)


func _restore_item(item: RigidBody3D, bottom: Vector3) -> void:
	for player: CharacterBody3D in [_player, target]:
		if player.held_pickup == item:
			player.release_pickup(false)
	var index: int = _apartment._pickups.find(item)
	if _apartment._bagged_items.has(index):
		var indices: Array[int] = [index]
		var poses: Array[Transform3D] = [Transform3D.IDENTITY]
		_apartment._apply_hit_drops(indices, poses, _apartment._ownership_revision + 1)
	item.freeze = true
	item.disarm()
	item.linear_velocity = Vector3.ZERO
	item.angular_velocity = Vector3.ZERO
	for body in item.get_collision_exceptions():
		item.remove_collision_exception_with(body)
	if item.get_parent() != _apartment:
		item.reparent(_apartment)
	var collision := item.get_node("CollisionShape3D") as CollisionShape3D
	var bounds := collision.transform * collision.shape.get_debug_mesh().get_aabb()
	item.global_transform = Transform3D(Basis.IDENTITY, bottom + Vector3.UP * (0.02 - bounds.position.y))
	item.show()
	item.collision_layer = 2
	item.collision_mask = 3
	item.add_to_group(&"pickups")


func _hide_item(body: RigidBody3D) -> void:
	if body.has_method(&"disarm"):
		body.disarm()
	if body.has_method(&"set_pickup_highlighted"):
		body.set_pickup_highlighted(false)
	body.freeze = true
	body.collision_layer = 0
	body.collision_mask = 0
	body.hide()
	if body.is_in_group(&"pickups"):
		body.remove_from_group(&"pickups")


func _place_player(at: Vector3) -> void:
	_player.global_position = at
	_player.velocity = Vector3.ZERO
	_player.rotation.y = 0.0
	_player._cancel_aim()
	_player._cancel_grab()


func _lesson_item() -> RigidBody3D:
	if step in [Step.GRAB, Step.BAG]:
		return _first_item
	if step == Step.AIM:
		return _throw_item
	return _contest_item


func _make_marker() -> Node3D:
	var marker := Node3D.new()
	marker.name = "LessonTarget"
	add_child(marker)
	var mesh := MeshInstance3D.new()
	var circle := CylinderMesh.new()
	circle.top_radius = 0.42
	circle.bottom_radius = 0.42
	circle.height = 0.018
	mesh.mesh = circle
	var material := StandardMaterial3D.new()
	material.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	material.albedo_color = Color(0.35, 0.95, 0.75, 0.65)
	material.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
	mesh.material_override = material
	marker.add_child(mesh)
	_marker_label = Label3D.new()
	_marker_label.font = FONT
	_marker_label.font_size = 36
	_marker_label.pixel_size = 0.0055
	_marker_label.position.y = 1.6
	_marker_label.billboard = BaseMaterial3D.BILLBOARD_ENABLED
	_marker_label.no_depth_test = true
	_marker_label.outline_size = 8
	marker.add_child(_marker_label)
	return marker
