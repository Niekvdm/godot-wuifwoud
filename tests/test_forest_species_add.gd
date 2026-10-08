# Copyright (c) 2026 Digitzone
# SPDX-License-Identifier: MIT
extends RefCounted
## Adding species: an id from the file's name, made unique; the crown and the kind guessed from the name; the textures
## read from the mesh's materials, bark and leaves by the name rule; the new species saved in its pack's species/ and
## added to the pack, selected; undo takes it out of the pack and leaves its file; Remove from pack and its undo; the
## starter takes neither.
##
## Run with a unit-suite runner: static run() returns {name, passed, failed, details}.

const Fix := preload("res://addons/wuifwoud/tests/fixtures/species_fixture.gd")
const AddRes := preload("res://addons/wuifwoud/editor/species/forest_species_add.gd")
const TreeFix := preload("res://addons/wuifwoud/tests/fixtures/tree_fixture.gd")
const ROOT := "user://wf_e1_add"


static func _chk(r: Dictionary, n: String, ok: bool) -> void:
	if ok:
		r.passed += 1
	else:
		r.failed += 1
		r.details.append("✗ " + n)


## A scene of a tree whose bark and leaf materials carry texture files.
static func _textured(path: String) -> Array:
	var img := Image.create_empty(4, 4, false, Image.FORMAT_RGBA8)
	var t := []
	for nm in ["bark_c", "bark_n", "leaf_c"]:
		var tex := ImageTexture.create_from_image(img)
		ResourceSaver.save(tex, ROOT + "/t/" + nm + ".res")
		t.append(load(ROOT + "/t/" + nm + ".res"))
	var m := TreeFix.tree_mesh(4, "Bark", "Leaves")
	(m.surface_get_material(0) as BaseMaterial3D).albedo_texture = t[0]
	(m.surface_get_material(0) as BaseMaterial3D).normal_texture = t[1]
	(m.surface_get_material(1) as BaseMaterial3D).albedo_texture = t[2]
	TreeFix.scene(path, [m], ["Pine_Tree_02"])
	return [ROOT + "/t/bark_c.res", ROOT + "/t/bark_n.res", ROOT + "/t/leaf_c.res"]


static func run() -> Dictionary:
	var r := {"name": "forest_species_add", "passed": 0, "failed": 0, "details": []}
	_chk(r, "an id from the name, made unique",
		AddRes.id_for("Pine Tree 02", {}) == "Pine_Tree_02" and AddRes.id_for("W_Tree", {"W_Tree": true}) == "W_Tree_2"
		and AddRes.id_for("W_Tree", {"W_Tree": true, "W_Tree_2": true}) == "W_Tree_3")
	_chk(r, "the crown guessed from the name",
		AddRes.crown_guess("Pine_Tree_02") == "conifer" and AddRes.crown_guess("Fir_Tall_2") == "conifer"
		and AddRes.crown_guess("Coast_Palm_Tree_1") == "palm" and AddRes.crown_guess("Oak") == "broadleaf")
	_chk(r, "the kind guessed from the name",
		AddRes.kind_guess("Garden_Bush_1") == "bush" and AddRes.kind_guess("Fern_1") == "bush"
		and AddRes.kind_guess("Shrub") == "bush" and AddRes.kind_guess("Oak") == "tree")
	var fx := Fix.make(ROOT)
	DirAccess.make_dir_recursive_absolute(ProjectSettings.globalize_path(ROOT + "/t"))
	var tex := _textured(ROOT + "/m/pine.tscn")
	var got := AddRes.textures_of(ROOT + "/m/pine.tscn")
	_chk(r, "the textures read from the mesh's materials (%s)" % str(got),
		got["bark_albedo"] == tex[0] and got["bark_normal"] == tex[1] and got["foliage_albedo"] == tex[2]
		and got["foliage_normal"] == "")

	# ── the dialog ──
	var made: Array = Fix.dialog(fx)
	var d = made[0]
	var runner = made[1]
	var pack: ForestSpeciesPack = fx["fixture"]
	(d.find_child("Pack_Fixture", true, false).find_child("AddSpecies", true, false) as Button).pressed.emit()
	_chk(r, "+ Add species… asks the picker for a mesh", runner.picks.size() == 1 and not bool(runner.picks[0][2]))
	(runner.picks[0][3] as Callable).call(ROOT + "/m/pine.tscn")
	var file := ROOT + "/fixture/species/pine.tres"
	var on_disk := ResourceLoader.load(fx["fixture"].resource_path, "", ResourceLoader.CACHE_MODE_IGNORE) as ForestSpeciesPack
	var added = ResourceLoader.load(file, "", ResourceLoader.CACHE_MODE_IGNORE)
	_chk(r, "saved in its pack's species/, added to the pack, selected (%s)" % d.selected,
		added is ForestSpecies and (added as ForestSpecies).crown == "conifer" and (added as ForestSpecies).bark_albedo == tex[0]
		and on_disk.species.size() == 5 and d.selected == "pine")
	_chk(r, "the new species lives in its own file: the pack names it by path (%s)" % String(pack.species.back().resource_path),
		String(pack.species.back().resource_path) == file
		and FileAccess.get_file_as_string(pack.resource_path).contains('path="%s"' % file))
	d.undo()
	on_disk = ResourceLoader.load(fx["fixture"].resource_path, "", ResourceLoader.CACHE_MODE_IGNORE) as ForestSpeciesPack
	_chk(r, "undo takes it out of the pack and leaves its file", on_disk.species.size() == 4 and FileAccess.file_exists(file))
	var kept := FileAccess.get_md5(file)
	d.add_species_from(pack, ROOT + "/m/pine.tscn")
	_chk(r, "the same mesh added again takes a new id: the file kept for the one taken out stays as it was (%s)" % d.selected,
		d.selected == "pine_2" and FileAccess.get_md5(file) == kept and FileAccess.file_exists(ROOT + "/fixture/species/pine_2.tres"))
	d.undo()

	# ── remove from pack ──
	d.remove_from_pack("W_New", pack)
	on_disk = ResourceLoader.load(fx["fixture"].resource_path, "", ResourceLoader.CACHE_MODE_IGNORE) as ForestSpeciesPack
	_chk(r, "Remove from pack: out of the pack, its file kept, said",
		on_disk.species.size() == 3 and FileAccess.file_exists(ROOT + "/fixture/species/W_New.tres") and d.note.contains("W_New"))
	d.undo()
	_chk(r, "and undone", pack.species.size() == 4)
	d.free()

	# ── the starter takes neither ──
	var starter := ForestConfig.new().starter_pack_path()
	var st := load(starter) as ForestSpeciesPack
	var src := {"name": "Starter trees", "kind": "wuifwoud", "path": starter, "enabled": true,
		"packs": [{"pack": st, "enabled": true}]}
	var ro: Array = Fix.dialog(fx, false, {"sources_of": func() -> Array: return [src]})
	var d2 = ro[0]
	var n0 := st.species.size()
	d2.add_species_from(st, ROOT + "/m/pine.tscn")
	d2.remove_from_pack(String(st.species[0].id), st)
	_chk(r, "the starter takes no new species and loses none",
		st.species.size() == n0 and d2.find_child("AddSpecies", true, false) == null)
	d2.free()
	TreeFix.rm_tree(ROOT)
	return r
