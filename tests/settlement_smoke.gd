extends SceneTree
# godot --headless --path . --script res://tests/settlement_smoke.gd

const Settlement := preload("res://settlement.gd")
const Effect := Settlement.Effect

var failed := false


func _initialize() -> void:
	_test_order_and_face_value()
	_test_rolls()
	_test_alimony_cap()
	_test_validation()
	if not failed:
		print("Settlement smoke test passed.")
	quit(int(failed))


func _rng(seed_value: int) -> RandomNumberGenerator:
	var rng := RandomNumberGenerator.new()
	rng.seed = seed_value
	return rng


## [player, pickup, item_id, gold]
func _bags() -> Array:
	return [
		[0, 4, "14-letter", 150], [1, 2, "17-tv", 900], [0, 0, "06-egg", 10], [1, 3, "12-ring", 800],
		[0, 1, "16-piggy-bank", 0], [1, 5, "05-cake", 150], [0, 6, "07-frying-pan", 200],
	]


func _rows(entries: PackedInt32Array) -> Array:
	var rows := []
	for offset in range(0, entries.size(), Settlement.STRIDE):
		rows.append(Array(entries.slice(offset, offset + Settlement.STRIDE)))
	return rows


func _test_order_and_face_value() -> void:
	var entries := Settlement.build(_bags(), _rng(1), false)
	var rows := _rows(entries)
	var pickups := rows.map(func(row: Array) -> int: return row[1])
	# Normal items cheapest first (ties by pickup index), then piggy bank, ring, letter.
	_check(pickups == [0, 5, 6, 2, 1, 3, 4], "Reveal order is cheap to expensive, then the evidence (got %s)" % [pickups])
	_check(rows[4][3] == Effect.PIGGY and rows[5][3] == Effect.RING_REAL and rows[6][3] == Effect.LETTER_LOVE,
		"Without surprises the evidence keeps its face value")
	_check(Settlement.totals(entries) == Vector2i(10 + 200 + 0 + 150, 150 + 900 + 800), "Face-value totals equal the bag sums")
	_check(Settlement.is_valid(entries, 7), "A built list passes validation")
	_check(Settlement.build([], _rng(1)).is_empty() and Settlement.totals(PackedInt32Array()) == Vector2i.ZERO, "Empty bags settle to nothing")


func _test_rolls() -> void:
	var seen := {}
	for seed_value in 300:
		var entries := Settlement.build(_bags(), _rng(seed_value))
		var running := Vector2i.ZERO
		var ok := Settlement.is_valid(entries, 7)
		for row: Array in _rows(entries):
			seen[row[3]] = true
			match row[3]:
				Effect.PIGGY:
					ok = ok and row[2] % 10 == 0 and row[2] >= 0 and row[2] <= Settlement.PIGGY_MAX_COINS * 10
				Effect.RING_REAL:
					ok = ok and row[2] == 800
				Effect.RING_FAKE:
					ok = ok and row[2] == Settlement.FAKE_RING_GOLD
				Effect.LETTER_LOVE:
					ok = ok and row[2] == 150 and row[4] == 0
				Effect.LETTER_AFFAIR:
					ok = ok and row[2] == 150 and row[4] == mini(Settlement.ALIMONY, running[1 - row[0]])
			running[row[0]] += row[2] + row[4]
			running[1 - row[0]] -= row[4]
			ok = ok and running.x >= 0 and running.y >= 0
		ok = ok and running == Settlement.totals(entries)
		if not ok:
			_check(false, "Seed %d produced an inconsistent settlement %s" % [seed_value, entries])
			return
	_check(seen.has(Effect.RING_REAL) and seen.has(Effect.RING_FAKE) and seen.has(Effect.LETTER_LOVE) and seen.has(Effect.LETTER_AFFAIR),
		"Across seeds both ring and both letter outcomes occur")
	_check(Settlement.build(_bags(), _rng(7)) == Settlement.build(_bags(), _rng(7)), "The same seed gives the same settlement")


func _test_alimony_cap() -> void:
	# The wife's letter is revealed after the husband's 120 G are counted.
	var items := [[1, 0, "14-letter", 150], [0, 1, "04-kimchi", 120]]
	var affair := -1
	for seed_value in 50:
		var entries := Settlement.build(items, _rng(seed_value))
		if entries[3 + Settlement.STRIDE] == Effect.LETTER_AFFAIR:
			affair = seed_value
			_check(entries[4 + Settlement.STRIDE] == 120 and Settlement.totals(entries) == Vector2i(0, 270),
				"Alimony is capped by what the other player holds")
			break
	_check(affair >= 0, "Some seed rolls an affair letter")
	# Solo: nobody to take alimony from.
	for seed_value in 50:
		var solo := Settlement.build([[0, 0, "14-letter", 150]], _rng(seed_value))
		if solo[4] != 0 or Settlement.totals(solo) != Vector2i(150, 0):
			_check(false, "A solo letter never takes alimony")
			return


func _test_validation() -> void:
	var good := PackedInt32Array([0, 1, 120, Effect.NONE, 0, 1, 2, 150, Effect.LETTER_AFFAIR, 120])
	_check(Settlement.is_valid(good, 3), "A well-formed list is valid")
	var bad := {
		"short entry": PackedInt32Array([0, 1, 120, Effect.NONE]),
		"third player": PackedInt32Array([2, 1, 120, Effect.NONE, 0]),
		"pickup out of range": PackedInt32Array([0, 3, 120, Effect.NONE, 0]),
		"duplicate pickup": PackedInt32Array([0, 1, 120, Effect.NONE, 0, 1, 1, 10, Effect.NONE, 0]),
		"unknown effect": PackedInt32Array([0, 1, 120, 99, 0]),
		"negative gold": PackedInt32Array([0, 1, -5, Effect.NONE, 0]),
		"alimony without affair": PackedInt32Array([0, 1, 120, Effect.LETTER_LOVE, 50]),
		"alimony over the cap": PackedInt32Array([0, 1, 150, Effect.LETTER_AFFAIR, Settlement.ALIMONY + 1]),
	}
	for label: String in bad:
		_check(not Settlement.is_valid(bad[label], 3), "Rejects %s" % label)


func _check(condition: bool, message: String) -> void:
	if not condition:
		failed = true
		push_error(message)
