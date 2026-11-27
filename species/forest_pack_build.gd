# Copyright (c) 2026 Digitzone
# SPDX-License-Identifier: MIT
@tool
extends RefCounted
## One pack build: every species of `packs` that needs building (`force`: every one; `only`: those ids), one at a time
## on the main thread, poll by poll. Each is PREPARED (ForestAssets.prepare_species_of, the forest's own preparation)
## and saved to the staging folder; its impostor BAKED (ForestImpostorBaker, a row of views a round, once per drawn
## frame) and its picture rendered (ForestPicture), then its sheets COMPRESSED and its picture filtered on a worker
## (image work only) with the far palette's crown colour read from the compressed albedo, while the next species
## prepares and bakes (at most MAX_STORES compressing at once, each holding two full-size sheets); then, oldest first,
## it LANDS: its sheets saved, its files renamed from the staging folder into the pack's built/, then its entry written
## to built.json, so a species lands whole or not at all. Cancel stops at the next poll: the species already landed
## stay, the current one leaves nothing. The editor polls it every frame (start(host), poll()), the command line too
## (res://addons/wuifwoud/tools/build_packs.gd); tests run it without a bake (run_now()).
##
## WHY THE MAIN THREAD: every mesh read and texture save goes through the rendering server, and
## under its "Safe" thread model a worker's read waits for the main thread's next flush.

## The build ended: its report.
signal finished(report: Dictionary)

## The species' assets (the preparation).
const AssetsRes := preload("res://addons/wuifwoud/forest_assets.gd")
## A pack's species.
const SpeciesRes := preload("res://addons/wuifwoud/species/forest_species.gd")
## A built species.
const BuiltRes := preload("res://addons/wuifwoud/species/forest_built_species.gd")
## The impostor baker.
const BakerRes := preload("res://addons/wuifwoud/species/forest_impostor_baker.gd")
## The filled leaf sheets.
const LeafRes := preload("res://addons/wuifwoud/species/forest_leaf_sheet.gd")
## The far palette (its mean colour).
const PaletteRes := preload("res://addons/wuifwoud/forest_far_palette.gd")
## The species' picture.
const PictureRes := preload("res://addons/wuifwoud/species/forest_picture.gd")
## A pack's manifest file in built/.
const MANIFEST := "built.json"
## The staging folder inside built/: hidden, so the editor's file system never lists it.
const STAGING := ".building"

## The packs to build.
var packs: Array = []
## Only these ids (empty: every one).
var only := PackedStringArray()
## Build species that are built too.
var force := false
## Bake impostors (tests turn it off).
var bake := true
## The drawn-frame counter the bake steps on (a render suite forces its frames and counts them itself).
var frames: Callable = func() -> int: return Engine.get_frames_drawn()
## The report, set when the build ends.
var report := {}
var _progress := {"phase": "", "species": "", "done": 0, "total": 0}
var _cancel := false
var _running := false
var _todo: Array = []        # [{"s": ForestSpecies, "id", "dir": its pack's built dir}], decided at start
var _next := 0
var _finished_n := 0         # species of _todo landed or failed
## Built dir -> {"packs": {pack file name: true}, "ids": {species id: true}}: the packs of this build that keep their
## species in that folder (two packs in one folder share its built/), and what they hold now.
var _ids_of := {}
var _manifests := {}         # built dir -> its built.json as this build writes it
var _leaves := {}            # built dir -> {leaf file -> its texture}: each sheet made once a build and folder
var _current := {}           # the prepared species the baker has
## The stores in flight, oldest first: [{"r": the prepared species, "task": its worker task, "out": what the worker
## writes, read only once the task is done}].
var _stores: Array = []
## Stores in flight at most: each holds two full-size sheets (64 MB each at GRID 8, TILE 512).
const MAX_STORES := 2
var _baker = null
var _picture = null          # the picture rig, beside the baker
var _baked := false          # this build bakes: `bake` on, and a host to bake under
var _last_frame := -1
var _out := {}
var _t0 := 0


func _init(p_packs: Array, p_options := {}) -> void:
	packs = p_packs
	only = PackedStringArray(p_options.get("only", []))
	force = bool(p_options.get("force", false))
	bake = bool(p_options.get("bake", true))


## A pack's built.json; {} when it has none.
static func read_manifest(dir: String) -> Dictionary:
	if dir == "":
		return {}
	var p := dir.path_join(MANIFEST)
	var j: Variant = JSON.parse_string(FileAccess.get_file_as_string(p)) if FileAccess.file_exists(p) else null
	return j if j is Dictionary else {}


## A source file as built.json records it: {md5, mtime, size}; a missing one as {"md5": "", "mtime": -1, "size": -1}.
static func source_record(f: String) -> Dictionary:
	if not FileAccess.file_exists(f):
		return {"md5": "", "mtime": -1, "size": -1}
	return {"md5": FileAccess.get_md5(f), "mtime": FileAccess.get_modified_time(f), "size": _size(f)}


static func _size(f: String) -> int:
	var fa := FileAccess.open(f, FileAccess.READ)
	return fa.get_length() if fa != null else -1


## Every species of `p_packs` and whether it is built: [{pack, name, dir, species: [{id, s, state, why}]}].
## MAIN THREAD (reads built.json and the files' sizes and times; MD5 only for a file whose size or time moved).
static func states(p_packs: Array) -> Array:
	var out := []
	for p in p_packs:
		if p == null:
			continue
		var dir: String = p.built_dir()
		var man := read_manifest(dir)
		var rows := []
		for s in p.species:
			if s == null or String(s.id) == "":
				continue
			var st := state_of(s, dir, man)
			st["id"] = String(s.id)
			st["s"] = s
			rows.append(st)
		out.append({"pack": p, "name": String(p.name) if String(p.name) != "" else String(p.resource_path).get_file(),
			"dir": dir, "species": rows})
	return out


## Whether species `s` of the pack built in `dir` (its built.json `man`) is built: "missing" (its mesh does not
## resolve), "unbuilt" (no entry, or a pack that is not its own file), "needs" (another prep version, its file gone, no
## picture in a baked pack or its picture gone, a source file changed (by its size and time first, by its MD5 only when
## those moved: a copied built/ is no change), its settings changed (its leaf materials, its alpha cut) or a file's
## import settings did), else "built"; with why.
static func state_of(s, dir: String, man: Dictionary) -> Dictionary:
	var mesh := SpeciesRes.resolve(String(s.mesh))
	if mesh == "" or not ResourceLoader.exists(mesh):
		return {"state": "missing", "why": "no mesh at %s" % (mesh if mesh != "" else String(s.mesh))}
	if dir == "":
		return {"state": "unbuilt", "why": "the pack is not saved as its own file"}
	var e: Dictionary = (man.get("species", {}) as Dictionary).get(String(s.id), {})
	if e.is_empty():
		return {"state": "unbuilt", "why": "not built"}
	var v := int(e.get("prep_version", -1))
	if v != AssetsRes.PREP_VERSION:
		return {"state": "needs", "why": "built by prep version %d, now %d" % [v, AssetsRes.PREP_VERSION]}
	if not FileAccess.file_exists(dir.path_join(String(s.id) + ".res")):
		return {"state": "needs", "why": "its built file is gone"}
	if man.has("bake") and not bool(e.get("picture", false)):
		return {"state": "needs", "why": "it has no picture yet"}
	if bool(e.get("picture", false)) and not FileAccess.file_exists(dir.path_join(String(s.id) + "_picture.res")):
		return {"state": "needs", "why": "its picture is gone"}
	# A species with impostor sheets from a bake before the trimmed card and the depth sheet: it still draws (the plain
	# square, no parallax), and a build gives it both.
	if man.has("bake") and e.has("span"):
		var bk: Dictionary = man["bake"]
		var id := String(s.id)
		if int(bk.get("trim_bands", 0)) <= 0 or float(bk.get("depth_range", 0.0)) <= 0.0 \
				or String(bk.get("alpha_mips", "")) != "coverage" \
				or not FileAccess.file_exists(dir.path_join(id + "_trim.res")) \
				or not FileAccess.file_exists(dir.path_join(id + "_depth.res")):
			return {"state": "needs", "why": "its impostor has no trim or depth sheet yet"}
		var fol := SpeciesRes.resolve(String(s.foliage_albedo))
		var lf := String(e.get("leaf", ""))
		if fol != "" and (lf != LeafRes.file_for(fol, float(s.alpha_cut)) or not FileAccess.file_exists(dir.path_join(lf))):
			return {"state": "needs", "why": "its leaves have no filled sheet yet"}
	var src: Dictionary = e.get("sources", {})
	var files: PackedStringArray = s.files()
	for f in src:
		if not files.has(String(f)):
			return {"state": "needs", "why": "%s is no longer one of its files" % String(f).get_file()}
	for f in files:
		var rec = src.get(f)
		if typeof(rec) != TYPE_DICTIONARY:
			return {"state": "needs", "why": "%s is new" % f.get_file()}
		if not FileAccess.file_exists(f):
			if int(rec.get("size", 0)) == -1:
				continue
			return {"state": "needs", "why": "%s is gone" % f.get_file()}
		if int(rec.get("size", -2)) == _size(f) and int(rec.get("mtime", -2)) == FileAccess.get_modified_time(f):
			continue
		if String(rec.get("md5", "")) != FileAccess.get_md5(f):
			return {"state": "needs", "why": "%s changed" % f.get_file()}
	if not e.has("settings"):
		return {"state": "needs", "why": "built before its settings were recorded"}
	var inputs: Dictionary = s.build_inputs()
	if String(e["settings"]) != String(inputs["settings"]):
		return {"state": "needs", "why": "its settings changed"}
	# recorded since roles were tracked; an older entry has none and is taken as it is (its next build records them)
	if e.has("roles") and String(e["roles"]) != String(inputs["roles"]):
		return {"state": "needs", "why": "which file plays which part changed"}
	var imp: Dictionary = e.get("imports", {})
	for f in (inputs["imports"] as Dictionary):
		if String(imp.get(f, "")) != String(inputs["imports"][f]):
			return {"state": "needs", "why": "%s's import settings changed" % String(f).get_file()}
	return {"state": "built", "why": ""}


## The far palette's crown colour from a stored (compressed, premultiplied) albedo sheet, exactly as the palette reads a
## bake back from the GPU (ForestFarPalette._read_crown_colour): decompressed, RGBA8, its mean. Image work only.
static func crown_colour_of(stored: Image):
	var img := stored.duplicate() as Image
	if img.is_compressed() and img.decompress() != OK:
		return null
	img.convert(Image.FORMAT_RGBA8)
	return PaletteRes.mean_colour(img)


## Decides what needs building (states; the first pack's species where two hold an id, as the forest grows it), makes
## the staging folders and, when baking under `host` (null: no bake), the baker's viewports. Then poll() every frame.
func start(host: Node) -> void:
	_running = true
	_cancel = false
	_t0 = Time.get_ticks_msec()
	_out = {"built": [], "skipped": [], "failed": {}, "warnings": {}, "removed": [], "cancelled": false}
	_todo = []
	_next = 0
	_finished_n = 0
	_current = {}
	_stores = []
	_last_frame = -1
	var seen := {}
	for row in states(packs):
		var dir: String = row["dir"]
		var pf := String(row["pack"].resource_path).get_file()
		if dir != "":
			if not _manifests.has(dir):
				_manifests[dir] = read_manifest(dir)
			var held: Dictionary = _ids_of.get(dir, {"packs": {}, "ids": {}})
			(held["packs"] as Dictionary)[pf] = true
			for st in row["species"]:
				(held["ids"] as Dictionary)[st["id"]] = true
			_ids_of[dir] = held
		for st in row["species"]:
			var id: String = st["id"]
			if seen.has(id):
				continue
			seen[id] = true
			if not only.is_empty() and not only.has(id):
				continue
			if st["state"] == "missing" or dir == "":
				(_out["failed"] as Dictionary)[id] = st["why"]
			elif st["state"] == "built" and not force:
				(_out["skipped"] as Array).append(id)
			else:
				_todo.append({"s": st["s"], "id": id, "dir": dir, "pack": pf})
	for t in _todo:
		DirAccess.make_dir_recursive_absolute(_stage(t["dir"]))
	_baked = bake and host != null and not _todo.is_empty()
	if _baked:
		_baker = BakerRes.new()
		_baker.setup(host)
		_picture = PictureRes.new()
		_picture.setup(host)
	_set_progress("prepare", "", _todo.size())


## The main thread, every frame while it runs, after the frame is drawn: true once the build has ended (`finished`).
func poll() -> bool:
	if not _running:
		return true
	# The oldest store that is done lands first: the species land in the order they were baked.
	while not _stores.is_empty() and WorkerThreadPool.is_task_completed(int(_stores[0]["task"])):
		var st: Dictionary = _stores.pop_front()
		WorkerThreadPool.wait_for_task_completion(int(st["task"]))
		if _cancel:
			_discard(st["r"])
		else:
			_land(st["r"], st["out"])
	if _cancel:
		if not _stores.is_empty():
			return false             # a store is image work: it ends on its own, then is discarded
		return _stop()
	if not _current.is_empty():
		var f: int = frames.call()
		if f == _last_frame:
			return false
		_last_frame = f
		var baked: bool = _baker.step()
		var pictured: bool = _picture.step()
		if baked and pictured:
			var res: Dictionary = _baker.result()
			res["picture"] = _picture.result()
			var out := {}
			var task := WorkerThreadPool.add_task(_store.bind(res, out), true, "forest_pack_store")
			_stores.append({"r": _current, "task": task, "out": out})
			_set_progress("store", String(_current["id"]), _todo.size())
			_current = {}
		return false
	if _next >= _todo.size():
		if not _stores.is_empty():
			return false
		return _end()
	if _stores.size() >= MAX_STORES:
		return false
	var t: Dictionary = _todo[_next]
	_next += 1
	_set_progress("prepare", String(t["id"]), _todo.size())
	_prepare(t)
	return false


## This thread, start to end, without a bake (tests): the report.
func run_now() -> Dictionary:
	bake = false
	start(null)
	while not poll():
		pass
	return report


## Stop at the next poll; what landed stays.
func cancel() -> void:
	_cancel = true


## Stop build `b` now, without its landing (`on_landed`, connected to its `finished`, is disconnected first): what the
## editor does when the plugin unloads mid-build. A build that is not running is left alone.
static func stop(b, on_landed: Callable) -> void:
	if b == null or not b.is_running():
		return
	if b.finished.is_connected(on_landed):
		b.finished.disconnect(on_landed)
	b.cancel()
	while not b.poll():     # a running store is image work: it ends on its own
		OS.delay_msec(5)


## {"phase": "prepare" | "bake" | "store" | "land" | "done", "species": its id, "done": species finished, "total"}.
func progress() -> Dictionary:
	return _progress.duplicate()


## Whether the build is running.
func is_running() -> bool:
	return _running


func _set_progress(phase: String, species: String, total: int) -> void:
	_progress = {"phase": phase, "species": species, "done": _finished_n, "total": total}


func _stage(dir: String) -> String:
	return ProjectSettings.globalize_path(dir.path_join(STAGING))


## One species prepared and saved to the staging folder; its bake begun, or it lands at once when the build does not bake.
func _prepare(t: Dictionary) -> void:
	var s = t["s"]
	var id: String = t["id"]
	var p: Dictionary = AssetsRes.prepare_species_of(s)
	var r := {"id": id, "dir": t["dir"], "pack": t["pack"], "s": s,
		"warnings": PackedStringArray(p.get("warnings", PackedStringArray()))}
	if not p.has("combined"):
		var w: PackedStringArray = r["warnings"]
		_fail(r, "; ".join(w) if not w.is_empty() else "it could not be prepared")
		return
	var b = BuiltRes.new()
	b.fill(id, p, AssetsRes.PREP_VERSION)
	var path := _stage(t["dir"]).path_join(id + ".res")
	var err := ResourceSaver.save(b, path)
	if err != OK:
		_fail(r, "could not save %s: %s" % [path, error_string(err)])
		return
	var src := {}
	for f in s.files():
		src[f] = source_record(f)
	r["sources"] = src
	r["inputs"] = s.build_inputs()
	# A bush is baked too: it has no card, but the far forest's palette colours a bush-only forest type from its bake.
	if _baked:
		# The filled leaf sheet first, so the bake samples what the mesh trees will (ForestLeafSheet).
		var leaf := _leaf_sheet(s, t["dir"], r)
		var mesh: ArrayMesh = p["combined"]
		AssetsRes._dress(s, mesh, p, false, leaf)
		if _baker.begin(mesh):
			_picture.begin(mesh)
			_current = r
			_set_progress("bake", id, _todo.size())
			return
	_land(r, {"baked": _baked})


## Species `s`'s filled leaf sheet for built folder `dir`: made and staged once a build per source sheet (species
## share them), its file named in `r` ("leaf") for the landing; null when it names no foliage sheet or it will not
## load (it then draws its source, as before), with a warning when the fill or the save fails.
func _leaf_sheet(s, dir: String, r: Dictionary) -> Texture2D:
	var src := SpeciesRes.resolve(String(s.foliage_albedo))
	if src == "" or not ResourceLoader.exists(src):
		return null
	var cut := float(s.alpha_cut)
	var f := LeafRes.file_for(src, cut)
	if not _leaves.has(dir):
		_leaves[dir] = {}
	var made: Dictionary = _leaves[dir]
	if not made.has(f):
		var tex := load(src) as Texture2D
		var img := LeafRes.store(LeafRes.fill(tex.get_image() if tex != null else null, cut))
		var err := _save_sheet(img, _stage(dir).path_join(f)) if img != null else FAILED
		made[f] = ImageTexture.create_from_image(img) if err == OK else null
		if err != OK:
			var w: PackedStringArray = r["warnings"]
			w.append("its leaf sheet could not be filled or saved (%s)" % error_string(err))
			r["warnings"] = w
	if made[f] == null:
		return null
	r["leaf"] = f
	return made[f]


## The store worker: the sheets premultiplied, sized, mipmapped and BC7-compressed, the crown colour read from the
## compressed albedo: image work only (the textures are made and saved when the species lands). Writes `out`, which no
## other thread touches until the task is done.
func _store(res: Dictionary, out: Dictionary) -> void:
	out["baked"] = true
	var pic: Image = PictureRes.finish(res.get("picture"))
	if pic != null:
		out["picture"] = pic
	if int(res.get("opaque", 0)) == 0:
		out["warning"] = "its impostor rendered nothing: it has no card"
	else:
		var alb = BakerRes.store_image(res["albedo"], false, BakerRes.CARD_CUT)
		var nrm = BakerRes.store_image(res["normal"])
		if alb == null or nrm == null:
			out["warning"] = "its impostor sheets could not be compressed (BC7)"
		else:
			out.merge({"albedo": alb, "normal": nrm, "span": res["span"], "w": res["w"], "h": res["h"],
				"crown_colour": crown_colour_of(alb)})
			# The depth sheet (a bake before it had none): the card's parallax. A sheet that does not compress is
			# left out, and the card reprojects on the frames' planes alone.
			var dep = BakerRes.store_image(res["depth"], true) if res.get("depth") is Image else null
			if dep != null:
				out["depth"] = dep
			elif res.get("depth") is Image:
				out["warning"] = "its impostor depth sheet could not be compressed (BC5): its card has no parallax"
			# The card's trim, measured on the sheets AS STORED: what the card samples is what it may not cut.
			var trim = BakerRes.trim_of(alb, dep)
			if trim != null:
				out["trim"] = trim
			else:
				out["warning"] = "its impostor card could not be trimmed: it draws the full square"


## A species lands (main thread): its sheets saved to the staging folder, its files renamed into built/ (an older
## bake's sheets removed when it has none now), then its entry in built.json.
func _land(r: Dictionary, b: Dictionary) -> void:
	var id: String = r["id"]
	var dir: String = r["dir"]
	var stage := _stage(dir)
	var dst := ProjectSettings.globalize_path(dir)
	var warnings := PackedStringArray(r["warnings"])
	if b.has("warning"):
		warnings.append(String(b["warning"]))
	var files := [id + ".res"]
	var sheets := false
	if b.has("albedo"):
		# Saved as Images, their resource id fixed: the same sheet is the same bytes whoever built it (an ImageTexture
		# saves a fresh Image of its own, under a random id, every time).
		var e0 := _save_sheet(b["albedo"], stage.path_join(id + "_albedo.res"))
		var e1 := _save_sheet(b["normal"], stage.path_join(id + "_normal.res"))
		if e0 == OK and e1 == OK:
			sheets = true
			files.append_array([id + "_albedo.res", id + "_normal.res"])
		else:
			warnings.append("its impostor sheets could not be saved (%s, %s)" % [error_string(e0), error_string(e1)])
	# The depth sheet and the trim ride with the sheets they were measured with: older ones left beside new sheets
	# would shift and cut them.
	var deep := false
	if sheets and b.has("depth"):
		var ed := _save_sheet(b["depth"], stage.path_join(id + "_depth.res"))
		if ed == OK:
			deep = true
			files.append(id + "_depth.res")
		else:
			warnings.append("its impostor depth sheet could not be saved (%s)" % error_string(ed))
	if not deep and FileAccess.file_exists(dst.path_join(id + "_depth.res")):
		DirAccess.remove_absolute(dst.path_join(id + "_depth.res"))
	var trimmed := false
	if sheets and b.has("trim"):
		var et := _save_trim(b["trim"], stage.path_join(id + "_trim.res"))
		if et == OK:
			trimmed = true
			files.append(id + "_trim.res")
		else:
			warnings.append("its impostor card's trim could not be saved (%s)" % error_string(et))
	if not trimmed and FileAccess.file_exists(dst.path_join(id + "_trim.res")):
		DirAccess.remove_absolute(dst.path_join(id + "_trim.res"))
	if not sheets:
		for f in [id + "_albedo.res", id + "_normal.res"]:
			if FileAccess.file_exists(dst.path_join(f)):
				DirAccess.remove_absolute(dst.path_join(f))
	var pictured := false
	if b.has("picture"):
		var ep := _save_picture(b["picture"], stage.path_join(id + "_picture.res"))
		if ep == OK:
			pictured = true
			files.append(id + "_picture.res")
		else:
			warnings.append("its picture could not be saved (%s)" % error_string(ep))
	if not pictured and FileAccess.file_exists(dst.path_join(id + "_picture.res")):
		DirAccess.remove_absolute(dst.path_join(id + "_picture.res"))
	for f in files:
		if FileAccess.file_exists(dst.path_join(f)):
			DirAccess.remove_absolute(dst.path_join(f))
		DirAccess.rename_absolute(stage.path_join(f), dst.path_join(f))
	# The leaf sheet is shared: the first species of this build to land with it moves it in, the rest find it there.
	var leaf := String(r.get("leaf", ""))
	if leaf != "":
		if FileAccess.file_exists(stage.path_join(leaf)):
			if FileAccess.file_exists(dst.path_join(leaf)):
				DirAccess.remove_absolute(dst.path_join(leaf))
			DirAccess.rename_absolute(stage.path_join(leaf), dst.path_join(leaf))
		if not FileAccess.file_exists(dst.path_join(leaf)):
			leaf = ""
	var inputs: Dictionary = r.get("inputs", {})
	var e := {"prep_version": AssetsRes.PREP_VERSION, "pack": String(r.get("pack", "")), "sources": r.get("sources", {}),
		"settings": inputs.get("settings", ""), "roles": inputs.get("roles", ""), "imports": inputs.get("imports", {}),
		"warnings": Array(warnings)}
	if sheets:
		e["span"] = float(b["span"])
		e["w"] = float(b["w"])
		e["h"] = float(b["h"])
	if bool(b.get("baked", false)):
		var c = b.get("crown_colour") if sheets else null
		e["crown_colour"] = [c.r, c.g, c.b] if c is Color else null
	if pictured:
		e["picture"] = true
	if leaf != "":
		e["leaf"] = leaf
	var man: Dictionary = _manifests.get(dir, {})
	if _baked:
		man["bake"] = BakerRes.settings()
	if not man.has("species"):
		man["species"] = {}
	(man["species"] as Dictionary)[id] = e
	_manifests[dir] = man
	_write_manifest(dir, man)
	prune_leaves(dir, man)
	(_out["built"] as Array).append(id)
	if not warnings.is_empty():
		(_out["warnings"] as Dictionary)[id] = Array(warnings)
	_finished_n += 1
	_set_progress("land", id, _todo.size())


static func _save_sheet(img: Image, path: String) -> Error:
	img.resource_scene_unique_id = "sheet"
	return ResourceSaver.save(img, path)


## The card's trim saved as an Image, its resource id fixed (the same trim is the same bytes whoever built it).
static func _save_trim(img: Image, path: String) -> Error:
	img.resource_scene_unique_id = "trim"
	return ResourceSaver.save(img, path)


## The picture saved as an Image, its resource id fixed (the same picture is the same bytes whoever built it), compressed.
static func _save_picture(img: Image, path: String) -> Error:
	img.resource_scene_unique_id = "picture"
	return ResourceSaver.save(img, path, ResourceSaver.FLAG_COMPRESS)


func _fail(r: Dictionary, why: String) -> void:
	(_out["failed"] as Dictionary)[r["id"]] = why
	_discard(r)
	_finished_n += 1


## The leaf sheets in built folder `dir` that no species of its built.json `man` names any more: deleted.
static func prune_leaves(dir: String, man: Dictionary) -> void:
	var g := ProjectSettings.globalize_path(dir)
	if not DirAccess.dir_exists_absolute(g):
		return
	var named := {}
	for id in (man.get("species", {}) as Dictionary):
		var e = man["species"][id]
		if e is Dictionary and String(e.get("leaf", "")) != "":
			named[String(e["leaf"])] = true
	for f in DirAccess.get_files_at(g):
		if f.begins_with("leaf_") and f.ends_with(".res") and not named.has(f):
			DirAccess.remove_absolute(g.path_join(f))


## A species that does not land: its staged files deleted.
func _discard(r: Dictionary) -> void:
	if r.is_empty():
		return
	var stage := _stage(r["dir"])
	for f in [String(r["id"]) + ".res", String(r["id"]) + "_albedo.res", String(r["id"]) + "_normal.res",
			String(r["id"]) + "_depth.res", String(r["id"]) + "_trim.res", String(r["id"]) + "_picture.res"]:
		if FileAccess.file_exists(stage.path_join(f)):
			DirAccess.remove_absolute(stage.path_join(f))


func _write_manifest(dir: String, man: Dictionary) -> void:
	var path := ProjectSettings.globalize_path(dir.path_join(MANIFEST))
	if write_atomic(path, JSON.stringify(man, "  ", true, true)) != OK:
		(_out["warnings"] as Dictionary)[dir] = ["could not write %s" % dir.path_join(MANIFEST)]


## `text` written to `path` whole or not at all: a temporary file beside it, renamed over it. A failed write leaves the
## old file as it was.
static func write_atomic(path: String, text: String) -> Error:
	var tmp := path + ".tmp"
	var f := FileAccess.open(tmp, FileAccess.WRITE)
	if f == null:
		return FileAccess.get_open_error()
	f.store_string(text)
	f.close()
	var err := DirAccess.rename_absolute(tmp, path)
	if err != OK:
		DirAccess.remove_absolute(tmp)
	return err


## Whether a build's report needs the landing (the editor's rescan and regrow): it built or removed a species.
static func landed_anything(report: Dictionary) -> bool:
	return not (report.get("built", []) as Array).is_empty() or not (report.get("removed", []) as Array).is_empty()


## Cancelled, with no store running: the baker stopped, the current species discarded.
func _stop() -> bool:
	if _baker != null and _baker.busy():
		_baker.abort()
	if _picture != null and _picture.busy():
		_picture.abort()
	_discard(_current)
	_current = {}
	_out["cancelled"] = true
	return _end()


## The end: species no longer in their pack removed (a full build only), the staging folders gone, the report. A
## species is this build's to remove when a pack of this build built it (or an entry from before entries named their
## pack) and no pack of this build in its folder holds it now: another pack sharing the folder keeps its own.
func _end() -> bool:
	if not bool(_out["cancelled"]) and only.is_empty():
		for dir in _ids_of:
			var held: Dictionary = _ids_of[dir]
			var man: Dictionary = _manifests.get(dir, {})
			var gone := []
			var entries: Dictionary = man.get("species", {})
			for id in entries:
				var owner := String((entries[id] as Dictionary).get("pack", "")) if entries[id] is Dictionary else ""
				if (owner == "" or (held["packs"] as Dictionary).has(owner)) and not (held["ids"] as Dictionary).has(id):
					gone.append(id)
			for id in gone:
				for f in [String(id) + ".res", String(id) + "_albedo.res", String(id) + "_normal.res",
						String(id) + "_depth.res", String(id) + "_trim.res", String(id) + "_picture.res"]:
					var p := ProjectSettings.globalize_path(String(dir).path_join(f))
					if FileAccess.file_exists(p):
						DirAccess.remove_absolute(p)
				(man["species"] as Dictionary).erase(id)
				(_out["removed"] as Array).append(id)
			if not gone.is_empty():
				_write_manifest(dir, man)
				prune_leaves(dir, man)
	for dir in _manifests:
		var stage := _stage(dir)
		if DirAccess.dir_exists_absolute(stage):
			for f in DirAccess.get_files_at(stage):
				DirAccess.remove_absolute(stage.path_join(f))
			DirAccess.remove_absolute(stage)
	if _baker != null:
		_baker.free_nodes()
		_baker = null
	if _picture != null:
		_picture.free_nodes()
		_picture = null
	report = _out.duplicate(true)
	report["ok"] = (report["failed"] as Dictionary).is_empty() and not bool(report["cancelled"])
	report["ms"] = Time.get_ticks_msec() - _t0
	_running = false
	_set_progress("done", "", _todo.size())
	finished.emit(report)
	return true
