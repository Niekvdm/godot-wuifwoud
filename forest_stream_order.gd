# Copyright (c) 2026 Digitzone
# SPDX-License-Identifier: MIT
@tool
class_name ForestStreamOrder
extends RefCounted
## The ordering rule for the forest's camera-following rings (a copy of the game's stream priority rule, so the
## addon needs nothing of the game; grass and forest fill in the same order while they agree). Lower score = sooner.
## score = distance * (1 + behind_weight * (1 - cos θ) / 2 * ramp(distance))
##
## Straight ahead costs its plain distance; a cell directly behind the camera costs
## (1 + behind_weight)x that, so at the default 2 it is built after anything ahead
## within three times its range. Inside `free_radius_m` the direction term ramps to
## nothing: the player can turn their head faster than a ring can fill, so the
## ground under and around them is never deferred for looking the other way.
##
## Pure and static: callable from any thread, no scene access.

## How much a cell behind the camera counts against one ahead of it.
const BEHIND_WEIGHT := 2.0
## Inside this radius direction does not matter: nearest first.
const FREE_RADIUS_M := 30.0


## A cell centre's score from the eye and the look direction: lower fills first.
static func score(centre: Vector2, eye: Vector2, look: Vector2,
		behind_weight: float = BEHIND_WEIGHT, free_radius_m: float = FREE_RADIUS_M) -> float:
	var to := centre - eye
	var d := to.length()
	if d <= 0.0001:
		return 0.0
	var look_len := look.length()
	if look_len <= 0.0001 or behind_weight <= 0.0:
		return d
	var cos_t := to.dot(look) / (d * look_len)
	var ramp := clampf((d - free_radius_m) / maxf(free_radius_m, 0.001), 0.0, 1.0)
	return d * (1.0 + behind_weight * (1.0 - cos_t) * 0.5 * ramp)


## Indices of `centres` in ascending score order, via ONE native sort over packed
## (score, index) keys. A sort_custom with a GDScript comparator costs a closure
## call per compare (~10 ms for a thousand cells), which is why rings call this
## instead. Scores are quantised to 1/1024 m; ties fall back to index order.
static func order_indices(centres: PackedVector2Array, eye: Vector2, look: Vector2,
		behind_weight: float = BEHIND_WEIGHT, free_radius_m: float = FREE_RADIUS_M) -> PackedInt32Array:
	var n := centres.size()
	var keys := PackedInt64Array()
	keys.resize(n)
	for i in n:
		var s := score(centres[i], eye, look, behind_weight, free_radius_m)
		keys[i] = (int(s * 1024.0) << 20) | i
	keys.sort()
	var out := PackedInt32Array()
	out.resize(n)
	for i in n:
		out[i] = int(keys[i] & 0xFFFFF)
	return out
