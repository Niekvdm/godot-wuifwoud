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
var _jobs := {}          # task id -> {"loc": Vector2i, "img": Image, "bytes": PackedByteArray, "res": region, "out": …}
var _loads := {}         # region file path -> {"loc": Vector2i, "seen": µs it first read loaded, -1 before}
var _queue: Array = []   # [path, Vector2i]: disk loads wanted, waiting for a slot (MAX_LOADS)
var _wanted := {}        # Vector2i -> true, region in flight (loading or converting)

## ── THE DISK FALLBACK ───────────────────────────────────────────────────────────
## `get_regionp` answers only for regions Terrain3D has STREAMED. Declining anything
## else would bound every consumer of this pump by the RENDERER's residency: measured
## on one island, 8 of 1024 regions are resident (~1536 m around the player) against a
## 2800 m impostor ring, so the forest's far field could not be placed at all; and,
## worse, `ForestSpawner._regions_ready` waits only for regions that read `pending` (and a
## cell's centre region unless it is off the map), so a declined region elsewhere in the cell
## never blocks, and the cell is placed with NAN over it and then marked done forever.
##
## The region files are on disk whatever the renderer is holding. Measured cost of
## loading one standalone: **5.3 ms** (512², FORMAT_RF), so it never runs on a frame:
## the threaded loader reads it (requested here, see _load_region) and the float
## conversion runs on a worker like a live region's.
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
## Injectable for tests: path -> the region (or null), called on the main thread in place of the threaded loader
## (by `collect()`, so the region reads pending until then). See _load_region.
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
	var img := _height_image(region)
	if img == null:
		return
	var job := {"loc": loc, "img": img, "bytes": null, "out": null}
	_wanted[loc] = true
	_note(loc, "live")
	var id := WorkerThreadPool.add_task(_run.bind(job), false, "region_height_copy")
	_jobs[id] = job


## A region's height map as the copy wants it, or null.
## THE COMPOSITE, NOT THE BASE. get_height_map is the untouched hillside; a road
## carve lives in the deform composite, which is what get_height reads and the
## cars drive on. A Terrain3D that composites deforms exposes it as
## get_height_map_composited (aliasing the base when nothing has carved); one that
## does not has only the base. Only the raw float format can be reinterpreted wholesale.
static func _height_image(region: Object) -> Image:
	if region == null or not region.has_method("get_height_map"):
		return null
	var img: Image = region.call("get_height_map_composited") \
			if region.has_method("get_height_map_composited") else region.call("get_height_map")
	if img == null or img.get_format() != Image.FORMAT_RF:
		return null
	return img


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
	_wanted[loc] = true
	_note(loc, "disk")
	_queue.append([path, loc])
	_start_loads()


## Request queued disk loads while fewer than MAX_LOADS are in flight. A load refused
## by the loader is no longer wanted, so a later ensure asks again.
func _start_loads() -> void:
	while not _queue.is_empty() and _loads.size() < MAX_LOADS:
		var q: Array = _queue.pop_front()
		if loader.is_valid() or _load_region(q[0]):
			_loads[q[0]] = {"loc": q[1], "seen": -1}
		else:
			_wanted.erase(q[1])


func _note(loc: Vector2i, kind: String) -> void:
	stats[kind] = int(stats[kind]) + 1
	if _ever.has(loc):
		stats["reload"] = int(stats["reload"]) + 1
	else:
		_ever[loc] = true


## Worker thread. Converts what the main thread handed over: a live region's Image, or
## a disk region's height bytes, taken on the main thread (the worker never reads the
## region: a concurrent request may share it with the terrain); both end as the same
## float array, which is the cache's only install shape. A disk region's last
## reference is dropped here, so its other maps (~8 MB at 1024², ~75 µs to free) are
## freed off the main thread.
func _run(job: Dictionary) -> void:
	job["res"] = null
	var bytes = job["bytes"]
	if bytes == null:
		job["out"] = (job["img"] as Image).get_data().to_float32_array()
		return
	job["bytes"] = null
	job["out"] = (bytes as PackedByteArray).to_float32_array()


## THE THREADED LOADER, REQUESTED ON THE MAIN THREAD, NEVER A load() ON A WORKER.
## Measured headless on 12 region files (Godot 4.8), every reference dropped after: a
## load() inside a WorkerThreadPool task retains the whole decompressed region (~11 MB)
## for the rest of the run, with CACHE_MODE_REPLACE (still cached) and IGNORE (not
## cached) alike, and so does load_threaded_request + load_threaded_get from a task. In
## a pool task load() becomes a load task of its own; the caller, waiting, runs it
## itself, and the pool's own run of it later drops the last reference to the load's
## token without freeing it, which keeps the task and its resource alive. A blocking
## load_threaded_get on the main thread while the pool has not started the load does
## the same. A request here, polled by `collect()` and taken once loaded, retains
## nothing, and the main thread pays only the polls and the taking (the region itself
## is freed on the conversion's worker, see _run). CACHE_MODE_REUSE: a region the
## cache already holds (a body the terrain keeps) is not read again, and nothing the
## terrain holds is overwritten (the REPLACE this used to load with would have copied
## the file over such a region). A concurrent request of the same path (the terrain's
## streamer) shares the load and its object, which is only read here.
func _load_region(path: String) -> bool:
	var e := ResourceLoader.load_threaded_request(path, "", false, ResourceLoader.CACHE_MODE_REUSE)
	return e == OK


## Land the disk loads that finished: each region's height bytes go to a worker for the
## conversion, which drops the region; queued loads take the freed slots. `block` waits
## for every load in flight or queued.
##
## A load is taken on a LATER call than the one that first read it loaded, at least
## TAKE_AFTER_US on: the loader marks a load done before its pool task lets go of its
## token, and a get between the two leaves the token (and the region) alive for good.
func _land_loads(block: bool) -> void:
	_land_some(block)
	_start_loads()
	while block and not _loads.is_empty():
		_land_some(true)
		_start_loads()


func _land_some(block: bool) -> void:
	for path in _loads.keys():
		var entry: Dictionary = _loads[path]
		var r: Object = null
		if loader.is_valid():
			r = loader.call(path)
		else:
			var st := ResourceLoader.load_threaded_get_status(path)
			while block and st == ResourceLoader.THREAD_LOAD_IN_PROGRESS:
				OS.delay_usec(500)
				st = ResourceLoader.load_threaded_get_status(path)
			if st == ResourceLoader.THREAD_LOAD_IN_PROGRESS:
				continue
			if st == ResourceLoader.THREAD_LOAD_LOADED:
				var now := Time.get_ticks_usec()
				if int(entry["seen"]) < 0:
					entry["seen"] = now
				var wait := TAKE_AFTER_US - (now - int(entry["seen"]))
				if wait > 0:
					if not block:
						continue
					OS.delay_usec(wait)
			r = ResourceLoader.load_threaded_get(path)   # a failed load is taken too: an untaken request stays pinned
		_loads.erase(path)
		var loc: Vector2i = entry["loc"]
		var img := _height_image(r)
		if img == null:
			_wanted.erase(loc)   # unreadable: a later ensure asks again
			continue
		var job := {"loc": loc, "img": null, "bytes": img.get_data(), "res": r, "out": null}
		img = null
		r = null                 # the job holds the region now: the worker drops it
		var id := WorkerThreadPool.add_task(_run.bind(job), false, "region_height_disk")
		_jobs[id] = job


## See _land_loads.
const TAKE_AFTER_US := 1000
## Disk loads in flight at once; the rest wait in a queue (wanted, so they read pending).
## A status poll costs the main thread ~5 µs a load a frame, and the pool runs only a
## few low-priority tasks at once anyway.
const MAX_LOADS := 8


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
## there is no "wait now, collect later". Disk loads that finished go to their
## conversion first (_land_loads).
func collect(block: bool = false) -> void:
	if not _loads.is_empty() or not _queue.is_empty():
		_land_loads(block)
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


## A pump let go with work in flight (its consumer rebuilt) still takes every load it
## requested (an untaken threaded load keeps its region for good) and waits for its
## conversions, which run its own method.
func _notification(what: int) -> void:
	if what != NOTIFICATION_PREDELETE:
		return
	if not loader.is_valid():
		for path in _loads:
			while ResourceLoader.load_threaded_get_status(path) == ResourceLoader.THREAD_LOAD_IN_PROGRESS:
				OS.delay_usec(500)
			OS.delay_usec(TAKE_AFTER_US)
			ResourceLoader.load_threaded_get(path)
	_loads.clear()
	_queue.clear()
	for id in _jobs:
		WorkerThreadPool.wait_for_task_completion(id)
	_jobs.clear()
