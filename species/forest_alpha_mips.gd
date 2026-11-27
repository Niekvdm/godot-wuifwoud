# Copyright (c) 2026 Digitzone
# SPDX-License-Identifier: MIT
@tool
extends RefCounted
## COVERAGE-PRESERVING ALPHA MIPS (I. Castaño, "Computing Alpha Mipmaps", 2010; Unity's `mipMapsPreserveCoverage`).
## Image work only: a worker may run it.
##
## A mip averages alpha, so the share of texels that pass an alpha cut drifts with the level: a dense crown thins out
## (most texels fall under the cut), a sparse one (thin branches) can do either. The card and the leaf shaders used to
## patch this at runtime with one global boost, `alpha *= 1 + lod * 0.25` (Golus' anti-aliased alpha test), which
## measured wrong both ways on the starter pack: a dead tree's card covered 1.2-1.3x its mesh at 160 m and 2.4-2.7x at
## 300 m, while mesh crowns lost coverage there. This scales each mip's alpha instead (per tile: an impostor sheet's
## views are separate images) so that at each level the share of texels at or over `cut` is the base level's, and the
## shaders' boost goes to 0 for a sheet made so.
##
## The scale is found from each tile's alpha histogram: the byte value t at which the level keeps exactly the base share
## of texels, then s = cut / t. Premultiplied sheets scale their colour with their alpha (the colour, colour / alpha,
## does not change); straight ones keep their colour. Alpha saturates at 1.

## `img` (RGBA8, mipmapped; the base level untouched) with each mip's alpha scaled to the base level's coverage at
## `cut`, tile by tile on a `tiles` × `tiles` grid (1: the whole image). A level whose tiles are under a texel is left as
## it is. Returns a new image; null when `img` is not RGBA8 with mips.
static func preserve(img: Image, cut: float, tiles := 1, premultiplied := false) -> Image:
	if img == null or img.get_format() != Image.FORMAT_RGBA8 or not img.has_mipmaps():
		return null
	var d := img.get_data()
	var w := img.get_width()
	var h := img.get_height()
	var cut8 := clampi(int(ceilf(cut * 255.0)), 1, 255)
	# A tile's size, width and height apart: a sheet need not be square (a leaf sheet twice as wide as tall).
	var tw0 := w / tiles
	var th0 := h / tiles
	# The base level's share of texels at or over the cut, a tile each.
	var base := PackedFloat32Array()
	base.resize(tiles * tiles)
	for ty in tiles:
		for tx in tiles:
			var n := 0
			for y in th0:
				var row := ((ty * th0 + y) * w + tx * tw0) * 4 + 3
				for x in tw0:
					if d[row + x * 4] >= cut8:
						n += 1
			base[ty * tiles + tx] = float(n) / float(maxi(tw0 * th0, 1))
	for m in range(1, img.get_mipmap_count() + 1):
		var mw := maxi(w >> m, 1)
		var mh := maxi(h >> m, 1)
		var tw := mw / tiles
		var th := mh / tiles
		if tw < 1 or th < 1:
			break
		var off := img.get_mipmap_offset(m)
		for ty in tiles:
			for tx in tiles:
				var target := int(roundf(base[ty * tiles + tx] * float(tw * th)))
				if target <= 0:
					continue
				# The histogram, then the byte value t whose count of texels at or over it comes CLOSEST to `target`
				# (Castaño: a discrete problem; many texels share a value at a coarse level, and the first t to reach
				# the target can overshoot it many times over). Ties keep the lower coverage.
				var hist := PackedInt32Array()
				hist.resize(256)
				for y in th:
					var row := off + ((ty * th + y) * mw + tx * tw) * 4 + 3
					for x in tw:
						hist[d[row + x * 4]] += 1
				var acc := 0
				var t := 0
				var best := target + 1
				for v in range(255, 0, -1):
					acc += hist[v]
					if absi(acc - target) < best:
						best = absi(acc - target)
						t = v
					if acc >= target:
						break
				if t <= 0:
					continue
				var s := float(cut8) / float(t)
				if absf(s - 1.0) < 0.002:
					continue
				for y in th:
					var row := off + ((ty * th + y) * mw + tx * tw) * 4
					for x in tw:
						var i := row + x * 4
						var a := d[i + 3]
						if a == 0:
							continue
						var na := mini(int(roundf(float(a) * s)), 255)
						if premultiplied:
							var k := float(na) / float(a)
							d[i] = mini(int(roundf(d[i] * k)), 255)
							d[i + 1] = mini(int(roundf(d[i + 1] * k)), 255)
							d[i + 2] = mini(int(roundf(d[i + 2] * k)), 255)
						d[i + 3] = na
	return Image.create_from_data(w, h, true, Image.FORMAT_RGBA8, d)


## The share of texels at or over `cut` in tile (tx, ty) of a `tiles` grid at mip `m` of `img` (RGBA8, mipmapped).
static func coverage(img: Image, m: int, cut: float, tiles := 1, tx := 0, ty := 0) -> float:
	var d := img.get_data()
	var mw := maxi(img.get_width() >> m, 1)
	var tw := mw / tiles
	var th := maxi(img.get_height() >> m, 1) / tiles
	var off := img.get_mipmap_offset(m)
	var cut8 := clampi(int(ceilf(cut * 255.0)), 1, 255)
	var n := 0
	for y in th:
		var row := off + ((ty * th + y) * mw + tx * tw) * 4 + 3
		for x in tw:
			if d[row + x * 4] >= cut8:
				n += 1
	return float(n) / float(maxi(tw * th, 1))
