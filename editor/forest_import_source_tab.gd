# Copyright (c) 2026 Digitzone
# SPDX-License-Identifier: MIT
@tool
extends RefCounted
## The Import dialog's Source tab: the source files (each with what was read from it:
## polygons paint the maps, points and lines are single trees and rows), the terrain
## folder and its regions (and a note when the scene's forest reads its maps from elsewhere), the texel size and what a
## texel costs, the exclusion files and their zones.

## The forest maps (their texel sizes).
const ForestMapsRes := preload("res://addons/wuifwoud/forest_maps.gd")
## The texel sizes offered (vertices a texel).
const SIZES := [1, 2, 4, 8]


## The tab for the dialog `d`.
static func build(d) -> Control:
	var sc := ScrollContainer.new()
	sc.name = "SourceScroll"
	sc.horizontal_scroll_mode = ScrollContainer.SCROLL_MODE_DISABLED
	var v := VBoxContainer.new()
	v.name = "SourceTab"
	v.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	v.add_theme_constant_override("separation", 6)
	sc.add_child(v)
	var doc: Dictionary = d.mapping.doc
	var ready: bool = d.read_ready()
	var f: Dictionary = d.reader.files if ready else {}
	v.add_child(d.kit.section("Sources"))
	var srcs: Array = d.mapping.sources()
	var rows: Array = f.get("sources", [])
	for i in srcs.size():
		var h := HBoxContainer.new()
		h.name = "Source%d" % i
		var l := Label.new()
		l.text = str(srcs[i])
		l.clip_text = true
		l.size_flags_horizontal = Control.SIZE_EXPAND_FILL
		h.add_child(l)
		var row: Dictionary = rows[i] if i < rows.size() else {}
		if not row.is_empty():
			var kinds := PackedStringArray()
			for k in (row.get("kinds", {}) as Dictionary):
				kinds.append("%d %s" % [int(row["kinds"][k]), k])
			h.add_child(d.note("%d features: %s" % [int(row.get("features", 0)), ", ".join(kinds)]))
		var x := Button.new()
		x.name = "Remove"
		x.text = "✕"
		x.tooltip_text = "Remove this source"
		x.focus_mode = Control.FOCUS_NONE
		var at := i
		x.pressed.connect(func() -> void: d.change(func() -> void: d.mapping.remove_source(at)))
		h.add_child(x)
		v.add_child(h)
		for e in row.get("errors", []):
			v.add_child(d.red(String(e)))
	var add_src: Button = d.kit.chip("+ Add a source…", false, d.accent)
	add_src.name = "AddSource"
	add_src.size_flags_horizontal = Control.SIZE_SHRINK_BEGIN
	add_src.pressed.connect(func() -> void: d.pick("A source: world-space GeoJSON",
		PackedStringArray(["*.geojson, *.json ; GeoJSON"]), false,
		func(p: String) -> void: d.change(func() -> void: d.mapping.add_source(p))))
	v.add_child(add_src)
	if not ready:
		v.add_child(d.hint("reading the sources…"))
	else:
		var kinds_all := PackedStringArray()
		for k in (f.get("kinds", {}) as Dictionary):
			kinds_all.append("%d %s" % [int(f["kinds"][k]), k])
		var info: Label = d.hint("%d features in all: %s · polygons paint the maps, points and lines are single trees and rows" % [
			(f.get("features", []) as Array).size(), ", ".join(kinds_all)])
		info.name = "SourceInfo"
		v.add_child(info)
	v.add_child(d.kit.section("Terrain folder"))
	v.add_child(_path_row(d, "Terrain", str(doc.get("data_directory", "")), "The terrain's folder (its region files)",
		PackedStringArray(), true,
		func(p: String) -> void: d.change(func() -> void: d.mapping.doc["data_directory"] = p)))
	var meta: Dictionary = f.get("meta", {})
	if not meta.is_empty():
		var ti: Label = d.hint("%d regions · %d vertices a side · %.2f m a vertex" % [(meta["regions"] as Array).size(),
			int(meta["region_size"]), float(meta["vertex_spacing"])])
		ti.name = "TerrainInfo"
		v.add_child(ti)
	var writes := str(doc.get("data_directory", "")).path_join(ForestMapsRes.FOLDER)
	if d.maps_dir != "" and d.maps_dir.simplify_path() != writes.simplify_path():
		var n: Label = d.amber("This scene's forest reads its maps from %s; the import writes %s." % [d.maps_dir, writes])
		n.name = "MapsNote"
		v.add_child(n)
	v.add_child(d.kit.section("Texel size (vertices a texel)"))
	var t := int(doc.get("texel_vertices", 1))
	var seg: HBoxContainer = d.kit.segmented(SIZES.map(func(x): return "%d" % x), SIZES.find(t), d.accent,
		func(i: int) -> void: d.change(func() -> void: d.mapping.doc["texel_vertices"] = SIZES[i]))
	seg.name = "TexelSize"
	v.add_child(seg)
	if not meta.is_empty():
		var w := int(meta["region_size"]) / maxi(t, 1)
		var cost: Label = d.hint("%.2f m a texel · %d × %d texels a region · %.1f MB a map in memory" % [
			float(t) * float(meta["vertex_spacing"]), w, w, float(w * w * 4) / 1048576.0])
		cost.name = "TexelCost"
		v.add_child(cost)
	v.add_child(d.kit.section("Exclusions (nothing grows inside)"))
	var ex: Array = doc.get("exclusions", [])
	var counts: Array = f.get("zone_counts", [])
	for i in ex.size():
		var h := HBoxContainer.new()
		h.name = "Exclusion%d" % i
		var l := Label.new()
		l.text = str(ex[i])
		l.clip_text = true
		l.size_flags_horizontal = Control.SIZE_EXPAND_FILL
		h.add_child(l)
		if i < counts.size():
			h.add_child(d.note("%d zones" % int(counts[i]) if int(counts[i]) >= 0 else "unreadable"))
		var x := Button.new()
		x.name = "Remove"
		x.text = "✕"
		x.tooltip_text = "Remove"
		x.focus_mode = Control.FOCUS_NONE
		var at := i
		x.pressed.connect(func() -> void: d.change(func() -> void: (d.mapping.doc["exclusions"] as Array).remove_at(at)))
		h.add_child(x)
		v.add_child(h)
	var add: Button = d.kit.chip("+ Add exclusion zones…", false, d.accent)
	add.name = "AddExclusion"
	add.size_flags_horizontal = Control.SIZE_SHRINK_BEGIN
	add.pressed.connect(func() -> void: d.pick("Exclusion zones (vegetation_exclusions/1)",
		PackedStringArray(["*.json ; Zones"]), false,
		func(p: String) -> void: d.change(func() -> void: (d.mapping.doc["exclusions"] as Array).append(p))))
	v.add_child(add)
	return sc


## A path field (Enter or leaving it writes it) and its … picker.
static func _path_row(d, nm: String, value: String, title: String, filters: PackedStringArray, dir_mode: bool,
		on_set: Callable) -> Control:
	var h := HBoxContainer.new()
	h.name = nm + "Row"
	var e := LineEdit.new()
	e.name = nm + "Path"
	e.text = value
	e.placeholder_text = "res://…"
	e.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	e.text_submitted.connect(func(t: String) -> void: _set_path(value, t, on_set))
	e.focus_exited.connect(func() -> void: _set_path(value, e.text, on_set))
	h.add_child(e)
	var b := Button.new()
	b.name = nm + "Pick"
	b.text = "…"
	b.tooltip_text = title
	b.focus_mode = Control.FOCUS_NONE
	b.pressed.connect(func() -> void: d.pick(title, filters, dir_mode, on_set))
	h.add_child(b)
	return h


static func _set_path(was: String, now: String, on_set: Callable) -> void:
	if now != was:
		on_set.call(now)
