# Copyright (c) 2026 Digitzone
# SPDX-License-Identifier: MIT
extends RefCounted
## The preparation saved: ForestAssets.prepare_species_of on a tree with an authored chain,
## a bush without one, a species naming its leaf materials and one whose mesh is missing; no material on any surface;
## saved as a ForestBuiltSpecies and loaded back, byte for byte; the forest loads a built species instead of preparing
## it, prepares one of another prep version or one whose file will not load and says once that its pack is not built;
## the built crown colour; an id two packs hold, the second built: the first's grows, prepared; a pack folder moved
## with its built/ still loads its built species.
##
## Run with a unit-suite runner: static run() returns {name, passed, failed, details}.

const VA := preload("res://addons/wuifwoud/forest_assets.gd")
const BuiltRes := preload("res://addons/wuifwoud/species/forest_built_species.gd")
const ForestLogRes := preload("res://addons/wuifwoud/forest_log.gd")
const TreeFix := preload("res://addons/wuifwoud/tests/fixtures/tree_fixture.gd")
const ROOT := "user://wf_d1_built"


class Capture:
	var lines: Array = []

	func take(level: StringName, msg: String) -> void:
		lines.append([level, msg])


static func _chk(r: Dictionary, n: String, ok: bool) -> void:
	if ok:
		r.passed += 1
	else:
		r.failed += 1
		r.details.append("✗ " + n)


static func _no_materials(p: Dictionary) -> bool:
	var all := [p["combined"]]
	all.append_array(p["levels"])
	for m in all:
		for si in (m as ArrayMesh).get_surface_count():
			if (m as ArrayMesh).surface_get_material(si) != null:
				return false
	return true


static func _write_json(path: String, d: Dictionary) -> void:
	var f := FileAccess.open(path, FileAccess.WRITE)
	f.store_string(JSON.stringify(d))
	f.close()


static func _save_built(id: String, p: Dictionary, path: String) -> void:
	var b = BuiltRes.new()
	b.fill(id, p, VA.PREP_VERSION)
	DirAccess.make_dir_recursive_absolute(ProjectSettings.globalize_path(path.get_base_dir()))
	ResourceSaver.save(b, path)


static func run() -> Dictionary:
	var r := {"name": "forest_built_species", "passed": 0, "failed": 0, "details": []}
	var keep: Callable = ForestLogRes.sink
	var cap := Capture.new()
	ForestLogRes.sink = cap.take
	TreeFix.rm_tree(ROOT)
	TreeFix.scene(ROOT + "/m/tree.tscn", [TreeFix.tree_mesh(12, "Bark", "Leaves"), TreeFix.tree_mesh(4, "Bark", "Leaves")],
		["Fix_LOD0", "Fix_LOD1"])
	TreeFix.scene(ROOT + "/m/bush.tscn", [TreeFix.tree_mesh(6, "Wood", "Leaf")], ["Bush"])
	TreeFix.scene(ROOT + "/m/named.tscn", [TreeFix.tree_mesh(5, "Stem", "Crown")], ["Named"])
	var tree := TreeFix.species("W_Tree", ROOT + "/m/tree.tscn")
	var bush := TreeFix.species("W_Bush", ROOT + "/m/bush.tscn")
	var named := TreeFix.species("W_Named", ROOT + "/m/named.tscn", PackedStringArray(["Crown"]))
	var unnamed := TreeFix.species("W_Unnamed", ROOT + "/m/named.tscn")
	var missing := TreeFix.species("W_Missing", ROOT + "/m/none.tscn")

	# ── the preparation ──
	var pt: Dictionary = VA.prepare_species_of(tree)
	_chk(r, "a tree with an authored chain: two surfaces, two levels, the leaves its second surface, its cards stamped (%s)"
		% str(pt.get("foliage")), pt.has("combined") and (pt["combined"] as ArrayMesh).get_surface_count() == 2
		and (pt["levels"] as Array).size() == 2 and pt["foliage"] == PackedInt32Array([1]) and bool(pt["stamped"])
		and (pt["aabb"] as AABB).size.y > 4.0)
	_chk(r, "no material on any prepared surface (the forest dresses them at load)", _no_materials(pt))
	var pb: Dictionary = VA.prepare_species_of(bush)
	_chk(r, "a bush without a chain: no levels, and that is said with its triangles (%s)" % str(pb.get("warnings")),
		(pb["levels"] as Array).is_empty() and Array(pb["warnings"]).any(func(w): return String(w).contains("ships no authored LOD chain")))
	var pn: Dictionary = VA.prepare_species_of(named)
	var pu: Dictionary = VA.prepare_species_of(unnamed)
	_chk(r, "a species naming its leaf materials is taken at its word; the name rule finds none there (%s, %s)"
		% [str(pn.get("foliage")), str(pu.get("foliage"))],
		pn["foliage"] == PackedInt32Array([1]) and (pu["foliage"] as PackedInt32Array).is_empty())
	var pm: Dictionary = VA.prepare_species_of(missing)
	_chk(r, "a missing mesh: warnings alone (%s)" % str(pm), not pm.has("combined")
		and Array(pm["warnings"]).has("mesh missing: W_Missing"))

	# ── saved and loaded back, byte for byte ──
	var same := true
	for pair in [["W_Tree", pt], ["W_Bush", pb]]:
		var p: Dictionary = pair[1]
		var path := ROOT + "/rt/%s.res" % pair[0]
		_save_built(pair[0], p, path)
		var back = ResourceLoader.load(path, "", ResourceLoader.CACHE_MODE_IGNORE)
		var q: Dictionary = back.to_prepared()
		same = same and TreeFix.mesh_bytes(p["combined"]) == TreeFix.mesh_bytes(q["combined"]) and (p["levels"] as Array).size() == (q["levels"] as Array).size()
		for k in (p["levels"] as Array).size():
			same = same and TreeFix.mesh_bytes(p["levels"][k]) == TreeFix.mesh_bytes(q["levels"][k])
		for key in ["foliage", "stamped", "crown_centre", "crown_radius", "spherify", "crown_uv", "aabb"]:
			same = same and p[key] == q[key]
		same = same and int(back.prep_version) == VA.PREP_VERSION and String(back.id) == pair[0]
	_chk(r, "a built species loads back as the preparation it saved, byte for byte", same)

	# ── the forest loads a built species instead of preparing it ──
	var pack_dir := ROOT + "/pack"
	var p0 := ForestSpeciesPack.new()
	p0.name = "Fixture"
	var sl: Array[ForestSpecies] = [tree, bush, named]
	p0.species = sl
	DirAccess.make_dir_recursive_absolute(ProjectSettings.globalize_path(pack_dir + "/built"))
	ResourceSaver.save(p0, pack_dir + "/pack.tres")
	var pack := load(pack_dir + "/pack.tres") as ForestSpeciesPack
	_save_built("W_Tree", pt, pack_dir + "/built/W_Tree.res")
	var current := {"species": {"W_Tree": {"prep_version": VA.PREP_VERSION}}}
	_write_json(pack_dir + "/built/built.json", current)
	VA.use_packs([pack])
	var n0: int = VA.prepared_count
	var mats: Array = VA._species_materials("W_Tree")
	var dressed := not mats.is_empty() and (mats[0] as ArrayMesh).get_surface_count() == 2
	for si in 2:
		dressed = dressed and (mats[0] as ArrayMesh).surface_get_material(si) is ShaderMaterial
	_chk(r, "a built species loads: none prepared, the same bytes, dressed at load, its levels and height (%d)"
		% (VA.prepared_count - n0), VA.prepared_count == n0 and dressed and TreeFix.mesh_bytes(mats[0]) == TreeFix.mesh_bytes(pt["combined"])
		and VA._species_lod_meshes("W_Tree").size() == 2
		and is_equal_approx(VA.species_height("W_Tree"), (pt["aabb"] as AABB).size.y))

	# ── another prep version: prepared, the pack said once to be unbuilt ──
	_write_json(pack_dir + "/built/built.json", {"species": {"W_Tree": {"prep_version": VA.PREP_VERSION + 1},
		"W_Bush": {"prep_version": VA.PREP_VERSION + 1}}})
	VA.reset()
	cap.lines.clear()
	n0 = VA.prepared_count
	VA._species_materials("W_Tree")
	VA._species_materials("W_Bush")
	var unbuilt := cap.lines.filter(func(l): return l[0] == &"warn" and String(l[1]).contains("is not built"))
	_chk(r, "another prep version: both prepared (%d), the pack said once to be unbuilt (%d)"
		% [VA.prepared_count - n0, unbuilt.size()], VA.prepared_count == n0 + 2 and unbuilt.size() == 1)

	# ── a built file that will not load: prepared, the file named ──
	_write_json(pack_dir + "/built/built.json", current)
	var bad := FileAccess.open(pack_dir + "/built/W_Tree.res", FileAccess.WRITE)
	bad.store_string("not a resource")
	bad.close()
	VA.reset()
	cap.lines.clear()
	n0 = VA.prepared_count
	VA._species_materials("W_Tree")
	var named_file := cap.lines.filter(func(l): return l[0] == &"warn" and String(l[1]).contains("W_Tree.res"))
	_chk(r, "a built file that will not load: prepared, the file named once (%d)" % named_file.size(),
		VA.prepared_count == n0 + 1 and named_file.size() == 1)
	_save_built("W_Tree", pt, pack_dir + "/built/W_Tree.res")

	# ── the built crown colour ──
	_write_json(pack_dir + "/built/built.json", {"species": {"W_Tree": {"prep_version": VA.PREP_VERSION,
		"crown_colour": [0.1, 0.2, 0.3]}, "W_Bush": {"prep_version": VA.PREP_VERSION, "crown_colour": null}}})
	VA.reset()
	var tc: Array = VA.built_crown_colour("W_Tree")
	_chk(r, "the built crown colour: [Color] when read at the build, [null] when there was none, [] when not built (%s)"
		% str([tc, VA.built_crown_colour("W_Bush"), VA.built_crown_colour("W_Named")]),
		tc.size() == 1 and (tc[0] as Color).is_equal_approx(Color(0.1, 0.2, 0.3))
		and VA.built_crown_colour("W_Bush") == [null] and VA.built_crown_colour("W_Named").is_empty())

	# ── an id two packs hold, the second built: the first's grows, prepared ──
	var first := ForestSpeciesPack.new()
	first.name = "First"
	var fl: Array[ForestSpecies] = [TreeFix.species("W_Tree", ROOT + "/m/tree.tscn")]
	first.species = fl
	VA.use_packs([first, pack])
	n0 = VA.prepared_count
	VA._species_materials("W_Tree")
	_chk(r, "an id two packs hold: the first pack's species grows, prepared; the second's built file never loaded",
		VA.prepared_count == n0 + 1)

	# ── a pack folder moved with its built/ ──
	var moved := ROOT + "/moved"
	DirAccess.make_dir_recursive_absolute(ProjectSettings.globalize_path(moved + "/built"))
	DirAccess.copy_absolute(ProjectSettings.globalize_path(pack_dir + "/pack.tres"),
		ProjectSettings.globalize_path(moved + "/pack.tres"))
	for f in ["W_Tree.res", "built.json"]:
		DirAccess.copy_absolute(ProjectSettings.globalize_path(pack_dir + "/built/" + f),
			ProjectSettings.globalize_path(moved + "/built/" + f))
	var mp := load(moved + "/pack.tres") as ForestSpeciesPack
	VA.use_packs([mp])
	n0 = VA.prepared_count
	VA._species_materials("W_Tree")
	_chk(r, "a pack folder moved with its built/: its built folder follows it, its species load built (%s)" % mp.built_dir(),
		mp.built_dir() == moved + "/built" and VA.prepared_count == n0)

	VA.forget_packs()
	VA.reset()
	TreeFix.rm_tree(ROOT)
	ForestLogRes.sink = keep
	return r
