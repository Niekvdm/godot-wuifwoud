# Copyright (c) 2026 Digitzone
# SPDX-License-Identifier: MIT
extends RefCounted
## What the Species dialog's view draws: a built species' preparation, its combined mesh and levels dressed with its own
## materials (the alpha cut on the leaves only), no ring without a bake and no card for a bush; an unbuilt species
## prepared now; a missing mesh nothing. ring_at reads a bake's sheets and framing, and card_of spans that framing. The
## forest's own cards still come cached and registered. The sheet's view lookup inverts the bake's view directions.
##
## Run with a unit-suite runner: static run() returns {name, passed, failed, details}.

const VA := preload("res://addons/wuifwoud/forest_assets.gd")
const BuildRes := preload("res://addons/wuifwoud/species/forest_pack_build.gd")
const BakerRes := preload("res://addons/wuifwoud/species/forest_impostor_baker.gd")
const TreeFix := preload("res://addons/wuifwoud/tests/fixtures/tree_fixture.gd")
const ROOT := "user://wf_e1_view_parts"


static func _chk(r: Dictionary, n: String, ok: bool) -> void:
	if ok:
		r.passed += 1
	else:
		r.failed += 1
		r.details.append("✗ " + n)


static func _param(mesh: ArrayMesh, si: int, nm: String) -> Variant:
	var m := mesh.surface_get_material(si) as ShaderMaterial
	return m.get_shader_parameter(nm) if m != null else null


static func run() -> Dictionary:
	var r := {"name": "forest_view_parts", "passed": 0, "failed": 0, "details": []}
	TreeFix.rm_tree(ROOT)
	TreeFix.scene(ROOT + "/m/tree.tscn", [TreeFix.tree_mesh(8, "Bark", "Leaves"), TreeFix.tree_mesh(3, "Bark", "Leaves")],
		["Tree_LOD0", "Tree_LOD1"])
	var tree := TreeFix.species("W_Tree", ROOT + "/m/tree.tscn")
	tree.alpha_cut = 0.37
	var bush := TreeFix.species("W_Bush", ROOT + "/m/tree.tscn")
	bush.kind = "bush"
	var lost := TreeFix.species("W_Lost", ROOT + "/m/none.tscn")
	var p := ForestSpeciesPack.new()
	var sl: Array[ForestSpecies] = [tree, bush, lost]
	p.species = sl
	DirAccess.make_dir_recursive_absolute(ProjectSettings.globalize_path(ROOT + "/pack"))
	ResourceSaver.save(p, ROOT + "/pack/pack.tres")
	var pack := ResourceLoader.load(ROOT + "/pack/pack.tres", "", ResourceLoader.CACHE_MODE_REPLACE) as ForestSpeciesPack
	BuildRes.new([pack], {"only": ["W_Tree"]}).run_now()
	var dir := pack.built_dir()
	var man := BuildRes.read_manifest(dir)

	# ── a built species ──
	var v := VA.view_parts(pack.species[0], dir, man)
	var c: ArrayMesh = v.get("combined")
	_chk(r, "a built species: its built preparation, dressed (%s)" % str(v.keys()),
		bool(v.get("built", false)) and c != null and c.get_surface_count() == 2 and _param(c, 0, "albedo") != null)
	_chk(r, "the alpha cut on the leaves only (%s, %s)" % [str(_param(c, 1, "alpha_cut")), str(_param(c, 0, "alpha_cut"))],
		is_equal_approx(float(_param(c, 1, "alpha_cut")), 0.37) and is_equal_approx(float(_param(c, 0, "alpha_cut")), 0.0))
	_chk(r, "its authored levels, each with the combined mesh's materials (%d)" % (v["levels"] as Array).size(),
		(v["levels"] as Array).size() == 2
		and (v["levels"][1] as ArrayMesh).surface_get_material(1) == c.surface_get_material(1))
	_chk(r, "no bake: no ring, and a card on the procedural silhouette",
		(v["ring"] as Dictionary).is_empty() and int((v["card"]["mat"] as ShaderMaterial).get_shader_parameter("impostor_grid")) == 0)
	_chk(r, "the view's materials are not the forest's live ones", not VA._live_materials.has(c.surface_get_material(0)))

	# ── unbuilt, a bush, a missing mesh ──
	var u := VA.view_parts(pack.species[1], dir, man)
	_chk(r, "an unbuilt species is prepared now", not bool(u.get("built", true)) and u.get("combined") != null)
	_chk(r, "a bush has no card", (u.get("card", {"x": 1}) as Dictionary).is_empty())
	_chk(r, "a missing mesh: nothing", VA.view_parts(pack.species[2], dir, man).is_empty())

	# ── ring_at and card_of on a bake's framing ──
	var sheet := Image.create_empty(16, 16, false, Image.FORMAT_RGBA8)
	sheet.resource_scene_unique_id = "sheet"
	ResourceSaver.save(sheet, dir.path_join("W_Tree_albedo.res"))
	ResourceSaver.save(sheet, dir.path_join("W_Tree_normal.res"))
	var fake := man.duplicate(true)
	fake["bake"] = {"grid": 8, "cols": 8, "rows": 8}
	fake["species"]["W_Tree"]["span"] = 12.5
	fake["species"]["W_Tree"]["w"] = 6.0
	fake["species"]["W_Tree"]["h"] = 12.0
	var ring := VA.ring_at(dir, "W_Tree", fake)
	_chk(r, "ring_at reads the sheets and the framing (%s)" % str(ring.keys()),
		ring.get("albedo") is Texture2D and int(ring.get("grid", 0)) == 8 and is_equal_approx(float(ring.get("span", 0.0)), 12.5))
	_chk(r, "and nothing where the bake is not", VA.ring_at(dir, "W_Bush", fake).is_empty() and VA.ring_at("", "W_Tree", fake).is_empty())
	var card := VA.card_of("W_Tree", pack.species[0], v["prepared"], ring, VA.crown_profile("conifer"))
	_chk(r, "card_of spans the bake's square and names its profile",
		(card["mesh"] as QuadMesh).size == Vector2(12.5, 12.5)
		and int((card["mat"] as ShaderMaterial).get_shader_parameter("profile")) == 1)
	_chk(r, "crown_profile: broadleaf 0, conifer 1, palm 2, anything else 0",
		VA.crown_profile("broadleaf") == 0 and VA.crown_profile("conifer") == 1 and VA.crown_profile("palm") == 2
		and VA.crown_profile("x") == 0)

	# ── the forest's own card: cached and registered as before ──
	VA.use_packs([pack])
	var bb := VA._billboard("W_Tree")
	_chk(r, "the forest's card is cached and registered for the pushes",
		not bb.is_empty() and VA._live_materials.has(bb["mat"]) and is_same(VA._billboard("W_Tree"), bb))
	VA.forget_packs()
	VA.reset()

	# ── the sheet's view lookup ──
	var exact := true
	var n1 := float(BakerRes.GRID - 1)
	for row in BakerRes.GRID:
		for col in BakerRes.GRID:
			var d := BakerRes.hemi_oct_dir(float(col) / n1, float(row) / n1)
			exact = exact and BakerRes.view_cell(d) == Vector2i(col, row)
	_chk(r, "view_cell finds every baked view from its own direction", exact)
	_chk(r, "straight up is the centre; a direction under the horizon lands on the border",
		BakerRes.hemi_oct_uv(Vector3.UP).is_equal_approx(Vector2(0.5, 0.5))
		and BakerRes.hemi_oct_uv(Vector3(1.0, -0.5, 0.0)).is_equal_approx(Vector2(1.0, 0.0)))
	TreeFix.rm_tree(ROOT)
	return r
