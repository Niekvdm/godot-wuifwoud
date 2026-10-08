# Copyright (c) 2026 Digitzone
# SPDX-License-Identifier: MIT
extends RefCounted
## Wuifwoud's species packs: a species' fields and files; a pack's built folder; which packs grow (the
## config's, then the pack addons' sets (sorted by folder, each in its own order), then the starter) less
## disabled_packs, each pack once; a set or pack that will not load is skipped and named.
##
## Run with a unit-suite runner: static run() returns {name, passed, failed, details}.

const ForestLogRes := preload("res://addons/wuifwoud/forest_log.gd")
const ROOT := "user://wf_d1_packs"
const VA := preload("res://addons/wuifwoud/forest_assets.gd")
const Veg := preload("res://addons/wuifwoud/forest_spawner.gd")


class Capture:
	var lines: Array = []

	func take(level: StringName, msg: String) -> void:
		lines.append([level, msg])


## A config whose starter pack is a test fixture's, not the addon's.
class Cfg extends ForestConfig:
	var starter := ""

	func starter_pack_path() -> String:
		return starter


static func _chk(r: Dictionary, n: String, ok: bool) -> void:
	if ok:
		r.passed += 1
	else:
		r.failed += 1
		r.details.append("✗ " + n)


static func _species(id: String) -> ForestSpecies:
	var s := ForestSpecies.new()
	s.id = id
	return s


## A pack of `ids` saved at `path`, loaded back (so it has its file).
static func _pack(path: String, nm: String, ids: Array) -> ForestSpeciesPack:
	var p := ForestSpeciesPack.new()
	p.name = nm
	var sp: Array[ForestSpecies] = []
	for id in ids:
		sp.append(_species(str(id)))
	p.species = sp
	DirAccess.make_dir_recursive_absolute(ProjectSettings.globalize_path(path.get_base_dir()))
	ResourceSaver.save(p, path)
	return load(path) as ForestSpeciesPack


## A pack addon's set at `<dir>/wuifwoud_packs.tres`.
static func _save_set(dir: String, nm: String, packs: Array) -> String:
	var s := ForestPackSet.new()
	s.name = nm
	var ps: Array[ForestSpeciesPack] = []
	for p in packs:
		ps.append(p)
	s.packs = ps
	DirAccess.make_dir_recursive_absolute(ProjectSettings.globalize_path(dir))
	var path := dir.path_join(ForestConfig.SET_FILE)
	ResourceSaver.save(s, path)
	return path


static func _rm_tree(dir: String) -> void:
	var abs := ProjectSettings.globalize_path(dir)
	var d := DirAccess.open(abs)
	if d == null:
		return
	for f in d.get_files():
		DirAccess.remove_absolute(abs.path_join(f))
	for sub in d.get_directories():
		_rm_tree(dir.path_join(sub))
	DirAccess.remove_absolute(abs)


static func _ids(packs: Array) -> Array:
	var out := []
	for p in packs:
		for s in p.species:
			out.append(String(s.id))
	return out


static func run() -> Dictionary:
	var r := {"name": "forest_packs", "passed": 0, "failed": 0, "details": []}
	var keep: Callable = ForestLogRes.sink
	var cap := Capture.new()
	ForestLogRes.sink = cap.take
	_rm_tree(ROOT)

	# ── a species ──
	var s := ForestSpecies.new()
	_chk(r, "a new species: a broadleaf tree, trunk 0.26 m, alpha cut 0.5, no age",
		s.kind == "tree" and s.crown == "broadleaf" and is_equal_approx(s.trunk_radius, 0.26)
		and is_equal_approx(s.alpha_cut, 0.5) and not s.mature and not s.young and s.foliage_materials.is_empty())
	s.mesh = "res://addons/wuifwoud/tests/fake/tree.glb"
	s.foliage_albedo = "res://addons/wuifwoud/tests/fake/leaf.png"
	_chk(r, "its files: the mesh and the textures it names, the empty ones left out (%s)" % str(s.files()),
		s.files() == PackedStringArray(["res://addons/wuifwoud/tests/fake/tree.glb", "res://addons/wuifwoud/tests/fake/leaf.png"]))
	var cfg_uid := ResourceUID.id_to_text(ResourceLoader.get_resource_uid("res://addons/wuifwoud/forest_config.gd"))
	_chk(r, "a uid:// path resolves to its file, an unknown one to \"\" (%s)" % cfg_uid,
		ForestSpecies.resolve(cfg_uid) == "res://addons/wuifwoud/forest_config.gd"
		and ForestSpecies.resolve("uid://b0000000000000") == "" and ForestSpecies.resolve("res://addons/wuifwoud/tests/fake/a.glb") == "res://addons/wuifwoud/tests/fake/a.glb")

	# ── a pack's built folder ──
	var listed := _pack(ROOT + "/listed/listed.tres", "Listed", ["L1"])
	_chk(r, "a pack's built folder sits beside its file; a pack made in code has none (%s)" % listed.built_dir(),
		listed.built_dir() == ROOT + "/listed/built" and ForestSpeciesPack.new().built_dir() == "")

	# ── which packs grow ──
	var addons := ROOT + "/addons"
	var b1 := _pack(addons + "/b_set/b1/b1.tres", "BS1", ["BS1"])
	var b2 := _pack(addons + "/b_set/b2/b2.tres", "BS2", ["BS2"])
	var b_set := _save_set(addons + "/b_set", "B set", [b1, b2])
	var a1 := _pack(addons + "/a_set/a1/a1.tres", "A1", ["A1"])
	var a_set := _save_set(addons + "/a_set", "", [a1])
	DirAccess.make_dir_recursive_absolute(ProjectSettings.globalize_path(addons + "/c_bad"))
	var bad := FileAccess.open(addons + "/c_bad/" + ForestConfig.SET_FILE, FileAccess.WRITE)
	bad.store_string("this is not a resource")
	bad.close()
	DirAccess.make_dir_recursive_absolute(ProjectSettings.globalize_path(addons + "/d_none"))
	var starter := _pack(ROOT + "/starter/starter.tres", "Starter", ["S1"])
	var cfg := Cfg.new()
	cfg.starter = starter.resource_path
	var lp: Array[ForestSpeciesPack] = [listed]
	cfg.packs = lp
	cap.lines.clear()
	var srcs := cfg.resolved_sources(addons)
	var bad_warn := cap.lines.filter(func(l): return l[0] == &"warn" and String(l[1]).contains("c_bad"))
	_chk(r, "the config's packs, the pack addons by folder (a set with no name takes its folder's), the starter (%s)"
		% str(srcs.map(func(x): return [x["name"], x["kind"]])),
		srcs.map(func(x): return x["name"]) == ["Listed", "a_set", "B set", "Starter trees"]
		and srcs.map(func(x): return x["kind"]) == ["project", "addon", "addon", "wuifwoud"]
		and _ids(cfg.resolved_packs(addons)) == ["L1", "A1", "BS1", "BS2", "S1"])
	_chk(r, "a set that will not load is skipped and named once (%d); a folder without a set is no source"
		% bad_warn.size(), bad_warn.size() == 1)
	_chk(r, "the discovered sets, sorted (%s)" % str(ForestConfig.discovered_set_paths(addons)),
		ForestConfig.discovered_set_paths(addons) == PackedStringArray([a_set, b_set,
			addons + "/c_bad/" + ForestConfig.SET_FILE]))

	# ── disabled_packs: a listed pack, a whole pack addon, one pack of an addon, the starter ──
	cfg.disabled_packs = PackedStringArray([listed.resource_path, a_set, b2.resource_path, starter.resource_path])
	_chk(r, "disabled: the listed pack, a whole addon, one pack of another, the starter; BS1 alone grows (%s)"
		% str(_ids(cfg.resolved_packs(addons))), _ids(cfg.resolved_packs(addons)) == ["BS1"])
	cfg.disabled_packs = PackedStringArray()

	# ── a pack counts once; an empty slot is skipped and said ──
	var twice: Array[ForestSpeciesPack] = [b1, null]
	cfg.packs = twice
	cap.lines.clear()
	var once := _ids(cfg.resolved_packs(addons))
	var slot := cap.lines.filter(func(l): return l[0] == &"warn" and String(l[1]).contains("empty pack slot"))
	_chk(r, "a pack the config lists and an addon ships counts once, where it comes first; an empty slot is said (%s, %d)"
		% [str(once), slot.size()], once == ["BS1", "A1", "BS2", "S1"] and slot.size() == 1)

	_assets(r, cap)
	_rm_tree(ROOT)
	ForestLogRes.sink = keep
	return r


## ForestAssets on packs: a species' own files and scalars; an id two packs hold (the first grows,
## said once); one no pack has (neutral defaults, said once); a profile names its unknown species at once; with no packs
## and no fallback flora a type's pools exist nowhere.
static func _assets(r: Dictionary, cap: Capture) -> void:
	var a := ForestSpeciesPack.new()
	a.name = "A"
	var t := _species("Aa_Tree")
	t.crown = "conifer"
	t.trunk_radius = 0.3
	t.mature = true
	t.alpha_cut = 0.4
	t.mesh = "res://addons/wuifwoud/tests/fake/aa/Aa_Tree.fbx"
	t.bark_albedo = "res://addons/wuifwoud/tests/fake/aat/bark.png"
	t.foliage_albedo = "res://addons/wuifwoud/tests/fake/aat/leaf.png"
	t.bark_normal = "res://addons/wuifwoud/tests/fake/aat/pbn.png"
	t.foliage_mtao = "res://addons/wuifwoud/tests/fake/aat/pfm.png"
	var odd := _species("Aa_Odd")
	odd.crown = "palm"
	odd.trunk_radius = 0.2
	odd.alpha_cut = 0.25
	odd.young = true
	var bush := _species("Aa_Bush")
	bush.kind = "bush"
	bush.trunk_radius = 0.0
	var al: Array[ForestSpecies] = [t, odd, bush]
	a.species = al
	var b := ForestSpeciesPack.new()
	b.name = "B"
	var dup := _species("Aa_Tree")
	dup.trunk_radius = 0.9
	var bl: Array[ForestSpecies] = [dup, _species("Bb_Tree")]
	b.species = bl
	cap.lines.clear()
	VA.use_packs([a, b])
	var clash := cap.lines.filter(func(l): return (l[0] == &"warn" and String(l[1]).contains("Aa_Tree")
		and String(l[1]).contains("two packs")))
	_chk(r, "an id two packs hold: the first pack's grows, said once (%d)" % clash.size(), clash.size() == 1
		and is_equal_approx(VA.trunk_radius_for("Aa_Tree"), 0.3) and VA.has_species("Bb_Tree"))
	_chk(r, "every species id, sorted (%s)" % str(VA.species_ids()),
		VA.species_ids() == PackedStringArray(["Aa_Bush", "Aa_Odd", "Aa_Tree", "Bb_Tree"]))
	_chk(r, "a species' mesh is its own; one no pack has has none",
		VA.mesh_path("Aa_Tree") == "res://addons/wuifwoud/tests/fake/aa/Aa_Tree.fbx" and VA.mesh_path("Zz") == "")
	_chk(r, "kind, trunk, crown, age", not VA.is_bush_mesh("Aa_Tree") and VA.is_bush_mesh("Aa_Bush")
		and VA._profile_of("Aa_Tree") == 1 and VA._profile_of("Aa_Odd") == 2 and VA._profile_of("Aa_Bush") == 0
		and VA.is_mature("Aa_Tree") and VA.is_young("Aa_Odd") and not VA.is_young("Aa_Tree"))
	_chk(r, "alpha cut: the species' own; 0.5 for one no pack has", is_equal_approx(VA.alpha_cut_for("Aa_Odd"), 0.25)
		and is_equal_approx(VA.alpha_cut_for("Aa_Tree"), 0.4) and is_equal_approx(VA.alpha_cut_for("Aa_Bush"), 0.5)
		and is_equal_approx(VA.alpha_cut_for("Zz_Tree"), 0.5))
	_chk(r, "the PBR maps: the species' own, each only when named (%s)" % str(VA._tex_set("Aa_Tree", false)),
		VA._tex_set("Aa_Tree", false) == {"normal": "res://addons/wuifwoud/tests/fake/aat/pbn.png"}
		and VA._tex_set("Aa_Tree", true) == {"mtao": "res://addons/wuifwoud/tests/fake/aat/pfm.png"}
		and VA._tex_set("Aa_Odd", false).is_empty() and VA._atlas_for("Aa_Odd", true) == null)
	cap.lines.clear()
	var unknown_ok: bool = not VA.is_bush_mesh("New_Mesh") and VA._profile_of("New_Mesh") == 0 \
		and is_equal_approx(VA.trunk_radius_for("New_Mesh"), VA.DEFAULT_TRUNK_RADIUS)
	var w := cap.lines.filter(func(l): return l[0] == &"warn" and String(l[1]).contains("New_Mesh"))
	_chk(r, "a species no pack has: neutral defaults, ONE warning however often it is asked (%d)" % w.size(),
		unknown_ok and w.size() == 1)
	# A profile names its unknown species AT ONCE, on the main thread, before any placement worker asks.
	var prof := "user://wf_test_profile.json"
	var pf := FileAccess.open(prof, FileAccess.WRITE)
	pf.store_string('{"species": {"mid": [["Ghost_Tree", 1.0]]}, "dead": {"mid": ["Ghost_Snag"]}}')
	pf.close()
	cap.lines.clear()
	var vp = Veg.new()
	vp.profile_path = prof
	vp._load_profile()
	var named := cap.lines.filter(func(l): return (l[0] == &"warn"
		and (String(l[1]).contains("Ghost_Tree") or String(l[1]).contains("Ghost_Snag"))))
	_chk(r, "loading a profile warns about its unknown species right away (%d of 2)" % named.size(), named.size() == 2)
	vp.free()
	DirAccess.remove_absolute(ProjectSettings.globalize_path(prof))
	# No packs and no fallback flora (the starter disabled, so its flora is not the fallback either).
	var bare := ForestConfig.new()
	bare.disabled_packs = PackedStringArray([bare.starter_pack_path()])
	ForestConfig.use(bare)
	VA.use_packs([])
	var prof2 := "user://wf_test_profile_types.json"
	var pf2 := FileAccess.open(prof2, FileAccess.WRITE)
	pf2.store_string('{"types": [{"id": 1, "name": "Wood", "style": "natural", "density_per_m2": 0.01}]}')
	pf2.close()
	cap.lines.clear()
	var vs = Veg.new()
	vs.profile_path = prof2
	vs._load_profile()
	var pool_errs := cap.lines.filter(func(l): return l[0] == &"error" and String(l[1]).contains("names pool"))
	_chk(r, "no packs and no fallback flora: the type's pools exist nowhere: an error (%d), no types, nothing placed"
		% pool_errs.size(), vs._types.ids().is_empty() and pool_errs.size() == 1)
	vs.free()
	DirAccess.remove_absolute(ProjectSettings.globalize_path(prof2))
	ForestConfig.use(null)
	VA.forget_packs()
	VA.reset()
