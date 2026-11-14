extends CanvasLayer

const FALLBACK_ICON := preload("res://assets/Sprites/Items/Item_Ring.png")
const GOLD_STEP_SECONDS := 0.04
const LOG_SECONDS := 3.0

var _shown_gold := Vector2i.ZERO
var _target_gold := Vector2i.ZERO
var _gold_step_left := 0.0

@onready var _bags: Array[GridContainer] = [$HusbandBag/Items, $WifeBag/Items]
@onready var _gold: Array[Label] = [$HusbandProfile/HusbandWallet/Gold, $WifeProfile/WifeWallet/Gold]
@onready var _logs: VBoxContainer = $AcquisitionLogs


func _ready() -> void:
	set_process(false)


func add_bag_item(player_index: int, pickup_index: int, pickup: RigidBody3D) -> void:
	var icon := TextureRect.new()
	icon.name = "Item%d" % pickup_index
	icon.texture = pickup.bag_icon if pickup.bag_icon != null else FALLBACK_ICON
	icon.custom_minimum_size = Vector2(42, 30)
	icon.expand_mode = TextureRect.EXPAND_IGNORE_SIZE
	icon.stretch_mode = TextureRect.STRETCH_KEEP_ASPECT_CENTERED
	icon.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_bags[player_index].add_child(icon)
	_target_gold[player_index] += pickup.gold_value
	set_process(true)

	if _logs.get_child_count() == 2:
		var oldest := _logs.get_child(0)
		_logs.remove_child(oldest)
		oldest.queue_free()
	var log := Label.new()
	var player_name := "남편" if player_index == 0 else "아내"
	log.text = "%s님이 %s을(를) 획득했습니다!" % [player_name, pickup.get_meta(&"pickup_name", "구")]
	log.custom_minimum_size.y = 46.0
	log.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	log.vertical_alignment = VERTICAL_ALIGNMENT_CENTER
	log.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_logs.add_child(log)
	var expiry := log.create_tween()
	expiry.tween_interval(LOG_SECONDS)
	expiry.tween_callback(log.queue_free)


func remove_bag_item(player_index: int, pickup_index: int, value: int) -> void:
	var icon := _bags[player_index].get_node("Item%d" % pickup_index)
	_bags[player_index].remove_child(icon)
	icon.queue_free()
	_target_gold[player_index] -= value
	set_process(true)


func _process(delta: float) -> void:
	_gold_step_left -= delta
	if _gold_step_left > 0.0:
		return
	_gold_step_left = GOLD_STEP_SECONDS
	var animating := false
	for index in _bags.size():
		var target := _target_gold[index]
		if _shown_gold[index] != target:
			var step := maxi(1, ceili(abs(target - _shown_gold[index]) / 5.0))
			_shown_gold[index] = move_toward(_shown_gold[index], target, step)
			_gold[index].text = "%06d" % _shown_gold[index]
			animating = animating or _shown_gold[index] != target
	set_process(animating)
