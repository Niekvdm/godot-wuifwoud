# Copyright (c) 2026 Digitzone
# SPDX-License-Identifier: MIT
extends RefCounted
## ForestImport: the mapping's checks; rule matching (every key, any-of lists, the first match
## wins); a rule's texel; texels painted by their CENTRE with holes and multipolygons; the first rule wins an overlap in
## either feature order; exclusions and type-0 rules write no forest; only regions with a region file, and only those
## with forest, get a map; the report; a whole run writes the maps and deletes a stale one; a non-world source refused.
## the rectangle rasteriser (paint_rect, region_map), the paint merge (merge_painted, painted), the values scan;
## a re-import keeps painted texels and discard_painted overwrites them. Sources as a list; points and lines as
## single trees and rows with their rule's fields; keys (Multi parts, duplicates, a geometry hash); the zone cut; the
## merge (ids, edits, deletions, hand-made items, discard); the scan's lengths and points.
##
## Run with a unit-suite runner: static run() returns {name, passed, failed, details}.

const ImportRes := preload("res://addons/wuifwoud/forest_import.gd")
const DIR := "user://wf_b1_import"
const RS := 64       # region size in vertices at 1 m: a 64 m region, one texel a metre


static func _chk(r: Dictionary, n: String, ok: bool) -> void:
	if ok:
		r.passed += 1
	else:
		r.failed += 1
		r.details.append("✗ " + n)


static func _sq(x0: float, z0: float, s: float) -> Array:
	return [[x0, z0], [x0 + s, z0], [x0 + s, z0 + s], [x0, z0 + s], [x0, z0]]


static func _feature(kind: String, coords: Array, multi := false) -> Dictionary:
	return {"type": "Feature", "properties": {"class": "landuse", "kind": kind, "osm_id": 1.0},
		"geometry": {"type": "MultiPolygon" if multi else "Polygon", "coordinates": coords}}


static func _line(kind: String, id, coords: Array, multi := false) -> Dictionary:
	var props := {"kind": kind}
	if id != null:
		props["osm_id"] = float(id)
	return {"type": "Feature", "properties": props,
		"geometry": {"type": "MultiLineString" if multi else "LineString", "coordinates": coords}}


static func _point(kind: String, id, xz: Array) -> Dictionary:
	var props := {"kind": kind}
	if id != null:
		props["osm_id"] = float(id)
	return {"type": "Feature", "properties": props, "geometry": {"type": "Point", "coordinates": xz}}


static func _mapping(rules: Array) -> Dictionary:
	return {"schema": "wuifwoud_import/1", "source": DIR.path_join("landuse.geojson"), "data_directory": DIR,
		"texel_vertices": 1, "exclusions": [], "rules": rules}


## Texels whose R is `ty`.
static func _count(data: PackedByteArray, ty: int) -> int:
	var n := 0
	for i in range(0, data.size(), 4):
		if data[i] == ty:
			n += 1
	return n


static func _paint(features: Array, rules: Array, zones := []) -> PackedByteArray:
	var sh: Dictionary = ImportRes.shapes_of(features, rules, zones)
	return ImportRes.paint_region(Vector2i(0, 0), float(RS), RS, sh["shapes"])


## The texels of `rect` out of a w-texel map's bytes, row by row.
static func _slice(data: PackedByteArray, w: int, rect: Rect2i) -> PackedByteArray:
	var out := PackedByteArray()
	for j in range(rect.position.y, rect.end.y):
		out.append_array(data.slice((j * w + rect.position.x) * 4, (j * w + rect.end.x) * 4))
	return out


static func _img(w: int, px: Array) -> Image:
	var img := Image.create_empty(w, w, false, Image.FORMAT_RGBA8)
	img.fill(Color8(px[0], px[1], px[2], px[3]))
	return img


static func _count_a(img: Image, a: int) -> int:
	var d := img.get_data()
	var n := 0
	for i in range(3, d.size(), 4):
		if d[i] == a:
			n += 1
	return n


static func run() -> Dictionary:
	var r := {"name": "forest_import", "passed": 0, "failed": 0, "details": []}
	var wood := [{"match": {"kind": "wood"}, "type": 1}]

	# ── the mapping's checks ──
	_chk(r, "a good mapping has no errors (%s)" % str(ImportRes.validate(_mapping(wood))),
		ImportRes.validate(_mapping(wood)).is_empty())
	var bads := [
		{"schema": "other/1"}, {"source": ""}, {"texel_vertices": 3}, {"rules": []},
		{"rules": [{"match": {"kind": "wood"}, "type": 300}]}, {"rules": [{"match": {}, "type": 1}]},
		{"rules": [{"match": {"kind": "wood"}, "type": 1, "density": 1.5}]},
		{"rules": [{"match": {"kind": "wood"}, "type": 1, "age": -2.0}]}, {"exclusions": "x.json"}, {"source": 5}, {"source": []},
		{"rules": [{"match": {"kind": "wood"}, "type": 1, "spacing_m": 0.5}]},
		{"rules": [{"match": {"kind": "wood"}, "type": 1, "clear_m": -1.0}]},
		{"rules": [{"match": {"kind": "wood"}, "type": 1, "species": 3}]},
	]
	var silent := []
	for b in bads:
		var m := _mapping(wood)
		m.merge(b, true)
		if ImportRes.validate(m).is_empty():
			silent.append(b)
	_chk(r, "every bad mapping is named (%s passed)" % str(silent), silent.is_empty())

	# ── matching ──
	var rules := [{"match": {"kind": "wood"}, "type": 1},
		{"match": {"kind": ["meadow", "grass"], "class": "landuse"}, "type": 2}]
	_chk(r, "matching: every key, any-of lists, the first match, an absent key never matches",
		ImportRes.match_rule(rules, {"kind": "wood"}) == 0
		and ImportRes.match_rule(rules, {"kind": "grass", "class": "landuse"}) == 1
		and ImportRes.match_rule(rules, {"kind": "grass", "class": "natural"}) == -1
		and ImportRes.match_rule(rules, {"class": "landuse"}) == -1)

	# ── a rule's texel ──
	_chk(r, "a rule's texel: type, round(density·255), 128 + round(age·127); type 0 is no forest",
		ImportRes.texel_of({"type": 2, "density": 0.7, "age": -0.5}) == PackedByteArray([2, 179, 64, 0])
		and ImportRes.texel_of({"type": 1}) == PackedByteArray([1, 255, 128, 0])
		and ImportRes.texel_of({"type": 0, "density": 0.2}) == PackedByteArray([0, 255, 128, 0]))

	# ── painting by texel centre, with a hole ──
	var holed := _paint([_feature("wood", [_sq(10, 10, 20), _sq(15, 15, 5)])], wood)
	_chk(r, "a 20 m square with a 5 m hole: 400 − 25 texels (%d)" % _count(holed, 1), _count(holed, 1) == 375
		and holed.size() == RS * RS * 4)
	var multi := _paint([_feature("wood", [[_sq(2, 2, 10)], [_sq(40, 40, 10)]], true)], wood)
	_chk(r, "a multipolygon paints both parts (%d)" % _count(multi, 1), _count(multi, 1) == 200)

	# ── the first rule wins an overlap, in either feature order ──
	var two := [{"match": {"kind": "wood"}, "type": 1}, {"match": {"kind": "park"}, "type": 3}]
	var fa := [_feature("wood", [_sq(0, 0, 30)]), _feature("park", [_sq(20, 0, 30)])]
	var fb := [fa[1], fa[0]]
	var pa := _paint(fa, two)
	_chk(r, "either feature order gives the same map; wood (rule 0) wins the overlap (%d wood, %d park)" % [
		_count(pa, 1), _count(pa, 3)], pa == _paint(fb, two) and _count(pa, 1) == 900 and _count(pa, 3) == 600)

	# ── exclusions and type-0 rules write no forest ──
	var zone := PackedVector2Array([Vector2(0, 0), Vector2(10, 0), Vector2(10, 10), Vector2(0, 10)])
	var ex := _paint([_feature("wood", [_sq(0, 0, 30)])], wood, [zone])
	var carve := _paint([_feature("bare_rock", [_sq(0, 0, 10)]), _feature("wood", [_sq(0, 0, 30)])],
		[{"match": {"kind": "bare_rock"}, "type": 0}, {"match": {"kind": "wood"}, "type": 1}])
	_chk(r, "an exclusion zone and a type-0 rule each clear 100 texels (%d, %d)" % [_count(ex, 1), _count(carve, 1)],
		_count(ex, 1) == 800 and _count(carve, 1) == 800)

	# ── build: only regions with a region file, only those with forest ──
	var feats := [_feature("wood", [_sq(10, 10, 20)]), _feature("wood", [_sq(70, 10, 20)]),
		_feature("pitch", [_sq(130, 10, 10)])]
	var built: Dictionary = ImportRes.build(_mapping(wood), feats, [Vector2i(0, 0), Vector2i(2, 0)], RS, 1.0, [])
	var km2: Dictionary = built["km2"]
	_chk(r, "maps for regions with a region file and forest only; km² and the unmatched kind (%s, %s, %s)" % [
		str(built["images"].keys()), str(km2), str(built["unmatched"])],
		built["images"].keys() == [Vector2i(0, 0)] and is_equal_approx(float(km2.get(1, 0.0)), 400.0 / 1e6)
		and is_equal_approx(float(built["unmatched"].get("kind=pitch", 0.0)), 100.0 / 1e6))

	# ── paint_rect is paint_region's rasteriser, a rectangle at a time ──
	var feats2 := [_feature("wood", [_sq(10, 10, 20), _sq(15, 15, 5)]), _feature("park", [_sq(40, 0.5, 30)])]
	var sh2: Dictionary = ImportRes.shapes_of(feats2, two, [])
	var full := ImportRes.paint_region(Vector2i(0, 0), float(RS), RS, sh2["shapes"])
	var odd := []
	for rc in [Rect2i(0, 0, RS, RS), Rect2i(10, 10, 20, 5), Rect2i(0, 60, RS, 4), Rect2i(60, 0, 4, RS),
			Rect2i(63, 63, 1, 1), Rect2i(12, 12, 6, 6)]:
		if ImportRes.paint_rect(Vector2i(0, 0), float(RS), RS, sh2["shapes"], rc) != _slice(full, RS, rc):
			odd.append(rc)
	_chk(r, "paint_rect equals paint_region's texels over any rectangle, edges and corners too (%s differ)" % str(odd),
		odd.is_empty())
	var rm0 := ImportRes.region_map(Vector2i(0, 0), float(RS), RS, sh2["shapes"])
	_chk(r, "region_map: the region's map, or null where nothing grows",
		rm0 != null and rm0.get_data() == full and ImportRes.region_map(Vector2i(5, 5), float(RS), RS, sh2["shapes"]) == null)

	# ── merge_painted ──
	var made := _img(RS, [1, 255, 128, 0])
	var plain := _img(RS, [3, 200, 100, 0])
	var pnt := _img(RS, [3, 200, 100, 0])
	pnt.set_pixel(5, 6, Color8(2, 90, 30, 255))
	var mp := ImportRes.merge_painted(pnt, made, RS)
	_chk(r, "merge: a painted texel stays; every other texel is the import's, A 0 (%s)" % str(mp.get_pixel(5, 6) if mp else null),
		mp != null and mp.get_pixel(5, 6) == Color8(2, 90, 30, 255) and mp.get_pixel(0, 0) == Color8(1, 255, 128, 0)
		and _count(mp.get_data(), 1) == RS * RS - 1)
	var kept_m := ImportRes.merge_painted(pnt, null, RS)
	_chk(r, "merge: where the import grows nothing a painted map is kept, the rest nothing grows",
		kept_m != null and kept_m.get_pixel(5, 6) == Color8(2, 90, 30, 255) and kept_m.get_pixel(0, 0) == Color8(0, 255, 128, 0))
	_chk(r, "merge: no old map, or an unpainted one, is the import's; nothing either way is no map",
		ImportRes.merge_painted(null, made, RS) == made and ImportRes.merge_painted(plain, made, RS) == made
		and ImportRes.merge_painted(plain, null, RS) == null and ImportRes.merge_painted(null, null, RS) == null)
	var fine := _img(RS, [0, 255, 128, 0])
	fine.set_pixel(7, 7, Color8(2, 255, 128, 255))                  # an odd texel: a nearest resize would drop it
	var coarse := ImportRes.merge_painted(fine, null, RS / 2)
	var small := _img(RS / 2, [0, 255, 128, 0])
	small.set_pixel(3, 3, Color8(2, 255, 128, 255))
	var big := ImportRes.merge_painted(small, null, RS)
	_chk(r, "merge across a texel size change keeps every painted texel: coarser under it, finer over all it covers",
		coarse != null and coarse.get_width() == RS / 2 and coarse.get_pixel(3, 3) == Color8(2, 255, 128, 255)
		and big != null and big.get_width() == RS and _count_a(big, 255) == 4 and big.get_pixel(6, 6).a8 == 255
		and big.get_pixel(7, 7).a8 == 255 and fine.get_width() == RS)
	var half := _img(RS, [3, 200, 100, 0])
	half.set_pixel(1, 1, Color8(2, 90, 30, 7))
	_chk(r, "merge: an A between 0 and 255 is not paint, the texel is the import's; painted() is A above 0 on RGBA8",
		ImportRes.merge_painted(half, made, RS).get_pixel(1, 1) == Color8(1, 255, 128, 0)
		and ImportRes.painted(pnt) and ImportRes.painted(half) and not ImportRes.painted(plain)
		and not ImportRes.painted(null))

	# ── the values scan ──
	var point := {"type": "Feature", "properties": {"kind": "wood"}, "geometry": {"type": "Point", "coordinates": [1, 1]}}
	var sc: Dictionary = ImportRes.scan_source(feats + [point, _line("tree_row", 40, [[0, 0], [30, 0]]), _point("tree", 41, [1, 1])])
	_chk(r, "scan_source: each value's area, length of lines and points, and its features: polygons, lines and points (%s)" % str(
		sc["areas"].get("kind")), int(sc["features"]) == 6 and is_equal_approx(float(sc["areas"]["kind"]["wood"]), 800.0)
		and int(sc["counts"]["kind"]["wood"]) == 3 and int(sc["points"]["kind"]["wood"]) == 1
		and is_equal_approx(float(sc["lengths"]["kind"]["tree_row"]), 30.0) and int(sc["points"]["kind"]["tree"]) == 1
		and is_equal_approx(float(sc["areas"]["kind"]["pitch"]), 100.0) and is_equal_approx(float(sc["areas"]["class"]["landuse"]), 900.0))

	# ── a whole run: writes the maps, deletes a stale one, reports ──
	DirAccess.make_dir_recursive_absolute(DIR.path_join("forest"))
	var src := FileAccess.open(DIR.path_join("landuse.geojson"), FileAccess.WRITE)
	src.store_string(JSON.stringify({"type": "FeatureCollection", "coord_space": "world", "features": feats}))
	src.close()
	var stale := DIR.path_join("forest").path_join(Terrain3DUtil.location_to_filename(Vector2i(5, 5)))
	ResourceSaver.save(Image.create_empty(RS, RS, false, Image.FORMAT_RGBA8), stale)
	var rep: Dictionary = ImportRes.run(_mapping(wood), {"regions": [Vector2i(0, 0), Vector2i(1, 0)],
		"region_size": RS, "vertex_spacing": 1.0})
	var p00 := DIR.path_join("forest").path_join(Terrain3DUtil.location_to_filename(Vector2i(0, 0)))
	var back := ResourceLoader.load(p00, "", ResourceLoader.CACHE_MODE_IGNORE) as Image
	_chk(r, "a run writes (0,0) and (1,0), deletes the stale (5,5) whose region is gone (%s)" % str(rep),
		bool(rep["ok"]) and rep["written"].size() == 2 and rep["deleted_no_region"] == [Vector2i(5, 5)]
		and not FileAccess.file_exists(stale) and int(rep["bytes"]) > 0 and back != null
		and _count(back.get_data(), 1) == 400)
	var raw := FileAccess.open(DIR.path_join("pixels.geojson"), FileAccess.WRITE)
	raw.store_string(JSON.stringify({"type": "FeatureCollection", "features": feats}))
	raw.close()
	var pm := _mapping(wood)
	pm["source"] = DIR.path_join("pixels.geojson")
	var refused: Dictionary = ImportRes.run(pm, {"regions": [Vector2i(0, 0)], "region_size": RS, "vertex_spacing": 1.0})
	_chk(r, "a source that is not world-space is refused (%s)" % str(refused["errors"]),
		not bool(refused["ok"]) and str(refused["errors"]).contains("world"))

	# ── a re-import keeps painted texels; discard_painted overwrites them ──
	var pimg := ResourceLoader.load(p00, "", ResourceLoader.CACHE_MODE_IGNORE) as Image
	pimg.set_pixel(3, 3, Color8(2, 255, 128, 255))
	ResourceSaver.save(pimg, p00, ResourceSaver.FLAG_COMPRESS)
	var meta := {"regions": [Vector2i(0, 0), Vector2i(1, 0)], "region_size": RS, "vertex_spacing": 1.0}
	var again: Dictionary = ImportRes.run(_mapping(wood), meta)
	var kept := ResourceLoader.load(p00, "", ResourceLoader.CACHE_MODE_IGNORE) as Image
	_chk(r, "a re-import keeps a painted texel (%s)" % str(again["errors"]),
		bool(again["ok"]) and kept != null and kept.get_pixel(3, 3) == Color8(2, 255, 128, 255))
	var forced: Dictionary = ImportRes.run(_mapping(wood), meta, true)
	var clean := ResourceLoader.load(p00, "", ResourceLoader.CACHE_MODE_IGNORE) as Image
	_chk(r, "discard_painted re-imports and the mark is gone (%s)" % str(forced["painted_overwritten"]),
		bool(forced["ok"]) and clean != null and not clean.get_used_rect().has_area()
		and forced["painted_overwritten"] == [Vector2i(0, 0)])
	# ── points and lines ──
	_chk(r, "sources: one path or a list (%s)" % str(ImportRes.sources_of({"source": ["a", "b"]})),
		ImportRes.sources_of({"source": "a"}) == ["a"] and ImportRes.sources_of({"source": ["a", "b"]}) == ["a", "b"]
		and ImportRes.sources_of({"source": ""}).is_empty())
	var irules := [{"match": {"kind": "tree_row"}, "type": 1, "spacing_m": 6.0, "clear_m": 2.0, "species": "W_Old"},
		{"match": {"kind": "tree"}, "type": 2, "age": 0.5}, {"match": {"kind": "hedge"}, "type": 0}]
	var lf := [_line("tree_row", 7, [[0, 0], [30, 0]]), _point("tree", 8, [5, 5]), _line("hedge", 9, [[0, 9], [9, 9]]),
		_line("fence", 10, [[0, 20], [30, 20]]), _point("bench", 11, [1, 1]), _line("tree_row", 12, [[3, 3]])]
	var io: Dictionary = ImportRes.items_of(lf, irules, [])
	var its: Array = io["items"]
	_chk(r, "items_of: a line a row and a point a tree with their rule's fields, keyed by osm_id, in source order; type 0 skips; a one-point line is malformed; no rule: metres of line, points counted; none of them skipped as polygons (%s)" % str(io),
		its.size() == 2 and its[0][0] == "osm_id:7" and its[0][1]["kind"] == "row" and its[0][1]["spacing_m"] == 6.0
		and its[0][1]["clear_m"] == 2.0 and its[0][1]["species"] == "W_Old" and its[0][1]["source"] == "osm_id:7"
		and its[0][1]["points"] == PackedVector2Array([Vector2(0, 0), Vector2(30, 0)])
		and its[1][0] == "osm_id:8" and its[1][1]["kind"] == "tree" and its[1][1]["at"] == Vector2(5, 5)
		and is_equal_approx(float(its[1][1]["age"]), 0.5) and its[1][1]["clear_m"] == 3.0
		and io["invalid"] == {"LineString": 1} and is_equal_approx(float(io["unmatched_lines"].get("kind=fence", 0.0)), 30.0)
		and io["unmatched_points"] == {"kind=bench": 1} and ImportRes.shapes_of(lf, irules, [])["skipped"].is_empty())
	var kf := [_line("tree_row", 20, [[[0, 0], [9, 0]], [[0, 5], [9, 5]]], true), _line("tree_row", 21, [[0, 9], [9, 9]]),
		_line("tree_row", 21, [[0, 12], [9, 12]]), _line("tree_row", null, [[0, 15], [9, 15]])]
	var ko: Dictionary = ImportRes.items_of(kf, irules, [])
	var k1: Array = (ko["items"] as Array).map(func(x): return x[0])
	var k2: Array = (ImportRes.items_of(kf, irules, [])["items"] as Array).map(func(x): return x[0])
	_chk(r, "keys: a Multi geometry's parts #0 #1; a key seen again ^2, counted; no id: a hash of its coordinates, the same each time (%s)" % str(k1),
		k1.size() == 5 and k1[0] == "osm_id:20#0" and k1[1] == "osm_id:20#1" and k1[2] == "osm_id:21"
		and k1[3] == "osm_id:21^2" and String(k1[4]).begins_with("geom:") and String(k1[4]).length() == 17
		and k1 == k2 and int(ko["dups"]) == 1)
	var zone2 := PackedVector2Array([Vector2(20, -10), Vector2(30, -10), Vector2(30, 10), Vector2(20, 10)])
	var zf := [_line("tree_row", 30, [[0, 0], [50, 0]]), _point("tree", 31, [25, 0]), _line("tree_row", 32, [[22, 0], [28, 0]]),
		_line("tree_row", 33, [[0, 20], [50, 20]])]
	var zo: Dictionary = ImportRes.items_of(zf, irules, [zone2])
	var zk: Array = (zo["items"] as Array).map(func(x): return x[0])
	var zp1: PackedVector2Array = zo["items"][0][1]["points"]
	var zp2: PackedVector2Array = zo["items"][1][1]["points"]
	_chk(r, "a zone cuts a row at its edges into pieces keyed ~1 ~2; a point inside is skipped; a row wholly inside is gone; a row beside it is whole (%s; %s %s)" % [str(zk), str(zp1), str(zp2)],
		zk == ["osm_id:30~1", "osm_id:30~2", "osm_id:33"] and int(zo["cut"]) == 2
		and zp1[0] == Vector2(0, 0) and zp1[zp1.size() - 1].is_equal_approx(Vector2(20, 0))
		and zp2[0].is_equal_approx(Vector2(30, 0)) and zp2[zp2.size() - 1] == Vector2(50, 0)
		and zo["items"][2][1]["points"] == PackedVector2Array([Vector2(0, 20), Vector2(50, 20)]))
	var mrules := [{"match": {"kind": "tree_row"}, "type": 1}, {"match": {"kind": "tree"}, "type": 2}]
	var src1 := [_line("tree_row", 1, [[0, 0], [20, 0]]), _line("tree_row", 2, [[0, 10], [20, 10]]), _point("tree", 3, [5, 5])]
	var m1: Dictionary = ImportRes.merge_items({}, ImportRes.items_of(src1, mrules, [])["items"], false)
	var st: Dictionary = (m1["state"] as Dictionary).duplicate(true)
	_chk(r, "a first import numbers its items in source order (%s)" % str(st["items"].keys()),
		st["items"].keys() == [1, 2, 3] and int(st["next_id"]) == 4 and int(m1["rows"]) == 2 and int(m1["trees"]) == 1
		and st["items"][1]["source"] == "osm_id:1" and not bool(st["items"][1]["edited"]))
	var st1: Dictionary = st["items"][1]
	st1["edited"] = true
	st1["points"] = PackedVector2Array([Vector2(0, 1), Vector2(20, 1)])               # the author moved row 1
	(st["items"] as Dictionary).erase(2)
	st["removed"] = ["osm_id:2"]                                                      # and deleted row 2
	st["items"][4] = {"id": 4, "kind": "tree", "at": Vector2(9, 9), "type": 1, "age": 0.0, "species": "",
		"clear_m": 3.0, "edited": false}                                              # and placed a tree
	st["next_id"] = 5
	var src2 := [_line("tree_row", 1, [[0, 0], [25, 0]]), _line("tree_row", 2, [[0, 10], [20, 10]]),
		_line("tree_row", 5, [[0, 30], [20, 30]])]                                    # upstream: 1 longer, 3 gone, 5 new
	var made2: Array = ImportRes.items_of(src2, mrules, [])["items"]
	var m2: Dictionary = ImportRes.merge_items(st, made2, false)
	var s2: Dictionary = m2["state"]
	_chk(r, "a re-import keeps the author's edit and deletion, deletes an unedited item the source lost, leaves a hand-made one, numbers a new one next (%s)" % str([s2["items"].keys(), m2["kept_edited"], m2["deleted"]]),
		s2["items"].size() == 3 and s2["items"][1]["points"] == PackedVector2Array([Vector2(0, 1), Vector2(20, 1)])
		and bool(s2["items"][1]["edited"]) and not s2["items"].has(2) and not s2["items"].has(3) and s2["items"].has(4)
		and s2["items"][5]["source"] == "osm_id:5" and int(s2["next_id"]) == 6 and s2["removed"] == ["osm_id:2"]
		and int(m2["kept_edited"]) == 1 and int(m2["skipped_removed"]) == 1 and int(m2["deleted"]) == 1 and int(m2["rows"]) == 1)
	var m3: Dictionary = ImportRes.merge_items(st, made2, true)
	var s3: Dictionary = m3["state"]
	_chk(r, "discard: the edit and the deletion go, the import's rows come back, a hand-made tree stays (%s)" % str(s3["items"].keys()),
		s3["items"][1]["points"] == PackedVector2Array([Vector2(0, 0), Vector2(25, 0)]) and not bool(s3["items"][1]["edited"])
		and s3["items"].has(4) and (s3["removed"] as Array).is_empty() and s3["items"].size() == 4
		and s3["items"][5]["source"] == "osm_id:2" and s3["items"][6]["source"] == "osm_id:5")
	var nf: Dictionary = ImportRes.run_file("user://wf_b2c_import_none.json")
	_chk(r, "the report names the single trees and rows too (%s)" % str(nf.keys()),
		nf.has("items_written") and nf.has("items_kept_edited") and nf.has("items_deleted") and nf.has("rows_cut")
		and nf.has("unmatched_lines") and nf.has("unmatched_points") and nf.get("trees_file") == "unchanged")
	for f in DirAccess.get_files_at(DIR.path_join("forest")):
		DirAccess.remove_absolute(ProjectSettings.globalize_path(DIR.path_join("forest").path_join(f)))
	for f in DirAccess.get_files_at(DIR):
		DirAccess.remove_absolute(ProjectSettings.globalize_path(DIR.path_join(f)))
	DirAccess.remove_absolute(ProjectSettings.globalize_path(DIR.path_join("forest")))
	DirAccess.remove_absolute(ProjectSettings.globalize_path(DIR))
	return r
