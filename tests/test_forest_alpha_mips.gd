# Copyright (c) 2026 Digitzone
# SPDX-License-Identifier: MIT
extends RefCounted
## Coverage-preserving alpha mips (ForestAlphaMips): each mip's share of texels at or over the cut is the base level's,
## per tile, for a dense blob (plain mips thin it out) and for thin lines (plain mips lose them); the base level is
## untouched; a premultiplied sheet keeps its colour (colour / alpha) as its alpha is scaled.
##
## Run with a unit-suite runner: static run() returns {name, passed, failed, details}.

const MipRes := preload("res://addons/wuifwoud/species/forest_alpha_mips.gd")


static func _chk(r: Dictionary, n: String, ok: bool) -> void:
	if ok:
		r.passed += 1
	else:
		r.failed += 1
		r.details.append("✗ " + n)


static func run() -> Dictionary:
	var r := {"name": "forest_alpha_mips", "passed": 0, "failed": 0, "details": []}
	var cut := 0.35
	# Two tiles side by side: a crown of scattered leaf clumps (dense) and thin wandering branches (sparse). A coarse
	# mip of a sparse tile is a few texels, so its coverage can only be approached (Castaño: a discrete problem).
	var img := Image.create_empty(256, 128, false, Image.FORMAT_RGBA8)
	img.fill(Color(0, 0, 0, 0))
	var rng := RandomNumberGenerator.new()
	rng.seed = 5
	for i in 260:                       # leaf clumps scattered over a crown
		var c := Vector2(rng.randf_range(20, 108), rng.randf_range(20, 108))
		var rad := rng.randf_range(1.0, 3.5)
		for y in range(int(c.y - rad), int(c.y + rad) + 1):
			for x in range(int(c.x - rad), int(c.x + rad) + 1):
				if Vector2(x, y).distance_to(c) <= rad:
					img.set_pixel(x, y, Color(0.2, 0.4, 0.1, 1.0))
	for k in 9:                         # thin wandering branches
		var y0 := rng.randf_range(10, 118)
		for x in range(132, 252):
			img.set_pixel(x, clampi(int(y0 + sin(x * 0.11 + k) * 6.0), 0, 127), Color(0.3, 0.25, 0.2, 1.0))
	img.premultiply_alpha()
	img.generate_mipmaps()
	# The tiles are side by side, not a square grid: crop each tile into its own image for the per-tile check.
	var tiles := []
	for tx in 2:
		var t := img.get_region(Rect2i(tx * 128, 0, 128, 128))
		t.generate_mipmaps()
		tiles.append(t)
	for i in 2:
		var src: Image = tiles[i]
		var out := MipRes.preserve(src, cut, 1, true)
		var c0 := MipRes.coverage(src, 0, cut)
		var worst_plain := 0.0
		var worst := 0.0
		for m in range(1, 5):
			worst_plain = maxf(worst_plain, absf(MipRes.coverage(src, m, cut) - c0))
			worst = maxf(worst, absf(MipRes.coverage(out, m, cut) - c0))
		var kind: String = ["dense crown", "thin branches"][i]
		_chk(r, "%s: plain mips drift from the base coverage %.2f by up to %.2f; preserved by at most %.2f"
			% [kind, c0, worst_plain, worst], worst < worst_plain * 0.75 and worst < 0.06)
		_chk(r, "%s: the base level is untouched" % kind, out.get_region(Rect2i(0, 0, 128, 128)).get_data()
			== src.get_region(Rect2i(0, 0, 128, 128)).get_data())
	# Colour kept on a premultiplied sheet: colour / alpha of a scaled texel is what it was.
	var src2: Image = tiles[0]
	var out2 := MipRes.preserve(src2, cut, 1, true)
	var off: int = src2.get_mipmap_offset(2)
	var a := src2.get_data()
	var b := out2.get_data()
	var drift := 0.0
	for i in range(off, off + 32 * 32 * 4, 4):
		if a[i + 3] > 40 and b[i + 3] > a[i + 3]:
			drift = maxf(drift, absf(float(a[i + 1]) / a[i + 3] - float(b[i + 1]) / b[i + 3]))
	_chk(r, "a premultiplied sheet keeps its colour as its alpha rises (worst %.3f)" % drift, drift < 0.03)
	# Tiled: the same result per tile as on each tile alone.
	var grid := Image.create_empty(256, 256, false, Image.FORMAT_RGBA8)
	grid.fill(Color(0, 0, 0, 0))
	grid.blit_rect(img.get_region(Rect2i(0, 0, 256, 128)), Rect2i(0, 0, 256, 128), Vector2i(0, 0))
	grid.generate_mipmaps()
	var gout := MipRes.preserve(grid, cut, 2, true)
	_chk(r, "on a tile grid each tile keeps its own base coverage (%.2f, %.2f at mip 3)"
		% [MipRes.coverage(gout, 3, cut, 2, 0, 0), MipRes.coverage(gout, 3, cut, 2, 1, 0)],
		absf(MipRes.coverage(gout, 3, cut, 2, 0, 0) - MipRes.coverage(grid, 0, cut, 2, 0, 0)) < 0.06
		and absf(MipRes.coverage(gout, 3, cut, 2, 1, 0) - MipRes.coverage(grid, 0, cut, 2, 1, 0)) < 0.06
		and MipRes.coverage(gout, 3, cut, 2, 0, 1) == 0.0)
	# Not square (a leaf sheet twice as wide as tall, as a pack's sakura has): every level measured on its own height.
	var wide := Image.create_empty(256, 128, false, Image.FORMAT_RGBA8)
	wide.fill(Color(0, 0, 0, 0))
	wide.blit_rect(tiles[0], Rect2i(0, 0, 128, 128), Vector2i(0, 0))
	wide.blit_rect(tiles[1], Rect2i(0, 0, 128, 128), Vector2i(128, 0))
	wide.generate_mipmaps()
	var wout := MipRes.preserve(wide, cut)
	var tall := Image.create_empty(128, 256, false, Image.FORMAT_RGBA8)
	tall.fill(Color(0, 0, 0, 0))
	tall.blit_rect(tiles[0], Rect2i(0, 0, 128, 128), Vector2i(0, 0))
	tall.generate_mipmaps()
	var tout := MipRes.preserve(tall, cut)
	_chk(r, "a sheet wider or taller than it is high or wide is preserved too (%.3f / %.3f at mip 2, base %.3f / %.3f)"
		% [MipRes.coverage(wout, 2, cut) if wout else -1.0, MipRes.coverage(tout, 2, cut) if tout else -1.0,
		MipRes.coverage(wide, 0, cut), MipRes.coverage(tall, 0, cut)],
		wout != null and tout != null and absf(MipRes.coverage(wout, 2, cut) - MipRes.coverage(wide, 0, cut)) < 0.06
		and absf(MipRes.coverage(tout, 2, cut) - MipRes.coverage(tall, 0, cut)) < 0.06)
	_chk(r, "not RGBA8 with mips: null", MipRes.preserve(Image.create_empty(8, 8, false, Image.FORMAT_RGBA8), cut) == null)
	return r
