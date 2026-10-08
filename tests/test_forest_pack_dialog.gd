# Copyright (c) 2026 Digitzone
# SPDX-License-Identifier: MIT
extends RefCounted
## Forest → Build packs…, headless: the menu asks for it; the dialog lists each pack and each
## species' state; Build what's needed and Rebuild all hand the packs to the plugin's run (not forced, forced); while a
## build runs, its progress and Cancel; its report when it ends (a cancelled one says what stays); reopened while a build
## runs, it watches that build; without the overlay's components it builds from plain controls.
##
## Run with a unit-suite runner: static run() returns {name, passed, failed, details}.

const DialogRes := preload("res://addons/wuifwoud/editor/forest_pack_dialog.gd")
const MenuRes := preload("res://addons/wuifwoud/editor/forest_preview_menu.gd")
const BuildRes := preload("res://addons/wuifwoud/species/forest_pack_build.gd")
const TreeFix := preload("res://addons/wuifwoud/tests/fixtures/tree_fixture.gd")
const UX := "res://addons/terrain_3d_extended/src/ux_components.gd"
const ROOT := "user://wf_d1_dialog"


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


## The plugin's side: run() starts a (fake) build and says ""; job_of() is that build.
class Runner extends RefCounted:
	var calls: Array = []
	var job = null

	func run(packs: Array, force: bool) -> String:
		calls.append([packs.size(), force])
		job = FakeBuild.new()
		return ""

	func job_of():
		return job


static func _chk(r: Dictionary, n: String, ok: bool) -> void:
	if ok:
		r.passed += 1
	else:
		r.failed += 1
		r.details.append("✗ " + n)


static func _state(d: Control, id: String) -> String:
	var row := d.find_child("Species_" + id, true, false)
	if row == null:
		return "(no row)"
	var l := row.find_child("State", true, false) as Label
	return l.text if l != null else "(no state)"


static func _press(d: Control, nm: String) -> bool:
	var b := d.find_child(nm, true, false) as Button
	if b == null or b.disabled:
		return false
	b.pressed.emit()
	return true


static func _text(d: Control, nm: String) -> String:
	var l := d.find_child(nm, true, false) as Label
	return l.text if l != null else ""


static func run() -> Dictionary:
	var r := {"name": "forest_pack_dialog", "passed": 0, "failed": 0, "details": []}
	TreeFix.rm_tree(ROOT)
	TreeFix.scene(ROOT + "/m/tree.tscn", [TreeFix.tree_mesh(8, "Bark", "Leaves")], ["Tree"])
	var tree := TreeFix.species("W_Tree", ROOT + "/m/tree.tscn")
	var p := ForestSpeciesPack.new()
	p.name = "Fixture"
	var one: Array[ForestSpecies] = [tree]
	p.species = one
	DirAccess.make_dir_recursive_absolute(ProjectSettings.globalize_path(ROOT + "/pack"))
	ResourceSaver.save(p, ROOT + "/pack/pack.tres")
	var pack := ResourceLoader.load(ROOT + "/pack/pack.tres", "", ResourceLoader.CACHE_MODE_REPLACE) as ForestSpeciesPack
	BuildRes.new([pack]).run_now()
	var three: Array[ForestSpecies] = [tree, TreeFix.species("W_New", ROOT + "/m/tree.tscn"),
		TreeFix.species("W_Missing", ROOT + "/m/none.tscn")]
	pack.species = three
	ResourceSaver.save(pack, ROOT + "/pack/pack.tres")
	pack = ResourceLoader.load(ROOT + "/pack/pack.tres", "", ResourceLoader.CACHE_MODE_REPLACE) as ForestSpeciesPack
	var kit = load(UX) if ResourceLoader.exists(UX) else null

	# ── the menu ──
	var m = MenuRes.new()
	var asked := [false]
	m.build_requested.connect(func() -> void: asked[0] = true)
	m._on_id(MenuRes.ID_BUILD)
	var pop: PopupMenu = m.get_popup()
	_chk(r, "Forest → Build packs… asks the plugin for the dialog",
		asked[0] and pop.get_item_text(pop.get_item_index(MenuRes.ID_BUILD)) == "Build packs…")
	m.free()

	# ── the list ──
	var runner := Runner.new()
	var d = DialogRes.new()
	d.setup({"kit": kit, "packs": [pack], "run": runner.run, "job_of": runner.job_of})
	_chk(r, "each species' state: built, not built, mesh missing with why (%s, %s, %s)"
		% [_state(d, "W_Tree"), _state(d, "W_New"), _state(d, "W_Missing")],
		_state(d, "W_Tree") == "built" and _state(d, "W_New") == "not built"
		and _state(d, "W_Missing").begins_with("mesh missing: no mesh at"))
	_chk(r, "what needs building is counted (%s)" % _text(d, "Needed"),
		d.needed_count() == 1 and d.species_count() == 3 and _text(d, "Needed") == "1 of 3 species need building.")

	# ── Build what's needed; the build's progress; Cancel ──
	var pressed := _press(d, "BuildNeeded")
	_chk(r, "Build what's needed hands the packs to the plugin, not forced (%s)" % str(runner.calls),
		pressed and runner.calls == [[1, false]] and d.busy())
	_chk(r, "while it runs: its progress and phase (%s)" % _text(d, "Phase"),
		d.find_child("Progress", true, false) != null and _text(d, "Phase") == "Baking W_Tree · 1 of 3")
	_press(d, "Cancel")
	_chk(r, "Cancel cancels the build at once", runner.job.cancelled)

	# ── the report ──
	runner.job.running = false
	runner.job.report = {"built": ["W_New"], "skipped": ["W_Tree"], "failed": {"W_Missing": "no mesh at x"},
		"removed": [], "warnings": {"W_New": ["W_New ships no authored LOD chain: indirect bins all draw LOD0 (40 tri)"]},
		"cancelled": false, "ms": 1500}
	d._process(0.0)
	var rep := d.find_child("Report", true, false)
	_chk(r, "when it ends, its report: the counts, the failure, the warning (%s)" % _text(d, "Summary"),
		not d.busy() and rep != null and _text(d, "Summary") == "1 built, 1 up to date, 1 failed, 0 removed · 1.5 s"
		and rep.get_child_count() == 3)
	runner.job.report["cancelled"] = true
	d.report = runner.job.report
	d.rebuild()
	_chk(r, "a cancelled build says what stays (%s)" % _text(d, "Summary"),
		_text(d, "Summary").begins_with("Cancelled: the species built before it stay."))

	# ── Rebuild all ──
	_press(d, "RebuildAll")
	_chk(r, "Rebuild all hands the packs over forced (%s)" % str(runner.calls), runner.calls.back() == [1, true])
	d.free()

	# ── reopened while a build runs ──
	var d2 = DialogRes.new()
	d2.setup({"kit": kit, "packs": [pack], "run": runner.run, "job_of": runner.job_of})
	_chk(r, "reopened while a build runs, it watches that build", d2.busy() and d2.find_child("Progress", true, false) != null)
	d2.free()

	# ── no overlay components: plain controls ──
	var d3 = DialogRes.new()
	runner.job.running = false
	d3.setup({"kit": null, "packs": [pack], "run": runner.run, "job_of": runner.job_of})
	var bn := d3.find_child("BuildNeeded", true, false) as Button
	_chk(r, "without the overlay's components it builds from plain controls",
		bn != null and bn.text == "Build what's needed" and not bn.disabled)
	d3.free()
	TreeFix.rm_tree(ROOT)
	return r
