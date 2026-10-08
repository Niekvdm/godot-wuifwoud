# Copyright (c) 2026 Digitzone
# SPDX-License-Identifier: MIT
extends RefCounted
## The forest without its native core (a fresh clone that has not built the library, a platform it
## is not built for): a ring cell is registered empty at once and no job runs; the far forest starts nothing; one warning
## says why and where the library comes from; the maps still read, paint and save (no block grows anything); with the
## core back, the forest grows again.
##
## Run with a unit-suite runner: static run() returns {name, passed, failed, details}.

const Veg := preload("res://addons/wuifwoud/forest_spawner.gd")
const VA := preload("res://addons/wuifwoud/forest_assets.gd")
const PackOf := preload("res://addons/wuifwoud/tests/fixtures/pack_of.gd")
const NativeRes := preload("res://addons/wuifwoud/forest_native.gd")
const ForestConfigRes := preload("res://addons/wuifwoud/forest_config.gd")
const ForestLogRes := preload("res://addons/wuifwoud/forest_log.gd")
const FakeTerrain := preload("res://addons/wuifwoud/tests/fixtures/fake_terrain.gd")
const PROFILE_PATH := "user://wf_c1_no_native_profile.json"
const PROFILE := {
	"bands": {"coast_top_m": 10.0, "mid_top_m": 500.0, "treeline_m": 900.0, "treeline_keep": 0.35},
	"species": {"coast": [["W_Old", 1.0]], "mid": [["W_Old", 1.0]], "high": [["W_Old", 1.0]], "bush": [["W_Old", 1.0]]},
	"dead": {},
	"types": [{"id": 1, "name": "Wood", "style": "natural", "density_per_m2": 0.04}],
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


static func _map() -> Image:
	var img := Image.create_empty(256, 256, false, Image.FORMAT_RGBA8)
	img.fill(Color8(1, 255, 128, 0))
	return img


static func run() -> Dictionary:
	var r := {"name": "forest_no_native", "passed": 0, "failed": 0, "details": []}
	var keep: Callable = ForestLogRes.sink
	var cap := Capture.new()
	ForestLogRes.sink = cap.take
	ForestConfigRes.use(ForestConfigRes.new())
	VA.use_packs([PackOf.make({"species": {"W_Old": {"kind": "tree", "trunk_radius": 0.3}}})])
	var f := FileAccess.open(PROFILE_PATH, FileAccess.WRITE)
	f.store_string(JSON.stringify(PROFILE))
	f.close()
	NativeRes.force_absent = true
	NativeRes._warned = false
	var vs = Veg.new()
	vs.profile_path = PROFILE_PATH
	vs._load_profile()
	vs.chunk_size = 64.0
	vs.far_cell_regions = 1
	vs.maps.configure(256, 1.0, "")
	vs.maps.type_ids = vs._types.ids()
	vs.maps.editing = true
	vs.maps.adopt(Vector2i(0, 0), _map())
	vs._scatter_cell(Vector2i(0, 0), vs._chunks, 64.0, false)
	vs._scatter_cell(Vector2i(1, 0), vs._chunks, 64.0, false)
	var said := func() -> int:
		return cap.lines.filter(func(l): return l[0] == &"warn" and String(l[1]).contains("native core")).size()
	_chk(r, "a ring cell is registered empty at once, no job runs, and one warning says why and where the library comes from (%d)" % said.call(),
		bool(vs._chunks[Vector2i(0, 0)]["done"]) and bool(vs._chunks[Vector2i(1, 0)]["done"]) and vs._scatter_jobs.is_empty()
		and said.call() == 1 and cap.lines.any(func(l): return String(l[1]).contains("addons/wuifwoud/native")))
	var ft = FakeTerrain.new()
	ft.region_size = 256
	vs._ensure_far()
	vs._far.heights_of = func(_loc: Vector2i) -> PackedFloat32Array:
		var a := PackedFloat32Array()
		a.resize(16 * 16)
		a.fill(10.0)
		return a
	vs._far.build_now(ft)
	_chk(r, "the far forest starts nothing (%d cells), and says nothing more (%d)" % [int(vs._far.info()["cells"]), said.call()],
		not vs._far._started and int(vs._far.info()["cells"]) == 0 and said.call() == 1)
	var img: Image = vs.maps.edit_image(Vector2i(0, 0))
	img.fill_rect(Rect2i(0, 0, 8, 8), Color8(1, 128, 128, 255))
	vs.maps.refresh(Vector2i(0, 0), Rect2i(0, 0, 8, 8))
	_chk(r, "the maps still read and paint: held, editable, no error, and no block names a type (nothing can grow)",
		vs.maps.is_held(Vector2i(0, 0)) and img != null and vs.maps.errors.is_empty()
		and vs.maps.blocks_in([Vector2i(0, 0)], Rect2(0, 0, 256, 256)).is_empty())
	NativeRes.force_absent = false
	vs.maps.resummarise()
	vs._scatter_cell(Vector2i(2, 0), vs._chunks, 64.0, false)
	var back: bool = vs._scatter_jobs.size() == 1
	vs._collect_scatter(true)
	_chk(r, "the core back (after a restart): the forest grows again (%d points)" % Veg.point_count(vs._chunks[Vector2i(2, 0)]["pts"]),
		NativeRes.core() != null and back and Veg.point_count(vs._chunks[Vector2i(2, 0)]["pts"]) > 0)
	vs._far.drain()
	vs.free()
	ft.free()
	DirAccess.remove_absolute(ProjectSettings.globalize_path(PROFILE_PATH))
	NativeRes._warned = false
	ForestConfigRes.use(null)
	VA.forget_packs()
	ForestLogRes.sink = keep

	# The extension names a library for Linux, Windows and macOS, as native/SConstruct names them: one built per the
	# README on another platform loads without editing the extension file.
	var ext := ConfigFile.new()
	var ext_ok := ext.load("res://addons/wuifwoud/wuifwoud_core.gdextension") == OK
	var wrong: Array = []
	for t in ["debug", "release"]:
		for p in [["linux", ".x86_64", "linux.template_%s.x86_64.so"], ["windows", ".x86_64", "windows.template_%s.x86_64.dll"],
				["macos", "", "macos.template_%s.universal.dylib"]]:
			var want := "res://addons/wuifwoud/bin/libwuifwoud_core." + (p[2] as String) % t
			if String(ext.get_value("libraries", "%s.%s%s" % [p[0], t, p[1]], "")) != want:
				wrong.append("%s.%s" % [p[0], t])
	_chk(r, "the extension names the library for Linux, Windows and macOS (wrong or missing: %s)" % str(wrong),
		ext_ok and wrong.is_empty())
	return r
