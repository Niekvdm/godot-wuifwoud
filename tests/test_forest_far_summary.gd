# Copyright (c) 2026 Digitzone
# SPDX-License-Identifier: MIT
extends RefCounted
## The far summary through ForestFar's worker step, the native core's: the type at each far
## texel's centre (or the first the profile has in it), the cover (the share of its map texels whose type the profile
## has, times their density, exactly), the mean age; for a full stand, a half-density one, a half-covered texel, a
## second type, a bare map and an id the profile lacks; a map of another texel size; a map not square, or bytes that do
## not match a width, refused; a 1024² map in under 50 ms; two summaries byte for byte the same, a bare map no cover.
##
## Run with a unit-suite runner: static run() returns {name, passed, failed, details}.

const FarRes := preload("res://addons/wuifwoud/forest_far.gd")
const NativeRes := preload("res://addons/wuifwoud/forest_native.gd")


static func _chk(r: Dictionary, n: String, ok: bool) -> void:
	if ok:
		r.passed += 1
	else:
		r.failed += 1
		r.details.append("✗ " + n)


## A w² map filled with `px` ([R, G, B, A]).
static func _map(w: int, px: Array) -> Image:
	var img := Image.create_empty(w, w, false, Image.FORMAT_RGBA8)
	img.fill(Color8(px[0], px[1], px[2], px[3]))
	return img


## ForestFar's summary job for `img` (a map of a region `rs` vertices a side): {"out": the summary's bytes, "any"}.
static func _job(img: Image, out_w: int, ids: PackedInt32Array, rs := 256) -> Dictionary:
	var job := {"img": img, "rs": rs, "w": out_w, "ids": ids, "core": NativeRes.core(), "out": PackedByteArray(),
		"any": false, "hash": 0}
	FarRes._run_summary(job)
	return job


## The summary as an Image out_w square, or null when the map was refused.
static func _summary(img: Image, out_w: int, ids: PackedInt32Array, rs := 256) -> Image:
	var out: PackedByteArray = _job(img, out_w, ids, rs)["out"]
	return Image.create_from_data(out_w, out_w, false, Image.FORMAT_RGBA8, out) if not out.is_empty() else null


## The far texel (i, j) of a summary: [R, G, B, A].
static func _at(s: Image, i: int, j: int) -> Array:
	var d := s.get_data()
	var o := (j * s.get_width() + i) * 4
	return [d[o], d[o + 1], d[o + 2], d[o + 3]]


static func run() -> Dictionary:
	var r := {"name": "forest_far_summary", "passed": 0, "failed": 0, "details": []}
	_chk(r, "the native core is built (if not: build it, see the addon's README)", NativeRes.core() != null)
	if NativeRes.core() == null:
		return r
	var ids := PackedInt32Array([1, 2])
	var full := _summary(_map(256, [1, 255, 128, 0]), 32, ids)
	_chk(r, "a full stand: every far texel type 1, cover 255, age 128 (%s)" % (str(_at(full, 5, 7)) if full != null else "null"),
		full != null and full.get_width() == 32 and _at(full, 0, 0) == [1, 255, 128, 0] and _at(full, 31, 31) == [1, 255, 128, 0])
	# The left half forest at half density, the right half bare (as the import writes no forest: G 255).
	var half := _map(256, [0, 255, 128, 0])
	half.fill_rect(Rect2i(0, 0, 128, 256), Color8(1, 128, 200, 0))
	var hs := _summary(half, 32, ids)
	_chk(r, "half density on the left, bare on the right: cover 128 and age 200 there, nothing here (%s %s)" % [
		str(_at(hs, 3, 3)), str(_at(hs, 28, 3))],
		_at(hs, 3, 3) == [1, 128, 200, 0] and _at(hs, 28, 3)[0] == 0 and _at(hs, 28, 3)[1] == 0)
	# Far texel (0, 0), map texels 0-7, has rows 0-3 of type 2 at full density and rows 4-7 bare: its centre is bare.
	var stripes := _map(256, [0, 255, 128, 0])
	stripes.fill_rect(Rect2i(0, 0, 8, 4), Color8(2, 255, 128, 0))
	var ss := _summary(stripes, 32, ids)
	var sc: Array = _at(ss, 0, 0)
	_chk(r, "a far texel half covered: cover half (share x density, exactly), and the type found in it though its centre is bare (%s)" % str(sc),
		sc[0] == 2 and sc[1] == 128 and _at(ss, 1, 0)[1] == 0)
	var stray := _map(256, [9, 255, 128, 0])
	stray.fill_rect(Rect2i(0, 0, 128, 256), Color8(1, 255, 128, 0))
	var st := _summary(stray, 32, ids)
	_chk(r, "an id the profile lacks is no forest (%s %s)" % [str(_at(st, 3, 3)), str(_at(st, 28, 3))],
		_at(st, 3, 3) == [1, 255, 128, 0] and _at(st, 28, 3)[0] == 0 and _at(st, 28, 3)[1] == 0)
	var coarse := _summary(_map(64, [1, 200, 128, 0]), 32, ids)
	var fine := _summary(_map(32, [1, 200, 128, 0]), 64, ids)
	_chk(r, "a map of another texel size: its box means, or its texels repeated where the summary is the wider",
		coarse != null and _at(coarse, 10, 10) == [1, 200, 128, 0] and fine != null and fine.get_width() == 64
		and _at(fine, 63, 63) == [1, 200, 128, 0])
	var bad: Dictionary = NativeRes.core().far_summarise(PackedByteArray([1, 2, 3]), 64, 32, ids)
	_chk(r, "a map not square, or bytes that do not match a width: no summary",
		_summary(Image.create_empty(64, 32, false, Image.FORMAT_RGBA8), 32, ids) == null
		and (bad["texels"] as PackedByteArray).is_empty() and not bool(bad["any"]))
	# A 1024² map, every far texel at the edge of a stand of type 1 or 2.
	var big := _map(1024, [0, 255, 128, 0])
	for b in range(0, 1024, 16):
		big.fill_rect(Rect2i(b, 0, 8, 1024), Color8(1 + ((b >> 4) % 2), 180, 90, 0))
	_summary(big, 128, ids, 1024)
	var best := 1e9
	for _i in 3:
		var t0 := Time.get_ticks_usec()
		_summary(big, 128, ids, 1024)
		best = minf(best, float(Time.get_ticks_usec() - t0) / 1000.0)
	_chk(r, "a 1024² map summarises in under 50 ms (%.1f ms)" % best, best < 50.0)
	var again := _job(half, 32, ids)
	_chk(r, "two summaries of one map are byte for byte the same; a bare map has no cover",
		(again["out"] as PackedByteArray) == hs.get_data() and bool(again["any"])
		and not bool(_job(_map(256, [0, 255, 128, 0]), 32, ids)["any"]))
	return r
