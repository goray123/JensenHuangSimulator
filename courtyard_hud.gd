extends CanvasLayer

const FALLBACK_ICON := preload("res://assets/Sprites/Items/Item_Ring.png")
const SPEECH_BUBBLES := preload("res://ui/speech_bubbles.gd")
const HIT_SPLAT_TEXTURES := {
	&"cake": preload("res://assets/Sprites/Effects/CakeSplat.png"),
	&"egg": preload("res://assets/Sprites/Effects/EggSplat.png"),
}
const GOLD_STEP_SECONDS := 0.04
const LOG_SECONDS := 3.0
const SPLAT_FADE_SECONDS := 0.45

## Holding an item worth at least this much gold shows the proud portrait.
@export var proud_gold_threshold := 500

var _shown_gold := Vector2i.ZERO
var _target_gold := Vector2i.ZERO
var _gold_step_left := 0.0
var _bound_players: Array[CharacterBody3D] = []
var _hit_splats: Control

@onready var _bags: Array[GridContainer] = [$HusbandBag/Items, $WifeBag/Items]
@onready var _gold: Array[Label] = [$HusbandProfile/HusbandWallet/Gold, $WifeProfile/WifeWallet/Gold]
@onready var _logs: VBoxContainer = $AcquisitionLogs
@onready var portraits: Array[TextureRect] = [$HusbandProfile/Portrait, $WifeProfile/Portrait]
var speech: Control


func _ready() -> void:
	set_process(false)
	speech = SPEECH_BUBBLES.new()
	speech.name = "SpeechBubbles"
	add_child(speech)
	# Behind the cards, bags and logs so a bubble near the edge never covers the scores.
	move_child(speech, 0)
	_hit_splats = Control.new()
	_hit_splats.name = "HitSplats"
	_hit_splats.mouse_filter = Control.MOUSE_FILTER_IGNORE
	add_child(_hit_splats)
	_hit_splats.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	move_child(_hit_splats, 0)


func show_hit_splat(effect: StringName, seconds: float) -> void:
	var texture: Texture2D = HIT_SPLAT_TEXTURES.get(effect)
	if texture == null:
		return
	var splat := TextureRect.new()
	splat.texture = texture
	splat.mouse_filter = Control.MOUSE_FILTER_IGNORE
	splat.expand_mode = TextureRect.EXPAND_IGNORE_SIZE
	splat.stretch_mode = TextureRect.STRETCH_KEEP_ASPECT_CENTERED
	_hit_splats.add_child(splat)
	var center := Vector2(randf_range(0.34, 0.66), randf_range(0.40, 0.60))
	var half_size := Vector2(0.21, 0.37) * randf_range(0.9, 1.0)
	splat.anchor_left = center.x - half_size.x
	splat.anchor_right = center.x + half_size.x
	splat.anchor_top = center.y - half_size.y
	splat.anchor_bottom = center.y + half_size.y
	splat.pivot_offset = splat.size * 0.5
	splat.scale = Vector2.ONE * 0.7
	var fade_seconds := minf(SPLAT_FADE_SECONDS, seconds)
	var tween := splat.create_tween()
	tween.tween_property(splat, ^"scale", Vector2.ONE, minf(0.15, seconds)).set_trans(Tween.TRANS_BACK).set_ease(Tween.EASE_OUT)
	tween.parallel().tween_property(splat, ^"modulate:a", 0.0, fade_seconds).set_delay(seconds - fade_seconds)
	tween.tween_callback(splat.queue_free)


## Index 0 is the husband (host) card and 1 the wife (guest) card, matching the bag and gold order.
## Every peer runs these player events locally: hits, status effects and contest results
## arrive by reliable RPC, held items by snapshots and bagging by a reliable event.
## Binding the same player twice is ignored so reactions are never doubled.
func bind_player(player_index: int, player: CharacterBody3D) -> void:
	if _bound_players.has(player):
		return
	_bound_players.append(player)
	var portrait := portraits[player_index]
	player.hit_received.connect(portrait.play_reaction.bind(&"fallen", 0.0))
	player.contest_lost.connect(portrait.play_reaction.bind(&"angry", 0.0))
	player.status_effect_applied.connect(func(_effect: StringName, seconds: float) -> void: portrait.play_reaction(&"sad", seconds))
	player.held_pickup_changed.connect(func(is_holding: bool) -> void:
		if is_holding and player.held_pickup != null and player.held_pickup.gold_value >= proud_gold_threshold:
			portrait.play_reaction(&"proud"))
	speech.bind(player_index, player)
	player.hit_received.connect(speech.crunch.bind(player_index))
	player.hit_received.connect(speech.say.bind(player_index, &"hit"))
	player.banana_peel_stepped.connect(speech.say.bind(player_index, &"slip"))
	player.throw_played.connect(speech.say.bind(player_index, &"throw"))
	player.contest_lost.connect(func() -> void:
		speech.say(player_index, &"lost")
		speech.say(1 - player_index, &"won"))


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
	# Reliable on every peer, unlike the held-item snapshot a quick pickup-and-bag can skip.
	if pickup.gold_value >= proud_gold_threshold:
		portraits[player_index].play_reaction(&"proud")
	speech.say(player_index, &"bag")
	set_process(true)
	add_log("%s님이 %s을(를) 획득했습니다!" % [player_name(player_index), item_name(pickup)])


func add_attack_log(pickup: RigidBody3D, victim_index: int) -> void:
	var item := item_name(pickup)
	var victim := player_name(victim_index)
	add_log("%s%s %s%s 공격 하였다!" % [item, "으로" if _needs_euro(item) else "로", victim, "을" if _has_final_consonant(victim) else "를"])


func add_drop_log(pickup: RigidBody3D) -> void:
	var item := item_name(pickup)
	add_log("%s%s 떨어졌다!" % [item, "이" if _has_final_consonant(item) else "가"])


static func player_name(player_index: int) -> String:
	return "남편" if player_index == 0 else "아내"


static func item_name(pickup: RigidBody3D) -> String:
	return str(pickup.get_meta(&"pickup_name", "구"))


## True when the last Hangul syllable has a final consonant (받침).
static func _has_final_consonant(word: String) -> bool:
	var code := word.unicode_at(word.length() - 1) if not word.is_empty() else 0
	return code >= 0xAC00 and code <= 0xD7A3 and (code - 0xAC00) % 28 != 0


## "으로" after a final consonant other than ㄹ, otherwise "로".
static func _needs_euro(word: String) -> bool:
	return _has_final_consonant(word) and (word.unicode_at(word.length() - 1) - 0xAC00) % 28 != 8


func add_log(text: String) -> void:
	if _logs.get_child_count() == 2:
		var oldest := _logs.get_child(0)
		_logs.remove_child(oldest)
		oldest.queue_free()
	var log := Label.new()
	log.text = text
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
