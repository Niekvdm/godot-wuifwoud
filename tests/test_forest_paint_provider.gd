# Copyright (c) 2026 Digitzone
# SPDX-License-Identifier: MIT
extends RefCounted
## The Forest workspace: Terrain3D Extended's contract (when it is installed); the rail
## entry and the tools; no forest in the scene says so; the library is the forest's own types; a Paint stroke paints,
## marks, dirties and is ONE undo step on the forest node, whose undo puts every channel back and redo paints again;
## Ctrl paints no forest; Pick selects the type under the cursor, says what it picked, hands back; the overlay's level.
## Import…, the pause while an import runs, Revert, a stroke from before an import not undone. The Place tools
## in the list; Restore deleted imports in the ⋯; the Revert note asking at most once a second.
##
## Run with a unit-suite runner: static run() returns {name, passed, failed, details}.

const ProviderRes := preload("res://addons/wuifwoud/editor/forest_paint_provider.gd")
const Veg := preload("res://addons/wuifwoud/forest_spawner.gd")
const VA := preload("res://addons/wuifwoud/forest_assets.gd")
const PackOf := preload("res://addons/wuifwoud/tests/fixtures/pack_of.gd")
const ForestConfigRes := preload("res://addons/wuifwoud/forest_config.gd")
const OldProviders := preload("res://addons/wuifwoud/tests/fixtures/old_providers.gd")
const ImportRes := preload("res://addons/wuifwoud/forest_import.gd")
const PROVIDERS := "res://addons/terrain_3d_extended/src/tool_providers.gd"
const PROFILE_PATH := "user://wf_b2a_paint_profile.json"
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
			(call[0] as Object).callv(call[1], call[2])


## Stands in for ForestSourceReader: its rules' shapes are ready (or not).
class StubReader:
	var rules := {}
	var ready := true
	var asked := 0

	func request(_m: Dictionary) -> void:
		asked += 1

	func poll() -> bool:
		return ready


static func _chk(r: Dictionary, n: String, ok: bool) -> void:
	if ok:
		r.passed += 1
	else:
		r.failed += 1
		r.details.append("✗ " + n)


static func run() -> Dictionary:
	var r := {"name": "forest_paint_provider", "passed": 0, "failed": 0, "details": []}
	var p = ProviderRes.new()
	var bad := PackedStringArray()
	if ResourceLoader.exists(PROVIDERS):
		bad = load(PROVIDERS).check(p)
	_chk(r, "Terrain3D Extended's provider contract holds (%s)" % str(bad), bad.is_empty())
	var ws: Dictionary = p.workspace()
	_chk(r, "the rail entry: Forest, paints itself, API 3, its eyedropper, the types library (%s)" % str(ws),
		ws["id"] == "forest" and ws["api"] == 3 and ws["paints_itself"] and ws["pick_tool"] == "forest.pick"
		and ws["library"] == "types")
	var tl: Array = p.tools()
	var ids := tl.map(func(t): return t["id"])
	_chk(r, "the tools: Paint, Replace (From chip), Density, Age, Smooth, Revert, Tree, Row, Pick hidden (%s)" % str(ids),
		ids == ["forest.paint", "forest.replace", "forest.density", "forest.age", "forest.smooth", "forest.revert",
			"forest.tree", "forest.row", "forest.pick"] and bool(tl[8].get("hidden", false))
		and bool(tl[1].get("source_item", false)))
	_chk(r, "no forest in the scene: the cursor note says so, the library is empty",
		p.cursor_note() == "no forest in this scene" and (p.library()["items"] as Array).is_empty())

	ForestConfigRes.use(ForestConfigRes.new())
	VA.use_packs([PackOf.make(CAT)])
	var f := FileAccess.open(PROFILE_PATH, FileAccess.WRITE)
	f.store_string(JSON.stringify(PROFILE))
	f.close()
	var vp = Veg.new()
	vp.profile_path = PROFILE_PATH
	vp._load_profile()
	vp.maps.configure(64, 1.0, "")
	vp.maps.type_ids = vp._types.ids()
	vp.maps.editing = true
	var blank := Image.create_empty(64, 64, false, Image.FORMAT_RGBA8)
	blank.fill(Color8(0, 255, 128, 0))
	vp.maps.adopt(Vector2i(0, 0), blank)
	var undo := StubUndo.new()
	p.forest_of = func(): return vp
	p.set_undo(undo)
	var lib: Dictionary = p.library()
	var names: Array = (lib["items"] as Array).map(func(i): return i["name"])
	_chk(r, "the library is the forest's types (%s; %s)" % [str(names), lib["footer"]],
		names == ["Wood", "Orchard"] and String(lib["footer"]).begins_with("2 types"))

	p.library_select(2)
	p.activate("forest.paint", null)
	var brush := {"size": 4.0, "strength": 1.0, "pressure": 1.0, "gamma": 1.0, "image": null, "invert": false}
	var orig: PackedByteArray = vp.maps.edit_image(Vector2i(0, 0)).get_data()
	p.stroke_begin(Vector3(10.5, 0, 10.5), brush)
	p.stroke_to(Vector3(14.5, 0, 10.5))
	p.stroke_end()
	var c: Color = vp.maps.edit_image(Vector2i(0, 0)).get_pixel(10, 10)
	_chk(r, "a Paint stroke paints type 2, marks it, dirties the map, and is one undo step on the forest (%s; %d)" % [
		str([c.r8, c.a8]), undo.actions.size()], [c.r8, c.a8] == [2, 255] and vp.maps.unsaved()
		and undo.actions.size() == 1 and undo.actions[0]["name"] == "Forest: Paint" and undo.actions[0]["context"] == vp)
	undo.play("undo")
	_chk(r, "undo puts every channel back, the marks included",
		vp.maps.edit_image(Vector2i(0, 0)).get_data() == orig)
	undo.play("do")
	var redone: int = vp.maps.edit_image(Vector2i(0, 0)).get_pixel(10, 10).r8
	var inv := brush.duplicate()
	inv["invert"] = true
	p.stroke_begin(Vector3(10.5, 0, 10.5), inv)
	p.stroke_end()
	_chk(r, "redo paints again; Ctrl paints no forest (%d, %d)" % [redone,
		vp.maps.edit_image(Vector2i(0, 0)).get_pixel(10, 10).r8],
		redone == 2 and vp.maps.edit_image(Vector2i(0, 0)).get_pixel(10, 10).r8 == 0)

	# final review #5: a stroke's sends regrow its mesh chunks only; its end regrows the card cells it crossed
	vp._scatter_cell(Vector2i(0, 0), vp._chunks, vp.chunk_size, false)
	vp._scatter_cell(Vector2i(0, 0), vp._bb_cells, vp.billboard_chunk_m, true)
	vp._collect_scatter(true)
	var ch0: Dictionary = vp._chunks[Vector2i(0, 0)]
	var bc0: Dictionary = vp._bb_cells[Vector2i(0, 0)]
	p.activate("forest.paint", null)
	p.stroke_begin(Vector3(30.5, 0, 30.5), brush)
	p._last_send_ms = -100000                                       # the next motion sends, as 250 ms on
	p.stroke_to(Vector3(34.5, 0, 30.5))
	var mid_ok: bool = not is_same(vp._chunks[Vector2i(0, 0)], ch0) and is_same(vp._bb_cells[Vector2i(0, 0)], bc0)
	p.stroke_end()
	vp._collect_scatter(true)
	_chk(r, "a stroke's sends regrow its mesh chunks; its end regrows the card cells it crossed (%s)" % str(mid_ok),
		mid_ok and not is_same(vp._bb_cells[Vector2i(0, 0)], bc0))

	var dones := []
	p.tool_done.connect(func(t): dones.append(t))
	p.library_select(1)
	p.activate("forest.pick", null)
	p.stroke_begin(Vector3(14.5, 0, 10.5), brush)
	_chk(r, "Pick selects the type under the cursor, says what it picked, hands back (%s; %s)" % [p.picked, str(dones)],
		p.library_selected() == 2 and p.picked.contains("Orchard") and p.picked.contains("painted")
		and dones == ["forest.pick"])
	_chk(r, "the overlay's level: 2 or more here, 1 for an overlay without one",
		(not ResourceLoader.exists(PROVIDERS) or ProviderRes.overlay_level(load(PROVIDERS)) >= 2)
		and ProviderRes.overlay_level(OldProviders) == 1)
	# ── Import… opens the dialog ──
	var opened := [0]
	p.import_requested.connect(func() -> void: opened[0] += 1)
	var acts: Array = p.workspace_actions().map(func(a): return a["id"])
	p.workspace_action("import")
	_chk(r, "the panel's ⋯ has Import… first, Restore deleted imports next, and Import… asks the plugin for the dialog (%s)" % str(acts),
		acts == ["import", "restore", "reload", "regrow"] and opened[0] == 1)

	# ── while an import runs no stroke lands; the note says how far it is ──
	p.importing = func() -> Dictionary: return {"phase": "regions", "done": 3, "total": 9}
	var at_import: PackedByteArray = vp.maps.edit_image(Vector2i(0, 0)).get_data()
	p.activate("forest.paint", null)
	p.stroke_begin(Vector3(40.5, 0, 40.5), brush)
	p.stroke_end()
	_chk(r, "while an import runs a stroke does nothing and the note says how far it is (%s)" % p.cursor_note(),
		vp.maps.edit_image(Vector2i(0, 0)).get_data() == at_import and p.cursor_note() == "importing 3/9")
	p.importing = Callable()

	# ── Revert ──
	var stub := StubReader.new()
	var wood_shapes: Dictionary = ImportRes.shapes_of([{"type": "Feature", "properties": {"kind": "wood"},
		"geometry": {"type": "Polygon", "coordinates": [[[0, 0], [64, 0], [64, 64], [0, 64], [0, 0]]]}}],
		[{"match": {"kind": "wood"}, "type": 1}], [])
	stub.rules = {"shapes": wood_shapes["shapes"]}
	p.reader = stub
	p.activate("forest.revert", null)
	_chk(r, "Revert without a mapping: the note says Import… first", p.cursor_note() == "no mapping: Import… first")
	p.mapping_of = func() -> Dictionary: return {"rules": [{"match": {"kind": "wood"}, "type": 1}]}
	p.activate("forest.revert", null)                 # the note asks again on a tool change (it asks at most once a second)
	stub.ready = false
	var waiting := p.cursor_note()
	stub.ready = true
	var n_actions := undo.actions.size()
	p.stroke_begin(Vector3(10.5, 0, 10.5), brush)
	p.stroke_end()
	var rc: Color = vp.maps.edit_image(Vector2i(0, 0)).get_pixel(10, 10)
	_chk(r, "Revert: the mapping's texel, unmarked, one undo step; while the mapping is read the note says so (%s; %s)" % [
		str([rc.r8, rc.a8]), waiting], [rc.r8, rc.a8] == [1, 0] and undo.actions.size() == n_actions + 1
		and undo.actions[-1]["name"] == "Forest: Revert" and waiting == "reading the mapping…")

	# ── a stroke from before an import does not undo ──
	var before_gen: PackedByteArray = vp.maps.edit_image(Vector2i(0, 0)).get_data()
	vp.maps.generation += 1
	undo.play("undo")
	_chk(r, "a stroke from before an import is not undone; the note says why (%s)" % p.cursor_note(),
		vp.maps.edit_image(Vector2i(0, 0)).get_data() == before_gen and p.cursor_note() == "painted before the import: not undone")

	# ── final review: an undo while an import runs is not applied (the import's copy would bring the stroke back) ──
	p._stale_until = 0
	p.activate("forest.paint", null)
	p.stroke_begin(Vector3(50.5, 0, 50.5), brush)
	p.stroke_end()
	var painted_now: PackedByteArray = vp.maps.edit_image(Vector2i(0, 0)).get_data()
	p.importing = func() -> Dictionary: return {"phase": "regions", "done": 1, "total": 2}
	undo.play("undo")
	var held_note: String = p.cursor_note()
	p.importing = Callable()
	_chk(r, "an undo while an import runs changes nothing and the note says why (%s)" % held_note,
		vp.maps.edit_image(Vector2i(0, 0)).get_data() == painted_now and held_note == "importing 1/2")
	# ── the Revert brush's note asks for the mapping and the reader at most once a second ──
	var asks := [0]
	p.mapping_of = func() -> Dictionary:
		asks[0] += 1
		return {"rules": [{"match": {"kind": "wood"}, "type": 1}]}
	p.activate("forest.revert", null)
	var asked0: int = stub.asked
	for _i in 50:
		p.cursor_note()
	_chk(r, "fifty frames of the Revert brush's note ask for the mapping and the reader once (%d, %d)" % [asks[0], stub.asked - asked0],
		asks[0] == 1 and stub.asked - asked0 == 1)
	vp._drain_scatter_jobs()
	vp.free()
	DirAccess.remove_absolute(ProjectSettings.globalize_path(PROFILE_PATH))
	ForestConfigRes.use(null)
	VA.forget_packs()
	return r
