# Copyright (c) 2026 Digitzone
# SPDX-License-Identifier: MIT
@tool
extends RefCounted
## The Forest workspace's Place tools: Tree places, moves and deletes single trees; Row draws
## rows and edits their vertices. They work on the edited scene's forest's items (ForestTrees) through the paint
## provider, which routes its two Place tools' strokes, hover, panel and cursor note here. Every gesture is one undo
## step in that scene's history; an imported item a gesture changes becomes the author's (`edited`), one it deletes is
## remembered (`removed`); nothing changes while an import runs, and a step from before an import is not undone. The
## cells under an edit grow again every REGROW_EVERY_MS during a drag and at its end.

## The single trees and rows.
const ForestTreesRes := preload("res://addons/wuifwoud/forest_trees.gd")
## The forest's log, through its sink.
const ForestLogRes := preload("res://addons/wuifwoud/forest_log.gd")
## The terrain adapter.
const ForestTerrainRes := preload("res://addons/wuifwoud/forest_terrain.gd")
## The overlay.
const OverlayRes := preload("res://addons/wuifwoud/editor/forest_place_overlay.gd")
## Errors.
const ERROR := Color("ff8a80")
## The Tree tool's id.
const TREE := "forest.tree"
## The Row tool's id.
const ROW := "forest.row"
## A press picks the nearest handle within this many screen pixels.
const PICK_PX := 12.0
## A drawn row: a sample every SAMPLE_M, simplified to SIMPLIFY_M; a path shorter than MIN_ROW_M is a click.
const SAMPLE_M := 0.5
## A drawn row is simplified to this (m).
const SIMPLIFY_M := 0.5
## A shorter row is one tree (m).
const MIN_ROW_M := 1.0
## The touched cells grow again at most this often during a drag (ms).
const REGROW_EVERY_MS := 250
## A cursor note older than this (ms) is dropped.
const STALE_NOTE_MS := 4000
## The note when no type is selected.
const NO_TYPE := "pick a forest type in the library first"
## The note when trees.json did not read whole.
const NOT_WHOLE := "trees.json did not read whole: fix it by hand (the Output names what was dropped), then reopen the scene"

## What new items take.
var age := 0.0
## The species new items pin ("": the type picks).
var species := ""
## A new single tree's clearance (m).
var tree_clear := ForestTreesRes.TREE_CLEAR_M
## A new row's clearance (m).
var row_clear := ForestTreesRes.ROW_CLEAR_M
## A new row's spacing (m).
var spacing := ForestTreesRes.SPACING_M
## The selected item's id.
var selected := -1
## The item under the cursor.
var hover := -1
## (distance m) -> metres a screen pixel spans there; unset: the forest's camera.
var px_m := Callable()
## () -> Shift is held; unset: the keyboard.
var shift_held := Callable()
var _provider_ref: WeakRef = null
var _from := Vector3.INF             # the view ray's origin at the last hover
var _hit := Vector3.INF              # where it landed
var _g := {}                         # the gesture in progress
var _last_send_ms := 0
var _stale_until := 0
var _note := ""                      # a one-off note (a gesture refused, Revert's outcome), until the hover moves
var _box: VBoxContainer = null       # the panel's contents (the tools refill it)
var _kit: Object = null
var _accent := Color.WHITE
var _tool := TREE
var _overlay = null                  # ForestPlaceOverlay
var _drawn := []                     # what the overlay last drew: [revision, selected, hover, generation]
var _seen: WeakRef = null            # the forest the selection, the hover, a gesture and the overlay belong to


## The paint provider these tools serve (held weakly: it holds them).
func bind(p: Object) -> void:
	_provider_ref = weakref(p)


func _pv() -> Object:
	return _provider_ref.get_ref() if _provider_ref != null else null


## The edited scene's forest. When it is another than last time (another scene tab, a scene closed), what belonged to
## the old one goes first (_forest_changed).
func _forest() -> Node:
	var p := _pv()
	var f: Node = p._forest() if p != null else null
	var was = _seen.get_ref() if _seen != null else null
	if f != was:
		_seen = weakref(f) if f != null else null
		_forest_changed()
	return f


## The selection, the hover, a gesture and the note were the old forest's: they reset, and its overlay is freed (it
## would stay drawn in that scene); the panel follows.
func _forest_changed() -> void:
	selected = -1
	hover = -1
	_g = {}
	_note = ""
	_drawn = []
	if _overlay != null and is_instance_valid(_overlay):
		var par: Node = _overlay.get_parent()
		if par != null:
			par.remove_child(_overlay)
		_overlay.queue_free()
	_overlay = null
	refresh()


## Whether the forest's items may be edited: not when their file did not read whole (a save would lose what was
## dropped; ForestTrees.save refuses it too), said in the note.
func _editable(f: Node) -> bool:
	if f.trees.whole:
		return true
	_note = NOT_WHOLE
	return false


func _importing() -> bool:
	var p := _pv()
	return p != null and not (p._import_progress() as Dictionary).is_empty()


func _type() -> int:
	var p := _pv()
	return int(p.selected) if p != null else 0


func _shift() -> bool:
	return bool(shift_held.call()) if shift_held.is_valid() else Input.is_key_pressed(KEY_SHIFT)


func _select(id: int) -> void:
	selected = id
	refresh()


# ── gestures (the provider's strokes, API v3) ──

## A stroke begins: what the press is on decides the gesture. Nothing while an import runs.
func begin(p_tool: String, p_hit: Vector3, p_brush: Dictionary) -> void:
	_g = {}
	var f := _forest()
	if f == null or not f.maps.configured() or _importing() or not _editable(f):
		return
	var t = f.trees
	var p := Vector2(p_hit.x, p_hit.z)
	var r := pick_radius(p_hit)
	var ctrl := bool(p_brush.get("invert", false))
	if p_tool == TREE:
		var id: int = t.pick_tree(p, r)
		if ctrl:
			if id >= 0:
				_commit(f, "Forest: Delete tree", t.snapshot([id]), t.deletion(id))
			return
		if id >= 0:
			_select(id)
			_g = {"f": f, "mode": "move", "id": id, "before": t.snapshot([id]), "start": p, "moved": false}
			return
		if _type() <= 0:
			_note = NO_TYPE
			return
		var before: Dictionary = t.snapshot([t.next_id])
		var nid: int = t.add({"kind": "tree", "at": p, "type": _type(), "age": age, "species": species,
			"clear_m": tree_clear, "edited": false})
		_select(nid)
		_g = {"f": f, "mode": "place", "id": nid, "before": before, "start": p, "moved": true}
		_send(true)
		return
	var v: Array = t.pick_vertex(p, r)
	var l: Array = t.pick_line(p, r) if v.is_empty() else []
	var hit_id: int = int(v[0]) if not v.is_empty() else (int(l[0]) if not l.is_empty() else -1)
	if ctrl:
		if not v.is_empty():
			_commit(f, "Forest: Delete vertex", t.snapshot([hit_id]), _without_vertex(t, hit_id, int(v[1])))
		elif hit_id >= 0:
			_commit(f, "Forest: Delete row", t.snapshot([hit_id]), t.deletion(hit_id))
		return
	if hit_id >= 0:
		_select(hit_id)
		var mode := "shift" if _shift() else ("vertex" if not v.is_empty() else "line")
		_g = {"f": f, "mode": mode, "id": hit_id, "before": t.snapshot([hit_id]), "start": p, "moved": false,
			"vi": int(v[1]) if not v.is_empty() else -1, "seg": int(l[1]) if not l.is_empty() else -1,
			"points": (t.items[hit_id]["points"] as PackedVector2Array).duplicate(), "inserted": false}
		return
	_select(-1)
	if _type() <= 0:
		_note = NO_TYPE
		return
	_g = {"f": f, "mode": "draw", "path": PackedVector2Array([p])}


## The stroke moves: the gesture follows; the cells under the change grow again at most every REGROW_EVERY_MS. A press
## on an item moves it only once the cursor has left half the pick radius (a click selects).
func drag(p_hit: Vector3) -> void:
	if _g.is_empty():
		return
	var f: Node = _g["f"]
	if not is_instance_valid(f):
		_g = {}
		return
	var t = f.trees
	var p := Vector2(p_hit.x, p_hit.z)
	var mode := String(_g["mode"])
	if mode == "draw":
		var path: PackedVector2Array = _g["path"]
		if p.distance_to(path[path.size() - 1]) >= SAMPLE_M:
			path.append(p)
			_g["path"] = path
		return
	if not bool(_g["moved"]) and p.distance_to(_g["start"]) < pick_radius(p_hit) * 0.5:
		return
	var it: Dictionary = ForestTreesRes.touched(t.items[_g["id"]])
	if mode == "place":
		it = (t.items[_g["id"]] as Dictionary).duplicate(true)
	if mode == "move" or mode == "place":
		it["at"] = p
	else:
		var pts: PackedVector2Array = (_g["points"] as PackedVector2Array).duplicate()
		if mode == "line":
			pts.insert(int(_g["seg"]), p)
			_g["mode"] = "vertex"
			_g["vi"] = int(_g["seg"])
			_g["points"] = pts
			_g["inserted"] = true
		elif mode == "vertex":
			pts[int(_g["vi"])] = p
			_g["points"] = pts
		else:
			var d := p - (_g["start"] as Vector2)
			for i in pts.size():
				pts[i] += d
		it["points"] = pts
	t.apply({"items": {int(_g["id"]): it}, "removed": t.removed, "next_id": t.next_id})
	_g["moved"] = true
	_send(false)


## The stroke ends: one undo step for what it did (a click on an item only selects it).
func end() -> void:
	if _g.is_empty():
		return
	var g := _g
	_g = {}
	var f: Node = g["f"]
	if not is_instance_valid(f):
		return
	var t = f.trees
	var mode := String(g["mode"])
	if mode == "draw":
		var pts := simplify(g["path"], SIMPLIFY_M)
		if _length(pts) < MIN_ROW_M:
			return
		var before: Dictionary = t.snapshot([t.next_id])
		var nid: int = t.add({"kind": "row", "points": pts, "type": _type(), "age": age, "species": species,
			"spacing_m": spacing, "clear_m": row_clear, "edited": false})
		_select(nid)
		var after: Dictionary = t.snapshot([nid])
		_record(f, "Forest: Draw row", before, after)
		_regrow(f, before, after, true)
		return
	if not bool(g["moved"]):
		return
	var id: int = g["id"]
	var after2: Dictionary = t.snapshot([id])
	var label := "Forest: Place tree"
	match mode:
		"move":
			label = "Forest: Move tree"
		"vertex":
			label = "Forest: Add vertex" if bool(g.get("inserted", false)) else "Forest: Move vertex"
		"shift":
			label = "Forest: Move row"
	_record(f, label, g["before"], after2)
	_regrow(f, g["before"], after2, true)


## The change that deletes vertex `vi` of row `id`: the row without it, or the row itself when fewer than 2 would stay.
func _without_vertex(t, id: int, vi: int) -> Dictionary:
	var pts: PackedVector2Array = (t.items[id]["points"] as PackedVector2Array).duplicate()
	if pts.size() <= 2:
		return t.deletion(id)
	pts.remove_at(vi)
	var it: Dictionary = ForestTreesRes.touched(t.items[id])
	it["points"] = pts
	return {"items": {id: it}, "removed": (t.removed as Array).duplicate(), "next_id": t.next_id}


# ── undo, regrowth ──

## A change made at once (a delete, a panel edit, Revert, Restore): applied, one undo step, the cells regrown.
func _commit(f: Node, label: String, before: Dictionary, after: Dictionary) -> void:
	f.trees.apply(after)
	if not f.trees.items.has(selected):
		_select(-1)
	_record(f, label, before, after)
	_regrow(f, before, after, true)
	refresh()


## One undo step in the forest's scene (the change is already made): the items before and after it.
func _record(f: Node, label: String, before: Dictionary, after: Dictionary) -> void:
	var p := _pv()
	var ur: Object = p._undo if p != null else null
	if ur == null:
		return
	var gen: int = f.trees.generation
	ur.create_action(label, UndoRedo.MERGE_DISABLE, f)
	ur.add_do_method(self, &"_apply", f, gen, after)
	ur.add_undo_method(self, &"_apply", f, gen, before)
	ur.commit_action(false)


## Undo and redo of a Place step: the items as they were (or are again), then the cells under them grow again. Not while
## an import runs (its copy of the items would bring the change back), nor across one: said.
func _apply(f: Node, gen: int, change: Dictionary) -> void:
	if not is_instance_valid(f):
		return
	if _importing():
		ForestLogRes.warn("[Wuifwoud] a Place step is not undone or redone while an import runs: the import copied the trees with it")
		return
	if int(f.trees.generation) != gen:
		if Time.get_ticks_msec() >= _stale_until:
			ForestLogRes.warn("[Wuifwoud] a Place step from before the last import is not undone or redone: it would put the old import back")
		_stale_until = Time.get_ticks_msec() + STALE_NOTE_MS
		return
	var was: Dictionary = f.trees.snapshot((change.get("items", {}) as Dictionary).keys())
	f.trees.apply(change)
	if not f.trees.items.has(selected):
		_select(-1)
	_regrow(f, was, change, true)
	refresh()


## The cells under the items of two changes (where they were and where they are) grow again: the mesh chunks, and the
## card cells when `cards`.
func _regrow(f: Node, a: Dictionary, b: Dictionary, cards: bool) -> void:
	var rect := Rect2()
	var any := false
	for ch in [a, b]:
		var its: Dictionary = ch.get("items", {})
		for id in its:
			if its[id] == null:
				continue
			var e := ForestTreesRes.extent(its[id])
			rect = rect.merge(e) if any else e
			any = true
	if any:
		f.regrow(rect, true, cards)


## During a drag: the mesh chunks under the gesture's item grow again, at most every REGROW_EVERY_MS (`force`: now).
func _send(force: bool) -> void:
	var now := Time.get_ticks_msec()
	if not force and now - _last_send_ms < REGROW_EVERY_MS:
		return
	_last_send_ms = now
	var f: Node = _g.get("f")
	if f == null or not is_instance_valid(f) or not _g.has("id"):
		return
	_regrow(f, _g.get("before", {}), f.trees.snapshot([_g["id"]]), false)


# ── hover, the note, picking ──

## The view ray landed at `p_hit` from `p_from` (the provider's project_hit, on every mouse event): the item under the
## cursor is the hover.
func hover_at(p_tool: String, p_from: Vector3, p_hit: Vector3) -> void:
	_from = p_from
	_hit = p_hit
	var f := _forest()
	var h := -1
	if f != null:
		var p := Vector2(p_hit.x, p_hit.z)
		var r := pick_radius(p_hit)
		if p_tool == TREE:
			h = f.trees.pick_tree(p, r)
		else:
			var v: Array = f.trees.pick_vertex(p, r)
			var l: Array = v if not v.is_empty() else f.trees.pick_line(p, r)
			h = int(l[0]) if not l.is_empty() else -1
	if h != hover:
		hover = h
		_note = ""


## The cursor note: busy, refused, the item under the cursor, why a tree would not grow there, or what
## a click does.
func note(p_tool: String) -> String:
	var f := _forest()
	if f == null:
		return "no forest in this scene"
	var p := _pv()
	var prog: Dictionary = p._import_progress() if p != null else {}
	if not prog.is_empty():
		return "importing %d/%d" % [int(prog.get("done", 0)), int(prog.get("total", 0))]
	if not f.maps.configured():
		return "the forest's maps are not ready"
	if not f.trees.whole:
		return NOT_WHOLE
	if Time.get_ticks_msec() < _stale_until:
		return "placed before the import: not undone"
	if _note != "":
		return _note
	if hover >= 0 and f.trees.items.has(hover):
		return describe(f.trees.items[hover])
	if not _hit.is_finite():
		return ""
	var why: String = f.item_gate(Vector2(_hit.x, _hit.z))
	if why != "":
		return why + ": won't grow"
	if _type() <= 0:
		return NO_TYPE
	return "click: a tree" if p_tool == TREE else "drag: a row"


## "row 12 (imported)", "row 12 (imported, edited)", "tree 57 (hand-made)".
static func describe(it: Dictionary) -> String:
	var who := "hand-made"
	if it.has("source"):
		who = "imported, edited" if bool(it.get("edited", false)) else "imported"
	return "%s %d (%s)" % [it["kind"], int(it["id"]), who]


## The pick radius at `p_hit`: PICK_PX screen pixels at its distance from the view (the last hover's ray origin; 50 m
## before any hover), at least 0.25 m.
func pick_radius(p_hit: Vector3) -> float:
	var d := _from.distance_to(p_hit) if _from.is_finite() else 50.0
	var per := float(px_m.call(d)) if px_m.is_valid() else _cam_px_m(d)
	return maxf(0.25, PICK_PX * per)


## Metres a screen pixel spans at `d` through the forest's camera (the editor's view); without one, 0.1 % of `d`.
func _cam_px_m(d: float) -> float:
	var f := _forest()
	var cam: Camera3D = f._camera() if f != null else null
	if cam == null or not cam.is_inside_tree():
		return d * 0.001
	var h := maxf(cam.get_viewport().get_visible_rect().size.y, 1.0)
	return 2.0 * d * tan(deg_to_rad(cam.fov) * 0.5) / h


# ── Revert and Restore ──

## The import's version of each source key (the reader's read of the scene's mapping): {"items": {key: item}}, or
## {"why": …} while there is none yet.
func _imported() -> Dictionary:
	var p := _pv()
	if p == null:
		return {"why": "no forest in this scene"}
	var m: Dictionary = p._mapping()
	if m.is_empty() or p.reader == null:
		return {"why": "no mapping for this scene: Import… first"}
	p.reader.request(m)
	if not p.reader.poll():
		return {"why": "reading the source…"}
	return {"items": p.reader.rules.get("items", {})}


## Revert to import: the selected edited imported item takes the import's current version of its key (its id kept,
## not edited). One undo step.
func revert_selected() -> void:
	var f := _forest()
	if f == null or not f.trees.items.has(selected) or _importing() or not _editable(f):
		return
	var it: Dictionary = f.trees.items[selected]
	if not it.has("source"):
		return
	var got := _imported()
	if got.has("why"):
		_note = String(got["why"])
		return
	var src = (got["items"] as Dictionary).get(it["source"])
	if src == null:
		_note = "the source no longer has %s" % it["source"]
		return
	var back: Dictionary = (src as Dictionary).duplicate(true)
	back["id"] = selected
	back["edited"] = false
	_commit(f, "Forest: Revert to import", f.trees.snapshot([selected]),
		{"items": {selected: back}, "removed": (f.trees.removed as Array).duplicate(), "next_id": f.trees.next_id})
	_note = ""


## Restore deleted imports (the panel's ⋯): every removed key the import still writes comes back with a new id;
## `removed` is emptied. One undo step.
func restore_removed() -> void:
	var f := _forest()
	if f == null or _importing() or not _editable(f):
		return
	if (f.trees.removed as Array).is_empty():
		_note = "no deleted imports to restore"
		return
	var got := _imported()
	if got.has("why"):
		_note = String(got["why"])
		return
	var its := {}
	var ids := []
	var nid: int = f.trees.next_id
	for k in f.trees.removed:
		var src = (got["items"] as Dictionary).get(k)
		if src == null:
			continue
		var back: Dictionary = (src as Dictionary).duplicate(true)
		back["id"] = nid
		back["edited"] = false
		its[nid] = back
		ids.append(nid)
		nid += 1
	_commit(f, "Forest: Restore deleted imports", f.trees.snapshot(ids), {"items": its, "removed": [], "next_id": nid})
	_note = "%d restored" % ids.size()


# ── pure helpers ──

## A drawn path simplified (Douglas-Peucker, `tol` metres): its ends kept, every point nearer than `tol` to the line
## between its kept neighbours dropped. Pure.
static func simplify(path: PackedVector2Array, tol: float) -> PackedVector2Array:
	if path.size() <= 2:
		return path.duplicate()
	var keep := PackedByteArray()
	keep.resize(path.size())
	keep.fill(0)
	keep[0] = 1
	keep[path.size() - 1] = 1
	var stack := [[0, path.size() - 1]]
	while not stack.is_empty():
		var span: Array = stack.pop_back()
		var a: int = span[0]
		var b: int = span[1]
		var worst := -1
		var wd := tol * tol
		for i in range(a + 1, b):
			var d := ForestTreesRes.seg_dist2(path[i], path[a], path[b])
			if d > wd:
				wd = d
				worst = i
		if worst >= 0:
			keep[worst] = 1
			stack.append([a, worst])
			stack.append([worst, b])
	var out := PackedVector2Array()
	for i in path.size():
		if keep[i] == 1:
			out.append(path[i])
	return out


static func _length(pts: PackedVector2Array) -> float:
	var n := 0.0
	for i in range(1, pts.size()):
		n += pts[i - 1].distance_to(pts[i])
	return n


# ── the panel ──

## The provider's build_settings for a Place tool: the selected item (who owns it, its type, species, age, spacing
## (a row) and clearance, Revert to import, Delete) and the settings new items take. The tools refill it on a change (a
## selection, an undo, an import's catch-up): the overlay builds a tool's settings only when the tool is activated.
func build_panel(box: VBoxContainer, p_tool: String, kit: Object, accent: Color) -> void:
	_kit = kit
	_accent = accent
	_tool = p_tool
	_box = VBoxContainer.new()
	_box.name = "PlacePanel"
	_box.add_theme_constant_override("separation", 6)
	box.add_child(_box)
	refresh()


## The panel's contents built again from the items as they are now.
func refresh() -> void:
	if _box == null or not is_instance_valid(_box) or _kit == null:
		return
	for c in _box.get_children():
		_box.remove_child(c)
		c.queue_free()
	var f := _forest()
	if f != null and f.trees.items.has(selected):
		_selected_section(f, f.trees.items[selected])
	_new_section(f)


func _selected_section(f: Node, it: Dictionary) -> void:
	_box.add_child(_kit.section("Selected"))
	var who: Label = _kit.description(describe(it))
	who.name = "Owner"
	_box.add_child(who)
	var types := HFlowContainer.new()
	types.name = "Types"
	var tg := ButtonGroup.new()
	var ids: Array = Array(f._types.ids())
	ids.sort()
	for id in ids:
		var b: Button = _kit.toggle_chip(String((f._types.get_type(id) as Dictionary).get("name", "type %d" % id)),
			int(it["type"]) == int(id), _accent)
		b.name = "Type%d" % id
		b.button_group = tg
		var to := int(id)
		b.pressed.connect(func() -> void: _edit("type", to))
		types.add_child(b)
	_box.add_child(types)
	_box.add_child(_species_chips(f, str(it.get("species", "")), "", func(sp: String) -> void: _edit("species", sp)))
	_box.add_child(_slider("Age", -1.0, 1.0, 0.05, float(it["age"]), "", func(v: float) -> void: _edit("age", v), true))
	if it["kind"] == "row":
		_box.add_child(_slider("Spacing", ForestTreesRes.MIN_SPACING_M, 50.0, 0.5, float(it["spacing_m"]), "m",
			func(v: float) -> void: _edit("spacing_m", v), true))
	_box.add_child(_slider("Clearance", 0.0, 20.0, 0.5, float(it["clear_m"]), "m",
		func(v: float) -> void: _edit("clear_m", v), true))
	var acts := HBoxContainer.new()
	if it.has("source") and bool(it.get("edited", false)):
		var rv: Button = _kit.chip("Revert to import", false, _accent)
		rv.name = "RevertItem"
		rv.pressed.connect(revert_selected)
		acts.add_child(rv)
	var del: Button = _kit.chip("Delete", false, ERROR)
	del.name = "DeleteItem"
	del.pressed.connect(delete_selected)
	acts.add_child(del)
	_box.add_child(acts)


func _new_section(f: Node) -> void:
	_box.add_child(_kit.section("New items"))
	if f != null:
		_box.add_child(_species_chips(f, species, "New", func(sp: String) -> void: species = sp))
	_box.add_child(_slider("NewAge", -1.0, 1.0, 0.05, age, "", func(v: float) -> void: age = v, false, "Age"))
	if _tool == ROW:
		_box.add_child(_slider("NewSpacing", ForestTreesRes.MIN_SPACING_M, 50.0, 0.5, spacing, "m",
			func(v: float) -> void: spacing = v, false, "Spacing"))
		_box.add_child(_slider("NewClearance", 0.0, 20.0, 0.5, row_clear, "m",
			func(v: float) -> void: row_clear = v, false, "Clearance"))
	else:
		_box.add_child(_slider("NewClearance", 0.0, 20.0, 0.5, tree_clear, "m",
			func(v: float) -> void: tree_clear = v, false, "Clearance"))


## By type, or one of the profile's species (named `prefix` + "Species…").
func _species_chips(f: Node, current: String, prefix: String, on_pick: Callable) -> Control:
	var flow := HFlowContainer.new()
	flow.name = prefix + "Species"
	var g := ButtonGroup.new()
	var by: Button = _kit.toggle_chip("By type", current == "", _accent)
	by.name = prefix + "SpeciesBy"
	by.button_group = g
	by.pressed.connect(func() -> void: on_pick.call(""))
	flow.add_child(by)
	for nm in f.species_names():
		var b: Button = _kit.toggle_chip(String(nm), String(nm) == current, _accent)
		b.name = prefix + "Species_" + String(nm).validate_node_name()
		b.button_group = g
		var at := String(nm)
		b.pressed.connect(func() -> void: on_pick.call(at))
		flow.add_child(b)
	return flow


## A slider row named `nm`: `on_value` gets its value when let go (`on_release`: one undo step) or as it moves.
func _slider(nm: String, lo: float, hi: float, step: float, value: float, suffix: String, on_value: Callable,
		on_release: bool, label := "") -> Control:
	var row: VBoxContainer = _kit.slider_row(label if label != "" else nm, lo, hi, step, value, suffix, _accent)
	row.name = nm
	var s := row.get_node("Slider") as HSlider
	if on_release:
		s.drag_ended.connect(func(changed: bool) -> void:
			if changed:
				on_value.call(s.value))
	else:
		s.value_changed.connect(func(v: float) -> void: on_value.call(v))
	return row


## A field of the selected item changed in the panel: one undo step; an imported item becomes the author's.
func _edit(field: String, value) -> void:
	var f := _forest()
	if f == null or not f.trees.items.has(selected) or _importing() or not _editable(f):
		return
	var it: Dictionary = ForestTreesRes.touched(f.trees.items[selected])
	if typeof(it.get(field)) == typeof(value) and it.get(field) == value:
		return
	it[field] = value
	_commit(f, "Forest: Change %s" % field.trim_suffix("_m"), f.trees.snapshot([selected]),
		{"items": {selected: it}, "removed": (f.trees.removed as Array).duplicate(), "next_id": f.trees.next_id})


## The panel's Delete: the selected item, one undo step (an imported one is remembered).
func delete_selected() -> void:
	var f := _forest()
	if f == null or not f.trees.items.has(selected) or _importing() or not _editable(f):
		return
	_commit(f, "Forest: Delete %s" % str(f.trees.items[selected]["kind"]), f.trees.snapshot([selected]),
		f.trees.deletion(selected))


# ── the overlay ──

## The plugin's frame (through the provider): the overlay shows while a Place tool is the overlay's active tool (`on`)
## and draws again when the items, the selection, the hover or an import's catch-up changed.
func tick(on: bool) -> void:
	var f := _forest()
	if f == null or not on:
		if _overlay != null and is_instance_valid(_overlay):
			_overlay.visible = false
		return
	if _overlay == null or not is_instance_valid(_overlay) or _overlay.get_parent() != f:
		_overlay = OverlayRes.new()
		f.add_child(_overlay, false, Node.INTERNAL_MODE_BACK)
		_drawn = []
	_overlay.visible = true
	var want := [f.trees.revision, selected, hover, f.trees.generation]
	if want != _drawn:
		_drawn = want
		_overlay.draw(f.trees.items, selected, hover, _height_of(f))


## The ground's height under (x, z) from the forest's terrain (0 where unknown).
func _height_of(f: Node) -> Callable:
	var t: Node = f.terrain_source if f.terrain_source != null else ForestTerrainRes.find_cached(f)
	var data = t.get("data") if t != null else null
	if data == null or not data.has_method("get_height"):
		return func(_x: float, _z: float) -> float: return 0.0
	return func(x: float, z: float) -> float:
		var h: float = data.get_height(Vector3(x, 0.0, z))
		return 0.0 if is_nan(h) else h
