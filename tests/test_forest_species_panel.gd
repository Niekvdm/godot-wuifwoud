# Copyright (c) 2026 Digitzone
# SPDX-License-Identifier: MIT
extends RefCounted
## The selected species' settings: a slider let go writes its species' file and undo writes it back; the display name, the
## kind and the crown; a leaf material chip per material of its mesh (none on: the name rule), turning one on names it;
## an empty albedo is said in red; the starter's species are read-only; a pack addon's say what an update does;
## mesh_surfaces reads a mesh's surfaces.
##
## Run with a unit-suite runner: static run() returns {name, passed, failed, details}.

const Fix := preload("res://addons/wuifwoud/tests/fixtures/species_fixture.gd")
const VA := preload("res://addons/wuifwoud/forest_assets.gd")
const ROOT := "user://wf_e1_panel"


static func _chk(r: Dictionary, n: String, ok: bool) -> void:
	if ok:
		r.passed += 1
	else:
		r.failed += 1
		r.details.append("✗ " + n)


static func _disk(path: String) -> ForestSpecies:
	return ResourceLoader.load(path, "", ResourceLoader.CACHE_MODE_IGNORE) as ForestSpecies


static func run() -> Dictionary:
	var r := {"name": "forest_species_panel", "passed": 0, "failed": 0, "details": []}
	var fx := Fix.make(ROOT)
	var surf := VA.mesh_surfaces(ROOT + "/m/tree.tscn")
	_chk(r, "mesh_surfaces: each surface's material and the name rule (%s)" % str(surf),
		surf.size() == 2 and surf[0]["name"] == "Bark" and not bool(surf[0]["foliage"])
		and surf[1]["name"] == "Leaves" and bool(surf[1]["foliage"]))
	var made: Array = Fix.dialog(fx)
	var d = made[0]
	d.select("W_Tree")
	var sp: ForestSpecies = fx["fixture"].species[0]
	var path := sp.resource_path

	# ── a slider, written and undone ──
	var row := d.find_child("TrunkRadius", true, false) as VBoxContainer
	var s := row.get_node("Slider") as HSlider
	var ac := (d.find_child("AlphaCut", true, false) as Node).get_node("Slider") as HSlider
	_chk(r, "the sliders take no mouse wheel (it would move one without a write; the wheel scrolls the column)",
		not s.scrollable and not ac.scrollable)
	s.value = 0.5
	s.drag_ended.emit(true)
	_chk(r, "Trunk radius let go: written to its file", is_equal_approx(_disk(path).trunk_radius, 0.5))
	d.undo()
	_chk(r, "undo writes it back", is_equal_approx(_disk(path).trunk_radius, ForestSpecies.DEFAULT_TRUNK_RADIUS))

	# ── name, kind, crown ──
	var dn := d.find_child("DisplayName", true, false) as LineEdit
	dn.text = "Fixture tree"
	dn.text_submitted.emit(dn.text)
	(d.find_child("Kind", true, false).get_node("Seg1") as Button).pressed.emit()
	(d.find_child("Crown", true, false).get_node("Seg2") as Button).pressed.emit()
	var back := _disk(path)
	_chk(r, "the display name, the kind and the crown written (%s, %s, %s)" % [back.display_name, back.kind, back.crown],
		back.display_name == "Fixture tree" and back.kind == "bush" and back.crown == "palm")
	# A typed name whose field loses its focus because a rebuild takes it down (a click on a tile, Build, a mode): the
	# edit lands once the rebuild is done (the dialog applies it deferred; called here, a suite draws no frame).
	var dn2 := d.find_child("DisplayName", true, false) as LineEdit
	dn2.text = "Taken down"
	d._rebuilding = true
	dn2.focus_exited.emit()
	d._rebuilding = false
	d._apply_pending()
	_chk(r, "a name committed by a rebuild taking its field down is written (%s)" % _disk(path).display_name,
		_disk(path).display_name == "Taken down")
	var tp := (d.find_child("Tex_bark_normal", true, false) as Node).get_node("Path") as LineEdit
	tp.text = "res://addons/wuifwoud/tests/fixtures/x_n.png"
	tp.focus_exited.emit()
	_chk(r, "a path field writes when it loses focus", _disk(path).bark_normal == "res://addons/wuifwoud/tests/fixtures/x_n.png")

	# ── leaf materials, an empty albedo ──
	var bark := d.find_child("Leaf_Bark", true, false) as Button
	var leaves := d.find_child("Leaf_Leaves", true, false) as Button
	_chk(r, "a chip per material of the mesh, none on (the name rule)",
		bark != null and leaves != null and not bark.button_pressed and not leaves.button_pressed)
	leaves.button_pressed = true          # a toggle button emits `toggled` when set
	_chk(r, "turning one on names it", _disk(path).foliage_materials == PackedStringArray(["Leaves"]))
	_chk(r, "an empty albedo is said in red", d.find_child("Empty_bark_albedo", true, false) != null
		and d.find_child("Empty_foliage_albedo", true, false) != null)
	d.free()

	# ── read-only and pack addon notes ──
	var starter := ForestConfig.new().starter_pack_path()
	var st_pack := load(starter) as ForestSpeciesPack
	var src := {"name": "Starter trees", "kind": "wuifwoud", "path": starter, "enabled": true,
		"packs": [{"pack": st_pack, "enabled": true}]}
	var ro: Array = Fix.dialog(fx, false, {"sources_of": func() -> Array: return [src]})
	var d2 = ro[0]
	d2.select(String(st_pack.species[0].id))
	_chk(r, "the starter's species are read-only: the note, no settings",
		d2.find_child("ReadOnly", true, false) != null and d2.find_child("TrunkRadius", true, false) == null)
	d2.free()
	var ad := {"name": "Woods", "kind": "addon", "path": "res://addons/wuifwoud/tests/fixtures/woods/wuifwoud_packs.tres", "enabled": true,
		"packs": [{"pack": fx["other"], "enabled": true}]}
	var an: Array = Fix.dialog(fx, false, {"sources_of": func() -> Array: return [ad]})
	var d3 = an[0]
	d3.select("W_Other")
	var note := d3.find_child("AddonNote", true, false) as Label
	_chk(r, "a pack addon's species say what an update does", note != null and note.text.contains("Woods"))
	d3.free()
	Fix.TreeFix.rm_tree(ROOT)
	return r
