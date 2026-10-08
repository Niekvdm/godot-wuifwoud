# Copyright (c) 2026 Digitzone
# SPDX-License-Identifier: MIT
extends RefCounted
## Tests: the Species dialog's world in `root`: a tree mesh scene; pack "Fixture" (W_Tree built, W_New not built, W_Bush a
## bush, W_Missing whose mesh is missing) and pack "Other" (W_Other), each species its own .tres in its pack's species/,
## each pack its own file; a ForestConfig listing both, saved. And the dialog on them with a stand-in for the plugin.

const TreeFix := preload("res://addons/wuifwoud/tests/fixtures/tree_fixture.gd")
const BuildRes := preload("res://addons/wuifwoud/species/forest_pack_build.gd")
const DialogRes := preload("res://addons/wuifwoud/editor/species/forest_species_dialog.gd")
const KitRes := preload("res://addons/wuifwoud/editor/common/forest_kit.gd")
## No pack addons here.
const NO_ADDONS := "res://addons/wuifwoud/tests/fixtures"


## A build as the dialog sees it.
class FakeBuild extends RefCounted:
	var running := true
	var cancelled := false
	var report := {}
	var prog := {"phase": "bake", "species": "W_Tree", "done": 1, "total": 3}

	func is_running() -> bool:
		return running

	func cancel() -> void:
		cancelled = true

	func progress() -> Dictionary:
		return prog


## The plugin's side.
class Runner extends RefCounted:
	var calls: Array = []
	var job = null
	var picks: Array = []
	var shown: Array = []

	func run(packs: Array, options: Dictionary) -> String:
		calls.append([packs, options])
		job = FakeBuild.new()
		return ""

	func job_of():
		return job

	func pick(title: String, filters: PackedStringArray, dir: bool, on_pick: Callable) -> void:
		picks.append([title, filters, dir, on_pick])

	func show(path: String) -> void:
		shown.append(path)


static func make(root: String) -> Dictionary:
	TreeFix.rm_tree(root)
	TreeFix.scene(root + "/m/tree.tscn", [TreeFix.tree_mesh(8, "Bark", "Leaves")], ["Tree"])
	var fixture := _pack(root, "fixture", "Fixture",
		[["W_Tree", "tree"], ["W_New", "tree"], ["W_Bush", "bush"], ["W_Missing", "missing"]])
	BuildRes.new([fixture], {"only": ["W_Tree"]}).run_now()
	var other := _pack(root, "other", "Other", [["W_Other", "tree"]])
	var cfg := ForestConfig.new()
	var two: Array[ForestSpeciesPack] = [fixture, other]
	cfg.packs = two
	ResourceSaver.save(cfg, root + "/config.tres")
	cfg = ResourceLoader.load(root + "/config.tres", "", ResourceLoader.CACHE_MODE_REPLACE) as ForestConfig
	return {"config": cfg, "fixture": cfg.packs[0], "other": cfg.packs[1], "root": root}


static func _pack(root: String, dir: String, nm: String, list: Array) -> ForestSpeciesPack:
	var base := root + "/" + dir
	DirAccess.make_dir_recursive_absolute(ProjectSettings.globalize_path(base + "/species"))
	var sl: Array[ForestSpecies] = []
	for e in list:
		var s := TreeFix.species(String(e[0]), root + ("/m/none.tscn" if e[1] == "missing" else "/m/tree.tscn"))
		if e[1] == "bush":
			s.kind = "bush"
		var p := base + "/species/" + String(e[0]) + ".tres"
		ResourceSaver.save(s, p)
		sl.append(ResourceLoader.load(p, "", ResourceLoader.CACHE_MODE_REPLACE) as ForestSpecies)
	var pack := ForestSpeciesPack.new()
	pack.name = nm
	pack.species = sl
	ResourceSaver.save(pack, base + "/pack.tres")
	return ResourceLoader.load(base + "/pack.tres", "", ResourceLoader.CACHE_MODE_REPLACE) as ForestSpeciesPack


## The config's own packs, as the dialog lists them (no starter, no pack addons).
static func sources(cfg: ForestConfig) -> Array:
	return cfg.listed_sources(NO_ADDONS).filter(func(s): return String(s["kind"]) == "project")


## The dialog on world `fx`, with plain controls (or the overlay's), and the plugin's stand-in: [dialog, runner].
static func dialog(fx: Dictionary, overlay := false, extra := {}) -> Array:
	var runner := Runner.new()
	var cfg: ForestConfig = fx["config"]
	var ctx := {"kit": KitRes.new(KitRes.overlay() if overlay else null), "config": cfg,
		"config_path": cfg.resource_path, "sources_of": func() -> Array: return sources(cfg), "run": runner.run,
		"job_of": runner.job_of, "pick_file": runner.pick, "show_file": runner.show,
		"uses": func() -> Dictionary: return {}}
	ctx.merge(extra, true)
	var d = DialogRes.new()
	d.setup(ctx)
	return [d, runner]
