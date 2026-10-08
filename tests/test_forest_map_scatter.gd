# Copyright (c) 2026 Digitzone
# SPDX-License-Identifier: MIT
extends RefCounted
## Placement from the forest maps: each type walks its own grid on its own texels only; the grid
## type's count is exact; density (G) keeps a subset; the quality tier keeps a subset; age (B) picks the young or
## mature subset and slides the scale; the same map gives the same forest and forest_seed re-rolls it; a type the
## profile lacks grows nothing; a cell whose map is loading WAITS, then scatters; a cell over more maps than the budget
## still scatters. A row's trees in the scatter; the clearance (understory too); a cell with items and no map;
## a cell that grows nothing registered at once; the item gates and a pinned species; the card ring; roads win; a species the catalog lacks and a type
## the profile lacks; the unbounded mode; why an item would not grow; the profile's species; the trees file read from
## the maps folder.
##
## Run with a unit-suite runner: static run() returns {name, passed, failed, details}.

const Veg := preload("res://addons/wuifwoud/forest_spawner.gd")
const VA := preload("res://addons/wuifwoud/forest_assets.gd")
const PackOf := preload("res://addons/wuifwoud/tests/fixtures/pack_of.gd")
const MapsRes := preload("res://addons/wuifwoud/forest_maps.gd")
const ForestConfigRes := preload("res://addons/wuifwoud/forest_config.gd")
const ForestLogRes := preload("res://addons/wuifwoud/forest_log.gd")
const PROFILE_PATH := "user://wf_b1_scatter_profile.json"
const DIR := "user://wf_b1_scatter_maps"
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
const PROFILE := {
	"bands": {"coast_top_m": 10.0, "mid_top_m": 500.0, "treeline_m": 900.0, "treeline_keep": 0.35},
	"species": {"coast": [["W_Old", 1.0], ["W_Young", 1.0]], "mid": [["W_Old", 1.0], ["W_Young", 1.0]],
		"high": [["W_Old", 1.0], ["W_Young", 1.0]], "bush": [["W_Bush", 1.0]], "orchard": [["W_Plum", 1.0]]},
	"dead": {},
	"types": [
		{"id": 1, "name": "Wood", "style": "natural", "density_per_m2": 0.04, "understory": 0.0, "dead_frac": 0.0},
		{"id": 2, "name": "Orchard", "style": "grid", "pitch_m": 7.0},
	],
}

const ITEMS_PROFILE_PATH := "user://wf_b2c_scatter_profile.json"
const ITEMS_PROFILE := {
	"bands": {"coast_top_m": 10.0, "mid_top_m": 500.0, "treeline_m": 900.0, "treeline_keep": 0.35},
	"species": {"coast": [["W_Old", 1.0], ["W_Young", 1.0]], "mid": [["W_Old", 1.0], ["W_Young", 1.0]],
		"high": [["W_Old", 1.0], ["W_Young", 1.0]], "bush": [["W_Bush", 1.0]], "orchard": [["W_Plum", 1.0]]},
	"dead": {},
	"types": [{"id": 1, "name": "Wood", "style": "natural", "density_per_m2": 0.04, "understory": 1.0, "dead_frac": 0.0}],
}
const TreesRes := preload("res://addons/wuifwoud/forest_trees.gd")
const FakeTerrain := preload("res://addons/wuifwoud/tests/fixtures/fake_terrain.gd")
const FakeHeights := preload("res://addons/wuifwoud/tests/fixtures/fake_heights.gd")
const WfPoints := preload("res://addons/wuifwoud/tests/fixtures/wf_points.gd")
const NativeRes := preload("res://addons/wuifwoud/forest_native.gd")


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


## A map w texels square of one texel `px`, `patch` (texels) set to `ppx`.
static func _map(w: int, px: Array, patch := Rect2i(), ppx := [0, 0, 0, 0]) -> Image:
	var img := Image.create_empty(w, w, false, Image.FORMAT_RGBA8)
	img.fill(Color8(px[0], px[1], px[2], px[3]))
	if patch.size != Vector2i.ZERO:
		img.fill_rect(patch, Color8(ppx[0], ppx[1], ppx[2], ppx[3]))
	return img


## A spawner on the test profile, its maps configured for 256 m regions (or `dir`'s files).
static func _spawner(rs := 256, dir := ""):
	var vp = Veg.new()
	vp.profile_path = PROFILE_PATH
	vp._load_profile()
	vp.maps.configure(rs, 1.0, dir)
	vp.maps.type_ids = vp._types.ids()
	return vp


static func _scatter(vp, bb := false) -> Array:
	var job: Dictionary = WfPoints.scatter(vp, Rect2(0, 0, 256, 256), [Vector2i(0, 0)], [], bb)
	return WfPoints.decode(job["pts"], job.get("tables"))


static func _seeds(pts: Array) -> Dictionary:
	var out := {}
	for pt in pts:
		out[pt["seed"]] = pt["p"]
	return out


## A spawner on the items profile (wood with understory), its 256 m region all wood, and one row along z = 100 from x 20
## to 100 (type 1, age 0.5, W_Old pinned).
static func _row_spawner():
	var vp = Veg.new()
	vp.profile_path = ITEMS_PROFILE_PATH
	vp._load_profile()
	vp.maps.configure(256, 1.0, "")
	vp.maps.type_ids = vp._types.ids()
	vp.maps.adopt(Vector2i(0, 0), _map(256, [1, 255, 128, 0]))
	vp.trees.add({"kind": "row", "points": PackedVector2Array([Vector2(20, 100), Vector2(100, 100)]), "type": 1,
		"age": 0.5, "species": "W_Old", "spacing_m": 8.0, "clear_m": 2.5, "edited": false})
	return vp


## The region's scatter with the items reaching it, as a job gets them.
static func _scatter_with_items(vp, bb := false) -> Array:
	var rect := Rect2(0, 0, 256, 256)
	var job: Dictionary = WfPoints.scatter(vp, rect, [Vector2i(0, 0)], vp._items_for(rect), bb)
	return WfPoints.decode(job["pts"], job.get("tables"))


static func run() -> Dictionary:
	var r := {"name": "forest_map_scatter", "passed": 0, "failed": 0, "details": []}
	var keep: Callable = ForestLogRes.sink
	var cap := Capture.new()
	ForestLogRes.sink = cap.take
	# No fallback flora: the pools are the test profile's alone (a config's default is the starter's flora).
	var cfg = ForestConfigRes.new()
	cfg.disabled_packs = PackedStringArray([cfg.starter_pack_path()])
	ForestConfigRes.use(cfg)
	VA.use_packs([PackOf.make(CAT)])
	var f := FileAccess.open(PROFILE_PATH, FileAccess.WRITE)
	f.store_string(JSON.stringify(PROFILE))
	f.close()

	# ── two types side by side: each on its own texels, each at its own pitch ──
	var vp = _spawner()
	_chk(r, "the profile's types load (%s)" % str(vp._types.errors), vp._types.errors.is_empty()
		and Array(vp._types.ids()) == [1, 2])
	vp.maps.adopt(Vector2i(0, 0), _map(256, [1, 255, 128, 0], Rect2i(128, 0, 128, 256), [2, 255, 128, 0]))
	var pts := _scatter(vp)
	var wood := pts.filter(func(p): return p["type"] == 1)
	var orch := pts.filter(func(p): return p["type"] == 2)
	var wood_ok := wood.size() > 500 and wood.all(func(p): return (p["p"] as Vector2).x < 128.0 + 0.45 * 5.0)
	var orch_ok := orch.all(func(p): return ((p["p"] as Vector2).x >= 128.0
		and is_equal_approx(fposmod((p["p"] as Vector2).x - 3.5, 7.0), 0.0)))
	_chk(r, "each type on its own texels (%d wood, %d orchard)" % [wood.size(), orch.size()], wood_ok and orch_ok)
	_chk(r, "the orchard is the exact 7 m grid of its half: 19 x 37 = 703 (%d)" % orch.size(), orch.size() == 703)

	# ── density: G = 128 keeps about half, a subset of G = 255 ──
	var full = _spawner()
	full.maps.adopt(Vector2i(0, 0), _map(256, [1, 255, 128, 0]))
	var half = _spawner()
	half.maps.adopt(Vector2i(0, 0), _map(256, [1, 128, 128, 0]))
	var zero = _spawner()
	zero.maps.adopt(Vector2i(0, 0), _map(256, [1, 0, 128, 0]))
	var sf := _seeds(_scatter(full))
	var sh := _seeds(_scatter(half))
	var ratio := float(sh.size()) / maxf(float(sf.size()), 1.0)
	_chk(r, "G = 128 keeps %.2f of G = 255, every one of them; G = 0 grows nothing" % ratio,
		absf(ratio - 0.5) < 0.06 and sh.keys().all(func(k): return sf.has(k) and sf[k] == sh[k])
		and _scatter(zero).is_empty())

	# ── the quality tier is a subset too ──
	full._quality_density_scale = 0.5
	var sq := _seeds(_scatter(full))
	full._quality_density_scale = 1.0
	var qratio := float(sq.size()) / maxf(float(sf.size()), 1.0)
	_chk(r, "the quality tier at 0.5 keeps %.2f, a subset" % qratio, absf(qratio - 0.5) < 0.06
		and sq.keys().all(func(k): return sf.has(k)))

	# ── age: B = 0 is young growth, B = 255 old growth (species and scale) ──
	var ages := []
	var core = NativeRes.core()
	for b in [0, 255]:
		var va = _spawner()
		va.maps.adopt(Vector2i(0, 0), _map(256, [1, 255, b, 0]))
		var names := {}
		var lo := INF
		var hi := -INF
		# Trees clear of a glade's soft edge (the clearing noise 0.12 above its 0.28 floor): their age alone decides.
		var aged_pts := _scatter(va).filter(func(p): return (p["role"] == "tree"
			and float(core.noise_at(p["p"], va.forest_seed)) >= 0.40 + 1.0e-4))
		for inst in WfPoints.instances(WfPoints.place(va, aged_pts, [Vector2i(0, 0), WfPoints.flat(256, 50.0)], 256)):
			names[inst["mesh"]] = true
			var s: float = (inst["xf"] as Transform3D).basis.get_scale().x
			lo = minf(lo, s)
			hi = maxf(hi, s)
		ages.append([names.keys(), lo, hi, aged_pts.is_empty() or is_equal_approx(aged_pts[0]["age"], -1.0 if b == 0 else 1.0)])
		va.free()
	_chk(r, "age -1: young species, scale 0.6-1.0; age +1: mature, 1.1-1.5 (%s)" % str(ages),
		ages[0][0] == ["W_Young"] and ages[0][1] >= 0.6 - 1e-4 and ages[0][2] <= 1.0 + 1e-4 and ages[0][3]
		and ages[1][0] == ["W_Old"] and ages[1][1] >= 1.1 - 1e-4 and ages[1][2] <= 1.5 + 1e-4 and ages[1][3])

	# ── the same map, the same forest; forest_seed re-rolls it ──
	var again = _spawner()
	again.maps.adopt(Vector2i(0, 0), _map(256, [1, 255, 128, 0]))
	var reroll = _spawner()
	reroll.forest_seed = 1
	reroll.maps.adopt(Vector2i(0, 0), _map(256, [1, 255, 128, 0]))
	var sa := _seeds(_scatter(again))
	var sr := _seeds(_scatter(reroll))
	_chk(r, "deterministic (%d = %d), and forest_seed 1 shares no seed (%d)" % [sa.size(), sf.size(),
		sr.keys().filter(func(k): return sf.has(k)).size()],
		sa == sf and not sr.is_empty() and sr.keys().all(func(k): return not sf.has(k)))

	# ── a type the profile lacks grows nothing, named once ──
	cap.lines.clear()
	var vu = _spawner()
	vu.maps.adopt(Vector2i(0, 0), _map(256, [0, 255, 128, 0], Rect2i(0, 0, 64, 64), [9, 255, 128, 0]))
	var pu := _scatter(vu)
	var w9 := cap.lines.filter(func(l): return l[0] == &"warn" and String(l[1]).contains("type 9"))
	_chk(r, "type 9 (not in the profile): nothing grows (%d), one warning (%d)" % [pu.size(), w9.size()],
		pu.is_empty() and w9.size() == 1)

	# ── a cell whose map is loading waits, then scatters ──
	DirAccess.make_dir_recursive_absolute(DIR)
	for loc in [Vector2i(0, 0), Vector2i(1, 0), Vector2i(0, 1), Vector2i(1, 1)]:
		ResourceSaver.save(_map(64, [1, 255, 128, 0]), DIR.path_join(Terrain3DUtil.location_to_filename(loc)),
			ResourceSaver.FLAG_COMPRESS)
	var vw = _spawner(64, DIR)
	vw.chunk_size = 64.0
	vw._scatter_cell(Vector2i(0, 0), vw._chunks, 64.0, false)
	var waited: Dictionary = vw._chunks.get(Vector2i(0, 0), {})
	var waits := bool(waited.get("mapwait", false)) and not bool(waited.get("done", true))
	vw._feed_maps()
	vw.maps.collect(true)
	vw._feed_maps()
	vw._collect_scatter(true)
	var landed: Dictionary = vw._chunks.get(Vector2i(0, 0), {})
	_chk(r, "a cell whose map is loading waits (%s), then scatters (%d points)" % [waits,
		Veg.point_count(landed.get("pts", []))], waits and Veg.point_count(landed.get("pts", [])) > 0)

	# ── a cell over more maps than the budget still scatters ──
	var vb = _spawner(64, DIR)
	vb.maps.budget_mb = 0.001                     # one map at a time
	vb.chunk_size = 128.0                         # one cell over four 64 m regions
	vb._scatter_cell(Vector2i(0, 0), vb._chunks, 128.0, false)
	for _tick in 3:
		vb._feed_maps()
		vb.maps.collect(true)
	vb._feed_maps()
	vb._collect_scatter(true)
	var big: Dictionary = vb._chunks.get(Vector2i(0, 0), {})
	_chk(r, "a cell over 4 maps with a budget of 1 still scatters (%d points)" % Veg.point_count(big.get("pts", [])),
		Veg.point_count(big.get("pts", [])) > 0 and not bool(big.get("mapwait", false)))

	# ── single trees and rows in the scatter ──
	var ipf := FileAccess.open(ITEMS_PROFILE_PATH, FileAccess.WRITE)
	ipf.store_string(JSON.stringify(ITEMS_PROFILE))
	ipf.close()
	var iv = _row_spawner()
	var with_items := _scatter_with_items(iv)
	var item_pts := with_items.filter(func(p): return bool(p.get("item", false)))
	_chk(r, "a row's trees join the scatter: one point a planted tree, flagged item, with the row's type, age and species (%d)" % item_pts.size(),
		item_pts.size() == 11 and item_pts.all(func(p): return (p["type"] == 1 and p["species"] == "W_Old"
			and is_equal_approx(float(p["age"]), 0.5) and p["role"] == "tree")))
	var ip = _row_spawner()
	ip.trees.set_state({})
	var plain_pts := _scatter_with_items(ip)
	var row_near: Array = iv._items_for(Rect2(0, 0, 256, 256))
	var with_seeds := {}
	for wp in with_items:
		if not bool(wp.get("item", false)):
			with_seeds[wp["seed"]] = true
	var gone_parent := {}                 # a tree the row clears takes its understory bush with it, as every gate does
	for pp in plain_pts:
		if pp["role"] != "understory" and TreesRes.cleared(row_near, pp["p"]):
			gone_parent[pp["seed"]] = true
	var lost_ok := true
	var lost := 0
	var lost_under := 0
	var orphans := 0
	for pp in plain_pts:
		var inside: bool = TreesRes.cleared(row_near, pp["p"])
		var orphan: bool = not inside and pp["role"] == "understory" and gone_parent.has(int(pp["seed"]) ^ WfPoints.UNDER_TAG)
		var gone := inside or orphan
		if gone:
			lost += 1
			if pp["role"] == "understory" and inside:
				lost_under += 1
			if orphan:
				orphans += 1
		if gone == with_seeds.has(pp["seed"]):
			lost_ok = false
	_chk(r, "clearance: every map point within 2.5 m of the row is dropped, understory too, and a dropped tree's understory with it; every other is as without the row (%d dropped, %d understory inside, %d with their tree)" % [lost, lost_under, orphans],
		lost_ok and lost > 0 and lost_under > 0 and with_items.size() - item_pts.size() == plain_pts.size() - lost)
	var inm = Veg.new()
	inm.profile_path = ITEMS_PROFILE_PATH
	inm._load_profile()
	inm.chunk_size = 64.0
	inm.maps.configure(256, 1.0, "")
	inm.maps.type_ids = inm._types.ids()
	inm.trees.add({"kind": "tree", "at": Vector2(40, 40), "type": 1, "age": 0.0, "species": "", "clear_m": 3.0,
		"edited": false})
	inm._scatter_cell(Vector2i(0, 0), inm._chunks, 64.0, false)
	var queued: bool = inm._scatter_jobs.size() == 1
	inm._collect_scatter(true)
	var inm_got: Array = WfPoints.decode(inm._chunks[Vector2i(0, 0)]["pts"], inm._tables_now())
	inm._scatter_cell(Vector2i(2, 2), inm._chunks, 64.0, false)
	_chk(r, "a cell over no forest map with a single tree scatters only that tree; one with neither is registered empty at once (%d)" % inm_got.size(),
		queued and inm_got.size() == 1 and bool(inm_got[0]["item"]) and inm_got[0]["p"] == Vector2(40, 40)
		and bool(inm._chunks[Vector2i(2, 2)]["done"]) and inm._scatter_jobs.is_empty() and inm._items_planted == 1)
	var iz = _spawner()
	iz.chunk_size = 64.0
	iz.maps.adopt(Vector2i(0, 0), _map(256, [0, 255, 128, 0]))
	iz._scatter_cell(Vector2i(1, 1), iz._chunks, 64.0, false)
	_chk(r, "a cell whose held map grows nothing there, and no item, is registered empty at once: no worker",
		bool(iz._chunks[Vector2i(1, 1)]["done"]) and iz._scatter_jobs.is_empty())
	var pt_item := {"p": Vector2(50, 50), "type": 1, "seed": 12345, "role": "tree", "age": 0.0, "item": true,
		"species": ""}
	var pt_map := {"p": Vector2(50, 50), "type": 1, "seed": 12345, "role": "tree", "age": 0.0}
	var item_list := []
	var map_list := []
	for gk in 40:
		var ia := pt_item.duplicate()
		ia["seed"] = 1000 + gk
		item_list.append(ia)
		var ma := pt_map.duplicate()
		ma["seed"] = 1000 + gk
		map_list.append(ma)
	# Above the treeline (950 m), on the thinning slope (rise/run 1.0 at (50, 50)); a cliff (1.3); under the sea line.
	var slope1 := [Vector2i(0, 0), WfPoints.region(256, func(x: float, _z: float) -> float: return 950.0 + (x - 50.0))]
	var cliff := [Vector2i(0, 0), WfPoints.region(256, func(x: float, _z: float) -> float: return 100.0 + 1.3 * (x - 50.0))]
	var trees_of := func(job: Dictionary) -> int:
		return WfPoints.instances(job).filter(func(i): return str(i["mesh"]) in ["W_Old", "W_Young"]).size()
	var high_items: int = trees_of.call(WfPoints.place(iv, item_list, slope1, 256))
	var high_map_trees: int = trees_of.call(WfPoints.place(iv, map_list, slope1, 256))
	var pinned := pt_item.duplicate()
	pinned["species"] = "W_Plum"
	var pin_inst: Array = WfPoints.instances(WfPoints.place(iv, [pinned], [Vector2i(0, 0), WfPoints.flat(256, 100.0)], 256))
	_chk(r, "an item tree skips the treeline and the slope thinning but keeps the cliff cut and the sea; a pinned species is what grows (%d of 40; %d map trees)" % [high_items, high_map_trees],
		high_items == 40 and high_map_trees == 0
		and WfPoints.instances(WfPoints.place(iv, [pt_item], cliff, 256)).is_empty()
		and WfPoints.instances(WfPoints.place(iv, [pt_item], [Vector2i(0, 0), WfPoints.flat(256, 0.2)], 256)).is_empty()
		and pin_inst.size() == 1 and pin_inst[0]["mesh"] == "W_Plum")
	var card_items := _scatter_with_items(iv, true).filter(func(p): return bool(p.get("item", false)))
	_chk(r, "the card ring carries the row's trees as card points of a tree (%d)" % card_items.size(),
		card_items.size() == 11 and card_items.all(func(p): return (p["role"] == "bb" and p["mrole"] == "tree")))
	var ir = _row_spawner()
	ir.set_road_segments(PackedFloat64Array([60.0, 0.0, 60.0, 256.0, 2.0]))
	var road_items := _scatter_with_items(ir).filter(func(p): return bool(p.get("item", false)))
	_chk(r, "roads win: the row's tree in a road's corridor is dropped, the rest stand (%d)" % road_items.size(),
		road_items.size() == 10 and road_items.all(func(p): return absf((p["p"] as Vector2).x - 60.0) >= 5.0))
	# A street tree stands at the verge: the corridor the host sends is the road; road_margin is the map trees' own
	# clearance from it, not an item's (rows commonly stand 0-3 m past the corridor). The row's trees at x 60 and 68
	# stand 3.2-4.8 m from this road's centre: inside its corridor + road_margin (5 m), outside its corridor (2 m).
	var iv2 = _row_spawner()
	iv2.set_road_segments(PackedFloat64Array([64.0, 0.0, 64.0, 256.0, 2.0]))
	var verge_items := _scatter_with_items(iv2).filter(func(p): return bool(p.get("item", false)))
	_chk(r, "an item keeps off the road's corridor, not the forest's road_margin beyond it: the row's trees 3-5 m from the road stand, and the cursor note agrees (%d; %s, %s)" % [
		verge_items.size(), iv2.item_gate(Vector2(60, 50)), iv2.item_gate(Vector2(64, 50))],
		verge_items.size() == 11 and iv2.item_gate(Vector2(60, 50)) == "" and iv2.item_gate(Vector2(64, 50)) == "on a road")
	var iu = _row_spawner()
	iu.trees.add({"kind": "tree", "at": Vector2(200, 200), "type": 1, "age": 0.0, "species": "W_Nope", "clear_m": 3.0,
		"edited": false})
	iu.trees.add({"kind": "tree", "at": Vector2(205, 205), "type": 9, "age": 0.0, "species": "", "clear_m": 3.0,
		"edited": false})
	var n_lines := cap.lines.size()
	var iu1: Array = iu._items_for(Rect2(190, 190, 20, 20))
	var iu2: Array = iu._items_for(Rect2(190, 190, 20, 20))
	var said := cap.lines.slice(n_lines)
	var nope := said.filter(func(l): return String(l[1]).contains("W_Nope")).size()
	var no_type := said.filter(func(l): return String(l[1]).contains("type 9")).size()
	_chk(r, "a pinned species the catalog lacks: the scatter's copy lets the type pick; a type the profile lacks grows nothing; each said once; the item keeps its species (%d, %d)" % [nope, no_type],
		iu1.size() == 2 and iu1[0]["species"] == "" and iu2[0]["species"] == "" and nope == 1 and no_type == 1
		and str(iu.trees.items[2]["species"]) == "W_Nope")
	var cells_i: Array = inm._cells_with_maps(64.0)
	_chk(r, "the unbounded mode lists a cell where only a single tree stands (%s)" % str(cells_i),
		cells_i.has(Vector2i(0, 0)))
	var ig = _row_spawner()
	var gt = FakeTerrain.new()
	var gh = FakeHeights.new()
	gh.height = func(x: float, _z: float) -> float: return -5.0 if x < 10.0 else ((x - 150.0) * 2.0 if x > 150.0 else 20.0)
	gt.data = gh
	ig.terrain_source = gt
	ig.set_road_segments(PackedFloat64Array([60.0, 0.0, 60.0, 256.0, 2.0]))
	var gates := [ig.item_gate(Vector2(60, 50)), ig.item_gate(Vector2(5, 50)), ig.item_gate(Vector2(200, 50)),
		ig.item_gate(Vector2(100, 50))]
	_chk(r, "why an item would not grow there: on a road, under water, too steep; nothing where it grows (%s)" % str(gates),
		gates == ["on a road", "under water", "too steep", ""])
	_chk(r, "the profile's species, sorted, each once (%s)" % str(iv.species_names()),
		Array(iv.species_names()) == ["W_Bush", "W_Old", "W_Plum", "W_Young"])
	var ic = Veg.new()
	ic.profile_path = ITEMS_PROFILE_PATH
	ic._load_profile()
	var ict = FakeTerrain.new()
	ict.region_size = 256
	ict.data_directory = "user://wf_b2c_scatter"
	var tw = TreesRes.new()
	tw.path = "user://wf_b2c_scatter/forest/trees.json"
	tw.set_state({"items": {1: {"id": 1, "kind": "tree", "at": Vector2(9, 9), "type": 1, "age": 0.0, "species": "",
		"clear_m": 3.0, "edited": false}}, "next_id": 2})
	tw.save()
	ic._ensure_maps(ict)
	_chk(r, "the forest reads its trees file from its own maps folder when the maps are configured (%s)" % ic.trees.path,
		ic.trees.path == "user://wf_b2c_scatter/forest/trees.json" and ic.trees.items.size() == 1)
	gt.free()
	ict.free()
	DirAccess.remove_absolute(ProjectSettings.globalize_path("user://wf_b2c_scatter/forest/trees.json"))
	DirAccess.remove_absolute(ProjectSettings.globalize_path("user://wf_b2c_scatter/forest"))
	DirAccess.remove_absolute(ProjectSettings.globalize_path("user://wf_b2c_scatter"))
	DirAccess.remove_absolute(ProjectSettings.globalize_path(ITEMS_PROFILE_PATH))

	for n in [vp, full, half, zero, again, reroll, vu, vw, vb, iv, ip, inm, iz, ir, iu, ig, ic]:
		n._drain_scatter_jobs()
		n.free()
	for f2 in DirAccess.get_files_at(DIR):
		DirAccess.remove_absolute(ProjectSettings.globalize_path(DIR.path_join(f2)))
	DirAccess.remove_absolute(ProjectSettings.globalize_path(DIR))
	DirAccess.remove_absolute(ProjectSettings.globalize_path(PROFILE_PATH))
	ForestConfigRes.use(null)
	VA.forget_packs()
	ForestLogRes.sink = keep
	return r
