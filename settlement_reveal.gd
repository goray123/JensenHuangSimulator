extends Control
## Courtroom scoreboard shown before the verdict. Both bags empty one item at a time while
## the gold counters race up; special evidence (piggy bank, ring, letter) then gets its own
## card: a short scenario, the icon, a verdict stamp and the gold it changes. The gavel ends it.
## Index 0 is the husband (right card), 1 the wife (left card), matching the 3D stage.

signal finished(gold: Vector2i)

const SETTLEMENT := preload("res://settlement.gd")
const Effect := SETTLEMENT.Effect
const SFX := preload("res://sfx.gd")
const PORTRAIT := preload("res://ui/bust_portrait.tscn")
const DIGITS := preload("res://assets/Fonts/IntelOneMono-Bold.otf")
const NAMES := ["남편", "아내"]
## Card badges use the HUD's English names so they match the "WIFE" / "HUSBAND" art.
const BADGES := ["HUSBAND", "WIFE"]
const SUBJECTS := ["남편이", "아내가"]
const TO := ["남편에게", "아내에게"]
## Contest colors: husband gold, wife blue.
const ACCENTS := [Color(0.91, 0.74, 0.29), Color(0.36, 0.48, 0.94)]
const YELLOW := Color(0.95, 0.76, 0.31)
const INK := Color(0.06, 0.05, 0.08, 0.9)
const GOOD := Color(0.5, 0.9, 0.38)
const BAD := Color(0.95, 0.3, 0.24)
const LOVE := Color(1.0, 0.56, 0.72)
const HIDDEN := Color(0, 0, 0, 0.5)
const BIG_ITEM_GOLD := 500
## Normal items: the first pair takes this long, later pairs speed up to the minimum.
const FIRST_STEP := 0.42
const MIN_STEP := 0.14
const STEP_SPEEDUP := 0.86
## Totals within this share of the larger one get a drumroll before the gavel.
const CLOSE_SHARE := 0.1

## Running totals as the reveal applies each entry; equals final_gold once done.
var gold := Vector2i.ZERO
var final_gold := Vector2i.ZERO
## opening, items, evidence, verdict, done
var phase := &""
var evidence_count := 0
var done := false

var _rows: Array = []
var _tweens: Array[Tween] = []
var _transients: Array[Node] = []
var _cards: Array[PanelContainer] = []
var _counters: Array[Label] = []
var _counter_tweens: Array[Tween] = [null, null]
var _shown := [0.0, 0.0]
var _portraits: Array[TextureRect] = []
var _icons: Array[TextureRect] = []
var _caption: Label
var _evidence: Control
var _evidence_panel: PanelContainer
var _evidence_header: Label
var _evidence_icon: TextureRect
var _evidence_title: Label
var _evidence_story: Label
var _evidence_stamp: Label
var _evidence_gold: Label
var _flash: ColorRect


## The HUD badge look ("WIFE" art): IntelOneMono, white fill, thick black outline and drop shadow.
static func badge_style(label: Label, font_size: int, color := Color.WHITE) -> void:
	label.add_theme_font_override(&"font", DIGITS)
	label.add_theme_font_size_override(&"font_size", font_size)
	label.add_theme_color_override(&"font_color", color)
	label.add_theme_color_override(&"font_outline_color", Color.BLACK)
	label.add_theme_constant_override(&"outline_size", maxi(8, font_size / 3))
	label.add_theme_color_override(&"font_shadow_color", Color.BLACK)
	label.add_theme_constant_override(&"shadow_offset_x", -2)
	label.add_theme_constant_override(&"shadow_offset_y", maxi(3, font_size / 9))
	label.add_theme_constant_override(&"shadow_outline_size", maxi(8, font_size / 3))


## Same outline and shadow for Korean text, which IntelOneMono cannot draw.
static func _korean_badge(label: Label, font_size: int, color: Color) -> void:
	badge_style(label, font_size, color)
	label.remove_theme_font_override(&"font")


## Rows: {player, icon, name, face, gold, effect, taken} in reveal order (see courtyard.gd).
static func totals(rows: Array) -> Vector2i:
	var result := Vector2i.ZERO
	for row: Dictionary in rows:
		result[row.player] += row.gold + row.taken
		result[1 - row.player] -= row.taken
	return result


func start(rows: Array) -> void:
	_rows = rows
	final_gold = totals(rows)
	set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	mouse_filter = Control.MOUSE_FILTER_IGNORE
	_build()
	_run()


func counter_text(player: int) -> String:
	return _counters[player].text


## Jumps to the gavel with every entry applied. Running steps are dropped mid-await.
func skip() -> void:
	if done:
		return
	for tween in _tweens:
		if tween.is_valid():
			tween.kill()
	_tweens.clear()
	for node in _transients:
		if is_instance_valid(node):
			node.queue_free()
	_transients.clear()
	_evidence.hide()
	for card in _cards:
		card.modulate = Color.WHITE
		card.scale = Vector2.ONE
	for index in _rows.size():
		_icons[index].modulate = _final_icon_color(_rows[index])
		_icons[index].scale = Vector2.ONE
	gold = final_gold
	for player in 2:
		_set_count(gold[player], player)
	_gavel()


func _run() -> void:
	_set_phase(&"opening", "재산 분할 심리를 시작합니다")
	for card in _cards:
		card.modulate.a = 0.0
		_tween().tween_property(card, "modulate:a", 1.0, 0.35)
	await _wait(1.3)
	await _count_items()
	for index in _rows.size():
		if _rows[index].effect != Effect.NONE:
			await _present(index)
	await _verdict()


func _count_items() -> void:
	var sides: Array = [[], []]
	for index in _rows.size():
		if _rows[index].effect == Effect.NONE:
			sides[_rows[index].player].append(index)
	if sides[0].is_empty() and sides[1].is_empty():
		var has_evidence := not _rows.is_empty()
		_set_phase(&"items", "특수 증거물만 남았습니다" if has_evidence else "두 가방 모두 비어 있습니다")
		await _wait(1.0)
		return
	_set_phase(&"items", "가방을 하나씩 열어 봅니다")
	var step := FIRST_STEP
	for slot in maxi(sides[0].size(), sides[1].size()):
		var big := false
		for player in 2:
			if slot < sides[player].size():
				big = _reveal_item(sides[player][slot], step) or big
		_sound(&"pickup_coin", -9.0, minf(1.0 + slot * 0.05, 1.7))
		if big:
			_sound(&"pickup_sparkle", -6.0)
		await _wait(step + (0.35 if big else 0.0))
		step = maxf(MIN_STEP, step * STEP_SPEEDUP)
	await _wait(0.4)


## Pops one bag icon into color with a floating "+gold"; returns true for a big-ticket item.
func _reveal_item(index: int, step: float) -> bool:
	var row: Dictionary = _rows[index]
	var icon := _icons[index]
	var pop := _tween().set_parallel()
	pop.tween_property(icon, "modulate", Color.WHITE, 0.12)
	icon.scale = Vector2.ONE * 1.5
	pop.tween_property(icon, "scale", Vector2.ONE, 0.28).set_trans(Tween.TRANS_BACK).set_ease(Tween.EASE_OUT)
	_float_text(icon, "+%d" % row.gold, GOOD)
	_add_gold(row.player, row.gold, minf(step, 0.3))
	if row.gold >= BIG_ITEM_GOLD:
		_portraits[row.player].play_reaction(&"proud", 2.0)
		return true
	return false


## One evidence card: scenario, suspense, stamp, then the gold lands on the counters.
func _present(index: int) -> void:
	var row: Dictionary = _rows[index]
	var player: int = row.player
	var other := 1 - player
	if phase != &"evidence":
		_set_phase(&"evidence", "특수 증거물 감정")
		await _wait(0.7)
	evidence_count += 1
	var icon := _icons[index]
	icon.modulate = Color(1, 1, 1, 0.9)
	var nudge := _tween()
	nudge.tween_property(icon, "scale", Vector2.ONE * 1.35, 0.15)
	nudge.tween_property(icon, "scale", Vector2.ONE, 0.15)
	await _wait(0.3)
	_evidence_header.text = "특수 증거물 · %s의 가방" % NAMES[player]
	_evidence_header.add_theme_color_override(&"font_color", ACCENTS[player])
	_evidence_icon.texture = row.icon
	_evidence_icon.modulate = Color.WHITE
	_evidence_icon.rotation = 0.0
	_evidence_title.text = row.name
	_evidence_story.text = ""
	_evidence_stamp.text = ""
	_evidence_gold.text = ""
	_evidence_gold.remove_theme_color_override(&"font_color")
	_evidence.show()
	_evidence.modulate.a = 0.0
	_evidence_panel.pivot_offset = _evidence_panel.size / 2.0
	_evidence_panel.scale = Vector2.ONE * 0.85
	var open := _tween().set_parallel()
	open.tween_property(_evidence, "modulate:a", 1.0, 0.2)
	open.tween_property(_evidence_panel, "scale", Vector2.ONE, 0.3).set_trans(Tween.TRANS_BACK).set_ease(Tween.EASE_OUT)
	_sound(&"pickup_pop", -4.0)
	await _wait(0.35)
	match row.effect:
		Effect.PIGGY:
			await _type("망치로 저금통을 깨 봅니다…")
			var shake := _tween()
			for turn in 6:
				shake.tween_property(_evidence_icon, "rotation", 0.14 * (1 if turn % 2 == 0 else -1), 0.07)
			shake.tween_property(_evidence_icon, "rotation", 0.0, 0.07)
			_tween().tween_method(func(_t: float) -> void: _evidence_gold.text = "%d G" % (randi_range(0, SETTLEMENT.PIGGY_MAX_COINS) * 10), 0.0, 1.0, 0.85)
			await _wait(0.9)
			_sound(&"hit_shatter", -3.0)
			if row.gold > 0:
				_stamp("동전 와르르!", GOOD)
				_portraits[player].play_reaction(&"proud", 2.0)
			else:
				_stamp("텅 비었다!", BAD)
				_portraits[player].play_reaction(&"sad", 2.0)
			_show_gold("+%d G" % row.gold, GOOD if row.gold > 0 else BAD)
		Effect.RING_REAL, Effect.RING_FAKE:
			await _type("감정사가 반지를 살펴봅니다…")
			_tween().tween_method(func(dots: float) -> void: _evidence_gold.text = "감정 중" + ".".repeat(int(dots) % 4), 0.0, 7.9, 1.0)
			await _wait(1.05)
			if row.effect == Effect.RING_REAL:
				_sound(&"pickup_sparkle")
				_stamp("진품!", GOOD)
				_show_gold("+%d G" % row.gold, GOOD)
				_portraits[player].play_reaction(&"proud", 2.0)
			else:
				_sound(&"hit_shatter")
				_stamp("가짜!", BAD)
				_show_gold("%d → %d G" % [row.face, row.gold], BAD)
				_evidence_icon.modulate = Color(0.55, 0.55, 0.55)
				_tween().tween_property(_evidence_icon, "rotation", -0.3, 0.25).set_trans(Tween.TRANS_BOUNCE).set_ease(Tween.EASE_OUT)
				_portraits[player].play_reaction(&"sad", 2.0)
				_portraits[other].play_reaction(&"proud", 2.0)
		Effect.LETTER_LOVE, Effect.LETTER_AFFAIR:
			await _type("편지를 열어 보니…")
			await _wait(0.45)
			if row.effect == Effect.LETTER_LOVE:
				await _type("%s %s 쓴 연애편지였어요.\n추억 값만 인정됩니다." % [SUBJECTS[other], TO[player]])
				_sound(&"pickup_sparkle", -6.0)
				_stamp("추억", LOVE)
				_show_gold("+%d G" % row.gold, LOVE)
			else:
				var claim := "위자료를 받습니다." if row.taken > 0 else "그런데 받을 재산이 없네요."
				await _type("%s 다른 사람에게 쓴 연애편지!\n불륜 증거로 %s" % [SUBJECTS[other], claim])
				_sound(&"hit_thud")
				_stamp("불륜 증거!", BAD)
				_show_gold("+%d G · 위자료 +%d G" % [row.gold, row.taken], GOOD)
				_portraits[player].play_reaction(&"proud", 2.5)
				_portraits[other].play_reaction(&"angry", 2.5)
	await _wait(1.1)
	var close := _tween()
	close.tween_property(_evidence, "modulate:a", 0.0, 0.18)
	close.tween_callback(_evidence.hide)
	icon.modulate = _final_icon_color(row)
	_add_gold(player, row.gold, 0.45)
	if row.taken > 0:
		_fly_coins(other, player)
		_add_gold(other, -row.taken, 0.7)
		_add_gold(player, row.taken, 0.7, 0.2)
		await _wait(0.6)
	await _wait(0.65)


func _verdict() -> void:
	_set_phase(&"verdict", "판결을 선고합니다")
	await _wait(0.6)
	var top := maxi(gold.x, gold.y)
	if top > 0 and absi(gold.x - gold.y) <= top * CLOSE_SHARE:
		_caption.text = "박빙! 두구두구…"
		var roll := _tween()
		for beat in 10:
			roll.tween_callback(_sound.bind(&"hit_soft", -10.0, 0.9 + beat * 0.03))
			roll.tween_interval(0.13)
		for card in _cards:
			card.pivot_offset = card.size / 2.0
			var pulse := _tween()
			pulse.set_loops(4)
			pulse.tween_property(card, "scale", Vector2.ONE * 1.04, 0.16)
			pulse.tween_property(card, "scale", Vector2.ONE, 0.16)
		await _wait(1.35)
	_gavel()


func _gavel() -> void:
	if done:
		return
	done = true
	phase = &"done"
	_caption.hide()
	_sound(&"hit_thud", 2.0, 0.8)
	_sound(&"hit_metal", -8.0, 0.7)
	_flash.show()
	_flash.modulate.a = 0.7
	var flash := create_tween()
	flash.tween_property(_flash, "modulate:a", 0.0, 0.35)
	flash.tween_callback(_flash.hide)
	var shake := create_tween()
	for offset: Vector2 in [Vector2(10, -6), Vector2(-8, 5), Vector2(5, -3), Vector2.ZERO]:
		shake.tween_property(self, "position", offset, 0.05)
	# A skip can land while an evidence card's sad or angry face is still running.
	for portrait in _portraits:
		portrait.clear_reactions()
	if gold.x != gold.y:
		var winner := 0 if gold.x > gold.y else 1
		var card := _cards[winner]
		card.pivot_offset = card.size / 2.0
		var pop := create_tween()
		pop.tween_property(card, "scale", Vector2.ONE * 1.1, 0.15)
		pop.tween_property(card, "scale", Vector2.ONE * 1.05, 0.2)
		_counters[winner].add_theme_color_override(&"font_color", YELLOW)
		_cards[1 - winner].modulate = Color(0.7, 0.7, 0.75)
		_portraits[winner].play_reaction(&"proud", 30.0)
		_portraits[1 - winner].play_reaction(&"sad", 30.0)
	finished.emit(gold)


func _final_icon_color(row: Dictionary) -> Color:
	return Color(0.55, 0.55, 0.55) if row.effect == Effect.RING_FAKE else Color.WHITE


func _set_phase(name: StringName, caption: String) -> void:
	phase = name
	_caption.text = caption
	_caption.modulate.a = 0.0
	_tween().tween_property(_caption, "modulate:a", 1.0, 0.2)


func _type(text: String) -> void:
	_evidence_story.text = text
	_evidence_story.visible_ratio = 0.0
	var seconds := clampf(text.length() * 0.04, 0.4, 1.3)
	_tween().tween_property(_evidence_story, "visible_ratio", 1.0, seconds)
	await _wait(seconds + 0.15)


func _stamp(text: String, color: Color) -> void:
	_evidence_stamp.text = text
	_evidence_stamp.add_theme_color_override(&"font_color", color)
	_evidence_stamp.pivot_offset = _evidence_stamp.size / 2.0
	_evidence_stamp.scale = Vector2.ONE * 2.2
	_evidence_stamp.modulate.a = 0.0
	var stamp := _tween().set_parallel()
	stamp.tween_property(_evidence_stamp, "scale", Vector2.ONE, 0.18).set_trans(Tween.TRANS_QUAD).set_ease(Tween.EASE_IN)
	stamp.tween_property(_evidence_stamp, "modulate:a", 1.0, 0.12)


func _show_gold(text: String, color: Color) -> void:
	_evidence_gold.text = text
	_evidence_gold.add_theme_color_override(&"font_color", color)


func _add_gold(player: int, amount: int, seconds: float, delay := 0.0) -> void:
	gold[player] += amount
	var target := gold[player]
	if delay > 0.0:
		_tween().tween_callback(_count_to.bind(player, target, seconds)).set_delay(delay)
	else:
		_count_to(player, target, seconds)


func _count_to(player: int, target: int, seconds: float) -> void:
	if _counter_tweens[player] != null and _counter_tweens[player].is_valid():
		_counter_tweens[player].kill()
	_counter_tweens[player] = _tween()
	_counter_tweens[player].tween_method(_set_count.bind(player), _shown[player], float(target), seconds)


func _set_count(value: float, player: int) -> void:
	_shown[player] = value
	_counters[player].text = "%d G" % roundi(value)


func _float_text(anchor: Control, text: String, color: Color) -> void:
	var label := _label(text, 22, color)
	badge_style(label, 22, color)
	add_child(label)
	_transients.append(label)
	label.size = Vector2(120, 30)
	label.position = anchor.get_global_rect().get_center() - global_position - label.size / 2.0
	var rise := _tween().set_parallel()
	rise.tween_property(label, "position:y", label.position.y - 42.0, 0.7).set_ease(Tween.EASE_OUT)
	rise.tween_property(label, "modulate:a", 0.0, 0.3).set_delay(0.4)
	rise.chain().tween_callback(label.queue_free)


func _fly_coins(from_player: int, to_player: int) -> void:
	var start := _counters[from_player].get_global_rect().get_center() - global_position
	var end := _counters[to_player].get_global_rect().get_center() - global_position
	for coin_index in 6:
		var coin := _label("G", 17, Color(0.36, 0.2, 0.07), DIGITS)
		var style := StyleBoxFlat.new()
		style.bg_color = Color(0.98, 0.76, 0.3)
		style.set_corner_radius_all(14)
		coin.add_theme_stylebox_override(&"normal", style)
		coin.size = Vector2(28, 28)
		coin.position = start - coin.size / 2.0
		coin.modulate.a = 0.0
		add_child(coin)
		_transients.append(coin)
		var flight := _tween()
		flight.tween_interval(coin_index * 0.08)
		flight.tween_property(coin, "modulate:a", 1.0, 0.05)
		flight.tween_property(coin, "position", end - coin.size / 2.0, 0.5).set_trans(Tween.TRANS_SINE).set_ease(Tween.EASE_IN_OUT)
		flight.tween_callback(_sound.bind(&"pickup_coin", -12.0, 1.2))
		flight.tween_callback(coin.queue_free)


func _sound(sound: StringName, volume_db := 0.0, pitch := 1.0) -> void:
	var player := AudioStreamPlayer.new()
	player.stream = SFX.STREAMS[sound]
	player.bus = SFX._bus()
	player.volume_db = volume_db
	player.pitch_scale = pitch
	player.finished.connect(player.queue_free)
	add_child(player)
	player.play()


func _tween() -> Tween:
	_tweens = _tweens.filter(func(tween: Tween) -> bool: return tween.is_valid())
	var tween := create_tween()
	_tweens.append(tween)
	return tween


func _wait(seconds: float) -> void:
	var tween := _tween()
	tween.tween_interval(seconds)
	await tween.finished


func _build() -> void:
	for player in 2:
		_cards.append(_build_card(player))
	for row: Dictionary in _rows:
		var icon := TextureRect.new()
		icon.texture = row.icon
		icon.custom_minimum_size = Vector2(50, 40)
		icon.pivot_offset = icon.custom_minimum_size / 2.0
		icon.expand_mode = TextureRect.EXPAND_IGNORE_SIZE
		icon.stretch_mode = TextureRect.STRETCH_KEEP_ASPECT_CENTERED
		icon.mouse_filter = Control.MOUSE_FILTER_IGNORE
		icon.modulate = HIDDEN
		_cards[row.player].get_node("Content/Bag").add_child(icon)
		_icons.append(icon)
	_caption = _label("", 32, Color(1, 0.97, 0.9))
	_korean_badge(_caption, 32, Color(1, 0.97, 0.9))
	_caption.set_anchors_and_offsets_preset(Control.PRESET_CENTER_TOP)
	_caption.offset_left = -330.0
	_caption.offset_right = 330.0
	_caption.offset_top = 30.0
	_caption.offset_bottom = 84.0
	add_child(_caption)
	_build_evidence()
	_flash = ColorRect.new()
	_flash.color = Color(1, 0.97, 0.88)
	_flash.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_flash.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	_flash.hide()
	add_child(_flash)


func _build_card(player: int) -> PanelContainer:
	var card := PanelContainer.new()
	card.name = "%sCard" % ["Husband", "Wife"][player]
	card.mouse_filter = Control.MOUSE_FILTER_IGNORE
	card.custom_minimum_size.x = 240.0
	card.add_theme_stylebox_override(&"panel", _panel_style(INK, ACCENTS[player], 3, 16, 14))
	if player == 1:
		card.set_anchors_and_offsets_preset(Control.PRESET_TOP_LEFT)
		card.position = Vector2(16, 112)
	else:
		card.set_anchors_and_offsets_preset(Control.PRESET_TOP_RIGHT)
		card.grow_horizontal = Control.GROW_DIRECTION_BEGIN
		card.offset_left = -256.0
		card.offset_right = -16.0
		card.offset_top = 112.0
	var content := VBoxContainer.new()
	content.name = "Content"
	content.add_theme_constant_override(&"separation", 8)
	card.add_child(content)
	var header := HBoxContainer.new()
	header.add_theme_constant_override(&"separation", 10)
	content.add_child(header)
	var portrait := PORTRAIT.instantiate() as TextureRect
	portrait.character = "man" if player == 0 else "woman"
	portrait.custom_minimum_size = Vector2(84, 84)
	header.add_child(portrait)
	_portraits.append(portrait)
	var names := VBoxContainer.new()
	names.alignment = BoxContainer.ALIGNMENT_CENTER
	header.add_child(names)
	var title := _label(BADGES[player], 22, ACCENTS[player])
	badge_style(title, 22)
	title.horizontal_alignment = HORIZONTAL_ALIGNMENT_LEFT
	names.add_child(title)
	var counter := _label("0 G", 32, Color(1, 0.96, 0.86))
	badge_style(counter, 32, Color(1, 0.96, 0.86))
	counter.horizontal_alignment = HORIZONTAL_ALIGNMENT_LEFT
	names.add_child(counter)
	_counters.append(counter)
	var rule := ColorRect.new()
	rule.color = ACCENTS[player]
	rule.custom_minimum_size.y = 3.0
	content.add_child(rule)
	var bag_label := _label("가방", 15, Color(0.75, 0.73, 0.8))
	bag_label.horizontal_alignment = HORIZONTAL_ALIGNMENT_LEFT
	content.add_child(bag_label)
	var bag := GridContainer.new()
	bag.name = "Bag"
	bag.columns = 4
	bag.add_theme_constant_override(&"h_separation", 6)
	bag.add_theme_constant_override(&"v_separation", 6)
	bag.custom_minimum_size.y = 40.0
	content.add_child(bag)
	add_child(card)
	return card


func _build_evidence() -> void:
	_evidence = Control.new()
	_evidence.name = "Evidence"
	_evidence.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_evidence.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	_evidence.hide()
	add_child(_evidence)
	var dim := ColorRect.new()
	dim.color = Color(0, 0, 0, 0.55)
	dim.mouse_filter = Control.MOUSE_FILTER_IGNORE
	dim.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	_evidence.add_child(dim)
	_evidence_panel = PanelContainer.new()
	_evidence_panel.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_evidence_panel.add_theme_stylebox_override(&"panel", _panel_style(Color(0.11, 0.09, 0.14, 0.97), YELLOW, 4, 18, 22))
	_evidence_panel.set_anchors_and_offsets_preset(Control.PRESET_CENTER)
	_evidence_panel.grow_horizontal = Control.GROW_DIRECTION_BOTH
	_evidence_panel.grow_vertical = Control.GROW_DIRECTION_BOTH
	_evidence_panel.offset_left = -300.0
	_evidence_panel.offset_right = 300.0
	_evidence_panel.offset_top = -150.0
	_evidence_panel.offset_bottom = 150.0
	_evidence.add_child(_evidence_panel)
	var content := VBoxContainer.new()
	content.add_theme_constant_override(&"separation", 10)
	_evidence_panel.add_child(content)
	_evidence_header = _label("", 18, YELLOW)
	_evidence_header.horizontal_alignment = HORIZONTAL_ALIGNMENT_LEFT
	content.add_child(_evidence_header)
	var body := HBoxContainer.new()
	body.add_theme_constant_override(&"separation", 22)
	content.add_child(body)
	_evidence_icon = TextureRect.new()
	_evidence_icon.custom_minimum_size = Vector2(180, 160)
	_evidence_icon.pivot_offset = _evidence_icon.custom_minimum_size / 2.0
	_evidence_icon.expand_mode = TextureRect.EXPAND_IGNORE_SIZE
	_evidence_icon.stretch_mode = TextureRect.STRETCH_KEEP_ASPECT_CENTERED
	_evidence_icon.mouse_filter = Control.MOUSE_FILTER_IGNORE
	body.add_child(_evidence_icon)
	var text := VBoxContainer.new()
	text.add_theme_constant_override(&"separation", 6)
	body.add_child(text)
	_evidence_title = _label("", 30, Color(1, 0.97, 0.9))
	_korean_badge(_evidence_title, 30, Color(1, 0.97, 0.9))
	_evidence_title.horizontal_alignment = HORIZONTAL_ALIGNMENT_LEFT
	text.add_child(_evidence_title)
	_evidence_story = _label("", 19, Color(0.88, 0.86, 0.92))
	_evidence_story.horizontal_alignment = HORIZONTAL_ALIGNMENT_LEFT
	_evidence_story.vertical_alignment = VERTICAL_ALIGNMENT_TOP
	_evidence_story.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	_evidence_story.custom_minimum_size = Vector2(330, 60)
	text.add_child(_evidence_story)
	_evidence_stamp = _label("", 40, BAD)
	_korean_badge(_evidence_stamp, 40, BAD)
	_evidence_stamp.horizontal_alignment = HORIZONTAL_ALIGNMENT_LEFT
	_evidence_stamp.custom_minimum_size = Vector2(330, 56)
	text.add_child(_evidence_stamp)
	_evidence_gold = _label("", 26, Color(1, 0.96, 0.86))
	badge_style(_evidence_gold, 26, Color(1, 0.96, 0.86))
	_evidence_gold.horizontal_alignment = HORIZONTAL_ALIGNMENT_LEFT
	_evidence_gold.custom_minimum_size = Vector2(330, 34)
	text.add_child(_evidence_gold)


func _panel_style(background: Color, border: Color, border_width: int, radius: int, margin: int) -> StyleBoxFlat:
	var style := StyleBoxFlat.new()
	style.bg_color = background
	style.border_color = border
	style.set_border_width_all(border_width)
	style.set_corner_radius_all(radius)
	style.set_content_margin_all(margin)
	return style


func _label(text: String, font_size: int, color: Color, font: Font = null) -> Label:
	var label := Label.new()
	label.text = text
	label.mouse_filter = Control.MOUSE_FILTER_IGNORE
	label.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	label.vertical_alignment = VERTICAL_ALIGNMENT_CENTER
	label.add_theme_font_size_override(&"font_size", font_size)
	label.add_theme_color_override(&"font_color", color)
	label.add_theme_color_override(&"font_outline_color", Color(0, 0, 0, 0.9))
	label.add_theme_constant_override(&"outline_size", 6)
	if font != null:
		label.add_theme_font_override(&"font", font)
	return label
