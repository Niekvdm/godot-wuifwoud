# Copyright (c) 2026 Digitzone
# SPDX-License-Identifier: MIT
@tool
extends RefCounted
## THE FILLED LEAF SHEET: a species' foliage texture as the mesh trees sample it, its clear texels given the colour of
## the leaves around them. Image work only: a worker may run it.
##
## WHY. A leaf texture's clear texels hold whatever colour the artist left there (the starter's broadleaf sheet: half the
## leaves' brightness, over three quarters of the sheet; its pine sheet: near white), and a texture's mips average
## colour WITHOUT weighting it by alpha. Past a few metres a crown samples coarse mips, so its colour sinks toward the
## clear texels' (and a coarse mip's alpha lets through pixels whose own texel is clear, which draw that colour
## outright). Measured on the starter's CommonTree_3: the mesh crown's green fell from 0.106 at 20 m to 0.046 at 160 m
## while its impostor card, baked from the full-size sheet, held 0.104, so every tree brightened as it handed over.
## `fix_alpha_border` on import bleeds the colour a few texels only. With this sheet the crown held 0.111-0.113 from
## 20 m to 160 m and met its card within 7 %.
##
## HOW. Push-pull: an alpha-weighted pyramid (premultiplied halvings, each divided by its coverage), then from the
## coarsest level down each level laid over the one above it scaled up, so a clear texel takes the colour of the nearest
## leaves at whatever scale they are. Only a fully clear texel changes: one with any coverage keeps its own colour (an
## anti-aliased leaf edge is drawn with it), and the alpha is the source's, so the leaves' shape is untouched.

## A sheet's file in a pack's built/: one per source texture (species often share a sheet), named after its path and
## the sheet's version: "v2" are plain mips. The v1 sheets kept their coverage per mip (ForestAlphaMips) and made
## thin-leaved crowns VANISH with distance (the asian_flora pack's needle pines and bamboo: the mesh covered 0-39 % of a
## supersampled reference at 160-230 m, against 100-113 % with plain mips and the runtime boost), so a v1 name reads
## as stale and the species is built again.
static func file_for(source_path: String) -> String:
	return "leaf_%s.res" % ("%s|v2" % source_path).md5_text().substr(0, 12)


## The filled sheet of `src` (any format; decompressed, its mips dropped), RGBA8 with fresh, PLAIN mips; null without
## one. Coverage at distance is the mesh shader's mip boost (tree_wind `leaf_mip_scale`), as for any leaf sheet: per-mip
## coverage keeping was tried here and dropped (file_for says why).
static func fill(src: Image) -> Image:
	if src == null or src.is_empty():
		return null
	var img := src.duplicate() as Image
	if img.is_compressed() and img.decompress() != OK:
		return null
	img.clear_mipmaps()
	img.convert(Image.FORMAT_RGBA8)
	var orig := img.get_data()
	# Pull: each halving of the premultiplied sheet, divided back by its coverage (straight colour, coverage alpha).
	var levels: Array[Image] = []
	var p := img.duplicate() as Image
	p.premultiply_alpha()
	while p.get_width() > 1 or p.get_height() > 1:
		p = p.duplicate() as Image
		p.resize(maxi(p.get_width() / 2, 1), maxi(p.get_height() / 2, 1), Image.INTERPOLATE_BILINEAR)
		var d := p.get_data()
		var s := d.duplicate()
		for i in range(0, d.size(), 4):
			var a := d[i + 3]
			if a > 0:
				s[i] = mini(d[i] * 255 / a, 255)
				s[i + 1] = mini(d[i + 1] * 255 / a, 255)
				s[i + 2] = mini(d[i + 2] * 255 / a, 255)
		levels.append(Image.create_from_data(p.get_width(), p.get_height(), false, Image.FORMAT_RGBA8, s))
	if levels.is_empty() or levels[levels.size() - 1].get_pixel(0, 0).a == 0.0:
		img.generate_mipmaps()    # nothing covered anywhere: nothing to fill from
		return img
	# Push: the coarsest level made opaque, then each finer one laid over it scaled up (Image.blend_rect over an opaque
	# base: its colour × its coverage + the fill × the rest), down to the full-size sheet itself.
	var f := levels[levels.size() - 1].duplicate() as Image
	var fd := f.get_data()
	for i in range(3, fd.size(), 4):
		fd[i] = 255
	f = Image.create_from_data(f.get_width(), f.get_height(), false, Image.FORMAT_RGBA8, fd)
	for k in range(levels.size() - 2, -2, -1):
		var lvl: Image = levels[k] if k >= 0 else img
		var up := f.duplicate() as Image
		up.resize(lvl.get_width(), lvl.get_height(), Image.INTERPOLATE_BILINEAR)
		up.blend_rect(lvl, Rect2i(Vector2i.ZERO, lvl.get_size()), Vector2i.ZERO)
		f = up
	# The source back wherever it has coverage: only a clear texel takes the fill's colour.
	var out := f.get_data()
	for i in range(0, out.size(), 4):
		if orig[i + 3] > 0:
			out[i] = orig[i]
			out[i + 1] = orig[i + 1]
			out[i + 2] = orig[i + 2]
		out[i + 3] = orig[i + 3]
	var res := Image.create_from_data(img.get_width(), img.get_height(), false, Image.FORMAT_RGBA8, out)
	res.generate_mipmaps()
	return res


## `img` (fill's) as it is saved: BC7 with its mips, the bake's sheets' format. Null when the compression fails.
static func store(img: Image) -> Image:
	if img == null:
		return null
	var out := img.duplicate() as Image
	if not out.has_mipmaps():
		out.generate_mipmaps()
	if out.compress(Image.COMPRESS_BPTC, Image.COMPRESS_SOURCE_GENERIC) != OK:
		return null
	return out
