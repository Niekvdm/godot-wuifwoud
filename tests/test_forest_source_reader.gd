# Copyright (c) 2026 Digitzone
# SPDX-License-Identifier: MIT
extends RefCounted
## ForestSourceReader: a mapping's files read on a worker (the features, the values scan,
## the geometry kinds, the exclusion zones, the terrain's regions) and its rules' shapes and areas; read by two readers
## (a worker's own load() of a path answers null the second time it is asked, so the region file is read twice on
## purpose); a rules change reads the rules only; a source changed on disk is read again; a missing or non-world
## source is an error. Two sources pooled and listed; the rules' read gains the import's items and each rule's
## metres and points; a change to the second source is read again; wait() lands a read and starts none.
##
## Run with a unit-suite runner: static run() returns {name, passed, failed, details}.

const ReaderRes := preload("res://addons/wuifwoud/forest_source_reader.gd")
const FakeRegion := preload("res://addons/wuifwoud/tests/fixtures/fake_region.gd")
const DIR := "user://wf_b2b_reader"


static func _chk(r: Dictionary, n: String, ok: bool) -> void:
	if ok:
		r.passed += 1
	else:
		r.failed += 1
		r.details.append("✗ " + n)


static func _sq(x0: float, z0: float, s: float) -> Array:
	return [[x0, z0], [x0 + s, z0], [x0 + s, z0 + s], [x0, z0 + s], [x0, z0]]


static func _feature(kind: String, coords: Array) -> Dictionary:
	return {"type": "Feature", "properties": {"kind": kind}, "geometry": {"type": "Polygon", "coordinates": coords}}


static func _write(path: String, data) -> void:
	var f := FileAccess.open(path, FileAccess.WRITE)
	f.store_string(JSON.stringify(data))
	f.close()


static func _mapping(rules: Array, source := "landuse.geojson") -> Dictionary:
	return {"schema": "wuifwoud_import/1", "source": DIR.path_join(source), "data_directory": DIR.path_join("terrain"),
		"texel_vertices": 1, "exclusions": [DIR.path_join("zones.json")], "rules": rules}


static func _settle(rd) -> bool:
	for _i in 2000:
		if rd.poll():
			return true
		OS.delay_msec(5)
	return false


## Holds one low-priority slot of the WorkerThreadPool until let go (final review: the pool runs only threads × ratio
## low-priority tasks at once, and a low-priority task that waits on a threaded load needs another slot).
class Blocker:
	var hold := true
	var running := false

	func run() -> void:
		running = true
		while hold:
			OS.delay_msec(2)


## Every low-priority slot of the thread pool but one, held: [Blocker...] and their task ids.
static func _hold_slots() -> Array:
	var t := int(ProjectSettings.get_setting("threading/worker_pool/max_threads", -1))
	if t <= 0:
		t = OS.get_processor_count()
	var ratio := float(ProjectSettings.get_setting("threading/worker_pool/low_priority_thread_ratio", 0.3))
	var slots := clampi(int(float(t) * ratio), 1, t - 1)
	var held := []
	for _i in slots - 1:
		var b := Blocker.new()
		held.append([b, WorkerThreadPool.add_task(b.run, false, "wf_b2b_slot_holder")])
	for _w in 1000:
		if held.all(func(h): return (h[0] as Blocker).running):
			break
		OS.delay_msec(2)
	return held


static func _let_go(held: Array) -> void:
	for h in held:
		(h[0] as Blocker).hold = false
	for h in held:
		WorkerThreadPool.wait_for_task_completion(h[1])


static func _clean() -> void:
	for sub in ["terrain", ""]:
		var d := DIR.path_join(sub) if sub != "" else DIR
		if DirAccess.dir_exists_absolute(d):
			for f in DirAccess.get_files_at(d):
				DirAccess.remove_absolute(ProjectSettings.globalize_path(d.path_join(f)))
			DirAccess.remove_absolute(ProjectSettings.globalize_path(d))


static func run() -> Dictionary:
	var r := {"name": "forest_source_reader", "passed": 0, "failed": 0, "details": []}
	_clean()
	DirAccess.make_dir_recursive_absolute(DIR.path_join("terrain"))
	var feats := [_feature("wood", [_sq(0, 0, 20)]), _feature("wood", [_sq(30, 0, 10)]), _feature("pitch", [_sq(0, 30, 10)]),
		{"type": "Feature", "properties": {"kind": "wood"}, "geometry": {"type": "Point", "coordinates": [1, 1]}}]
	_write(DIR.path_join("landuse.geojson"), {"type": "FeatureCollection", "coord_space": "world", "features": feats})
	_write(DIR.path_join("zones.json"), {"schema": "vegetation_exclusions/1", "coord_space": "world",
		"zones": [{"id": "z", "outer": [[0, 0], [5, 0], [5, 5], [0, 5]]}]})
	ResourceSaver.save(FakeRegion.new(), DIR.path_join("terrain").path_join("terrain3d_00_00.res"))
	var two := [{"match": {"kind": "wood"}, "type": 1}, {"match": {"kind": "park"}, "type": 3}]

	# ── the files and the rules, read on a worker ──
	var rd = ReaderRes.new()
	rd.request(_mapping(two))
	var ok1 := _settle(rd)
	var f: Dictionary = rd.files
	var sc: Dictionary = f.get("scan", {})
	_chk(r, "the files: the features, the values scan, the geometry kinds, the zones, the terrain's regions (%s)" % str(
		[f.get("kinds"), f.get("zone_counts"), f.get("meta"), f.get("errors")]),
		ok1 and rd.is_ready() and (f["features"] as Array).size() == 4 and f["world"]
		and is_equal_approx(float(sc["areas"]["kind"]["wood"]), 500.0) and int(sc["counts"]["kind"]["wood"]) == 3
		and f["kinds"] == {"Polygon": 3, "Point": 1} and f["zone_counts"] == [1] and (f["zones"] as Array).size() == 1
		and int(f["meta"].get("region_size", 0)) == 64 and (f["meta"].get("regions", []) as Array).size() == 1
		and f["meta"]["regions"][0] == Vector2i(0, 0)
		and (f["errors"] as Array).is_empty())
	_chk(r, "the rules: each rule's area by first match, the unmatched area, the shapes (%s)" % str(rd.rules.get("rule_m2")),
		rd.rules.get("rule_m2") == [500.0, 0.0] and is_equal_approx(float(rd.rules["unmatched_m2"]), 100.0)
		and not (rd.rules["shapes"] as Array).is_empty())

	# ── a rules change reads the rules only ──
	var f1: Dictionary = rd.files
	rd.request(_mapping([{"match": {"kind": "pitch"}, "type": 2}]))
	var ok2 := _settle(rd)
	_chk(r, "a rules change reads the rules again and not the files (%s)" % str(rd.rules.get("rule_m2")),
		ok2 and is_same(rd.files, f1) and rd.rules.get("rule_m2") == [100.0])

	# ── a second reader reads the same files again on a worker (the threaded loader's second time) ──
	var rd2 = ReaderRes.new()
	rd2.request(_mapping(two))
	var ok3 := _settle(rd2)
	_chk(r, "a second reader reads the same files, the region file included (%s)" % str(rd2.files.get("meta")),
		ok3 and int(rd2.files["meta"].get("region_size", 0)) == 64 and (rd2.files["features"] as Array).size() == 4)

	# ── final review: the reader finishes with every other low-priority slot of the pool busy ──
	var held := _hold_slots()
	var rd4 = ReaderRes.new()
	rd4.request(_mapping(two))
	var landed := false
	var t0 := Time.get_ticks_msec()
	while Time.get_ticks_msec() - t0 < 5000:
		if rd4.poll():
			landed = true
			break
		OS.delay_msec(5)
	_let_go(held)
	if not landed:
		_settle(rd4)
	_chk(r, "on a busy thread pool (one low-priority slot left) the reader still finishes: the region file read is not left waiting for a slot it holds (%s)" % str(landed),
		landed and int(rd4.files.get("meta", {}).get("region_size", 0)) == 64)

	# ── a source changed on disk is read again ──
	_write(DIR.path_join("landuse.geojson"), {"type": "FeatureCollection", "coord_space": "world",
		"features": [_feature("wood", [_sq(0, 0, 40)])]})
	rd.request(_mapping([{"match": {"kind": "pitch"}, "type": 2}]))
	var ok4 := _settle(rd)
	_chk(r, "a source changed on disk is read again (%d features)" % (rd.files.get("features", []) as Array).size(),
		ok4 and (rd.files["features"] as Array).size() == 1 and not is_same(rd.files, f1))

	# ── a missing or non-world source is an error ──
	_write(DIR.path_join("pixels.geojson"), {"type": "FeatureCollection", "features": feats})
	var rd3 = ReaderRes.new()
	rd3.request(_mapping(two, "missing.geojson"))
	var ok5 := _settle(rd3)
	var missing := str(rd3.files.get("errors"))
	rd3.request(_mapping(two, "pixels.geojson"))
	var ok6 := _settle(rd3)
	_chk(r, "a missing source and a non-world one are errors (%s; %s)" % [missing, str(rd3.files.get("errors"))],
		ok5 and ok6 and missing.contains("no such source") and str(rd3.files["errors"]).contains("world")
		and not rd3.files["world"])
	# ── two sources, the import's items; wait() ──
	_write(DIR.path_join("lines.geojson"), {"type": "FeatureCollection", "coord_space": "world", "features": [
		{"type": "Feature", "properties": {"kind": "tree_row", "osm_id": 7.0}, "geometry": {"type": "LineString",
			"coordinates": [[10, 20], [40, 20]]}},
		{"type": "Feature", "properties": {"kind": "tree", "osm_id": 8.0}, "geometry": {"type": "Point", "coordinates": [5, 5]}}]})
	var m5 := _mapping([{"match": {"kind": "wood"}, "type": 1}, {"match": {"kind": "tree_row"}, "type": 1}])
	m5["source"] = [DIR.path_join("landuse.geojson"), DIR.path_join("lines.geojson")]
	var rd5 = ReaderRes.new()
	rd5.request(m5)
	var ok7 := _settle(rd5)
	var srcs: Array = rd5.files.get("sources", [])
	_chk(r, "two sources: their features pooled, each listed with its features and kinds; the rules' read has the import's items and each rule's metres of lines (%s; %s; %s)" % [str(srcs), str(rd5.rules.get("items", {}).keys()), str(rd5.rules.get("rule_m"))],
		ok7 and srcs.size() == 2 and int(srcs[0]["features"]) == 1 and int(srcs[1]["features"]) == 2
		and srcs[1]["kinds"] == {"LineString": 1, "Point": 1} and (rd5.files["features"] as Array).size() == 3
		and is_equal_approx(float(rd5.rules["rule_m"][1]), 30.0) and int(rd5.rules["rule_n"][1]) == 0
		and (rd5.rules["items"] as Dictionary).keys() == ["osm_id:7"])
	_write(DIR.path_join("lines.geojson"), {"type": "FeatureCollection", "coord_space": "world", "features": [
		{"type": "Feature", "properties": {"kind": "tree_row", "osm_id": 7.0}, "geometry": {"type": "LineString",
			"coordinates": [[10, 20], [40, 20]]}},
		{"type": "Feature", "properties": {"kind": "tree_row", "osm_id": 9.0}, "geometry": {"type": "LineString",
			"coordinates": [[10, 29], [40, 29]]}}]})
	rd5.request(m5)
	var ok8 := _settle(rd5)
	_chk(r, "a change to the second source is read again (%d items)" % (rd5.rules["items"] as Dictionary).size(),
		ok8 and (rd5.rules["items"] as Dictionary).size() == 2)
	var rd6 = ReaderRes.new()
	rd6.request(m5)
	rd6.wait()
	_chk(r, "wait(): the read on a worker lands and no new one starts", rd6._task < 0 and rd6.is_ready())
	_clean()
	return r
