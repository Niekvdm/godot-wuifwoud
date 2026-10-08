# Copyright (c) 2026 Digitzone
# SPDX-License-Identifier: MIT
extends RefCounted
## Species on and off: what uses a species (a type's lanes, an import rule, pinned single trees and rows); switching off
## an unused species writes it to the config at once, a used one asks first and Keep it changes nothing; on again; a
## species listed in two packs is switched by its id (both rows dim); the tile's menu switches and builds.
##
## Run with a unit-suite runner: static run() returns {name, passed, failed, details}.

const Fix := preload("res://addons/wuifwoud/tests/fixtures/species_fixture.gd")
const UseRes := preload("res://addons/wuifwoud/editor/species/forest_species_use.gd")
const TypesRes := preload("res://addons/wuifwoud/forest_types.gd")
const ROOT := "user://wf_e1_enable"


static func _chk(r: Dictionary, n: String, ok: bool) -> void:
	if ok:
		r.passed += 1
	else:
		r.failed += 1
		r.details.append("✗ " + n)


static func run() -> Dictionary:
	var r := {"name": "forest_species_enable", "passed": 0, "failed": 0, "details": []}
	# ── what uses a species ──
	var ft := TypesRes.new()
	var pools := {"coast": [["W_Tree", 1.0]], "mid": [["W_Tree", 1.0], ["W_New", 2.0]], "high": [["W_New", 1.0]],
		"bush": [["W_Bush", 1.0]], "orchard": [["W_New", 1.0]]}
	ft.load_list([{"id": 1, "name": "Wood", "style": "natural", "density_per_m2": 0.01},
		{"id": 2, "name": "Orchard", "style": "grid", "pitch_m": 7.0}], pools, {"mid": ["W_Bush"]},
		func(_n: String) -> bool: return false, func(_n: String) -> bool: return false)
	var items := {3: {"species": "W_Tree"}, 4: {"species": "W_Tree"}, 5: {"species": ""}}
	var rules := [{"type": 1}, {"type": 2, "species": "W_New"}]
	var u := UseRes.of(ft.by_id, items, rules)
	_chk(r, "a type's lanes, an import rule, pinned trees (%s)" % str(u),
		u.get("W_Tree") == PackedStringArray(["Wood (coast, mid)", "pinned by 2 single trees or rows"])
		and u.get("W_New") == PackedStringArray(["Wood (mid, high)", "Orchard (grid)", "import rule 2"])
		and u.get("W_Bush") == PackedStringArray(["Wood (dead (mid), bushes)", "Orchard (bushes)"]))

	# ── on and off ──
	var fx := Fix.make(ROOT)
	var made: Array = Fix.dialog(fx, false, {"uses": func() -> Dictionary: return u})
	var d = made[0]
	var runner = made[1]
	d.select("W_Missing")
	d.set_species_enabled("W_Missing", false)
	var on_disk := ResourceLoader.load(fx["config"].resource_path, "", ResourceLoader.CACHE_MODE_IGNORE) as ForestConfig
	_chk(r, "an unused species switches off at once, written", on_disk.disabled_species == PackedStringArray(["W_Missing"]))
	d.select("W_Tree")
	_chk(r, "Used by in the panel (%s)" % str(d.find_child("UsedBy", true, false)),
		d.find_child("UsedBy", true, false) != null and (d.find_child("UsedBy", true, false) as Label).text.contains("Wood (coast, mid)"))
	d.set_species_enabled("W_Tree", false)
	_chk(r, "a used species asks first, naming what loses it",
		not d.config.disabled_species.has("W_Tree") and d.find_child("Question", true, false) != null
		and String(d.asking.get("text", "")).contains("Wood (coast, mid)"))
	d.cancel_question()
	_chk(r, "Keep it changes nothing", d.asking.is_empty() and not d.config.disabled_species.has("W_Tree"))
	d.set_species_enabled("W_Tree", false)
	d.confirm_question()
	_chk(r, "Disable switches it off", d.config.disabled_species.has("W_Tree"))
	d.set_species_enabled("W_Tree", true)
	_chk(r, "on again", not d.config.disabled_species.has("W_Tree"))

	# ── one id in two packs ──
	var twin := ForestSpecies.new()
	twin.id = "W_Bush"
	twin.mesh = ROOT + "/m/tree.tscn"
	var arr: Array[ForestSpecies] = fx["other"].species.duplicate()
	arr.append(twin)
	fx["other"].species = arr
	d.refresh_states()
	d.set_species_enabled("W_Bush", false, true)
	_chk(r, "a species in two packs is switched by its id (%d rows)" % d.rows_of("W_Bush").size(),
		d.rows_of("W_Bush").size() == 2 and not d.grows("W_Bush", fx["fixture"]) and not d.grows("W_Bush", fx["other"]))

	# ── the tile's menu ──
	d.tile_menu_action("W_Bush", d.TILE_TOGGLE)
	_chk(r, "the tile's menu switches it", not d.config.disabled_species.has("W_Bush"))
	d.tile_menu_action("W_New", d.TILE_BUILD)
	_chk(r, "and builds it", runner.calls.back()[1] == {"force": true, "only": ["W_New"]})
	runner.job.running = false
	d._process(0.0)
	d.tile_menu_action("W_Bush", d.TILE_REMOVE, fx["other"])
	var has_bush := func(pk) -> bool: return (pk.species as Array).any(func(x): return String(x.id) == "W_Bush")
	_chk(r, "a tile's Remove takes it out of the pack the tile is in, not the first that lists the id",
		not has_bush.call(fx["other"]) and has_bush.call(fx["fixture"]))
	d.undo()
	d.tile_menu_action("W_Bush", d.TILE_BUILD, fx["other"])
	_chk(r, "a tile's Build builds the pack the tile is in", runner.calls.back()[0] == [fx["other"]]
		and runner.calls.back()[1] == {"force": true, "only": ["W_Bush"]})
	d.free()
	Fix.TreeFix.rm_tree(ROOT)
	return r
