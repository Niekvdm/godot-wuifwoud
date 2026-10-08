# Copyright (c) 2026 Digitzone
# SPDX-License-Identifier: MIT
@tool
extends RefCounted
## A mapping's sources and exclusions, read off the main thread: the pooled features
## of every source (and each source's own count, kinds and errors), the
## values scan (key -> value -> m², and how many features), the geometry kinds, the exclusion zones and the terrain's
## regions; then, for a set of rules, the paint shapes and each rule's area. Both reads run on a worker and are kept:
## the files' by each file's modified time and size (and the terrain folder's file count), the rules' by their text,
## keyed at request(), never every frame. The import dialog and the Revert brush share one reader; poll() lands a
## finished read on the main thread.

## The import (its readers and matchers).
const ForestImportRes := preload("res://addons/wuifwoud/forest_import.gd")
## The exclusion zones.
const ForestExclusionsRes := preload("res://addons/wuifwoud/forest_exclusions.gd")

## The files' read: {"errors": [String], "features": Array, "scan": ForestImport.scan_source's, "kinds": {geometry type:
## n}, "world": bool, "zones": Array, "zone_counts": [int a file, -1: unreadable], "meta": region_meta's ({}: none),
## "sources": [{"path", "features", "kinds", "errors", "world"}]}.
var files := {}
## The rules' read: {"shapes": ForestImport.shapes_of's, "rule_m2": [m² a rule], "unmatched_m2": float, "rule_m": [m
## of lines a rule], "rule_n": [points a rule], "items": {key: item} (the import's single trees and rows, before ids)}.
var rules := {}
var _files_key := ""
var _rules_key := ""
var _want := {}            # the newest mapping asked for
var _want_keys := ["", ""]
var _task := -1
var _job := {}


## Ask for `m`'s reads: nothing when they are current; else a worker starts, or this waits for the one running.
func request(m: Dictionary) -> void:
	var keys := [files_key(m), rules_key(m)]
	if keys == _want_keys and not _want.is_empty():
		return
	_want = m.duplicate(true)
	_want_keys = keys
	_start_if_idle()


## The main thread: lands a finished read and starts the next one asked for. True when the reads are the last ask's.
func poll() -> bool:
	if _task >= 0:
		if not WorkerThreadPool.is_task_completed(_task):
			return false
		_land()
	_start_if_idle()
	return is_ready()


## Waits for the read running on a worker, if any, and lands it; starts nothing (the plugin at exit).
func wait() -> void:
	if _task >= 0:
		_land()


func _land() -> void:
	WorkerThreadPool.wait_for_task_completion(_task)
	_task = -1
	if _job.has("files"):
		files = _job["files"]
	_files_key = _job["keys"][0]
	rules = _job["rules"]
	_rules_key = _job["keys"][1]
	_job = {}


## The reads are the last ask's.
func is_ready() -> bool:
	return _task < 0 and not _want.is_empty() and _want_keys == [_files_key, _rules_key]


func _start_if_idle() -> void:
	if _task >= 0 or _want.is_empty() or _want_keys == [_files_key, _rules_key]:
		return
	_job = {"m": _want, "keys": _want_keys.duplicate(), "old": files if _want_keys[0] == _files_key else {}}
	# High priority: _work waits on a threaded load (region_meta's load_fresh), itself a low-priority task; holding the
	# last low-priority slot of the pool, it would wait forever for the slot it holds.
	_task = WorkerThreadPool.add_task(_work.bind(_job), true, "forest_source_reader")


## A worker: reads only `job` and the files; writes only `job`.
func _work(job: Dictionary) -> void:
	var f: Dictionary = job["old"]
	if f.is_empty():
		f = read_files(job["m"])
		job["files"] = f
	job["rules"] = rule_read(f, job["m"].get("rules", []))


## The files a mapping reads, as they are now: each source and zone file with its modified time and size, and the
## terrain folder with its file count (main thread, a few stats).
static func files_key(m: Dictionary) -> String:
	var parts := PackedStringArray()
	for sp in ForestImportRes.sources_of(m):
		parts.append(_stamp(str(sp)))
	for zf in m.get("exclusions", []):
		parts.append(_stamp(str(zf)))
	var dd := str(m.get("data_directory", ""))
	var n := DirAccess.get_files_at(dd).size() if dd != "" and DirAccess.dir_exists_absolute(dd) else -1
	parts.append("%s|%d" % [dd, n])
	return "\n".join(parts)


## The rules' text a paint read is keyed by.
static func rules_key(m: Dictionary) -> String:
	return JSON.stringify(m.get("rules", []))


static func _stamp(path: String) -> String:
	if path == "" or not FileAccess.file_exists(path):
		return path + "|-"
	var f := FileAccess.open(path, FileAccess.READ)
	return "%s|%d|%d" % [path, FileAccess.get_modified_time(path), f.get_length() if f != null else -1]


## A mapping's files, read (a worker runs it): see `files`.
static func read_files(m: Dictionary) -> Dictionary:
	var out := {"errors": [], "features": [], "scan": {"areas": {}, "lengths": {}, "points": {}, "counts": {},
		"features": 0}, "kinds": {}, "world": false, "zones": [], "zone_counts": [], "meta": {}, "sources": []}
	var srcs := ForestImportRes.sources_of(m)
	if srcs.is_empty():
		out["errors"].append("no source file chosen")
	var all_world := not srcs.is_empty()
	for sp in srcs:
		var row := {"path": sp, "features": 0, "kinds": {}, "errors": [], "world": false}
		if not FileAccess.file_exists(sp):
			row["errors"].append("%s: no such source file" % sp)
		else:
			var src = JSON.parse_string(FileAccess.get_file_as_string(sp))
			if typeof(src) != TYPE_DICTIONARY:
				row["errors"].append("%s is not a JSON object" % sp)
			else:
				row["world"] = str(src.get("coord_space", "")) == "world"
				if not row["world"]:
					row["errors"].append("%s is not world-space GeoJSON (\"coord_space\": \"world\")" % sp)
				var feats = src.get("features", [])
				if typeof(feats) == TYPE_ARRAY:
					out["features"].append_array(feats)
					row["features"] = (feats as Array).size()
					for ft in feats:
						var gt := "none"
						if typeof(ft) == TYPE_DICTIONARY and typeof(ft.get("geometry")) == TYPE_DICTIONARY:
							gt = str((ft["geometry"] as Dictionary).get("type", "none"))
						row["kinds"][gt] = int(row["kinds"].get(gt, 0)) + 1
						out["kinds"][gt] = int(out["kinds"].get(gt, 0)) + 1
		all_world = all_world and bool(row["world"])
		out["errors"].append_array(row["errors"])
		out["sources"].append(row)
	out["world"] = all_world
	out["scan"] = ForestImportRes.scan_source(out["features"])
	for zf in m.get("exclusions", []):
		var zerr: Array = []
		var ex = ForestExclusionsRes.new()
		if FileAccess.file_exists(str(zf)):
			ex.load_file(str(zf), zerr)
		else:
			zerr.append("%s: no such exclusions file" % zf)
		out["errors"].append_array(zerr)
		out["zones"].append_array(ex.rings())
		out["zone_counts"].append(ex.size() if zerr.is_empty() else -1)
	var dd := str(m.get("data_directory", ""))
	out["meta"] = ForestImportRes.region_meta(dd) if dd != "" else {}
	if (out["meta"] as Dictionary).is_empty():
		out["errors"].append("%s holds no Terrain3D region file" % (dd if dd != "" else "<no terrain folder>"))
	return out


## A set of rules over files already read (a worker runs it): see `rules`. A rule with no match (the import refuses
## it) never matches here.
static func rule_read(f: Dictionary, p_rules: Array) -> Dictionary:
	var safe := []
	for rl in p_rules:
		var good: bool = typeof(rl) == TYPE_DICTIONARY and typeof(rl.get("match")) == TYPE_DICTIONARY \
			and not (rl["match"] as Dictionary).is_empty()
		safe.append(rl if good else {"match": {"\u0001never": "\u0001"}, "type": 0})
	var feats: Array = f.get("features", [])
	var zones: Array = f.get("zones", [])
	var sh := ForestImportRes.shapes_of(feats, safe, zones)
	var m2 := []
	var lm := []
	var pn := []
	for arr in [m2, lm, pn]:
		arr.resize(safe.size())
	m2.fill(0.0)
	lm.fill(0.0)
	pn.fill(0)
	var unmatched := 0.0
	for ft in feats:
		if typeof(ft) != TYPE_DICTIONARY:
			continue
		var geom: Dictionary = ft["geometry"] if typeof(ft.get("geometry")) == TYPE_DICTIONARY else {}
		var props: Dictionary = ft["properties"] if typeof(ft.get("properties")) == TYPE_DICTIONARY else {}
		var polys = ForestImportRes.polygons_of(geom)
		if polys != null:
			var a := ForestImportRes.area_of(polys)
			var i := ForestImportRes.match_rule(safe, props)
			if i < 0:
				unmatched += a
			else:
				m2[i] = float(m2[i]) + a
			continue
		var lines = ForestImportRes.lines_of(geom)
		var pts = ForestImportRes.points_of(geom) if lines == null else null
		if lines == null and pts == null:
			continue
		var j := ForestImportRes.match_rule(safe, props)
		if j < 0:
			continue
		if lines != null:
			lm[j] = float(lm[j]) + ForestImportRes.length_of(lines)
		else:
			pn[j] = int(pn[j]) + (pts as Array).size()
	var by_key := {}
	for pair in ForestImportRes.items_of(feats, safe, zones)["items"]:
		by_key[pair[0]] = pair[1]
	return {"shapes": sh["shapes"], "rule_m2": m2, "unmatched_m2": unmatched, "rule_m": lm, "rule_n": pn,
		"items": by_key}
