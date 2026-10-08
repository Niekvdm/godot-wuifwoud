# Copyright (c) 2026 Digitzone
# SPDX-License-Identifier: MIT
@tool
extends RefCounted
## The single trees and tree rows of one map, kept in `trees.json` beside the forest maps:
## read, check and write the file (stable bytes: one item a line, its keys in ORDER, defaults left out; every item is
## rounded to 0.01 as it comes in, so the editor and the file plant the same trees); the trees an item plants (a single
## tree at its point; a row at both ends and evenly between, each nudged from its seed); the map trees it clears; a
## block index. An item: {"id", "kind": "tree" | "row", "at": Vector2 | "points": PackedVector2Array, "type", "age",
## "species", "spacing_m" (a row), "clear_m", "source" (the import's key; absent on a hand-made one), "edited"}. No node
## and no editor type: scatter workers call only the static functions, over copies (near()).

## The trees file's schema.
const SCHEMA := "wuifwoud_trees/1"
## The trees file's name, in the maps' folder.
const FILE := "trees.json"
## The block index's block, in metres.
const BLOCK_M := 64.0
## A single tree's clearance (m) by default.
const TREE_CLEAR_M := 3.0
## A row's clearance (m) by default.
const ROW_CLEAR_M := 2.5
## A row's distance between trees (m) by default.
const SPACING_M := 8.0
## The least distance between a row's trees (m).
const MIN_SPACING_M := 1.0
## A row shorter than this is one tree at its first point.
const SHORT_ROW_M := 0.5
## A row's tree is nudged from its seed: along the row by up to this share of the gap each way, across it by up to
## NUDGE_ACROSS_M each way.
const NUDGE_ALONG := 0.1
## How far a row's tree is nudged across the row at most (m).
const NUDGE_ACROSS_M := 0.3
## An item's keys as the file writes them.
const ORDER := ["id", "kind", "at", "points", "type", "age", "species", "spacing_m", "clear_m", "source", "edited"]

## The file; "" for none (tests)
var path := ""
## Id -> item.
var items := {}
## The source keys of imported items the author deleted, sorted.
var removed: Array = []
## The id the next new item takes.
var next_id := 1
## Items dropped as malformed, named once each.
var errors: PackedStringArray = []
## The file read without dropping anything (no file: true). False: an item was malformed, or the file could not be read
## at all: save() refuses to write over it and the Place tools do not edit the set; what was dropped would be gone.
var whole := true
## Moves on every change (the editor's overlay draws again)
var revision := 0
## Changed since the file was read or written.
var dirty := false
## Moves when an import rewrote the file: Place steps from before it are refused.
var generation := 0
## () -> the scene this set is saved with (the editor: Save As moves it); unset: scene_path.
var scene_of := Callable()
## The scene the trees are saved with.
var scene_path := ""
static var _live: Array = []    # WeakRef of every configured or changed set: the scene save and an import reach them
var _index := {}                # Vector2i block -> PackedInt32Array: the ids whose extent reaches it


## Points this set at `p_path` and reads it (no file: no items). The set joins the live sets.
func configure(p_path: String) -> void:
	path = p_path
	errors.clear()
	dirty = false
	whole = true
	if path != "" and FileAccess.file_exists(path):
		load_file(path)
	else:
		set_state({})
	_register()


## Reads a trees file. False when it cannot be read as one (no items then); a malformed item is dropped and named in
## `errors`, the rest load.
func load_file(p: String) -> bool:
	var d = JSON.parse_string(FileAccess.get_file_as_string(p)) if FileAccess.file_exists(p) else null
	if typeof(d) != TYPE_DICTIONARY:
		errors.append("%s is not a JSON object: no single trees or rows" % p)
		set_state({})
		whole = false
		return false
	return parse(d, p)


## Read a trees document: false when an item was malformed (the rest are kept).
func parse(d: Dictionary, label := "trees") -> bool:
	set_state({})
	whole = true
	if str(d.get("schema", "")) != SCHEMA:
		errors.append("%s: schema must be '%s': no single trees or rows" % [label, SCHEMA])
		whole = false
		return false
	var list = d.get("items", [])
	if typeof(list) != TYPE_ARRAY:
		errors.append("%s: 'items' must be a list" % label)
		whole = false
		list = []
	for i in (list as Array).size():
		var it := normalise(list[i], i, errors)
		if it.is_empty():
			whole = false
			continue
		if items.has(it["id"]):
			errors.append("%s: item %d appears twice: the second is dropped" % [label, it["id"]])
			whole = false
			continue
		items[it["id"]] = it
	var rm = d.get("removed", [])
	if typeof(rm) == TYPE_ARRAY:
		for k in rm:
			if not removed.has(str(k)):
				removed.append(str(k))
	removed.sort()
	var top := 0
	for id in items:
		top = maxi(top, int(id))
	var nx = d.get("next_id", top + 1)
	next_id = int(nx) if _whole(nx) else top + 1
	if next_id <= top:
		errors.append("%s: next_id %d is not above every id: set to %d" % [label, next_id, top + 1])
		next_id = top + 1
	_reindex()
	return true


## The whole set as plain data: {"items": {id: item}, "removed": [...], "next_id": n} (copies).
func state() -> Dictionary:
	return {"items": items.duplicate(true), "removed": removed.duplicate(), "next_id": next_id}


## Takes a state (state()'s shape; {}: empty). Items come in rounded, as the file would hold them.
func set_state(s: Dictionary) -> void:
	items.clear()
	var its: Dictionary = s.get("items", {})
	for id in its:
		items[int(id)] = rounded((its[id] as Dictionary).duplicate(true))
	removed = (s.get("removed", []) as Array).duplicate()
	removed.sort()
	next_id = int(s.get("next_id", 1))
	_reindex()
	revision += 1


## Whether the set holds no item.
func is_empty() -> bool:
	return items.is_empty() and removed.is_empty()


## The file's text: schema, next_id, the items by id one a line (ORDER, defaults left out), removed.
func text() -> String:
	var ids := items.keys()
	ids.sort()
	var lines := PackedStringArray()
	for id in ids:
		lines.append("  " + JSON.stringify(written(items[id]), "", false))
	var body := ("\n" + ",\n".join(lines) + "\n ]") if not lines.is_empty() else "]"
	return "{\n \"schema\": %s,\n \"next_id\": %d,\n \"items\": [%s,\n \"removed\": %s\n}\n" % [
		JSON.stringify(SCHEMA), next_id, body, JSON.stringify(removed, "", false)]


## Writes the file; an empty set deletes it (no file: no items). ERR_FILE_CORRUPT, nothing written, when the set did not
## read its file whole: fix the file by hand, then read it again.
func save() -> Error:
	if path == "":
		return ERR_FILE_BAD_PATH
	if not whole:
		return ERR_FILE_CORRUPT
	if is_empty():
		if FileAccess.file_exists(path):
			var e := DirAccess.remove_absolute(ProjectSettings.globalize_path(path))
			if e != OK:
				return e
		dirty = false
		return OK
	DirAccess.make_dir_recursive_absolute(path.get_base_dir())
	var f := FileAccess.open(path, FileAccess.WRITE)
	if f == null:
		return FileAccess.get_open_error()
	f.store_string(text())
	f.close()
	dirty = false
	return OK


## Copies of the items whose extent reaches `rect`, by id (what a scatter job reads).
func near(rect: Rect2) -> Array:
	var out := []
	for id in _ids_near(rect):
		if rect.intersects(extent(items[id]), true):
			out.append((items[id] as Dictionary).duplicate(true))
	return out


## Every item's extent (the unbounded mode lists the cells under them).
func extents() -> Array:
	var out := []
	for id in items:
		out.append(extent(items[id]))
	return out


## The edit operations: a change is {"items": {id: item or null}, "removed": [...], "next_id": n}. The
## Place tools take a snapshot of the items a gesture touches before it, apply its state as it runs, and record both
## as one undo step.
func snapshot(ids: Array) -> Dictionary:
	var its := {}
	for id in ids:
		its[int(id)] = (items[int(id)] as Dictionary).duplicate(true) if items.has(int(id)) else null
	return {"items": its, "removed": removed.duplicate(), "next_id": next_id}


## Puts a change's state in: each item set (rounded) or, null, removed; `removed` and `next_id` as it says.
func apply(change: Dictionary) -> void:
	var its: Dictionary = change.get("items", {})
	for id in its:
		if its[id] == null:
			items.erase(int(id))
		else:
			items[int(id)] = rounded((its[id] as Dictionary).duplicate(true))
	removed = (change.get("removed", removed) as Array).duplicate()
	removed.sort()
	next_id = int(change.get("next_id", next_id))
	_changed()


## A new item, its id the next one: the id.
func add(it: Dictionary) -> int:
	var id := next_id
	var c := it.duplicate(true)
	c["id"] = id
	apply({"items": {id: c}, "removed": removed, "next_id": id + 1})
	return id


## The change that deletes `id`: an imported item's source joins `removed`, so a re-import does not bring it back.
func deletion(id: int) -> Dictionary:
	var rm := removed.duplicate()
	var it: Dictionary = items.get(id, {})
	if it.has("source") and not rm.has(it["source"]):
		rm.append(it["source"])
	rm.sort()
	return {"items": {id: null}, "removed": rm, "next_id": next_id}


## A copy of `it` as the author changed it: an imported item becomes theirs (`edited`), so a re-import keeps it.
static func touched(it: Dictionary) -> Dictionary:
	var c := it.duplicate(true)
	if c.has("source"):
		c["edited"] = true
	return c


## The single tree nearest `p` within `r` metres, or -1 (a tie: the lower id).
func pick_tree(p: Vector2, r: float) -> int:
	var best := -1
	var bd := r * r
	for id in _ids_near(Rect2(p - Vector2(r, r), Vector2(r, r) * 2.0)):
		var it: Dictionary = items[id]
		if it["kind"] != "tree":
			continue
		var d := p.distance_squared_to(it["at"])
		if d <= bd and (best < 0 or d < bd):
			bd = d
			best = id
	return best


## The row vertex nearest `p` within `r`: [id, index], or [].
func pick_vertex(p: Vector2, r: float) -> Array:
	var best := []
	var bd := r * r
	for id in _ids_near(Rect2(p - Vector2(r, r), Vector2(r, r) * 2.0)):
		var it: Dictionary = items[id]
		if it["kind"] != "row":
			continue
		var pts: PackedVector2Array = it["points"]
		for i in pts.size():
			var d := p.distance_squared_to(pts[i])
			if d <= bd and (best.is_empty() or d < bd):
				bd = d
				best = [id, i]
	return best


## The row line nearest `p` within `r`: [id, index of the segment's end point, the nearest point on it], or [].
func pick_line(p: Vector2, r: float) -> Array:
	var best := []
	var bd := r * r
	for id in _ids_near(Rect2(p - Vector2(r, r), Vector2(r, r) * 2.0)):
		var it: Dictionary = items[id]
		if it["kind"] != "row":
			continue
		var pts: PackedVector2Array = it["points"]
		for i in range(1, pts.size()):
			var ab := pts[i] - pts[i - 1]
			var l2 := ab.length_squared()
			var q := pts[i - 1] + ab * (0.0 if l2 <= 0.0 else clampf((p - pts[i - 1]).dot(ab) / l2, 0.0, 1.0))
			var d := p.distance_squared_to(q)
			if d <= bd and (best.is_empty() or d < bd):
				bd = d
				best = [id, i, q]
	return best


func _changed() -> void:
	_reindex()
	revision += 1
	dirty = true
	_register()


func _register() -> void:
	for w in _live.duplicate():
		var t = (w as WeakRef).get_ref()
		if t == null:
			_live.erase(w)
		elif t == self:
			return
	_live.append(weakref(self))


## Every live set whose file is in `dir` (written either way: a trailing slash, `.` and `..` folded).
static func live_for(dir: String) -> Array:
	var want := _norm(dir)
	var out := []
	for w in _live.duplicate():
		var t = (w as WeakRef).get_ref()
		if t == null:
			_live.erase(w)
		elif want != "" and String(t.path) != "" and _norm(String(t.path).get_base_dir()) == want:
			out.append(t)
	return out


## Every live set with unsaved changes, in any open scene tab (the scene save and the close prompt use it).
static func unsaved() -> Array:
	var out := []
	for w in _live.duplicate():
		var t = (w as WeakRef).get_ref()
		if t == null:
			_live.erase(w)
		elif t.dirty:
			out.append(t)
	return out


## Those of one scene ("": every scene, as when the editor quits).
static func unsaved_for(p_scene: String) -> Array:
	return unsaved().filter(func(t) -> bool: return p_scene == "" or t.scene() == p_scene)


## The scene this set is saved with: scene_of's answer now, else scene_path.
func scene() -> String:
	return String(scene_of.call()) if scene_of.is_valid() else scene_path


## A trees file rewritten by an import, or one the editor's unsaved trees were handed to (`trees_reload`:
## Overwrite may have dropped them though the file stayed): every live set reading `report.dir`'s file reads it again and
## moves `generation` on (its forest regrows; Place steps from before are refused). A run that left the file alone and
## was handed nothing reaches none. How many it reached.
static func imported(report: Dictionary) -> int:
	if not (str(report.get("trees_file", "")) in ["written", "deleted"]) and not bool(report.get("trees_reload", false)):
		return 0
	var ts := live_for(str(report.get("dir", "")))
	for t in ts:
		t.reload()
	return ts.size()


## The file read again after an import (its unsaved edits went into that import), `generation` on.
func reload() -> void:
	var g := generation
	configure(path)
	generation = g + 1


static func _norm(p: String) -> String:
	return p.simplify_path().trim_suffix("/") if p != "" else ""


## The ids indexed in the blocks under `rect`, sorted.
func _ids_near(rect: Rect2) -> Array:
	var ids := {}
	for bz in range(floori(rect.position.y / BLOCK_M), floori((rect.end.y - 0.001) / BLOCK_M) + 1):
		for bx in range(floori(rect.position.x / BLOCK_M), floori((rect.end.x - 0.001) / BLOCK_M) + 1):
			for id in _index.get(Vector2i(bx, bz), PackedInt32Array()):
				ids[id] = true
	var out := ids.keys()
	out.sort()
	return out


func _reindex() -> void:
	_index.clear()
	for id in items:
		var e := extent(items[id])
		for bz in range(floori(e.position.y / BLOCK_M), floori(e.end.y / BLOCK_M) + 1):
			for bx in range(floori(e.position.x / BLOCK_M), floori(e.end.x / BLOCK_M) + 1):
				var b := Vector2i(bx, bz)
				var arr: PackedInt32Array = _index.get(b, PackedInt32Array())
				arr.append(int(id))
				_index[b] = arr


## One item as read from a file (`at`: its place in the list, for the message): the item, rounded, or {} with why in
## `errs`.
static func normalise(e, at: int, errs: PackedStringArray) -> Dictionary:
	if typeof(e) != TYPE_DICTIONARY:
		errs.append("item %d is not an object: dropped" % at)
		return {}
	var d: Dictionary = e
	if not _whole(d.get("id")) or int(d["id"]) < 1:
		errs.append("item %d: id must be a whole number of 1 or more: dropped" % at)
		return {}
	var id := int(d["id"])
	var kind := str(d.get("kind", ""))
	var row := kind == "row"
	var out := {"id": id, "kind": kind}
	var why := ""
	if kind == "tree":
		var a = _xz(d.get("at"))
		if a == null:
			why = "'at' must be [x, z]"
		else:
			out["at"] = a
	elif row:
		var pts := PackedVector2Array()
		var raw = d.get("points")
		if typeof(raw) == TYPE_ARRAY:
			for c in raw:
				var v = _xz(c)
				if v != null:
					pts.append(v)
		if typeof(raw) != TYPE_ARRAY or pts.size() < 2 or pts.size() != (raw as Array).size():
			why = "'points' must be two or more [x, z]"
		else:
			out["points"] = pts
	else:
		why = "kind must be \"tree\" or \"row\""
	var ty = d.get("type")
	var age = d.get("age", 0.0)
	var sp = d.get("species", "")
	var spacing = d.get("spacing_m", SPACING_M)
	var clear = d.get("clear_m", ROW_CLEAR_M if row else TREE_CLEAR_M)
	var src = d.get("source")
	var ed = d.get("edited", false)
	if why != "":
		pass
	elif not _whole(ty) or int(ty) < 1 or int(ty) > 255:
		why = "type must be a whole number 1-255"
	elif not _num(age) or float(age) < -1.0 or float(age) > 1.0:
		why = "age must be -1..1"
	elif typeof(sp) != TYPE_STRING:
		why = "species must be text"
	elif row and (not _num(spacing) or float(spacing) < MIN_SPACING_M):
		why = "spacing_m must be 1 or more"
	elif not _num(clear) or float(clear) < 0.0:
		why = "clear_m must be 0 or more"
	elif src != null and typeof(src) != TYPE_STRING:
		why = "source must be text"
	elif typeof(ed) != TYPE_BOOL:
		why = "edited must be true or false"
	if why != "":
		errs.append("item %d: %s: dropped" % [id, why])
		return {}
	out["type"] = int(ty)
	out["age"] = float(age)
	out["species"] = str(sp)
	if row:
		out["spacing_m"] = float(spacing)
	out["clear_m"] = float(clear)
	if src != null and str(src) != "":
		out["source"] = str(src)
	out["edited"] = bool(ed) and out.has("source")
	return rounded(out)


## `it` as the file holds it (in place, and returned): coordinates, age, spacing and clearance to 0.01.
static func rounded(it: Dictionary) -> Dictionary:
	if it.has("at"):
		var a: Vector2 = it["at"]
		it["at"] = Vector2(_r(a.x), _r(a.y))
	if it.has("points"):
		var pts := PackedVector2Array()
		for p in (it["points"] as PackedVector2Array):
			pts.append(Vector2(_r(p.x), _r(p.y)))
		it["points"] = pts
	for k in ["age", "spacing_m", "clear_m"]:
		if it.has(k):
			it[k] = _r(float(it[k]))
	return it


## An item as the file writes it: keys in ORDER, a default left out (age 0, no species, not edited).
static func written(it: Dictionary) -> Dictionary:
	var row: bool = it["kind"] == "row"
	var out := {"id": it["id"], "kind": it["kind"]}
	if row:
		var pts := []
		for p in (it["points"] as PackedVector2Array):
			pts.append([_r(p.x), _r(p.y)])
		out["points"] = pts
	else:
		var a: Vector2 = it["at"]
		out["at"] = [_r(a.x), _r(a.y)]
	out["type"] = it["type"]
	if _r(float(it.get("age", 0.0))) != 0.0:
		out["age"] = _r(float(it["age"]))
	if str(it.get("species", "")) != "":
		out["species"] = str(it["species"])
	if row:
		out["spacing_m"] = _r(float(it["spacing_m"]))
	out["clear_m"] = _r(float(it["clear_m"]))
	if it.has("source"):
		out["source"] = it["source"]
	if bool(it.get("edited", false)):
		out["edited"] = true
	return out


## The trees `it` plants: [{"p": Vector2 (nudged), "base": Vector2 (un-nudged: the cell it belongs
## to), "k": index along the row, "seed": int}]. A single tree stands at `at`; a row has trees at both ends and n − 1
## between, n = max(1, round(L / spacing)); a row shorter than SHORT_ROW_M is one tree at its first point. A row's tree
## is nudged along it by up to NUDGE_ALONG of the gap and across it by up to NUDGE_ACROSS_M, from its seed. Pure.
static func planted(it: Dictionary, forest_seed: int) -> Array:
	var id: int = it["id"]
	var ty: int = it["type"]
	if it["kind"] == "tree":
		return [{"p": it["at"], "base": it["at"], "k": 0, "seed": hash(Vector4i(id, 0, ty, forest_seed))}]
	var pts: PackedVector2Array = it["points"]
	var total := 0.0
	for i in range(1, pts.size()):
		total += pts[i - 1].distance_to(pts[i])
	if total < SHORT_ROW_M:
		return [{"p": pts[0], "base": pts[0], "k": 0, "seed": hash(Vector4i(id, 0, ty, forest_seed))}]
	var n := maxi(1, roundi(total / float(it["spacing_m"])))
	var gap := total / float(n)
	var out := []
	var seg := 1
	var seg_start := 0.0
	for k in n + 1:
		var s := gap * float(k) if k < n else total
		while seg < pts.size() - 1 and seg_start + pts[seg - 1].distance_to(pts[seg]) < s:
			seg_start += pts[seg - 1].distance_to(pts[seg])
			seg += 1
		var a := pts[seg - 1]
		var b := pts[seg]
		var sl := a.distance_to(b)
		var dir := (b - a) / sl if sl > 0.0 else Vector2.RIGHT
		var base := a + dir * clampf(s - seg_start, 0.0, sl)
		var sd: int = hash(Vector4i(id, k, ty, forest_seed))
		var along := (_rand01(sd * 3 + 1) - 0.5) * 2.0 * NUDGE_ALONG * gap
		var across := (_rand01(sd * 7 + 2) - 0.5) * 2.0 * NUDGE_ACROSS_M
		out.append({"p": base + dir * along + Vector2(-dir.y, dir.x) * across, "base": base, "k": k, "seed": sd})
	return out


## The trees `near`'s items plant whose base lies in `rect` (half-open, as a ring cell is): planted() dicts with
## "item", the item they belong to. Pure: workers call it.
static func trees_in(near: Array, rect: Rect2, forest_seed: int) -> Array:
	var out := []
	for it in near:
		for t in planted(it, forest_seed):
			var b: Vector2 = t["base"]
			if b.x >= rect.position.x and b.y >= rect.position.y and b.x < rect.end.x and b.y < rect.end.y:
				t["item"] = it
				out.append(t)
	return out


## A map point at `p` falls within an item's clearance: within clear_m of a single tree's point or of
## a row's polyline. Pure: workers call it over near()'s copies.
static func cleared(near: Array, p: Vector2) -> bool:
	for it in near:
		var r := float(it["clear_m"])
		if r <= 0.0:
			continue
		if it["kind"] == "tree":
			if p.distance_squared_to(it["at"]) < r * r:
				return true
			continue
		var pts: PackedVector2Array = it["points"]
		for i in range(1, pts.size()):
			if seg_dist2(p, pts[i - 1], pts[i]) < r * r:
				return true
	return false


## The rectangle an item reaches: its points (where its trees belong) grown by its clearance.
static func extent(it: Dictionary) -> Rect2:
	var box: Rect2
	if it["kind"] == "tree":
		box = Rect2(it["at"], Vector2.ZERO)
	else:
		var pts: PackedVector2Array = it["points"]
		box = Rect2(pts[0], Vector2.ZERO)
		for p in pts:
			box = box.expand(p)
	return box.grow(maxf(float(it["clear_m"]), 0.0) + 0.01)


## The squared distance from `p` to the segment a-b.
static func seg_dist2(p: Vector2, a: Vector2, b: Vector2) -> float:
	var ab := b - a
	var l2 := ab.length_squared()
	var t := 0.0 if l2 <= 0.0 else clampf((p - a).dot(ab) / l2, 0.0, 1.0)
	return p.distance_squared_to(a + ab * t)


## The forest's deterministic 0..1 from an int: the spawner's formula (a preload of the spawner here would be
## cyclic); the native core ports it.
static func _rand01(s: int) -> float:
	var x := s
	x = (x ^ (x >> 16)) * 0x45d9f3b
	x = (x ^ (x >> 16)) * 0x45d9f3b
	x = x ^ (x >> 16)
	return float(x & 0xFFFFFF) / float(0x1000000)


static func _r(v: float) -> float:
	return snappedf(v, 0.01)


static func _num(v) -> bool:
	return typeof(v) in [TYPE_INT, TYPE_FLOAT]


static func _whole(v) -> bool:
	return _num(v) and float(int(v)) == float(v)


static func _xz(c) -> Variant:
	if typeof(c) == TYPE_ARRAY and (c as Array).size() == 2 and _num(c[0]) and _num(c[1]):
		return Vector2(float(c[0]), float(c[1]))
	return null
