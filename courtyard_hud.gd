extends CanvasLayer

const ITEM_ICON := preload("res://assets/Sprites/Items/Item_Ring.png")
const GOLD_PER_ITEM := 10
const GOLD_STEP_SECONDS := 0.04
const LOG_SECONDS := 3.0

var _shown_gold := Vector2i.ZERO
var _gold_step_left := 0.0

@onready var _bags: Array[GridContainer] = [$WifeBag/Items, $HusbandBag/Items]
@onready var _gold: Array[Label] = [$WifeProfile/WifeWallet/Gold, $HusbandProfile/HusbandWallet/Gold]
@onready var _logs: VBoxContainer = $AcquisitionLogs


func _ready() -> void:
	set_process(false)


func add_bag_item(player_index: int, item_name: String) -> void:
	var icon := TextureRect.new()
	icon.texture = ITEM_ICON
	# shortcut: 11 rows fit the current 21 items, add scrolling if the map grows.
	icon.custom_minimum_size = Vector2(42, 32)
	icon.expand_mode = TextureRect.EXPAND_IGNORE_SIZE
	icon.stretch_mode = TextureRect.STRETCH_KEEP_ASPECT_CENTERED
	icon.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_bags[player_index].add_child(icon)
	set_process(true)

	if _logs.get_child_count() == 2:
		var oldest := _logs.get_child(0)
		_logs.remove_child(oldest)
		oldest.queue_free()
	var log := Label.new()
	var player_name := "아내" if player_index == 0 else "남편"
	log.text = "%s님이 %s을(를) 획득했습니다!" % [player_name, item_name]
	log.custom_minimum_size.y = 46.0
	log.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	log.vertical_alignment = VERTICAL_ALIGNMENT_CENTER
	log.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_logs.add_child(log)
	var expiry := log.create_tween()
	expiry.tween_interval(LOG_SECONDS)
	expiry.tween_callback(log.queue_free)


func _process(delta: float) -> void:
	_gold_step_left -= delta
	if _gold_step_left > 0.0:
		return
	_gold_step_left = GOLD_STEP_SECONDS
	var animating := false
	for index in _bags.size():
		var target_gold := _bags[index].get_child_count() * GOLD_PER_ITEM
		if _shown_gold[index] < target_gold:
			_shown_gold[index] += 1
			_gold[index].text = "%06d" % _shown_gold[index]
			animating = animating or _shown_gold[index] < target_gold
	set_process(animating)
