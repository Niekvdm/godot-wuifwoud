# Copyright (c) 2026 Digitzone
# SPDX-License-Identifier: MIT
extends RefCounted
## ForestBrush: each Forest tool's texel rule: Paint (the 0.5 threshold; empty ground starts
## full and neutral, forest keeps its density and age; Ctrl: no forest), Replace (only the From type), Density and Age
## (typed texels only, clamped), Smooth (toward the weighted mean); the painted mark (A = 255 only where R, G or B
## changed), a dab across a region seam, a region without terrain, the brush image and gamma, the touched rectangles,
## the undo's first-change call and take_fresh; Revert (the mapping's texels, unmarked; a rectangle a region).
##
## Run with a unit-suite runner: static run() returns {name, passed, failed, details}.

const BrushRes := preload("res://addons/wuifwoud/forest_brush.gd")
const RM := 64.0           # 64 m regions, one texel a metre
const NONE := [0, 255, 128, 0]
const PAINTED := [2, 255, 128, 255]


static func _chk(r: Dictionary, n: String, ok: bool) -> void:
	if ok:
		r.passed += 1
	else:
		r.failed += 1
		r.details.append("✗ " + n)


static func _map(px: Array) -> Image:
	var img := Image.create_empty(64, 64, false, Image.FORMAT_RGBA8)
	img.fill(Color8(px[0], px[1], px[2], px[3]))
	return img


## A brush over `imgs` (location -> Image; a location not in it has no terrain).
static func _brush(imgs: Dictionary):
	var b = BrushRes.new()
	b.region_m = RM
	b.image_of = func(l: Vector2i): return imgs.get(l)
	b.begin()
	return b


static func _disc(size: float, strength := 1.0, shape: Image = null, gamma := 1.0) -> Dictionary:
	return {"size": size, "strength": strength, "pressure": 1.0, "image": shape, "gamma": gamma}


static func _px(img: Image, i: int, j: int) -> Array:
	var c := img.get_pixel(i, j)
	return [c.r8, c.g8, c.b8, c.a8]


static func _count(img: Image, px: Array) -> int:
	var n := 0
	for j in img.get_height():
		for i in img.get_width():
			if _px(img, i, j) == px:
				n += 1
	return n


## Texels of a 64-texel map whose centre lies within `radius` of (cx, cz), map-local metres.
static func _in_disc(cx: float, cz: float, radius: float) -> int:
	var n := 0
	for j in 64:
		for i in 64:
			if Vector2(i + 0.5 - cx, j + 0.5 - cz).length_squared() <= radius * radius:
				n += 1
	return n


static func run() -> Dictionary:
	var r := {"name": "forest_brush", "passed": 0, "failed": 0, "details": []}
	var want := _in_disc(20.0, 20.0, 4.0)

	# ── Paint on empty ground ──
	var a := _map(NONE)
	_brush({Vector2i(0, 0): a}).dab(Vector3(20, 0, 20), _disc(8.0), {"op": BrushRes.Op.PAINT, "type": 2})
	_chk(r, "Paint: every texel under the disc is type 2, full, neutral, marked (%d of %d)" % [_count(a, PAINTED), want],
		_count(a, PAINTED) == want and _count(a, NONE) == 4096 - want)

	# ── Paint over forest keeps its density and age ──
	var f := _map([1, 100, 40, 0])
	_brush({Vector2i(0, 0): f}).dab(Vector3(20, 0, 20), _disc(8.0), {"op": BrushRes.Op.PAINT, "type": 2})
	_chk(r, "Paint over forest keeps G and B (%s)" % str(_px(f, 20, 20)), _px(f, 20, 20) == [2, 100, 40, 255])

	# ── the 0.5 threshold: a type is painted where the weight is 0.5 or more, never blended ──
	var lo := _map(NONE)
	var blo = _brush({Vector2i(0, 0): lo})
	blo.dab(Vector3(20, 0, 20), _disc(8.0, 0.4), {"op": BrushRes.Op.PAINT, "type": 2})
	var hi := _map(NONE)
	_brush({Vector2i(0, 0): hi}).dab(Vector3(20, 0, 20), _disc(8.0, 0.6), {"op": BrushRes.Op.PAINT, "type": 2})
	_chk(r, "Paint: weight 0.4 changes nothing, 0.6 paints (%d, %d)" % [_count(lo, NONE), _count(hi, PAINTED)],
		blo.touched.is_empty() and _count(lo, NONE) == 4096 and _count(hi, PAINTED) == want)

	# ── Ctrl: no forest, density and age kept ──
	var e := _map([1, 90, 30, 0])
	_brush({Vector2i(0, 0): e}).dab(Vector3(20, 0, 20), _disc(8.0), {"op": BrushRes.Op.ERASE})
	_chk(r, "Ctrl (Erase): R 0, G and B kept, marked (%s)" % str(_px(e, 20, 20)), _px(e, 20, 20) == [0, 90, 30, 255])

	# ── Replace: only the From type ──
	var rp := _map([1, 255, 128, 0])
	rp.fill_rect(Rect2i(20, 0, 44, 32), Color8(3, 255, 128, 0))
	rp.fill_rect(Rect2i(0, 32, 64, 32), Color8(0, 255, 128, 0))
	_brush({Vector2i(0, 0): rp}).dab(Vector3(20, 0, 32), _disc(30.0), {"op": BrushRes.Op.REPLACE, "type": 2, "from": 1})
	_chk(r, "Replace turns From (1) into 2, leaves 3 and empty ground alone (%s %s %s)" % [str(_px(rp, 15, 25)),
		str(_px(rp, 25, 25)), str(_px(rp, 15, 40))], _px(rp, 15, 25) == [2, 255, 128, 255]
		and _px(rp, 25, 25) == [3, 255, 128, 0] and _px(rp, 15, 40) == [0, 255, 128, 0])

	# ── Density: typed texels only, clamped ──
	var d := _map([1, 250, 128, 0])
	d.fill_rect(Rect2i(0, 0, 32, 64), Color8(0, 250, 128, 0))
	_brush({Vector2i(0, 0): d}).dab(Vector3(32, 0, 32), _disc(8.0), {"op": BrushRes.Op.DENSITY_UP})
	var dn := _map([1, 10, 128, 0])
	_brush({Vector2i(0, 0): dn}).dab(Vector3(32, 0, 32), _disc(8.0), {"op": BrushRes.Op.DENSITY_DOWN})
	_chk(r, "Density: +STEP clamps at 255 on forest, skips empty ground (unmarked); −STEP clamps at 0 (%s %s %s)" % [
		str(_px(d, 33, 32)), str(_px(d, 30, 32)), str(_px(dn, 32, 32))], _px(d, 33, 32) == [1, 255, 128, 255]
		and _px(d, 30, 32) == [0, 250, 128, 0] and _px(dn, 32, 32) == [1, 0, 128, 255])

	# ── Age: the same on B, by weight ──
	var ag := _map([1, 255, 100, 0])
	_brush({Vector2i(0, 0): ag}).dab(Vector3(32, 0, 32), _disc(8.0, 0.5), {"op": BrushRes.Op.AGE_UP})
	var ay := _map([1, 255, 100, 0])
	_brush({Vector2i(0, 0): ay}).dab(Vector3(32, 0, 32), _disc(8.0, 0.5), {"op": BrushRes.Op.AGE_DOWN})
	_chk(r, "Age: older +STEP·w, younger −STEP·w (%s %s)" % [str(_px(ag, 32, 32)), str(_px(ay, 32, 32))],
		_px(ag, 32, 32) == [1, 255, 132, 255] and _px(ay, 32, 32) == [1, 255, 68, 255])

	# ── Smooth: density and age go to the weighted mean of the typed texels under the brush ──
	var sm := _map([1, 0, 0, 0])
	for j in 64:
		for i in 64:
			if (i + j) % 2 == 0:
				sm.set_pixel(i, j, Color8(1, 200, 100, 0))
	_brush({Vector2i(0, 0): sm}).dab(Vector3(32, 0, 32), _disc(6.0), {"op": BrushRes.Op.SMOOTH})
	var vals := {}
	for j in range(29, 36):
		for i in range(29, 36):
			if Vector2(i + 0.5 - 32.0, j + 0.5 - 32.0).length() <= 3.0:
				vals[str(_px(sm, i, j))] = true
	_chk(r, "Smooth: a checkerboard under a full-strength brush becomes one value (%s)" % str(vals.keys()),
		vals.size() == 1)

	# ── the mark: a dab that changes nothing marks nothing ──
	var same := _map([2, 255, 128, 0])
	var bs = _brush({Vector2i(0, 0): same})
	bs.dab(Vector3(20, 0, 20), _disc(8.0), {"op": BrushRes.Op.PAINT, "type": 2})
	_chk(r, "a stroke over matching forest marks nothing (%d unmarked)" % _count(same, [2, 255, 128, 0]),
		bs.touched.is_empty() and _count(same, [2, 255, 128, 0]) == 4096)

	# ── a dab across a region seam; the undo hears each region once a stroke ──
	var west := _map(NONE)
	var east := _map(NONE)
	var calls := []
	var bw = _brush({Vector2i(0, 0): west, Vector2i(1, 0): east})
	bw.on_first_change = func(l: Vector2i): calls.append(l)
	bw.dab(Vector3(64.0, 0.0, 32.0), _disc(8.0), {"op": BrushRes.Op.PAINT, "type": 2})
	bw.dab(Vector3(64.0, 0.0, 33.0), _disc(8.0), {"op": BrushRes.Op.PAINT, "type": 2})
	_chk(r, "a dab across a seam paints both regions; the undo hears each once (%s, %s)" % [str(bw.touched), str(calls)],
		bw.touched.size() == 2 and (bw.touched[Vector2i(0, 0)] as Rect2i).position.x == 60
		and (bw.touched[Vector2i(1, 0)] as Rect2i).end.x == 4 and calls.size() == 2)

	# ── a region without terrain ──
	var lone := _map(NONE)
	var bn = _brush({Vector2i(0, 0): lone})
	bn.dab(Vector3(64.0, 0.0, 32.0), _disc(8.0), {"op": BrushRes.Op.PAINT, "type": 2})
	_chk(r, "where the terrain has no region the dab paints only what exists (%s)" % str(bn.touched.keys()),
		bn.touched.keys() == [Vector2i(0, 0)])

	# ── the brush image's red, raised to gamma, weighs each texel ──
	var shape := Image.create_empty(4, 4, false, Image.FORMAT_RGB8)
	shape.fill(Color8(153, 153, 153))            # 0.6
	var g1 := _map(NONE)
	_brush({Vector2i(0, 0): g1}).dab(Vector3(20, 0, 20), _disc(8.0, 1.0, shape, 1.0), {"op": BrushRes.Op.PAINT, "type": 2})
	var g2 := _map(NONE)
	_brush({Vector2i(0, 0): g2}).dab(Vector3(20, 0, 20), _disc(8.0, 1.0, shape, 2.0), {"op": BrushRes.Op.PAINT, "type": 2})
	_chk(r, "the brush image at 0.6: gamma 1 paints its square, gamma 2 (0.36) does not (%d, %d)" % [
		_count(g1, PAINTED), _count(g2, NONE)], _count(g1, PAINTED) == 64 and _count(g2, NONE) == 4096)

	# ── take_fresh: what changed since the last call, once ──
	var t := _map(NONE)
	var bt = _brush({Vector2i(0, 0): t})
	bt.dab(Vector3(10, 0, 10), _disc(2.0), {"op": BrushRes.Op.PAINT, "type": 2})
	var f1: Dictionary = bt.take_fresh()
	var f2: Dictionary = bt.take_fresh()
	_chk(r, "take_fresh hands over the rectangles changed since the last call, once (%s, %s)" % [str(f1), str(f2)],
		f1.size() == 1 and f1.has(Vector2i(0, 0)) and f2.is_empty() and bt.touched.size() == 1)

	# ── Revert: the mapping's texels, unmarked, asked once a region for the dab's rectangle ──
	var rv := _map(PAINTED)
	rv.set_pixel(30, 30, Color8(5, 255, 128, 0))                 # already what the mapping says
	var asked := []
	var br = _brush({Vector2i(0, 0): rv})
	br.revert_of = func(loc: Vector2i, rect: Rect2i, w: int) -> PackedByteArray:
		asked.append([loc, rect, w])
		var out := PackedByteArray()
		for _i in rect.size.x * rect.size.y:
			out.append_array(PackedByteArray([5, 255, 128, 0]))
		return out
	br.dab(Vector3(20, 0, 20), _disc(8.0), {"op": BrushRes.Op.REVERT})
	_chk(r, "Revert: every texel under the disc takes the mapping's texel, A 0, one ask for the dab's rectangle (%d; %s)" % [
		_count(rv, [5, 255, 128, 0]), str(asked)], _count(rv, [5, 255, 128, 0]) == want + 1
		and _count(rv, PAINTED) == 4096 - want - 1 and asked == [[Vector2i(0, 0), Rect2i(16, 16, 8, 8), 64]])
	var same_rv := _map([5, 255, 128, 0])
	var bsr = _brush({Vector2i(0, 0): same_rv})
	bsr.revert_of = br.revert_of
	bsr.dab(Vector3(20, 0, 20), _disc(8.0), {"op": BrushRes.Op.REVERT})
	var low := _map(PAINTED)
	var bl = _brush({Vector2i(0, 0): low})
	bl.revert_of = br.revert_of
	bl.dab(Vector3(20, 0, 20), _disc(8.0, 0.4), {"op": BrushRes.Op.REVERT})
	var bz = _brush({Vector2i(0, 0): _map(PAINTED)})
	bz.dab(Vector3(20, 0, 20), _disc(8.0), {"op": BrushRes.Op.REVERT})
	_chk(r, "Revert changes nothing already as the mapping says, nothing below weight 0.5, nothing without a mapping (%s)" % str(
		[bsr.touched.size(), bl.touched.size(), bz.touched.size()]),
		bsr.touched.is_empty() and bl.touched.is_empty() and bz.touched.is_empty() and _count(low, PAINTED) == 4096)
	return r
