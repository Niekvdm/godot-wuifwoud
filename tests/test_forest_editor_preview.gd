# Copyright (c) 2026 Digitzone
# SPDX-License-Identifier: MIT
extends RefCounted
## The forest in the editor: one switch; the editor inputs attach (only @tool ones) and the
## runtime ones do not; the forest joins its group there too; stored nodes of the old Spawn in scene button are freed;
## a scene save stores nothing the forest made; the ring follows the terrain's editor camera; a scene tab left and come
## back tears the preview down and builds it once; the Forest menu's switch releases every cell and lets the ring fill
## again; the editor's forest never puts its occlusion builder on the scene's environment; regrow re-grows only the
## cells over an edit, from the edited map, and drops a job started before it; Re-grow all; Reload types (ids,
## summaries, every cell); the Forest menu flips the switch and asks for a re-grow. The maps with the preview off; a
## regrow after an import; the maps' scene. A regrow after an import of the trees file; the trees' scene.
##
## Run with a unit-suite runner: static run() returns {name, passed, failed, details}.

const Veg := preload("res://addons/wuifwoud/forest_spawner.gd")
const IndRes := preload("res://addons/wuifwoud/forest_indirect.gd")
const ForestConfigRes := preload("res://addons/wuifwoud/forest_config.gd")
const ForestLogRes := preload("res://addons/wuifwoud/forest_log.gd")
const PreviewRes := preload("res://addons/wuifwoud/forest_preview.gd")
const ProbeFeeder := preload("res://addons/wuifwoud/tests/fixtures/probe_feeder.gd")
const EditorProbe := preload("res://addons/wuifwoud/tests/fixtures/editor_probe_feeder.gd")
const FakeTerrain := preload("res://addons/wuifwoud/tests/fixtures/fake_terrain.gd")
const VA := preload("res://addons/wuifwoud/forest_assets.gd")
const PackOf := preload("res://addons/wuifwoud/tests/fixtures/pack_of.gd")
const MenuRes := preload("res://addons/wuifwoud/editor/forest_preview_menu.gd")
const WfPoints := preload("res://addons/wuifwoud/tests/fixtures/wf_points.gd")
const StubIndirect := preload("res://addons/wuifwoud/tests/fixtures/stub_indirect.gd")
const PROFILE_PATH := "user://wf_b2a_preview_profile.json"
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
		{"id": 1, "name": "Wood", "style": "natural", "density_per_m2": 0.04, "understory": 0.0, "dead_frac": 0.0},
		{"id": 2, "name": "Orchard", "style": "grid", "pitch_m": 7.0},
	],
}


class Capture:
	var lines: Array = []

	func take(level: StringName, msg: String) -> void:
		lines.append([level, msg])

	func warns(part: String) -> int:
		return lines.filter(func(l): return l[0] == &"warn" and String(l[1]).contains(part)).size()


static func _chk(r: Dictionary, n: String, ok: bool) -> void:
	if ok:
		r.passed += 1
	else:
		r.failed += 1
		r.details.append("✗ " + n)


static func _write_profile(p: Dictionary) -> void:
	var f := FileAccess.open(PROFILE_PATH, FileAccess.WRITE)
	f.store_string(JSON.stringify(p))
	f.close()


static func _filled(w: int, px: Array) -> Image:
	var img := Image.create_empty(w, w, false, Image.FORMAT_RGBA8)
	img.fill(Color8(px[0], px[1], px[2], px[3]))
	return img


## A spawner on the test profile, its maps editing over 256 m regions, (0, 0) adopted as `img`; not in the tree.
static func _forest(img: Image):
	var vp = Veg.new()
	vp.profile_path = PROFILE_PATH
	vp._load_profile()
	vp.chunk_size = 64.0
	vp.maps.configure(256, 1.0, "")
	vp.maps.type_ids = vp._types.ids()
	vp.maps.editing = true
	vp.maps.adopt(Vector2i(0, 0), img)
	return vp


static func _seeds(pts: Array) -> Dictionary:
	var out := {}
	for pt in pts:
		out[pt["seed"]] = pt["p"]
	return out


static func run() -> Dictionary:
	var r := {"name": "forest_editor_preview", "passed": 0, "failed": 0, "details": []}
	var tree := Engine.get_main_loop() as SceneTree
	var keep: Callable = ForestLogRes.sink
	var cap := Capture.new()
	ForestLogRes.sink = cap.take
	var cfg = ForestConfigRes.new()
	var rt: Array[Script] = [ProbeFeeder]
	var ed: Array[Script] = [EditorProbe, ProbeFeeder]
	cfg.runtime_inputs = rt
	cfg.editor_inputs = ed
	ForestConfigRes.use(cfg)
	PreviewRes.visible = true

	# ── the editor's forest: its inputs, its group, the old button's stored nodes ──
	var vs: Node3D = Veg.new()
	vs.force_editor = true
	vs.indirect_mmi = false
	var stored := Node3D.new()
	stored.name = "Veg_old_0"
	vs.add_child(stored)
	stored.owner = vs                    # stored by a scene: the old button owned its nodes to the scene root
	tree.root.add_child(vs)
	await tree.process_frame
	var eds := vs.get_children().filter(func(c): return c.get_script() == EditorProbe)
	var rts := vs.get_children().filter(func(c): return c.get_script() == ProbeFeeder)
	_chk(r, "in the editor the editor inputs attach, a non-@tool one is skipped with one warning, the runtime ones do not (%d %d %d)" % [
		eds.size(), rts.size(), cap.warns("not @tool")], eds.size() == 1 and rts.size() == 0 and cap.warns("not @tool") == 1)
	_chk(r, "the forest joins its group in the editor too (its feeders find it)",
		vs.is_in_group(&"wuifwoud_forest") and eds.size() == 1 and eds[0].forest == vs)
	_chk(r, "a stored node of the old Spawn in scene button is freed, one warning (%d)" % cap.warns("stored preview"),
		vs.find_child("Veg_old_0", false, false) == null and cap.warns("stored preview") == 1)
	var ps := PackedScene.new()
	ps.pack(vs)
	_chk(r, "a scene saved now stores the forest node alone (%d nodes), no Timer in the editor" % ps.get_state().get_node_count(),
		ps.get_state().get_node_count() == 1 and vs.get_children().all(func(c): return c.owner == null)
		and vs.get_children().filter(func(c): return c is Timer).is_empty())

	# ── the camera ──
	var ft = FakeTerrain.new()
	ft.cam = Camera3D.new()
	vs.terrain_source = ft
	var game: Node3D = Veg.new()
	game.indirect_mmi = false
	game.tree_collision = false
	game.terrain_source = ft
	tree.root.add_child(game)
	await tree.process_frame
	_chk(r, "the ring follows the terrain's editor camera in the editor, the viewport's in the game",
		vs._camera() == ft.cam and game._camera() != ft.cam)
	vs.terrain_source = null

	# ── a scene tab left and come back ──
	vs._chunks[Vector2i(9, 9)] = {"pts": [], "done": true, "nodes": []}
	tree.root.remove_child(vs)
	var torn: bool = vs._chunks.is_empty() and not vs.is_node_ready()
	tree.root.add_child(vs)
	await tree.process_frame
	var eds2 := vs.get_children().filter(func(c): return c.get_script() == EditorProbe)
	_chk(r, "a scene tab left and come back: torn down on exit, readied once again, inputs not doubled (%s %d)" % [
		str(torn), eds2.size()], torn and vs.is_node_ready() and eds2.size() == 1)

	# ── the Forest menu's switch ──
	vs._chunks[Vector2i(3, 3)] = {"pts": [], "done": true, "nodes": []}
	PreviewRes.visible = false
	vs._editor_tick()
	var off_ok: bool = vs._chunks.is_empty() and vs._preview_off
	PreviewRes.visible = true
	vs._stream_dirty = false
	vs._editor_tick()
	_chk(r, "the preview switch: off releases every cell, on lets the ring fill again",
		off_ok and not vs._preview_off and vs._stream_dirty)

	# ── the GPU node in the editor (final review #1, #2): cleared when the preview goes off; culled from the editor's
	#    camera, not the edited scene's ──
	var stub = StubIndirect.new()
	vs.add_child(stub)
	vs._indirect = stub
	var ft2 = FakeTerrain.new()
	ft2.cam = Camera3D.new()
	vs.terrain_source = ft2
	PreviewRes.visible = false
	vs._editor_tick()
	var cleared_off: int = stub.cleared
	PreviewRes.visible = true
	vs._editor_tick()
	_chk(r, "the preview switch clears the GPU node; on, the cull is handed the editor's camera (%d cleared, %s)" % [
		cleared_off, str(stub.camera == ft2.cam)], cleared_off == 1 and stub.camera == ft2.cam and stub.updates >= 1)
	vs._indirect = null
	vs.terrain_source = null
	stub.queue_free()
	var cam_a := Camera3D.new()
	var cam_b := Camera3D.new()
	cam_b.position = Vector3(500.0, 40.0, -300.0)                # elsewhere, looking the other way
	cam_b.rotation = Vector3(0.0, PI, 0.0)
	tree.root.add_child(cam_a)
	tree.root.add_child(cam_b)
	cam_a.make_current()                                         # the viewport's camera
	var ic: Node3D = IndRes.new()
	tree.root.add_child(ic)
	ic.camera = cam_b
	await tree.process_frame
	var rows_got := (ic._globals_bytes() as PackedByteArray).to_float32_array().slice(8, 32)
	_chk(r, "the GPU node's cull frustum is the camera it was handed, not the viewport's",
		rows_got == IndRes.frustum_rows(cam_b) and rows_got != IndRes.frustum_rows(cam_a))
	for n3 in [ic, cam_a, cam_b, ft2.cam, ft2]:
		n3.free()

	# ── the occlusion builder never reaches the scene's environment from the editor ──
	var we := WorldEnvironment.new()
	we.environment = Environment.new()
	tree.root.add_child(we)
	var ie: Node3D = IndRes.new()
	ie.editor = true
	tree.root.add_child(ie)
	ie._ensure_hiz_builder()
	var in_editor: bool = we.compositor == null
	var ig: Node3D = IndRes.new()
	tree.root.add_child(ig)
	ig._ensure_hiz_builder()
	_chk(r, "the editor's forest never puts its occlusion builder on the scene's environment (the game's does)",
		in_editor and we.compositor != null)

	# ── the Forest menu ──
	var menu = MenuRes.new()
	var changes := []
	var regrows := []
	menu.changed.connect(func(): changes.append(1))
	menu.regrow_requested.connect(func(): regrows.append(1))
	PreviewRes.visible = true
	menu._on_id(MenuRes.ID_SHOW)
	var off_now: bool = not PreviewRes.visible
	menu._on_id(MenuRes.ID_REGROW)
	menu._on_id(MenuRes.ID_SHOW)
	_chk(r, "the Forest menu flips the preview switch (and says so) and asks for a re-grow (%d %d)" % [changes.size(),
		regrows.size()], off_now and PreviewRes.visible and changes.size() == 2 and regrows.size() == 1)
	menu.free()

	# ── regrow ──
	ForestConfigRes.use(ForestConfigRes.new())        # no fallback flora: the pools are the test profile's alone
	VA.use_packs([PackOf.make(CAT)])
	_write_profile(PROFILE)
	var vg = _forest(_filled(256, [1, 255, 128, 0]))
	for k in [Vector2i(0, 0), Vector2i(1, 0)]:
		vg._scatter_cell(k, vg._chunks, 64.0, false)
	vg._collect_scatter(true)
	var e0: Dictionary = vg._chunks[Vector2i(0, 0)]
	var e1: Dictionary = vg._chunks[Vector2i(1, 0)]
	var img: Image = vg.maps.edit_image(Vector2i(0, 0))
	img.fill_rect(Rect2i(0, 0, 64, 64), Color8(2, 255, 128, 255))
	vg.maps.refresh(Vector2i(0, 0), Rect2i(0, 0, 64, 64))
	vg.regrow(vg.maps.world_rect(Vector2i(0, 0), Rect2i(0, 0, 64, 64)))
	var renewed: bool = not is_same(vg._chunks[Vector2i(0, 0)], e0) and is_same(vg._chunks[Vector2i(1, 0)], e1)
	vg._collect_scatter(true)
	var got: Array = WfPoints.decode(vg._chunks[Vector2i(0, 0)]["pts"], vg._tables_now())
	var fresh = _forest(img.duplicate())
	var wj: Dictionary = WfPoints.scatter(fresh, Rect2(0, 0, 64, 64), [Vector2i(0, 0)])
	var want: Array = WfPoints.decode(wj["pts"], wj.get("tables"))
	_chk(r, "regrow re-grows only the cells over the edit (%s), as a fresh scatter of the edited map (%d = %d, all type 2)" % [
		str(renewed), got.size(), want.size()], renewed and not got.is_empty() and _seeds(got) == _seeds(want)
		and got.all(func(p): return p["type"] == 2))

	# final review #5: during a stroke only the mesh chunks regrow; the 1 km card cells at its end
	vg._scatter_cell(Vector2i(0, 0), vg._bb_cells, vg.billboard_chunk_m, true)
	vg._collect_scatter(true)
	var c0: Dictionary = vg._chunks[Vector2i(0, 0)]
	var bb0: Dictionary = vg._bb_cells[Vector2i(0, 0)]
	vg.regrow(Rect2(0, 0, 16, 16), true, false)
	var mesh_only: bool = not is_same(vg._chunks[Vector2i(0, 0)], c0) and is_same(vg._bb_cells[Vector2i(0, 0)], bb0)
	var c1: Dictionary = vg._chunks[Vector2i(0, 0)]
	vg.regrow(Rect2(0, 0, 16, 16), false, true)
	_chk(r, "regrow takes the mesh chunks alone (a stroke in progress) or the card cells alone (its end) (%s)" % str(mesh_only),
		mesh_only and is_same(vg._chunks[Vector2i(0, 0)], c1) and not is_same(vg._bb_cells[Vector2i(0, 0)], bb0))
	vg._collect_scatter(true)

	var vj = _forest(_filled(256, [1, 255, 128, 0]))
	vj._scatter_cell(Vector2i(0, 0), vj._chunks, 64.0, false)          # its job starts on the old map
	var ij: Image = vj.maps.edit_image(Vector2i(0, 0))
	ij.fill_rect(Rect2i(0, 0, 64, 64), Color8(2, 255, 128, 255))
	vj.maps.refresh(Vector2i(0, 0), Rect2i(0, 0, 64, 64))
	vj.regrow(Rect2(0, 0, 64, 64))
	vj._collect_scatter(true)
	var jp: Array = WfPoints.decode(vj._chunks[Vector2i(0, 0)]["pts"], vj._tables_now())
	_chk(r, "a job that started before the regrow is dropped when it lands (%d points, all type 2)" % jp.size(),
		not jp.is_empty() and jp.all(func(p): return p["type"] == 2))

	vj.regrow_all()
	_chk(r, "Re-grow all releases every cell; the ring admits them again", vj._chunks.is_empty() and vj._stream_dirty)

	var p3 := PROFILE.duplicate(true)
	(p3["types"] as Array).append({"id": 3, "name": "Scrub", "style": "bushes", "density_per_m2": 0.01})
	_write_profile(p3)
	var ip: Image = vg.maps.edit_image(Vector2i(0, 0))
	ip.fill_rect(Rect2i(100, 100, 8, 8), Color8(3, 255, 128, 255))
	vg.maps.refresh(Vector2i(0, 0), Rect2i(100, 100, 8, 8))     # summarised for ids [1, 2]: type 3 not listed yet
	vg._scatter_cell(Vector2i(2, 2), vg._chunks, 64.0, false)  # a job in flight: its worker reads the old types
	vg.reload_types()
	var b3: Dictionary = vg.maps.blocks_in([Vector2i(0, 0)], Rect2(64, 64, 64, 64))
	_chk(r, "Reload types waits for the jobs in flight (final review #4), reads the profile again, re-summarises the held maps and releases every cell (%s, %s, %d jobs)" % [
		str(Array(vg._types.ids())), str(b3), vg._scatter_jobs.size()], Array(vg._types.ids()) == [1, 2, 3]
		and Array(vg.maps.type_ids) == [1, 2, 3] and b3.has(Vector2i(1, 1)) and Array(b3[Vector2i(1, 1)]).has(3)
		and vg._chunks.is_empty() and vg._scatter_jobs.is_empty())
	# ── the maps are configured with the preview off; an import's generation regrows ──
	var vo = Veg.new()
	vo.profile_path = PROFILE_PATH
	vo._load_profile()
	vo._editor = true
	var tt = FakeTerrain.new()
	tt.region_size = 256
	tt.data_directory = "user://wf_b2b_nowhere"
	vo.terrain_source = tt
	PreviewRes.visible = false
	vo._editor_tick()
	var configured_off: bool = vo.maps.configured() and vo.maps.directory == "user://wf_b2b_nowhere/forest"
	vo._scatter_cell(Vector2i(0, 0), vo._chunks, vo.chunk_size, false)
	var had: bool = vo._chunks.has(Vector2i(0, 0))
	vo.maps.generation += 1
	vo._editor_tick()
	PreviewRes.visible = true
	_chk(r, "with the preview off the maps are configured from the terrain (%s); an import's generation regrows every cell (%s)" % [
		vo.maps.directory, str([had, vo._chunks.size(), vo._seen_generation])],
		configured_off and had and vo._chunks.is_empty() and vo._seen_generation == 1)
	PreviewRes.visible = false
	vo._scatter_cell(Vector2i(0, 0), vo._chunks, vo.chunk_size, false)
	var had_t: bool = vo._chunks.has(Vector2i(0, 0))
	vo.trees.generation += 1
	vo._editor_tick()
	PreviewRes.visible = true
	_chk(r, "an import's new trees file regrows every cell too (%s)" % str([had_t, vo._chunks.size(), vo._seen_trees_generation]),
		had_t and vo._chunks.is_empty() and vo._seen_trees_generation == 1)
	vo.free()
	tt.free()
	# ── the forest's maps follow its scene's path ──
	var vn: Node3D = Veg.new()
	vn.force_editor = true
	vn.indirect_mmi = false
	vn.scene_file_path = "scene_e.tscn"
	tree.root.add_child(vn)
	await tree.process_frame
	var s1: String = vn.maps.scene()
	vn.scene_file_path = "scene_f.tscn"
	_chk(r, "the forest's maps and trees follow its scene's path, Save As included (%s -> %s)" % [s1, vn.maps.scene()],
		s1 == "scene_e.tscn" and vn.maps.scene() == "scene_f.tscn" and vn.trees.scene() == "scene_f.tscn")
	vn.queue_free()
	await tree.process_frame

	for n2 in [vg, fresh, vj]:
		n2._drain_scatter_jobs()
		n2.free()
	DirAccess.remove_absolute(ProjectSettings.globalize_path(PROFILE_PATH))
	VA.forget_packs()

	for n in [vs, game, ie, ig, we]:
		n.queue_free()
	ft.cam.free()
	ft.free()
	await tree.process_frame
	ForestConfigRes.use(null)
	ForestLogRes.sink = keep
	return r
