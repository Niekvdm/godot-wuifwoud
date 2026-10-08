# Copyright (c) 2026 Digitzone
# SPDX-License-Identifier: MIT
extends RefCounted
## The native place through the spawner's own job: below the sea line nothing;
## above the treeline a natural type's trees thin to treeline_keep and turn to scrub, its cards go, a grid's stay; the
## slope band thins, past the cut nothing, a single tree skips the thinning; a type the profile lacks grows nothing; a
## tree's trunk and raw crown in its trunk cell, a bush none; render buckets, trunk and card cells west and south of the
## origin; a cell over a held and a missing region places what has ground; no ground or inconsistent points refused with
## a reason; the same job the same bytes.
##
## Run with a unit-suite runner: static run() returns {name, passed, failed, details}.

const Veg := preload("res://addons/wuifwoud/forest_spawner.gd")
const VA := preload("res://addons/wuifwoud/forest_assets.gd")
const PackOf := preload("res://addons/wuifwoud/tests/fixtures/pack_of.gd")
const NativeRes := preload("res://addons/wuifwoud/forest_native.gd")
const WfPoints := preload("res://addons/wuifwoud/tests/fixtures/wf_points.gd")
const ForestConfigRes := preload("res://addons/wuifwoud/forest_config.gd")
const ForestLogRes := preload("res://addons/wuifwoud/forest_log.gd")
const PROFILE_PATH := "user://wf_c1_place_profile.json"
const CAT := {
	"default_pack": {"mesh_dir": "res://addons/wuifwoud/tests/fake/m/", "ext": ".glb",
		"tex_dir": "res://addons/wuifwoud/tests/fake/t/"},
	"packs": {},
	"species": {
		"W_Old": {"kind": "tree", "trunk_radius": 0.3, "crown": "conifer", "mature": true},
		"W_Young": {"kind": "tree", "trunk_radius": 0.1, "crown": "conifer", "young": true},
		"W_Bush": {"kind": "bush", "trunk_radius": 0.0, "crown": "broadleaf"},
		"W_Plum": {"kind": "tree", "trunk_radius": 0.2, "crown": "broadleaf"},
	},
}
const PROFILE := {
	"bands": {"coast_top_m": 10.0, "mid_top_m": 500.0, "treeline_m": 900.0, "treeline_keep": 0.35},
	"species": {"coast": [["W_Old", 1.0], ["W_Young", 1.0]], "mid": [["W_Old", 1.0], ["W_Young", 1.0]],
		"high": [["W_Old", 1.0], ["W_Young", 1.0]], "bush": [["W_Bush", 1.0]], "orchard": [["W_Plum", 1.0]]},
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


static func _chk(r: Dictionary, n: String, ok: bool) -> void:
	if ok:
		r.passed += 1
	else:
		r.failed += 1
		r.details.append("✗ " + n)


## n points of `base` at (50, 50) (or at `at`), seeds 1000 + k.
static func _many(n: int, base: Dictionary, at := Vector2(50.0, 50.0)) -> Array:
	var out := []
	for k in n:
		var pt := base.duplicate()
		pt["p"] = at
		pt["seed"] = 1000 + k
		out.append(pt)
	return out


## One 64 m region at (0, 0) of `h_of(x, z)`.
static func _ground(h_of: Callable) -> Array:
	return [Vector2i(0, 0), WfPoints.region(64, h_of)]


static func _flat(h: float) -> Array:
	return [Vector2i(0, 0), WfPoints.flat(64, h)]


static func _meshes(job: Dictionary) -> Array:
	return WfPoints.instances(job).map(func(i): return i["mesh"])


static func run() -> Dictionary:
	var r := {"name": "wf_place", "passed": 0, "failed": 0, "details": []}
	var core = NativeRes.core()
	_chk(r, "the native core is built (if not: build it, see the addon's README)", core != null)
	if core == null:
		return r
	var keep: Callable = ForestLogRes.sink
	var cap := Capture.new()
	ForestLogRes.sink = cap.take
	ForestConfigRes.use(ForestConfigRes.new())   # no fallback flora: the pools are the test profile's alone
	VA.use_packs([PackOf.make(CAT)])
	var f := FileAccess.open(PROFILE_PATH, FileAccess.WRITE)
	f.store_string(JSON.stringify(PROFILE))
	f.close()
	var vp = Veg.new()
	vp.profile_path = PROFILE_PATH
	vp._load_profile()
	var tree := {"type": 1, "role": "tree", "age": 0.0}
	var card := {"type": 1, "role": "bb", "mrole": "tree", "age": 0.0}
	var orchard := {"type": 2, "role": "tree", "age": 0.0}
	var item := {"type": 1, "role": "tree", "age": 0.0, "item": true, "species": ""}

	var wet := _meshes(WfPoints.place(vp, _many(20, tree), _flat(vp.sea_level - 0.1), 64))
	var dry := _meshes(WfPoints.place(vp, _many(20, tree), _flat(vp.sea_level + 0.4), 64))
	_chk(r, "the sea line: below it nothing grows, just above it every tree (%d, %d)" % [wet.size(), dry.size()],
		wet.is_empty() and dry.size() == 20)
	# The tint (the GDScript _tint's, now the native place's): near white, its green the brightness 0.82-1.12, red and
	# blue a warm shift of at most 0.07 either way, and it differs from seed to seed.
	var tints: Array = WfPoints.instances(WfPoints.place(vp, _many(20, tree), _flat(vp.sea_level + 0.4), 64)).map(
		func(i): return i["color"])
	_chk(r, "a tree's tint: near white, green 0.82-1.12, a warm shift of at most 0.07, per seed (%s)" % str(tints.slice(0, 3)),
		tints.size() == 20 and tints.all(func(c: Color): return (c.g >= 0.82 - 1.0e-4 and c.g <= 1.12 + 1.0e-4
			and absf(c.r - c.g) <= 0.07 + 1.0e-4 and absf(c.b - c.g) <= 0.07 + 1.0e-4
			and is_equal_approx(c.r - c.g, c.g - c.b) and is_equal_approx(c.a, 1.0)))
		and tints.any(func(c: Color): return not c.is_equal_approx(tints[0])))

	var high_trees := _meshes(WfPoints.place(vp, _many(400, tree), _flat(950.0), 64))
	var high_cards := _meshes(WfPoints.place(vp, _many(400, card), _flat(950.0), 64))
	var high_orch := _meshes(WfPoints.place(vp, _many(400, orchard), _flat(950.0), 64))
	_chk(r, "above the treeline a natural type's trees thin to treeline_keep (0.35) and turn to scrub, its cards go; a grid's stay (%d, %d, %d)" % [
		high_trees.size(), high_cards.size(), high_orch.size()],
		absf(float(high_trees.size()) / 400.0 - 0.35) < 0.1 and high_trees.all(func(m): return m == "W_Bush")
		and high_cards.is_empty() and high_orch.size() == 400 and high_orch.all(func(m): return m == "W_Plum"))

	var band := _ground(func(x: float, _z: float) -> float: return 100.0 + (x - 50.0))
	var cliff := _ground(func(x: float, _z: float) -> float: return 100.0 + 1.3 * (x - 50.0))
	var on_band := _meshes(WfPoints.place(vp, _many(400, tree), band, 64)).size()
	var on_cliff := _meshes(WfPoints.place(vp, _many(400, tree), cliff, 64)).size()
	var items_band := _meshes(WfPoints.place(vp, _many(400, item), band, 64)).size()
	var items_cliff := _meshes(WfPoints.place(vp, _many(400, item), cliff, 64)).size()
	_chk(r, "the slope: rise/run 1.0 keeps about half (the 0.8-1.2 band), past 1.2 nothing; a single tree skips the thinning, not the cut (%d, %d, %d, %d)" % [
		on_band, on_cliff, items_band, items_cliff],
		absf(float(on_band) / 400.0 - 0.5) < 0.1 and on_cliff == 0 and items_band == 400 and items_cliff == 0)

	var stray := tree.duplicate()
	stray["type"] = 9
	_chk(r, "a type the profile lacks grows nothing", _meshes(WfPoints.place(vp, _many(20, stray), _flat(50.0), 64)).is_empty())

	var old := item.duplicate()
	old["species"] = "W_Old"
	var bush := item.duplicate()
	bush["species"] = "W_Bush"
	var tj: Dictionary = WfPoints.place(vp, _many(1, old, Vector2(10.0, 12.0)) + _many(1, bush, Vector2(20.0, 22.0)), _flat(20.0), 64)
	var inst: Array = WfPoints.instances(tj)
	var scl: float = (inst[0]["xf"] as Transform3D).basis.get_scale().x if not inst.is_empty() else 0.0
	var trunk: PackedFloat32Array = (tj["trunks"] as Dictionary).get(Vector2i(0, 0), PackedFloat32Array())
	var crown: PackedFloat32Array = ((tj["crowns"] as Dictionary).get(Vector2i(0, 0), {}) as Dictionary).get("W_Old", PackedFloat32Array())
	_chk(r, "a pinned species grows; a tree's trunk (x, ground, z, radius x scale) and raw crown (x, z, ground, scale) in its trunk cell, a bush none (%s; %s)" % [
		str(trunk), str(crown)],
		inst.size() == 2 and inst[0]["mesh"] == "W_Old" and inst[1]["mesh"] == "W_Bush" and trunk.size() == 4
		and is_equal_approx(trunk[0], 10.0) and is_equal_approx(trunk[1], 20.0) and is_equal_approx(trunk[2], 12.0)
		and absf(trunk[3] - 0.3 * scl) < 1.0e-4 and crown.size() == 4 and absf(crown[3] - scl) < 1.0e-4
		and is_equal_approx(((inst[0]["xf"] as Transform3D).origin.y), 19.95))

	var west := [Vector2i(-1, -1), WfPoints.flat(64, 30.0), Vector2i(0, 0), WfPoints.flat(64, 30.0)]
	var oldcard := old.duplicate()
	oldcard["role"] = "bb"
	oldcard["mrole"] = "tree"
	var wj: Dictionary = WfPoints.place(vp, _many(1, old, Vector2(-10.0, -10.0)) + _many(1, old, Vector2(10.0, 10.0))
		+ _many(1, oldcard, Vector2(-10.0, -10.0)), west, 64)
	_chk(r, "west and south of the origin: buckets, trunk cells and card cells floor, never truncate (%s; %s; %s)" % [
		str((wj["species"] as Dictionary).keys()), str((wj["trunks"] as Dictionary).keys()), str((wj["bbs"] as Dictionary).keys())],
		(wj["species"] as Dictionary).keys() == ["-1,-1/W_Old", "0,0/W_Old"]
		and (wj["trunks"] as Dictionary).keys() == [Vector2i(-1, -1), Vector2i(0, 0)]
		and (wj["bbs"] as Dictionary).keys() == [Vector2i(-1, -1)])

	# Region (0, 0) held, (1, 0) missing: x 30 grows; x 63 sits on a vertex (its missing neighbour carries no weight) and
	# grows, its slope unknown; x 63.5 needs a missing vertex; x 70 has no ground.
	var half := [Vector2i(0, 0), WfPoints.flat(64, 30.0)]
	var hp: Array = []
	for x in [30.0, 63.0, 63.5, 70.0]:
		hp.append_array(_many(1, old, Vector2(x, 20.0)))
	var hx: Array = WfPoints.instances(WfPoints.place(vp, hp, half, 64)).map(func(i): return (i["xf"] as Transform3D).origin.x)
	_chk(r, "a cell over a held and a missing region places what has ground, the rest dropped (%s)" % str(hx),
		hx.size() == 2 and hx.has(30.0) and hx.has(63.0))

	var none: Dictionary = WfPoints.place(vp, _many(5, tree), [], 64)
	var odd: Dictionary = vp._place_job(WfPoints.encode(_many(5, tree), vp._tables_now()), _flat(50.0), 64, 1.0)
	(odd["pts"] as Dictionary)["n"] = 6
	vp._run_place_job_body(odd)
	_chk(r, "no ground, or points whose arrays disagree: nothing placed, and why (%s; %s)" % [str(none.get("error", "")),
		str(odd.get("error", ""))],
		str(none.get("error", "")) != "" and str(odd.get("error", "")) != "" and WfPoints.instances(none).is_empty()
		and WfPoints.instances(odd).is_empty())

	var a: Dictionary = WfPoints.place(vp, _many(300, tree), band, 64)
	var b: Dictionary = WfPoints.place(vp, _many(300, tree), band, 64)
	_chk(r, "the same job twice: the same bytes",
		var_to_bytes([a["species"], a["bbs"], a["trunks"], a["crowns"]]) == var_to_bytes([b["species"], b["bbs"], b["trunks"], b["crowns"]]))

	# Each slot carries its level-1 clusters for the GPU arena: the walk over its own buffer, one cluster
	# every 256 instances, the species' reach not in it (the install adds it).
	var spread := []
	for k in 1600:
		var tp := tree.duplicate()
		tp["p"] = Vector2(2.0 + float(k % 40) * 1.5, 2.0 + float(k / 40) * 1.5)
		tp["seed"] = 5000 + k
		spread.append(tp)
		var cp := card.duplicate()
		cp["p"] = tp["p"]
		cp["seed"] = 9000 + k
		spread.append(cp)
	var cj: Dictionary = WfPoints.place(vp, spread, _flat(20.0), 64)
	var cslots: Array = (cj["species"] as Dictionary).values()
	for cell in cj["bbs"]:
		cslots.append_array((cj["bbs"][cell] as Dictionary).values())
	var cl_ok := cslots.size() >= 2
	var big := false
	for cs in cslots:
		var cn := int(cs["n"])
		var cc: PackedFloat32Array = cs.get("clusters", PackedFloat32Array())
		big = big or cn > 256
		cl_ok = cl_ok and cc.size() == ceili(float(cn) / 256.0) * 6 and cc == core.plan_walk(cs["buf"], cn, 16, 0.0)
	_chk(r, "every mesh and card slot carries its clusters: the walk over its own buffer, a cluster every 256 instances, no reach (%d slots)" % cslots.size(),
		cl_ok and big)
	# A Dictionary that grows on one thread while another reads it is a data race (the main thread reads the job's
	# "task" every tick while the worker runs), so every key the worker writes is in the job before it is submitted.
	var kj: Dictionary = vp._place_job(WfPoints.encode(_many(30, tree), vp._tables_now()), band, 64, 1.0)
	var kbefore := kj.keys()
	vp._run_place_job(kj)
	var kadded := kj.keys().filter(func(k): return not (k in kbefore))
	_chk(r, "a place job holds every key its worker writes before it is submitted, the task's too (added: %s)" % str(kadded),
		kadded.is_empty() and kbefore.has("task") and WfPoints.instances(kj).size() > 0)

	vp.free()
	DirAccess.remove_absolute(ProjectSettings.globalize_path(PROFILE_PATH))
	ForestConfigRes.use(null)
	VA.forget_packs()
	ForestLogRes.sink = keep
	return r
