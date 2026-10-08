# Copyright (c) 2026 Digitzone
# SPDX-License-Identifier: MIT
extends RefCounted
## Switching species and packs off: the config lists every pack, the switched-off ones marked, and resolved_sources keeps
## the rest as before; a disabled species is in no species table and is named disabled; drop_species takes it out of
## every pool, the rest in order with their weights, and returns the pools themselves when nothing is disabled; a
## profile loads without it (each type's pools too); a single tree pinned to it grows its type's pick.
##
## Run with a unit-suite runner: static run() returns {name, passed, failed, details}.

const Veg := preload("res://addons/wuifwoud/forest_spawner.gd")
const VA := preload("res://addons/wuifwoud/forest_assets.gd")
const TypesRes := preload("res://addons/wuifwoud/forest_types.gd")
const TreeFix := preload("res://addons/wuifwoud/tests/fixtures/tree_fixture.gd")
const ROOT := "user://wf_e1_disabled"
const NO_ADDONS := "res://addons/wuifwoud/tests/fixtures"
const PROFILE := {"species": {"mid": [["W_A", 2.0], ["W_B", 1.0], ["W_C", 3.0]], "bush": [["W_B", 1.0]]},
	"dead": {"mid": ["W_B", "W_A"]},
	"types": [{"id": 1, "name": "Wood", "style": "natural", "density_per_m2": 0.01}]}


static func _chk(r: Dictionary, n: String, ok: bool) -> void:
	if ok:
		r.passed += 1
	else:
		r.failed += 1
		r.details.append("✗ " + n)


static func _pack(dir: String, ids: Array) -> ForestSpeciesPack:
	var p := ForestSpeciesPack.new()
	p.name = dir
	var sl: Array[ForestSpecies] = []
	for id in ids:
		sl.append(TreeFix.species(String(id), ROOT + "/m/tree.tscn"))
	p.species = sl
	DirAccess.make_dir_recursive_absolute(ProjectSettings.globalize_path(ROOT + "/" + dir))
	ResourceSaver.save(p, ROOT + "/" + dir + "/pack.tres")
	return ResourceLoader.load(ROOT + "/" + dir + "/pack.tres", "", ResourceLoader.CACHE_MODE_REPLACE) as ForestSpeciesPack


static func run() -> Dictionary:
	var r := {"name": "forest_disabled_species", "passed": 0, "failed": 0, "details": []}
	TreeFix.rm_tree(ROOT)
	TreeFix.scene(ROOT + "/m/tree.tscn", [TreeFix.tree_mesh(4, "Bark", "Leaves")], ["Tree"])
	var a := _pack("a", ["W_A", "W_B"])
	var b := _pack("b", ["W_C"])

	# ── the config lists every pack; resolved_sources keeps the ones that grow ──
	var cfg := ForestConfig.new()
	var two: Array[ForestSpeciesPack] = [a, b]
	cfg.packs = two
	cfg.disabled_packs = PackedStringArray([b.resource_path])
	var mine := cfg.listed_sources(NO_ADDONS).filter(func(s): return String(s["kind"]) == "project")
	_chk(r, "listed_sources lists a switched-off pack, marked (%s)" % str(mine.map(func(s): return [s["name"], s["enabled"]])),
		mine.size() == 2 and bool(mine[0]["enabled"]) and not bool(mine[1]["enabled"])
		and not bool((mine[1]["packs"] as Array)[0]["enabled"]) and (mine[1]["packs"] as Array)[0]["pack"] == b)
	var res := cfg.resolved_sources(NO_ADDONS).filter(func(s): return String(s["kind"]) == "project")
	_chk(r, "resolved_sources keeps only the packs that grow", res.size() == 1 and res[0]["packs"] == [a])
	_chk(r, "disabled_species is empty by default", ForestConfig.new().disabled_species.is_empty())

	# ── a disabled species is in no species table ──
	VA.use_packs([a, b], PackedStringArray(["W_B"]))
	_chk(r, "a disabled species is not in the species table, and is named disabled (%s)" % str(VA.species_ids()),
		VA.species_ids() == PackedStringArray(["W_A", "W_C"]) and VA.is_disabled("W_B") and not VA.has_species("W_B")
		and not VA.is_disabled("W_A") and VA.disabled_ids() == PackedStringArray(["W_B"]))

	# ── drop_species ──
	var dropped := TypesRes.drop_species(PROFILE["species"], PackedStringArray(["W_B"]))
	_chk(r, "drop_species takes it out of every pool, the rest in order with their weights (%s)" % str(dropped),
		dropped["mid"] == [["W_A", 2.0], ["W_C", 3.0]] and dropped["bush"] == [])
	_chk(r, "a pool of names (the dead) loses it too",
		TypesRes.drop_species(PROFILE["dead"], PackedStringArray(["W_B"]))["mid"] == ["W_A"])
	_chk(r, "nothing disabled: the pools themselves, untouched",
		is_same(TypesRes.drop_species(PROFILE["species"], PackedStringArray()), PROFILE["species"]))

	# ── a profile loads without it; a pin on it lets the type pick ──
	var f := FileAccess.open(ROOT + "/profile.json", FileAccess.WRITE)
	f.store_string(JSON.stringify(PROFILE))
	f.close()
	var vs = Veg.new()
	vs.profile_path = ROOT + "/profile.json"
	vs._load_profile()
	var mid: Array = vs._species["mid"]
	_chk(r, "a profile loads without the disabled species (%s)" % str(mid),
		mid.map(func(e): return String(e[0])) == ["W_A", "W_C"] and (vs._dead["mid"] as Array) == ["W_A"])
	var t: Dictionary = vs._types.get_type(1)
	_chk(r, "and each type's pool without it",
		(t["bands"]["mid"] as Array).map(func(e): return String(e[0])) == ["W_A", "W_C"])
	vs.trees.add({"kind": "tree", "at": Vector2(5, 5), "type": 1, "age": 0.0, "species": "W_B", "clear_m": 0.0,
		"edited": false})
	var items: Array = vs._items_for(Rect2(0, 0, 50, 50))
	_chk(r, "a single tree pinned to it grows its type's pick", items.size() == 1 and String(items[0]["species"]) == "")
	vs.free()
	VA.forget_packs()
	VA.reset()
	TreeFix.rm_tree(ROOT)
	return r
