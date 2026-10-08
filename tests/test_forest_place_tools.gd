# Copyright (c) 2026 Digitzone
# SPDX-License-Identifier: MIT
extends RefCounted
## The Forest workspace's Place tools: Tree and Row join the tools; Tree places a tree of the
## library's type with the tools' settings (one undo step, undone and redone), moves one, selects one with a click,
## deletes one with Ctrl; Row draws a row (a click draws none), moves a vertex, adds one on the line, moves the whole row
## with Shift, deletes a vertex and then the row with Ctrl; an imported row changed becomes the author's and one deleted
## is remembered; nothing while an import runs, no undo across one; Revert to import and Restore deleted imports
## through the reader; the cells under an edit grow again; the cursor note; the pick radius. The panel (the selected
## item, its fields one step each, refilled; the new items' settings in a preset); the overlay (an internal, unowned
## child, drawn again only on a change, hidden for a paint tool or another workspace). The forest finder
## walks a scene without a forest once a second, not on every ask.
##
## Run with a unit-suite runner: static run() returns {name, passed, failed, details}.

const ProviderRes := preload("res://addons/wuifwoud/editor/forest_paint_provider.gd")
const Veg := preload("res://addons/wuifwoud/forest_spawner.gd")
const VA := preload("res://addons/wuifwoud/forest_assets.gd")
const PackOf := preload("res://addons/wuifwoud/tests/fixtures/pack_of.gd")
const ForestConfigRes := preload("res://addons/wuifwoud/forest_config.gd")
const ForestLogRes := preload("res://addons/wuifwoud/forest_log.gd")
const PROVIDERS := "res://addons/terrain_3d_extended/src/tool_providers.gd"
const KIT := "res://addons/terrain_3d_extended/src/ux_components.gd"
const FinderRes := preload("res://addons/wuifwoud/editor/forest_finder.gd")
const OverlayRes := preload("res://addons/wuifwoud/editor/forest_place_overlay.gd")
const BAD_DIR := "user://wf_b2c_place_bad"
const PROFILE_PATH := "user://wf_b2c_place_profile.json"
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


## Stands in for EditorUndoRedoManager: records each action's do and undo calls.
class StubUndo:
	var actions: Array = []

	func create_action(p_name: String, _merge := 0, p_context: Object = null, _backward := false) -> void:
		actions.append({"name": p_name, "context": p_context, "do": [], "undo": []})

	func add_do_method(o: Object, m: StringName, a = null, b = null, c = null, d = null, e = null) -> void:
		actions[-1]["do"].append([o, m, [a, b, c, d, e]])

	func add_undo_method(o: Object, m: StringName, a = null, b = null, c = null, d = null, e = null) -> void:
		actions[-1]["undo"].append([o, m, [a, b, c, d, e]])

	func commit_action(_execute := true) -> void:
		pass

	func play(p_which: String) -> void:
		for call in actions[-1][p_which]:
			var args: Array = call[2]
			while not args.is_empty() and args[-1] == null:
				args = args.slice(0, args.size() - 1)
			(call[0] as Object).callv(call[1], args)


## Stands in for ForestSourceReader: the import's items are ready (or not).
class StubReader:
	var rules := {}
	var ready := true
	var asked := 0

	func request(_m: Dictionary) -> void:
		asked += 1

	func poll() -> bool:
		return ready


## Stands in for Terrain3D Extended's UI node: its overlay says another workspace's tool is active.
class FakeUi extends Node:
	var overlay = null


class OtherOverlay extends RefCounted:
	func active_provider() -> Object:
		return null


static func _chk(r: Dictionary, n: String, ok: bool) -> void:
	if ok:
		r.passed += 1
	else:
		r.failed += 1
		r.details.append("✗ " + n)


static func _brush(ctrl := false) -> Dictionary:
	return {"size": 1.0, "strength": 1.0, "pressure": 1.0, "gamma": 1.0, "image": null, "invert": ctrl}


## A press at path[0], a drag through the rest, a release, with the active tool.
static func _gesture(p, path: Array, ctrl := false) -> void:
	var a: Vector2 = path[0]
	p.stroke_begin(Vector3(a.x, 0.0, a.y), _brush(ctrl))
	for i in range(1, path.size()):
		var b: Vector2 = path[i]
		p.stroke_to(Vector3(b.x, 0.0, b.y))
	p.stroke_end()


## The forest's Place overlays: [how many, how many visible].
static func _overlays(vp) -> Array:
	var n := 0
	var vis := 0
	for c in vp.get_children(true):
		if c.get_script() == OverlayRes:
			n += 1
			vis += 1 if c.visible else 0
	return [n, vis]


static func _id_of(vp, key: String) -> int:
	for id in vp.trees.items:
		if str((vp.trees.items[id] as Dictionary).get("source", "")) == key:
			return int(id)
	return -1


static func run() -> Dictionary:
	var r := {"name": "forest_place_tools", "passed": 0, "failed": 0, "details": []}
	var keep: Callable = ForestLogRes.sink
	ForestLogRes.sink = func(_level: StringName, _msg: String) -> void: pass
	ForestConfigRes.use(ForestConfigRes.new())
	VA.use_packs([PackOf.make(CAT)])
	var pf := FileAccess.open(PROFILE_PATH, FileAccess.WRITE)
	pf.store_string(JSON.stringify(PROFILE))
	pf.close()
	var vp = Veg.new()
	vp.profile_path = PROFILE_PATH
	vp._load_profile()
	vp.chunk_size = 64.0
	vp.maps.configure(256, 1.0, "")
	vp.maps.type_ids = vp._types.ids()
	vp.maps.editing = true
	var p = ProviderRes.new()
	var undo := StubUndo.new()
	var shift := [false]
	p.forest_of = func(): return vp
	p.set_undo(undo)
	p.place.px_m = func(_d: float) -> float: return 0.05            # 12 px are 0.6 m
	p.place.shift_held = func() -> bool: return shift[0]
	p.library_select(1)

	# ── the tools ──
	var ids: Array = p.tools().map(func(t): return t["id"])
	var tree_t: Dictionary = p.tools()[ids.find("forest.tree")]
	var bad := PackedStringArray()
	if ResourceLoader.exists(PROVIDERS):
		bad = load(PROVIDERS).check(p)
	_chk(r, "Tree and Row join the tools in a Place group, no size or strength, Ctrl their inverse; the contract still holds (%s; %s)" % [str(ids), str(bad)],
		ids.slice(6, 8) == ["forest.tree", "forest.row"] and tree_t["group"] == "place" and not bool(tree_t["uses_size"])
		and not bool(tree_t["uses_strength"]) and (tree_t["inverse"] as Dictionary).has("title") and bad.is_empty())

	# ── Tree: a click places a tree; one undo step; undo and redo ──
	p.activate("forest.tree", null)
	p.place.age = 0.4
	p.place.species = "W_Plum"
	_gesture(p, [Vector2(40, 40)])
	var placed: Dictionary = vp.trees.items.get(1, {})
	var act: Dictionary = undo.actions[-1] if not undo.actions.is_empty() else {}
	_chk(r, "a click on open ground places a tree of the library's type with the tools' settings, selected; one undo step on the forest (%s)" % str(placed),
		not placed.is_empty() and placed["at"] == Vector2(40, 40) and int(placed["type"]) == 1
		and is_equal_approx(float(placed["age"]), 0.4) and placed["species"] == "W_Plum" and float(placed["clear_m"]) == 3.0
		and not placed.has("source") and p.place.selected == 1 and undo.actions.size() == 1
		and act["name"] == "Forest: Place tree" and act["context"] == vp)
	undo.play("undo")
	var gone: bool = vp.trees.items.is_empty() and vp.trees.next_id == 1
	undo.play("do")
	_chk(r, "undo takes the tree away (and its id back); redo puts it back (%s)" % str(gone),
		gone and vp.trees.items.has(1) and vp.trees.next_id == 2)
	var n0 := undo.actions.size()
	_gesture(p, [Vector2(40.2, 40), Vector2(41, 40), Vector2(44, 43)])
	var mv_ok: bool = vp.trees.items[1]["at"] == Vector2(44, 43) and undo.actions.size() == n0 + 1 \
		and undo.actions[-1]["name"] == "Forest: Move tree"
	_gesture(p, [Vector2(44, 43.1)])
	var click_ok: bool = undo.actions.size() == n0 + 1 and p.place.selected == 1
	_gesture(p, [Vector2(44, 43)], true)
	_chk(r, "a drag on a tree moves it (one step), a click selects it (none), Ctrl+click deletes it (%s)" % str([mv_ok, click_ok]),
		mv_ok and click_ok and vp.trees.items.is_empty() and undo.actions[-1]["name"] == "Forest: Delete tree"
		and p.place.selected == -1)

	# ── Row: a drag draws a row; a click draws none ──
	p.activate("forest.row", null)
	var path := []
	for i in 41:
		path.append(Vector2(10.0 + float(i), 100.0))
	_gesture(p, path)
	var rid: int = p.place.selected
	var drawn: Dictionary = vp.trees.items.get(rid, {})
	var n1 := undo.actions.size()
	_gesture(p, [Vector2(200, 200), Vector2(200.4, 200)])
	_chk(r, "a drag draws a row, simplified to its ends, with the tools' spacing and clearance; a click draws none and clears the selection (%s)" % str(drawn.get("points")),
		not drawn.is_empty() and drawn["points"] == PackedVector2Array([Vector2(10, 100), Vector2(50, 100)])
		and float(drawn["spacing_m"]) == 8.0 and float(drawn["clear_m"]) == 2.5 and undo.actions[n1 - 1]["name"] == "Forest: Draw row"
		and undo.actions.size() == n1 and p.place.selected == -1)

	# ── Row: a vertex moved, one added on the line, the whole row with Shift; Ctrl deletes a vertex, then the row ──
	_gesture(p, [Vector2(50, 100.2), Vector2(51, 101), Vector2(55, 105)])
	var v_ok: bool = (vp.trees.items[rid]["points"] as PackedVector2Array)[1] == Vector2(55, 105) \
		and undo.actions[-1]["name"] == "Forest: Move vertex"
	_gesture(p, [Vector2(30, 102.4), Vector2(31, 103), Vector2(30, 90)])
	var pts_now: PackedVector2Array = vp.trees.items[rid]["points"]
	var ins_ok: bool = pts_now.size() == 3 and pts_now[1] == Vector2(30, 90) and undo.actions[-1]["name"] == "Forest: Add vertex"
	shift[0] = true
	_gesture(p, [Vector2(10, 100), Vector2(11, 100), Vector2(20, 110)])
	shift[0] = false
	var sh_pts: PackedVector2Array = vp.trees.items[rid]["points"]
	var sh_ok: bool = sh_pts[0] == Vector2(20, 110) and sh_pts[2] == Vector2(65, 115) and undo.actions[-1]["name"] == "Forest: Move row"
	_gesture(p, [sh_pts[1]], true)
	var dv_ok: bool = (vp.trees.items[rid]["points"] as PackedVector2Array).size() == 2 \
		and undo.actions[-1]["name"] == "Forest: Delete vertex"
	_gesture(p, [Vector2(42.5, 112.5)], true)
	_chk(r, "a vertex dragged, a vertex added on the line, the row moved with Shift, a vertex deleted with Ctrl, then the row (%s)" % str([v_ok, ins_ok, sh_ok, dv_ok]),
		v_ok and ins_ok and sh_ok and dv_ok and not vp.trees.items.has(rid) and undo.actions[-1]["name"] == "Forest: Delete row")

	# ── an imported row changed becomes the author's; one deleted is remembered ──
	vp.trees.apply({"items": {9: {"id": 9, "kind": "row", "points": PackedVector2Array([Vector2(100, 150), Vector2(140, 150)]),
		"type": 1, "age": 0.0, "species": "", "spacing_m": 8.0, "clear_m": 2.5, "source": "osm_id:77", "edited": false}},
		"removed": [], "next_id": 10})
	_gesture(p, [Vector2(140, 150), Vector2(141, 150), Vector2(145, 150)])
	var edited_ok: bool = bool(vp.trees.items[9]["edited"])
	_gesture(p, [Vector2(120, 150)], true)
	var rem_ok: bool = not vp.trees.items.has(9) and vp.trees.removed == ["osm_id:77"]
	undo.play("undo")
	_chk(r, "a moved imported row becomes the author's (edited); deleted, its source is remembered; undo brings both back (%s)" % str(vp.trees.removed),
		edited_ok and rem_ok and vp.trees.items.has(9) and vp.trees.removed.is_empty() and bool(vp.trees.items[9]["edited"]))

	# ── nothing while an import runs; no undo across one ──
	p.importing = func() -> Dictionary: return {"phase": "regions", "done": 1, "total": 2}
	var before_imp: Dictionary = vp.trees.state()
	_gesture(p, [Vector2(220, 220), Vector2(230, 220)])
	var none_ok: bool = vp.trees.state() == before_imp and p.cursor_note() == "importing 1/2"
	p.importing = Callable()
	vp.trees.generation += 1
	var before_gen: Dictionary = vp.trees.state()
	undo.play("undo")
	_chk(r, "while an import runs a gesture does nothing; a step from before an import is not undone, and the note says why (%s)" % p.cursor_note(),
		none_ok and vp.trees.state() == before_gen and p.cursor_note() == "placed before the import: not undone")

	# ── Revert to import, Restore deleted imports ──
	p.place._stale_until = 0
	var stub := StubReader.new()
	stub.rules = {"items": {
		"osm_id:77": {"kind": "row", "points": PackedVector2Array([Vector2(100, 150), Vector2(140, 150)]), "type": 1,
			"age": 0.0, "species": "", "spacing_m": 8.0, "clear_m": 2.5, "edited": false, "source": "osm_id:77"},
		"osm_id:78": {"kind": "tree", "at": Vector2(160, 160), "type": 1, "age": 0.0, "species": "", "clear_m": 3.0,
			"edited": false, "source": "osm_id:78"}}}
	p.reader = stub
	p.place.selected = 9
	p.place.revert_selected()
	var no_map: String = p.cursor_note()
	p.mapping_of = func() -> Dictionary: return {"rules": []}
	stub.ready = false
	p.place.revert_selected()
	var reading: String = p.cursor_note()
	stub.ready = true
	p.place.revert_selected()
	var rv: Dictionary = vp.trees.items[9]
	_chk(r, "Revert to import: without a mapping, and while it is read, the note says so; then the import's row, not edited, its id kept, one step (%s; %s)" % [no_map, reading],
		no_map == "no mapping for this scene: Import… first" and reading == "reading the source…"
		and rv["points"] == PackedVector2Array([Vector2(100, 150), Vector2(140, 150)]) and not bool(rv["edited"])
		and undo.actions[-1]["name"] == "Forest: Revert to import")
	vp.trees.apply(vp.trees.deletion(9))
	var add_rm: Dictionary = vp.trees.snapshot([])
	add_rm["removed"] = ["osm_id:77", "osm_id:78", "osm_id:99"]
	vp.trees.apply(add_rm)
	p.workspace_action("restore")
	var r77 := _id_of(vp, "osm_id:77")
	_chk(r, "Restore deleted imports (the panel's ⋯): every deleted key the import still has comes back, removed emptied, one step (%d, %d)" % [r77, _id_of(vp, "osm_id:78")],
		r77 > 0 and _id_of(vp, "osm_id:78") > 0 and vp.trees.removed.is_empty()
		and undo.actions[-1]["name"] == "Forest: Restore deleted imports")

	# ── the cells under an edit grow again ──
	vp._scatter_cell(Vector2i(2, 2), vp._chunks, 64.0, false)
	vp._collect_scatter(true)
	var c22: Dictionary = vp._chunks[Vector2i(2, 2)]
	p.activate("forest.tree", null)
	_gesture(p, [Vector2(170, 170)])
	vp._collect_scatter(true)
	_chk(r, "a tree placed regrows the cells under it",
		vp._chunks.has(Vector2i(2, 2)) and not is_same(vp._chunks[Vector2i(2, 2)], c22))

	# ── the cursor note; the pick radius ──
	p.activate("forest.row", null)
	p.project_hit(Vector3(130, 50, 150), Vector3.DOWN, Vector3(130, 0, 150.2))
	var over: String = p.cursor_note()
	vp.set_road_segments(PackedFloat64Array([240.0, 0.0, 240.0, 256.0, 2.0]))
	p.project_hit(Vector3(240, 50, 20), Vector3.DOWN, Vector3(240, 0, 20))
	var road: String = p.cursor_note()
	_chk(r, "the cursor note: the row under the cursor and who owns it; on a road, why a tree won't grow (%s; %s)" % [over, road],
		over == "row %d (imported)" % r77 and road == "on a road: won't grow")
	p.place.px_m = func(d: float) -> float: return d * 0.001
	p.project_hit(Vector3(0, 100, 0), Vector3.DOWN, Vector3.ZERO)
	_chk(r, "the pick radius is 12 screen pixels at the hit's distance (%.2f m)" % p.place.pick_radius(Vector3.ZERO),
		is_equal_approx(p.place.pick_radius(Vector3.ZERO), 1.2))

	# ── the panel ──
	if ResourceLoader.exists(KIT):
		var kit = load(KIT)
		var box := VBoxContainer.new()
		p.activate("forest.row", null)
		p.place.selected = r77
		p.build_settings(box, "forest.row", kit, Color.WHITE)
		var owner_l: Label = box.find_child("Owner", true, false)
		_chk(r, "the panel: the selected row (who owns it, its type, species, age, spacing, clearance, Delete) and the settings new items take (%s)" % (owner_l.text if owner_l != null else "no panel"),
			box.find_child("PlacePanel", true, false) != null and owner_l != null and owner_l.text == "row %d (imported)" % r77
			and box.find_child("Type1", true, false) != null and box.find_child("SpeciesBy", true, false) != null
			and box.find_child("Age", true, false) != null and box.find_child("Spacing", true, false) != null
			and box.find_child("Clearance", true, false) != null and box.find_child("DeleteItem", true, false) != null
			and box.find_child("RevertItem", true, false) == null and box.find_child("NewSpacing", true, false) != null)
		(box.find_child("Type2", true, false) as Button).pressed.emit()
		var retyped: Dictionary = vp.trees.items[r77]
		_chk(r, "a type picked in the panel: one step, the row retyped and the author's; the panel refills, Revert now offered (%s)" % str(retyped["type"]),
			int(retyped["type"]) == 2 and bool(retyped["edited"]) and undo.actions[-1]["name"] == "Forest: Change type"
			and box.find_child("RevertItem", true, false) != null)
		var ns := box.find_child("NewSpacing", true, false).get_node("Slider") as HSlider
		ns.value = 12.0
		ns.value_changed.emit(12.0)              # Range defers value_changed (Godot 4.8): the editor's comes a frame later
		var cap_state: Dictionary = p.capture("forest.row")
		_chk(r, "the new items' settings follow their sliders and ride in a preset (%s)" % str(cap_state),
			is_equal_approx(p.place.spacing, 12.0) and is_equal_approx(float(cap_state.get("spacing", 0.0)), 12.0))
		box.free()

	# ── the overlay ──
	p.activate("forest.row", null)
	p.tick()
	var ov = null
	for c in vp.get_children(true):
		if String(c.name) == "WuifwoudPlaceOverlay":
			ov = c
	var im: ImmediateMesh = ov.mesh if ov != null else null
	var verts: int = (im.surface_get_arrays(0)[Mesh.ARRAY_VERTEX] as PackedVector3Array).size() \
		if im != null and im.get_surface_count() > 0 else 0
	_chk(r, "a Place tool active: the overlay is an internal, unowned child of the forest, in world space, drawn (%d vertices)" % verts,
		ov != null and ov.owner == null and ov.top_level and ov.visible and verts > 0)
	var d0: int = ov.draws if ov != null else -1
	p.tick()
	var same: bool = ov != null and ov.draws == d0
	p.place.selected = -1
	p.tick()
	var redrawn: bool = ov != null and ov.draws == d0 + 1
	p.activate("forest.paint", null)
	p.tick()
	var hid_tool: bool = ov != null and not ov.visible
	var fake := FakeUi.new()
	fake.overlay = OtherOverlay.new()
	p.activate("forest.row", fake)
	p.tick()
	_chk(r, "drawn again only when the items, the selection or the hover changed; hidden for a paint tool, and when the overlay's active tool is another workspace's (%s)" % str([same, redrawn, hid_tool]),
		same and redrawn and hid_tool and ov != null and not ov.visible)
	fake.free()

	# ── another scene tab's forest (final review #1): the tools follow the edited scene's forest ──
	var vp2 = Veg.new()
	vp2.profile_path = PROFILE_PATH
	vp2._load_profile()
	vp2.chunk_size = 64.0
	vp2.maps.configure(256, 1.0, "")
	vp2.maps.type_ids = vp2._types.ids()
	vp2.maps.editing = true
	var vid: int = vp.trees.items.keys()[0]
	vp2.trees.apply({"items": {vid: {"id": vid, "kind": "tree", "at": Vector2(5, 5), "type": 1, "age": 0.0, "species": "",
		"clear_m": 3.0, "edited": false}}, "removed": [], "next_id": vid + 1})
	p.activate("forest.row", null)
	p.tick()
	p.place.selected = vid
	p.forest_of = func(): return vp2
	p.place.delete_selected()                          # the panel's Delete, before any tick: vp's selection, not vp2's
	var other_kept: bool = vp2.trees.items.has(vid)
	p.tick()
	var in_vp2: Array = _overlays(vp2)
	p.forest_of = func(): return vp
	p.tick()
	var back: Array = _overlays(vp)
	var gone2: Array = _overlays(vp2)
	p.activate("forest.paint", null)
	p.tick()
	_chk(r, "the edited scene's forest changed: the selection does not follow (Delete leaves the other forest's item %d), the old forest's overlay goes; back again one overlay, hidden for a paint tool (%s)" % [
		vid, str([in_vp2, back, gone2, _overlays(vp)])],
		other_kept and in_vp2 == [1, 1] and back == [1, 1] and gone2 == [0, 0] and _overlays(vp) == [1, 0]
		and p.place.selected == -1)

	# ── a trees file that did not read whole (final review #2): not edited, said ──
	DirAccess.make_dir_recursive_absolute(ProjectSettings.globalize_path(BAD_DIR))
	var bf := FileAccess.open(BAD_DIR.path_join("trees.json"), FileAccess.WRITE)
	bf.store_string(JSON.stringify({"schema": "wuifwoud_trees/1", "next_id": 3, "items": [
		{"id": 1, "kind": "tree", "at": [20, 20], "type": 1}, {"id": 2, "kind": "bush", "at": [30, 30], "type": 1}],
		"removed": []}))
	bf.close()
	vp2.trees.configure(BAD_DIR.path_join("trees.json"))
	p.forest_of = func(): return vp2
	p.activate("forest.tree", null)
	_gesture(p, [Vector2(60, 60)])
	p.place.selected = 1
	p.place.delete_selected()
	var locked: String = p.place.note("forest.tree")
	_chk(r, "a trees file that did not read whole is not edited (a save would lose the malformed item): a click places nothing, Delete deletes nothing, the note says why (%s)" % locked,
		vp2.trees.items.keys() == [1] and not vp2.trees.dirty and locked.contains("did not read whole"))
	p.forest_of = func(): return vp
	vp2._drain_scatter_jobs()
	vp2.free()
	DirAccess.remove_absolute(ProjectSettings.globalize_path(BAD_DIR.path_join("trees.json")))
	DirAccess.remove_absolute(ProjectSettings.globalize_path(BAD_DIR))

	# ── the edited scene's forest, found once ──
	var root := Node3D.new()
	var mid := Node3D.new()
	root.add_child(mid)
	var fv = Veg.new()
	mid.add_child(fv)
	var fd = FinderRes.new()
	var a1 = fd.find(root, 1000)
	var a2 = fd.find(root, 1001)
	var bare := Node3D.new()
	bare.add_child(Node3D.new())
	var w0: int = fd.walks
	fd.find(bare, 2000)
	fd.find(bare, 2500)
	fd.find(bare, 2999)
	var held: int = fd.walks - w0
	fd.find(bare, 3001)
	_chk(r, "the forest found once per scene; a scene without one walked once a second, not on every ask (%s)" % str([held, fd.walks - w0]),
		a1 == fv and a2 == fv and w0 == 1 and held == 1 and fd.walks - w0 == 2)
	root.free()
	bare.free()

	vp._drain_scatter_jobs()
	vp.free()
	DirAccess.remove_absolute(ProjectSettings.globalize_path(PROFILE_PATH))
	ForestConfigRes.use(null)
	VA.forget_packs()
	ForestLogRes.sink = keep
	return r
