# Copyright (c) 2026 Digitzone
# SPDX-License-Identifier: MIT
extends RefCounted
## The native scatter through the spawner's own job: each type on its own texels,
## the grid exact; a type the profile lacks grows nothing; roads win, a map tree by road_margin, a single tree by its
## own margin; natural trees only where the clearing noise allows, groves a subset; single trees and rows where
## ForestTrees.planted puts them; west and south of the origin; the same job the same bytes, forest_seed another forest;
## a map whose bytes do not match its width refused with a reason; a job keeps the tables it was given; eight workers on
## one core at once agree; the wood-membership cells follow the clutter switch.
##
## Run with a unit-suite runner: static run() returns {name, passed, failed, details}.

const Veg := preload("res://addons/wuifwoud/forest_spawner.gd")
const VA := preload("res://addons/wuifwoud/forest_assets.gd")
const PackOf := preload("res://addons/wuifwoud/tests/fixtures/pack_of.gd")
const NativeRes := preload("res://addons/wuifwoud/forest_native.gd")
const TreesRes := preload("res://addons/wuifwoud/forest_trees.gd")
const WfPoints := preload("res://addons/wuifwoud/tests/fixtures/wf_points.gd")
const ForestConfigRes := preload("res://addons/wuifwoud/forest_config.gd")
const ForestLogRes := preload("res://addons/wuifwoud/forest_log.gd")
const PROFILE_PATH := "user://wf_c1_scatter_profile.json"
const CAT := {
	"default_pack": {"mesh_dir": "res://addons/wuifwoud/tests/fake/m/", "ext": ".glb",
		"tex_dir": "res://addons/wuifwoud/tests/fake/t/"},
	"packs": {},
	"species": {
		"W_Old": {"kind": "tree", "trunk_radius": 0.3, "crown": "conifer", "mature": true},
		"W_Young": {"kind": "tree", "trunk_radius": 0.1, "crown": "conifer", "young": true},
		"W_Bush": {"kind": "bush", "trunk_radius": 0.0, "crown": "broadleaf"},
		"W_Plum": {"kind": "tree", "trunk_radius": 0.2, "crown": "broadleaf"},
	},
}
const SPECIES := {"coast": [["W_Old", 1.0], ["W_Young", 1.0]], "mid": [["W_Old", 1.0], ["W_Young", 1.0]],
	"high": [["W_Old", 1.0], ["W_Young", 1.0]], "bush": [["W_Bush", 1.0]], "orchard": [["W_Plum", 1.0]]}
const BANDS := {"coast_top_m": 10.0, "mid_top_m": 500.0, "treeline_m": 900.0, "treeline_keep": 0.35}


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


static func _map(w: int, px: Array, patch := Rect2i(), ppx := [0, 0, 0, 0]) -> Image:
	var img := Image.create_empty(w, w, false, Image.FORMAT_RGBA8)
	img.fill(Color8(px[0], px[1], px[2], px[3]))
	if patch.size != Vector2i.ZERO:
		img.fill_rect(patch, Color8(ppx[0], ppx[1], ppx[2], ppx[3]))
	return img


## A spawner on a profile of a natural Wood (clump `clump`) and a 7 m Orchard, its maps configured for 256 m regions.
static func _spawner(clump := 0.0, with_orchard := true):
	var types := [{"id": 1, "name": "Wood", "style": "natural", "density_per_m2": 0.04, "understory": 0.0,
		"dead_frac": 0.0, "clump": clump}]
	if with_orchard:
		types.append({"id": 2, "name": "Orchard", "style": "grid", "pitch_m": 7.0})
	var f := FileAccess.open(PROFILE_PATH, FileAccess.WRITE)
	f.store_string(JSON.stringify({"bands": BANDS, "species": SPECIES, "dead": {}, "types": types}))
	f.close()
	var vp = Veg.new()
	vp.profile_path = PROFILE_PATH
	vp._load_profile()
	vp.maps.configure(256, 1.0, "")
	vp.maps.type_ids = vp._types.ids()
	return vp


static func _pts(job: Dictionary) -> Array:
	return WfPoints.decode(job["pts"], job.get("tables"))


static func _seeds(pts: Array) -> Dictionary:
	var out := {}
	for pt in pts:
		out[pt["seed"]] = pt["p"]
	return out


static func run() -> Dictionary:
	var r := {"name": "wf_scatter", "passed": 0, "failed": 0, "details": []}
	var core = NativeRes.core()
	_chk(r, "the native core is built (if not: build it, see the addon's README)", core != null)
	if core == null:
		return r
	var keep: Callable = ForestLogRes.sink
	var cap := Capture.new()
	ForestLogRes.sink = cap.take
	ForestConfigRes.use(ForestConfigRes.new())   # no fallback flora: the pools are the test profile's alone
	VA.use_packs([PackOf.make(CAT)])
	var all := Rect2(0, 0, 256, 256)
	var spawners := []

	# ── the type per texel ──
	var vp = _spawner()
	spawners.append(vp)
	vp.maps.adopt(Vector2i(0, 0), _map(256, [1, 255, 128, 0], Rect2i(128, 0, 128, 256), [2, 255, 128, 0]))
	var job: Dictionary = WfPoints.scatter(vp, all, [Vector2i(0, 0)])
	var pts := _pts(job)
	var wood := pts.filter(func(p): return p["type"] == 1)
	var orch := pts.filter(func(p): return p["type"] == 2)
	_chk(r, "each type on its own texels, the orchard the exact 7 m grid of its half: 19 x 37 = 703 (%d wood, %d orchard; %s)" % [
		wood.size(), orch.size(), str(job["pts"].get("error", ""))],
		wood.size() > 500 and wood.all(func(p): return (p["p"] as Vector2).x < 128.0 + 0.45 * 5.0)
		and orch.size() == 703 and orch.all(func(p): return ((p["p"] as Vector2).x >= 128.0
			and is_equal_approx(fposmod((p["p"] as Vector2).x - 3.5, 7.0), 0.0))))
	var stray: Dictionary = vp._scatter_job(all, false, [Vector2i(0, 0)], [])
	stray["view"] = {Vector2i(0, 0): {"w": 256, "data": _map(256, [9, 255, 128, 0]).get_data()}}
	stray["blocks"] = {Vector2i(0, 0): PackedInt32Array([9]), Vector2i(1, 1): PackedInt32Array([9])}
	vp._run_scatter_job_body(stray)
	_chk(r, "a type the profile lacks grows nothing, even where a block names it (%d)" % Veg.point_count(stray["pts"]),
		Veg.point_count(stray["pts"]) == 0 and str(stray["pts"]["error"]) == "")

	# ── roads win: a map tree by road_margin, a single tree by its own margin ──
	var vr = _spawner()
	spawners.append(vr)
	vr.maps.adopt(Vector2i(0, 0), _map(256, [1, 255, 128, 0], Rect2i(128, 0, 128, 256), [2, 255, 128, 0]))
	vr.road_margin = 3.0
	vr.item_road_margin = 0.0
	vr.set_road_segments(PackedFloat64Array([60.0, 0.0, 60.0, 256.0, 2.0, 160.0, 0.0, 160.0, 256.0, 2.0]))
	vr.trees.add({"kind": "tree", "at": Vector2(61.0, 100.0), "type": 1, "age": 0.0, "species": "", "clear_m": 0.0,
		"edited": false})
	vr.trees.add({"kind": "tree", "at": Vector2(63.5, 120.0), "type": 1, "age": 0.0, "species": "", "clear_m": 0.0,
		"edited": false})
	var rp := _pts(WfPoints.scatter(vr, all, [Vector2i(0, 0)], vr._items_for(all)))
	var near_road := rp.filter(func(p): return (not bool(p.get("item", false))
		and (absf((p["p"] as Vector2).x - 60.0) < 5.0 or absf((p["p"] as Vector2).x - 160.0) < 5.0)))
	var road_items := rp.filter(func(p): return bool(p.get("item", false)))
	_chk(r, "roads win: no map tree within half width + road_margin (5 m) of either road; a single tree in the corridor dropped, one 3.5 m off its centre (past its half width) kept (%d, %s)" % [
		near_road.size(), str(road_items.map(func(p): return p["p"]))],
		near_road.is_empty() and road_items.size() == 1 and (road_items[0]["p"] as Vector2).is_equal_approx(Vector2(63.5, 120.0)))

	# ── clearings and groves ──
	var vc = _spawner()
	spawners.append(vc)
	vc.maps.adopt(Vector2i(0, 0), _map(256, [1, 255, 128, 0]))
	var cp := _pts(WfPoints.scatter(vc, all, [Vector2i(0, 0)]))
	var in_glade := cp.filter(func(p): return float(core.noise_at(p["p"], 0)) < 0.28 - 1.0e-4)
	var grid_cells := 52 * 52    # 5 m pitch over 256 m: 52 a side
	_chk(r, "clearings: every natural tree where the clearing noise is at least its floor, and some of the grid falls in clearings (%d of %d; %d in a glade)" % [
		cp.size(), grid_cells, in_glade.size()], in_glade.is_empty() and cp.size() > 1000 and cp.size() < grid_cells)
	var vg = _spawner(1.0)
	spawners.append(vg)
	vg.maps.adopt(Vector2i(0, 0), _map(256, [1, 255, 128, 0]))
	var gp := _seeds(_pts(WfPoints.scatter(vg, all, [Vector2i(0, 0)])))
	var cs := _seeds(cp)
	_chk(r, "groves: clump 1 keeps fewer trees than clump 0, every one of them clump 0's (%d of %d)" % [gp.size(), cs.size()],
		gp.size() > 200 and gp.size() < cs.size() and gp.keys().all(func(k): return cs.has(k) and cs[k] == gp[k]))

	# ── single trees and rows at their exact spots ──
	var vi = _spawner()
	spawners.append(vi)
	vi.maps.adopt(Vector2i(0, 0), _map(256, [1, 255, 128, 0]))
	vi.trees.add({"kind": "row", "points": PackedVector2Array([Vector2(20, 100), Vector2(100, 100)]), "type": 1,
		"age": 0.5, "species": "W_Plum", "spacing_m": 8.0, "clear_m": 2.5, "edited": false})
	var items: Array = vi._items_for(all)
	var ip := _pts(WfPoints.scatter(vi, all, [Vector2i(0, 0)], items)).filter(func(p): return bool(p.get("item", false)))
	var want: Array = TreesRes.trees_in(items, all, vi.forest_seed)
	var exact := ip.size() == want.size() and ip.size() == 11
	for k in mini(ip.size(), want.size()):
		exact = exact and (ip[k]["p"] as Vector2).is_equal_approx(want[k]["p"]) and ip[k]["species"] == "W_Plum" \
			and is_equal_approx(float(ip[k]["age"]), 0.5)
	_chk(r, "a row's trees are where ForestTrees.planted puts them, with the row's species and age (%d)" % ip.size(), exact)

	# ── west and south of the origin ──
	var vn = _spawner()
	spawners.append(vn)
	vn.maps.adopt(Vector2i(-1, -1), _map(256, [1, 255, 128, 0], Rect2i(0, 0, 128, 256), [2, 255, 128, 0]))
	var west := Rect2(-256, -256, 256, 256)
	var np := _pts(WfPoints.scatter(vn, west, [Vector2i(-1, -1)]))
	var norch := np.filter(func(p): return p["type"] == 2)
	_chk(r, "west and south of the origin: every point inside its cell, the orchard the same 703 (%d)" % norch.size(),
		norch.size() == 703 and np.all(func(p): return west.grow(5.0).has_point(p["p"]))
		and norch.all(func(p): return (p["p"] as Vector2).x < -128.0))

	# ── determinism; forest_seed ──
	var again: Dictionary = WfPoints.scatter(vp, all, [Vector2i(0, 0)])
	vp.forest_seed = 1
	var reroll := _seeds(_pts(WfPoints.scatter(vp, all, [Vector2i(0, 0)])))
	vp.forest_seed = 0
	var first := _seeds(pts)
	_chk(r, "the same job twice: the same bytes; forest_seed 1: no seed shared (%d)" % reroll.size(),
		var_to_bytes(again["pts"]) == var_to_bytes(job["pts"]) and not reroll.is_empty()
		and reroll.keys().all(func(k): return not first.has(k)))

	# ── refused inputs ──
	var bad: Dictionary = vp._scatter_job(all, false, [Vector2i(0, 0)], [])
	bad["view"] = {Vector2i(0, 0): {"w": 256, "data": PackedByteArray([1, 2, 3])}}
	vp._run_scatter_job_body(bad)
	_chk(r, "a map whose bytes do not match its width: no points, and why (%s)" % str(bad.get("error", "")),
		Veg.point_count(bad["pts"]) == 0 and str(bad.get("error", "")) != "")

	# ── a job keeps the tables it was given ──
	var held: Dictionary = vp._scatter_job(all, false, [Vector2i(0, 0)], [])
	var old_tables = vp._tables_now()
	var vt = _spawner(0.0, false)        # the profile file rewritten without the orchard
	spawners.append(vt)
	vp._load_profile()
	var new_tables = vp._tables_now()
	vp._run_scatter_job_body(held)
	var held_orch := _pts(held).filter(func(p): return p["type"] == 2)
	_chk(r, "a job keeps the tables it was given: the profile reloaded without the orchard meanwhile, the job's orchard still 703 (%d; new tables: %s)" % [
		held_orch.size(), str(Array(new_tables.type_ids()))],
		held_orch.size() == 703 and not is_same(old_tables, new_tables) and Array(new_tables.type_ids()) == [1])

	# ── eight workers on one core ──
	var jobs := []
	var tasks := []
	for _i in 8:
		var j: Dictionary = vc._scatter_job(all, false, [Vector2i(0, 0)], [])
		jobs.append(j)
		tasks.append(WorkerThreadPool.add_task(vc._run_scatter_job_body.bind(j), false, "wf_c1_test"))
	for t in tasks:
		WorkerThreadPool.wait_for_task_completion(t)
	var b0 := var_to_bytes(jobs[0]["pts"])
	_chk(r, "eight workers on one core at once: eight byte-identical results (%d points)" % Veg.point_count(jobs[0]["pts"]),
		Veg.point_count(jobs[0]["pts"]) == cp.size() and jobs.all(func(j): return var_to_bytes(j["pts"]) == b0))

	# ── the wood-membership cells ──
	vc.clutter_enabled = true
	var won: Dictionary = WfPoints.scatter(vc, all, [Vector2i(0, 0)])
	vc.clutter_enabled = false
	var woff: Dictionary = WfPoints.scatter(vc, all, [Vector2i(0, 0)])
	var wcells: PackedInt32Array = won["wood"]
	_chk(r, "the wood-membership cells: with the clutter ring on, each natural tree's 16 m cell, once; off, none (%d)" % (wcells.size() / 3),
		wcells.size() == 16 * 16 * 3 and (woff["wood"] as PackedInt32Array).is_empty())

	# ── the worker adds no key to its job ──
	# A Dictionary that grows on one thread while another reads it is a data race (the main thread reads the job's
	# "task" every tick while the worker runs), so every key the worker writes is in the job before it is submitted.
	var kj: Dictionary = vi._scatter_job(all, false, [Vector2i(0, 0)], items)
	var kbefore := kj.keys()
	vi._run_scatter_job(kj)
	var kadded := kj.keys().filter(func(k): return not (k in kbefore))
	_chk(r, "a scatter job holds every key its worker writes before it is submitted, the task's too (added: %s)" % str(kadded),
		kadded.is_empty() and kbefore.has("task"))

	for n in spawners:
		n._drain_scatter_jobs()
		n.free()
	DirAccess.remove_absolute(ProjectSettings.globalize_path(PROFILE_PATH))
	ForestConfigRes.use(null)
	VA.forget_packs()
	ForestLogRes.sink = keep
	return r
