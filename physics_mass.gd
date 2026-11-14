extends RefCounted

# Use the same density for every object; its world-size bounds determine mass.
const DENSITY := 40.0
const MIN_MASS := 0.02


static func from_bounds(bounds: AABB) -> float:
	return maxf(bounds.get_volume() * DENSITY, MIN_MASS)
