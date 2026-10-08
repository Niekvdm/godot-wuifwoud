# Copyright (c) 2026 Digitzone
# SPDX-License-Identifier: MIT
extends RefCounted
## Wuifwoud's own small parts: the ring order (ahead before behind, nearest first, the free radius
## ignores direction); the Terrain3D lookup by class name with its retry clock; the trunk pool taking its group,
## layer, mask and metadata from the config; the forest has a sea_level and no canopy switch.
##
## Run with a unit-suite runner: static run() returns {name, passed, failed, details}.

const Order := preload("res://addons/wuifwoud/forest_stream_order.gd")
const Terrain := preload("res://addons/wuifwoud/forest_terrain.gd")
const ForestConfigRes := preload("res://addons/wuifwoud/forest_config.gd")
const Veg := preload("res://addons/wuifwoud/forest_spawner.gd")
const ICON := "res://addons/wuifwoud/forest_spawner_icon.svg"
## Exports in metres whose names do not end in _m.
const METRES := ["chunk_size", "road_margin", "item_road_margin", "sea_level", "wind_strength", "clutter_road_margin"]


static func _chk(r: Dictionary, n: String, ok: bool) -> void:
	if ok:
		r.passed += 1
	else:
		r.failed += 1
		r.details.append("✗ " + n)


static func _exported(p: Dictionary) -> bool:
	return int(p["usage"]) & PROPERTY_USAGE_SCRIPT_VARIABLE != 0 and int(p["usage"]) & PROPERTY_USAGE_EDITOR != 0


static func _metres(n: String) -> bool:
	return n.ends_with("_m") or METRES.has(n)


## The script's exports that no @export_group precedes.
static func _ungrouped(s: Script) -> Array:
	var out: Array = []
	var group := ""
	for p in s.get_script_property_list():
		if int(p["usage"]) & PROPERTY_USAGE_GROUP != 0:
			group = String(p["name"])
		elif _exported(p) and group == "":
			out.append(p["name"])
	return out


static func run() -> Dictionary:
	var r := {"name": "forest_seams", "passed": 0, "failed": 0, "details": []}
	var c := PackedVector2Array([Vector2(0.0, -200.0), Vector2(0.0, 100.0), Vector2(0.0, 300.0), Vector2(0.0, 10.0)])
	var o := Order.order_indices(c, Vector2.ZERO, Vector2(0.0, 1.0))
	_chk(r, "nearest first, ahead before behind (%s)" % str(o), o == PackedInt32Array([3, 1, 2, 0]))
	var tree := Engine.get_main_loop() as SceneTree
	var host := Node3D.new()
	tree.root.add_child(host)
	Terrain.reset()
	_chk(r, "no terrain: null, and NaN heights", Terrain.find_cached(host) == null
		and is_nan(Terrain.height_at(null, Vector3.ZERO)))
	_chk(r, "a miss is retried later, not every call", Terrain.find_cached(host) == null)
	var t3: Node = ClassDB.instantiate("Terrain3D") if ClassDB.class_exists("Terrain3D") else null
	if t3 != null:
		host.add_child(t3)
	Terrain.reset()
	_chk(r, "Terrain3D found by class name from a sibling's subtree", t3 != null and Terrain.find_cached(host) == t3)
	host.queue_free()
	await tree.process_frame
	Terrain.reset()
	var cfg = ForestConfigRes.new()
	cfg.collision_group = &"wf_test_cars"
	cfg.trunk_layer = 4
	cfg.trunk_mask = 2
	cfg.trunk_meta = {&"k": 7}
	ForestConfigRes.use(cfg)
	var vs: Node3D = Veg.new()
	vs.indirect_mmi = false
	tree.root.add_child(vs)
	await tree.process_frame   # first frame: the batch root enters the tree (ledger T2 ruling)
	var body := vs.get_node_or_null(^"TreeCollision/TreeTrunks") as StaticBody3D
	_chk(r, "the trunk body keeps its name TreeTrunks", body != null)
	_chk(r, "and takes the config's layer, mask and metadata", body != null and body.collision_layer == 4
		and body.collision_mask == 2 and body.get_meta(&"k", 0) == 7)
	_chk(r, "the pool watches the config's group",
		vs.get_node_or_null(^"TreeCollision") != null and vs.get_node(^"TreeCollision").collision_group == &"wf_test_cars")
	_chk(r, "the forest has a sea level (0.6 m by default)", is_equal_approx(vs.sea_level, 0.6))
	_chk(r, "and no canopy switch any more", not ("canopy_overlay" in vs))
	vs.queue_free()
	await tree.process_frame
	ForestConfigRes.use(null)

	# The node in the inspector: every export in a group, a metre export says so, the class has its own icon.
	var ungrouped := _ungrouped(Veg)
	_chk(r, "every ForestSpawner export sits in an inspector group (ungrouped: %s)" % str(ungrouped), ungrouped.is_empty())
	var unsuffixed: Array = []
	for p in (Veg as Script).get_script_property_list():
		if _exported(p) and _metres(String(p["name"])) and not String(p["hint_string"]).contains("suffix:m"):
			unsuffixed.append(p["name"])
	_chk(r, "every metre export carries the m suffix (without: %s)" % str(unsuffixed), unsuffixed.is_empty())
	var icon := ""
	for gc in ProjectSettings.get_global_class_list():
		if String(gc["class"]) == "ForestSpawner":
			icon = String(gc["icon"])
	_chk(r, "ForestSpawner's icon is the addon's own (%s)" % icon, icon == ICON and FileAccess.file_exists(ICON))
	var cfg_ungrouped := _ungrouped(ForestConfigRes)
	_chk(r, "every ForestConfig export sits in an inspector group (ungrouped: %s)" % str(cfg_ungrouped),
		cfg_ungrouped.is_empty())

	# A cell waits for its centre region, unless that region is off the map: a 1024 m card cell over a small terrain's
	# corner has its centre where no region and no file is, and waiting for it would never place its cards. With the
	# disk fallback off the pump still knows which regions have a file (it only does not load them), and a terrain with
	# no data directory has no regions but the ones it holds.
	var ready_of := func(index, dir: String, disk_load := true, files_known := true) -> bool:
		var rs: Node3D = Veg.new()
		rs._pump = ForestHeightPump.new()
		rs._pump.configure(null, 64, 1.0, 16, dir, disk_load, files_known)
		rs._pump.loader = func(_p: String) -> Image: return null
		if index != null:
			rs._pump.set_disk_index(index)
		var ok: bool = rs._regions_ready(Vector2i(0, 0), 1024.0)
		rs._pump.collect(true)
		rs.free()
		return ok
	var centre_file := {Vector2i(8, 8): "res://addons/wuifwoud/tests/none/terrain3d_08_08.res"}
	var off_map: bool = ready_of.call({}, "")
	var on_disk: bool = ready_of.call(centre_file, "")
	var no_dir: bool = ready_of.call(null, "")
	var no_load_off: bool = ready_of.call({}, "", false)
	var no_load_on: bool = ready_of.call(centre_file, "", false)
	var unknown: bool = ready_of.call(null, "", true, false)
	_chk(r, "a cell whose centre region is off the map is ready, one whose centre is on disk waits for it, a terrain with "
		+ "an empty data directory has nothing on disk; with the disk fallback off the same; a terrain with no data "
		+ "directory at all cannot say, and waits (%s, %s, %s, %s, %s, %s)"
		% [off_map, on_disk, no_dir, no_load_off, no_load_on, unknown],
		off_map and not on_disk and no_dir and no_load_off and not no_load_on and not unknown)
	return r
