# Copyright (c) 2026 Digitzone
# SPDX-License-Identifier: MIT
@tool
class_name ForestImport
extends RefCounted
## World-space GeoJSON + a mapping -> the forest maps and the single trees and rows:
## polygons paint the maps, points and lines become trees.json's items. Headless; the launcher is
## res://addons/wuifwoud/tools/import_forest.gd. An import REPLACES the maps folder: every region that has a terrain
## region file and some forest gets a map, and a map of a region that now has none is deleted. An import keeps every
## texel painted by hand (A = 255) unless told to overwrite them; it runs region by region
## (ForestImportJob), staged and swapped.
##
## A mapping: {"schema": SCHEMA, "source": <a GeoJSON file, or a list of them, with "coord_space": "world">,
## "data_directory": <the terrain's>, "texel_vertices": 1|2|4|8, "exclusions": [<zone files, schema
## vegetation_exclusions/1>], "rules": [{"match": {property: value or [values]}, "type": 0-255, "density": 0-1, "age":
## -1..1, and for points and lines "spacing_m", "clear_m", "species"}, ...]}. A rule matches when every key of its
## `match` does; the FIRST matching rule wins, so rule order is the priority where features overlap. Type 0 writes no
## forest. Exclusion zones write no forest over everything, last.

## The mapping's schema.
const SCHEMA := "wuifwoud_import/1"
## The forest maps.
const ForestMapsRes := preload("res://addons/wuifwoud/forest_maps.gd")
## The exclusion zones.
const ForestExclusionsRes := preload("res://addons/wuifwoud/forest_exclusions.gd")
## The region height pump (region file names).
const ForestHeightPumpRes := preload("res://addons/wuifwoud/forest_height_pump.gd")
## The import job, loaded lazily: it preloads this script.
const JOB_PATH := "res://addons/wuifwoud/forest_import_job.gd"
## The single trees and rows.
const ForestTreesRes := preload("res://addons/wuifwoud/forest_trees.gd")
## The geometries that are items (single trees, rows), not polygons.
const ITEM_GEOMS := ["Point", "MultiPoint", "LineString", "MultiLineString"]


## Problems with a mapping; empty when it is usable.
static func validate(m: Dictionary) -> PackedStringArray:
	var e := PackedStringArray()
	if str(m.get("schema", "")) != SCHEMA:
		e.append("schema must be '%s'" % SCHEMA)
	var src = m.get("source", "")
	if typeof(src) == TYPE_ARRAY:
		if (src as Array).is_empty():
			e.append("'source' is missing")
		elif not (src as Array).all(func(s): return typeof(s) == TYPE_STRING and s != ""):
			e.append("'source' must be a file or a list of files")
	elif typeof(src) != TYPE_STRING:
		e.append("'source' must be a file or a list of files")
	elif src == "":
		e.append("'source' is missing")
	if str(m.get("data_directory", "")) == "":
		e.append("'data_directory' is missing")
	var t = m.get("texel_vertices", 1)
	if not (typeof(t) in [TYPE_INT, TYPE_FLOAT]) or float(int(t)) != float(t) or not (int(t) in ForestMapsRes.ALLOWED_T):
		e.append("texel_vertices must be one of %s" % str(ForestMapsRes.ALLOWED_T))
	if typeof(m.get("exclusions", [])) != TYPE_ARRAY:
		e.append("'exclusions' must be a list of zone files")
	var rules = m.get("rules", [])
	if typeof(rules) != TYPE_ARRAY or (rules as Array).is_empty():
		e.append("'rules' must be a non-empty list")
		return e
	for i in (rules as Array).size():
		var rl = rules[i]
		if typeof(rl) != TYPE_DICTIONARY or typeof(rl.get("match")) != TYPE_DICTIONARY \
				or (rl["match"] as Dictionary).is_empty():
			e.append("rule %d needs a non-empty 'match' object" % i)
			continue
		var ty = rl.get("type")
		if not (typeof(ty) in [TYPE_INT, TYPE_FLOAT]) or float(int(ty)) != float(ty) or int(ty) < 0 or int(ty) > 255:
			e.append("rule %d: type must be a whole number 0-255" % i)
		var dn := float(rl.get("density", 1.0))
		if dn < 0.0 or dn > 1.0:
			e.append("rule %d: density must be 0-1" % i)
		var ag := float(rl.get("age", 0.0))
		if ag < -1.0 or ag > 1.0:
			e.append("rule %d: age must be -1..1" % i)
		var spc = rl.get("spacing_m", ForestTreesRes.SPACING_M)
		if not (typeof(spc) in [TYPE_INT, TYPE_FLOAT]) or float(spc) < ForestTreesRes.MIN_SPACING_M:
			e.append("rule %d: spacing_m must be 1 or more" % i)
		var clr = rl.get("clear_m", 0.0)
		if not (typeof(clr) in [TYPE_INT, TYPE_FLOAT]) or float(clr) < 0.0:
			e.append("rule %d: clear_m must be 0 or more" % i)
		if typeof(rl.get("species", "")) != TYPE_STRING:
			e.append("rule %d: species must be text" % i)
	return e


## The index of the first rule whose every `match` key matches `props` (a value, or a list meaning any of), or -1.
## A property the feature does not have never matches.
static func match_rule(rules: Array, props: Dictionary) -> int:
	for i in rules.size():
		var mt: Dictionary = rules[i]["match"]
		var ok := true
		for k in mt:
			if not props.has(k):
				ok = false
				break
			var have := str(props[k])
			var want = mt[k]
			if typeof(want) == TYPE_ARRAY:
				if not (want as Array).any(func(w): return str(w) == have):
					ok = false
					break
			elif str(want) != have:
				ok = false
				break
		if ok:
			return i
	return -1


## The RGBA8 bytes a rule paints: type, round(density · 255), 128 + round(age · 127), 0. Type 0 is no forest.
static func texel_of(rule: Dictionary) -> PackedByteArray:
	var ty := int(rule.get("type", 0))
	if ty == 0:
		return PackedByteArray(ForestMapsRes.NONE_PX)
	return PackedByteArray([ty, int(round(clampf(float(rule.get("density", 1.0)), 0.0, 1.0) * 255.0)),
		128 + int(round(clampf(float(rule.get("age", 0.0)), -1.0, 1.0) * 127.0)), 0])


## A GeoJSON geometry's polygons, each a list of rings (PackedVector2Array of world x, z), or null for a geometry that
## is not a Polygon or MultiPolygon.
static func polygons_of(geom: Dictionary):
	match str(geom.get("type", "")):
		"Polygon":
			return [_rings(geom.get("coordinates", []))]
		"MultiPolygon":
			var out := []
			for p in geom.get("coordinates", []):
				out.append(_rings(p))
			return out
	return null


## Every feature as paint shapes in PAINT ORDER (the last rule first, so the first rule ends on top; the exclusion
## zones last of all) with the report's tallies: {"shapes": [{"rings", "bbox", "px"}], "unmatched": {"k=v": m²},
## "skipped": {geometry type: count}} (a type that is neither a polygon nor an item's).
static func shapes_of(features: Array, rules: Array, zones: Array) -> Dictionary:
	var key_list := _rule_keys(rules)
	var by_rule := []
	by_rule.resize(rules.size())
	for i in rules.size():
		by_rule[i] = []
	var unmatched := {}
	var skipped := {}
	for f in features:
		if typeof(f) != TYPE_DICTIONARY:
			continue
		var geom: Dictionary = f["geometry"] if typeof(f.get("geometry")) == TYPE_DICTIONARY else {}
		var polys = polygons_of(geom)
		if polys == null:
			var gt := str(geom.get("type", "none"))
			if not (gt in ITEM_GEOMS):
				skipped[gt] = int(skipped.get(gt, 0)) + 1
			continue
		var props: Dictionary = f["properties"] if typeof(f.get("properties")) == TYPE_DICTIONARY else {}
		var ri := match_rule(rules, props)
		if ri < 0:
			var key := _unmatched_key(key_list, props)
			unmatched[key] = float(unmatched.get(key, 0.0)) + area_of(polys)
			continue
		for rings in polys:
			if not (rings as Array).is_empty():
				by_rule[ri].append(rings)
	var shapes := []
	for ri in range(rules.size() - 1, -1, -1):
		var px := texel_of(rules[ri])
		for rings in by_rule[ri]:
			shapes.append({"rings": rings, "bbox": _bbox(rings), "px": px})
	for z in zones:
		shapes.append({"rings": [z], "bbox": _bbox([z]), "px": PackedByteArray(ForestMapsRes.NONE_PX)})
	return {"shapes": shapes, "unmatched": unmatched, "skipped": skipped}


## One region's map: `shapes` painted in order onto no forest. Texel (i, j) covers local [i·tm, (i+1)·tm) and takes a
## shape's bytes when its CENTRE is inside the shape (even-odd over its rings). Pure. The RGBA8 bytes, row by row.
static func paint_region(loc: Vector2i, region_m: float, w: int, shapes: Array) -> PackedByteArray:
	return paint_rect(loc, region_m, w, shapes, Rect2i(0, 0, w, w))


## The texels of `rect` (texel coordinates of a w-texel map) as paint_region paints them, row by row (the Revert
## brush asks for one dab's rectangle; the import for the whole map). Pure.
static func paint_rect(loc: Vector2i, region_m: float, w: int, shapes: Array, rect: Rect2i) -> PackedByteArray:
	var tm := region_m / float(w)
	var ox := float(loc.x) * region_m
	var oz := float(loc.y) * region_m
	var rw := rect.size.x
	var area := Rect2(ox + float(rect.position.x) * tm, oz + float(rect.position.y) * tm, float(rw) * tm,
		float(rect.size.y) * tm)
	var rows: Array[PackedByteArray] = []
	rows.resize(rect.size.y)
	rows.fill(_run(PackedByteArray(ForestMapsRes.NONE_PX), rw))
	for sh in shapes:
		var bb: Rect2 = sh["bbox"]
		if not bb.intersects(area, true):
			continue
		var j0 := maxi(rect.position.y, ceili((bb.position.y - oz) / tm - 0.5))
		var j1 := mini(rect.end.y - 1, floori((bb.end.y - oz) / tm - 0.5))
		if j1 < j0:
			continue
		var edges := _edges_by_row(sh["rings"], oz, tm, j0, j1)
		var px: PackedByteArray = sh["px"]
		for j in edges:
			var z := oz + (float(j) + 0.5) * tm
			var xs := PackedFloat64Array()
			for e in edges[j]:
				var a: Vector2 = e[0]
				var b: Vector2 = e[1]
				if (a.y > z) != (b.y > z):
					xs.append(a.x + (z - a.y) / (b.y - a.y) * (b.x - a.x))
			if xs.size() < 2:
				continue
			xs.sort()
			var row := int(j) - rect.position.y
			for k in range(0, xs.size() - 1, 2):
				var i0 := maxi(rect.position.x, ceili((xs[k] - ox) / tm - 0.5)) - rect.position.x
				var i1 := mini(rect.end.x - 1, floori((xs[k + 1] - ox) / tm - 0.5)) - rect.position.x
				if i1 >= i0:
					rows[row] = rows[row].slice(0, i0 * 4) + _run(px, i1 - i0 + 1) + rows[row].slice((i1 + 1) * 4)
	var out := PackedByteArray()
	for row in rows:
		out.append_array(row)
	return out


## One region's map as an Image, or null where nothing grows on it (the import goes region by region).
static func region_map(loc: Vector2i, region_m: float, w: int, shapes: Array) -> Image:
	var area := Rect2(float(loc.x) * region_m, float(loc.y) * region_m, region_m, region_m)
	if not shapes.any(func(s): return (s["bbox"] as Rect2).intersects(area, true)):
		return null
	var img := Image.create_from_data(w, w, false, Image.FORMAT_RGBA8, paint_region(loc, region_m, w, shapes))
	return img if _r_plane(img).count(0) != w * w else null


## The maps for `regions` (locations with a terrain region file): {"images": {loc: Image} for regions with some
## forest, "km2": {type: km²}, "unmatched": {"k=v": km²}, "skipped": {geometry type: count}}. Every map at once: the
## stale-map test's; an import goes region by region (ForestImportJob).
static func build(m: Dictionary, features: Array, regions: Array, region_size: int, vertex_spacing: float,
		zones: Array) -> Dictionary:
	var w := region_size / int(m.get("texel_vertices", 1))
	var region_m := float(region_size) * vertex_spacing
	var sh := shapes_of(features, m["rules"], zones)
	var types := rule_types(m["rules"])
	var texels := {}
	var images := {}
	for loc in regions:
		var img := region_map(loc, region_m, w, sh["shapes"])
		if img == null:
			continue
		images[loc] = img
		count_types(img, types, texels)
	return {"images": images, "km2": km2_of(texels, region_m / float(w)), "unmatched": unmatched_km2(sh),
		"skipped": sh["skipped"]}


## The type ids the rules paint, in rule order (no 0).
static func rule_types(rules: Array) -> Array:
	var out := []
	for rl in rules:
		var t := int(rl["type"])
		if t != 0 and not out.has(t):
			out.append(t)
	return out


## Adds each of `types`' texel count in `img` to `texels` (type -> count).
static func count_types(img: Image, types: Array, texels: Dictionary) -> void:
	var plane := _r_plane(img)
	for ty in types:
		texels[ty] = int(texels.get(ty, 0)) + plane.count(ty)


## Texel counts as km², a texel `tm` metres square.
static func km2_of(texels: Dictionary, tm: float) -> Dictionary:
	var out := {}
	for ty in texels:
		out[ty] = float(texels[ty]) * tm * tm / 1e6
	return out


## shapes_of's unmatched areas in km².
static func unmatched_km2(sh: Dictionary) -> Dictionary:
	var out := {}
	for k in sh["unmatched"]:
		out[k] = float(sh["unmatched"][k]) / 1e6
	return out


## The mapping's source files: `source` is one path or a list of them.
static func sources_of(m: Dictionary) -> Array:
	var s = m.get("source", "")
	if typeof(s) == TYPE_ARRAY:
		return (s as Array).map(func(x): return str(x)).filter(func(x): return x != "")
	return [str(s)] if str(s) != "" else []


## A GeoJSON geometry's lines (each a PackedVector2Array of two or more world x, z), or null for one that is not a
## LineString or MultiLineString, or is malformed.
static func lines_of(geom: Dictionary):
	var t := str(geom.get("type", ""))
	var parts: Array
	if t == "LineString":
		parts = [geom.get("coordinates")]
	elif t == "MultiLineString" and typeof(geom.get("coordinates")) == TYPE_ARRAY:
		parts = geom["coordinates"]
	else:
		return null
	var out := []
	for c in parts:
		var l := PackedVector2Array()
		if typeof(c) == TYPE_ARRAY:
			for v in c:
				if typeof(v) == TYPE_ARRAY and (v as Array).size() >= 2:
					l.append(Vector2(float(v[0]), float(v[1])))
		if l.size() < 2:
			return null
		out.append(l)
	return out if not out.is_empty() else null


## A GeoJSON geometry's points (world x, z), or null for one that is not a Point or MultiPoint, or is malformed.
static func points_of(geom: Dictionary):
	var t := str(geom.get("type", ""))
	var parts: Array
	if t == "Point":
		parts = [geom.get("coordinates")]
	elif t == "MultiPoint" and typeof(geom.get("coordinates")) == TYPE_ARRAY:
		parts = geom["coordinates"]
	else:
		return null
	var out := []
	for v in parts:
		if typeof(v) != TYPE_ARRAY or (v as Array).size() < 2:
			return null
		out.append(Vector2(float(v[0]), float(v[1])))
	return out if not out.is_empty() else null


## Lines' length (m).
static func length_of(lines: Array) -> float:
	var n := 0.0
	for l in lines:
		var pts: PackedVector2Array = l
		for i in range(1, pts.size()):
			n += pts[i - 1].distance_to(pts[i])
	return n


## An imported item's key: "osm_id:<n>" from the feature's osm_id (a whole number printed whole), else
## "id:<v>", else "geom:" and the first 12 hex digits of the MD5 of its coordinates rounded to 0.01 m.
static func key_of(props: Dictionary, geom: Dictionary) -> String:
	for k in ["osm_id", "id"]:
		var v = props.get(k)
		if v == null or str(v) == "":
			continue
		var s := str(int(v)) if typeof(v) == TYPE_FLOAT and float(int(v)) == float(v) else str(v)
		return "%s:%s" % [k, s]
	return "geom:" + JSON.stringify(_round_coords(geom.get("coordinates"))).md5_text().substr(0, 12)


static func _round_coords(c):
	if typeof(c) == TYPE_ARRAY:
		return (c as Array).map(func(x): return _round_coords(x))
	return snappedf(float(c), 0.01) if typeof(c) in [TYPE_INT, TYPE_FLOAT] else c


## The points and lines of `features` as single trees and rows, before ids (the polygons are the
## maps', shapes_of): {"items": [[key, item]] in source order, "unmatched_lines": {"k=v": metres}, "unmatched_points":
## {"k=v": points}, "invalid": {geometry type: features}, "cut": rows a zone cut, "dups": keys seen twice}. A rule's
## type, age, spacing_m, clear_m and species; type 0 skips. A point in an exclusion zone is skipped; a row is cut at the
## zones' edges, its pieces keyed k~1, k~2, …; a Multi geometry's parts k#0, k#1, …; a key seen again k^2, k^3, ….
## Pure.
static func items_of(features: Array, rules: Array, zones: Array) -> Dictionary:
	var key_list := _rule_keys(rules)
	var out := {"items": [], "unmatched_lines": {}, "unmatched_points": {}, "invalid": {}, "cut": 0, "dups": 0}
	var seen := {}
	for f in features:
		if typeof(f) != TYPE_DICTIONARY:
			continue
		var geom: Dictionary = f["geometry"] if typeof(f.get("geometry")) == TYPE_DICTIONARY else {}
		var gt := str(geom.get("type", ""))
		if not (gt in ITEM_GEOMS):
			continue
		var line := gt.ends_with("LineString")
		var parts = lines_of(geom) if line else points_of(geom)
		if parts == null:
			out["invalid"][gt] = int(out["invalid"].get(gt, 0)) + 1
			continue
		var props: Dictionary = f["properties"] if typeof(f.get("properties")) == TYPE_DICTIONARY else {}
		var ri := match_rule(rules, props)
		if ri < 0:
			var uk := _unmatched_key(key_list, props)
			if line:
				out["unmatched_lines"][uk] = float(out["unmatched_lines"].get(uk, 0.0)) + length_of(parts)
			else:
				out["unmatched_points"][uk] = int(out["unmatched_points"].get(uk, 0)) + (parts as Array).size()
			continue
		var rule: Dictionary = rules[ri]
		if int(rule.get("type", 0)) == 0:
			continue
		var base := key_of(props, geom)
		var multi := gt.begins_with("Multi")
		for pi in (parts as Array).size():
			var k := ("%s#%d" % [base, pi]) if multi else base
			if line:
				var res := cut_line(parts[pi], zones)
				if bool(res["cut"]):
					out["cut"] = int(out["cut"]) + 1
				var pieces: Array = res["pieces"]
				for qi in pieces.size():
					var kk := ("%s~%d" % [k, qi + 1]) if bool(res["cut"]) else k
					_add_item(out, seen, kk, _item_of(rule, "row", pieces[qi]))
			elif not in_zones(parts[pi], zones):
				_add_item(out, seen, k, _item_of(rule, "tree", parts[pi]))
	return out


## An item as a rule makes it (no id yet).
static func _item_of(rule: Dictionary, kind: String, geo) -> Dictionary:
	var row := kind == "row"
	var it := {"kind": kind, "type": int(rule["type"]), "age": clampf(float(rule.get("age", 0.0)), -1.0, 1.0),
		"species": str(rule.get("species", "")),
		"clear_m": float(rule.get("clear_m", ForestTreesRes.ROW_CLEAR_M if row else ForestTreesRes.TREE_CLEAR_M)),
		"edited": false}
	if row:
		it["points"] = geo
		it["spacing_m"] = maxf(float(rule.get("spacing_m", ForestTreesRes.SPACING_M)), ForestTreesRes.MIN_SPACING_M)
	else:
		it["at"] = geo
	return it


static func _add_item(out: Dictionary, seen: Dictionary, k: String, it: Dictionary) -> void:
	var key := k
	if seen.has(k):
		seen[k] = int(seen[k]) + 1
		key = "%s^%d" % [k, seen[k]]
		out["dups"] = int(out["dups"]) + 1
	else:
		seen[k] = 1
	it["source"] = key
	(out["items"] as Array).append([key, it])


## A line cut by the exclusion zones: {"pieces": [PackedVector2Array] outside every zone, "cut":
## whether a zone took any of it}. Each segment is split where it crosses a zone's edge; a part whose middle is inside a
## zone is dropped; a piece shorter than ForestTrees.SHORT_ROW_M goes too. A line no zone takes comes back whole.
static func cut_line(pts: PackedVector2Array, zones: Array) -> Dictionary:
	if zones.is_empty():
		return {"pieces": [pts], "cut": false}
	var pieces := []
	var cur := PackedVector2Array()
	var cut := false
	for i in range(1, pts.size()):
		var a := pts[i - 1]
		var b := pts[i]
		var ab_len := a.distance_to(b)
		var ts := [0.0, 1.0]
		for z in zones:
			var ring: PackedVector2Array = z
			for j in ring.size():
				var x = Geometry2D.segment_intersects_segment(a, b, ring[j], ring[(j + 1) % ring.size()])
				if x != null and ab_len > 0.0:
					ts.append(a.distance_to(x) / ab_len)
		ts.sort()
		for q in range(1, ts.size()):
			var t0: float = ts[q - 1]
			var t1: float = ts[q]
			if t1 - t0 <= 1e-9:
				continue
			if in_zones(a.lerp(b, (t0 + t1) * 0.5), zones):
				cut = true
				if cur.size() >= 2:
					pieces.append(cur)
				cur = PackedVector2Array()
				continue
			if cur.is_empty():
				cur.append(a.lerp(b, t0))
			cur.append(a.lerp(b, t1))
	if cur.size() >= 2:
		pieces.append(cur)
	if not cut:
		return {"pieces": [pts], "cut": false}
	return {"pieces": pieces.filter(func(pc): return length_of([pc]) >= ForestTreesRes.SHORT_ROW_M), "cut": true}


## `p` is inside an exclusion zone (each a ring).
static func in_zones(p: Vector2, zones: Array) -> bool:
	for z in zones:
		if Geometry2D.is_point_in_polygon(p, z):
			return true
	return false


## The single trees and rows a re-import leaves: `old` the current set (ForestTrees.state()'s shape;
## {}: none), `made` items_of's items. A removed key is skipped; an imported item the author edited is kept, also
## when the source no longer has it; any other imported item is the source's now (its id kept), or deleted when the
## source lost it; a hand-made item is never touched; a new key takes the next id. `discard` (Overwrite painted texels)
## drops the edits and the removed keys, never a hand-made item. Pure. {"state", "rows", "trees", "kept_edited",
## "skipped_removed", "deleted"}.
static func merge_items(old: Dictionary, made: Array, discard: bool) -> Dictionary:
	var old_items: Dictionary = old.get("items", {})
	var removed: Array = [] if discard else (old.get("removed", []) as Array).duplicate()
	var next_id := int(old.get("next_id", 1))
	var by_key := {}
	var out_items := {}
	for id in old_items:
		var it: Dictionary = old_items[id]
		if it.has("source"):
			by_key[it["source"]] = it
		else:
			out_items[int(id)] = it.duplicate(true)
		next_id = maxi(next_id, int(id) + 1)
	var rep := {"rows": 0, "trees": 0, "kept_edited": 0, "skipped_removed": 0, "deleted": 0}
	var seen := {}
	for pair in made:
		var k: String = pair[0]
		seen[k] = true
		if removed.has(k):
			rep["skipped_removed"] += 1
			continue
		var was: Dictionary = by_key.get(k, {})
		if not was.is_empty() and bool(was.get("edited", false)) and not discard:
			out_items[int(was["id"])] = was.duplicate(true)
			rep["kept_edited"] += 1
			continue
		var it: Dictionary = (pair[1] as Dictionary).duplicate(true)
		var id := int(was["id"]) if not was.is_empty() else next_id
		if was.is_empty():
			next_id += 1
		it["id"] = id
		it["source"] = k
		it["edited"] = false
		out_items[id] = it
		rep["rows" if it["kind"] == "row" else "trees"] += 1
	for k in by_key:
		if seen.has(k):
			continue
		var was: Dictionary = by_key[k]
		if bool(was.get("edited", false)) and not discard:
			out_items[int(was["id"])] = was.duplicate(true)
			rep["kept_edited"] += 1
		else:
			rep["deleted"] += 1
	rep["state"] = {"items": out_items, "removed": removed, "next_id": next_id}
	return rep


## The property keys any rule matches on, sorted: how an unmatched feature is named in the report.
static func _rule_keys(rules: Array) -> Array:
	var keys := {}
	for rl in rules:
		for k in (rl["match"] as Dictionary):
			keys[k] = true
	var out := keys.keys()
	out.sort()
	return out


static func _unmatched_key(key_list: Array, props: Dictionary) -> String:
	var parts := PackedStringArray()
	for k in key_list:
		parts.append("%s=%s" % [k, str(props.get(k, ""))])
	return ", ".join(parts)


## An RGBA8 image's R plane.
static func _r_plane(img: Image) -> PackedByteArray:
	var p := img.duplicate() as Image
	p.convert(Image.FORMAT_R8)
	return p.get_data()


## An RGBA8 map with a texel whose A is above 0: something was painted on it.
static func painted(img: Image) -> bool:
	return img != null and not img.is_empty() and img.get_format() == Image.FORMAT_RGBA8 \
		and img.get_used_rect().has_area()


## The map a re-import writes where `old` is on disk (null: none) and the import made `made` (null:
## nothing grows) at w texels: every A = 255 texel from `old`, every other texel from `made` with A = 0; null when `old`
## holds no painted texel and `made` is null. `old` at another size keeps every painted texel: a finer old map's paints
## the coarse texel under it, a coarser one's every fine texel it covers. An A between 1 and 254 is not paint. Pure;
## neither image is changed.
static func merge_painted(old: Image, made: Image, w: int) -> Image:
	if not painted(old):
		return made
	var used := old.get_used_rect()
	var ow := old.get_width()
	var a := old.get_data()
	var out := made.get_data() if made != null else _run(PackedByteArray(ForestMapsRes.NONE_PX), w * w)
	var any := false
	for j in range(used.position.y, used.end.y):
		for i in range(used.position.x, used.end.x):
			var k := (j * ow + i) * 4
			if a[k + 3] != 255:
				continue
			any = true
			if ow >= w:
				var o := ((j * w / ow) * w + i * w / ow) * 4
				out[o] = a[k]
				out[o + 1] = a[k + 1]
				out[o + 2] = a[k + 2]
				out[o + 3] = 255
			else:
				var s := w / ow
				for jj in range(j * s, j * s + s):
					for ii in range(i * s, i * s + s):
						var o := (jj * w + ii) * 4
						out[o] = a[k]
						out[o + 1] = a[k + 1]
						out[o + 2] = a[k + 2]
						out[o + 3] = 255
	if not any:
		return made
	return Image.create_from_data(w, w, false, Image.FORMAT_RGBA8, out)


## The source's property values, for the import dialog: {"areas": {key: {value: m²}},
## "lengths": {key: {value: m of lines}}, "points": {key: {value: points}}, "counts": {key: {value: features}},
## "features": features counted}. Values as text, as match_rule compares them; polygons, lines and points count. Pure.
static func scan_source(features: Array) -> Dictionary:
	var out := {"areas": {}, "lengths": {}, "points": {}, "counts": {}, "features": 0}
	for f in features:
		if typeof(f) != TYPE_DICTIONARY:
			continue
		var geom: Dictionary = f["geometry"] if typeof(f.get("geometry")) == TYPE_DICTIONARY else {}
		var measure := ""
		var amount := 0.0
		var polys = polygons_of(geom)
		if polys != null:
			measure = "areas"
			amount = area_of(polys)
		else:
			var lines = lines_of(geom)
			if lines != null:
				measure = "lengths"
				amount = length_of(lines)
			else:
				var pts = points_of(geom)
				if pts == null:
					continue
				measure = "points"
				amount = float((pts as Array).size())
		out["features"] = int(out["features"]) + 1
		var props: Dictionary = f["properties"] if typeof(f.get("properties")) == TYPE_DICTIONARY else {}
		for k in props:
			var key := str(k)
			var v := str(props[k])
			for mk in ["areas", "lengths", "points", "counts"]:
				if not (out[mk] as Dictionary).has(key):
					out[mk][key] = {}
			if measure == "points":
				out["points"][key][v] = int(out["points"][key].get(v, 0)) + int(amount)
			else:
				out[measure][key][v] = float(out[measure][key].get(v, 0.0)) + amount
			out["counts"][key][v] = int(out["counts"][key].get(v, 0)) + 1
	return out


## The terrain's regions in `data_directory`: {"regions": [Vector2i], "region_size", "vertex_spacing"}, read from its
## region files (one read through load_fresh: safe on a worker); {} without one.
static func region_meta(data_directory: String) -> Dictionary:
	var regions: Array[Vector2i] = []
	var first := ""
	if not DirAccess.dir_exists_absolute(data_directory):
		return {}
	for f in DirAccess.get_files_at(data_directory):
		var loc = ForestHeightPumpRes.parse_region_filename(f)
		if loc != null:
			regions.append(loc)
			if first == "":
				first = data_directory.path_join(f)
	if regions.is_empty():
		return {}
	var r: Resource = load_fresh(first)
	if r == null:
		return {}
	return {"regions": regions, "region_size": int(r.get("region_size")), "vertex_spacing": float(r.get("vertex_spacing"))}


## A file read fresh through the threaded loader: safe on a worker, where a plain load() of a path answers null the
## second time it is asked. Null when it cannot be read. A concurrent request for the same path may
## share the object: never change what this returns in place.
static func load_fresh(path: String) -> Resource:
	if ResourceLoader.load_threaded_request(path, "", false, ResourceLoader.CACHE_MODE_IGNORE) != OK:
		return null
	var st := ResourceLoader.load_threaded_get_status(path)
	while st == ResourceLoader.THREAD_LOAD_IN_PROGRESS:
		OS.delay_usec(500)
		st = ResourceLoader.load_threaded_get_status(path)
	var res := ResourceLoader.load_threaded_get(path)
	return res if st == ResourceLoader.THREAD_LOAD_LOADED else null


## A mapping file, run: see run().
static func run_file(mapping_path: String, discard_painted := false) -> Dictionary:
	var m = JSON.parse_string(FileAccess.get_file_as_string(mapping_path)) \
		if FileAccess.file_exists(mapping_path) else null
	if typeof(m) != TYPE_DICTIONARY:
		return _report(["%s is not a JSON object" % mapping_path])
	return run(m, {}, discard_painted)


## A mapping, run on this thread (ForestImportJob.run_now) against the terrain `meta` describes
## (region_meta's shape; empty: read from the mapping's data_directory). Writes <data_directory>/forest and returns the
## report: {"ok", "errors", "cancelled", "written", "kept_painted", "deleted", "deleted_no_region", "resampled",
## "painted_overwritten", "km2", "unmatched", "skipped", "bytes", "ms", "dir"}. Keeps every texel painted by hand unless
## `discard_painted`.
static func run(m: Dictionary, meta: Dictionary = {}, discard_painted := false) -> Dictionary:
	return load(JOB_PATH).new(m, {"meta": meta, "discard_painted": discard_painted}).run_now()


static func _report(errors: Array) -> Dictionary:
	return {"ok": errors.is_empty(), "errors": errors, "cancelled": false, "written": [], "kept_painted": [],
		"deleted": [], "deleted_no_region": [], "resampled": [], "painted_overwritten": [], "km2": {},
		"unmatched": {}, "skipped": {}, "bytes": 0, "ms": 0, "dir": "",
		"items_written": {"rows": 0, "trees": 0}, "items_kept_edited": 0, "items_skipped_removed": 0,
		"items_deleted": 0, "rows_cut": 0, "items_dup_keys": 0, "items_invalid": {}, "unmatched_lines": {},
		"unmatched_points": {}, "trees_file": "unchanged"}


static func _rings(coords) -> Array:
	var out := []
	if typeof(coords) != TYPE_ARRAY:
		return out
	for ring in coords:
		var rg := PackedVector2Array()
		if typeof(ring) == TYPE_ARRAY:
			for c in ring:
				if typeof(c) == TYPE_ARRAY and (c as Array).size() >= 2:
					rg.append(Vector2(float(c[0]), float(c[1])))
		if rg.size() >= 2 and rg[0].is_equal_approx(rg[rg.size() - 1]):
			rg.remove_at(rg.size() - 1)
		if rg.size() >= 3:
			out.append(rg)
	return out


static func _bbox(rings: Array) -> Rect2:
	var first: PackedVector2Array = rings[0]
	var box := Rect2(first[0], Vector2.ZERO)
	for rg in rings:
		for p in (rg as PackedVector2Array):
			box = box.expand(p)
	return box


## Polygons' area, holes subtracted (m²): the report's unmatched figure and the dialog's value areas.
static func area_of(polys: Array) -> float:
	var a := 0.0
	for rings in polys:
		for i in (rings as Array).size():
			var rg: PackedVector2Array = rings[i]
			var s := 0.0
			for k in rg.size():
				var p := rg[k]
				var q := rg[(k + 1) % rg.size()]
				s += p.x * q.y - q.x * p.y
			a += absf(s) * 0.5 * (1.0 if i == 0 else -1.0)
	return a


## Rows whose texel-centre z an edge spans: {row: [[a, b], ...]} over rows j0..j1.
static func _edges_by_row(rings: Array, oz: float, tm: float, j0: int, j1: int) -> Dictionary:
	var out := {}
	for ring in rings:
		var rg: PackedVector2Array = ring
		var n := rg.size()
		for i in n:
			var a := rg[i]
			var b := rg[(i + 1) % n]
			var lo := maxi(j0, ceili((minf(a.y, b.y) - oz) / tm - 0.5))
			var hi := mini(j1, floori((maxf(a.y, b.y) - oz) / tm - 0.5))
			for j in range(lo, hi + 1):
				if not out.has(j):
					out[j] = []
				(out[j] as Array).append([a, b])
	return out


## `n` texels of `px`, built by doubling (a few native appends, not n).
static func _run(px: PackedByteArray, n: int) -> PackedByteArray:
	var out := px.duplicate()
	while out.size() < n * 4:
		out.append_array(out)
	return out.slice(0, n * 4)
