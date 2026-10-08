# Copyright (c) 2026 Digitzone
# SPDX-License-Identifier: MIT
extends RefCounted
## The native map summary: a map's blocks list the profile's types they hold, in the
## profile's order; a texel counts in the block its centre lies in; an id the profile lacks is named, never listed; a
## region west and south of the origin; only the blocks asked for (an edit's); a map whose bytes do not match its width
## refused with a reason; ForestMaps summarises and refreshes through it; two summaries byte for byte the same.
##
## Run with a unit-suite runner: static run() returns {name, passed, failed, details}.

const NativeRes := preload("res://addons/wuifwoud/forest_native.gd")
const MapsRes := preload("res://addons/wuifwoud/forest_maps.gd")
const ForestLogRes := preload("res://addons/wuifwoud/forest_log.gd")


static func _chk(r: Dictionary, n: String, ok: bool) -> void:
	if ok:
		r.passed += 1
	else:
		r.failed += 1
		r.details.append("✗ " + n)


static func _map(w: int, px: Array, patch := Rect2i(), ppx := [0, 0, 0, 0]) -> Image:
	var img := Image.create_empty(w, w, false, Image.FORMAT_RGBA8)
	img.fill(Color8(px[0], px[1], px[2], px[3]))
	if patch.size != Vector2i.ZERO:
		img.fill_rect(patch, Color8(ppx[0], ppx[1], ppx[2], ppx[3]))
	return img


## A 256 m region's summary at its own corner, blocks (0, 0)-(3, 3), from a map w texels square.
static func _sum(core, img: Image, loc := Vector2i.ZERO, ids := PackedInt32Array([1, 2])) -> Dictionary:
	var w := img.get_width()
	var b0 := Vector2i(loc.x * 4, loc.y * 4)
	return core.summarise_map(img.get_data(), w, float(loc.x) * 256.0, float(loc.y) * 256.0, 256.0 / float(w), ids, b0,
		b0 + Vector2i(3, 3))


class Capture:
	var lines: Array = []

	func take(level: StringName, msg: String) -> void:
		lines.append([level, msg])


static func run() -> Dictionary:
	var r := {"name": "wf_map_summary", "passed": 0, "failed": 0, "details": []}
	var core = NativeRes.core()
	_chk(r, "the native core is built (if not: build it, see the addon's README)", core != null)
	if core == null:
		return r
	# Type 1 left of x = 100, type 2 right of it, and an 8 m patch of type 9 (not in the profile) in the corner.
	var two := _map(256, [1, 255, 128, 0], Rect2i(100, 0, 156, 256), [2, 255, 128, 0])
	two.fill_rect(Rect2i(0, 0, 8, 8), Color8(9, 255, 128, 0))
	var s := _sum(core, two)
	var b: Dictionary = s["blocks"]
	_chk(r, "each block lists the types it holds, in the profile's order (%s %s %s)" % [str(b.get(Vector2i(0, 0))),
		str(b.get(Vector2i(1, 0))), str(b.get(Vector2i(3, 2)))],
		str(s["error"]) == "" and b.size() == 16 and Array(b[Vector2i(0, 0)]) == [1] and Array(b[Vector2i(1, 0)]) == [1, 2]
		and Array(b[Vector2i(3, 2)]) == [2])
	_chk(r, "an id the profile lacks is named, never listed (%s)" % str(s["unknown"]),
		Array(s["unknown"]) == [9] and not b.values().any(func(v): return Array(v).has(9)))
	# A 64 texel map (4 m texels): texel 16 spans x 64-68, its centre in block 1; texel 15 (60-64) in block 0.
	var t := _map(64, [0, 255, 128, 0], Rect2i(16, 0, 1, 1), [2, 255, 128, 0])
	var u := _map(64, [0, 255, 128, 0], Rect2i(15, 0, 1, 1), [2, 255, 128, 0])
	var tb: Dictionary = _sum(core, t)["blocks"]
	var ub: Dictionary = _sum(core, u)["blocks"]
	_chk(r, "a texel counts in the block its centre lies in (%s; %s)" % [str(tb.keys()), str(ub.keys())],
		tb.keys() == [Vector2i(1, 0)] and ub.keys() == [Vector2i(0, 0)])
	var neg: Dictionary = _sum(core, _map(64, [1, 255, 128, 0]), Vector2i(-1, -1))["blocks"]
	_chk(r, "a region west and south of the origin: its own 16 blocks, (-4, -4) to (-1, -1) (%d)" % neg.size(),
		neg.size() == 16 and neg.has(Vector2i(-4, -4)) and neg.has(Vector2i(-1, -1)) and not neg.has(Vector2i(0, 0)))
	var one: Dictionary = core.summarise_map(two.get_data(), 256, 0.0, 0.0, 1.0, PackedInt32Array([1, 2]), Vector2i(2, 1),
		Vector2i(2, 1))["blocks"]
	_chk(r, "only the blocks asked for (an edit's) (%s)" % str(one.keys()), one.keys() == [Vector2i(2, 1)])
	var bad: Dictionary = core.summarise_map(PackedByteArray([1, 2, 3]), 256, 0.0, 0.0, 1.0, PackedInt32Array([1]),
		Vector2i.ZERO, Vector2i(3, 3))
	_chk(r, "a map whose bytes do not match its width: refused with a reason, no block (%s)" % str(bad["error"]),
		str(bad["error"]) != "" and (bad["blocks"] as Dictionary).is_empty())
	# ForestMaps through it: adopt, then an edit refreshed.
	var keep: Callable = ForestLogRes.sink
	var cap := Capture.new()
	ForestLogRes.sink = cap.take
	var m = MapsRes.new()
	m.configure(256, 1.0, "")
	m.type_ids = PackedInt32Array([1, 2])
	m.editing = true
	m.adopt(Vector2i(0, 0), _map(256, [1, 255, 128, 0]))
	var before: Dictionary = m.blocks_in([Vector2i(0, 0)], Rect2(0, 0, 256, 256))
	var img: Image = m.edit_image(Vector2i(0, 0))
	img.fill_rect(Rect2i(130, 70, 4, 4), Color8(2, 255, 128, 255))
	m.refresh(Vector2i(0, 0), Rect2i(130, 70, 4, 4))
	var after: Dictionary = m.blocks_in([Vector2i(0, 0)], Rect2(0, 0, 256, 256))
	_chk(r, "ForestMaps summarises through it, and an edit refreshes its own block (%s -> %s)" % [
		str(before.get(Vector2i(2, 1))), str(after.get(Vector2i(2, 1)))],
		before.size() == 16 and Array(before[Vector2i(2, 1)]) == [1] and Array(after[Vector2i(2, 1)]) == [1, 2]
		and Array(after[Vector2i(1, 1)]) == [1])
	ForestLogRes.sink = keep
	_chk(r, "two summaries of one map are byte for byte the same", var_to_bytes(_sum(core, two)) == var_to_bytes(s))
	return r
