# Copyright (c) 2026 Digitzone
# SPDX-License-Identifier: MIT
@tool
class_name ForestHeightPump
extends RefCounted
## Fills a ForestHeightCache from live Terrain3D regions, off the main thread.
##
## The contract that makes off-thread placement legal (see ForestHeightCache): a
## worker never touches terrain state, only copies this pump made. The Image is
## fetched HERE, on the main thread, and handed to the pool by reference (Image is
## RefCounted, so the copy cannot race an eviction), and the float conversion (two
## 4 MB copies, ~7 ms on a 1024² region) runs on a worker so it never lands on a
## frame. A consumer asks `ensure()` for the regions a job needs, submits the job
## only once `covered()` says the copies are in, and calls `collect()` each tick.

## The copies this pump fills; consumers read it (and snapshot it for workers).
var cache := ForestHeightCache.new()
var _tdata: Object = null
var _jobs := {}          # task id -> {"loc": Vector2i, "img": Image, "path": String, "out": …}
var _wanted := {}        # Vector2i -> true, region in flight

## ── THE DISK FALLBACK ───────────────────────────────────────────────────────────
## `get_regionp` answers only for regions Terrain3D has STREAMED. Declining anything
## else would bound every consumer of this pump by the RENDERER's residency: measured
## on one island, 8 of 1024 regions are resident (~1536 m around the player) against a
## 2800 m impostor ring, so the forest's far field could not be placed at all; and,
## worse, `ForestSpawner._regions_ready` only waits for regions that read `pending`,
## so a declined region never blocks, and the cell is placed with NAN over it and then
## marked done forever.
##
## The region files are on disk whatever the renderer is holding. Measured cost of
## loading one standalone: **5.3 ms** (512², FORMAT_RF), and the float conversion on a
## worker is 0.1 ms, so the whole fetch runs on the worker and never touches a frame.
##
## What disk CANNOT give is the deform composite: a road carve lives in the runtime
## composite, and a region file holds the base hillside. That is why a live region is
## always preferred; disk is the fallback, and it only ever serves cells beyond
## streaming range, where a metre of carve is far below a pixel.
var _dir := ""           # data_directory; "": a terrain with no files, whose regions are only the ones it holds
var _disk_load := true   # load regions from their files (off: the files only say which regions exist)
var _files_known := true # the terrain has a data directory ("" included); false: what exists is unknown
var _disk := {}          # Vector2i -> file path, one directory scan
var _disk_scanned := false
## Injectable for tests. Default loads with CACHE_MODE_REPLACE: see _load_region.
var loader: Callable = Callable()
## Where copies came from, so "is the disk path too heavy?" is measurable rather
## than argued. `reload` counts a location fetched more than once, i.e. LRU thrash.
var stats := {"live": 0, "disk": 0, "absent": 0, "reload": 0}
var _ever := {}


## The terrain data to copy from, its region size and vertex spacing, how many copies to keep, its data directory
## ("": a terrain with no files), whether a region the terrain has not streamed is loaded from its file, and whether
## the terrain has a data directory at all (one with none cannot say which regions exist: they are never absent).
func configure(tdata: Object, region_size: int, vertex_spacing: float,
		max_regions: int = 16, data_dir: String = "", disk_load := true, files_known := true) -> void:
	_tdata = tdata
	cache.configure(region_size, vertex_spacing)
	cache.max_regions = max_regions
	_dir = data_dir
	_disk_load = disk_load
	_files_known = files_known
	_disk.clear()
	_disk_scanned = false


## Terrain3D names a region file `terrain3d` then each coordinate as a separator plus
## digits, where the separator IS the sign: `_` for >= 0 and `-` for negative
## (`terrain3d_00_00`, `terrain3d_00-01`, `terrain3d-16-16`). Returns null for
## anything that is not a region file, so a stray `farfield.res` in the same
## directory cannot be read as location (0, 0).
##
## Parsed rather than formatted, and the index is built by SCANNING the directory:
## a formatter that is wrong about negatives would silently map a cell to the wrong
## hillside, which is far worse than not finding the file at all.
static func parse_region_filename(fn: String) -> Variant:
	if not fn.begins_with("terrain3d") or not fn.ends_with(".res"):
		return null
	var body := fn.substr(9, fn.length() - 13)
	if body.length() < 4:
		return null
	var sx := body[0]
	if sx != "_" and sx != "-":
		return null
	var rest := body.substr(1)
	var i := 0
	while i < rest.length() and rest[i] >= "0" and rest[i] <= "9":
		i += 1
	if i == 0 or i >= rest.length():
		return null
	var xs := rest.substr(0, i)
	var sy := rest[i]
	if sy != "_" and sy != "-":
		return null
	var ys := rest.substr(i + 1)
	if ys.is_empty() or not ys.is_valid_int() or not xs.is_valid_int():
		return null
	return Vector2i(int(xs) * (-1 if sx == "-" else 1),
		int(ys) * (-1 if sy == "-" else 1))


## Test seam: supply the location -> path index instead of scanning a directory.
func set_disk_index(index: Dictionary) -> void:
	_disk = index.duplicate()
	_disk_scanned = true


func _scan_disk() -> void:
	_disk_scanned = true
	if _dir.is_empty():
		return
	var da := DirAccess.open(_dir)
	if da == null:
		return
	da.list_dir_begin()
	var f := da.get_next()
	while f != "":
		if not da.current_is_dir():
			var loc = parse_region_filename(f)
			if loc != null:
				_disk[loc] = _dir.path_join(f)
		f = da.get_next()
	da.list_dir_end()


## Copy the region under `pos` unless it is already copied or in flight. A region
## the terrain has not streamed (no regionp) is simply not requested; the caller
## retries later, exactly as it would on a NAN height.
func ensure(pos: Vector3) -> void:
	if cache.region_size <= 0:
		return
	var loc := cache.region_location(pos.x, pos.z)
	if cache.has_region(loc) or _wanted.has(loc):
		return
	var region: Object = null
	if _tdata != null and _tdata.has_method("get_regionp"):
		region = _tdata.call("get_regionp", pos)
	if region == null or not region.has_method("get_height_map"):
		# Not streamed. The file is still on disk: see the header.
		_ensure_disk(loc)
		return
	# THE COMPOSITE, NOT THE BASE. get_height_map is the untouched hillside; a road
	# carve lives in the deform composite, which is what get_height reads and the
	# cars drive on. A Terrain3D that composites deforms exposes it as
	# get_height_map_composited (aliasing the base when nothing has carved); one that
	# does not has only the base.
	var img: Image = region.call("get_height_map_composited") \
			if region.has_method("get_height_map_composited") else region.call("get_height_map")
	# Only the raw float format can be reinterpreted wholesale.
	if img == null or img.get_format() != Image.FORMAT_RF:
		return
	var job := {"loc": loc, "img": img, "path": "", "out": null}
	_wanted[loc] = true
	_note(loc, "live")
	var id := WorkerThreadPool.add_task(_run.bind(job), false, "region_height_copy")
	_jobs[id] = job


## Queue a disk fetch for a region the terrain has not streamed. A location with no
## file is genuinely off-map: it must NOT be marked wanted, or every consumer that
## waits on `pending()` would wait on it forever.
func _ensure_disk(loc: Vector2i) -> void:
	if not _disk_scanned:
		if not _files_known:
			return             # unknown: never scanned, so never absent
		_scan_disk()           # no directory scans as no files: then the terrain's own regions are all there is
	var path: String = _disk.get(loc, "")
	if path.is_empty():
		stats["absent"] = int(stats["absent"]) + 1
		return
	if not _disk_load:
		return                 # on disk but not loaded: the caller waits for the terrain to stream it
	var job := {"loc": loc, "img": null, "path": path, "out": null}
	_wanted[loc] = true
	_note(loc, "disk")
	var id := WorkerThreadPool.add_task(_run.bind(job), false, "region_height_disk")
	_jobs[id] = job


func _note(loc: Vector2i, kind: String) -> void:
	stats[kind] = int(stats[kind]) + 1
	if _ever.has(loc):
		stats["reload"] = int(stats["reload"]) + 1
	else:
		_ever[loc] = true


## Worker thread. Either converts an Image the main thread handed over (live path)
## or loads the region file itself (disk path); both end as the same float array,
## which is the cache's only install shape.
func _run(job: Dictionary) -> void:
	var img: Image = job["img"]
	if img == null:
		var r: Object = _load_region(job["path"])
		if r == null or not r.has_method("get_height_map"):
			return
		img = r.call("get_height_map_composited") \
				if r.has_method("get_height_map_composited") else r.call("get_height_map")
		if img == null or img.get_format() != Image.FORMAT_RF:
			return
	job["out"] = img.get_data().to_float32_array()


## CACHE_MODE_REPLACE, NOT IGNORE, AND NOT MAIN-THREAD LOADING. Measured headless on
## 30 region files: a load on a WORKER thread with CACHE_MODE_IGNORE retains the whole
## decompressed region (~10-13 MB) per call, unbounded (24 GB a minute in a game). The
## same load on the MAIN thread retains nothing, but a load costs ~5-15 ms, and the far
## field needs up to ~16 loads/s. REPLACE off-thread retains exactly ONE copy per unique
## region and reuses it on every later fetch: bounded by the map's region count (~1.9 GB
## for a whole island, typically only the ring's) instead of growing forever.
## (See also: godotengine/godot#59669, CACHE_MODE_IGNORE not actually ignoring.)
func _load_region(path: String) -> Object:
	if loader.is_valid():
		return loader.call(path)
	return ResourceLoader.load(path, "", ResourceLoader.CACHE_MODE_REPLACE)


## Whether the region under `pos` is copied.
func covered(pos: Vector3) -> bool:
	return cache.region_size > 0 and cache.has_region(cache.region_location(pos.x, pos.z))


## Whether the region under `pos` is in flight.
func pending(pos: Vector3) -> bool:
	return cache.region_size > 0 and _wanted.has(cache.region_location(pos.x, pos.z))


## Whether the region under `pos` is off the map: not copied, not in flight, not streamed by the terrain, and no file
## for it in the data directory. False until the directory has been scanned (`ensure` scans it): unknown is not absent.
func absent(pos: Vector3) -> bool:
	if cache.region_size <= 0 or not _disk_scanned:
		return false
	var loc := cache.region_location(pos.x, pos.z)
	if cache.has_region(loc) or _wanted.has(loc) or _disk.has(loc):
		return false
	return _tdata == null or not _tdata.has_method("get_regionp") or _tdata.call("get_regionp", pos) == null


## Install finished copies. Main thread. `block` waits for every copy in flight.
##
## A task that has been waited on is FORGOTTEN by the pool (is_task_completed on
## its id is an error afterwards), so waiting and installing are one step here;
## there is no "wait now, collect later".
func collect(block: bool = false) -> void:
	if _jobs.is_empty():
		return
	for id in _jobs.keys():
		if not block and not WorkerThreadPool.is_task_completed(id):
			continue
		WorkerThreadPool.wait_for_task_completion(id)
		var job: Dictionary = _jobs[id]
		_jobs.erase(id)
		var loc: Vector2i = job["loc"]
		_wanted.erase(loc)
		if job["out"] != null:
			cache.store(loc, job["out"])


## Wait for every in-flight copy and install it (shutdown, tests).
func drain() -> void:
	collect(true)


## Forget every copy: a terrain edit invalidates them. In-flight copies are
## waited for first so nothing stale lands afterwards.
func drop_all() -> void:
	drain()
	cache.drop_all()
