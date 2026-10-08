# Copyright (c) 2026 Digitzone
# SPDX-License-Identifier: MIT
extends RefCounted
## ForestFar: on a spawner with adopted maps (256 m regions, one-region cells), a far cell is built
## for every map's cell and its neighbours that see cover (the forest's own cells whole, the walls of its edges in the
## next ones) and none where no cover is near; the material carries the cards' end and the handover; the quality tier
## moves the handover; switched off, no far forest and every cell gone; a forest region with no ground grows nothing far
## away and is said once; the debug numbers. A paint stroke regrows the far cells it reaches, at most every 250 ms; a
## build that lands after its cell was wanted again is dropped; a Place edit (map bytes unchanged) rebuilds nothing;
## Re-grow all and an import's catch-up rebuild every cell, Reload types the palette too; a map file asked for twice at
## once is given to both.
##
## Run with a unit-suite runner: static run() returns {name, passed, failed, details}.

const Veg := preload("res://addons/wuifwoud/forest_spawner.gd")
const VA := preload("res://addons/wuifwoud/forest_assets.gd")
const PackOf := preload("res://addons/wuifwoud/tests/fixtures/pack_of.gd")
const ForestConfigRes := preload("res://addons/wuifwoud/forest_config.gd")
const ForestLogRes := preload("res://addons/wuifwoud/forest_log.gd")
const ForestMapsRes := preload("res://addons/wuifwoud/forest_maps.gd")
const FakeTerrain := preload("res://addons/wuifwoud/tests/fixtures/fake_terrain.gd")
const PROFILE_PATH := "user://wf_b3_far_profile.json"
const CAT := {
	"default_pack": {"mesh_dir": "res://addons/wuifwoud/tests/fake/m/", "ext": ".glb",
		"tex_dir": "res://addons/wuifwoud/tests/fake/t/"},
	"packs": {},
	"species": {
		"W_Old": {"kind": "tree", "trunk_radius": 0.3, "crown": "conifer", "mature": true},
		"W_Bush": {"kind": "bush", "trunk_radius": 0.0, "crown": "broadleaf"},
		"W_Plum": {"kind": "tree", "trunk_radius": 0.2, "crown": "broadleaf"},
	},
}
const PROFILE := {
	"bands": {"coast_top_m": 10.0, "mid_top_m": 500.0, "treeline_m": 900.0, "treeline_keep": 0.35},
	"species": {"coast": [["W_Old", 1.0]], "mid": [["W_Old", 1.0]], "high": [["W_Old", 1.0]],
		"bush": [["W_Bush", 1.0]], "orchard": [["W_Plum", 1.0]]},
	"dead": {},
	"types": [
		{"id": 1, "name": "Wood", "style": "natural", "density_per_m2": 0.04},
		{"id": 2, "name": "Orchard", "style": "grid", "pitch_m": 7.0},
	],
}


class Capture:
	var lines: Array = []

	func take(level: StringName, msg: String) -> void:
		lines.append([level, msg])


static func _chk(r: Dictionary, n: String, ok: bool) -> void:
	if ok:
		r.passed += 1
	else:
		r.failed += 1
		r.details.append("✗ " + n)


static func _map(w: int, px: Array) -> Image:
	var img := Image.create_empty(w, w, false, Image.FORMAT_RGBA8)
	img.fill(Color8(px[0], px[1], px[2], px[3]))
	return img


## A spawner over 256 m regions with one-region far cells, maps adopted (no files), the far forest's ground flat at
## 10 m and its colours and heights injected (the test catalog has no bakes).
static func _spawner():
	var vp = Veg.new()
	vp.profile_path = PROFILE_PATH
	vp._load_profile()
	vp.maps.configure(256, 1.0, "")
	vp.maps.type_ids = vp._types.ids()
	vp.far_cell_regions = 1
	return vp


static func _far_of(vp) -> Object:
	vp._ensure_far()
	vp._far.heights_of = func(_loc: Vector2i) -> PackedFloat32Array:
		var a := PackedFloat32Array()
		a.resize(16 * 16)
		a.fill(10.0)
		return a
	vp._far.colour_of = func(_sp: String): return Color(0.05, 0.2, 0.05)
	vp._far.height_of = func(_sp: String) -> float: return 20.0
	return vp._far


static func _cells(far) -> Array:
	var out := []
	for c in far.get_children():
		if String(c.name).begins_with("Far_"):
			out.append(String(c.name))
	out.sort()
	return out


static func _quads(far, nm: String) -> int:
	var mi := far.get_node_or_null(nm) as MeshInstance3D
	if mi == null or mi.mesh == null:
		return 0
	return (mi.mesh.surface_get_arrays(0)[Mesh.ARRAY_INDEX] as PackedInt32Array).size() / 6


static func run() -> Dictionary:
	var r := {"name": "forest_far", "passed": 0, "failed": 0, "details": []}
	var keep: Callable = ForestLogRes.sink
	var cap := Capture.new()
	ForestLogRes.sink = cap.take
	ForestConfigRes.use(ForestConfigRes.new())
	VA.use_packs([PackOf.make(CAT)])
	var pf := FileAccess.open(PROFILE_PATH, FileAccess.WRITE)
	pf.store_string(JSON.stringify(PROFILE))
	pf.close()
	var ft = FakeTerrain.new()
	ft.region_size = 256

	var vp = _spawner()
	vp.maps.adopt(Vector2i(0, 0), _map(256, [1, 255, 128, 0]))
	vp.maps.adopt(Vector2i(1, 0), _map(256, [1, 255, 128, 0]))
	vp.maps.adopt(Vector2i(5, 0), _map(256, [0, 255, 128, 0]))
	var far = _far_of(vp)
	far.build_now(ft)
	var names := _cells(far)
	_chk(r, "the forest's cells whole, their walls in the 10 cells around, none where no cover is near (%s)" % str(names),
		names.size() == 12 and not names.has("Far_5_0") and _quads(far, "Far_0_0") == 256
		and _quads(far, "Far_1_0") == 256 and _quads(far, "Far_2_0") == 16 and _quads(far, "Far_-1_-1") == 1
		and int(far.info()["quads"]) == 612)
	var mi := far.get_node_or_null("Far_0_0") as MeshInstance3D
	var mat: ShaderMaterial = mi.material_override if mi != null else null
	var box: AABB = mi.mesh.get_aabb() if mi != null else AABB()
	_chk(r, "a cell's material carries the cards' end and the handover; its shell stands from 5 m (the skirt) to the canopy (%s)" % str(box),
		mat != null and is_equal_approx(float(mat.get_shader_parameter("far_cut")), vp.billboard_far_m)
		and is_equal_approx(float(mat.get_shader_parameter("fade_m")), vp.far_fade_m)
		and mi.cast_shadow == GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
		and box.position.y >= 4.99 and box.end.y > 25.0 and box.end.y <= 10.0 + 22.5 * 1.3 + 0.01)
	vp.apply_quality_params({"visibility": 200.0, "lod_bias": 1.0, "shadow_ring": 100.0, "billboard_far": 1800.0,
		"density_scale": 1.0})
	_chk(r, "the quality tier moves the handover (%s)" % str(mat.get_shader_parameter("far_cut") if mat != null else null),
		mat != null and is_equal_approx(float(mat.get_shader_parameter("far_cut")), 1800.0))
	var info: Dictionary = vp.debug_churn().get("far", {})
	_chk(r, "the debug numbers (%s)" % str(info),
		int(info.get("cells", 0)) == 12 and int(info.get("pending", -1)) == 0 and int(info.get("built", 0)) == 12
		and int(info.get("regions", 0)) == 3 and info.has("ms"))
	# ── one build a tick; a spent box lands its mesh one tick and its texture and node the next ──
	var vl = _spawner()
	vl.maps.adopt(Vector2i(0, 0), _map(256, [1, 255, 128, 0]))
	vl.maps.adopt(Vector2i(1, 0), _map(256, [1, 255, 128, 0]))
	var fl = _far_of(vl)
	fl._start()
	fl._advance(ft)
	fl._land_jobs(true)                      # the summaries
	fl._advance(ft)                          # the ground (injected)
	fl._advance(ft)                          # every build submitted
	var pending: int = fl._jobs.size()
	var t_wait := Time.get_ticks_msec()
	while fl._jobs.keys().any(func(id): return not WorkerThreadPool.is_task_completed(id)) \
			and Time.get_ticks_msec() - t_wait < 10000:
		OS.delay_msec(1)
	fl.box_until_us = 1                      # a box already spent
	var seen := []
	for _t in 4:
		fl._land_jobs(false)
		seen.append([int(fl.stats["built"]), not fl._landing.is_empty()])
	fl.box_until_us = 0                      # no box: a whole build a tick
	fl._land_jobs(false)
	var open_box := int(fl.stats["built"])
	fl.build_now(ft)
	_chk(r, "the far landing: one build a tick; with the box spent its mesh one tick, its texture and node the next; the same shells in the end (%d builds; %s; %d; %d cells)" % [
		pending, str(seen), open_box, _cells(fl).size()],
		pending == 12 and seen == [[0, true], [1, false], [1, true], [2, false]] and open_box == 3
		and _cells(fl).size() == 12 and _quads(fl, "Far_0_0") == 256 and fl._landing.is_empty())
	vl.free()

	# ── with no colours injected, the palette reads one species a tick (two in its pools) ──
	var vw = _spawner()
	vw.maps.adopt(Vector2i(0, 0), _map(256, [1, 255, 128, 0]))
	vw._ensure_far()
	var fw = vw._far
	var starts := []
	for _t in 4:
		starts.append(fw._start())
	_chk(r, "the far palette reads one species' colour a tick, then starts (%s; %d read)" % [str(starts), fw._colours.size()],
		starts == [false, true, true, true] and fw._colours.size() == 2 and fw._palette != null)
	vw.free()

	# ── the editor's edits ──
	vp.maps.editing = true
	var img: Image = vp.maps.edit_image(Vector2i(0, 0))
	img.fill_rect(Rect2i(0, 0, 128, 256), Color8(0, 255, 128, 0))
	vp.maps.refresh(Vector2i(0, 0), Rect2i(0, 0, 128, 256))
	var b0 := int(far.stats["built"])
	vp.regrow(Rect2(0, 0, 128, 256))
	far.build_now(ft)
	var after := _cells(far)
	_chk(r, "a stroke erasing the left half regrows the cells it reaches: its wall moved in, the cells west of it gone (%s; %d built)" % [
		str(after), int(far.stats["built"]) - b0],
		_quads(far, "Far_0_0") == 144 and not after.has("Far_-1_0") and not after.has("Far_-1_1") and after.size() == 9
		and int(far.stats["built"]) - b0 == 3)
	far._flush_ms = -100000
	far.touch(Rect2(0, 0, 8, 8))
	far._flush_touches(false)
	far.touch(Rect2(0, 0, 8, 8))
	far._flush_touches(false)
	_chk(r, "touches are flushed at most every 250 ms (%d waiting)" % far._touched.size(), far._touched.size() == 1)
	far._touched.clear()
	var b1 := int(far.stats["built"])
	vp.regrow(Rect2(200, 200, 10, 10))
	far.build_now(ft)
	_chk(r, "a Place edit (the map's bytes unchanged) rebuilds nothing (%d)" % (int(far.stats["built"]) - b1),
		int(far.stats["built"]) == b1)
	# A build that lands after its cell was wanted again is dropped.
	img.fill_rect(Rect2i(0, 0, 96, 64), Color8(1, 255, 128, 0))
	vp.maps.refresh(Vector2i(0, 0), Rect2i(0, 0, 96, 64))
	far.touch(Rect2(0, 0, 96, 64))
	far._flush_touches(true)
	far._advance(ft)
	far._land_jobs(true)
	far._advance(ft)
	var in_flight: int = far._jobs.size()
	img.fill_rect(Rect2i(96, 0, 16, 64), Color8(1, 255, 128, 0))
	vp.maps.refresh(Vector2i(0, 0), Rect2i(96, 0, 16, 64))
	far.touch(Rect2(96, 0, 16, 64))
	far._flush_touches(true)
	var d0 := int(far.stats["dropped"])
	far._land_jobs(true)
	far.build_now(ft)
	_chk(r, "a build that lands after its cell was wanted again is dropped; the newer one stands (%d in flight, %d dropped, %d quads)" % [
		in_flight, int(far.stats["dropped"]) - d0, _quads(far, "Far_0_0")],
		in_flight == 4 and int(far.stats["dropped"]) - d0 == 2 and _quads(far, "Far_0_0") == 179)
	var b2 := int(far.stats["built"])
	vp.regrow_all()
	far.build_now(ft)
	_chk(r, "Re-grow all (an import's catch-up) rebuilds every cell (%d of %d)" % [int(far.stats["built"]) - b2,
		int(far.info()["cells"])], int(far.stats["built"]) - b2 == int(far.info()["cells"]))
	var p0 = far._palette
	vp.reload_types()
	far.build_now(ft)
	_chk(r, "Reload types builds the palette again", far._palette != p0 and far._palette != null and int(far.info()["cells"]) > 0)
	DirAccess.make_dir_recursive_absolute(ProjectSettings.globalize_path("user://wf_b3_far"))
	var mp := "user://wf_b3_far/terrain3d_00_00.res"
	ForestMapsRes.save_map(_map(256, [1, 255, 128, 0]), mp)
	var e1 := ResourceLoader.load_threaded_request(mp, "", false, ResourceLoader.CACHE_MODE_IGNORE)
	var e2 := ResourceLoader.load_threaded_request(mp, "", false, ResourceLoader.CACHE_MODE_IGNORE)
	while ResourceLoader.load_threaded_get_status(mp) == ResourceLoader.THREAD_LOAD_IN_PROGRESS:
		OS.delay_usec(500)
	var got1 = ResourceLoader.load_threaded_get(mp)
	var got2 = ResourceLoader.load_threaded_get(mp)
	_chk(r, "a map file asked for twice at once (the near forest and the far one) is given to both",
		e1 == OK and e2 == OK and got1 is Image and got2 is Image)
	DirAccess.remove_absolute(ProjectSettings.globalize_path(mp))
	DirAccess.remove_absolute(ProjectSettings.globalize_path("user://wf_b3_far"))
	vp.far_forest = false
	vp._far_tick(ft)
	_chk(r, "switched off: no far forest, every cell gone", vp._far == null and vp.get_child_count(true) == 0)

	var vo = _spawner()
	vo.far_forest = false
	vo._far_tick(ft)
	_chk(r, "off from the start: nothing is made", vo._far == null and vo.get_child_count(true) == 0)

	var vn = _spawner()
	vn.maps.adopt(Vector2i(0, 0), _map(256, [1, 255, 128, 0]))
	vn._ensure_far()
	vn._far.colour_of = func(_sp: String): return Color(0.05, 0.2, 0.05)
	vn._far.height_of = func(_sp: String) -> float: return 20.0
	var n0 := cap.lines.size()
	vn._far.build_now(ft)
	vn._far.build_now(ft)
	var said := cap.lines.slice(n0).filter(func(l): return String(l[1]).contains("no ground for region (0, 0)")).size()
	_chk(r, "a forest region with no ground (no region file, none streamed): no shell over it, said once (%d)" % said,
		_cells(vn._far).is_empty() and said == 1)

	# The final review's fixes.
	var vh = _spawner()
	vh._ensure_far()
	var hm := Image.create_empty(1024, 1024, false, Image.FORMAT_RF)
	hm.fill(Color(10.0, 0.0, 0.0))
	vh._far._submit_sample(Vector2i(0, 0), hm)
	hm.fill(Color(999.0, 0.0, 0.0))   # the main thread writes it (a terrain's recomposite, a sculpt) while the job runs
	vh._far._land_jobs(true)
	var hs: PackedFloat32Array = vh._far._heights.get(Vector2i(0, 0), PackedFloat32Array())
	_chk(r, "a height map handed to a worker is read as it was handed, though the main thread writes it after (%s)" % str(hs.slice(0, 3)),
		hs.size() == 256 and Array(hs).all(func(v): return is_equal_approx(v, 10.0)))
	var vb = _spawner()
	vb.maps.adopt(Vector2i(0, 0), _map(256, [1, 255, 128, 0]))
	_far_of(vb)
	vb._scatter_jobs.append({"task": -1})   # the near forest has work in flight
	vb._far.tick(ft)
	var held: int = vb._far._jobs.size() + vb._far._loads.size()
	vb._scatter_jobs.clear()
	vb._far.tick(ft)
	var unsettled: int = vb._far._jobs.size() + vb._far._loads.size()
	var pal_held = vb._far._palette   # its palette reads the bakes on this thread: not before the near forest is done
	vb._settled = true   # the ring around the player has filled once
	vb._far.tick(ft)
	_chk(r, "the near forest first: nothing far starts (not even its palette) while it has work in flight, nor before its ring has filled once (%d, %d, %s, then %d)" % [
		held, unsettled, str(pal_held != null), vb._far._jobs.size()],
		held == 0 and unsettled == 0 and pal_held == null and vb._far._jobs.size() > 0)
	var vq = _spawner()
	vq._ensure_far()
	vq.apply_quality_params({"visibility": 200.0, "lod_bias": 1.0, "shadow_ring": 100.0, "billboard_far": 3000.0,
		"density_scale": 1.0})
	var band_hi: Vector2 = vq._far._band
	vq.apply_quality_params({"visibility": 200.0, "lod_bias": 1.0, "shadow_ring": 100.0, "billboard_far": 1800.0,
		"density_scale": 1.0})
	var band_lo: Vector2 = vq._far._band
	vq.apply_quality_params({"visibility": 200.0, "lod_bias": 1.0, "shadow_ring": 100.0, "billboard_far": 0.0,
		"density_scale": 1.0})
	var band_none: Vector2 = vq._far._band
	_chk(r, "the shell's handover covers the cards' own dissolve (660 m under 3000 m cards, 600 m under 1800 m); cards that never end, no shell (%s %s %s)" % [
		str(band_hi), str(band_lo), str(band_none)],
		band_hi.is_equal_approx(Vector2(3000.0, 660.0)) and band_lo.is_equal_approx(Vector2(1800.0, 600.0))
		and band_none.x >= 1.0e8)

	for v in [vp, vo, vn, vh, vb, vq]:
		if v._far != null:
			v._far.drain()
		v.free()
	DirAccess.remove_absolute(ProjectSettings.globalize_path(PROFILE_PATH))
	ForestConfigRes.use(null)
	VA.forget_packs()
	ForestLogRes.sink = keep
	return r
