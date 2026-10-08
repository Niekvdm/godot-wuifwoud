# Copyright (c) 2026 Digitzone
# SPDX-License-Identifier: MIT
extends RefCounted
## The species picker: what it offers (the forest's species and every species the packs grow, each once, by name); its
## face (By type, or the species' picture and name; a pin that grows nowhere in red, saying why); its popover (By type
## first, a tile a species, the one picked framed, a pin that grows nowhere offered and framed red); the search (by id
## or name, the grid alone filled again); a pick (the face, the popover closed, `picked`); a tile's click lands after
## its input is done.
##
## Run with a unit-suite runner: static run() returns {name, passed, failed, details}.

const PickerRes := preload("res://addons/wuifwoud/editor/common/forest_species_picker.gd")
const PicturesRes := preload("res://addons/wuifwoud/editor/common/forest_pictures.gd")
const KitRes := preload("res://addons/wuifwoud/editor/common/forest_kit.gd")
const VA := preload("res://addons/wuifwoud/forest_assets.gd")
const Fix := preload("res://addons/wuifwoud/tests/fixtures/species_fixture.gd")
const ROOT := "user://wf_e3_picker"
const ACC := Color("8bc34a")


static func _chk(r: Dictionary, n: String, ok: bool) -> void:
	if ok:
		r.passed += 1
	else:
		r.failed += 1
		r.details.append("✗ " + n)


static func _frames(n: int) -> void:
	for i in n:
		await (Engine.get_main_loop() as SceneTree).process_frame


## The popover grid's tile names, in order.
static func _names(pk) -> Array:
	var g: Node = pk.find_child(String(pk.prefix) + "SpeciesGrid", true, false)
	return g.get_children().map(func(c): return String(c.name)) if g != null else []


static func run() -> Dictionary:
	var r := {"name": "forest_species_picker", "passed": 0, "failed": 0, "details": []}
	var fx := Fix.make(ROOT)
	VA.use_packs([fx["fixture"], fx["other"]], PackedStringArray(["W_Other"]))
	var offered: PackedStringArray = PickerRes.choices(PackedStringArray(["W_Gone", "W_Tree"]))
	_chk(r, "it offers the forest's species and every species the packs grow, each once, by name (%s)" % str(offered),
		offered == PackedStringArray(["W_Bush", "W_Gone", "W_Missing", "W_New", "W_Tree"]))
	# ── the face ──
	var pk = PickerRes.new().setup(KitRes.new(null), "", offered, ACC, "New")
	_chk(r, "By type: its tile on the face, named by its prefix (%s)" % String(pk.text),
		String(pk.name) == "NewSpecies" and String(pk.text) == "By type ▾" and pk.icon == PickerRes.picture_of(""))
	var sp_pk = PickerRes.new().setup(KitRes.new(null), "W_Bush", offered, ACC)
	_chk(r, "a species: its picture and name on the face (%s)" % String(sp_pk.text),
		String(sp_pk.name) == "Species" and String(sp_pk.text) == "W Bush ▾" and sp_pk.icon == PicturesRes.of_id("W_Bush")
		and not sp_pk.has_theme_color_override("font_color"))
	sp_pk.free()
	var off_pk = PickerRes.new().setup(KitRes.new(null), "W_Other", offered, ACC)
	var gone_pk = PickerRes.new().setup(KitRes.new(null), "W_Gone", offered, ACC)
	off_pk.open()
	var off_tile: Button = off_pk.find_child("Species_W_Other", true, false)
	_chk(r, "a pin that grows nowhere: the face in red says why; the popover still offers it, framed red (%s; %s)" % [
		String(off_pk.tooltip_text), String(gone_pk.tooltip_text)],
		off_pk.get_theme_color("font_color") == PickerRes.ERROR and String(off_pk.tooltip_text).contains("switched off")
		and String(gone_pk.tooltip_text).contains("in no species pack") and off_tile != null
		and off_tile.tooltip_text.contains("switched off") and off_tile.has_theme_stylebox_override("normal"))
	off_pk.free()
	gone_pk.free()
	# ── the popover ──
	pk.open()
	var pop: PopupPanel = pk.find_child("NewSpeciesPop", true, false)
	var names := _names(pk)
	var by: Button = pk.find_child("NewSpeciesBy", true, false)
	var bush: Button = pk.find_child("NewSpecies_W_Bush", true, false)
	_chk(r, "open: the popover (shown only in a tree), By type first and framed (the pick), then a tile a species offered (%s)" % str(names),
		pop != null and not pop.visible and names == ["NewSpeciesBy", "NewSpecies_W_Bush", "NewSpecies_W_Gone",
		"NewSpecies_W_Missing", "NewSpecies_W_New", "NewSpecies_W_Tree"]
		and by != null and by.has_theme_stylebox_override("normal") and bush != null
		and not bush.has_theme_stylebox_override("normal"))
	# ── the search ──
	var field: LineEdit = pk.find_child("NewSpeciesSearch", true, false)
	field.text_changed.emit("bu")
	var by_id := _names(pk)
	var sp_new: ForestSpecies = VA.species_of("W_New")
	sp_new.display_name = "Rowan"
	pk.set_search("row")
	var by_name := _names(pk)
	sp_new.display_name = ""
	_chk(r, "the search narrows by id or name; the grid alone is filled again, the field kept (%s; %s)" % [str(by_id), str(by_name)],
		by_id == ["NewSpeciesBy", "NewSpecies_W_Bush"] and by_name == ["NewSpeciesBy", "NewSpecies_W_New"]
		and is_same(field, pk.find_child("NewSpeciesSearch", true, false)))
	# ── a pick ──
	var got := []
	pk.picked.connect(func(id: String) -> void: got.append(id))
	pk.choose("W_Tree")
	_chk(r, "a pick: the face shows it, the popover closes, picked says which (%s)" % str(got),
		got == ["W_Tree"] and String(pk.current) == "W_Tree" and String(pk.text) == "W Tree ▾" and not pop.visible)
	pk.open()
	(pk.find_child("NewSpecies_W_Bush", true, false) as Button).pressed.emit()
	var at_once: Array = got.duplicate()
	await _frames(2)
	(pk.find_child("NewSpeciesBy", true, false) as Button).pressed.emit()
	await _frames(2)
	_chk(r, "a tile's click lands once its input is done; By type picks \"\" (%s; at once %s)" % [str(got), str(at_once)],
		at_once == ["W_Tree"] and got == ["W_Tree", "W_Bush", ""] and String(pk.current) == "")
	pk.free()
	PicturesRes.forget()
	VA.forget_packs()
	VA.reset()
	Fix.TreeFix.rm_tree(ROOT)
	return r
