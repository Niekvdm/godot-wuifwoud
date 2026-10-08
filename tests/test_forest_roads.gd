# Copyright (c) 2026 Digitzone
# SPDX-License-Identifier: MIT
extends RefCounted
## The forest's road corridor: set_road_segments takes ROAD_STRIDE floats a segment
## (ax, az, bx, bz, half width), adds road_margin, and gates points the way _build_road_blocker did; an empty array
## is a map without roads; a malformed one is refused and changes nothing; before any call nothing is gated. The gate read
## here is the main thread's (the Place tools' cursor note, the clutter ring); the native scatter's is test_wf_tables'.
##
## Run with a unit-suite runner: static run() returns {name, passed, failed, details}.

const Veg := preload("res://addons/wuifwoud/forest_spawner.gd")
const ForestLogRes := preload("res://addons/wuifwoud/forest_log.gd")


class Capture:
	var lines: Array = []

	func take(level: StringName, msg: String) -> void:
		lines.append([level, msg])


static func _chk(r: Dictionary, n: String, ok: bool) -> void:
	if ok:
		r.passed += 1
	else:
		r.failed += 1
		r.details.append("✗ " + n)


static func run() -> Dictionary:
	var r := {"name": "forest_roads", "passed": 0, "failed": 0, "details": []}
	var keep: Callable = ForestLogRes.sink
	var cap := Capture.new()
	ForestLogRes.sink = cap.take
	var vs = Veg.new()
	vs.road_margin = 3.0
	_chk(r, "before any call nothing is gated", not vs._road_blocker_built and not vs._road_blocked_within(Vector2(50.0, 2.0), vs.road_margin))
	vs.set_road_segments(PackedFloat64Array([0.0, 0.0, 100.0, 0.0, 4.5, 200.0, 200.0, 200.0, 300.0, 4.0]))
	_chk(r, "two segments (%d)" % vs._road_rects.size(), vs._road_rects.size() == 2)
	_chk(r, "the half width carries road_margin (7.5 and 7.0)", vs._road_rects.size() == 2
		and is_equal_approx(float(vs._road_rects[0]["hw"]), 7.5) and is_equal_approx(float(vs._road_rects[1]["hw"]), 7.0))
	_chk(r, "a point on the first road is blocked", vs._road_blocked_within(Vector2(50.0, 2.0), vs.road_margin))
	_chk(r, "a point 30 m off it is not", not vs._road_blocked_within(Vector2(50.0, 30.0), vs.road_margin))
	_chk(r, "a point beside the second road is blocked", vs._road_blocked_within(Vector2(203.0, 250.0), vs.road_margin))
	_chk(r, "the corridor is marked built", vs._road_blocker_built)
	vs.set_road_segments(PackedFloat64Array([1.0, 2.0, 3.0]))
	_chk(r, "a malformed array is refused with an error and changes nothing",
		vs._road_rects.size() == 2 and cap.lines.any(func(l): return l[0] == &"error"))
	vs.set_road_segments(PackedFloat64Array())
	_chk(r, "an empty array is a map without roads: built, nothing gated",
		vs._road_rects.is_empty() and vs._road_blocker_built and not vs._road_blocked_within(Vector2(50.0, 2.0), vs.road_margin))
	vs.free()
	ForestLogRes.sink = keep
	return r
