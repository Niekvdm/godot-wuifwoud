# Copyright (c) 2026 Digitzone
# SPDX-License-Identifier: MIT
extends RefCounted
## The starter pack: it ships with the addon: 8 to 12 species, ids prefixed WW_, CC0 and credited;
## a project with nothing configured grows it and, naming no flora, its starter flora (three forest types); every
## species is built and current and loads without preparing, each tree with its far colour; the committed built/ is what
## the preparation makes now, byte for byte (the guard for a preparation changed without a PREP_VERSION
## bump); the addon alone grows a forest from it on a forest map.
##
## Run with a unit-suite runner: static run() returns {name, passed, failed, details}.

const VA := preload("res://addons/wuifwoud/forest_assets.gd")
const Veg := preload("res://addons/wuifwoud/forest_spawner.gd")
const BuildRes := preload("res://addons/wuifwoud/species/forest_pack_build.gd")
const WfPoints := preload("res://addons/wuifwoud/tests/fixtures/wf_points.gd")
const TreeFix := preload("res://addons/wuifwoud/tests/fixtures/tree_fixture.gd")


static func _chk(r: Dictionary, n: String, ok: bool) -> void:
	if ok:
		r.passed += 1
	else:
		r.failed += 1
		r.details.append("✗ " + n)


static func run() -> Dictionary:
	var r := {"name": "forest_starter", "passed": 0, "failed": 0, "details": []}
	var bare := ForestConfig.new()
	var path := bare.starter_pack_path()
	var starter = load(path) if ResourceLoader.exists(path) else null
	var n: int = starter.species.size() if starter is ForestSpeciesPack else 0
	_chk(r, "the starter pack ships with the addon: 8-12 species, ids prefixed WW_, credited CC0 (%d)" % n,
		starter is ForestSpeciesPack and n >= 8 and n <= 12
		and Array(starter.species).all(func(s): return String(s.id).begins_with("WW_"))
		and String(starter.credits).contains("CC0"))
	if not (starter is ForestSpeciesPack):
		return r
	var lic := path.get_base_dir().path_join("LICENSE")
	var lic_text := FileAccess.get_file_as_string(lic) if FileAccess.file_exists(lic) else ""
	_chk(r, "its LICENSE: CC0, Quaternius credited", lic_text.contains("CC0") and lic_text.contains("Quaternius"))
	var off := ForestConfig.new()
	off.disabled_packs = PackedStringArray([off.starter_pack_path()])
	_chk(r, "nothing configured: the starter grows; disabled: nothing does",
		bare.resolved_packs() == [starter] and off.resolved_packs().is_empty())

	ForestConfig.use(bare)
	var vp = Veg.new()
	vp.profile_path = bare.starter_flora_path()
	vp._load_profile()
	var pools: Dictionary = Veg._fallback_pools()["species"]
	_chk(r, "naming no flora, the starter flora is the fallback; its three types load (%s)" % str(vp._types.errors),
		pools.has("conifer") and pools.has("bush") and Array(vp._types.ids()) == [1, 2, 3] and vp._types.errors.is_empty())

	var not_built := []
	for row in BuildRes.states([starter]):
		for st in row["species"]:
			if st["state"] != "built":
				not_built.append("%s %s (%s)" % [st["id"], st["state"], st["why"]])
	_chk(r, "every starter species is built and current (%s)" % str(not_built), not_built.is_empty())
	var differ := []
	for s in starter.species:
		var id := String(s.id)
		var back = ResourceLoader.load(starter.built_dir().path_join(id + ".res"), "", ResourceLoader.CACHE_MODE_IGNORE)
		var q: Dictionary = back.to_prepared() if back != null else {}
		var p: Dictionary = VA.prepare_species_of(s)
		var same: bool = q.has("combined") and p.has("combined") and int(back.prep_version) == VA.PREP_VERSION \
			and TreeFix.mesh_bytes(p["combined"]) == TreeFix.mesh_bytes(q["combined"]) \
			and (p["levels"] as Array).size() == (q["levels"] as Array).size()
		if same:
			for k in (p["levels"] as Array).size():
				same = same and TreeFix.mesh_bytes(p["levels"][k]) == TreeFix.mesh_bytes(q["levels"][k])
			for key in ["foliage", "stamped", "crown_centre", "crown_radius", "spherify", "crown_uv", "aabb"]:
				same = same and p[key] == q[key]
		if not same:
			differ.append(id)
	_chk(r, "the committed built/ is what the preparation makes now, byte for byte (differ: %s)" % str(differ), differ.is_empty())

	VA.use_packs([starter])
	var n0: int = VA.prepared_count
	var coloured := true
	for s in starter.species:
		VA._species_materials(String(s.id))
		if String(s.kind) != "bush":
			var c: Array = VA.built_crown_colour(String(s.id))
			coloured = coloured and c.size() == 1 and c[0] is Color
	_chk(r, "they load without preparing (%d prepared); each tree has its far colour" % (VA.prepared_count - n0),
		VA.prepared_count == n0 and coloured)

	vp.maps.configure(256, 1.0, "")
	vp.maps.type_ids = vp._types.ids()
	var img := Image.create_empty(256, 256, false, Image.FORMAT_RGBA8)
	img.fill(Color8(1, 255, 128, 0))
	vp.maps.adopt(Vector2i(0, 0), img)
	var job: Dictionary = WfPoints.scatter(vp, Rect2(0, 0, 256, 256), [Vector2i(0, 0)], [], false)
	var pts: Array = WfPoints.decode(job["pts"], job.get("tables"))
	var inst: Array = WfPoints.instances(WfPoints.place(vp, pts, [Vector2i(0, 0), WfPoints.flat(256, 50.0)], 256))
	var ids := {}
	for i in inst:
		ids[String(i["mesh"])] = true
	_chk(r, "the addon alone grows a forest from it on a forest map (%d plants of %s)" % [inst.size(), str(ids.keys())],
		inst.size() > 100 and ids.keys().all(func(k): return String(k).begins_with("WW_")))
	vp.free()
	ForestConfig.use(null)
	VA.forget_packs()
	VA.reset()
	return r
