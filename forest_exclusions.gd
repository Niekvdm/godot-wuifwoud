# Copyright (c) 2026 Digitzone
# SPDX-License-Identifier: MIT
@tool
class_name ForestExclusions
extends RefCounted
## Areas where NOTHING grows (no tree, no bush, no ground clutter): the forest import (ForestImport) writes them into
## the forest maps as no forest.
##
## World-space polygons (x, z) from a per-map exclusions JSON, schema `vegetation_exclusions/1`: a volcano's bare
## summit, a landing meadow, a work site. A data file is hand-authorable and survives regenerating whatever the map's
## other sources come from, which is why this is not a hole cut into a land-use source.
##
## IMMUTABLE AFTER LOAD: `excludes` and `rings` touch only the arrays built here.

## The exclusions file's schema.
const SCHEMA := "vegetation_exclusions/1"

var _rings: Array[PackedVector2Array] = []
var _boxes: Array[Rect2] = []
## Union of every zone's box: a point outside it (almost every tree on the island) is rejected with one
## Rect2 test, before any ring is walked.
var _bounds := Rect2()


## Replace the set from `path`. "" or a missing file means no exclusions: a map without one. A file
## that exists but is malformed is an ERROR, appended to `errors` (an exclusion dropped in silence plants
## a forest in a crater), and leaves the set empty so the map still loads.
func load_file(path: String, errors: Array) -> void:
	_rings.clear()
	_boxes.clear()
	_bounds = Rect2()
	if path == "" or not FileAccess.file_exists(path):
		return
	var data = JSON.parse_string(FileAccess.get_file_as_string(path))
	if typeof(data) != TYPE_DICTIONARY:
		errors.append("%s: not a JSON object" % path)
		return
	if str(data.get("schema", "")) != SCHEMA:
		errors.append("%s: schema must be '%s', got '%s'" % [path, SCHEMA, str(data.get("schema", ""))])
		return
	if str(data.get("coord_space", "")) != "world":
		errors.append("%s: coord_space must be 'world'" % path)
		return
	var zones = data.get("zones", [])
	if typeof(zones) != TYPE_ARRAY:
		errors.append("%s: 'zones' must be an array" % path)
		return
	set_zones(zones, errors, path)


## Add zones ({"id", "outer": [[x, z], ...]}). A repeated closing point is dropped; a zone with fewer
## than 3 distinct points is reported and skipped.
func set_zones(zones: Array, errors: Array, where: String = "zones") -> void:
	for z in zones:
		var zd: Dictionary = z if typeof(z) == TYPE_DICTIONARY else {}
		var ring := PackedVector2Array()
		for c in zd.get("outer", []):
			if typeof(c) == TYPE_ARRAY and (c as Array).size() >= 2:
				ring.append(Vector2(float(c[0]), float(c[1])))
		if ring.size() >= 2 and ring[0].is_equal_approx(ring[ring.size() - 1]):
			ring.remove_at(ring.size() - 1)
		if ring.size() < 3:
			errors.append("%s: zone '%s' has fewer than 3 points" % [where, str(zd.get("id", "?"))])
			continue
		var box := Rect2(ring[0], Vector2.ZERO)
		for p in ring:
			box = box.expand(p)
		_bounds = box if _rings.is_empty() else _bounds.merge(box)
		_rings.append(ring)
		_boxes.append(box)


## How many zones the set holds.
func size() -> int:
	return _rings.size()


## The rectangle every zone lies in (empty for none).
func bounds() -> Rect2:
	return _bounds


## The zones' rings (world x, z): the forest import writes them into the forest maps as no forest.
func rings() -> Array[PackedVector2Array]:
	return _rings.duplicate()


## True when `p` (world x, z) lies inside any zone. Even-odd, so either winding works.
func excludes(p: Vector2) -> bool:
	if _rings.is_empty() or not _bounds.has_point(p):
		return false
	for i in _rings.size():
		# Native crossing test: a 184-point ring walked in GDScript was ~1 µs a vertex, per tree point.
		if _boxes[i].has_point(p) and Geometry2D.is_point_in_polygon(p, _rings[i]):
			return true
	return false

