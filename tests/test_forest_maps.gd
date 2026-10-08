# Copyright (c) 2026 Digitzone
# SPDX-License-Identifier: MIT
extends RefCounted
## ForestMaps: a map's texel size read from its own size, per map: maps of different sizes
## coexist in either order; a map that fits no size, or is no image, is no forest (one error); a non-RGBA8 map
## converted; the addressing; the 64 m block summary; a type id the profile lacks named once; the budget in bytes,
## counted in the largest map held; keep_only; and the REAL read path: a file through the
## threaded loader and a worker's summary, released and read AGAIN (a worker's own load() of the same path answers
## null the second time, so this is read twice on purpose). The edit mode: editable images (the held map, a blank one
## at the nearest map's t, none off the terrain), edited maps never released, refresh (bytes and the touched blocks'
## summary), pixel_at, saving and the unsaved registry, a failed save staying dirty. save_map's one way of writing;
## an import's catch-up, the unsaved copies, an unreadable map, the scene after Save As.
##
## Run with a unit-suite runner: static run() returns {name, passed, failed, details}.

const MapsRes := preload("res://addons/wuifwoud/forest_maps.gd")
const ForestLogRes := preload("res://addons/wuifwoud/forest_log.gd")
const DIR := "user://wf_b1_maps"
const NONE := [0, 255, 128, 0]


class Capture:
	var lines: Array = []

	func take(level: StringName, msg: String) -> void:
		lines.append([level, msg])

	func count(level: StringName) -> int:
		return lines.filter(func(l): return l[0] == level).size()


static func _chk(r: Dictionary, n: String, ok: bool) -> void:
	if ok:
		r.passed += 1
	else:
		r.failed += 1
		r.details.append("✗ " + n)


## A w-texel square RGBA8 map filled with `px` ([r, g, b, a]), the texels of `patch` set to `ppx`.
static func _map(w: int, px: Array, patch := Rect2i(), ppx := [0, 0, 0, 0]) -> Image:
	var img := Image.create_empty(w, w, false, Image.FORMAT_RGBA8)
	img.fill(Color8(px[0], px[1], px[2], px[3]))
	if patch.size != Vector2i.ZERO:
		img.fill_rect(patch, Color8(ppx[0], ppx[1], ppx[2], ppx[3]))
	return img


static func _maps(rs: int, ids := PackedInt32Array([1, 2, 3])):
	var m = MapsRes.new()
	m.configure(rs, 1.0, "")
	m.type_ids = ids
	return m


static func run() -> Dictionary:
	var r := {"name": "forest_maps", "passed": 0, "failed": 0, "details": []}
	var keep: Callable = ForestLogRes.sink
	var cap := Capture.new()
	ForestLogRes.sink = cap.take

	# ── t from the size ──
	var ts := []
	for w in [256, 128, 64, 32]:
		var m = _maps(256)
		m.adopt(Vector2i(0, 0), _map(w, NONE))
		var v: Dictionary = m.view([Vector2i(0, 0)])
		ts.append(256 / int(v[Vector2i(0, 0)]["w"]) if v.has(Vector2i(0, 0)) else 0)
	_chk(r, "every allowed t is held at its own size: %s" % str(ts), ts == [1, 2, 4, 8])

	# ── a size that fits no allowed t is no forest, one error each ──
	var mb = _maps(256)
	cap.lines.clear()
	mb.adopt(Vector2i(0, 0), _map(100, NONE))
	mb.adopt(Vector2i(1, 0), _map(16, NONE))    # t = 16 is not allowed
	_chk(r, "a map that fits no t is no forest, one error each (%d)" % cap.count(&"error"),
		not mb.has_map(Vector2i(0, 0)) and not mb.has_map(Vector2i(1, 0)) and cap.count(&"error") == 2)

	# ── maps of different t coexist, whatever order they arrive in (the order follows a peer's camera: a forest that
	#    depended on it would differ between two peers with the same maps) ──
	var orders := []
	for order in [[0, 1], [1, 0]]:
		var mt = _maps(256)
		var given := [_map(128, [1, 255, 128, 0]), _map(256, [2, 255, 128, 0])]
		cap.lines.clear()
		for i in order:
			mt.adopt(Vector2i(i, 0), given[i])
		var vt: Dictionary = mt.view([Vector2i(0, 0), Vector2i(1, 0)])
		orders.append([mt.is_held(Vector2i(0, 0)), mt.is_held(Vector2i(1, 0)),
			MapsRes.texel(vt, 256.0, 10.0, 10.0) & 0xFF, MapsRes.texel(vt, 256.0, 266.0, 10.0) & 0xFF,
			cap.count(&"error")])
	_chk(r, "maps of different t coexist, in either order (%s)" % str(orders),
		orders == [[true, true, 1, 2, 0], [true, true, 1, 2, 0]])

	# ── a non-RGBA8 map is converted, with one warning ──
	var mc = _maps(64)
	var rgb := Image.create_empty(64, 64, false, Image.FORMAT_RGB8)
	rgb.fill(Color8(2, 255, 128))
	cap.lines.clear()
	mc.adopt(Vector2i(0, 0), rgb)
	var vc: Dictionary = mc.view([Vector2i(0, 0)])
	_chk(r, "a non-RGBA8 map is converted and held, one warning (%d)" % cap.count(&"warn"),
		mc.is_held(Vector2i(0, 0)) and (MapsRes.texel(vc, 64.0, 10.0, 10.0) & 0xFF) == 2 and cap.count(&"warn") == 1)

	# ── addressing: floor(local / (t · spacing)); negative regions; no map = -1 ──
	var ma = _maps(256)
	ma.adopt(Vector2i(0, 0), _map(128, NONE, Rect2i(10, 20, 1, 1), [3, 200, 40, 0]))
	ma.adopt(Vector2i(-1, -1), _map(128, NONE, Rect2i(10, 20, 1, 1), [2, 255, 128, 0]))
	var va: Dictionary = ma.view([Vector2i(0, 0), Vector2i(-1, -1)])
	var hit: int = MapsRes.texel(va, 256.0, 21.0, 41.0)          # texel (10, 20) spans x 20..22, z 40..42
	var edge: int = MapsRes.texel(va, 256.0, 19.9, 41.0)         # texel (9, 20)
	var neg: int = MapsRes.texel(va, 256.0, -256.0 + 21.0, -256.0 + 41.0)
	var off: int = MapsRes.texel(va, 256.0, 300.0, 10.0)         # region (1, 0) has no map
	_chk(r, "texel addressing (hit %x edge %x neg %x off %d)" % [hit, edge, neg, off],
		hit == (3 | 200 << 8 | 40 << 16) and edge == (0 | 255 << 8 | 128 << 16) and (neg & 0xFF) == 2 and off == -1)

	# ── the block summary: type ids per world-anchored 64 m block ──
	var ms = _maps(256, PackedInt32Array([3, 5]))
	ms.adopt(Vector2i(1, 0), _map(256, NONE, Rect2i(70, 10, 11, 11), [3, 255, 128, 0]))   # world x 326..337
	var bl: Dictionary = ms.blocks_in([Vector2i(1, 0)], Rect2(256, 0, 256, 256))
	_chk(r, "the summary: type 3 in block (5, 0) only (%s)" % str(bl),
		bl.size() == 1 and bl.has(Vector2i(5, 0)) and Array(bl[Vector2i(5, 0)]) == [3])

	# ── a type id the profile lacks: no block lists it, named once over every map ──
	var mu = _maps(256, PackedInt32Array([3]))
	cap.lines.clear()
	mu.adopt(Vector2i(0, 0), _map(256, NONE, Rect2i(0, 0, 8, 8), [9, 255, 128, 0]))
	mu.adopt(Vector2i(1, 0), _map(256, NONE, Rect2i(0, 0, 8, 8), [9, 255, 128, 0]))
	var w9 := cap.lines.filter(func(l): return l[0] == &"warn" and String(l[1]).contains("type 9"))
	_chk(r, "an unknown type id: one warning (%d), no block lists it" % w9.size(),
		w9.size() == 1 and mu.blocks_in([Vector2i(0, 0)], Rect2(0, 0, 256, 256)).is_empty())

	# ── the budget is in bytes, counted in the largest map held so far, and never 0 ──
	var mg = _maps(1024)
	var b1: int = mg.budget_regions()
	mg.adopt(Vector2i(0, 0), _map(512, NONE))
	var b2: int = mg.budget_regions()
	mg.adopt(Vector2i(1, 0), _map(1024, NONE))
	var b3: int = mg.budget_regions()
	mg.budget_mb = 0.001
	_chk(r, "budget: 16 maps of 4 MB, 64 of 1 MB, 16 once a 4 MB map is held, never 0 (%d %d %d %d)" % [b1, b2, b3,
		mg.budget_regions()], b1 == 16 and b2 == 64 and b3 == 16 and mg.budget_regions() == 1)

	# ── keep_only never drops an adopted map ──
	var mk = _maps(64)
	mk.adopt(Vector2i(0, 0), _map(64, NONE))
	mk.keep_only({})
	_chk(r, "keep_only keeps an adopted map", mk.is_held(Vector2i(0, 0)))

	# ── the real read path, twice ──
	DirAccess.make_dir_recursive_absolute(DIR)
	var p0 := DIR.path_join(Terrain3DUtil.location_to_filename(Vector2i(0, 0)))
	var p1 := DIR.path_join(Terrain3DUtil.location_to_filename(Vector2i(-1, 0)))
	var src := _map(128, NONE, Rect2i(0, 0, 64, 128), [1, 255, 128, 0])
	ResourceSaver.save(src, p0, ResourceSaver.FLAG_COMPRESS)
	ResourceSaver.save(_map(100, NONE), p1, ResourceSaver.FLAG_COMPRESS)      # a wrong size on disk
	var mf = MapsRes.new()
	mf.configure(128, 1.0, DIR)
	mf.type_ids = PackedInt32Array([1])
	var locs: Array = Array(mf.locations())
	locs.sort()
	_chk(r, "the folder's maps are listed (%s)" % str(locs), locs == [Vector2i(-1, 0), Vector2i(0, 0)])
	var size0 := FileAccess.get_file_as_bytes(p0).size()
	_chk(r, "a saved map is compressed (%d < %d bytes)" % [size0, 128 * 128 * 4], size0 > 0 and size0 < 128 * 128 * 4)
	var reads := []
	for _pass in 2:
		mf.request(Vector2i(0, 0))
		var pending: bool = mf.is_pending(Vector2i(0, 0))
		mf.collect(true)
		var vf: Dictionary = mf.view([Vector2i(0, 0)])
		var same: bool = vf.has(Vector2i(0, 0)) and (vf[Vector2i(0, 0)]["data"] as PackedByteArray) == src.get_data()
		reads.append([pending, mf.is_held(Vector2i(0, 0)), MapsRes.texel(vf, 128.0, 10.0, 50.0) & 0xFF,
			MapsRes.texel(vf, 128.0, 100.0, 50.0) & 0xFF, same,
			mf.blocks_in([Vector2i(0, 0)], Rect2(0, 0, 128, 128)).size()])
		mf.keep_only({})
	_chk(r, "read, released, read again: the same map both times (%s)" % str(reads),
		reads.size() == 2 and reads.all(func(x): return x == [true, true, 1, 0, true, 2])
		and not mf.is_held(Vector2i(0, 0)) and int(mf.stats["reloads"]) == 1)
	cap.lines.clear()
	mf.request(Vector2i(-1, 0))
	mf.collect(true)
	mf.request(Vector2i(-1, 0))
	_chk(r, "a wrong size on disk: no forest, one error, not asked for again (%d)" % cap.count(&"error"),
		not mf.has_map(Vector2i(-1, 0)) and not mf.is_pending(Vector2i(-1, 0)) and cap.count(&"error") == 1)
	# ── edit mode ──
	var me = _maps(256)
	me.editing = true
	me.region_exists = func(l: Vector2i) -> bool: return l != Vector2i(5, 5)
	me.adopt(Vector2i(0, 0), _map(128, [1, 255, 128, 0]))        # held, t = 2
	var held_img: Image = me.edit_image(Vector2i(0, 0))
	var blank: Image = me.edit_image(Vector2i(1, 0))               # no map: blank, at the nearest held map's t
	var offt = me.edit_image(Vector2i(5, 5))                       # the terrain has no region there
	_chk(r, "edit_image: the held map; a blank map at the nearest map's t; none off the terrain (%s %s %s)" % [
		str(held_img != null), str(blank.get_width() if blank != null else -1), str(offt)],
		held_img != null and held_img.get_data() == _map(128, [1, 255, 128, 0]).get_data()
		and blank != null and blank.get_width() == 128 and blank.get_pixel(5, 5) == Color8(0, 255, 128, 0)
		and offt == null and me.has_map(Vector2i(1, 0)) and Array(me.locations()).has(Vector2i(1, 0)))
	me.mark_dirty(Vector2i(1, 0))
	me.keep_only({})
	_chk(r, "keep_only keeps edited and unsaved maps", me.is_held(Vector2i(0, 0)) and me.is_held(Vector2i(1, 0)))
	blank.fill_rect(Rect2i(0, 0, 8, 8), Color8(2, 255, 128, 255))   # 16 m at world x 256..272, z 0..16
	var before_b: Dictionary = me.blocks_in([Vector2i(1, 0)], Rect2(256, 0, 256, 256))
	me.refresh(Vector2i(1, 0), Rect2i(0, 0, 8, 8))
	var after_b: Dictionary = me.blocks_in([Vector2i(1, 0)], Rect2(256, 0, 256, 256))
	var vr: Dictionary = me.view([Vector2i(1, 0)])
	_chk(r, "refresh: the view's bytes and the touched block's summary follow the edit (%s -> %s)" % [str(before_b),
		str(after_b)], before_b.is_empty() and after_b.keys() == [Vector2i(4, 0)]
		and Array(after_b[Vector2i(4, 0)]) == [2] and (MapsRes.texel(vr, 256.0, 260.0, 4.0) & 0xFF) == 2
		and me.world_rect(Vector2i(1, 0), Rect2i(0, 0, 8, 8)) == Rect2(256, 0, 16, 16))
	_chk(r, "pixel_at reads the newest texel with its mark; [] where nothing is held (%s %s)" % [
		str(me.pixel_at(258.0, 2.0)), str(me.pixel_at(900.0, 2.0))],
		Array(me.pixel_at(258.0, 2.0)) == [2, 255, 128, 255] and me.pixel_at(900.0, 2.0).is_empty())
	var ms2 = MapsRes.new()
	ms2.configure(128, 1.0, DIR)
	ms2.type_ids = PackedInt32Array([1])
	ms2.editing = true
	ms2.scene_path = "scene_a.tscn"
	var ei: Image = ms2.edit_image(Vector2i(2, 0))
	ei.fill_rect(Rect2i(0, 0, 4, 4), Color8(1, 255, 128, 255))
	ms2.mark_dirty(Vector2i(2, 0))
	var listed: bool = MapsRes.unsaved_for("scene_a.tscn").has(ms2) \
		and not MapsRes.unsaved_for("scene_b.tscn").has(ms2)
	var saved: Dictionary = ms2.save_dirty()
	var p2 := DIR.path_join(Terrain3DUtil.location_to_filename(Vector2i(2, 0)))
	var back := ResourceLoader.load(p2, "", ResourceLoader.CACHE_MODE_IGNORE) as Image
	_chk(r, "save_dirty writes the edited map compressed; the scene's unsaved list empties (%s)" % str(saved),
		listed and saved.get(Vector2i(2, 0)) == OK and back != null and back.get_data() == ei.get_data()
		and FileAccess.get_file_as_bytes(p2).size() < 128 * 128 * 4 and not ms2.unsaved()
		and not MapsRes.unsaved_for("scene_a.tscn").has(ms2))
	var mr = MapsRes.new()                                         # final review #3: the map is on disk, not held
	mr.configure(128, 1.0, DIR)
	mr.type_ids = PackedInt32Array([1])
	_chk(r, "pixel_at reads a map that is not held from its file (%s)" % str(mr.pixel_at(257.0, 1.0)),
		not mr.is_held(Vector2i(2, 0)) and Array(mr.pixel_at(257.0, 1.0)) == [1, 255, 128, 255]
		and not mr.is_held(Vector2i(2, 0)))
	var mn = MapsRes.new()
	mn.configure(64, 1.0, "")                                      # no maps directory: nowhere to save
	mn.editing = true
	mn.edit_image(Vector2i(0, 0))
	mn.mark_dirty(Vector2i(0, 0))
	cap.lines.clear()
	var failed: Dictionary = mn.save_dirty()
	_chk(r, "a failed save stays dirty, one error (%s)" % str(failed),
		failed.get(Vector2i(0, 0)) == ERR_FILE_BAD_PATH and mn.unsaved() and cap.count(&"error") == 1)

	# ── an import's catch-up reaches every live instance of its folder ──
	var mla = MapsRes.new()
	mla.configure(64, 1.0, "user://wf_b2b_live/forest")
	mla.type_ids = PackedInt32Array([1])
	mla.editing = true
	var ea2: Image = mla.edit_image(Vector2i(0, 0))
	ea2.set_pixel(1, 1, Color8(1, 255, 128, 255))
	mla.mark_dirty(Vector2i(0, 0))
	mla.edit_image(Vector2i(1, 0))                                  # edited, never changed: clean
	var mlb = MapsRes.new()
	mlb.configure(64, 1.0, "user://wf_b2b_live/forest/")            # the same folder, written differently
	var mlc = MapsRes.new()
	mlc.configure(64, 1.0, "user://wf_b2b_other/forest")
	var copies: Dictionary = mla.dirty_images()
	(copies[Vector2i(0, 0)] as Image).set_pixel(2, 2, Color8(3, 255, 128, 255))
	_chk(r, "dirty_images: copies of the unsaved maps only (%s)" % str(copies.keys()),
		copies.keys() == [Vector2i(0, 0)] and ea2.get_pixel(2, 2).r8 != 3)
	var live: Array = MapsRes.live_for("user://wf_b2b_live/forest")
	var n_caught: int = MapsRes.imported({"dir": "user://wf_b2b_live/forest", "written": [Vector2i(0, 0)],
		"deleted": [], "deleted_no_region": []})
	_chk(r, "an import's catch-up: every live instance of its folder, none of another; the written maps dropped and clean; the generation moves (%d %s)" % [
		n_caught, str([mla.generation, mlb.generation, mlc.generation])],
		n_caught == 2 and live.has(mla) and live.has(mlb) and not live.has(mlc) and not mla.unsaved()
		and [mla.generation, mlb.generation, mlc.generation] == [1, 1, 0] and not mla.is_held(Vector2i(0, 0))
		and mla.is_held(Vector2i(1, 0)))

	# ── final review: a run that changed nothing (cancelled, or stopped by an error) catches nothing up ──
	var mz = MapsRes.new()
	mz.configure(64, 1.0, "user://wf_b2b_cancel/forest")
	mz.editing = true
	(mz.edit_image(Vector2i(0, 0)) as Image).set_pixel(1, 1, Color8(1, 255, 128, 255))
	mz.mark_dirty(Vector2i(0, 0))
	var nz: int = MapsRes.imported({"dir": "user://wf_b2b_cancel/forest", "cancelled": true, "written": [],
		"deleted": [], "deleted_no_region": []})
	_chk(r, "a run that changed nothing catches nothing up: the generation stays, the unsaved paint stays (%d %d)" % [nz,
		mz.generation], nz == 0 and mz.generation == 0 and mz.unsaved())

	# ── an unreadable map is never edited, so a save never overwrites it ──
	DirAccess.make_dir_recursive_absolute(DIR)
	var pj := DIR.path_join(Terrain3DUtil.location_to_filename(Vector2i(3, 0)))
	var jf := FileAccess.open(pj, FileAccess.WRITE)
	jf.store_string("not a map")
	jf.close()
	var muj = MapsRes.new()
	muj.configure(128, 1.0, DIR)
	muj.type_ids = PackedInt32Array([1])
	muj.editing = true
	cap.lines.clear()
	var none_img = muj.edit_image(Vector2i(3, 0))
	muj.save_dirty()
	_chk(r, "an unreadable map is not edited and stays as it was; named once (%s)" % str(muj.unreadable),
		none_img == null and muj.unreadable.has(Vector2i(3, 0)) and muj.edit_image(Vector2i(3, 0)) == null
		and FileAccess.get_file_as_string(pj) == "not a map" and cap.count(&"error") == 1)

	# ── the scene the maps belong to follows Save As ──
	var ms3 = MapsRes.new()
	ms3.configure(64, 1.0, "")
	ms3.editing = true
	var where := ["scene_c.tscn"]
	ms3.scene_of = func() -> String: return where[0]
	ms3.edit_image(Vector2i(0, 0))
	ms3.mark_dirty(Vector2i(0, 0))
	var at_c: bool = MapsRes.unsaved_for("scene_c.tscn").has(ms3)
	where[0] = "scene_d.tscn"
	_chk(r, "the scene the maps belong to follows Save As (%s)" % ms3.scene(),
		at_c and MapsRes.unsaved_for("scene_d.tscn").has(ms3) and not MapsRes.unsaved_for("scene_c.tscn").has(ms3))

	# ── every writer writes a map the same way: compressed, its resource id fixed ──
	var sm := _map(64, [1, 255, 128, 0])
	DirAccess.make_dir_recursive_absolute(DIR.path_join(".st"))
	var pa := DIR.path_join("save_a.res")
	var pb := DIR.path_join(".st").path_join("save_b.res")
	var ea: Error = MapsRes.save_map(sm, pa)
	var eb: Error = MapsRes.save_map(_map(64, [1, 255, 128, 0]), ProjectSettings.globalize_path(pb))
	var back_s := ResourceLoader.load(pa, "", ResourceLoader.CACHE_MODE_IGNORE) as Image
	_chk(r, "save_map: the same map is the same bytes at any path, absolute or not, and reads back (%s %s)" % [
		error_string(ea), error_string(eb)], ea == OK and eb == OK
		and FileAccess.get_file_as_bytes(pa) == FileAccess.get_file_as_bytes(pb)
		and FileAccess.get_file_as_bytes(pa).size() < 64 * 64 * 4 and back_s != null and back_s.get_data() == sm.get_data())

	for f in [p0, p1, p2, pa, pb, pj]:
		DirAccess.remove_absolute(ProjectSettings.globalize_path(f))
	DirAccess.remove_absolute(ProjectSettings.globalize_path(DIR.path_join(".st")))
	DirAccess.remove_absolute(ProjectSettings.globalize_path(DIR))
	ForestLogRes.sink = keep
	return r
