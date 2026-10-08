# Copyright (c) 2026 Digitzone
# SPDX-License-Identifier: MIT
extends RefCounted
## The forest's native core: the library is built, found by name through ClassDB (never as an
## identifier: an editor that predates the library would not parse one) and made once; it says what it is. A library of
## another version counts as none and says so once.
##
## Run with a unit-suite runner: static run() returns {name, passed, failed, details}.

const NativeRes := preload("res://addons/wuifwoud/forest_native.gd")
const ForestLogRes := preload("res://addons/wuifwoud/forest_log.gd")
const Veg := preload("res://addons/wuifwoud/forest_spawner.gd")
const VA := preload("res://addons/wuifwoud/forest_assets.gd")


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
	var r := {"name": "wf_core", "passed": 0, "failed": 0, "details": []}
	var core = NativeRes.core()
	_chk(r, "the native core is built and found by name (if not: build it, see the addon's README, then a headless --import)",
		core != null)
	if core == null:
		return r
	_chk(r, "it says what it is (%s): the version these scripts need" % str(core.version()),
		str(core.version()) == NativeRes.VERSION and NativeRes.VERSION == "wuifwoud_core 3")
	_chk(r, "made once: asked again, the same object", is_same(NativeRes.core(), core))
	# The crowns kernel: the spawner's crown entries, byte for byte, from a trunk cell's raw records.
	VA._crown_cache["WfCrownTest"] = Vector2(13.37, 2.9)
	var raw := PackedFloat32Array([10.0, -12.5, 3.25, 1.125, -777.5, 4096.75, 512.0625, 0.8125, 0.1, 0.2, 0.3, 1.45])
	var want := PackedFloat32Array()
	for i in range(0, raw.size() - 3, 4):
		want.append_array(Veg._crown_entry("WfCrownTest", raw[i], raw[i + 1], raw[i + 2], raw[i + 3]))
	var c: Vector2 = VA.species_crown("WfCrownTest")
	var got: PackedFloat32Array = core.crowns(raw, c.x, c.y, Veg.CROWN_BOTTOM_FRAC)
	VA._crown_cache.erase("WfCrownTest")
	_chk(r, "the crowns kernel: the spawner's crown entries byte for byte; none for a species without a crown (%s)" % str(got),
		got == want and got.size() == 15 and (core.crowns(raw, 0.0, 2.0, 0.35) as PackedFloat32Array).is_empty())
	# A library of another version (built before these scripts, or the one an open editor still holds) counts as none
	# and says so once: rebuild it, then restart the editor (it would otherwise fail job by job on what it lacks).
	var keep: Callable = ForestLogRes.sink
	var cap := Capture.new()
	ForestLogRes.sink = cap.take
	NativeRes.expect_version = "wuifwoud_core 0"
	NativeRes.reprobe()
	var stale_none: bool = NativeRes.core() == null and not NativeRes.available()
	NativeRes.warn_missing()
	NativeRes.warn_missing()
	NativeRes.expect_version = NativeRes.VERSION
	NativeRes.reprobe()
	var back = NativeRes.core()
	ForestLogRes.sink = keep
	var said: String = str(cap.lines[0][1]) if cap.lines.size() == 1 else str(cap.lines)
	_chk(r, "a library of another version counts as none, said once: rebuild, then restart the editor (%s)" % said,
		stale_none and cap.lines.size() == 1 and "out of date" in said and "'wuifwoud_core 3'" in said
		and "restart the editor" in said and back != null)
	return r
