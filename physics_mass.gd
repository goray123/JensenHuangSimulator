extends RefCounted

# Physical mass scales furniture and pickups independently of carry weight.
const DENSITY := 40.0
const MIN_MASS := 0.02
const PHYSICAL_MASS_SCALE := 0.5
const ITEM_WEIGHT_SCALE := 0.75


static func from_bounds(bounds: AABB) -> float:
	return maxf(bounds.get_volume() * DENSITY, MIN_MASS) * PHYSICAL_MASS_SCALE


static func from_item_bounds(bounds: AABB) -> float:
	return from_bounds(bounds) * ITEM_WEIGHT_SCALE
