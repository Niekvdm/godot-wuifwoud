# Copyright (c) 2026 Digitzone
# SPDX-License-Identifier: MIT
extends RefCounted
## A type's lanes: by its style, a band's with its dead row; an own lane at full strength, an inheriting one dimmed and
## saying from where; a switched-off species framed red; a stacked bar a species; a species dropped from the strip onto
## an inheriting lane (what it inherited copied first, the lane's mean weight); a tile dropped on its own lane, or a
## species a lane has, changes nothing and leaves no undo step; a tile moved to another lane with its weight, dragged out
## of the lanes, dropped on a dead row; a tile's weight and ✕; Copy from… and Reset; the Defaults row's lanes; the strip:
## what the forest grows, a filter, a search, a click adding to the lane in focus.
##
## Run with a unit-suite runner: static run() returns {name, passed, failed, details}.

const Fix := preload("res://addons/wuifwoud/tests/fixtures/types_fixture.gd")
const ROOT := "user://wf_e2_type_lanes"


static func _chk(r: Dictionary, n: String, ok: bool) -> void:
	if ok:
		r.passed += 1
	else:
		r.failed += 1
		r.details.append("✗ " + n)


static func _disk(path: String) -> Dictionary:
	var v = JSON.parse_string(FileAccess.get_file_as_string(path))
	return v if v is Dictionary else {}


## Type `id`'s own mixes on disk ({}: none).
static func _mixes(path: String, id: int) -> Dictionary:
	for t in (_disk(path).get("types", []) as Array):
		if t is Dictionary and t.has("id") and int(t["id"]) == id:
			return t.get("mixes", {})
	return {}


static func _names(entries) -> Array:
	return (entries as Array).map(func(e): return str(e[0]) if e is Array else str(e)) if entries is Array else []


## The species ids of row `lane`'s tiles, in order.
static func _tiles(d: Node, lane: String) -> Array:
	var row: Node = d.find_child("Drop_" + lane.replace(".", "_"), true, false)
	var flow: Node = row.find_child("Tiles", true, false) if row != null else null
	return flow.get_children().map(func(t): return String(t.name).substr(9)) if flow != null else []


## Every label's text under `n`, joined.
static func _texts(n: Node) -> String:
	var out := PackedStringArray()
	if n != null:
		for l in n.find_children("*", "Label", true, false):
			out.append((l as Label).text)
	return " | ".join(out)


static func _strip(d: Node) -> Array:
	var row: Node = d.find_child("StripTiles", true, false)
	return row.get_children().map(func(t): return String(t.id)) if row != null else []


static func run() -> Dictionary:
	var r := {"name": "forest_type_lanes", "passed": 0, "failed": 0, "details": []}
	var fx := Fix.make(ROOT)
	var made: Array = Fix.dialog(fx)
	var d = made[0]
	var path: String = fx["profile"]
	d.select(1)
	_chk(r, "Wood's lanes: coast, mid, high (each with its dead row), bushes; no grid lane",
		d.find_child("Lane_coast", true, false) != null and d.find_child("Drop_dead_mid", true, false) != null
		and d.find_child("Lane_bush", true, false) != null and d.find_child("Lane_grid", true, false) == null)
	var mid_row: Node = d.find_child("Drop_mid", true, false)
	var high_row: Node = d.find_child("Drop_high", true, false)
	_chk(r, "an own lane at full strength; an inheriting one dimmed, saying from where (%s / %s)" % [_texts(mid_row),
		_texts(high_row)],
		(d.find_child("Drop_coast", true, false) as Control).modulate.a == 1.0 and (mid_row as Control).modulate.a < 1.0
		and _texts(mid_row).contains("map's default") and _texts(high_row).contains("project's default"))
	var other: Node = d.find_child("Drop_coast", true, false).find_child("LaneTile_W_Other", true, false)
	_chk(r, "a lane's tiles in order; a switched-off species framed red and said (%s)" % str(_tiles(d, "coast")),
		_tiles(d, "coast") == ["W_Other", "W_Tree"] and other != null and other.get_meta("why", "") == "switched off"
		and _texts(d.find_child("Drop_coast", true, false)).contains("W_Other is switched off"))
	var bar: Node = d.find_child("Drop_coast", true, false).find_child("Bar", true, false)
	_chk(r, "a stacked bar, a segment a species", bar != null and bar.get_child_count() == 2)
	# ── drops ──
	mid_row._drop_data(Vector2.ZERO, {"kind": "wuifwoud_species", "id": "W_Bush"})
	_chk(r, "a species dropped from the strip on an inheriting lane: what it inherited copied, then added at its mean (%s)" % str(_mixes(path, 1).get("mid")),
		_mixes(path, 1).get("mid") == [["W_Tree", 3.0], ["W_New", 1.0], ["W_Bush", 2.0]])
	var depth: int = d._undo.size()
	d.find_child("Drop_mid", true, false)._drop_data(Vector2.ZERO, {"kind": d.LANE_KIND, "id": "mid|W_Bush"})
	_chk(r, "a tile dropped on its own lane: nothing written, no undo step", d._undo.size() == depth)
	d.find_child("Drop_mid", true, false)._drop_data(Vector2.ZERO, {"kind": "wuifwoud_species", "id": "W_Bush"})
	_chk(r, "a species the lane has: refused and said, no undo step (%s)" % d.error, d._undo.size() == depth
		and d.error.contains("already"))
	d.find_child("Drop_high", true, false)._drop_data(Vector2.ZERO, {"kind": d.LANE_KIND, "id": "mid|W_Bush"})
	_chk(r, "a tile dropped on another lane moves there with its weight",
		not _names(_mixes(path, 1).get("mid")).has("W_Bush") and _mixes(path, 1).get("high") == [["W_Tree", 1.0], ["W_Bush", 2.0]])
	d.find_child("Lanes", true, false)._drop_data(Vector2.ZERO, {"kind": d.LANE_KIND, "id": "high|W_Bush"})
	_chk(r, "a tile dragged out of the lanes leaves its lane", _mixes(path, 1).get("high") == [["W_Tree", 1.0]])
	d.find_child("Drop_dead_mid", true, false)._drop_data(Vector2.ZERO, {"kind": "wuifwoud_species", "id": "W_Tree"})
	_chk(r, "a dead row takes a species without a weight",
		(_mixes(path, 1).get("dead", {}) as Dictionary).get("mid") == ["W_Missing", "W_Tree"])
	# ── a tile's weight and ✕ ──
	d.pick_tile("coast", "W_Tree")
	var w_row: Node = d.find_child("Weight", true, false)
	var w: HSlider = w_row.get_node("Slider") as HSlider if w_row != null else null
	w.value = 4.5
	w.drag_ended.emit(true)
	_chk(r, "a tile clicked shows its weight; let go, it is written",
		_mixes(path, 1).get("coast") == [["W_Other", 1.0], ["W_Tree", 4.5]])
	(d.find_child("Remove", true, false) as Button).pressed.emit()
	_chk(r, "✕ takes it out", _mixes(path, 1).get("coast") == [["W_Other", 1.0]] and d.lane_pick.is_empty())
	# ── Copy from…, Reset to default ──
	var srcs: Array = d.copy_sources("bush")
	var at := -1
	for i in srcs.size():
		if String(srcs[i]["text"]).begins_with("Scrub"):
			at = i
	var menu := d.find_child("Lane_bush", true, false).find_child("CopyFrom", true, false) as MenuButton
	menu.get_popup().id_pressed.emit(at)
	_chk(r, "Copy from… another type's lane of the same kind; the default first (%s)" % str(srcs.map(func(s): return s["text"])),
		at > 0 and String(srcs[0]["text"]).begins_with("The default") and _mixes(path, 1).get("bush") == [["W_Bush", 1.0]])
	(d.find_child("Lane_bush", true, false).find_child("Reset", true, false) as Button).pressed.emit()
	_chk(r, "Reset to default drops the own mix", not _mixes(path, 1).has("bush"))
	# ── the Defaults row ──
	d.select(0)
	var gone: Node = d.find_child("Drop_coast", true, false).find_child("LaneTile_W_Gone", true, false)
	_chk(r, "the Defaults row: every default pool; the one the fallback supplies dimmed; a species no pack has framed red",
		d.find_child("Lane_grid", true, false) != null and (d.find_child("Drop_high", true, false) as Control).modulate.a < 1.0
		and (d.find_child("Drop_mid", true, false) as Control).modulate.a == 1.0 and gone != null
		and gone.get_meta("why", "") == "in no species pack")
	# ── the strip ──
	_chk(r, "the strip: what the forest grows, a switched-off species left out (%s)" % str(_strip(d)),
		_strip(d) == ["W_Bush", "W_Missing", "W_New", "W_Tree"])
	d.set_strip_filter("bushes")
	_chk(r, "Bushes", _strip(d) == ["W_Bush"])
	d.set_strip_filter("all")
	d.strip_search_changed("new")
	d._apply_strip_search()
	_chk(r, "the search", _strip(d) == ["W_New"])
	d.strip_search_changed("")
	d._apply_strip_search()
	d.focus_lane("mid")
	(d.find_child("StripTiles", true, false).get_child(0) as Button).pressed.emit()
	_chk(r, "a strip tile clicked joins the lane in focus (the Defaults' mid: the map's own pool)",
		_names(_disk(path)["species"]["mid"]).has("W_Bush"))
	d.free()
	Fix.clean(ROOT)
	return r
