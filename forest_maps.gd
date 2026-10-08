# Copyright (c) 2026 Digitzone
# SPDX-License-Identifier: MIT
@tool
class_name ForestMaps
extends RefCounted
## The forest maps: one RGBA8 Image per Terrain3D region, saved in `directory` under the
## region's own file name. R is the forest type (0: none), G the density share (255: all of the type's density), B the
## age (128: neutral), A reserved (0). A map is w texels square with w = region_size / t, t (vertices a texel) one of
## ALLOWED_T and read from the map itself; each map has its own t, and every map is read at its own size whatever
## order the maps arrive in (that order follows the camera: a forest that depended on it would differ between two
## peers with the same maps). A region without a map has no forest.
##
## THE READ PATH: the threaded loader, requested on the main thread (a worker's own load() of a path answers null the
## second time it is asked), then a WorkerThreadPool task checks the map and builds its BLOCK SUMMARY:
## the type ids present per BLOCK_M block. A map is held only while the forest asks for it (`keep_only`), within
## `budget_mb`. The forest's scatter workers get `view()`s and summaries and read nothing else; every member here is
## main-thread state.
##
## EDIT MODE (the editor only): `edit_image` hands the Forest tools a region's map as an Image
## (the held one, the file read at once, or a new blank map where the terrain has a region), held and never released;
## `refresh` puts an edit back into the held bytes and the touched blocks' summary; dirty maps are saved by
## `save_dirty` (the editor plugin calls it with the scene save) and listed per scene for the unsaved prompt.
##
## AN IMPORT rewrites the folder off the main thread; `imported(report)` then reaches every live
## instance reading it (a scene tab in the background too, out of the tree), which drops its held and edited maps of
## the regions the import touched and moves `generation` on (the forest regrows; older strokes no longer undo).

## The maps' folder beside the terrain's region files.
const FOLDER := "forest"
## The texel sizes a map may have (vertices a texel).
const ALLOWED_T := [1, 2, 4, 8]
## The block summary's block, in metres.
const BLOCK_M := 64.0
## A texel where nothing grows: type 0, full density, neutral age.
const NONE_PX := [0, 255, 128, 0]
## The resource id every map is saved with: a saved image otherwise embeds a random one, so the same map
## written twice, or at another path, would differ byte for byte.
const SCENE_ID := "forest_map"
## The forest's log, through its sink.
const ForestLogRes := preload("res://addons/wuifwoud/forest_log.gd")
## The region height pump (region file names).
const ForestHeightPumpRes := preload("res://addons/wuifwoud/forest_height_pump.gd")
## The native core, reached by class name.
const ForestNativeRes := preload("res://addons/wuifwoud/forest_native.gd")

## Vertices a region side.
var region_size := 0
## Metres between vertices.
var vertex_spacing := 1.0
## Where the map files are; "" for none (tests adopt theirs)
var directory := ""
## Held maps at most (the forest always lets its first waiting cell's in)
var budget_mb := 64.0
## The profile's type ids: what the summary looks for.
var type_ids := PackedInt32Array()
## Maps refused by their checks, named once each.
var errors: PackedStringArray = []
## Map reads: loaded, reloaded, refused, and the most held at once.
var stats := {"loaded": 0, "reloads": 0, "bad": 0, "peak_held": 0, "peak_bytes": 0}

var _files := {}           # Vector2i -> path (one directory scan)
var _scanned := false
var _held := {}            # Vector2i -> {"w": int, "data": PackedByteArray, "blocks": Dictionary}
var _adopted := {}         # Vector2i -> true: given by adopt(), never released
var _loading := {}         # Vector2i -> path, in the threaded loader
var _summing := {}         # task id -> {"loc", "img", "rs", "rm", "ids", "out"}
var _summing_at := {}      # Vector2i -> task id
var _bad := {}             # Vector2i -> true: refused by its checks; no forest there, never asked for again
var _ever := {}            # Vector2i -> true: held at least once (stats.reloads)
var _unknown_warned := {}  # type id -> true
var _largest_w := 0        # the widest map held since configure(): what the budget counts in; 0 before any
## The editor: maps the Forest tools write. Off in the game.
var editing := false
## Whether the terrain has a region at a location: an edit there makes a map. Unset: every location has one (tests).
var region_exists := Callable()
## The scene the forest is saved in: the unsaved prompt asks per scene.
var scene_path := ""
var _images := {}          # Vector2i -> Image: the editable maps (editing); held, never released
var _dirty := {}           # Vector2i -> true: changed since the last save
static var _unsaved: Array = []   # WeakRef of every instance with unsaved changes
## Moves on every import that rewrote this folder; a stroke recorded before it no longer undoes.
var generation := 0
## location -> path of a map file that could not be read. Never replaced by a blank map, so
## a save cannot overwrite it.
var unreadable := {}
## () -> the scene's path now (Save As and a first save move it); unset: scene_path.
var scene_of := Callable()
static var _live: Array = []      # WeakRef of every configured instance: an import's catch-up reaches them all


## The terrain's region size and vertex spacing and the maps' folder; the held maps are dropped.
func configure(p_region_size: int, p_vertex_spacing: float, p_directory: String) -> void:
	drain()
	region_size = p_region_size
	vertex_spacing = p_vertex_spacing
	directory = p_directory
	_largest_w = 0
	errors.clear()
	_files.clear()
	_scanned = false
	_held.clear()
	_adopted.clear()
	_bad.clear()
	_images.clear()
	_dirty.clear()
	unreadable.clear()
	_register()


## Whether configure has run.
func configured() -> bool:
	return region_size > 0


## A region's side in metres.
func region_m() -> float:
	return float(region_size) * vertex_spacing


## The region under world (x, z).
func location_of(x: float, z: float) -> Vector2i:
	var rm := region_m()
	return Vector2i(floori(x / rm), floori(z / rm))


## The map file of the region at `loc`.
func path_for(loc: Vector2i) -> String:
	return directory.path_join(Terrain3DUtil.location_to_filename(loc)) if directory != "" else ""


## Every region with a map: the folder's files (one scan) and adopted maps, less those refused by their checks.
func locations() -> Array[Vector2i]:
	_scan()
	var out: Array[Vector2i] = []
	for loc in _files:
		if not _bad.has(loc):
			out.append(loc)
	for loc in _adopted:
		if not _files.has(loc):
			out.append(loc)
	for loc in _images:
		if not _files.has(loc) and not _adopted.has(loc):
			out.append(loc)
	return out


## How many map files the folder holds.
func file_count() -> int:
	_scan()
	return _files.size()


## Whether the region at `loc` has a map (held, adopted, or a file on disk its checks did not refuse).
func has_map(loc: Vector2i) -> bool:
	if _adopted.has(loc) or _images.has(loc):
		return true
	_scan()
	return _files.has(loc) and not _bad.has(loc)


## Whether the map of `loc` is held.
func is_held(loc: Vector2i) -> bool:
	return _held.has(loc)


## Whether the map of `loc` is being read.
func is_pending(loc: Vector2i) -> bool:
	return _loading.has(loc) or _summing_at.has(loc)


## The map of `loc` as it is now, without reading a file: the editor's image when it edits it, else the
## held or adopted bytes as an Image; null when neither (read its file: file_of).
func image_now(loc: Vector2i) -> Image:
	if _images.has(loc):
		return _images[loc]
	if _held.has(loc):
		var w: int = _held[loc]["w"]
		return Image.create_from_data(w, w, false, Image.FORMAT_RGBA8, _held[loc]["data"])
	return null


## The map file of `loc`; "" when it has none, or the forest refused it by its checks.
func file_of(loc: Vector2i) -> String:
	_scan()
	return String(_files.get(loc, "")) if not _bad.has(loc) else ""


func _scan() -> void:
	if _scanned:
		return
	_scanned = true
	if directory == "" or not DirAccess.dir_exists_absolute(directory):
		return
	for f in DirAccess.get_files_at(directory):
		var loc = ForestHeightPumpRes.parse_region_filename(f)
		if loc != null:
			_files[loc] = directory.path_join(f)


## Tests and tools: `img` IS this region's map (no file is read for it); held at once and never released.
func adopt(loc: Vector2i, img: Image) -> void:
	var s := summarise(img, loc, region_size, region_m(), type_ids)
	if String(s["error"]) != "":
		_error(loc, "%s %s" % [str(loc), s["error"]])
		return
	_hold(loc, s)
	_adopted[loc] = true
	_bad.erase(loc)


## Start reading a region's map, unless it is held, in flight, adopted, refused, or has none.
func request(loc: Vector2i) -> void:
	if _held.has(loc) or is_pending(loc) or _adopted.has(loc) or _images.has(loc) or not has_map(loc):
		return
	var path: String = _files[loc]
	var e := ResourceLoader.load_threaded_request(path, "", false, ResourceLoader.CACHE_MODE_IGNORE)
	if e != OK:
		_error(loc, "%s: the loader refused it (%s)" % [path, error_string(e)])
		return
	_loading[loc] = path


## Land what finished: a loaded map goes to a worker for its checks and summary; a summarised one is held. `block`
## waits for everything in flight (shutdown, a preview, tests).
func collect(block := false) -> void:
	for loc in _loading.keys():
		var path: String = _loading[loc]
		var st := ResourceLoader.load_threaded_get_status(path)
		while block and st == ResourceLoader.THREAD_LOAD_IN_PROGRESS:
			OS.delay_usec(500)
			st = ResourceLoader.load_threaded_get_status(path)
		if st == ResourceLoader.THREAD_LOAD_IN_PROGRESS:
			continue
		_loading.erase(loc)
		var img := ResourceLoader.load_threaded_get(path) as Image
		if _images.has(loc):
			continue                     # edited meanwhile: the edit is newer than the file
		if img == null:
			unreadable[loc] = path
			_error(loc, "%s could not be read as an image" % path)
			continue
		var job := {"loc": loc, "img": img, "rs": region_size, "rm": region_m(), "ids": type_ids, "out": {},
			"core": ForestNativeRes.core()}
		var id := WorkerThreadPool.add_task(_summarise_job.bind(job), false, "forest_map_summary")
		_summing[id] = job
		_summing_at[loc] = id
	for id in _summing.keys():
		if not block and not WorkerThreadPool.is_task_completed(id):
			continue
		WorkerThreadPool.wait_for_task_completion(id)
		var job: Dictionary = _summing[id]
		_summing.erase(id)
		_summing_at.erase(job["loc"])
		if _images.has(job["loc"]):
			continue
		var s: Dictionary = job["out"]
		if String(s.get("error", "")) != "":
			_error(job["loc"], "%s %s" % [path_for(job["loc"]), s["error"]])
		else:
			_hold(job["loc"], s)


## Wait for every read in flight and land it.
func drain() -> void:
	collect(true)


## Release every held map not in `needed` (location -> anything). Adopted maps stay; a scatter job already given a
## view keeps its own copy of the bytes.
func keep_only(needed: Dictionary) -> void:
	for loc in _held.keys():
		if not needed.has(loc) and not _adopted.has(loc) and not _images.has(loc) and not _dirty.has(loc):
			_held.erase(loc)


## The editor: the region's map as an Image the Forest tools write (the held map's, the file's (read
## now, on this thread), or a new blank one where the terrain has a region and no map: no forest, full density,
## neutral age, not painted; at the texel size of the nearest held map, or one texel a vertex). Null where the terrain
## has no region, or when not editing. A map refused by its checks is replaced by a blank one; a file that cannot be read
## is not edited at all (`unreadable`), so a save never overwrites it. Never released.
func edit_image(loc: Vector2i) -> Image:
	if _images.has(loc):
		return _images[loc]
	if not editing or not configured():
		return null
	if region_exists.is_valid() and not bool(region_exists.call(loc)):
		return null
	if unreadable.has(loc):
		return null
	_scan()
	if not _held.has(loc) and _files.has(loc) and not _bad.has(loc):
		var src := ResourceLoader.load(_files[loc], "", ResourceLoader.CACHE_MODE_IGNORE) as Image
		if src == null or src.is_empty():
			unreadable[loc] = _files[loc]
			_error(loc, "%s could not be read as an image (not painted, so a save cannot overwrite it)" % _files[loc])
			return null
		var s := summarise(src, loc, region_size, region_m(), type_ids)
		if String(s["error"]) == "":
			_hold(loc, s)
		else:
			_error(loc, "%s %s" % [_files[loc], s["error"]])
	var img: Image
	if _held.has(loc):
		var hw: int = _held[loc]["w"]
		img = Image.create_from_data(hw, hw, false, Image.FORMAT_RGBA8, _held[loc]["data"])
	else:
		var w := region_size / _t_near(loc)
		img = Image.create_empty(w, w, false, Image.FORMAT_RGBA8)
		img.fill(Color8(NONE_PX[0], NONE_PX[1], NONE_PX[2], NONE_PX[3]))
		_bad.erase(loc)
		_hold(loc, summarise(img, loc, region_size, region_m(), type_ids))
	_images[loc] = img
	return img


## The texel size (vertices a texel) of the held map nearest `loc` (a tie goes to the smaller location, y then x), or 1.
func _t_near(loc: Vector2i) -> int:
	var best := Vector3i(0x7fffffff, 0, 0)
	var t := 1
	for l in _held:
		var k := Vector3i((l - loc).length_squared(), l.y, l.x)
		if k < best:
			best = k
			t = region_size / int(_held[l]["w"])
	return t


## After an edit: the held map takes the edited Image's bytes, and the block summary is rebuilt for the blocks over the
## texel rectangle `rect`, on this thread, a few blocks, so a regrow right after reads the new summary.
func refresh(loc: Vector2i, rect: Rect2i) -> void:
	if not _images.has(loc) or not _held.has(loc):
		return
	var img: Image = _images[loc]
	var w := img.get_width()
	_held[loc]["data"] = img.get_data()
	var core = ForestNativeRes.core()
	if core == null:
		return                       # no native core: no block has a type (the forest says why, once)
	var rm := region_m()
	var wr := world_rect(loc, rect)
	var b0 := Vector2i(floori(wr.position.x / BLOCK_M), floori(wr.position.y / BLOCK_M))
	var b1 := Vector2i(floori((wr.end.x - 0.001) / BLOCK_M), floori((wr.end.y - 0.001) / BLOCK_M))
	var got: Dictionary = core.summarise_map(_held[loc]["data"], w, float(loc.x) * rm, float(loc.y) * rm, rm / float(w),
		type_ids, b0, b1)["blocks"]
	var blocks: Dictionary = _held[loc]["blocks"]
	for bz in range(b0.y, b1.y + 1):
		for bx in range(b0.x, b1.x + 1):
			var b := Vector2i(bx, bz)
			if got.has(b):
				blocks[b] = got[b]
			else:
				blocks.erase(b)


## The flora profile's type ids changed (Reload types): every held map's block summary is built again from its bytes.
func resummarise() -> void:
	for loc in _held.keys():
		var w: int = _held[loc]["w"]
		var img := Image.create_from_data(w, w, false, Image.FORMAT_RGBA8, _held[loc]["data"])
		_held[loc]["blocks"] = summarise(img, loc, region_size, region_m(), type_ids)["blocks"]


## A held or edited map's texel rectangle in world metres.
func world_rect(loc: Vector2i, rect: Rect2i) -> Rect2:
	var w := region_size
	if _images.has(loc):
		w = (_images[loc] as Image).get_width()
	elif _held.has(loc):
		w = int(_held[loc]["w"])
	var rm := region_m()
	var tm := rm / float(w)
	return Rect2(float(loc.x) * rm + float(rect.position.x) * tm, float(loc.y) * rm + float(rect.position.y) * tm,
		float(rect.size.x) * tm, float(rect.size.y) * tm)


## The texel at world (x, z) as [R, G, B, A]: the edited map's when there is one, else the held map's, else the file's
## (read now, on this thread, and not kept: the ring releases the maps near the camera once it has filled); [] where
## there is no map.
func pixel_at(x: float, z: float) -> PackedInt32Array:
	var loc := location_of(x, z)
	var rm := region_m()
	var img: Image = _images.get(loc)
	if img == null and not _held.has(loc):
		_scan()
		if _files.has(loc) and not _bad.has(loc):
			img = ResourceLoader.load(_files[loc], "", ResourceLoader.CACHE_MODE_IGNORE) as Image
	if img != null:
		var w := img.get_width()
		var tm := rm / float(w)
		var c := img.get_pixel(clampi(floori((x - float(loc.x) * rm) / tm), 0, w - 1),
			clampi(floori((z - float(loc.y) * rm) / tm), 0, w - 1))
		return PackedInt32Array([c.r8, c.g8, c.b8, c.a8])
	if _held.has(loc):
		var hw: int = _held[loc]["w"]
		var htm := rm / float(hw)
		var i := (clampi(floori((z - float(loc.y) * rm) / htm), 0, hw - 1) * hw
			+ clampi(floori((x - float(loc.x) * rm) / htm), 0, hw - 1)) * 4
		var d: PackedByteArray = _held[loc]["data"]
		return PackedInt32Array([d[i], d[i + 1], d[i + 2], d[i + 3]])
	return PackedInt32Array()


## Mark the map of `loc` as changed since its file was written.
func mark_dirty(loc: Vector2i) -> void:
	_dirty[loc] = true
	_track()


## Whether any map has unsaved changes.
func unsaved() -> bool:
	return not _dirty.is_empty()


## Every live ForestMaps with unsaved changes, in any open scene tab (the save and the quit prompt use it).
static func unsaved_maps() -> Array:
	var out := []
	for w in _unsaved.duplicate():
		var m = (w as WeakRef).get_ref()
		if m == null or not m.unsaved():
			_unsaved.erase(w)
		elif not out.has(m):
			out.append(m)
	return out


## Those of one scene ("": every scene, as when the editor quits).
static func unsaved_for(p_scene: String) -> Array:
	return unsaved_maps().filter(func(m) -> bool: return p_scene == "" or m.scene() == p_scene)


## The scene the maps are saved with: scene_of's answer now, else scene_path.
func scene() -> String:
	return String(scene_of.call()) if scene_of.is_valid() else scene_path


func _track() -> void:
	for w in _unsaved:
		if (w as WeakRef).get_ref() == self:
			return
	_unsaved.append(weakref(self))


## A map written the way every writer writes it (the import, the scene save): compressed, its resource id fixed, so the
## same map is the same bytes whatever path or process wrote it.
static func save_map(img: Image, path: String) -> Error:
	img.resource_scene_unique_id = SCENE_ID
	return ResourceSaver.save(img, path, ResourceSaver.FLAG_COMPRESS)


## Writes every dirty map (compressed, the import's format) and returns location -> Error. A failed write stays dirty
## (the next save retries), with one error.
func save_dirty() -> Dictionary:
	var out := {}
	for loc in _dirty.keys():
		var p := path_for(loc)
		if p == "" or not _images.has(loc):
			out[loc] = ERR_FILE_BAD_PATH
			ForestLogRes.error("[Wuifwoud] the forest map of region %s has nowhere to go (no maps directory)" % str(loc))
			continue
		DirAccess.make_dir_recursive_absolute(p.get_base_dir())
		var e := save_map(_images[loc], p)
		out[loc] = e
		if e == OK:
			_dirty.erase(loc)
			_files[loc] = p
		else:
			ForestLogRes.error("[Wuifwoud] the forest map of region %s was not saved to %s (%s)" % [str(loc), p,
				error_string(e)])
	unsaved_maps()                   # prunes this instance when it is clean
	return out


## Copies of the maps with unsaved changes (location -> Image): what the editor hands an import at Run.
func dirty_images() -> Dictionary:
	var out := {}
	for loc in _dirty:
		if _images.has(loc):
			out[loc] = (_images[loc] as Image).duplicate()
	return out


## An import rewrote this folder: the held and edited maps of every region it wrote or deleted are
## dropped and their unsaved marks cleared (their paint is in the files now: the editor handed it over at Run), the
## folder is scanned again and `generation` moves on.
func after_import(report: Dictionary) -> void:
	drain()
	for key in ["written", "deleted", "deleted_no_region"]:
		for loc in report.get(key, []):
			_images.erase(loc)
			_dirty.erase(loc)
			_held.erase(loc)
			_bad.erase(loc)
			unreadable.erase(loc)
	_files.clear()
	_scanned = false
	generation += 1
	unsaved_maps()                   # prunes this instance when it is clean


## An import's report reaches every live ForestMaps reading its folder (`report["dir"]`). How many it reached. A run
## that changed nothing (cancelled, or stopped by an error before its swap) reaches none: the maps are as they were,
## so no forest regrows and no stroke stops undoing.
static func imported(report: Dictionary) -> int:
	if (report.get("written", []) as Array).is_empty() and (report.get("deleted", []) as Array).is_empty() \
			and (report.get("deleted_no_region", []) as Array).is_empty():
		return 0
	var ms := live_for(String(report.get("dir", "")))
	for m in ms:
		m.after_import(report)
	return ms.size()


## Every live ForestMaps whose `directory` is `dir` (written either way: a trailing slash, `.` and `..` folded).
static func live_for(dir: String) -> Array:
	var want := _norm(dir)
	var out := []
	for w in _live.duplicate():
		var m = (w as WeakRef).get_ref()
		if m == null:
			_live.erase(w)
		elif want != "" and _norm(m.directory) == want:
			out.append(m)
	return out


static func _norm(p: String) -> String:
	return p.simplify_path().trim_suffix("/") if p != "" else ""


func _register() -> void:
	for w in _live.duplicate():
		var m = (w as WeakRef).get_ref()
		if m == null:
			_live.erase(w)
		elif m == self:
			return
	_live.append(weakref(self))


## How many maps the budget holds at once, at least one: counted in the largest map held so far (maps not yet read may
## be any size), or one texel a vertex before any.
func budget_regions() -> int:
	var w := maxi(_largest_w if _largest_w > 0 else region_size, 1)
	return maxi(1, int(budget_mb * 1048576.0 / float(w * w * 4)))


## The bytes the held maps take.
func held_bytes() -> int:
	var n := 0
	for loc in _held:
		n += (_held[loc]["data"] as PackedByteArray).size()
	return n


## The held maps of `locs`, for a scatter worker: {location: {"w": int, "data": PackedByteArray}}.
func view(locs: Array) -> Dictionary:
	var out := {}
	for loc in locs:
		if _held.has(loc):
			out[loc] = {"w": _held[loc]["w"], "data": _held[loc]["data"]}
	return out


## The type ids present per BLOCK_M block over `rect`, from the held maps of `locs`: {Vector2i: PackedInt32Array}.
func blocks_in(locs: Array, rect: Rect2) -> Dictionary:
	var b0 := Vector2i(floori(rect.position.x / BLOCK_M), floori(rect.position.y / BLOCK_M))
	var b1 := Vector2i(floori((rect.end.x - 0.001) / BLOCK_M), floori((rect.end.y - 0.001) / BLOCK_M))
	var out := {}
	for loc in locs:
		if not _held.has(loc):
			continue
		var bl: Dictionary = _held[loc]["blocks"]
		for b in bl:
			if b.x < b0.x or b.x > b1.x or b.y < b0.y or b.y > b1.y:
				continue
			if not out.has(b):
				out[b] = bl[b]
				continue
			var merged: PackedInt32Array = out[b]
			for id in bl[b]:
				if not merged.has(id):
					merged.append(id)
			out[b] = merged
	return out


## What a host's memory probe or a log line reports.
func debug_stats() -> Dictionary:
	return {"held": _held.size(), "in_flight": _loading.size() + _summing.size(), "files": _files.size(),
		"held_mb": float(held_bytes()) / 1048576.0, "peak_mb": float(stats["peak_bytes"]) / 1048576.0,
		"peak_held": stats["peak_held"], "loaded": stats["loaded"], "reloads": stats["reloads"], "bad": stats["bad"]}


## Packed texel R | G << 8 | B << 16 at world (x, z), or -1 where `view` holds no map. Pure: workers call it.
static func texel(p_view: Dictionary, p_region_m: float, x: float, z: float) -> int:
	var loc := Vector2i(floori(x / p_region_m), floori(z / p_region_m))
	var m = p_view.get(loc)
	if m == null:
		return -1
	var w: int = m["w"]
	var tm := p_region_m / float(w)
	var tx := clampi(floori((x - float(loc.x) * p_region_m) / tm), 0, w - 1)
	var tz := clampi(floori((z - float(loc.y) * p_region_m) / tm), 0, w - 1)
	var data: PackedByteArray = m["data"]
	var i := (tz * w + tx) * 4
	return data[i] | (data[i + 1] << 8) | (data[i + 2] << 16)


## A map's checks and its block summary, pure (a worker runs it). {"error": "" or why it is no forest, "warn": "",
## "w": int, "data": RGBA8 bytes, "blocks": {world block: PackedInt32Array of the `ids` present}, "unknown": ids
## present that `ids` lacks}. Never converts `src` in place: the threaded loader may share it. The blocks and the unknown
## ids come from the native core (`core`: a worker's, handed over by the main thread); without it a map has
## no block (nothing grows: the forest says why, once) but is still held, so the editor can paint and save it.
static func summarise(src: Image, loc: Vector2i, p_region_size: int, p_region_m: float,
		ids: PackedInt32Array, core = null) -> Dictionary:
	var out := {"error": "", "warn": "", "w": 0, "data": PackedByteArray(), "blocks": {},
		"unknown": PackedInt32Array()}
	if src == null or src.is_empty():
		out["error"] = "is empty"
		return out
	var w := src.get_width()
	if w != src.get_height() or w <= 0 or p_region_size % w != 0 or not ((p_region_size / w) in ALLOWED_T):
		out["error"] = "is %dx%d texels: a forest map is region_size / t square, t one of %s (region_size %d)" % [
			src.get_width(), src.get_height(), str(ALLOWED_T), p_region_size]
		return out
	var img := src
	if img.get_format() != Image.FORMAT_RGBA8:
		img = src.duplicate()
		img.convert(Image.FORMAT_RGBA8)
		out["warn"] = "is not RGBA8 (format %d): converted" % src.get_format()
	out["w"] = w
	out["data"] = img.get_data()
	var c = core if core != null else ForestNativeRes.core()
	if c == null:
		return out
	var ox := float(loc.x) * p_region_m
	var oz := float(loc.y) * p_region_m
	var s: Dictionary = c.summarise_map(out["data"], w, ox, oz, p_region_m / float(w), ids,
		Vector2i(floori(ox / BLOCK_M), floori(oz / BLOCK_M)),
		Vector2i(floori((ox + p_region_m - 0.001) / BLOCK_M), floori((oz + p_region_m - 0.001) / BLOCK_M)))
	out["blocks"] = s["blocks"]
	out["unknown"] = s["unknown"]
	return out


func _summarise_job(job: Dictionary) -> void:
	job["out"] = summarise(job["img"], job["loc"], int(job["rs"]), float(job["rm"]), job["ids"], job.get("core"))


func _hold(loc: Vector2i, s: Dictionary) -> void:
	var w := int(s["w"])
	_largest_w = maxi(_largest_w, w)
	if String(s["warn"]) != "":
		ForestLogRes.warn("[Wuifwoud] forest map %s %s" % [str(loc), s["warn"]])
	for id in s["unknown"]:
		if not _unknown_warned.has(id):
			_unknown_warned[id] = true
			ForestLogRes.warn("[Wuifwoud] forest map %s names type %d, which the profile lacks: it grows nothing"
				% [str(loc), id])
	_held[loc] = {"w": w, "data": s["data"], "blocks": s["blocks"]}
	stats["loaded"] = int(stats["loaded"]) + 1
	if _ever.has(loc):
		stats["reloads"] = int(stats["reloads"]) + 1
	_ever[loc] = true
	stats["peak_held"] = maxi(int(stats["peak_held"]), _held.size())
	stats["peak_bytes"] = maxi(int(stats["peak_bytes"]), held_bytes())


func _error(loc: Vector2i, msg: String) -> void:
	_bad[loc] = true
	_held.erase(loc)
	errors.append(msg)
	stats["bad"] = int(stats["bad"]) + 1
	ForestLogRes.error("[Wuifwoud] forest map %s: no forest there" % msg)
