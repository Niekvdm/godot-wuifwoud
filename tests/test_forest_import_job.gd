# Copyright (c) 2026 Digitzone
# SPDX-License-Identifier: MIT
extends RefCounted
## ForestImportJob: a run writes what the synchronous import writes; on a worker, twice, the same bytes
## (a worker's own load() of a path answers null the second time it is asked, so this runs twice on purpose); texels
## painted by hand stay and a painted map where nothing grows is kept; the editor's unsaved copies win over the files;
## a texel size change resamples the paint; an unreadable map stops the run unless painted texels may be overwritten;
## Cancel, a write error and a stale staging folder leave the maps as they were; a map whose terrain region is gone is
## deleted; the staging folder is an absolute path (the editor's save hook never runs on the worker). The single
## trees and rows staged and swapped with the maps; a run that changes nothing leaves the file byte for byte; the
## editor's unsaved trees win; a trees file with a malformed item stops the run, Overwrite replaces it; Cancel leaves
## it; nothing to keep deletes it; trees_edits_for; a second source that is not world-space.
##
## Run with a unit-suite runner: static run() returns {name, passed, failed, details}.

const ImportRes := preload("res://addons/wuifwoud/forest_import.gd")
const JobRes := preload("res://addons/wuifwoud/forest_import_job.gd")
const MapsRes := preload("res://addons/wuifwoud/forest_maps.gd")
const TreesRes := preload("res://addons/wuifwoud/forest_trees.gd")
const DIR := "user://wf_b2b_job"
const RS := 64
const META := {"regions": [Vector2i(0, 0), Vector2i(1, 0)], "region_size": RS, "vertex_spacing": 1.0}


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


static func _lf(kind: String, id: int, coords: Array) -> Dictionary:
	return {"type": "Feature", "properties": {"kind": kind, "osm_id": float(id)},
		"geometry": {"type": "LineString", "coordinates": coords}}


static func _pf(kind: String, id: int, xz: Array) -> Dictionary:
	return {"type": "Feature", "properties": {"kind": kind, "osm_id": float(id)},
		"geometry": {"type": "Point", "coordinates": xz}}


static func _write_json(path: String, data) -> void:
	var f := FileAccess.open(path, FileAccess.WRITE)
	f.store_string(JSON.stringify(data))
	f.close()


static func _mapping(texel := 1) -> Dictionary:
	return {"schema": "wuifwoud_import/1", "source": DIR.path_join("landuse.geojson"), "data_directory": DIR,
		"texel_vertices": texel, "exclusions": [], "rules": [{"match": {"kind": "wood"}, "type": 1}]}


static func _path(loc: Vector2i) -> String:
	return DIR.path_join("forest").path_join(Terrain3DUtil.location_to_filename(loc))


static func _read(loc: Vector2i) -> Image:
	if not FileAccess.file_exists(_path(loc)):
		return null
	return ResourceLoader.load(_path(loc), "", ResourceLoader.CACHE_MODE_IGNORE) as Image


## Every map file's bytes, by name.
static func _bytes() -> Dictionary:
	var out := {}
	var d := DIR.path_join("forest")
	if DirAccess.dir_exists_absolute(d):
		for f in DirAccess.get_files_at(d):
			out[f] = FileAccess.get_file_as_bytes(d.path_join(f))
	return out


static func _staging() -> bool:
	return DirAccess.dir_exists_absolute(DIR.path_join("forest").path_join(JobRes.STAGING))


static func _wait(job) -> bool:
	for _i in 2000:
		if job.poll():
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
	for sub in ["forest/" + JobRes.STAGING, "forest", ""]:
		var d := DIR.path_join(sub) if sub != "" else DIR
		if DirAccess.dir_exists_absolute(d):
			for f in DirAccess.get_files_at(d):
				DirAccess.remove_absolute(ProjectSettings.globalize_path(d.path_join(f)))
			DirAccess.remove_absolute(ProjectSettings.globalize_path(d))


static func run() -> Dictionary:
	var r := {"name": "forest_import_job", "passed": 0, "failed": 0, "details": []}
	_clean()
	DirAccess.make_dir_recursive_absolute(DIR.path_join("forest"))
	var feats := [_feature("wood", [_sq(10, 10, 20)]), _feature("pitch", [_sq(70, 10, 10)])]
	var src := FileAccess.open(DIR.path_join("landuse.geojson"), FileAccess.WRITE)
	src.store_string(JSON.stringify({"type": "FeatureCollection", "coord_space": "world", "features": feats}))
	src.close()
	var built: Dictionary = ImportRes.build(_mapping(), feats, META["regions"], RS, 1.0, [])
	var b00: PackedByteArray = (built["images"][Vector2i(0, 0)] as Image).get_data()

	# ── a run writes what the synchronous import writes ──
	ResourceSaver.save(Image.create_empty(RS, RS, false, Image.FORMAT_RGBA8), _path(Vector2i(5, 5)))
	var rep: Dictionary = JobRes.new(_mapping(), {"meta": META}).run_now()
	var m00 := _read(Vector2i(0, 0))
	_chk(r, "run_now writes the import's map for (0,0), none where nothing grows, deletes (5,5) whose region is gone, leaves no staging folder (%s)" % str(rep),
		bool(rep["ok"]) and rep["written"] == [Vector2i(0, 0)] and rep["deleted_no_region"] == [Vector2i(5, 5)]
		and m00 != null and m00.get_data() == b00 and not FileAccess.file_exists(_path(Vector2i(1, 0)))
		and not FileAccess.file_exists(_path(Vector2i(5, 5))) and not _staging()
		and is_equal_approx(float(rep["km2"].get(1, 0.0)), 400.0 / 1e6))
	_chk(r, "the staging folder is an absolute path: the editor's save hook never runs on the worker (%s)" % JobRes.stage_dir(DIR.path_join("forest")),
		JobRes.stage_dir(DIR.path_join("forest")).is_absolute_path()
		and not JobRes.stage_dir(DIR.path_join("forest")).begins_with("user:")
		and JobRes.stage_dir(DIR.path_join("forest")).ends_with(JobRes.STAGING))

	# ── on a worker, twice: the same bytes each time ──
	var first := _bytes()
	var runs := []
	for _pass in 2:
		var job = JobRes.new(_mapping(), {"meta": META})
		var seen := []
		job.finished.connect(func(rp): seen.append(rp))
		job.start()
		var done := _wait(job)
		var pr: Dictionary = job.progress()
		runs.append([done, bool(job.report.get("ok", false)), _bytes() == first, seen.size(), pr["phase"],
			pr["done"] == pr["total"], job.is_running()])
	_chk(r, "on a worker, twice: polled to the end, the same bytes as run_now, finished once, progress at its total (%s)" % str(runs),
		runs.all(func(x): return x == [true, true, true, 1, "done", true, false]))

	# ── final review: the job finishes with every other low-priority slot of the pool busy ──
	var held := _hold_slots()
	var starved = JobRes.new(_mapping(), {"meta": META})
	starved.start()
	var landed := false
	var t0 := Time.get_ticks_msec()
	while Time.get_ticks_msec() - t0 < 5000:
		if starved.poll():
			landed = true
			break
		OS.delay_msec(5)
	_let_go(held)
	if not landed:
		_wait(starved)
	_chk(r, "on a busy thread pool (one low-priority slot left) the job still finishes: its own map reads are not left waiting for a slot it holds (%s)" % str(landed),
		landed and bool(starved.report.get("ok", false)))

	# ── texels painted by hand stay; a painted map where nothing grows is kept ──
	var p00 := _read(Vector2i(0, 0))
	p00.set_pixel(3, 3, Color8(2, 90, 30, 255))
	ResourceSaver.save(p00, _path(Vector2i(0, 0)), ResourceSaver.FLAG_COMPRESS)
	var p10 := Image.create_empty(RS, RS, false, Image.FORMAT_RGBA8)
	p10.fill(Color8(0, 255, 128, 0))
	p10.set_pixel(8, 8, Color8(2, 255, 128, 255))
	ResourceSaver.save(p10, _path(Vector2i(1, 0)), ResourceSaver.FLAG_COMPRESS)
	var kr: Dictionary = JobRes.new(_mapping(), {"meta": META}).run_now()
	var k00 := _read(Vector2i(0, 0))
	var k10 := _read(Vector2i(1, 0))
	_chk(r, "a re-import keeps painted texels, the rest is the import's; a painted map where nothing grows is kept (%s)" % str(kr["kept_painted"]),
		bool(kr["ok"]) and k00 != null and k00.get_pixel(3, 3) == Color8(2, 90, 30, 255)
		and k00.get_pixel(15, 15) == Color8(1, 255, 128, 0) and k10 != null and k10.get_pixel(8, 8).a8 == 255
		and kr["kept_painted"] == [Vector2i(1, 0)] and (kr["written"] as Array).size() == 2)

	# ── the editor's unsaved copies win over the files ──
	var e00 := _read(Vector2i(0, 0))
	e00.set_pixel(20, 20, Color8(3, 255, 128, 255))
	var er: Dictionary = JobRes.new(_mapping(), {"meta": META, "edits": {Vector2i(0, 0): e00}}).run_now()
	_chk(r, "the editor's unsaved copy handed over at Run is merged and written (%s)" % str(er["errors"]),
		bool(er["ok"]) and _read(Vector2i(0, 0)).get_pixel(20, 20) == Color8(3, 255, 128, 255)
		and _read(Vector2i(0, 0)).get_pixel(3, 3) == Color8(2, 90, 30, 255))

	# ── a texel size change resamples the paint ──
	var tr: Dictionary = JobRes.new(_mapping(2), {"meta": META}).run_now()
	var t00 := _read(Vector2i(0, 0))
	_chk(r, "a texel size change: the map at the new size, its paint where it was, reported (%s)" % str(tr["resampled"]),
		bool(tr["ok"]) and t00 != null and t00.get_width() == RS / 2 and t00.get_pixel(1, 1) == Color8(2, 90, 30, 255)
		and (tr["resampled"] as Array).has(Vector2i(0, 0)))

	# ── an unreadable map stops the run, unless painted texels may be overwritten ──
	var junk := FileAccess.open(_path(Vector2i(1, 0)), FileAccess.WRITE)
	junk.store_string("not a map")
	junk.close()
	var before := _bytes()
	var ur: Dictionary = JobRes.new(_mapping(), {"meta": META}).run_now()
	_chk(r, "an unreadable map stops the run, names it, and nothing on disk changes (%s)" % str(ur["errors"]),
		not bool(ur["ok"]) and str(ur["errors"]).contains(Terrain3DUtil.location_to_filename(Vector2i(1, 0)))
		and _bytes() == before and not _staging())
	var ow: Dictionary = JobRes.new(_mapping(), {"meta": META, "discard_painted": true}).run_now()
	_chk(r, "Overwrite painted texels imports anyway: the import's maps, the overwritten paint named (%s)" % str(ow["painted_overwritten"]),
		bool(ow["ok"]) and _read(Vector2i(0, 0)).get_data() == b00 and not FileAccess.file_exists(_path(Vector2i(1, 0)))
		and ow["painted_overwritten"] == [Vector2i(0, 0)] and ow["deleted"] == [Vector2i(1, 0)])

	# ── Cancel, a write error, a stale staging folder: the maps stay as they were ──
	var p2 := _read(Vector2i(0, 0))
	p2.set_pixel(4, 4, Color8(2, 255, 128, 255))
	ResourceSaver.save(p2, _path(Vector2i(0, 0)), ResourceSaver.FLAG_COMPRESS)
	var kept_bytes := _bytes()
	var cj = JobRes.new(_mapping(2), {"meta": META})
	cj.cancel()
	var cr: Dictionary = cj.run_now()
	_chk(r, "Cancel stops before the swap: not ok, cancelled, the maps byte-identical, no staging folder (%s)" % str(cr),
		not bool(cr["ok"]) and bool(cr["cancelled"]) and _bytes() == kept_bytes and not _staging())
	var blocker := FileAccess.open(DIR.path_join("forest").path_join(JobRes.STAGING), FileAccess.WRITE)
	blocker.store_string("x")                                      # a FILE where the staging folder goes
	blocker.close()
	var wr: Dictionary = JobRes.new(_mapping(2), {"meta": META}).run_now()
	DirAccess.remove_absolute(ProjectSettings.globalize_path(DIR.path_join("forest").path_join(JobRes.STAGING)))
	_chk(r, "a write error stops before the swap and names the staging folder; the maps byte-identical (%s)" % str(wr["errors"]),
		not bool(wr["ok"]) and str(wr["errors"]).contains(JobRes.STAGING) and _bytes() == kept_bytes)
	var stale := DIR.path_join("forest").path_join(JobRes.STAGING)
	DirAccess.make_dir_recursive_absolute(stale)
	ResourceSaver.save(Image.create_empty(4, 4, false, Image.FORMAT_RGBA8), stale.path_join("terrain3d_09_09.res"))
	var sr: Dictionary = JobRes.new(_mapping(), {"meta": META}).run_now()
	_chk(r, "a stale staging folder from a crashed run is removed first (%s)" % str(sr["errors"]),
		bool(sr["ok"]) and not _staging() and not FileAccess.file_exists(_path(Vector2i(9, 9))))

	# ── the unsaved paint Run hands over ──
	var lm = MapsRes.new()
	lm.configure(RS, 1.0, DIR.path_join("forest"))
	lm.editing = true
	var li: Image = lm.edit_image(Vector2i(0, 0))
	li.set_pixel(2, 2, Color8(2, 255, 128, 255))
	lm.mark_dirty(Vector2i(0, 0))
	var other = MapsRes.new()
	other.configure(RS, 1.0, "user://wf_b2b_job_other/forest")
	other.editing = true
	other.edit_image(Vector2i(0, 0))
	other.mark_dirty(Vector2i(0, 0))
	var ed: Dictionary = JobRes.edits_for(_mapping())
	_chk(r, "edits_for: copies of the unsaved maps of every live forest reading the mapping's folder, none of another (%s)" % str(ed.keys()),
		ed.keys() == [Vector2i(0, 0)] and (ed[Vector2i(0, 0)] as Image).get_pixel(2, 2).a8 == 255
		and not is_same(ed[Vector2i(0, 0)], li))
	# ── the single trees and rows, staged and swapped with the maps ──
	_clean()
	DirAccess.make_dir_recursive_absolute(DIR.path_join("forest"))
	_write_json(DIR.path_join("landuse.geojson"), {"type": "FeatureCollection", "coord_space": "world", "features": feats})
	_write_json(DIR.path_join("lines.geojson"), {"type": "FeatureCollection", "coord_space": "world",
		"features": [_lf("tree_row", 7, [[5, 5], [45, 5]]), _pf("tree", 8, [30, 30])]})
	var tm := _mapping()
	tm["source"] = [DIR.path_join("landuse.geojson"), DIR.path_join("lines.geojson")]
	tm["rules"] = [{"match": {"kind": "wood"}, "type": 1}, {"match": {"kind": "tree_row"}, "type": 1},
		{"match": {"kind": "tree"}, "type": 1}]
	var tfile := DIR.path_join("forest").path_join("trees.json")
	var tr1: Dictionary = JobRes.new(tm, {"meta": META}).run_now()
	var tt = TreesRes.new()
	tt.configure(tfile)
	_chk(r, "a run writes the single trees and rows beside the maps, staged and swapped (%s)" % str([tr1["trees_file"], tr1["items_written"], tr1["errors"]]),
		bool(tr1["ok"]) and tr1["trees_file"] == "written" and tr1["items_written"] == {"rows": 1, "trees": 1}
		and tt.items.size() == 2 and tt.items[1]["source"] == "osm_id:7" and not _staging())
	var tb1 := FileAccess.get_file_as_bytes(tfile)
	var tr2: Dictionary = JobRes.new(tm, {"meta": META}).run_now()
	_chk(r, "run again unchanged: the trees file is left alone, byte for byte (%s)" % tr2["trees_file"],
		bool(tr2["ok"]) and tr2["trees_file"] == "unchanged" and FileAccess.get_file_as_bytes(tfile) == tb1)
	var ut = TreesRes.new()
	ut.set_state(tt.state())
	var moved: Dictionary = TreesRes.touched(ut.items[1])
	moved["points"] = PackedVector2Array([Vector2(5, 9), Vector2(45, 9)])
	ut.apply({"items": {1: moved}, "removed": ut.removed, "next_id": ut.next_id})
	var tr3: Dictionary = JobRes.new(tm, {"meta": META, "trees": ut.state()}).run_now()
	tt.configure(tfile)
	_chk(r, "the editor's unsaved trees handed over at Run are merged: the moved row stays as moved (%s)" % str(tr3["items_kept_edited"]),
		bool(tr3["ok"]) and int(tr3["items_kept_edited"]) == 1
		and (tt.items[1]["points"] as PackedVector2Array)[0] == Vector2(5, 9))
	_write_json(tfile, {"schema": "wuifwoud_trees/1", "next_id": 3, "items": [{"id": 1, "kind": "bush"}], "removed": []})
	var bad_text := FileAccess.get_file_as_string(tfile)
	var before_bad := _bytes()
	var tr4: Dictionary = JobRes.new(tm, {"meta": META}).run_now()
	_chk(r, "a trees file with a malformed item stops the run (it may hold hand-placed trees) and names it; nothing on disk changes (%s)" % str(tr4["errors"]),
		not bool(tr4["ok"]) and str(tr4["errors"]).contains("trees.json") and FileAccess.get_file_as_string(tfile) == bad_text
		and _bytes() == before_bad and not _staging())
	var tr4b: Dictionary = JobRes.new(tm, {"meta": META, "trees": ut.state()}).run_now()
	_chk(r, "the same stop when the editor hands in unsaved trees (final review #2): they came from that file (%s)" % str(tr4b["errors"]),
		not bool(tr4b["ok"]) and str(tr4b["errors"]).contains("trees.json") and FileAccess.get_file_as_string(tfile) == bad_text
		and _bytes() == before_bad and not _staging())
	var tr5: Dictionary = JobRes.new(tm, {"meta": META, "discard_painted": true}).run_now()
	_chk(r, "Overwrite painted texels replaces it with the import's (%s)" % tr5["trees_file"],
		bool(tr5["ok"]) and tr5["trees_file"] == "written" and FileAccess.get_file_as_bytes(tfile) == tb1)
	# Overwrite with the editor's unsaved move handed in (final review #4): the result is the file as it is, so nothing is
	# staged, and the editor still reads it again, or its unsaved move would be saved back.
	var uw = TreesRes.new()
	uw.configure(tfile)
	uw.apply({"items": {1: moved}, "removed": uw.removed, "next_id": uw.next_id})
	var tr5b: Dictionary = JobRes.new(tm, {"meta": META, "trees": uw.state(), "discard_painted": true}).run_now()
	var reached: int = TreesRes.imported(tr5b)
	_chk(r, "Overwrite with the editor's unsaved trees: the file stays the import's and the editor reads it again, the unsaved move gone (%s; %d reached)" % [
		tr5b["trees_file"], reached],
		bool(tr5b["ok"]) and tr5b["trees_file"] == "unchanged" and bool(tr5b.get("trees_reload", false)) and reached >= 1
		and not uw.dirty and uw.text() == FileAccess.get_file_as_string(tfile) and FileAccess.get_file_as_bytes(tfile) == tb1)
	var cj2 = JobRes.new(tm, {"meta": META})
	cj2.cancel()
	var crt: Dictionary = cj2.run_now()
	_chk(r, "Cancel leaves the trees file as it was (%s)" % str(crt["cancelled"]),
		bool(crt["cancelled"]) and crt["trees_file"] == "unchanged" and FileAccess.get_file_as_bytes(tfile) == tb1)
	var tm0 := tm.duplicate(true)
	tm0["rules"] = [{"match": {"kind": "wood"}, "type": 1}]
	var tr6: Dictionary = JobRes.new(tm0, {"meta": META}).run_now()
	_chk(r, "nothing left to keep: the import deletes the trees file (%s)" % tr6["trees_file"],
		bool(tr6["ok"]) and tr6["trees_file"] == "deleted" and int(tr6["items_deleted"]) == 2 and not FileAccess.file_exists(tfile))
	var lt = TreesRes.new()
	lt.configure(tfile)
	lt.add({"kind": "tree", "at": Vector2(9, 9), "type": 1, "age": 0.0, "species": "", "clear_m": 3.0, "edited": false})
	var ot = TreesRes.new()
	ot.configure("user://wf_b2c_job_other/forest/trees.json")
	ot.add({"kind": "tree", "at": Vector2(1, 1), "type": 1, "age": 0.0, "species": "", "clear_m": 3.0, "edited": false})
	var te2 = JobRes.trees_edits_for(tm)
	_chk(r, "trees_edits_for: the unsaved state of the live set reading the mapping's maps folder, none of another (%s)" % str(te2),
		te2 != null and (te2["items"] as Dictionary).size() == 1 and JobRes.trees_edits_for({"data_directory": "user://wf_b2c_nowhere"}) == null)
	_write_json(DIR.path_join("pixels.geojson"), {"type": "FeatureCollection", "features": []})
	var tm2 := tm.duplicate(true)
	tm2["source"] = [DIR.path_join("landuse.geojson"), DIR.path_join("pixels.geojson")]
	var tr7: Dictionary = JobRes.new(tm2, {"meta": META}).run_now()
	_chk(r, "a second source that is not world-space is refused, by name (%s)" % str(tr7["errors"]),
		not bool(tr7["ok"]) and str(tr7["errors"]).contains("pixels.geojson"))
	_clean()
	return r
