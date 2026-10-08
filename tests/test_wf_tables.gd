# Copyright (c) 2026 Digitzone
# SPDX-License-Identifier: MIT
extends RefCounted
## The forest's native tables and road corridor: a spawner's tables from its profile: every pool
## species and every catalog species indexed once, sorted; the catalog's scalars, an unknown species a broadleaf tree;
## the profile's types, built once a profile and again for a new one; the packs resolved again (reload_species: a
## species added since reaches them); a malformed input refused with a reason. The road
## corridor: a point on a road blocked by the corridor's margin, a single tree's by its own; the distance to the
## corridor's edge; west and south of the origin too; a malformed array refused.
##
## Run with a unit-suite runner: static run() returns {name, passed, failed, details}.

const Veg := preload("res://addons/wuifwoud/forest_spawner.gd")
const VA := preload("res://addons/wuifwoud/forest_assets.gd")
const PackOf := preload("res://addons/wuifwoud/tests/fixtures/pack_of.gd")
const NativeRes := preload("res://addons/wuifwoud/forest_native.gd")
const ForestConfigRes := preload("res://addons/wuifwoud/forest_config.gd")
const ForestLogRes := preload("res://addons/wuifwoud/forest_log.gd")
const PROFILE_PATH := "user://wf_c1_tables_profile.json"
const CAT := {
	"default_pack": {"mesh_dir": "res://addons/wuifwoud/tests/fake/m/", "ext": ".glb",
		"tex_dir": "res://addons/wuifwoud/tests/fake/t/"},
	"packs": {},
	"species": {
		"W_Old": {"kind": "tree", "trunk_radius": 0.3, "crown": "conifer", "mature": true},
		"W_Young": {"kind": "tree", "trunk_radius": 0.1, "crown": "conifer", "young": true},
		"W_Bush": {"kind": "bush", "trunk_radius": 0.0, "crown": "broadleaf"},
		"W_Plum": {"kind": "tree", "trunk_radius": 0.2, "crown": "broadleaf"},
		"W_Spare": {"kind": "tree", "trunk_radius": 0.4, "crown": "broadleaf"},
	},
}
const PROFILE := {
	"bands": {"coast_top_m": 10.0, "mid_top_m": 500.0, "treeline_m": 900.0, "treeline_keep": 0.35},
	"species": {"coast": [["W_Old", 2.0], ["W_Young", 1.0]], "mid": [["W_Old", 1.0]], "high": [["W_Old", 1.0]],
		"bush": [["W_Bush", 1.0]], "orchard": [["W_Plum", 1.0]], "wild": [["W_Gone", 1.0]]},
	"dead": {"coast": ["W_Old"]},
	"types": [
		{"id": 1, "name": "Wood", "style": "natural", "density_per_m2": 0.04},
		{"id": 4, "name": "Orchard", "style": "grid", "pitch_m": 7.0},
		{"id": 7, "name": "Garden", "style": "mix", "density_per_m2": 0.01, "tree_pool": "wild"},
	],
}


class Capture:
	var lines: Array = []

	func take(level: StringName, msg: String) -> void:
		lines.append([level, msg])


static func _chk(r: Dictionary, n: String, ok: bool) -> void:
	if ok:
		r.passed += 1
	else:
		r.failed += 1
		r.details.append("✗ " + n)


static func run() -> Dictionary:
	var r := {"name": "wf_tables", "passed": 0, "failed": 0, "details": []}
	var core = NativeRes.core()
	_chk(r, "the native core is built (if not: build it, see the addon's README)", core != null)
	if core == null:
		return r
	var keep: Callable = ForestLogRes.sink
	var cap := Capture.new()
	ForestLogRes.sink = cap.take
	# No fallback flora: the pools are the test profile's alone (a config's default is the starter's flora).
	var cfg = ForestConfigRes.new()
	cfg.disabled_packs = PackedStringArray([cfg.starter_pack_path()])
	ForestConfigRes.use(cfg)
	VA.use_packs([PackOf.make(CAT)])
	var f := FileAccess.open(PROFILE_PATH, FileAccess.WRITE)
	f.store_string(JSON.stringify(PROFILE))
	f.close()
	var vp = Veg.new()
	vp.profile_path = PROFILE_PATH
	vp._load_profile()
	var t = vp._tables_now()
	_chk(r, "the tables' types are the profile's (%s; %s)" % [str(t.type_ids()) if t != null else "null",
		str(t.error()) if t != null else ""], t != null and str(t.error()) == "" and Array(t.type_ids()) == [1, 4, 7])
	var names: Array = Array(t.species_names()) if t != null else []
	_chk(r, "every pool species and every catalog species, sorted, each once (%s)" % str(names),
		names == ["W_Bush", "W_Gone", "W_Old", "W_Plum", "W_Spare", "W_Young"])
	var old: int = t.species_index("W_Old") if t != null else -1
	var gone: int = t.species_index("W_Gone") if t != null else -1
	_chk(r, "the catalog's scalars: a bush is a bush, a tree's trunk radius; a species the catalog lacks a tree at 0.26 m; a name not in the tables -1",
		t != null and t.is_bush(t.species_index("W_Bush")) and not t.is_bush(old)
		and is_equal_approx(t.trunk_radius(old), 0.3) and not t.is_bush(gone)
		and is_equal_approx(t.trunk_radius(gone), VA.DEFAULT_TRUNK_RADIUS) and t.species_index("W_Nope") == -1)
	var again = vp._tables_now()
	vp._load_profile()
	var renewed = vp._tables_now()
	_chk(r, "built once a profile: asked again, the same tables; the profile read again, new ones",
		is_same(again, t) and renewed != null and not is_same(renewed, t))
	# A pack added since the forest started (the editor's build landing and Re-grow): its species reach the tables.
	var more: Array[ForestSpeciesPack] = [PackOf.make(CAT),
		PackOf.make({"species": {"W_New": {"kind": "tree", "trunk_radius": 0.2, "crown": "broadleaf"}}})]
	cfg.packs = more
	var had := Array(vp._tables_now().species_names()).has("W_New")
	vp.reload_species()
	var t2 = vp._tables_now()
	_chk(r, "reload_species: the packs resolved again, a species added since reaches the tables (before: %s)" % str(had),
		not had and t2 != null and Array(t2.species_names()).has("W_New") and VA.has_species("W_New"))
	var one := {"species": PackedStringArray(["A"]), "bush": PackedByteArray([0]), "trunk": PackedFloat32Array([0.1])}
	var past := one.duplicate()
	past["types"] = [{"id": 1, "style": 0, "pitch": 5.0, "pools": {"bush": [PackedInt32Array([3]), PackedFloat32Array([1.0])]}}]
	var twice := one.duplicate()
	twice["types"] = [{"id": 2, "style": 1, "pitch": 5.0, "pools": {}}, {"id": 2, "style": 1, "pitch": 5.0, "pools": {}}]
	var nostyle := one.duplicate()
	nostyle["types"] = [{"id": 3, "style": 9, "pitch": 5.0, "pools": {}}]
	var bad := [core.make_tables(past), core.make_tables(twice), core.make_tables(nostyle)]
	_chk(r, "a malformed input is refused with a reason and has no types: a pool naming no species, an id twice, a style out of range (%s)" % str(bad.map(func(b): return b.error())),
		bad.all(func(b): return str(b.error()) != "" and b.type_ids().is_empty()))
	# ── the road corridor ──
	vp.road_margin = 3.0
	vp.item_road_margin = 0.0
	vp.set_road_segments(PackedFloat64Array([0.0, 0.0, 100.0, 0.0, 2.0, -300.0, -300.0, -300.0, -100.0, 3.0]))
	var rd = vp._roads
	_chk(r, "the corridor is built with the GDScript one: two roads, the forest's margin (%s)" % (str(rd.size()) if rd != null else "null"),
		rd != null and str(rd.error()) == "" and rd.size() == 2 and is_equal_approx(rd.get_margin(), 3.0))
	_chk(r, "a map tree's gap is the road's half width + road_margin; an item's + its own margin; west and south of the origin too",
		rd != null and rd.is_blocked(Vector2(50.0, 4.9), 3.0) and not rd.is_blocked(Vector2(50.0, 5.1), 3.0)
		and rd.is_blocked(Vector2(50.0, 1.9), 0.0) and not rd.is_blocked(Vector2(50.0, 2.1), 0.0)
		and rd.is_blocked(Vector2(-300.0, -200.0), 3.0) and rd.is_blocked(Vector2(-305.9, -200.0), 3.0)
		and not rd.is_blocked(Vector2(-306.1, -200.0), 3.0))
	_chk(r, "the distance to the corridor's edge: 10 m off a 2 m road with a 3 m margin is 5 m; no road near, INF (%s)" % (
		str(rd.edge_distance(Vector2(50.0, 10.0))) if rd != null else "null"),
		rd != null and is_equal_approx(rd.edge_distance(Vector2(50.0, 10.0)), 5.0)
		and is_inf(rd.edge_distance(Vector2(5000.0, 5000.0))))
	var short = core.make_roads(PackedFloat64Array([1.0, 2.0, 3.0]), 3.0)
	_chk(r, "a malformed array is refused with a reason (%s)" % str(short.error()), str(short.error()) != "" and short.size() == 0)
	vp.free()
	DirAccess.remove_absolute(ProjectSettings.globalize_path(PROFILE_PATH))
	ForestConfigRes.use(null)
	VA.forget_packs()
	ForestLogRes.sink = keep
	return r
