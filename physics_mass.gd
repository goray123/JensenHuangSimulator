extends RefCounted

# World-size bounds determine base mass; pickups apply the item weight scale.
const DENSITY := 40.0
const MIN_MASS := 0.02
const ITEM_WEIGHT_SCALE := 0.75


static func from_bounds(bounds: AABB) -> float:
	return maxf(bounds.get_volume() * DENSITY, MIN_MASS)


static func from_item_bounds(bounds: AABB) -> float:
	return from_bounds(bounds) * ITEM_WEIGHT_SCALE
