# Copyright (c) 2026 Digitzone
# SPDX-License-Identifier: MIT
extends RefCounted
## The Import dialog, headless through its context as Waailand's dialogs are tested: its empty
## states (no forest, a scene never saved, no imports_dir, an unreadable mapping file (never offered Start), and no
## mapping yet: Start writes one); the shell (the tabs, a change written and undone, Esc); the Source tab (the source
## and the terrain folder set, what was read, the texel size, the exclusions, the maps folder note); the rules through
## the inspector (the type, density on release, a value taken out, a type the profile lacks, Delete); the Run bar (what
## Run needs, Run, the progress and Cancel (the rules read-only meanwhile), the report, the overwrite question); the
## source's values and dragging them onto rules, back, and between rows. The sources listed, added and removed; a
## line's value its length, a point's its count; the tiles capped; a rule's spacing, clearance and
## species; read-only while the import runs; the report's single trees and rows; the profile's species and
## a malformed mapping named in the context.
##
## Run with a unit-suite runner: static run() returns {name, passed, failed, details}.

const DialogRes := preload("res://addons/wuifwoud/editor/forest_import_dialog.gd")
const MappingRes := preload("res://addons/wuifwoud/forest_mapping.gd")
const ImportRes := preload("res://addons/wuifwoud/forest_import.gd")
const KIT := "res://addons/terrain_3d_extended/src/ux_components.gd"
const Veg := preload("res://addons/wuifwoud/forest_spawner.gd")
const VA := preload("res://addons/wuifwoud/forest_assets.gd")
const PackOf := preload("res://addons/wuifwoud/tests/fixtures/pack_of.gd")
const ForestConfigRes := preload("res://addons/wuifwoud/forest_config.gd")
const FakeTerrain := preload("res://addons/wuifwoud/tests/fixtures/fake_terrain.gd")
const PROFILE_PATH := "user://wf_b2b_dialog_profile.json"
const CAT := {
	"default_pack": {"mesh_dir": "res://addons/wuifwoud/tests/fake/m/", "ext": ".glb",
		"tex_dir": "res://addons/wuifwoud/tests/fake/t/"},
	"packs": {},
	"species": {"W_Old": {"kind": "tree", "trunk_radius": 0.3, "crown": "conifer", "mature": true},
		"W_Bush": {"kind": "bush", "trunk_radius": 0.0, "crown": "broadleaf"}},
}
const PROFILE := {
	"bands": {"coast_top_m": 10.0, "mid_top_m": 500.0, "treeline_m": 900.0, "treeline_keep": 0.35},
	"species": {"coast": [["W_Old", 1.0]], "mid": [["W_Old", 1.0]], "high": [["W_Old", 1.0]], "bush": [["W_Bush", 1.0]]},
	"dead": {},
	"types": [{"id": 1, "name": "Wood", "style": "natural", "density_per_m2": 0.04},
		{"id": 2, "name": "Scrub", "style": "bushes", "density_per_m2": 0.01}],
}
const DIR := "user://wf_b2b_dialog"
const PATH := "user://wf_b2b_dialog/isle.json"
const TERRAIN := "user://wf_b2b_dialog/terrain"
const TYPES := [{"id": 1, "name": "Forest", "colour": Color(0.2, 0.6, 0.2)},
	{"id": 2, "name": "Grassland", "colour": Color(0.6, 0.8, 0.3)},
	{"id": 3, "name": "Park", "colour": Color(0.4, 0.7, 0.5)}]
const RULES3 := [{"match": {"kind": ["wood", "forest"]}, "type": 1}, {"match": {"kind": "park"}, "type": 3},
	{"match": {"kind": "garden", "class": "landuse"}, "type": 2}]


## Stands in for ForestSourceReader: its files and rules are set by the test.
class StubReader:
	var files := {}
	var rules := {}
	var ready := true
	var asked := 0

	func request(_m: Dictionary) -> void:
		asked += 1

	func poll() -> bool:
		return ready

	func is_ready() -> bool:
		return ready


## Stands in for ForestImportJob.
class StubJob:
	var running := true
	var report := {}
	var cancelled := false
	var p := {"phase": "regions", "done": 3, "total": 9}

	func is_running() -> bool:
		return running

	func progress() -> Dictionary:
		return p

	func cancel() -> void:
		cancelled = true


## The plugin's side of the context: Run, the job, the file picker.
class Bench:
	var kit: Object
	var reader := StubReader.new()
	var ran: Array = []
	var picks: Array = []
	var job = null
	var answer := ""

	func run_import(doc: Dictionary, discard: bool) -> String:
		ran.append([doc, discard])
		job = StubJob.new()
		return ""

	func job_of():
		return job

	func pick(title: String, filters: PackedStringArray, dir: bool, on_pick: Callable) -> void:
		picks.append([title, filters, dir])
		on_pick.call(answer)

	func dialog(mapping, extra := {}) -> Control:
		var d = DialogRes.new()
		var ctx := {"kit": kit, "mapping": mapping, "scene": "isle", "saved": true, "path": PATH,
			"load_error": "", "terrain_dir": TERRAIN, "maps_dir": TERRAIN.path_join("forest"), "types": TYPES,
			"reader": reader, "run": run_import, "job_of": job_of, "pick_file": pick}
		ctx.merge(extra, true)
		d.setup(ctx)
		return d


static func _chk(r: Dictionary, n: String, ok: bool) -> void:
	if ok:
		r.passed += 1
	else:
		r.failed += 1
		r.details.append("✗ " + n)


static func _sq(x0: float, z0: float, s: float) -> Array:
	return [[x0, z0], [x0 + s, z0], [x0 + s, z0 + s], [x0, z0 + s], [x0, z0]]


static func _feature(kind: String, id: int, coords: Array) -> Dictionary:
	return {"type": "Feature", "properties": {"kind": kind, "osm_id": id},
		"geometry": {"type": "Polygon", "coordinates": coords}}


static func _line_f(kind: String, id: int, coords: Array) -> Dictionary:
	return {"type": "Feature", "properties": {"kind": kind, "osm_id": id},
		"geometry": {"type": "LineString", "coordinates": coords}}


static func _point_f(kind: String, id: int, xz: Array) -> Dictionary:
	return {"type": "Feature", "properties": {"kind": kind, "osm_id": id},
		"geometry": {"type": "Point", "coordinates": xz}}


static func _mapping(rules: Array):
	var m = MappingRes.new()
	m.start(TERRAIN)
	m.doc["source"] = DIR.path_join("landuse.geojson")
	m.doc["rules"] = rules.duplicate(true)
	return m


## The mapping file as the dialog last wrote it.
static func _saved() -> Dictionary:
	var m = MappingRes.new()
	return m.doc if m.load_file(PATH) == OK else {}


static func _has_text(n: Node, text: String) -> bool:
	for c in n.find_children("*", "", true, false):
		if (c is Label and (c as Label).text.contains(text)) or (c is Button and (c as Button).text.contains(text)):
			return true
	return false


static func _key(d: Control, code: Key, ctrl := false, shift := false) -> void:
	var k := InputEventKey.new()
	k.keycode = code
	k.pressed = true
	k.ctrl_pressed = ctrl
	k.shift_pressed = shift
	d._input(k)


static func _clean() -> void:
	if DirAccess.dir_exists_absolute(DIR):
		for f in DirAccess.get_files_at(DIR):
			DirAccess.remove_absolute(ProjectSettings.globalize_path(DIR.path_join(f)))
		DirAccess.remove_absolute(ProjectSettings.globalize_path(DIR))


static func run() -> Dictionary:
	var r := {"name": "forest_import_dialog", "passed": 0, "failed": 0, "details": []}
	if not ResourceLoader.exists(KIT):
		r.details.append("Terrain3D Extended is not installed: the dialog is built with its kit")
		return r
	_clean()
	var b := Bench.new()
	b.kit = load(KIT)
	var feats := [_feature("wood", 1, [_sq(0, 0, 20)]), _feature("wood", 2, [_sq(30, 0, 10)]),
		_feature("pitch", 3, [_sq(0, 30, 10)])]
	b.reader.files = {"errors": [], "features": feats, "scan": ImportRes.scan_source(feats), "kinds": {"Polygon": 3},
		"world": true, "zones": [], "zone_counts": [], "meta": {"regions": [Vector2i(0, 0)], "region_size": 64,
		"vertex_spacing": 1.0}}
	b.reader.rules = {"shapes": [], "rule_m2": [500.0, 0.0, 0.0], "unmatched_m2": 250000.0}

	# ── the empty states ──
	var none = b.dialog(null, {"scene": ""})
	var unsaved = b.dialog(null, {"saved": false})
	var nodir = b.dialog(null, {"path": ""})
	var broken = b.dialog(null, {"load_error": "Parse error"})
	_chk(r, "the empty states: no forest, a scene never saved, no imports_dir, an unreadable mapping file: never offered Start",
		_has_text(none, "no forest node") and _has_text(unsaved, "Save the scene first") and _has_text(nodir, "imports_dir")
		and _has_text(broken, "could not be read") and broken.find_child("Start", true, false) == null
		and nodir.find_child("Start", true, false) == null)
	for d0 in [none, unsaved, nodir, broken]:
		d0.free()
	var fresh = b.dialog(null)
	(fresh.find_child("Start", true, false) as Button).pressed.emit()
	var started := _saved()
	_chk(r, "no mapping yet: Start writes one from the scene's terrain folder and opens the Source tab (%s)" % str(started),
		started.get("data_directory", "") == TERRAIN and fresh.tab == "source"
		and fresh.find_child("SourceTab", true, false) != null)
	fresh.free()

	# ── the shell ──
	var d = b.dialog(_mapping(RULES3))
	var tabs_ok: bool = d.find_child("TabRules", true, false) != null and d.find_child("TabSource", true, false) != null
	(d.find_child("NewRule", true, false) as Button).pressed.emit()
	var after_new: int = (_saved().get("rules", []) as Array).size()
	_key(d, KEY_Z, true)
	var after_undo: int = (_saved().get("rules", []) as Array).size()
	_key(d, KEY_Z, true, true)
	var closed := [0]
	d.closed.connect(func() -> void: closed[0] += 1)
	_key(d, KEY_ESCAPE)
	_chk(r, "the shell: two tabs; a change is one undo step, written each way; Esc closes (%s)" % str(
		[after_new, after_undo, d.mapping.rules().size(), closed[0]]),
		tabs_ok and after_new == 4 and after_undo == 3 and d.mapping.rules().size() == 4 and closed[0] == 1)

	# ── the Source tab ──
	var s = b.dialog(_mapping(RULES3), {"maps_dir": "user://elsewhere/forest"})
	s.tab = "source"
	s.rebuild()
	var asked0: int = b.reader.asked
	b.answer = DIR.path_join("lines.geojson")
	(s.find_child("AddSource", true, false) as Button).pressed.emit()
	var src_ok: bool = _saved().get("source") == [DIR.path_join("landuse.geojson"), DIR.path_join("lines.geojson")] \
		and b.reader.asked > asked0
	(s.find_child("Source0", true, false).get_node("Remove") as Button).pressed.emit()
	src_ok = src_ok and _saved().get("source") == DIR.path_join("lines.geojson")
	b.answer = DIR.path_join("terrain2")
	(s.find_child("TerrainPick", true, false) as Button).pressed.emit()
	var dir_ok: bool = _saved().get("data_directory", "") == DIR.path_join("terrain2") and bool(b.picks[-1][2])
	(s.find_child("TexelSize", true, false).get_node("Seg1") as Button).pressed.emit()
	var t_ok: bool = int(_saved().get("texel_vertices", 0)) == 2
	b.answer = DIR.path_join("zones.json")
	(s.find_child("AddExclusion", true, false) as Button).pressed.emit()
	var ex_add: bool = _saved().get("exclusions", []) == [DIR.path_join("zones.json")]
	(s.find_child("Exclusion0", true, false).get_node("Remove") as Button).pressed.emit()
	var ex_rm: bool = (_saved().get("exclusions", []) as Array).is_empty()
	_chk(r, "the Source tab: a source added and one removed (one is written as a path), the terrain folder picked (a folder), the reader asked again; the texel size; exclusions added and removed (%s)" % str(
		[src_ok, dir_ok, t_ok, ex_add, ex_rm]), src_ok and dir_ok and t_ok and ex_add and ex_rm)
	_chk(r, "the Source tab says what was read, what a texel costs, and that this forest reads its maps elsewhere (the maps folder note)",
		_has_text(s, "3 features") and s.find_child("TerrainInfo", true, false) != null
		and s.find_child("TexelCost", true, false) != null and s.find_child("MapsNote", true, false) != null)
	s.free()

	# ── the rules, through the inspector ──
	var q = b.dialog(_mapping(RULES3 + [{"match": {"kind": "scrub"}, "type": 7}]))
	q.select(0)
	(q.find_child("Type3", true, false) as Button).pressed.emit()
	var typed: bool = int(_saved()["rules"][0]["type"]) == 3
	var dens := q.find_child("Density", true, false).get_node("Slider") as HSlider
	dens.value = 0.5
	dens.drag_ended.emit(true)
	var dens_ok: bool = is_equal_approx(float(_saved()["rules"][0].get("density", 1.0)), 0.5)
	(q.find_child("Value_forest", true, false) as Button).pressed.emit()
	var val_ok: bool = _saved()["rules"][0]["match"]["kind"] == "wood"
	q.select(3)
	var red_ok: bool = _has_text(q.find_child("Rule3", true, false), "not in the profile") \
		and q.find_child("Type7", true, false) != null
	(q.find_child("DeleteRule", true, false) as Button).pressed.emit()
	_chk(r, "the inspector: the type picked, density on release, a value taken out, a type the profile lacks shown, Delete (%s)" % str(
		[typed, dens_ok, val_ok, red_ok, (_saved()["rules"] as Array).size(), q.selected]),
		typed and dens_ok and val_ok and red_ok and (_saved()["rules"] as Array).size() == 3 and q.selected == 2)
	q.free()

	# ── the Run bar ──
	var e = b.dialog(_mapping([]))
	_chk(r, "Run needs a valid mapping: what is missing is said and Run is off",
		e.find_child("RunErrors", true, false) != null and _has_text(e, "rules")
		and (e.find_child("Run", true, false) as Button).disabled)
	e.free()
	var g = b.dialog(_mapping(RULES3))
	(g.find_child("Run", true, false) as Button).pressed.emit()
	var started_run: bool = b.ran.size() == 1 and not bool(b.ran[0][1]) and g.busy()
	var shows: bool = g.find_child("Progress", true, false) != null and _has_text(g, "Region 3 of 9")
	var n_rules: int = g.mapping.rules().size()
	(g.find_child("NewRule", true, false) as Button).pressed.emit()
	var ro: bool = g.mapping.rules().size() == n_rules
	(g.find_child("Cancel", true, false) as Button).pressed.emit()
	_chk(r, "Run starts the import; its progress shows; the rules are read-only meanwhile; Cancel asks the job (%s)" % str(
		[started_run, shows, ro, b.job.cancelled]), started_run and shows and ro and b.job.cancelled)
	var shield_ok: bool = g.find_child("ReadOnly", true, false) != null and g.error.begins_with("Read-only")
	b.job.p = {"phase": "trees", "done": 0, "total": 0}
	_chk(r, "while the import runs the tabs are shielded and a change is refused, said; the trees phase is named (%s; %s)" % [g.error, g.phase_text()],
		shield_ok and g.phase_text() == "Single trees and rows")
	b.job.running = false
	b.job.report = {"ok": true, "errors": [], "cancelled": false, "written": [Vector2i(0, 0)], "kept_painted": [],
		"deleted": [], "deleted_no_region": [], "resampled": [], "painted_overwritten": [], "km2": {1: 0.25},
		"unmatched": {"kind=pitch": 0.0001}, "skipped": {},
		"items_written": {"rows": 52, "trees": 0}, "items_kept_edited": 1, "items_skipped_removed": 0,
		"items_deleted": 0, "rows_cut": 0, "items_dup_keys": 0, "items_invalid": {},
		"unmatched_lines": {"kind=fence": 1200.0}, "unmatched_points": {}, "trees_file": "written",
		"bytes": 1000, "ms": 950}
	g._process(0.0)
	_chk(r, "the run ends: its report (maps written, area by type, what no rule matched, the single trees and rows); the read-only note gone",
		not g.busy() and g.find_child("Report", true, false) != null and _has_text(g, "1 maps written")
		and _has_text(g, "Forest 0.250 km²") and _has_text(g, "kind=pitch") and _has_text(g, "52 rows and 0 trees written")
		and _has_text(g, "kind=fence 1.20 km") and g.error == "")
	(g.find_child("Overwrite", true, false).get_node("Toggle") as CheckBox).toggled.emit(true)
	(g.find_child("Run", true, false) as Button).pressed.emit()
	var asked_q: bool = g.find_child("Question", true, false) != null and b.ran.size() == 1
	(g.find_child("Question", true, false).find_child("Action", true, false) as Button).pressed.emit()
	_chk(r, "Overwrite painted texels asks first; Overwrite runs it with the paint discarded (%s)" % str(b.ran.size()),
		asked_q and b.ran.size() == 2 and bool(b.ran[1][1]))
	g.free()

	# ── the source's values, and dragging them ──
	b.job = null                                                    # the Run rows' import is over
	var v = b.dialog(_mapping(RULES3))
	var keys_box: Node = v.find_child("Keys", true, false)
	var key_names: Array = keys_box.get_children().map(func(c): return (c as Button).text) if keys_box != null else []
	_chk(r, "the Values column: the source's keys (an id-like one last and dim), the rules' key chosen, its values with their areas (%s)" % str(key_names),
		key_names == ["kind", "osm_id"] and (keys_box.get_child(1) as Button).modulate.a < 1.0 and v.current_key() == "kind"
		and v.find_child("Tile_pitch", true, false) != null
		and (v.find_child("Tile_wood", true, false) as Button).text.contains("500 m²"))
	(v.find_child("FilterUnmatched", true, false) as Button).pressed.emit()
	_chk(r, "Unmatched shows only the values no rule takes (%s)" % str(v.find_child("Tile_wood", true, false)),
		v.find_child("Tile_pitch", true, false) != null and v.find_child("Tile_wood", true, false) == null)
	v.set_filter("all")
	var tile = v.find_child("Tile_pitch", true, false)
	var handle = v.find_child("Handle1", true, false)
	var row1 = v.find_child("Rule1", true, false)
	_chk(r, "a value tile and a rule's handle carry {kind, id}; a rule row takes both, the Values column values only",
		tile._get_drag_data(Vector2.ZERO) == {"kind": "wuifwoud_value", "id": "pitch"}
		and handle._get_drag_data(Vector2.ZERO) == {"kind": "wuifwoud_rule", "id": "1"}
		and row1._can_drop_data(Vector2.ZERO, {"kind": "wuifwoud_value", "id": "x"})
		and row1._can_drop_data(Vector2.ZERO, {"kind": "wuifwoud_rule", "id": "0"})
		and not v.find_child("Values", true, false)._can_drop_data(Vector2.ZERO, {"kind": "wuifwoud_rule", "id": "0"}))
	v.find_child("Rule1", true, false)._drop_data(Vector2.ZERO, {"kind": "wuifwoud_value", "id": "pitch"})
	var into: bool = _saved()["rules"][1]["match"]["kind"] == ["park", "pitch"] and v.selected == 1
	v.find_child("NewRuleZone", true, false)._drop_data(Vector2.ZERO, {"kind": "wuifwoud_value", "id": "wood"})
	var made: bool = (_saved()["rules"] as Array).size() == 4 and _saved()["rules"][3]["match"] == {"kind": "wood"} \
		and _saved()["rules"][0]["match"]["kind"] == "forest" and int(_saved()["rules"][3]["type"]) == 1 and v.selected == 3
	_chk(r, "a value dropped on a rule joins it; on the new-rule zone it makes a rule and leaves the rule that had it alone (%s)" % str(
		[into, made]), into and made)
	v.find_child("Values", true, false)._drop_data(Vector2.ZERO, {"kind": "wuifwoud_value", "id": "forest"})
	var out_ok: bool = (_saved()["rules"][0]["match"] as Dictionary).is_empty()
	v.find_child("Rule1", true, false)._drop_data(Vector2.ZERO, {"kind": "wuifwoud_rule", "id": "3"})
	var moved_ok: bool = _saved()["rules"][1]["match"] == {"kind": "wood"} and v.selected == 1
	_chk(r, "a value dropped back on the Values column leaves its rule; a handle dropped on a row moves its rule there (%s)" % str(
		[out_ok, moved_ok]), out_ok and moved_ok)
	_chk(r, "No rule: how many values of the key no rule takes, and the area no rule matches (%s)" % v.find_child("Unmatched", true, false).text,
		_has_text(v.find_child("NoRule", true, false), "0.250 km²")
		and _has_text(v.find_child("NoRule", true, false), "0 values of kind"))
	v.free()
	# ── lines and points among the values; the tiles capped ──
	var lfeats := feats + [_line_f("tree_row", 7, [[0, 0], [2600, 0]]), _point_f("bench", 8, [1, 1]),
		_point_f("bench", 9, [2, 2]), _point_f("bench", 10, [3, 3])]
	b.reader.files["scan"] = ImportRes.scan_source(lfeats)
	b.reader.rules["rule_m"] = [0.0, 2600.0, 0.0]
	var lv = b.dialog(_mapping(RULES3))
	_chk(r, "a line's value shows its length, a point's its count; a rule shows the metres of rows it takes (%s; %s)" % [
		(lv.find_child("Tile_tree_row", true, false) as Button).text, (lv.find_child("Tile_bench", true, false) as Button).text],
		(lv.find_child("Tile_tree_row", true, false) as Button).text.contains("2.60 km")
		and (lv.find_child("Tile_bench", true, false) as Button).text.contains("3 points")
		and _has_text(lv.find_child("Rule1", true, false), "2.60 km of rows"))
	lv.free()
	var many := []
	for i in 250:
		many.append(_feature("k%03d" % i, 100 + i, [_sq(0, 0, 1 + i)]))
	b.reader.files["scan"] = ImportRes.scan_source(many)
	var mv = b.dialog(_mapping(RULES3))
	var tiles: Node = mv.find_child("Tiles", true, false)
	_chk(r, "a key with 250 values shows the 200 largest and says how many more (%d)" % tiles.get_child_count(),
		tiles.get_child_count() == 201 and (mv.find_child("TileMore", true, false) as Button).text.contains("50 more")
		and mv.find_child("Tile_k249", true, false) != null and mv.find_child("Tile_k000", true, false) == null)
	mv.free()
	b.reader.files["scan"] = ImportRes.scan_source(feats)
	b.reader.rules.erase("rule_m")
	var it = b.dialog(_mapping(RULES3), {"species": ["W_Bush", "W_Old"]})
	it.select(0)
	var sp_s := it.find_child("Spacing", true, false).get_node("Slider") as HSlider
	sp_s.value = 6.0
	sp_s.drag_ended.emit(true)
	var cl_s := it.find_child("Clearance", true, false).get_node("Slider") as HSlider
	cl_s.value = 4.0
	cl_s.drag_ended.emit(true)
	(it.find_child("Species_W_Old", true, false) as Button).pressed.emit()
	var item_rule: Dictionary = _saved()["rules"][0]
	(it.find_child("SpeciesBy", true, false) as Button).pressed.emit()
	(it.find_child("ClearDefault", true, false) as Button).pressed.emit()
	var after_rule: Dictionary = _saved()["rules"][0]
	_chk(r, "the inspector's single trees and rows: spacing and clearance on release, a species picked; By type and the kind's clearance take them out again (%s)" % str(item_rule),
		is_equal_approx(float(item_rule.get("spacing_m", 0.0)), 6.0) and is_equal_approx(float(item_rule.get("clear_m", 0.0)), 4.0)
		and item_rule.get("species", "") == "W_Old" and not after_rule.has("species") and not after_rule.has("clear_m"))
	it.free()

	# ── what the plugin opens the dialog with ──
	var cfg = ForestConfigRes.new()
	cfg.imports_dir = DIR.path_join("imports")
	cfg.disabled_packs = PackedStringArray([cfg.starter_pack_path()])   # no starter flora under the test profile
	ForestConfigRes.use(cfg)
	VA.use_packs([PackOf.make(CAT)])
	var pf := FileAccess.open(PROFILE_PATH, FileAccess.WRITE)
	pf.store_string(JSON.stringify(PROFILE))
	pf.close()
	var vp = Veg.new()
	vp.profile_path = PROFILE_PATH
	vp._load_profile()
	vp.maps.configure(64, 1.0, TERRAIN.path_join("forest"))
	vp.scene_file_path = "isle.tscn"
	var ft = FakeTerrain.new()
	ft.data_directory = TERRAIN
	vp.terrain_source = ft
	var c0: Dictionary = DialogRes.context_for(vp, b.kit)
	var mf = _mapping(RULES3)
	mf.save_file(DIR.path_join("imports/isle.json"))
	var c1: Dictionary = DialogRes.context_for(vp, b.kit)
	var bad := FileAccess.open(DIR.path_join("imports/isle.json"), FileAccess.WRITE)
	bad.store_string("{ broken")
	bad.close()
	var c2: Dictionary = DialogRes.context_for(vp, b.kit)
	_chk(r, "context_for: the scene's mapping path, its terrain and maps folders, the profile's types; a mapping read when it exists, a broken one named and not read (%s)" % str(
		[c0["path"], c1["mapping"] != null, c2["load_error"]]),
		c0["path"] == DIR.path_join("imports/isle.json") and c0["mapping"] == null and c0["scene"] == "isle"
		and c0["terrain_dir"] == TERRAIN and c0["maps_dir"] == TERRAIN.path_join("forest")
		and (c0["types"] as Array).map(func(t): return t["name"]) == ["Wood", "Scrub"]
		and c1["mapping"] != null and (c1["mapping"].rules() as Array).size() == 3
		and c2["mapping"] == null and String(c2["load_error"]) != "")
	vp.scene_file_path = ""
	var c3: Dictionary = DialogRes.context_for(vp, b.kit)
	cfg.imports_dir = ""
	vp.scene_file_path = "isle.tscn"
	var c4: Dictionary = DialogRes.context_for(vp, b.kit)
	_chk(r, "context_for: a scene never saved has no mapping path yet; nor does a config without imports_dir; no forest: no scene",
		not bool(c3["saved"]) and c3["path"] == "" and c4["path"] == "" and bool(c4["saved"])
		and DialogRes.context_for(null, b.kit)["scene"] == "")
	cfg.imports_dir = DIR.path_join("imports")
	var bad2 := FileAccess.open(DIR.path_join("imports/isle.json"), FileAccess.WRITE)
	bad2.store_string(JSON.stringify({"schema": "wuifwoud_import/1", "rules": {}}))
	bad2.close()
	var c5: Dictionary = DialogRes.context_for(vp, b.kit)
	_chk(r, "context_for: the profile's species for the inspector; a malformed mapping named by what is wrong, not read (%s)" % c5["load_error"],
		c5["mapping"] == null and String(c5["load_error"]).contains("'rules' is not a list")
		and c0["species"] == ["W_Bush", "W_Old"])
	vp.free()
	ft.free()
	ForestConfigRes.use(null)
	VA.forget_packs()
	DirAccess.remove_absolute(ProjectSettings.globalize_path(PROFILE_PATH))
	for f in DirAccess.get_files_at(DIR.path_join("imports")):
		DirAccess.remove_absolute(ProjectSettings.globalize_path(DIR.path_join("imports").path_join(f)))
	DirAccess.remove_absolute(ProjectSettings.globalize_path(DIR.path_join("imports")))
	_clean()
	return r
