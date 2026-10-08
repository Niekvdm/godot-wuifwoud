# Copyright (c) 2026 Digitzone
# SPDX-License-Identifier: MIT
@tool
class_name ForestTerrain
extends RefCounted
## Finding the Terrain3D node and reading its height, for the forest (a copy of the game's terrain lookup, so
## the addon needs nothing of the game). Terrain3D is matched by class name, searched outward from a node: each
## ancestor's subtree, skipping the child subtree already covered, so a full miss visits each node once. A hit is
## cached until the terrain leaves the tree; a miss is retried on a clock that doubles from 1 s to 8 s, because the
## walk is the cost (~2 ms on a big scene) and a terrain-less scene would pay it forever. height_at is NaN without a
## terrain or outside the loaded regions: callers treat NaN as "unknown".

## Retry finding a terrain after this long (ms), doubling each time.
const RETRY_MS := 1000
## The longest wait between retries (ms).
const RETRY_MAX_MS := 8000

static var _terrain: Node = null
static var _interval_ms := RETRY_MS
static var _next_ms := 0


## The terrain the forest uses, from `from`'s scene, remembered once found.
static func find_cached(from: Node) -> Node:
	if _terrain != null and is_instance_valid(_terrain) and _terrain.is_inside_tree():
		return _terrain
	_terrain = null
	var now := Time.get_ticks_msec()
	if now < _next_ms:
		return null
	_terrain = find(from)
	if _terrain != null:
		_interval_ms = RETRY_MS
		_next_ms = now + RETRY_MS
	else:
		_next_ms = now + _interval_ms
		_interval_ms = mini(_interval_ms * 2, RETRY_MAX_MS)
	return _terrain


## The Terrain3D node in `from`'s scene, or null.
static func find(from: Node) -> Node:
	var ancestor: Node = from
	var covered: Node = null
	while ancestor != null:
		var found := _find_below(ancestor, covered)
		if found != null:
			return found
		covered = ancestor
		ancestor = ancestor.get_parent()
	return null


static func _find_below(node: Node, skip: Node = null) -> Node:
	for child in node.get_children():
		if child == skip:
			continue
		if child.get_class() == "Terrain3D":
			return child
		var nested := _find_below(child)
		if nested != null:
			return nested
	return null


## The terrain's height at a world point (NAN where it has none).
static func height_at(terrain: Node, world_pos: Vector3) -> float:
	if terrain == null or not is_instance_valid(terrain):
		return NAN
	return terrain.data.get_height(world_pos)


## Tests and scene swaps: forget the cached terrain and the retry clock.
static func reset() -> void:
	_terrain = null
	_interval_ms = RETRY_MS
	_next_ms = 0
