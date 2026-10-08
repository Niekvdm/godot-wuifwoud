# Copyright (c) 2026 Digitzone
# SPDX-License-Identifier: MIT
extends RefCounted
## The forest's wind and actor inputs. wind_targets is pinned at four speeds to the numbers
## _read_wind_targets gave before the extraction (strength 0.35: amplitude, sway rate, gust-front speed, gust
## depth). set_wind refuses a degenerate direction and reads a negative or NaN speed as calm. set_push_points pads
## to and truncates at PUSH_SLOTS. set_washes keeps at most MAX_WASHES.
##
## Run with a unit-suite runner: static run() returns {name, passed, failed, details}.

const Veg := preload("res://addons/wuifwoud/forest_spawner.gd")
const VA := preload("res://addons/wuifwoud/forest_assets.gd")
const ForestConfigRes := preload("res://addons/wuifwoud/forest_config.gd")
const COMMON_INC := "res://addons/wuifwoud/shaders/wf_common.gdshaderinc"


static func _chk(r: Dictionary, n: String, ok: bool) -> void:
	if ok:
		r.passed += 1
	else:
		r.failed += 1
		r.details.append("✗ " + n)


static func _near(a: float, b: float) -> bool:
	return absf(a - b) < 1e-5


static func run() -> Dictionary:
	var r := {"name": "forest_wind", "passed": 0, "failed": 0, "details": []}
	# [speed, dir, amp, rate, front, depth]
	var rows := [
		[0.0, Vector2(1.0, 0.3), 0.0875, 0.75, 2.0, 0.65],
		[6.0, Vector2(0.0, 1.0), 0.2625, 1.0833333, 6.0, 0.5],
		[12.0, Vector2(0.0, 1.0), 0.4375, 1.4166667, 12.0, 0.35],
		[30.0, Vector2(0.0, 1.0), 0.595, 1.9, 30.0, 0.25],
	]
	for row in rows:
		var t: Dictionary = Veg.wind_targets(row[1], row[0], 0.35)
		_chk(r, "speed %.0f: amp %.4f rate %.4f front %.1f depth %.3f" % [row[0], t.amp, t.rate, t.front, t.depth],
			_near(t.amp, row[2]) and _near(t.rate, row[3]) and _near(t.front, row[4]) and _near(t.depth, row[5])
			and (t.dir as Vector2).is_equal_approx((row[1] as Vector2).normalized()))
	var vs = Veg.new()
	vs.set_wind(Vector2(0.0, 2.0), 5.0)
	vs.set_wind(Vector2.ZERO, 3.0)
	_chk(r, "a zero direction keeps the last one", vs._fed_wind_dir == Vector2(0.0, 2.0) and vs._fed_wind_speed == 3.0)
	vs.set_wind(Vector2(1.0, 0.0), NAN)
	_chk(r, "a NaN speed reads as calm", vs._fed_wind_speed == 0.0)
	vs.set_wind(Vector2(1.0, 0.0), -4.0)
	_chk(r, "a negative speed reads as calm", vs._fed_wind_speed == 0.0)
	vs.set_push_points(PackedVector4Array([Vector4(1.0, 2.0, 3.0, 4.0)]))
	_chk(r, "one push point pads to PUSH_SLOTS with empty slots", vs._fed_push.size() == Veg.PUSH_SLOTS
		and vs._fed_push[0] == Vector4(1.0, 2.0, 3.0, 4.0) and vs._fed_push[1] == Vector4.ZERO)
	var six := PackedVector4Array()
	for i in 6:
		six.append(Vector4(float(i), 0.0, 1.0, 1.0))
	vs.set_push_points(six)
	_chk(r, "more than PUSH_SLOTS keeps the first PUSH_SLOTS (nearest first)",
		vs._fed_push.size() == Veg.PUSH_SLOTS and vs._fed_push[Veg.PUSH_SLOTS - 1].x == float(Veg.PUSH_SLOTS - 1))
	vs.set_washes(six)
	_chk(r, "at most MAX_WASHES washes (%d)" % vs._fed_washes.size(), vs._fed_washes.size() == Veg.MAX_WASHES)
	vs.free()
	# Fed values take effect when they ARRIVE, not on the forest's own 10 Hz clock: two clocks out of step would add up
	# to 100 ms to the push lag. set_wind derives the sway targets at once; set_push_points reaches the materials on
	# the next frame even when the forest's clock is far from due.
	var tree := Engine.get_main_loop() as SceneTree
	ForestConfigRes.use(ForestConfigRes.new())   # no feeders: nothing else may feed this forest
	var vf: Node3D = Veg.new()
	vf.indirect_mmi = false
	vf.tree_collision = false
	tree.root.add_child(vf)
	await tree.process_frame
	vf.set_wind(Vector2(0.0, 1.0), 12.0)
	_chk(r, "set_wind derives the sway targets at once (amp %.4f, rate %.4f)" % [vf._wind_amp_t, vf._wind_rate_t],
		_near(vf._wind_amp_t, 0.4375) and _near(vf._wind_rate_t, 1.4166667))
	var mat := ShaderMaterial.new()
	VA._live_materials.append(mat)
	vf._wind_poll = 10.0
	vf.set_push_points(PackedVector4Array([Vector4(5.0, 6.0, 3.2, 0.45)]))
	await tree.process_frame
	var got = mat.get_shader_parameter("wind_push")
	_chk(r, "pushed points reach the materials on the next frame (%s)" % str(got),
		got is PackedVector4Array and (got as PackedVector4Array).size() == Veg.PUSH_SLOTS
		and (got as PackedVector4Array)[0] == Vector4(5.0, 6.0, 3.2, 0.45))
	VA._live_materials.erase(mat)
	vf.queue_free()
	await tree.process_frame
	ForestConfigRes.use(null)

	# The wind globals are the addon's own names, the shared include declares each one, and each exists before a
	# tree shader is parsed (a global missing then is a compile error: every tree draws as the error shader).
	var keys: Array = VA.WIND_GLOBALS.keys()
	_chk(r, "the wind globals are the addon's own, wuifwoud_* (%s)" % str(keys),
		keys.all(func(k): return String(k).begins_with("wuifwoud_")))
	var inc := FileAccess.get_file_as_string(COMMON_INC)
	_chk(r, "the shared include declares each wind global (%s)" % COMMON_INC,
		inc != "" and keys.all(func(k): return inc.contains(" %s;" % k) and inc.contains("global uniform")))
	VA.ensure_wind_globals()
	var listed := Array(RenderingServer.global_shader_parameter_get_list()).map(func(n): return String(n))
	_chk(r, "each wind global exists after ensure_wind_globals (the project's or registered)",
		keys.all(func(k): return ProjectSettings.has_setting("shader_globals/" + k) or listed.has(k)))
	return r
