# Copyright (c) 2026 Digitzone
# SPDX-License-Identifier: MIT
@tool
extends RefCounted
## One forest import run: validate the mapping; read the source, the exclusions and the terrain's regions; then
## region by region rasterise, merge with the map on disk (or the editor's unsaved copy in `edits`) so texels painted
## by hand stay, and write the result into a hidden staging folder beside the maps; then swap (every staged map renamed
## over its map, the maps nothing keeps deleted) so the maps on disk are all old or
## all new. The editor runs it on a worker (start(), then poll() every frame on the main thread, which swaps and emits
## `finished`); the headless launcher and tests on the calling thread (run_now()). Cancel, a read or a write error stop
## it before the swap and leave the maps as they were.
##
## The single trees and rows ride along: the import's points and lines merged into the editor's unsaved
## items or the file's, staged as trees.json in the same folder and swapped in the same pass, or nothing staged when
## the file would not change; a file that cannot be read whole stops the run unless painted work may be overwritten.
##
## THE WORKER touches no node and calls no editor API: files are read through ForestImport.load_fresh (a worker's own
## load() of a path answers null the second time) and staged maps are saved to ABSOLUTE paths: a save to a res://
## path runs the editor's save hook (its file system, the folding file), which is main-thread code.

## The run ended: its report (see ForestImport.run).
signal finished(report: Dictionary)

## The import itself (the pure parts).
const ForestImportRes := preload("res://addons/wuifwoud/forest_import.gd")
## The forest maps.
const ForestMapsRes := preload("res://addons/wuifwoud/forest_maps.gd")
## The exclusion zones.
const ForestExclusionsRes := preload("res://addons/wuifwoud/forest_exclusions.gd")
## The region height pump (region file names).
const ForestHeightPumpRes := preload("res://addons/wuifwoud/forest_height_pump.gd")
## The single trees and rows.
const ForestTreesRes := preload("res://addons/wuifwoud/forest_trees.gd")
## The staging folder beside the maps: hidden, so the editor's file system never lists it.
const STAGING := ".importing"

## The mapping to run.
var mapping: Dictionary
## Overwrite texels painted by hand (and drop the edits and removals of imported trees).
var discard_painted := false
## Vector2i -> Image: the editor's unsaved maps (copies), newer than the files.
var edits := {}
## The editor's unsaved trees (ForestTrees.state()), newer than the file; null: none.
var trees_edit = null
## The terrain's regions (region_meta's shape); empty: read from data_directory.
var meta := {}
## Set when the run ends.
var report := {}
var _mutex := Mutex.new()
var _progress := {"phase": "", "done": 0, "total": 0}
var _cancel := false
var _task := -1
var _running := false
var _out := {}             # what the worker found: staged maps, deletions, the report's lists


func _init(p_mapping: Dictionary, p_options := {}) -> void:
	mapping = p_mapping
	discard_painted = bool(p_options.get("discard_painted", false))
	edits = p_options.get("edits", {})
	trees_edit = p_options.get("trees")
	meta = p_options.get("meta", {})


## The staging folder of the maps folder `dir`, as an absolute path.
static func stage_dir(dir: String) -> String:
	return ProjectSettings.globalize_path(dir.path_join(STAGING))


## The unsaved paint of every live forest map reading `m`'s maps folder (ForestMaps.live_for), as copies: what Run hands
## the import, newer than the files.
static func edits_for(m: Dictionary) -> Dictionary:
	var out := {}
	for maps in ForestMapsRes.live_for(str(m.get("data_directory", "")).path_join(ForestMapsRes.FOLDER)):
		out.merge(maps.dirty_images(), true)
	return out


## The unsaved single trees and rows of the live set reading `m`'s maps folder (ForestTrees.live_for), as a state: what
## Run hands the import, newer than the file. null when none is unsaved.
static func trees_edits_for(m: Dictionary):
	for t in ForestTreesRes.live_for(str(m.get("data_directory", "")).path_join(ForestMapsRes.FOLDER)):
		if t.dirty:
			return t.state()
	return null


## On a worker; poll() lands it. A HIGH-priority task: the pool runs only threads × 0.3 low-priority tasks at once, and
## this one waits on threaded loads (load_fresh), which are low-priority tasks themselves: holding the last
## low-priority slot, it would wait forever for the slot it holds (a 6-thread machine has one).
func start() -> void:
	_running = true
	_task = WorkerThreadPool.add_task(_work, true, "forest_import")


## The main thread, every frame while it runs: true once the run has ended (the swap done, `finished` emitted).
func poll() -> bool:
	if _task < 0:
		return not _running
	if not WorkerThreadPool.is_task_completed(_task):
		return false
	WorkerThreadPool.wait_for_task_completion(_task)
	_task = -1
	_end()
	return true


## This thread, start to end: the report.
func run_now() -> Dictionary:
	_running = true
	_work()
	_end()
	return report


## Stop at the next region; the maps stay as they were.
func cancel() -> void:
	_mutex.lock()
	_cancel = true
	_mutex.unlock()


## {"phase": "read" | "regions" | "trees" | "swap" | "done", "done": regions done, "total": regions}.
func progress() -> Dictionary:
	_mutex.lock()
	var p := _progress.duplicate()
	_mutex.unlock()
	return p


## Whether the run is in flight.
func is_running() -> bool:
	return _running


func _set_progress(phase: String, done: int, total: int) -> void:
	_mutex.lock()
	_progress = {"phase": phase, "done": done, "total": total}
	_mutex.unlock()


func _cancelled() -> bool:
	_mutex.lock()
	var c := _cancel
	_mutex.unlock()
	return c


## The run up to the swap (a worker under start()): writes only `_out` and the staging folder.
func _work() -> void:
	var out := {"t0": Time.get_ticks_msec(), "errors": [], "cancelled": false, "dir": "", "staged": {}, "delete": [],
		"deleted_no_region": [], "kept_painted": [], "resampled": [], "painted_overwritten": [], "km2": {},
		"unmatched": {}, "skipped": {}, "items": {}, "trees_file": "unchanged", "trees_staged": ""}
	_out = out
	_set_progress("read", 0, 0)
	var errs := ForestImportRes.validate(mapping)
	if not errs.is_empty():
		out["errors"] = Array(errs)
		return
	var feats: Array = []
	for sp in ForestImportRes.sources_of(mapping):
		var src = JSON.parse_string(FileAccess.get_file_as_string(sp)) if FileAccess.file_exists(sp) else null
		if typeof(src) != TYPE_DICTIONARY or str(src.get("coord_space", "")) != "world":
			out["errors"] = ["%s is not world-space GeoJSON (\"coord_space\": \"world\")" % sp]
			return
		var fl = src.get("features", [])
		if typeof(fl) == TYPE_ARRAY:
			feats.append_array(fl)
	var zones: Array = []
	for zf in mapping.get("exclusions", []):
		if not FileAccess.file_exists(str(zf)):
			out["errors"] = ["%s: no such exclusions file" % zf]
			return
		var ex = ForestExclusionsRes.new()
		var zerr: Array = []
		ex.load_file(str(zf), zerr)
		if not zerr.is_empty():
			out["errors"] = zerr
			return
		zones.append_array(ex.rings())
	var m := meta if not meta.is_empty() else ForestImportRes.region_meta(str(mapping["data_directory"]))
	if m.is_empty():
		out["errors"] = ["%s holds no Terrain3D region file" % mapping["data_directory"]]
		return
	var dir := str(mapping["data_directory"]).path_join(ForestMapsRes.FOLDER)
	out["dir"] = dir
	var stage := stage_dir(dir)
	_clear_stage(stage)
	var me := DirAccess.make_dir_recursive_absolute(stage)
	if me != OK:
		out["errors"] = ["%s: the staging folder could not be made (%s)" % [stage, error_string(me)]]
		return
	var rs := int(m["region_size"])
	var w := rs / int(mapping.get("texel_vertices", 1))
	var region_m := float(rs) * float(m["vertex_spacing"])
	var sh := ForestImportRes.shapes_of(feats, mapping["rules"], zones)
	var types := ForestImportRes.rule_types(mapping["rules"])
	var texels := {}
	var on_disk := _maps_in(dir)
	var regions: Array = m["regions"]
	for loc in on_disk:
		if not regions.has(loc):
			out["deleted_no_region"].append(loc)
	for idx in regions.size():
		if _cancelled():
			out["cancelled"] = true
			return
		_set_progress("regions", idx, regions.size())
		var loc: Vector2i = regions[idx]
		var made := ForestImportRes.region_map(loc, region_m, w, sh["shapes"])
		if made != null:
			ForestImportRes.count_types(made, types, texels)
		var old: Image = edits.get(loc)
		if old == null and on_disk.has(loc):
			old = ForestImportRes.load_fresh(on_disk[loc]) as Image
			if old == null and not discard_painted:
				out["errors"] = ["%s could not be read: it may hold paint, so the import stops (Overwrite painted texels imports anyway)" % on_disk[loc]]
				return
		var was_painted := ForestImportRes.painted(old)
		var result: Image = made
		if discard_painted:
			if was_painted:
				out["painted_overwritten"].append(loc)
		else:
			result = ForestImportRes.merge_painted(old, made, w)
			if was_painted and old.get_width() != w:
				out["resampled"].append(loc)
			if was_painted and made == null and result != null:
				out["kept_painted"].append(loc)
		if result != null:
			var p := stage.path_join(Terrain3DUtil.location_to_filename(loc))
			var e := ForestMapsRes.save_map(result, p)
			if e != OK:
				out["errors"] = ["%s: %s" % [p, error_string(e)]]
				return
			out["staged"][loc] = p
		elif on_disk.has(loc):
			out["delete"].append(loc)
	_set_progress("regions", regions.size(), regions.size())
	out["km2"] = ForestImportRes.km2_of(texels, region_m / float(w))
	out["unmatched"] = ForestImportRes.unmatched_km2(sh)
	out["skipped"] = sh["skipped"]
	if _cancelled():
		out["cancelled"] = true
		return
	_set_progress("trees", 0, 0)
	_stage_trees(out, feats, zones, dir, stage)


## The single trees and rows: the import's items merged into the editor's unsaved ones (`trees_edit`)
## or the file's, staged as trees.json when the result differs from the file. Stops the run (an error in `out`) when the
## file cannot be read whole (it may hold hand-placed trees, and the editor's unsaved ones were read from it) unless
## painted work may be overwritten, or when the stage cannot be written. With the editor's unsaved trees handed in, the
## editor reads the file again after the swap (`trees_reload`) even when it is unchanged: Overwrite may have dropped them.
func _stage_trees(out: Dictionary, feats: Array, zones: Array, dir: String, stage: String) -> void:
	var made := ForestImportRes.items_of(feats, mapping["rules"], zones)
	var tpath := dir.path_join(ForestTreesRes.FILE)
	var had := FileAccess.file_exists(tpath)
	var old := {}
	if had:
		var ot = ForestTreesRes.new()
		var ok: bool = ot.load_file(tpath)
		if not ok or not ot.errors.is_empty():
			if not discard_painted:
				out["errors"] = ["%s could not be read whole (%s): it may hold hand-placed trees, so the import stops (Overwrite painted texels imports anyway)" % [tpath, "; ".join(ot.errors)]]
				return
		else:
			old = ot.state()
	if trees_edit != null:
		old = trees_edit
		out["trees_reload"] = true
	var mg := ForestImportRes.merge_items(old, made["items"], discard_painted)
	out["items"] = {"written": {"rows": mg["rows"], "trees": mg["trees"]}, "kept_edited": mg["kept_edited"],
		"skipped_removed": mg["skipped_removed"], "deleted": mg["deleted"], "cut": made["cut"], "dups": made["dups"],
		"invalid": made["invalid"], "unmatched_lines": made["unmatched_lines"], "unmatched_points": made["unmatched_points"]}
	var nt = ForestTreesRes.new()
	nt.set_state(mg["state"])
	if nt.is_empty():
		out["trees_file"] = "deleted" if had else "unchanged"
		return
	var txt: String = nt.text()
	if had and FileAccess.get_file_as_string(tpath) == txt:
		return
	var sp := stage.path_join(ForestTreesRes.FILE)
	var f := FileAccess.open(sp, FileAccess.WRITE)
	if f == null:
		out["errors"] = ["%s: %s" % [sp, error_string(FileAccess.get_open_error())]]
		return
	f.store_string(txt)
	f.close()
	out["trees_staged"] = sp
	out["trees_file"] = "written"


## The swap and the report (the main thread under start(): poll()). A run that stopped swaps nothing.
func _end() -> void:
	var out := _out
	var dir := String(out.get("dir", ""))
	var rep := {"ok": false, "errors": out.get("errors", []), "cancelled": bool(out.get("cancelled", false)),
		"written": [], "kept_painted": out.get("kept_painted", []), "deleted": [], "deleted_no_region": [],
		"resampled": out.get("resampled", []), "painted_overwritten": out.get("painted_overwritten", []),
		"km2": out.get("km2", {}), "unmatched": out.get("unmatched", {}), "skipped": out.get("skipped", {}),
		"bytes": 0, "ms": 0, "dir": dir, "items_written": {"rows": 0, "trees": 0}, "items_kept_edited": 0,
		"items_skipped_removed": 0, "items_deleted": 0, "rows_cut": 0, "items_dup_keys": 0, "items_invalid": {},
		"unmatched_lines": {}, "unmatched_points": {}, "trees_file": "unchanged", "trees_reload": false}
	var stopped: bool = rep["cancelled"] or not (rep["errors"] as Array).is_empty()
	var swap_failed := false
	if not stopped:
		_set_progress("swap", 0, 0)
		var staged: Dictionary = out["staged"]
		for loc in staged:
			var to := ProjectSettings.globalize_path(dir.path_join(Terrain3DUtil.location_to_filename(loc)))
			var e := DirAccess.rename_absolute(staged[loc], to)
			if e != OK:
				swap_failed = true
				rep["errors"].append("%s: %s (the new map stays in %s)" % [to, error_string(e), stage_dir(dir)])
				continue
			rep["written"].append(loc)
			var fa := FileAccess.open(to, FileAccess.READ)
			rep["bytes"] = int(rep["bytes"]) + (fa.get_length() if fa != null else 0)
		for loc in out["delete"]:
			DirAccess.remove_absolute(ProjectSettings.globalize_path(dir.path_join(Terrain3DUtil.location_to_filename(loc))))
			rep["deleted"].append(loc)
		for loc in out["deleted_no_region"]:
			DirAccess.remove_absolute(ProjectSettings.globalize_path(dir.path_join(Terrain3DUtil.location_to_filename(loc))))
			rep["deleted_no_region"].append(loc)
		var items: Dictionary = out.get("items", {})
		if not items.is_empty():
			rep["items_written"] = items["written"]
			rep["items_kept_edited"] = items["kept_edited"]
			rep["items_skipped_removed"] = items["skipped_removed"]
			rep["items_deleted"] = items["deleted"]
			rep["rows_cut"] = items["cut"]
			rep["items_dup_keys"] = items["dups"]
			rep["items_invalid"] = items["invalid"]
			rep["unmatched_lines"] = items["unmatched_lines"]
			rep["unmatched_points"] = items["unmatched_points"]
		var tto := ProjectSettings.globalize_path(dir.path_join(ForestTreesRes.FILE))
		var ts := String(out.get("trees_staged", ""))
		if ts != "":
			var te := DirAccess.rename_absolute(ts, tto)
			if te != OK:
				swap_failed = true
				rep["errors"].append("%s: %s (the new file stays in %s)" % [tto, error_string(te), stage_dir(dir)])
			else:
				rep["trees_file"] = "written"
		elif String(out.get("trees_file", "")) == "deleted":
			DirAccess.remove_absolute(tto)
			rep["trees_file"] = "deleted"
		rep["trees_reload"] = bool(out.get("trees_reload", false)) and (ts == "" or rep["trees_file"] == "written")
	if dir != "" and not swap_failed:
		_clear_stage(stage_dir(dir))
	rep["ok"] = not rep["cancelled"] and (rep["errors"] as Array).is_empty()
	rep["ms"] = Time.get_ticks_msec() - int(out.get("t0", Time.get_ticks_msec()))
	report = rep
	_running = false
	var total := int(_progress.get("total", 0))
	_set_progress("done", total, total)
	finished.emit(rep)


## The region maps in `dir`: location -> path.
static func _maps_in(dir: String) -> Dictionary:
	var out := {}
	if DirAccess.dir_exists_absolute(dir):
		for f in DirAccess.get_files_at(dir):
			var loc = ForestHeightPumpRes.parse_region_filename(f)
			if loc != null:
				out[loc] = dir.path_join(f)
	return out


## Removes a staging folder and what is in it (a crashed run's, or this one's after a stop).
static func _clear_stage(stage: String) -> void:
	if not DirAccess.dir_exists_absolute(stage):
		return
	for f in DirAccess.get_files_at(stage):
		DirAccess.remove_absolute(stage.path_join(f))
	DirAccess.remove_absolute(stage)
