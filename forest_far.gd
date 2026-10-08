# Copyright (c) 2026 Digitzone
# SPDX-License-Identifier: MIT
@tool
extends Node3D
## The far forest: a canopy shell over the forested ground past the impostor cards, one mesh and one
## summary texture per far cell (far_cell_regions² regions), built from the forest maps on workers and drawn by
## shaders/forest_far.gdshader. An internal child of the forest node, which ticks it from its resolve pump and tells it
## what changed: the maps under a rectangle (touch), every map or the profile (rebuild_all), the quality tier
## (set_band).
##
## THE INPUTS ARE READ ONCE AND KEPT SMALL. Every map is summarised once (64 KB a region at the defaults) and every
## region's ground sampled once at the shell's grid (16 KB); a cell is built from those, with a one-quad margin from its
## neighbours so two cells agree on the vertices they share. The summary, the ground's samples and the cell's build run
## in the native core, one call a job; without it there is no far forest (said once). Files come through
## the engine's threaded loader with CACHE_MODE_IGNORE, landed on this thread and dropped. Measured on 86 forest regions:
## a worker load with CACHE_MODE_REPLACE kept 1148 MB of region copies; the threaded loader kept none (the engine's own
## allocations +1 MB), at 0.46 ms on this thread a region.
##
## A cell is wanted again when its inputs change, and its generation moves: a build that lands for an older generation
## is dropped. Workers read only the copies handed to them; this node, its cells, meshes and textures are made on the
## main thread. Worker tasks are low priority (none waits on a load), and so are the near forest's: while it has work in
## flight (forest.near_busy()) the far forest starts none of its own, so the ring around the player fills first.

## The far palette: per type and band, the crown colours and canopy heights.
const ForestFarPaletteRes := preload("res://addons/wuifwoud/forest_far_palette.gd")
## The region height pump (a streamed region, else its file).
const ForestHeightPumpRes := preload("res://addons/wuifwoud/forest_height_pump.gd")
## The forest maps.
const ForestMapsRes := preload("res://addons/wuifwoud/forest_maps.gd")
## The forest's log, through its sink.
const ForestLogRes := preload("res://addons/wuifwoud/forest_log.gd")
## The shell's shader.
const SHADER := preload("res://addons/wuifwoud/shaders/forest_far.gdshader")
## Touched cells rebuild at most this often while painting (ms).
const TOUCH_MS := 250
## Region file loads in flight at once.
const LOADS_AT_ONCE := 4
## The cells' node names begin with this.
const NAME_PREFIX := "Far_"
## The native core, reached by class name.
const ForestNativeRes := preload("res://addons/wuifwoud/forest_native.gd")
## A shell's surface: CUSTOM0 is four floats a vertex (the rules by place, skirt, ground height, type).
const MESH_FORMAT := Mesh.ARRAY_CUSTOM_RGBA_FLOAT << Mesh.ARRAY_FORMAT_CUSTOM0_SHIFT

## The forest node (set by it).
var forest: Node = null
## Tests and tools: region -> PackedFloat32Array of its ground at the shell's grid ((region_m / far_grid_m)², row-major
## from its corner), empty for none. Unset: the terrain's streamed region, else its region file.
var heights_of := Callable()
## Tests: species -> Color (linear) or null, and species -> metres. Unset: the impostor bakes and the species' meshes.
var colour_of := Callable()
## Tests: species -> its mean height (see colour_of).
var height_of := Callable()
## Builds landed and dropped, region loads, and the main-thread milliseconds spent, for the shot rig and the logs.
var stats := {"built": 0, "dropped": 0, "loads": 0, "ms": 0}
## The forest's box for this tick: set by the forest before each tick, the end of the main-thread time
## the far landing shares with the near forest's commit and card flush (µs, Time.get_ticks_usec); 0: no box (tests,
## build_now).
var box_until_us := 0

var _started := false
var _t0_ms := 0
var _summaries := {}       # region -> PackedByteArray (RGBA8 out_w²)
var _forest_in := {}       # region -> bool: its summary has cover
var _sum_gen := {}         # region -> int: moves when the region's map changed
var _map_hash := {}        # region -> int: the hash of the map bytes its summary came from
var _heights := {}         # region -> PackedFloat32Array (s²), empty: none
var _asked_sum := {}       # region -> true: a summary on its way
var _asked_h := {}         # region -> true: ground on its way
var _cells := {}           # cell -> {"gen": int, "node": MeshInstance3D or null, "quads": int}
var _want := {}            # cell -> true
var _queue: Array = []     # [path, kind, region, summary generation]: waiting for a loader slot
var _loads := {}           # path -> {"kind": "map" | "height", "loc": Vector2i, "gen": int}
var _jobs := {}            # task id -> job
var _palette = null        # ForestFarPalette
var _palette_tex: ImageTexture = null
var _region_files := {}
var _region_scanned := false
var _touched: Array = []   # Rect2: painted since the last flush
var _flush_ms := -TOUCH_MS
var _warned := {}
var _band := Vector2(2600.0, 600.0)   # where the cards end, and the handover under them
## A build whose mesh landed last tick and whose texture and node land this one: {"job", "mesh"}, or empty.
var _landing := {}
## The palette's crown colours, read one species a tick before the start: species -> Color or null.
var _colours := {}
var _warm: Array = []        # species whose colour is still to read
var _warm_listed := false


## The forest's resolve pump, every frame (the main thread): start once the maps and types are in, land what finished,
## flush paint, ask for what wanted cells lack, build those whose inputs are in.
func tick(terrain: Node) -> void:
	# THE NEAR FOREST FIRST: both run on the engine's low-priority worker lane (a few slots) and on this thread, so while
	# it is busy (forest.near_busy()) nothing new starts here, not even the start, whose palette reads every species'
	# bake on this thread (measured: ~0.3 s off the first ring fill). What is in flight still lands.
	var busy: bool = forest != null and forest.near_busy()
	if not _started and busy:
		return
	if not _start():
		return
	_land_loads(false)
	_land_jobs(false)
	_flush_touches(false)
	if not busy:
		_advance(terrain)
	_note_done()


## Tests and tools: every wanted cell built before this returns.
func build_now(terrain: Node) -> void:
	if not _start(true):
		return
	for _i in 100000:
		_land_loads(true)
		_land_jobs(true)
		_flush_touches(true)
		_advance(terrain)
		if _idle():
			break
	_note_done()


## Tests and tools: only `cells` are wanted (the others are left as they are).
func want_only(cells: Array) -> void:
	if not _start(true):
		return
	_want.clear()
	for c in cells:
		_want_cell(c)


## The maps under `rect` (world metres) changed in the editor (a stroke's send or end, an undo, a Place edit): flushed at
## most every TOUCH_MS; a region whose map bytes did not change is left as it is.
func touch(rect: Rect2) -> void:
	if _started:
		_touched.append(rect)


## The maps were rewritten (an import's catch-up, Re-grow all) or the profile reloaded (`profile`: the palette too):
## every region is summarised again and every cell rebuilt.
func rebuild_all(profile: bool) -> void:
	if not _started:
		return
	for loc in _summaries.keys() + _asked_sum.keys():
		_sum_gen[loc] = int(_sum_gen.get(loc, 0)) + 1
	_summaries.clear()
	_asked_sum.clear()
	_forest_in.clear()
	if profile:
		_build_palette()
	_t0_ms = Time.get_ticks_msec()
	stats["ms"] = 0
	_want_all()


## Where the cards end and the handover under them (the quality tier): every cell's material follows.
func set_band(cards_end_m: float, fade_m: float) -> void:
	_band = Vector2(cards_end_m, fade_m)
	for c in _cells:
		var mi = _cells[c].get("node")
		if mi != null and is_instance_valid(mi):
			var m: ShaderMaterial = mi.material_override
			m.set_shader_parameter("far_cut", cards_end_m)
			m.set_shader_parameter("fade_m", fade_m)


## Everything in flight landed and dropped (the forest's exit, a teardown, switched off): loads fetched, workers waited
## for. What was summarised stays.
func drain() -> void:
	for path in _loads.keys():
		while ResourceLoader.load_threaded_get_status(path) == ResourceLoader.THREAD_LOAD_IN_PROGRESS:
			OS.delay_usec(500)
		ResourceLoader.load_threaded_get(path)
	_loads.clear()
	_queue.clear()
	for id in _jobs.keys():
		WorkerThreadPool.wait_for_task_completion(id)
	_jobs.clear()
	_asked_sum.clear()
	_asked_h.clear()
	_landing = {}


## The far forest's numbers (the forest's debug_churn): cells drawn and their quads, builds landed and dropped, files
## loaded, what is still to do, regions summarised and sampled, and the ms the last full build took.
func info() -> Dictionary:
	var nodes := 0
	var quads := 0
	for c in _cells:
		var mi = _cells[c].get("node")
		if mi != null and is_instance_valid(mi):
			nodes += 1
			quads += int(_cells[c].get("quads", 0))
	return {"cells": nodes, "quads": quads, "built": int(stats["built"]), "dropped": int(stats["dropped"]),
		"loads": int(stats["loads"]),
		"pending": _want.size() + _queue.size() + _loads.size() + _jobs.size() + (0 if _landing.is_empty() else 1),
		"regions": _summaries.size(), "grounds": _heights.size(), "ms": int(stats["ms"])}


## A cell's material: the shader with its summary, the palette, where the cell lies, the band and the elevation bands.
static func material_for(summary: Texture2D, palette: Texture2D, origin: Vector2, cell_m: float, texels: int,
		band: Vector2, coast_m: float, mid_m: float) -> ShaderMaterial:
	var m := ShaderMaterial.new()
	m.shader = SHADER
	m.set_shader_parameter("summary", summary)
	m.set_shader_parameter("palette", palette)
	m.set_shader_parameter("cell_origin", origin)
	m.set_shader_parameter("cell_size", cell_m)
	m.set_shader_parameter("cell_texels", texels)
	m.set_shader_parameter("far_cut", band.x)
	m.set_shader_parameter("fade_m", band.y)
	m.set_shader_parameter("coast_m", coast_m)
	m.set_shader_parameter("mid_m", mid_m)
	return m


## `block` (tests and tools: build_now, want_only): the palette's colours read all at once, not one a tick.
func _start(block := false) -> bool:
	if _started:
		return true
	if forest == null or not forest.maps.configured() or (forest._types.by_id as Dictionary).is_empty():
		return false
	if not ForestNativeRes.available():
		ForestNativeRes.warn_missing()
		return false
	var rm: float = forest.maps.region_m()
	var g := float(forest.far_grid_m)
	var tm := float(forest.far_texel_m)
	if g <= 0.0 or tm <= 0.0 or not _divides(g, rm) or not _divides(tm, g):
		_warn_once("settings", "[Wuifwoud] the far forest needs far_grid_m (%.2f) to divide the region (%.0f m) and far_texel_m (%.2f) to divide far_grid_m: no far forest" % [g, rm, tm])
		return false
	if not _warm_colours(block):
		return false
	_build_palette()
	_started = true
	_t0_ms = Time.get_ticks_msec()
	_want_all()
	return true


static func _divides(a: float, b: float) -> bool:
	var q := b / a
	return absf(q - roundf(q)) < 1e-4


## The palette's crown colours, ONE SPECIES A TICK: each reads its impostor bake back on this thread, and the far
## forest starts after the near ring's first fill, while the player may be driving. True when all are read.
## `all`: every one this call (a caller that blocks anyway: build_now, want_only).
func _warm_colours(all := false) -> bool:
	if colour_of.is_valid():
		return true
	if not _warm_listed:
		_warm_listed = true
		var seen := {}
		for id in forest._types.ids():
			var t: Dictionary = forest._types.get_type(id)
			for band in ForestFarPaletteRes.BANDS:
				for e in ForestFarPaletteRes.pool_of(t, band):
					var sp := str(e[0])
					if not seen.has(sp) and not _colours.has(sp):
						seen[sp] = true
						_warm.append(sp)
	while not _warm.is_empty():
		var sp: String = _warm.pop_back()
		_colours[sp] = ForestFarPaletteRes.crown_colour(sp)
		if not all:
			break
	return _warm.is_empty()


## A species' crown colour: read once (a species a profile reload brings is read when the palette needs it).
func _crown_colour(sp: String):
	if not _colours.has(sp):
		_colours[sp] = ForestFarPaletteRes.crown_colour(sp)
	return _colours[sp]


func _build_palette() -> void:
	_palette = ForestFarPaletteRes.new()
	_palette.build(forest._types, colour_of if colour_of.is_valid() else _crown_colour,
		height_of if height_of.is_valid() else Callable(ForestAssets, "species_height"))
	for w in _palette.warnings:
		_warn_once("palette " + w, "[Wuifwoud] the far forest: %s" % w)
	_palette_tex = ImageTexture.create_from_image(_palette.texture_image())
	for c in _cells:
		var mi = _cells[c].get("node")
		if mi != null and is_instance_valid(mi):
			(mi.material_override as ShaderMaterial).set_shader_parameter("palette", _palette_tex)


func _rm() -> float:
	return forest.maps.region_m()


func _cr() -> int:
	return maxi(int(forest.far_cell_regions), 1)


func _cell_of(loc: Vector2i) -> Vector2i:
	var cr := _cr()
	return Vector2i(floori(float(loc.x) / float(cr)), floori(float(loc.y) / float(cr)))


## The regions a cell's build reads: its own and one around (the margin).
func _window(c: Vector2i) -> Array:
	var cr := _cr()
	var out := []
	for lz in range(c.y * cr - 1, c.y * cr + cr + 1):
		for lx in range(c.x * cr - 1, c.x * cr + cr + 1):
			out.append(Vector2i(lx, lz))
	return out


func _want_cell(c: Vector2i) -> void:
	var cell: Dictionary = _cells.get(c, {"gen": 0, "node": null, "quads": 0})
	cell["gen"] = int(cell["gen"]) + 1
	_cells[c] = cell
	_want[c] = true


## Every map's cell and its 8 neighbours (a forest's walls at a cell's edge lie in the next), and every cell built.
func _want_all() -> void:
	var cells := {}
	for loc in forest.maps.locations():
		var c := _cell_of(loc)
		for dz in range(-1, 2):
			for dx in range(-1, 2):
				cells[c + Vector2i(dx, dz)] = true
	for c in _cells:
		cells[c] = true
	for c in cells:
		_want_cell(c)


func _idle() -> bool:
	return _want.is_empty() and _queue.is_empty() and _loads.is_empty() and _jobs.is_empty() and _landing.is_empty()


func _note_done() -> void:
	if int(stats["ms"]) == 0 and _started and _idle():
		stats["ms"] = maxi(Time.get_ticks_msec() - _t0_ms, 1)


## Each wanted cell: its regions' summaries asked for; with no cover in its window it is dropped; else its ground asked
## for; with everything in, built.
func _advance(terrain: Node) -> void:
	for c in _want.keys():
		var waiting := false
		var any := false
		for loc in _window(c):
			if not forest.maps.has_map(loc):
				continue
			if not _summaries.has(loc):
				waiting = true
				_ask_summary(loc)
			elif bool(_forest_in.get(loc, false)):
				any = true
		if waiting:
			continue
		if not any:
			_want.erase(c)
			_drop_node(c)
			continue
		for loc in _window(c):
			if not _heights.has(loc):
				waiting = true
				_ask_heights(loc, terrain)
		if waiting:
			continue
		_want.erase(c)
		_submit_build(c)
	_pump_loads()


func _ask_summary(loc: Vector2i) -> void:
	if _asked_sum.has(loc):
		return
	_asked_sum[loc] = true
	var img: Image = forest.maps.image_now(loc)
	if img != null:
		_submit_summary(loc, img.duplicate() as Image, int(_sum_gen.get(loc, 0)))
		return
	var path: String = forest.maps.file_of(loc)
	if path == "":
		_set_summary(loc, PackedByteArray(), false, 0)
		return
	_queue.append([path, "map", loc, int(_sum_gen.get(loc, 0))])


func _set_summary(loc: Vector2i, bytes: PackedByteArray, any: bool, map_hash: int) -> void:
	_summaries[loc] = bytes
	_forest_in[loc] = any
	_map_hash[loc] = map_hash
	_asked_sum.erase(loc)


func _ask_heights(loc: Vector2i, terrain: Node) -> void:
	if _asked_h.has(loc):
		return
	if heights_of.is_valid():
		_heights[loc] = heights_of.call(loc)
		return
	var img := _live_height(loc, terrain)
	if img != null:
		_asked_h[loc] = true
		_submit_sample(loc, img)
		return
	var path := _region_file(loc, terrain)
	if path == "":
		_heights[loc] = PackedFloat32Array()
		if forest.maps.has_map(loc):
			_warn_once("ground " + str(loc), "[Wuifwoud] the far forest has no ground for region %s (no region file, none streamed): nothing grows there far away" % str(loc))
		return
	_asked_h[loc] = true
	_queue.append([path, "height", loc, 0])


## A region the terrain has streamed: its height map (the composite when the terrain has one), else null.
func _live_height(loc: Vector2i, terrain: Node) -> Image:
	var data = terrain.get("data") if terrain != null else null
	if data == null or not data.has_method("get_regionp"):
		return null
	var rm := _rm()
	var region = data.call("get_regionp", Vector3((float(loc.x) + 0.5) * rm, 0.0, (float(loc.y) + 0.5) * rm))
	if region == null or not region.has_method("get_height_map"):
		return null
	var img: Image = region.call("get_height_map_composited") if region.has_method("get_height_map_composited") \
		else region.call("get_height_map")
	return img if img != null and img.get_format() == Image.FORMAT_RF else null


## The terrain's region file for `loc` ("" when none): one scan of its data directory.
func _region_file(loc: Vector2i, terrain: Node) -> String:
	if not _region_scanned:
		_region_scanned = true
		var dd = terrain.get("data_directory") if terrain != null else null
		var dir := String(dd) if dd != null else ""
		if dir != "" and DirAccess.dir_exists_absolute(dir):
			for f in DirAccess.get_files_at(dir):
				var l = ForestHeightPumpRes.parse_region_filename(f)
				if l != null:
					_region_files[l] = dir.path_join(f)
	return String(_region_files.get(loc, ""))


## Start queued loads while fewer than LOADS_AT_ONCE are in flight; a path already loading waits its turn.
func _pump_loads() -> void:
	var tries := _queue.size()
	while not _queue.is_empty() and _loads.size() < LOADS_AT_ONCE and tries > 0:
		tries -= 1
		var q: Array = _queue.pop_front()
		var path: String = q[0]
		if _loads.has(path):
			_queue.append(q)
			continue
		var e := ResourceLoader.load_threaded_request(path, "", false, ResourceLoader.CACHE_MODE_IGNORE)
		if e != OK:
			_failed(String(q[1]), q[2], "%s: the loader refused it (%s)" % [path, error_string(e)])
			continue
		_loads[path] = {"kind": q[1], "loc": q[2], "gen": q[3]}
		stats["loads"] = int(stats["loads"]) + 1


## Land finished loads (on this thread): a map goes to a worker for its summary, a region file's height map to a worker
## for its samples; the file's resource is dropped. `block` waits for each.
func _land_loads(block: bool) -> void:
	for path in _loads.keys():
		var st := ResourceLoader.load_threaded_get_status(path)
		while block and st == ResourceLoader.THREAD_LOAD_IN_PROGRESS:
			OS.delay_usec(500)
			st = ResourceLoader.load_threaded_get_status(path)
		if st == ResourceLoader.THREAD_LOAD_IN_PROGRESS:
			continue
		var l: Dictionary = _loads[path]
		_loads.erase(path)
		var res = ResourceLoader.load_threaded_get(path)
		if String(l["kind"]) == "map":
			var img := res as Image
			if img == null or img.is_empty():
				_failed("map", l["loc"], "%s could not be read as an image" % path)
			else:
				_submit_summary(l["loc"], img, int(l["gen"]))
		else:
			var hm: Image = null
			if res != null and res.has_method("get_height_map"):
				hm = res.call("get_height_map_composited") if res.has_method("get_height_map_composited") \
					else res.call("get_height_map")
			if hm == null or hm.get_format() != Image.FORMAT_RF:
				_failed("height", l["loc"], "%s has no height map" % path)
			else:
				_submit_sample(l["loc"], hm)
		res = null


func _failed(kind: String, loc: Vector2i, why: String) -> void:
	if kind == "map":
		_set_summary(loc, PackedByteArray(), false, 0)
	else:
		_heights[loc] = PackedFloat32Array()
		_asked_h.erase(loc)
	_warn_once(kind + " " + str(loc), "[Wuifwoud] the far forest: %s" % why)


func _submit_summary(loc: Vector2i, img: Image, gen: int) -> void:
	var job := {"kind": "summary", "loc": loc, "gen": gen, "img": img,
		"w": int(round(_rm() / float(forest.far_texel_m))), "rs": int(forest.maps.region_size),
		"ids": forest._types.ids(), "out": PackedByteArray(), "any": false, "hash": 0, "core": ForestNativeRes.core()}
	_jobs[WorkerThreadPool.add_task(_run_summary.bind(job), false, "forest_far_summary")] = job


## WORKER. A map's summary, whether it has cover, and the hash of its bytes; a map of a size the forest refuses (not
## region_size / t, t one of ForestMaps.ALLOWED_T) has none, as the near forest grows nothing from it.
static func _run_summary(job: Dictionary) -> void:
	var img: Image = job["img"]
	var rs: int = job["rs"]
	var w := img.get_width()
	job["hash"] = hash(img.get_data())
	if w <= 0 or w != img.get_height() or rs % w != 0 or not ((rs / w) in ForestMapsRes.ALLOWED_T):
		return
	if img.get_format() != Image.FORMAT_RGBA8:
		img = img.duplicate() as Image
		img.convert(Image.FORMAT_RGBA8)
	var s: Dictionary = job["core"].far_summarise(img.get_data(), w, int(job["w"]), job["ids"])
	job["out"] = s["texels"]
	job["any"] = bool(s["any"])


## THE WORKER GETS THE BYTES, NOT THE IMAGE: a streamed region's height map is the terrain's live one, which the main
## thread rewrites (a recomposite replaces its data, a sculpt writes pixels) while the job runs; taken here, the bytes
## are the worker's own (copy on write).
func _submit_sample(loc: Vector2i, img: Image) -> void:
	var job := {"kind": "height", "loc": loc, "data": img.get_data(), "w": img.get_width(), "h": img.get_height(),
		"s": int(round(_rm() / float(forest.far_grid_m))),
		"step": float(forest.far_grid_m) / float(forest.maps.vertex_spacing), "out": PackedFloat32Array(),
		"core": ForestNativeRes.core()}
	_jobs[WorkerThreadPool.add_task(_run_sample.bind(job), false, "forest_far_ground")] = job


## WORKER. A region's ground at the shell's grid: s² heights from its height map, row-major from its corner (the native
## core's sampler).
static func _run_sample(job: Dictionary) -> void:
	job["out"] = job["core"].far_sample_ground(job["data"], int(job["w"]), int(job["h"]), int(job["s"]), float(job["step"]))


func _submit_build(c: Vector2i) -> void:
	var cr := _cr()
	var rm := _rm()
	var sums := {}
	var grounds := {}
	for loc in _window(c):
		sums[loc] = _summaries.get(loc, PackedByteArray())
		grounds[loc] = _heights.get(loc, PackedFloat32Array())
	var p := {"origin": Vector2(float(c.x), float(c.y)) * rm * float(cr), "cell_m": rm * float(cr), "rm": rm,
		"grid_m": float(forest.far_grid_m), "texel_m": float(forest.far_texel_m),
		"out_w": int(round(rm / float(forest.far_texel_m))), "s": int(round(rm / float(forest.far_grid_m))),
		"sums": sums, "grounds": grounds, "heights": _palette.heights_table(), "styles": _palette.styles(),
		"rules": forest.far_rules(), "seed": int(forest.forest_seed)}
	var job := {"kind": "build", "cell": c, "gen": int(_cells[c]["gen"]), "p": p, "out": {}, "core": ForestNativeRes.core()}
	_jobs[WorkerThreadPool.add_task(_run_build.bind(job), false, "forest_far_build")] = job


## WORKER. A cell's mesh arrays and its own far texels (the margin cut off, mipmapped) for the shader: the native core
## assembles the cell from its window's summaries and grounds and builds its shell.
static func _run_build(job: Dictionary) -> void:
	var res: Dictionary = job["core"].far_build_cell(job["p"])
	var tw := int(res.get("tw", 0))
	if tw <= 0:
		job["out"] = {"arrays": [], "quads": 0, "tex": null}
		return
	var tex := Image.create_from_data(tw, tw, false, Image.FORMAT_RGBA8, res["texels"])
	tex.generate_mipmaps()
	job["out"] = {"arrays": res["arrays"], "quads": int(res["quads"]), "tex": tex}


## Land finished workers (on this thread): summaries and samples kept (a summary for a map painted meanwhile is dropped:
## it was asked again), builds made into the cell's node, AT MOST ONE A TICK: a cell's mesh, texture and
## node are main-thread work the frame's box shares, so a finished build waits its turn in _jobs, and a tick that
## finishes last tick's landing lands no other. `block` (tests, build_now) lands them all.
func _land_jobs(block: bool) -> void:
	var sliced := not block
	var built := false
	if sliced and not _landing.is_empty():
		_finish_landing()
		built = true
	for id in _jobs.keys():
		if not block and not WorkerThreadPool.is_task_completed(id):
			continue
		if sliced and String((_jobs[id] as Dictionary)["kind"]) == "build":
			if built:
				continue
			built = true
		WorkerThreadPool.wait_for_task_completion(id)
		var job: Dictionary = _jobs[id]
		_jobs.erase(id)
		match String(job["kind"]):
			"summary":
				var loc: Vector2i = job["loc"]
				if int(job["gen"]) != int(_sum_gen.get(loc, 0)):
					continue
				_set_summary(loc, job["out"], bool(job["any"]), int(job["hash"]))
			"height":
				_heights[job["loc"]] = job["out"]
				_asked_h.erase(job["loc"])
			"build":
				_land_build(job, sliced)


## A build into its cell: its mesh, then (this tick, or the next when the mesh used the box up: `sliced`) its texture,
## material and node. Until then the cell draws the shell it had.
func _land_build(job: Dictionary, sliced := false) -> void:
	var c: Vector2i = job["cell"]
	var cell: Dictionary = _cells.get(c, {})
	if cell.is_empty() or int(cell["gen"]) != int(job["gen"]):
		stats["dropped"] = int(stats["dropped"]) + 1
		return
	var out: Dictionary = job["out"]
	var arrays: Array = out["arrays"]
	if arrays.is_empty():
		_drop_node(c)
		return
	var mesh := ArrayMesh.new()
	mesh.add_surface_from_arrays(Mesh.PRIMITIVE_TRIANGLES, arrays, [], {}, MESH_FORMAT)
	if sliced and box_until_us > 0 and Time.get_ticks_usec() > box_until_us:
		_landing = {"job": job, "mesh": mesh}
		return
	_finish_build(job, mesh)


## Last tick's landing, finished: dropped when its cell was wanted again meanwhile.
func _finish_landing() -> void:
	var l := _landing
	_landing = {}
	var job: Dictionary = l["job"]
	var cell: Dictionary = _cells.get(job["cell"], {})
	if cell.is_empty() or int(cell["gen"]) != int(job["gen"]):
		stats["dropped"] = int(stats["dropped"]) + 1
		return
	_finish_build(job, l["mesh"])


## A built cell's texture, material and node.
func _finish_build(job: Dictionary, mesh: ArrayMesh) -> void:
	var c: Vector2i = job["cell"]
	var cell: Dictionary = _cells[c]
	var out: Dictionary = job["out"]
	cell["quads"] = int(out["quads"])
	var p: Dictionary = job["p"]
	var rules: Dictionary = p["rules"]
	var tw := int(round(float(p["cell_m"]) / float(p["texel_m"])))
	var mat := material_for(ImageTexture.create_from_image(out["tex"]), _palette_tex, p["origin"], float(p["cell_m"]), tw,
		_band, float(rules["coast"]), float(rules["mid"]))
	var mi = cell.get("node")
	if mi == null or not is_instance_valid(mi):
		mi = MeshInstance3D.new()
		mi.name = "%s%d_%d" % [NAME_PREFIX, c.x, c.y]
		mi.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
		add_child(mi)
		cell["node"] = mi
	mi.mesh = mesh
	mi.material_override = mat
	stats["built"] = int(stats["built"]) + 1


func _drop_node(c: Vector2i) -> void:
	var cell: Dictionary = _cells.get(c, {})
	if cell.is_empty():
		return
	var mi = cell.get("node")
	if mi != null and is_instance_valid(mi):
		remove_child(mi)
		mi.queue_free()
	cell["node"] = null
	cell["quads"] = 0


## The paint touched since the last flush, at most every TOUCH_MS (`force`: now): each region under it whose map bytes
## changed is summarised again, and the cells within one quad of the touch rebuilt.
func _flush_touches(force: bool) -> void:
	if _touched.is_empty():
		return
	var now := Time.get_ticks_msec()
	if not force and now - _flush_ms < TOUCH_MS:
		return
	_flush_ms = now
	var rm := _rm()
	var cm := rm * float(_cr())
	var g := float(forest.far_grid_m)
	var cells := {}
	for r in _touched:
		var rect: Rect2 = r
		var changed := false
		for lz in range(floori(rect.position.y / rm), floori((rect.end.y - 0.001) / rm) + 1):
			for lx in range(floori(rect.position.x / rm), floori((rect.end.x - 0.001) / rm) + 1):
				var loc := Vector2i(lx, lz)
				var img: Image = forest.maps.image_now(loc)
				var h := hash(img.get_data()) if img != null else 0
				if _summaries.has(loc) and int(_map_hash.get(loc, -1)) == h:
					continue
				changed = true
				_summaries.erase(loc)
				_asked_sum.erase(loc)
				_sum_gen[loc] = int(_sum_gen.get(loc, 0)) + 1
		if not changed:
			continue
		var grown := rect.grow(g)
		for cz in range(floori(grown.position.y / cm), floori((grown.end.y - 0.001) / cm) + 1):
			for cx in range(floori(grown.position.x / cm), floori((grown.end.x - 0.001) / cm) + 1):
				cells[Vector2i(cx, cz)] = true
	_touched.clear()
	for c in cells:
		_want_cell(c)


func _warn_once(key: String, msg: String) -> void:
	if _warned.has(key):
		return
	_warned[key] = true
	ForestLogRes.warn(msg)
