# Copyright (c) 2026 Digitzone
# SPDX-License-Identifier: MIT
extends RefCounted
## The trimmed impostor card. The bake measures, per view and per mip set, the vertical reach of the silhouette and the
## horizontal reach of each of TRIM_BANDS bands (ForestImpostorBaker.trim_of); the measurement is CONSERVATIVE: every
## texel of a mip the set covers that can pass the card's cut lies inside its band's reach. ring_at reads the trim sheet,
## and card_of builds the band strip and hands the shader the sheet and its layout; a ring without one keeps the quad.
##
## Run with a unit-suite runner: static run() returns {name, passed, failed, details}.

const VA := preload("res://addons/wuifwoud/forest_assets.gd")
const BakerRes := preload("res://addons/wuifwoud/species/forest_impostor_baker.gd")
const BuildRes := preload("res://addons/wuifwoud/species/forest_pack_build.gd")
const TreeFix := preload("res://addons/wuifwoud/tests/fixtures/tree_fixture.gd")
const ROOT := "user://wf_card_trim"


static func _chk(r: Dictionary, n: String, ok: bool) -> void:
	if ok:
		r.passed += 1
	else:
		r.failed += 1
		r.details.append("✗ " + n)


## The trim sheet's entry (column `c`, set `s`, view `v`) as (lo, hi) in tile units; lo > hi: empty.
static func _at(trim: Image, c: int, s: int, v: int) -> Vector2:
	var px := trim.get_pixel(c, s * BakerRes.GRID * BakerRes.GRID + v)
	return Vector2(px.r, px.g)


## Every texel of mip `m` (of the decompressed `img`) the card's cut can keep lies inside its view's vertical reach
## and its band's horizontal reach in set `s`. Returns the first texel that does not, or "".
static func _escapes(img: Image, trim: Image, m: int, s: int) -> String:
	var g := BakerRes.GRID
	var k := BakerRes.TRIM_BANDS
	var t := (img.get_width() / g) >> m
	var mw := img.get_width() >> m
	var off := img.get_mipmap_offset(m)
	var data := img.get_data()
	var thr := BakerRes.trim_threshold(m)
	for v in g * g:
		var ox := (v % g) * t
		var oy := (v / g) * t
		for ty in t:
			for tx in t:
				if float(data[off + ((oy + ty) * mw + ox + tx) * 4 + 3]) / 255.0 < thr:
					continue
				var cx := (float(tx) + 0.5) / t
				var cy := 1.0 - (float(ty) + 0.5) / t
				var yr := _at(trim, 0, s, v)
				if cy < yr.x or cy > yr.y:
					return "mip %d view %d texel (%d, %d) above or below %s" % [m, v, tx, ty, yr]
				var band := clampi(int(cy * k), 0, k - 1)
				var xr := _at(trim, 1 + band, s, v)
				if cx < xr.x or cx > xr.y:
					return "mip %d view %d texel (%d, %d) beside band %d %s" % [m, v, tx, ty, band, xr]
	return ""


static func run() -> Dictionary:
	var r := {"name": "forest_card_trim", "passed": 0, "failed": 0, "details": []}
	var g := BakerRes.GRID
	var tile := BakerRes.OUT_TILE
	var k := BakerRes.TRIM_BANDS
	var sets := BakerRes.TRIM_SETS

	# ── a sheet: view 0 a box, view 9 one texel, view 20 a blob of fading alpha, the rest empty ──
	var atlas := Image.create_empty(g * tile, g * tile, false, Image.FORMAT_RGBA8)
	atlas.fill(Color(0, 0, 0, 0))
	atlas.fill_rect(Rect2i(40, 20, 48, 80), Color(0.2, 0.5, 0.1, 1.0))              # view 0: x 40..88, rows 20..100
	atlas.set_pixel(tile + 64, tile + 64, Color(0.2, 0.5, 0.1, 1.0))                  # view 9 (col 1, row 1)
	var o20 := Vector2i((20 % g) * tile, (20 / g) * tile)
	for y in tile:
		for x in tile:
			var d := Vector2(x - 64, y - 50).length()
			if d < 40.0:
				atlas.set_pixel(o20.x + x, o20.y + y, Color(0.3, 0.4, 0.1, 1.0 if d < 20.0 else 0.6 if d < 30.0 else 0.3))
	var stored := BakerRes.store_image(atlas)
	_chk(r, "the sheet stores (BC7)", stored != null)
	if stored == null:
		return r
	var trim := BakerRes.trim_of(stored)
	_chk(r, "trim_of measures a stored sheet", trim != null)
	if trim == null:
		return r
	_chk(r, "the trim sheet: a column a band and one for the view's reach, a row a view and a set (%s)" % str(trim.get_size()),
		trim.get_width() == k + 1 and trim.get_height() == sets * g * g and not trim.has_mipmaps())

	# ── the box (view 0): its reach, near-tight at set 0, and every set at least as wide as the one before ──
	var by := Vector2(1.0 - 100.0 / tile, 1.0 - 20.0 / tile)
	var bx := Vector2(40.0 / tile, 88.0 / tile)
	var y0 := _at(trim, 0, 0, 0)
	_chk(r, "the box's vertical reach holds it and stays near it at set 0 (%s for %s)" % [y0, by],
		y0.x <= by.x and y0.y >= by.y and y0.x >= by.x - 0.1 and y0.y <= by.y + 0.1)
	var mid := int(0.5 * k)                    # band 4: y 0.5..0.625, inside the box
	var x0 := _at(trim, 1 + mid, 0, 0)
	_chk(r, "a band through the box spans it and not much more (%s for %s)" % [x0, bx],
		x0.x <= bx.x and x0.y >= bx.y and x0.x >= bx.x - 0.1 and x0.y <= bx.y + 0.1)
	var top := _at(trim, k, 0, 0)              # band 7: y 0.875..1, above the box (top at 0.84) past every dilation at set 0
	_chk(r, "a band clear of the box is empty at set 0 (%s)" % top, top.x > top.y)
	var widening := true
	for s in range(1, sets):
		var a := _at(trim, 0, s - 1, 0)
		var b := _at(trim, 0, s, 0)
		var xa := _at(trim, 1 + mid, s - 1, 0)
		var xb := _at(trim, 1 + mid, s, 0)
		if b.x > a.x or b.y < a.y or xb.x > xa.x or xb.y < xa.y:
			widening = false
	_chk(r, "each set reaches at least as far as the finer one before it", widening)

	# ── one texel (view 9), an empty view (view 5) ──
	var y9 := _at(trim, 0, 0, 9)
	_chk(r, "a single texel still has a reach (%s)" % y9, y9.x <= 1.0 - 64.5 / tile and y9.y >= 1.0 - 64.5 / tile)
	var empty := true
	for s in sets:
		for c in k + 1:
			var e := _at(trim, c, s, 5)
			if e.x <= e.y:
				empty = false
	_chk(r, "an empty view is empty in every column and set", empty)

	# ── conservative: no texel the cut can keep, in any mip a set covers, falls outside its reach ──
	var dec := stored.duplicate() as Image
	dec.decompress()
	if dec.get_format() != Image.FORMAT_RGBA8:
		dec.convert(Image.FORMAT_RGBA8)
	var miss := ""
	for s in sets:
		for m in BakerRes.TRIM_MIP_SPAN + s:
			if miss == "":
				miss = _escapes(dec, trim, m, s)
	_chk(r, "every texel the cut keeps lies inside its band's reach, every set, every mip it covers %s" % miss, miss == "")

	# ── ring_at reads the trim sheet; card_of builds the strip ──
	TreeFix.rm_tree(ROOT)
	DirAccess.make_dir_recursive_absolute(ProjectSettings.globalize_path(ROOT))
	var sheet := Image.create_empty(16, 16, false, Image.FORMAT_RGBA8)
	sheet.resource_scene_unique_id = "sheet"
	ResourceSaver.save(sheet, ROOT.path_join("W_T_albedo.res"))
	ResourceSaver.save(sheet, ROOT.path_join("W_T_normal.res"))
	var man := {"bake": BakerRes.settings(), "species": {"W_T": {"span": 12.5, "w": 6.0, "h": 12.0}}}
	var plain := VA.ring_at(ROOT, "W_T", man)
	_chk(r, "a ring without a trim sheet has no trim", not plain.is_empty() and not plain.has("trim"))
	trim.resource_scene_unique_id = "trim"
	ResourceSaver.save(trim, ROOT.path_join("W_T_trim.res"))
	var ring := VA.ring_at(ROOT, "W_T", man)
	_chk(r, "ring_at reads the trim sheet and its layout",
		ring.get("trim") is Texture2D and int(ring.get("trim_bands", 0)) == k and int(ring.get("trim_sets", 0)) == sets
		and int(ring.get("tile", 0)) == tile)
	var old := man.duplicate(true)
	(old["bake"] as Dictionary).erase("trim_bands")
	_chk(r, "a bake that predates trimming reads no trim, whatever the folder holds",
		not VA.ring_at(ROOT, "W_T", old).has("trim"))

	var p := {"aabb": AABB(Vector3(-3, 0, -3), Vector3(6, 12, 6))}
	var card := VA.card_of("W_T", null, p, ring, 0)
	var mesh := card["mesh"] as ArrayMesh
	var mat := card["mat"] as ShaderMaterial
	_chk(r, "card_of on a trimmed ring builds the band strip", mesh != null and mesh.get_surface_count() == 1)
	if mesh != null:
		var arr := mesh.surface_get_arrays(0)
		var verts: PackedVector3Array = arr[Mesh.ARRAY_VERTEX]
		var uvs: PackedVector2Array = arr[Mesh.ARRAY_TEX_UV]
		var idx: PackedInt32Array = arr[Mesh.ARRAY_INDEX]
		_chk(r, "two vertices a row, two triangles a band (%d, %d)" % [verts.size(), idx.size()],
			verts.size() == 2 * (k + 1) and idx.size() == 6 * k)
		# Untrimmed it is the plain quad: the bake's square, corners where the QuadMesh has them, UV v top→bottom.
		var square := true
		for i in verts.size():
			var want := Vector2((uvs[i].x - 0.5) * 12.5, (0.5 - uvs[i].y) * 12.5)
			if not Vector2(verts[i].x, verts[i].y).is_equal_approx(want):
				square = false
		_chk(r, "untrimmed, the strip is the bake's square", square
			and Vector2(mesh.get_aabb().size.x, mesh.get_aabb().size.y).is_equal_approx(Vector2(12.5, 12.5)))
	_chk(r, "the card tells the shader the sheet, its layout and the square",
		mat.get_shader_parameter("impostor_trim") == ring["trim"] and int(mat.get_shader_parameter("trim_bands")) == k
		and int(mat.get_shader_parameter("trim_sets")) == sets and is_equal_approx(float(mat.get_shader_parameter("card_span")), 12.5)
		and is_equal_approx(float(mat.get_shader_parameter("trim_tile")), float(tile)))
	_chk(r, "and the card says its size", card.get("size") == Vector2(12.5, 12.5))
	var quad := VA.card_of("W_T", null, p, plain, 0)
	_chk(r, "a ring without trim keeps the quad and leaves trimming off",
		quad["mesh"] is QuadMesh and (quad["mat"] as ShaderMaterial).get_shader_parameter("trim_bands") in [null, 0]
		and quad.get("size") == Vector2(12.5, 12.5))

	# ── the pack build: the store worker measures the trim, the landing saves it with the sheets ──
	var built := ROOT.path_join("built")
	DirAccess.make_dir_recursive_absolute(ProjectSettings.globalize_path(built.path_join(BuildRes.STAGING)))
	var j := BuildRes.new([], {"bake": false})
	j._out = {"built": [], "skipped": [], "failed": {}, "warnings": {}, "removed": [], "cancelled": false}
	j._baked = true
	var res := {"albedo": atlas, "normal": atlas, "span": 12.5, "w": 6.0, "h": 12.0, "opaque": 10}
	var out := {}
	j._store(res, out)
	_chk(r, "the store worker measures the trim on the stored albedo",
		out.get("trim") is Image and (out["trim"] as Image).get_data() == BakerRes.trim_of(out["albedo"]).get_data())
	var land := {"id": "W_T", "dir": built, "warnings": [], "inputs": {}, "pack": "", "sources": {}}
	j._land(land, out)
	var bman: Dictionary = BuildRes.read_manifest(built)
	var landed := VA.ring_at(built, "W_T", bman)
	_chk(r, "it lands beside the sheets, and the manifest's bake names the layout (%s)" % str(bman.get("bake", {})),
		FileAccess.file_exists(ProjectSettings.globalize_path(built.path_join("W_T_trim.res")))
		and int((bman.get("bake", {}) as Dictionary).get("trim_bands", 0)) == k and landed.get("trim") is Texture2D)
	var untrimmed := out.duplicate()
	untrimmed.erase("trim")
	j._land(land, untrimmed)
	_chk(r, "new sheets without a trim take the old trim away with them",
		not FileAccess.file_exists(ProjectSettings.globalize_path(built.path_join("W_T_trim.res"))))
	TreeFix.rm_tree(ROOT)
	return r
