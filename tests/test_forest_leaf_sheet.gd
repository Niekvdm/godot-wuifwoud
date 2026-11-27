# Copyright (c) 2026 Digitzone
# SPDX-License-Identifier: MIT
extends RefCounted
## The filled leaf sheet (ForestLeafSheet). A leaf texture's clear texels carry whatever colour the artist left there
## (the starter's broadleaf sheet: half the leaves' brightness over three quarters of it), and mips average colour
## without weighting by alpha, so a mesh crown darkened with distance (CommonTree_3: 57 % by 160 m) while its card,
## baked near mip 0, did not. fill() gives every clear texel the colour of the leaves around it and leaves the rest:
## the alpha and every texel with coverage are exactly the source's, and a coarse mip's colour is the leaves'.
##
## Run with a unit-suite runner: static run() returns {name, passed, failed, details}.

const LeafRes := preload("res://addons/wuifwoud/species/forest_leaf_sheet.gd")
const BuildRes := preload("res://addons/wuifwoud/species/forest_pack_build.gd")
const VA := preload("res://addons/wuifwoud/forest_assets.gd")
const TreeFix := preload("res://addons/wuifwoud/tests/fixtures/tree_fixture.gd")
const ROOT := "user://wf_leaf_sheet"


static func _chk(r: Dictionary, n: String, ok: bool) -> void:
	if ok:
		r.passed += 1
	else:
		r.failed += 1
		r.details.append("✗ " + n)


## The mean colour of a mip's texels (its own colour channels, unweighted, as a sampler averages them).
static func _mean(img: Image, m: int) -> Color:
	var off: int = img.get_mipmap_offset(m)
	var w: int = maxi(img.get_width() >> m, 1)
	var h: int = maxi(img.get_height() >> m, 1)
	var d := img.get_data()
	var s := Vector3.ZERO
	for i in w * h:
		s += Vector3(d[off + i * 4], d[off + i * 4 + 1], d[off + i * 4 + 2])
	s /= float(w * h) * 255.0
	return Color(s.x, s.y, s.z)


static func run() -> Dictionary:
	var r := {"name": "forest_leaf_sheet", "passed": 0, "failed": 0, "details": []}
	# A sheet of green leaves (a quarter of it) on clear texels that hold a dark colour, as the starter's does.
	var leaf := Color(0.35, 0.47, 0.05, 1.0)
	var src := Image.create_empty(256, 256, false, Image.FORMAT_RGBA8)
	src.fill(Color(0.18, 0.25, 0.0, 0.0))
	for i in 16:
		src.fill_rect(Rect2i((i % 4) * 64 + 8, (i / 4) * 64 + 8, 32, 32), leaf)
	src.set_pixel(10, 200, Color(0.9, 0.1, 0.1, 0.5))            # one half-covered texel of another colour

	var out := LeafRes.fill(src)
	_chk(r, "fill returns the sheet at its size, mipmapped", out != null and out.get_size() == src.get_size() and out.has_mipmaps())
	if out == null:
		return r
	var same_alpha := true
	var same_covered := true
	var near := 1.0
	for y in 256:
		for x in 256:
			var a := src.get_pixel(x, y)
			var b := out.get_pixel(x, y)
			if absf(a.a - b.a) > 0.002:
				same_alpha = false
			if a.a > 0.0 and not a.is_equal_approx(b):
				same_covered = false
			if a.a == 0.0:
				near = minf(near, b.g)
	_chk(r, "the alpha is the source's, texel for texel", same_alpha)
	_chk(r, "a texel with any coverage keeps its colour exactly", same_covered)
	_chk(r, "every clear texel takes the leaves' colour (its green at least %.2f of their 0.47)" % near, near > 0.40)
	var half := out.get_pixel(10, 200)
	_chk(r, "a part-covered texel keeps its colour (%s)" % half, absf(half.r - 0.9) < 0.01 and absf(half.a - 0.5) < 0.01)

	# The point of it: a coarse mip's colour is the leaves', where the source's sinks toward its clear texels' dark.
	var plain := src.duplicate() as Image
	plain.generate_mipmaps()
	var m := 4
	var was := _mean(plain, m)
	var now := _mean(out, m)
	_chk(r, "mip %d: the source's colour sinks (green %.3f), the filled sheet's holds the leaves' (%.3f)" % [m, was.g, now.g],
		was.g < 0.33 and absf(now.g - leaf.g) < 0.03)

	# With a cut, the mips keep the base coverage at it (ForestAlphaMips): the mesh's mip boost is off for the sheet.
	const MipRes := preload("res://addons/wuifwoud/species/forest_alpha_mips.gd")
	var kept := LeafRes.fill(src, 0.5)
	var c0 := MipRes.coverage(kept, 0, 0.5)
	_chk(r, "with a cut its mips keep the base coverage (%.3f; mip 3 %.3f, plain %.3f)" % [c0, MipRes.coverage(kept, 3, 0.5),
		MipRes.coverage(out, 3, 0.5)], absf(MipRes.coverage(kept, 3, 0.5) - c0) <= absf(MipRes.coverage(out, 3, 0.5) - c0)
		and absf(MipRes.coverage(kept, 3, 0.5) - c0) < 0.05)
	_chk(r, "no sheet, nothing", LeafRes.fill(null) == null)
	var blank := Image.create_empty(16, 16, false, Image.FORMAT_RGBA8)
	_chk(r, "a sheet with no coverage at all comes back as it was (mipmapped)",
		LeafRes.fill(blank) != null and LeafRes.fill(blank).get_pixel(3, 3) == Color(0, 0, 0, 0))

	var stored := LeafRes.store(out)
	_chk(r, "store keeps the mips and compresses (BC7)", stored != null and stored.has_mipmaps()
		and stored.get_format() == Image.FORMAT_BPTC_RGBA)
	_chk(r, "a sheet's file is named after its source path and cut, stable",
		LeafRes.file_for("user://a/Leaves.png", 0.5) == LeafRes.file_for("user://a/Leaves.png", 0.5)
		and LeafRes.file_for("user://a/Leaves.png", 0.5) != LeafRes.file_for("user://b/Leaves.png", 0.5)
		and LeafRes.file_for("user://a/Leaves.png", 0.5) != LeafRes.file_for("user://a/Leaves.png", 0.4)
		and LeafRes.file_for("user://a/Leaves.png", 0.5).begins_with("leaf_") and LeafRes.file_for("user://a/Leaves.png", 0.5).ends_with(".res"))

	# ── the pack build: made once a build per source sheet, staged, landed by the first species, shared, pruned ──
	TreeFix.rm_tree(ROOT)
	var built := ROOT.path_join("built")
	DirAccess.make_dir_recursive_absolute(ProjectSettings.globalize_path(built.path_join(BuildRes.STAGING)))
	var tex_path := ROOT.path_join("leaves.res")
	ResourceSaver.save(ImageTexture.create_from_image(src), tex_path)
	var a := TreeFix.species("W_A", ROOT + "/m/none.tscn")
	var b := TreeFix.species("W_B", ROOT + "/m/none.tscn")
	a.foliage_albedo = tex_path
	b.foliage_albedo = tex_path
	var j := BuildRes.new([], {"bake": false})
	j._out = {"built": [], "skipped": [], "failed": {}, "warnings": {}, "removed": [], "cancelled": false}
	var ra := {"id": "W_A", "dir": built, "warnings": PackedStringArray(), "inputs": {}, "pack": "", "sources": {}}
	var rb := {"id": "W_B", "dir": built, "warnings": PackedStringArray(), "inputs": {}, "pack": "", "sources": {}}
	var ta := j._leaf_sheet(a, built, ra)
	var tb := j._leaf_sheet(b, built, rb)
	var f := LeafRes.file_for(tex_path, float(a.alpha_cut))
	var staged := ProjectSettings.globalize_path(built.path_join(BuildRes.STAGING).path_join(f))
	_chk(r, "a species' leaf sheet is filled and staged under its source's name, the texture the bake dresses with",
		ta is Texture2D and String(ra.get("leaf", "")) == f and FileAccess.file_exists(staged))
	_chk(r, "a second species on the same sheet shares it (made once)", is_same(ta, tb) and String(rb.get("leaf", "")) == f)
	var none := TreeFix.species("W_C", ROOT + "/m/none.tscn")
	var rc := {"id": "W_C", "dir": built, "warnings": PackedStringArray()}
	_chk(r, "a species with no foliage sheet has none", j._leaf_sheet(none, built, rc) == null and not rc.has("leaf"))
	j._land(ra, {})
	j._land(rb, {})
	var man: Dictionary = BuildRes.read_manifest(built)
	var dst := ProjectSettings.globalize_path(built.path_join(f))
	_chk(r, "the first to land moves it in, both entries name it, and the forest loads it",
		FileAccess.file_exists(dst) and String(man["species"]["W_A"].get("leaf", "")) == f
		and String(man["species"]["W_B"].get("leaf", "")) == f and VA.leaf_at(built, "W_B", man, true) is Texture2D)
	var stray := ProjectSettings.globalize_path(built.path_join(LeafRes.file_for("user://gone.png", 0.5)))
	ResourceSaver.save(Image.create_empty(4, 4, false, Image.FORMAT_RGBA8), stray)
	BuildRes.prune_leaves(built, man)
	_chk(r, "a sheet no species names is pruned; a named one stays", not FileAccess.file_exists(stray) and FileAccess.file_exists(dst))
	(man["species"]["W_A"] as Dictionary).erase("leaf")
	(man["species"]["W_B"] as Dictionary).erase("leaf")
	BuildRes.prune_leaves(built, man)
	_chk(r, "and goes once none does", not FileAccess.file_exists(dst))
	TreeFix.rm_tree(ROOT)
	return r
