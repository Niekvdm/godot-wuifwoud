# Copyright (c) 2026 Digitzone
# SPDX-License-Identifier: MIT
extends RefCounted
## The pack build headless, without a bake: what needs building (not built, a source changed (by
## its bytes: a time that moved alone is no change), another prep version, a mesh missing, a pack that is no file); a
## build lands each species whole (its file, its entry with its sources; the staging folder gone) and the forest loads
## what it prepared; a rebuild after a change replaces what an open forest had cached; `only` and `force`; a species
## no longer in the pack is removed; cancel keeps the species landed, and the next build carries on. What else a built
## species depends on: its leaf materials and alpha cut, its files' import settings (their [params], not their remap), a
## glTF's buffer files. Two packs in one folder: neither's build removes the other's species. The same species built
## anywhere writes the same bytes.
##
## Run with a unit-suite runner: static run() returns {name, passed, failed, details}.

const VA := preload("res://addons/wuifwoud/forest_assets.gd")
const BuildRes := preload("res://addons/wuifwoud/species/forest_pack_build.gd")
const TreeFix := preload("res://addons/wuifwoud/tests/fixtures/tree_fixture.gd")
const ForestLogRes := preload("res://addons/wuifwoud/forest_log.gd")
const ROOT := "user://wf_d1_build"


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


## The states of `pack`'s species: {id: state}.
static func _states(pack) -> Dictionary:
	var out := {}
	for row in BuildRes.states([pack]):
		for st in row["species"]:
			out[st["id"]] = st["state"]
	return out


static func _why(pack, id: String) -> String:
	for row in BuildRes.states([pack]):
		for st in row["species"]:
			if st["id"] == id:
				return st["why"]
	return ""


static func _save_pack(path: String, species: Array) -> ForestSpeciesPack:
	var p := ForestSpeciesPack.new()
	p.name = "Fixture"
	var sl: Array[ForestSpecies] = []
	for s in species:
		sl.append(s)
	p.species = sl
	DirAccess.make_dir_recursive_absolute(ProjectSettings.globalize_path(path.get_base_dir()))
	ResourceSaver.save(p, path)
	return ResourceLoader.load(path, "", ResourceLoader.CACHE_MODE_REPLACE) as ForestSpeciesPack


static func _sp(pack, id: String):
	for s in pack.species:
		if String(s.id) == id:
			return s
	return null


## An .import sidecar for `path`: its [remap] (`remap`, a line) and its [params] (`params`).
static func _import(path: String, remap: String, params: String) -> void:
	var f := FileAccess.open(path + ".import", FileAccess.WRITE)
	f.store_string("[remap]\n\nimporter=\"texture\"\n%s\n\n[deps]\n\nsource_file=\"%s\"\n\n[params]\n\n%s\n" % [remap, path, params])
	f.close()


static func _png(path: String, c: Color) -> void:
	var img := Image.create(4, 4, false, Image.FORMAT_RGBA8)
	img.fill(c)
	DirAccess.make_dir_recursive_absolute(ProjectSettings.globalize_path(path.get_base_dir()))
	img.save_png(path)


static func run() -> Dictionary:
	var r := {"name": "forest_pack_build", "passed": 0, "failed": 0, "details": []}
	var keep: Callable = ForestLogRes.sink
	var cap := Capture.new()
	ForestLogRes.sink = cap.take
	TreeFix.rm_tree(ROOT)
	TreeFix.scene(ROOT + "/m/tree.tscn", [TreeFix.tree_mesh(12, "Bark", "Leaves"), TreeFix.tree_mesh(4, "Bark", "Leaves")],
		["Fix_LOD0", "Fix_LOD1"])
	TreeFix.scene(ROOT + "/m/bush.tscn", [TreeFix.tree_mesh(6, "Wood", "Leaf")], ["Bush"])
	_png(ROOT + "/t/bark.png", Color(0.4, 0.3, 0.2))
	var tree := TreeFix.species("W_Tree", ROOT + "/m/tree.tscn")
	tree.bark_albedo = ROOT + "/t/bark.png"
	var bush := TreeFix.species("W_Bush", ROOT + "/m/bush.tscn")
	bush.kind = "bush"
	var missing := TreeFix.species("W_Missing", ROOT + "/m/none.tscn")
	var pack_path := ROOT + "/pack/pack.tres"
	var pack := _save_pack(pack_path, [tree, bush, missing])
	var built := ROOT + "/pack/built"

	# ── what needs building ──
	var s0 := _states(pack)
	_chk(r, "before a build: two species not built, one whose mesh is missing (%s)" % str(s0),
		s0 == {"W_Tree": "unbuilt", "W_Bush": "unbuilt", "W_Missing": "missing"})

	# ── a build: each species lands whole ──
	var rep: Dictionary = BuildRes.new([pack]).run_now()
	var man: Dictionary = BuildRes.read_manifest(built)
	var te: Dictionary = (man.get("species", {}) as Dictionary).get("W_Tree", {})
	_chk(r, "a build lands both, fails the missing one with why, and is not ok (%s)" % str(rep),
		rep["built"] == ["W_Tree", "W_Bush"] and (rep["failed"] as Dictionary).has("W_Missing")
		and String(rep["failed"]["W_Missing"]).begins_with("no mesh at") and not bool(rep["ok"]))
	_chk(r, "its files and entries: the built species, its sources (mesh and bark sheet), no bake and no colour without a bake, no staging left",
		FileAccess.file_exists(built + "/W_Tree.res") and FileAccess.file_exists(built + "/W_Bush.res")
		and int(te.get("prep_version", -1)) == VA.PREP_VERSION
		and (te.get("sources", {}) as Dictionary).keys().size() == 2 and not man.has("bake")
		and not te.has("crown_colour") and not DirAccess.dir_exists_absolute(ProjectSettings.globalize_path(built + "/" + BuildRes.STAGING)))
	_chk(r, "after it: built, built, missing (%s)" % str(_states(pack)),
		_states(pack) == {"W_Tree": "built", "W_Bush": "built", "W_Missing": "missing"})

	# ── the forest loads what the build prepared ──
	VA.use_packs([pack])
	var n0: int = VA.prepared_count
	var mats: Array = VA._species_materials("W_Tree")
	var fresh: Dictionary = VA.prepare_species_of(tree)
	_chk(r, "the forest loads the built species, none prepared, the bytes a preparation makes",
		VA.prepared_count == n0 + 1 and not mats.is_empty()
		and TreeFix.mesh_bytes(mats[0]) == TreeFix.mesh_bytes(fresh["combined"]))

	# ── a source whose time moved but whose bytes did not (a copied built/): still built; its bytes changed: needs ──
	te["sources"][ROOT + "/t/bark.png"]["mtime"] = 1
	man["species"]["W_Tree"] = te
	var f := FileAccess.open(built + "/" + BuildRes.MANIFEST, FileAccess.WRITE)
	f.store_string(JSON.stringify(man))
	f.close()
	var moved_time: String = _states(pack)["W_Tree"]
	_png(ROOT + "/t/bark.png", Color(0.9, 0.1, 0.1))
	_chk(r, "a time that moved alone is no change (%s); changed bytes need building (%s)" % [moved_time, _why(pack, "W_Tree")],
		moved_time == "built" and _states(pack)["W_Tree"] == "needs" and _why(pack, "W_Tree") == "bark.png changed")

	# ── a rebuild builds what needs it, and replaces what the forest had cached ──
	TreeFix.scene(ROOT + "/m/tree.tscn", [TreeFix.tree_mesh(16, "Bark", "Leaves"), TreeFix.tree_mesh(5, "Bark", "Leaves")],
		["Fix_LOD0", "Fix_LOD1"])
	var old_bytes := TreeFix.mesh_bytes(mats[0])
	var rep2: Dictionary = BuildRes.new([pack]).run_now()
	VA.reset()
	var mats2: Array = VA._species_materials("W_Tree")
	_chk(r, "a rebuild builds what needs it, skips the rest (%s), and the forest gets the NEW mesh, not its cached one"
		% str([rep2["built"], rep2["skipped"]]), rep2["built"] == ["W_Tree"] and rep2["skipped"] == ["W_Bush"]
		and not mats2.is_empty() and TreeFix.mesh_bytes(mats2[0]) != old_bytes
		and TreeFix.mesh_bytes(mats2[0]) == TreeFix.mesh_bytes(VA.prepare_species_of(tree)["combined"]))

	# ── another prep version ──
	man = BuildRes.read_manifest(built)
	man["species"]["W_Bush"]["prep_version"] = 0
	f = FileAccess.open(built + "/" + BuildRes.MANIFEST, FileAccess.WRITE)
	f.store_string(JSON.stringify(man))
	f.close()
	_chk(r, "another prep version needs building (%s)" % _why(pack, "W_Bush"),
		_states(pack)["W_Bush"] == "needs" and _why(pack, "W_Bush") == "built by prep version 0, now %d" % VA.PREP_VERSION)

	# ── only, force ──
	var rep3: Dictionary = BuildRes.new([pack], {"only": ["W_Tree"], "force": true}).run_now()
	_chk(r, "`only` builds those ids, `force` even when built (%s); the rest untouched" % str(rep3["built"]),
		rep3["built"] == ["W_Tree"] and _states(pack)["W_Bush"] == "needs")

	# ── cancel: before anything lands; after one lands; the next build carries on ──
	var j := BuildRes.new([pack], {"force": true, "bake": false})
	j.start(null)
	j.cancel()
	while not j.poll():
		pass
	var c0: Dictionary = j.report
	var j2 := BuildRes.new([pack], {"force": true, "bake": false})
	j2.start(null)
	j2.poll()
	j2.cancel()
	while not j2.poll():
		pass
	var c1: Dictionary = j2.report
	var rep4: Dictionary = BuildRes.new([pack]).run_now()
	_chk(r, "cancel: nothing landed (%s); one landed stays (%s); the next build carries on (%s); no staging left"
		% [str(c0["built"]), str(c1["built"]), str(rep4["built"])],
		bool(c0["cancelled"]) and (c0["built"] as Array).is_empty() and bool(c1["cancelled"]) and c1["built"] == ["W_Tree"]
		and rep4["built"] == ["W_Bush"] and rep4["skipped"] == ["W_Tree"]
		and not DirAccess.dir_exists_absolute(ProjectSettings.globalize_path(built + "/" + BuildRes.STAGING)))

	# ── a species no longer in the pack is removed; a pack that is no file builds nothing ──
	pack = _save_pack(pack_path, [tree, missing])
	var rep5: Dictionary = BuildRes.new([pack]).run_now()
	man = BuildRes.read_manifest(built)
	_chk(r, "a species no longer in its pack: removed, its file and entry gone (%s)" % str(rep5["removed"]),
		rep5["removed"] == ["W_Bush"] and not FileAccess.file_exists(built + "/W_Bush.res")
		and not (man["species"] as Dictionary).has("W_Bush"))
	var loose := ForestSpeciesPack.new()
	var ll: Array[ForestSpecies] = [TreeFix.species("W_Loose", ROOT + "/m/bush.tscn")]
	loose.species = ll
	var rep6: Dictionary = BuildRes.new([loose]).run_now()
	_chk(r, "a pack that is not its own file: nothing built, why given (%s)" % str(rep6["failed"]),
		(rep6["built"] as Array).is_empty() and String(rep6["failed"].get("W_Loose", "")) == "the pack is not saved as its own file")

	# ── what else a built species depends on: its leaf materials and alpha cut, its files' import settings, a glTF's
	# buffer files (the final review) ──
	BuildRes.new([pack], {"force": true}).run_now()
	var ts = _sp(pack, "W_Tree")
	var settled: String = _states(pack)["W_Tree"]
	ts.alpha_cut = 0.33
	var why_cut := _why(pack, "W_Tree")
	ts.alpha_cut = ForestSpecies.DEFAULT_ALPHA_CUT
	ts.foliage_materials = PackedStringArray(["Leaves"])
	var why_leaves := _why(pack, "W_Tree")
	ts.foliage_materials = PackedStringArray()
	var back: String = _states(pack)["W_Tree"]
	_chk(r, "its alpha cut changed (%s), its leaf materials changed (%s): needs building; put back: built (%s)"
		% [why_cut, why_leaves, back], settled == "built" and why_cut == "its settings changed"
		and why_leaves == "its settings changed" and back == "built")
	_import(ROOT + "/t/bark.png", "", "compress/mode=0")
	var why_new_imp := _why(pack, "W_Tree")
	BuildRes.new([pack]).run_now()
	var imp_built: String = _states(pack)["W_Tree"]
	_import(ROOT + "/t/bark.png", "path.s3tc=\"elsewhere.s3tc.ctex\"", "compress/mode=0")
	var remap_only: String = _states(pack)["W_Tree"]
	_import(ROOT + "/t/bark.png", "", "compress/mode=2")
	var why_imp := _why(pack, "W_Tree")
	_chk(r, "a file's import settings: new (%s) or changed (%s): needs building; built again: built (%s); its remap moved alone: still built (%s)"
		% [why_new_imp, why_imp, imp_built, remap_only], why_new_imp == "bark.png's import settings changed"
		and why_imp == "bark.png's import settings changed" and imp_built == "built" and remap_only == "built")
	var g := FileAccess.open(ROOT + "/m/g.gltf", FileAccess.WRITE)
	g.store_string(JSON.stringify({"asset": {"version": "2.0"}, "buffers": [{"uri": "g%20b.bin", "byteLength": 4},
		{"uri": "data:application/octet-stream;base64,AAAA", "byteLength": 3}]}))
	g.close()
	var gs := TreeFix.species("W_G", ROOT + "/m/g.gltf")
	_chk(r, "a glTF's external buffer files are among its files, an embedded one is not (%s)" % str(gs.files()),
		gs.files() == PackedStringArray([ROOT + "/m/g.gltf", ROOT + "/m/g b.bin"]))

	# ── two packs in one folder share its built/: neither's build removes the other's species ──
	BuildRes.new([pack]).run_now()
	var other := _save_pack(ROOT + "/pack/other.tres", [TreeFix.species("W_Other", ROOT + "/m/bush.tscn")])
	BuildRes.new([pack, other]).run_now()
	var after_both := [_states(pack)["W_Tree"], _states(other)["W_Other"]]
	var rb: Dictionary = BuildRes.new([other]).run_now()
	var ra: Dictionary = BuildRes.new([pack]).run_now()
	_chk(r, "two packs in one folder: both built (%s); a full build of either removes none of the other's (%s, %s)"
		% [str(after_both), str(rb["removed"]), str(ra["removed"])], after_both == ["built", "built"]
		and (rb["removed"] as Array).is_empty() and (ra["removed"] as Array).is_empty()
		and _states(pack)["W_Tree"] == "built" and _states(other)["W_Other"] == "built")
	# (An emptied pack would not do here: saved empty, its species are left out of the file, and reloading over the
	# cached pack keeps the old list.)
	other = _save_pack(ROOT + "/pack/other.tres", [TreeFix.species("W_Other2", ROOT + "/m/bush.tscn")])
	var rd: Dictionary = BuildRes.new([other]).run_now()
	_chk(r, "one of them dropping a species removes that one alone (%s)" % str(rd["removed"]),
		rd["removed"] == ["W_Other"] and not FileAccess.file_exists(built + "/W_Other.res") and _states(pack)["W_Tree"] == "built")

	# ── the same species built anywhere is the same bytes: a copy of the pack in another folder (within one process the
	# saver keeps a path's sub-resource ids, so a rebuild in place would hide what another process writes) ──
	BuildRes.new([pack], {"force": true}).run_now()
	var twin := _save_pack(ROOT + "/twin/pack.tres", [_sp(pack, "W_Tree")])
	BuildRes.new([twin], {"force": true}).run_now()
	var md0 := FileAccess.get_md5(built + "/W_Tree.res")
	_chk(r, "the same species built in another folder (another process) writes the same bytes",
		md0 != "" and FileAccess.get_md5(ROOT + "/twin/built/W_Tree.res") == md0)

	# ── a manifest written whole or not at all; a landing only when something landed ──
	var mp := ProjectSettings.globalize_path(ROOT + "/atomic/built.json")
	DirAccess.make_dir_recursive_absolute(mp.get_base_dir())
	var e1 := BuildRes.write_atomic(mp, "{\"a\": 1}")
	DirAccess.make_dir_recursive_absolute(mp + ".tmp")      # the temporary file cannot be written: a folder is in its way
	var e2 := BuildRes.write_atomic(mp, "{\"a\": 2}")
	_chk(r, "a manifest is written whole (%s); a failed write leaves the old one (%s)" % [error_string(e1), error_string(e2)],
		e1 == OK and e2 != OK and FileAccess.get_file_as_string(mp) == "{\"a\": 1}")
	DirAccess.remove_absolute(mp + ".tmp")
	_chk(r, "a landing is needed when a build landed or removed a species, not after a cancel that landed nothing",
		BuildRes.landed_anything({"built": ["W_Tree"], "removed": []})
		and BuildRes.landed_anything({"built": [], "removed": ["W_Bush"]})
		and not BuildRes.landed_anything({"built": [], "removed": [], "cancelled": true}))

	VA.forget_packs()
	VA.reset()
	TreeFix.rm_tree(ROOT)
	ForestLogRes.sink = keep
	return r
