# Copyright (c) 2026 Digitzone
# SPDX-License-Identifier: MIT
extends RefCounted
## The impostor's depth sheet. The bake's third channel stores how far each texel stands in front of its frame's centre
## plane; store_image keeps it as BC5 (depth × coverage, coverage); depth_reach_of reads each view's largest |depth|,
## which trim_of records for the card's margin. The pack build stores, lands and drops it with the sheets; ring_at reads
## it only from a bake that names its range, and card_of hands it to the shader.
##
## Run with a unit-suite runner: static run() returns {name, passed, failed, details}.

const VA := preload("res://addons/wuifwoud/forest_assets.gd")
const BakerRes := preload("res://addons/wuifwoud/species/forest_impostor_baker.gd")
const BuildRes := preload("res://addons/wuifwoud/species/forest_pack_build.gd")
const TreeFix := preload("res://addons/wuifwoud/tests/fixtures/tree_fixture.gd")
const ROOT := "user://wf_card_depth"


static func _chk(r: Dictionary, n: String, ok: bool) -> void:
	if ok:
		r.passed += 1
	else:
		r.failed += 1
		r.details.append("✗ " + n)


## A depth render as the bake writes it: (depth / range + 0.5, 1) where covered, clear elsewhere.
static func _depth_render(g: int, tile: int, views: Dictionary) -> Image:
	var img := Image.create_empty(g * tile, g * tile, false, Image.FORMAT_RGBA8)
	img.fill(Color(0, 0, 0, 0))
	for v in views:
		var z: float = views[v]
		img.fill_rect(Rect2i((v % g) * tile + 40, (v / g) * tile + 20, 48, 80),
			Color(z / BakerRes.DEPTH_RANGE + 0.5, 1.0, 0.0, 1.0))
	return img


static func run() -> Dictionary:
	var r := {"name": "forest_card_depth", "passed": 0, "failed": 0, "details": []}
	var g := BakerRes.GRID
	var tile := BakerRes.OUT_TILE

	_chk(r, "the bake renders three channels and its settings name the depth range",
		BakerRes.CHANNELS == 3 and is_equal_approx(float(BakerRes.settings().get("depth_range", 0.0)), BakerRes.DEPTH_RANGE))

	# ── the stored sheet: BC5, mipmapped ──
	var render := _depth_render(g, tile, {0: 0.3, 3: -0.45})
	var dep := BakerRes.store_image(render, true)
	_chk(r, "the depth sheet stores as BC5 with its mips (%s)" % (str(dep.get_format()) if dep != null else "null"),
		dep != null and dep.get_format() == Image.FORMAT_RGTC_RG and dep.has_mipmaps()
		and dep.get_width() == g * tile)
	if dep == null:
		return r

	# ── each view's depth reach ──
	var reach := BakerRes.depth_reach_of(dep)
	_chk(r, "a view's reach is its largest |depth| (%.3f, %.3f, %.3f)" % [reach[0], reach[3], reach[5]],
		reach.size() == g * g and absf(reach[0] - 0.3) < 0.02 and absf(reach[3] - 0.45) < 0.02 and reach[5] == 0.0)
	_chk(r, "no sheet, no reach", BakerRes.depth_reach_of(null).is_empty())

	# ── the trim records it, rounded up ──
	var alb := Image.create_empty(g * tile, g * tile, false, Image.FORMAT_RGBA8)
	alb.fill(Color(0, 0, 0, 0))
	for v in [0, 3]:
		alb.fill_rect(Rect2i((v % g) * tile + 40, (v / g) * tile + 20, 48, 80), Color(0.2, 0.5, 0.1, 1.0))
	var stored := BakerRes.store_image(alb)
	var trim := BakerRes.trim_of(stored, dep)
	var half := BakerRes.DEPTH_RANGE * 0.5
	_chk(r, "the trim is RGBA8 and holds each view's depth reach, never below it",
		trim != null and trim.get_format() == Image.FORMAT_RGBA8
		and trim.get_pixel(0, 0).b * half >= reach[0] and trim.get_pixel(0, 0).b * half <= reach[0] + 0.01
		and trim.get_pixel(0, 3).b * half >= reach[3] and trim.get_pixel(0, 5).b == 0.0)
	var flat := BakerRes.trim_of(stored)
	_chk(r, "without a depth sheet the reach is 0, the reaches the same",
		flat.get_pixel(0, 0).b == 0.0 and flat.get_pixel(1 + 4, 0).r == trim.get_pixel(1 + 4, 0).r
		and flat.get_pixel(1 + 4, 0).g == trim.get_pixel(1 + 4, 0).g)

	# ── ring_at and card_of ──
	TreeFix.rm_tree(ROOT)
	var built := ROOT.path_join("built")
	DirAccess.make_dir_recursive_absolute(ProjectSettings.globalize_path(built.path_join(BuildRes.STAGING)))
	var j := BuildRes.new([], {"bake": false})
	j._out = {"built": [], "skipped": [], "failed": {}, "warnings": {}, "removed": [], "cancelled": false}
	j._baked = true
	var out := {}
	j._store({"albedo": alb, "normal": alb, "depth": render, "span": 12.5, "w": 6.0, "h": 12.0, "opaque": 10}, out)
	_chk(r, "the store worker keeps the depth sheet and measures the trim with it",
		out.get("depth") is Image and (out["depth"] as Image).get_format() == Image.FORMAT_RGTC_RG
		and out.get("trim") is Image and (out["trim"] as Image).get_pixel(0, 0).b > 0.0)
	var land := {"id": "W_T", "dir": built, "warnings": [], "inputs": {}, "pack": "", "sources": {}}
	j._land(land, out)
	var man: Dictionary = BuildRes.read_manifest(built)
	var ring := VA.ring_at(built, "W_T", man)
	_chk(r, "it lands beside the sheets and ring_at reads it with its range",
		FileAccess.file_exists(ProjectSettings.globalize_path(built.path_join("W_T_depth.res")))
		and ring.get("depth") is Texture2D and is_equal_approx(float(ring.get("depth_range", 0.0)), BakerRes.DEPTH_RANGE))
	var old := man.duplicate(true)
	(old["bake"] as Dictionary).erase("depth_range")
	_chk(r, "a bake that predates the depth sheet reads none", not VA.ring_at(built, "W_T", old).has("depth"))

	var p := {"aabb": AABB(Vector3(-3, 0, -3), Vector3(6, 12, 6))}
	var card := VA.card_of("W_T", null, p, ring, 0)
	var mat := card["mat"] as ShaderMaterial
	_chk(r, "card_of hands the shader the depth sheet and its range",
		mat.get_shader_parameter("impostor_depth") == ring["depth"]
		and is_equal_approx(float(mat.get_shader_parameter("depth_range")), BakerRes.DEPTH_RANGE))
	_chk(r, "a bake whose mips keep coverage turns the card's mip boost off",
		bool(ring.get("coverage_mips", false)) and float(mat.get_shader_parameter("alpha_mip_scale")) == 0.0)
	var shallow := ring.duplicate()
	shallow.erase("depth")
	var plain := VA.card_of("W_T", null, p, shallow, 0).get("mat") as ShaderMaterial
	_chk(r, "without one the range stays 0 (no shift)", plain.get_shader_parameter("depth_range") in [null, 0.0])

	var nodepth := out.duplicate()
	nodepth.erase("depth")
	j._land(land, nodepth)
	_chk(r, "new sheets without a depth sheet take the old one away",
		not FileAccess.file_exists(ProjectSettings.globalize_path(built.path_join("W_T_depth.res"))))
	TreeFix.rm_tree(ROOT)
	return r
