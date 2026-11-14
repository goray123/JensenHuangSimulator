extends RefCounted
## Final property split. Every bagged item counts its gold; special evidence (piggy bank,
## ring, letter) is rolled once by the host and revealed last. Both peers replay the same
## packed list in the ending, so the counters, the cards and the verdict always agree.

enum Effect { NONE, PIGGY, RING_REAL, RING_FAKE, LETTER_LOVE, LETTER_AFFAIR }

## One entry: [player, pickup index, gold counted for the owner, Effect, gold taken from the other player].
const STRIDE := 5
const PIGGY_ID := "16-piggy-bank"
const RING_ID := "12-ring"
const LETTER_ID := "14-letter"
## Evidence order in the reveal: the letter can reverse the result, so it closes the show.
const SPECIAL_ORDER: Array[String] = [PIGGY_ID, RING_ID, LETTER_ID]
## The piggy bank breaks open to 0..600 G in 10 G coins.
const PIGGY_MAX_COINS := 60
const FAKE_RING_CHANCE := 0.3
const FAKE_RING_GOLD := 50
const AFFAIR_CHANCE := 0.5
## Alimony moved from the other player by an affair letter, capped by what they hold at that point.
const ALIMONY := 500
const MAX_GOLD := 1_000_000


## items: one [player_index, pickup_index, item_id, gold_value] per bagged item.
## With surprises off (tutorial) evidence keeps its face value: real ring, love letter, unbroken piggy bank.
static func build(items: Array, rng: RandomNumberGenerator, surprises := true) -> PackedInt32Array:
	var normal := items.filter(func(item: Array) -> bool: return item[2] not in SPECIAL_ORDER)
	# Cheapest first so the counters build up to the big items.
	normal.sort_custom(func(a: Array, b: Array) -> bool: return a[3] < b[3] if a[3] != b[3] else a[1] < b[1])
	var special := items.filter(func(item: Array) -> bool: return item[2] in SPECIAL_ORDER)
	special.sort_custom(func(a: Array, b: Array) -> bool:
		var order_a := SPECIAL_ORDER.find(a[2])
		var order_b := SPECIAL_ORDER.find(b[2])
		if order_a != order_b:
			return order_a < order_b
		return a[0] < b[0] if a[0] != b[0] else a[1] < b[1])
	var entries := PackedInt32Array()
	var gold := Vector2i.ZERO
	for item: Array in normal:
		entries.append_array([item[0], item[1], item[3], Effect.NONE, 0])
		gold[item[0]] += item[3]
	for item: Array in special:
		var player: int = item[0]
		var value: int = item[3]
		var effect := Effect.NONE
		var taken := 0
		match item[2]:
			PIGGY_ID:
				effect = Effect.PIGGY
				if surprises:
					value = rng.randi_range(0, PIGGY_MAX_COINS) * 10
			RING_ID:
				var fake := surprises and rng.randf() < FAKE_RING_CHANCE
				effect = Effect.RING_FAKE if fake else Effect.RING_REAL
				if fake:
					value = mini(value, FAKE_RING_GOLD)
			LETTER_ID:
				var affair := surprises and rng.randf() < AFFAIR_CHANCE
				effect = Effect.LETTER_AFFAIR if affair else Effect.LETTER_LOVE
				if affair:
					taken = mini(ALIMONY, gold[1 - player])
		gold[player] += value + taken
		gold[1 - player] -= taken
		entries.append_array([player, item[1], value, effect, taken])
	return entries


## Final gold per player index (x = husband/host, y = wife/guest).
static func totals(entries: PackedInt32Array) -> Vector2i:
	var gold := Vector2i.ZERO
	for offset in range(0, entries.size() - STRIDE + 1, STRIDE):
		var player := entries[offset]
		gold[player] += entries[offset + 2] + entries[offset + 4]
		gold[1 - player] -= entries[offset + 4]
	return gold


## Checks a host list before a peer replays it: shape, indices, effects and gold ranges.
static func is_valid(entries: PackedInt32Array, pickup_count: int) -> bool:
	if entries.size() % STRIDE != 0:
		return false
	var seen := {}
	for offset in range(0, entries.size(), STRIDE):
		var pickup := entries[offset + 1]
		if entries[offset] not in [0, 1] or pickup < 0 or pickup >= pickup_count or seen.has(pickup):
			return false
		if entries[offset + 3] < 0 or entries[offset + 3] >= Effect.size():
			return false
		if entries[offset + 2] < 0 or entries[offset + 2] > MAX_GOLD or entries[offset + 4] < 0 or entries[offset + 4] > ALIMONY:
			return false
		if entries[offset + 4] > 0 and entries[offset + 3] != Effect.LETTER_AFFAIR:
			return false
		seen[pickup] = true
	return true
