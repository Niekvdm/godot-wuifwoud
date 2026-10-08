# Copyright (c) 2026 Digitzone
# SPDX-License-Identifier: MIT
extends RefCounted
## The far cell's shell, the native core's build from its window of region summaries and
## grounds: quads only over cover plus one ring, the canopy's vertices at ground + the canopy height (± the relief), the
## ring's outer vertices 5 m under the sea line (or under the ground, where it is lower), on high ground too, as the
## terrain's far field past its streamed ring sits tens of metres under the region files and a shell standing on them
## would hover over it; the rules by place in CUSTOM0 (the sea line, a natural type's treeline, the slope band and the
## cliff cut); front faces up; two adjoining cells agree on the vertices they share; two builds byte for byte the same; no
## cover, no mesh; unknown ground, no quad; a cell with no size refused with a reason; a region's ground sampled at the
## shell's grid.
##
## Run with a unit-suite runner: static run() returns {name, passed, failed, details}.

const NativeRes := preload("res://addons/wuifwoud/forest_native.gd")
const G := 16.0
const TM := 8.0
const RM := 256.0      # one region a cell


static func _chk(r: Dictionary, n: String, ok: bool) -> void:
	if ok:
		r.passed += 1
	else:
		r.failed += 1
		r.details.append("✗ " + n)


## The cell at `origin` (one 256 m region, 16 quads a side) as ForestFar._submit_build hands it over: its window's region
## summaries from `cover_of(x, z) -> [type, cover, age]` at each far texel's centre and grounds from `ground_of(x, z)` at
## each grid point; type 1 natural (20 m), type 2 a grid (6 m).
static func _p(origin: Vector2, cover_of: Callable, ground_of: Callable) -> Dictionary:
	var out_w := int(RM / TM)
	var s := int(RM / G)
	var sums := {}
	var grounds := {}
	var c0 := Vector2i(floori(origin.x / RM), floori(origin.y / RM))
	for lz in range(c0.y - 1, c0.y + 2):
		for lx in range(c0.x - 1, c0.x + 2):
			var tex := PackedByteArray()
			tex.resize(out_w * out_w * 4)
			for v in out_w:
				for u in out_w:
					var c: Array = cover_of.call(float(lx) * RM + (float(u) + 0.5) * TM, float(lz) * RM + (float(v) + 0.5) * TM)
					var o := (v * out_w + u) * 4
					tex[o] = c[0]
					tex[o + 1] = c[1]
					tex[o + 2] = c[2]
			sums[Vector2i(lx, lz)] = tex
			var gr := PackedFloat32Array()
			gr.resize(s * s)
			for j in s:
				for i in s:
					gr[j * s + i] = float(ground_of.call(float(lx) * RM + float(i) * G, float(lz) * RM + float(j) * G))
			grounds[Vector2i(lx, lz)] = gr
	return {"origin": origin, "cell_m": RM, "rm": RM, "grid_m": G, "texel_m": TM, "out_w": out_w, "s": s, "sums": sums,
		"grounds": grounds, "heights": {1: PackedFloat32Array([20.0, 20.0, 20.0]), 2: PackedFloat32Array([6.0, 6.0, 6.0])},
		"styles": {1: "natural", 2: "grid"},
		"rules": {"sea": 0.6, "coast": 150.0, "mid": 450.0, "treeline": 600.0, "slope_thin": 0.8, "slope_max": 1.2},
		"seed": 7}


static func _build(p: Dictionary) -> Dictionary:
	return NativeRes.core().far_build_cell(p)


## The vertex at world (x, z): {"y", "c": [rules, skirt, ground, type]}, or {} when the mesh has none there.
static func _vert(res: Dictionary, x: float, z: float) -> Dictionary:
	if (res["arrays"] as Array).is_empty():
		return {}
	var vs: PackedVector3Array = res["arrays"][Mesh.ARRAY_VERTEX]
	var cs: PackedFloat32Array = res["arrays"][Mesh.ARRAY_CUSTOM0]
	for i in vs.size():
		if is_equal_approx(vs[i].x, x) and is_equal_approx(vs[i].z, z):
			return {"y": vs[i].y, "c": [cs[i * 4], cs[i * 4 + 1], cs[i * 4 + 2], cs[i * 4 + 3]]}
	return {}


static func run() -> Dictionary:
	var r := {"name": "forest_far_mesh", "passed": 0, "failed": 0, "details": []}
	_chk(r, "the native core is built (if not: build it, see the addon's README)", NativeRes.core() != null)
	if NativeRes.core() == null:
		return r
	var square := func(x: float, z: float) -> Array:
		return [1, 255, 128] if x >= 64.0 and x < 192.0 and z >= 64.0 and z < 192.0 else [0, 0, 128]
	var flat := func(_x: float, _z: float) -> float: return 10.0
	var res: Dictionary = _build(_p(Vector2.ZERO, square, flat))
	var vs: PackedVector3Array = res["arrays"][Mesh.ARRAY_VERTEX] if not (res["arrays"] as Array).is_empty() else PackedVector3Array()
	var idx: PackedInt32Array = res["arrays"][Mesh.ARRAY_INDEX] if not (res["arrays"] as Array).is_empty() else PackedInt32Array()
	_chk(r, "a 128 m stand: its 64 quads and one ring, 100 quads, 121 vertices (%d, %d)" % [int(res["quads"]), vs.size()],
		int(res["quads"]) == 100 and vs.size() == 121 and idx.size() == 600)
	var inner := _vert(res, 128.0, 128.0)
	var edge := _vert(res, 64.0, 64.0)
	var skirt := _vert(res, 48.0, 48.0)
	_chk(r, "a canopy vertex stands at ground + 20 m × 1.125 ± 30 %%; the stand's edge is canopy; the ring's outer vertex is 5 m under the sea line (%s %s %s)" % [
		str(inner.get("y")), str(edge.get("y")), str(skirt.get("y"))],
		not inner.is_empty() and float(inner["y"]) >= 10.0 + 22.5 * 0.7 - 0.01 and float(inner["y"]) <= 10.0 + 22.5 * 1.3 + 0.01
		and inner["c"][1] == 0.0 and inner["c"][3] == 1.0 and not edge.is_empty() and edge["c"][1] == 0.0
		and not skirt.is_empty() and is_equal_approx(float(skirt["y"]), 0.6 - 5.0) and skirt["c"][1] == 1.0 and skirt["c"][3] == 1.0)
	# A stand on a 400 m plateau: its ring still reaches under the sea line (the far field there may sit far lower); a
	# ring vertex on ground under the sea line goes 5 m under that ground.
	var plateau: Dictionary = _build(_p(Vector2.ZERO, square, func(_x: float, _z: float) -> float: return 400.0))
	var seabed: Dictionary = _build(_p(Vector2.ZERO, square, func(_x: float, _z: float) -> float: return -20.0))
	_chk(r, "a ring on high ground reaches 5 m under the sea line; on ground under the sea, 5 m under the ground (%s %s)" % [
		str(_vert(plateau, 48.0, 48.0).get("y")), str(_vert(seabed, 48.0, 48.0).get("y"))],
		is_equal_approx(float(_vert(plateau, 48.0, 48.0).get("y", 0.0)), 0.6 - 5.0)
		and is_equal_approx(float(_vert(seabed, 48.0, 48.0).get("y", 0.0)), -20.0 - 5.0))
	# A canopy vertex at the stand's edge is lit as canopy: its normal ignores the wall dropping 400 m beside it.
	var pn: PackedVector3Array = plateau["arrays"][Mesh.ARRAY_NORMAL]
	var pv: PackedVector3Array = plateau["arrays"][Mesh.ARRAY_VERTEX]
	var tilt := -1.0
	for i in pv.size():
		if is_equal_approx(pv[i].x, 64.0) and is_equal_approx(pv[i].z, 128.0):
			tilt = rad_to_deg(acos(clampf(pn[i].y, -1.0, 1.0)))
	_chk(r, "a stand's edge canopy vertex is lit as canopy, not as the wall beside it (tilt %.1f°)" % tilt,
		tilt >= 0.0 and tilt < 35.0)
	var flip := true
	for t in range(0, idx.size(), 3):
		var a := vs[idx[t]]
		var b := vs[idx[t + 1]]
		var c := vs[idx[t + 2]]
		if (c - a).cross(b - a).y <= 0.0:
			flip = false
	var normals: PackedVector3Array = res["arrays"][Mesh.ARRAY_NORMAL]
	_chk(r, "every triangle faces up (the project's winding rule) and every normal points up",
		flip and not normals.is_empty() and Array(normals).all(func(nv): return nv.y > 0.0))
	var all_wood := func(_x: float, _z: float) -> Array: return [1, 255, 128]
	var shore := func(x: float, _z: float) -> float: return 0.0 if x < 128.0 else 10.0
	var rs: Dictionary = _build(_p(Vector2.ZERO, all_wood, shore))
	var steep := func(x: float, _z: float) -> float: return x * 1.5
	var band := func(x: float, _z: float) -> float: return x * 1.0
	var high := func(_x: float, _z: float) -> float: return 700.0
	var orchard := func(_x: float, _z: float) -> Array: return [2, 255, 128]
	var r_sea: float = _vert(rs, 96.0, 128.0)["c"][0]
	var r_land: float = _vert(rs, 160.0, 128.0)["c"][0]
	var r_cliff: float = _vert(_build(_p(Vector2.ZERO, all_wood, steep)), 128.0, 128.0)["c"][0]
	var r_band: float = _vert(_build(_p(Vector2.ZERO, all_wood, band)), 128.0, 128.0)["c"][0]
	var r_tree: float = _vert(_build(_p(Vector2.ZERO, all_wood, high)), 128.0, 128.0)["c"][0]
	var r_grid: float = _vert(_build(_p(Vector2.ZERO, orchard, high)), 128.0, 128.0)["c"][0]
	_chk(r, "the rules by place: 0 below the sea line, 1 on land; 0 on a cliff, thinned on the slope band; 0 above a natural type's treeline, a grid's kept (%s)" % str([r_sea, r_land, r_cliff, r_band, r_tree, r_grid]),
		r_sea == 0.0 and r_land == 1.0 and r_cliff == 0.0 and absf(r_band - 0.5) < 0.01 and r_tree == 0.0 and r_grid == 1.0)
	var across := func(x: float, z: float) -> Array:
		return [1, 255, 128] if x >= 200.0 and x < 312.0 and z >= 64.0 and z < 192.0 else [0, 0, 128]
	var hilly := func(x: float, z: float) -> float: return 10.0 + 0.1 * x + 0.05 * z
	var ca: Dictionary = _build(_p(Vector2.ZERO, across, hilly))
	var cb: Dictionary = _build(_p(Vector2(256.0, 0.0), across, hilly))
	var meet := true
	for zi in range(3, 14):
		var va := _vert(ca, 256.0, float(zi) * G)
		var vb := _vert(cb, 256.0, float(zi) * G)
		if va.is_empty() or vb.is_empty() or not is_equal_approx(float(va["y"]), float(vb["y"])) or va["c"] != vb["c"]:
			meet = false
	_chk(r, "two adjoining cells agree on every vertex they share (the margin)", meet)
	var again: Dictionary = _build(_p(Vector2.ZERO, square, flat))
	_chk(r, "two builds of one input are byte for byte the same", var_to_bytes(again["arrays"]) == var_to_bytes(res["arrays"]))
	var none := func(_x: float, _z: float) -> Array: return [0, 0, 128]
	var half_known := func(x: float, _z: float) -> float: return NAN if x > 128.0 else 10.0
	var nc: Dictionary = _build(_p(Vector2.ZERO, none, flat))
	var nk: Dictionary = _build(_p(Vector2.ZERO, all_wood, half_known))
	var nkv: PackedVector3Array = nk["arrays"][Mesh.ARRAY_VERTEX]
	_chk(r, "no cover: no mesh; unknown ground: no quad over it (%d)" % nkv.size(),
		(nc["arrays"] as Array).is_empty() and int(nc["quads"]) == 0
		and Array(nkv).all(func(v): return v.x <= 128.0) and int(nk["quads"]) == 8 * 16)
	var none_p: Dictionary = _build({})
	_chk(r, "a cell with no size is refused with a reason (%s)" % str(none_p["error"]),
		str(none_p["error"]) != "" and (none_p["arrays"] as Array).is_empty() and int(none_p["tw"]) == 0)
	# A 64 x 48 height map (texel x + 100 z): the shell's 4 x 4 samples every 16 texels, the last clamped to the map.
	var hm := Image.create_empty(64, 48, false, Image.FORMAT_RF)
	for z in 48:
		for x in 64:
			hm.set_pixel(x, z, Color(float(x) + 100.0 * float(z), 0.0, 0.0))
	var g: PackedFloat32Array = NativeRes.core().far_sample_ground(hm.get_data(), 64, 48, 4, 16.0)
	_chk(r, "a region's ground at the shell's grid, row-major from its corner, the last row clamped (%s)" % str(g),
		g.size() == 16 and g[0] == 0.0 and g[1] == 16.0 and g[3] == 48.0 and g[4] == 1600.0 and g[12] == 4700.0
		and NativeRes.core().far_sample_ground(PackedByteArray([1, 2]), 64, 48, 4, 16.0).is_empty())
	return r
