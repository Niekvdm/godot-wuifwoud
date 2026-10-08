# Copyright (c) 2026 Digitzone
# SPDX-License-Identifier: MIT
extends RefCounted
## The Species dialog, headless: a row per pack with its counts and its species' tiles (the first pack open); the
## filters and the search narrow the tree and open the rows with a match; a pack switched off is written to the config
## and undone and redone; the selected species survives its pack switched off; a failed write is said and undone, the
## undo stack unchanged; Build what's needed, Rebuild all, Build this pack and a species' Build hand the plugin what they
## should; the build's progress and Cancel; its report; reopened while a build runs it watches it; Esc closes.
##
## Run with a unit-suite runner: static run() returns {name, passed, failed, details}.

const Fix := preload("res://addons/wuifwoud/tests/fixtures/species_fixture.gd")
const ROOT := "user://wf_e1_dialog"


static func _chk(r: Dictionary, n: String, ok: bool) -> void:
	if ok:
		r.passed += 1
	else:
		r.failed += 1
		r.details.append("✗ " + n)


static func _text(d: Control, nm: String) -> String:
	var l := d.find_child(nm, true, false) as Label
	return l.text if l != null else ""


static func _tiles(d: Control, pack: String) -> Array:
	var row := d.find_child("Pack_" + pack, true, false)
	var flow := row.find_child("Tiles", true, false) if row != null else null
	return flow.get_children().map(func(t): return String(t.id)) if flow != null else []


static func run() -> Dictionary:
	var r := {"name": "forest_species_dialog", "passed": 0, "failed": 0, "details": []}
	var fx := Fix.make(ROOT)
	var made: Array = Fix.dialog(fx)
	var d = made[0]
	var runner = made[1]

	# ── the tree ──
	var fixture_row: Node = d.find_child("Pack_Fixture", true, false)
	_chk(r, "a row per pack, its counts (%s)" % (_text(fixture_row, "Counts") if fixture_row != null else "none"),
		fixture_row != null and d.find_child("Pack_Other", true, false) != null
		and _text(fixture_row, "Counts") == "4 · 4 on · 2 to build")
	_chk(r, "the first pack open with its species' tiles, the second closed (%s)" % str(_tiles(d, "Fixture")),
		_tiles(d, "Fixture") == ["W_Tree", "W_New", "W_Bush", "W_Missing"] and _tiles(d, "Other") == [])
	d.set_filter("bushes")
	_chk(r, "the Bushes filter: the bush only, the other pack hidden",
		_tiles(d, "Fixture") == ["W_Bush"] and d.find_child("Pack_Other", true, false) == null)
	d.set_filter("all")
	d.search_changed("other")
	d._apply_search()
	_chk(r, "the search narrows and opens the rows with a match", _tiles(d, "Other") == ["W_Other"]
		and d.find_child("Pack_Fixture", true, false) == null)
	d.search_changed("")
	d._apply_search()

	# ── a pack switched off: written, undone, redone ──
	var other_path: String = fx["other"].resource_path
	d.select("W_Other")
	d.set_pack_enabled(d.sources[1], fx["other"], false)
	var on_disk := ResourceLoader.load(fx["config"].resource_path, "", ResourceLoader.CACHE_MODE_IGNORE) as ForestConfig
	_chk(r, "switching a pack off writes the config", on_disk.disabled_packs.has(other_path)
		and d.config.disabled_packs.has(other_path))
	_chk(r, "the selected species survives its pack switched off (%s)" % _text(d, "SpeciesName"),
		d.selected == "W_Other" and _text(d, "SpeciesName") == "W Other")
	d.undo()
	on_disk = ResourceLoader.load(fx["config"].resource_path, "", ResourceLoader.CACHE_MODE_IGNORE) as ForestConfig
	_chk(r, "undo puts it back on, on disk too", not on_disk.disabled_packs.has(other_path))
	d.redo()
	_chk(r, "redo switches it off again", d.config.disabled_packs.has(other_path))
	d.undo()

	# ── a failed write ──
	var depth: int = d._undo.size()
	var keep_path: String = d.config_path
	d.config.resource_path = ""
	d.config_path = ROOT + "/no/such/folder/config.tres"
	d.set_pack_enabled(d.sources[1], fx["other"], false)
	_chk(r, "a failed write is said and undone, the undo stack unchanged (%s)" % d.error,
		d.error.begins_with("Could not write") and not d.config.disabled_packs.has(other_path) and d._undo.size() == depth)
	d.config_path = keep_path
	d.config.take_over_path(keep_path)
	d.error = ""

	# ── building ──
	d.build_needed()
	_chk(r, "Build what's needed: the packs that grow, not forced (%s)" % str(runner.calls.back()[1]),
		runner.calls.back()[0] == [fx["fixture"], fx["other"]] and runner.calls.back()[1] == {"force": false})
	_chk(r, "while it runs: its progress and phase (%s)" % _text(d, "Phase"),
		d.busy() and d.find_child("Progress", true, false) != null and _text(d, "Phase") == "Baking W_Tree · 1 of 3")
	d.set_pack_enabled(d.sources[1], fx["other"], false)
	_chk(r, "read-only while it runs", d.error == d.READ_ONLY and not d.config.disabled_packs.has(other_path))
	d.error = ""
	d.cancel_run()
	_chk(r, "Cancel cancels it", runner.job.cancelled)
	runner.job.running = false
	runner.job.report = {"built": ["W_New"], "skipped": ["W_Tree"], "failed": {"W_Missing": "no mesh at x"},
		"removed": [], "warnings": {}, "cancelled": false, "ms": 1500}
	d._process(0.0)
	_chk(r, "its report when it ends (%s)" % _text(d, "Summary"),
		not d.busy() and _text(d, "Summary") == "1 built, 1 up to date, 1 failed, 0 removed · 1.5 s")
	d.rebuild_all()
	_chk(r, "Rebuild all: forced", runner.calls.back()[1] == {"force": true})
	runner.job.running = false
	d._process(0.0)
	d.build_pack(fx["other"])
	_chk(r, "Build this pack: that pack", runner.calls.back()[0] == [fx["other"]] and runner.calls.back()[1] == {"force": false})
	runner.job.running = false
	d._process(0.0)
	d.build_species("W_New")
	_chk(r, "a species' Build: its pack, that species, forced",
		runner.calls.back()[0] == [fx["fixture"]] and runner.calls.back()[1] == {"force": true, "only": ["W_New"]})
	d.free()

	# ── reopened while a build runs; Esc ──
	var again: Array = Fix.dialog(fx, true, {"run": runner.run, "job_of": runner.job_of})
	var d2 = again[0]
	_chk(r, "reopened while a build runs, it watches that build", d2.busy())
	var closed := [false]
	d2.closed.connect(func() -> void: closed[0] = true)
	var esc := InputEventKey.new()
	esc.keycode = KEY_ESCAPE
	esc.pressed = true
	d2._input(esc)
	_chk(r, "Esc closes it", closed[0])
	if not d2.is_queued_for_deletion():
		d2.free()
	Fix.TreeFix.rm_tree(ROOT)
	return r
