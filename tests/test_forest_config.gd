# Copyright (c) 2026 Digitzone
# SPDX-License-Identifier: MIT
extends RefCounted
## ForestConfig and ForestLog: a config loads from a path; a missing one is an empty
## config and ONE warning; every log level reaches the sink, and a sink whose owner is gone falls back to Godot's
## own channels.
##
## Run with a unit-suite runner: static run() returns {name, passed, failed, details}.

const ForestConfigRes := preload("res://addons/wuifwoud/forest_config.gd")
const ForestLogRes := preload("res://addons/wuifwoud/forest_log.gd")


class Capture:
	var lines: Array = []

	func take(level: StringName, msg: String) -> void:
		lines.append([level, msg])


## Records which thread each line arrived on.
class ThreadCapture:
	var on_main: Array = []

	func take(_level: StringName, msg: String) -> void:
		on_main.append([msg, OS.get_thread_caller_id() == OS.get_main_thread_id()])


static func _warn_from_worker() -> void:
	ForestLogRes.warn("[forest_config test] from a worker")


static func _chk(r: Dictionary, n: String, ok: bool) -> void:
	if ok:
		r.passed += 1
	else:
		r.failed += 1
		r.details.append("✗ " + n)


static func run() -> Dictionary:
	var r := {"name": "forest_config", "passed": 0, "failed": 0, "details": []}
	var keep: Callable = ForestLogRes.sink
	var cap := Capture.new()
	ForestLogRes.sink = cap.take
	var c = ForestConfigRes.load_from("res://addons/wuifwoud/tests/fake/no_such_config.tres")
	_chk(r, "a missing config loads as an empty ForestConfig", c != null and c.get_script() == ForestConfigRes)
	_chk(r, "an empty config has no feeders", c != null and (c.runtime_inputs as Array).is_empty())
	_chk(r, "an empty config keeps the trunk defaults (group vehicles, layer 1, mask 1)",
		c != null and c.collision_group == &"vehicles" and c.trunk_layer == 1 and c.trunk_mask == 1)
	var warns := cap.lines.filter(func(l): return l[0] == &"warn")
	_chk(r, "a missing config warns exactly once (%d)" % warns.size(), warns.size() == 1)
	var saved = ForestConfigRes.new()
	saved.disabled_packs = PackedStringArray(["res://addons/wuifwoud/tests/fake/pack.tres"])
	saved.trunk_meta = {&"strike_material": &"trunk"}
	var path := "user://wf_test_config.tres"
	var err := ResourceSaver.save(saved, path)
	var back = ForestConfigRes.load_from(path)
	_chk(r, "a saved config loads back (err %d)" % err, err == OK and back != null
		and back.disabled_packs == PackedStringArray(["res://addons/wuifwoud/tests/fake/pack.tres"])
		and back.trunk_meta.get(&"strike_material") == &"trunk")
	DirAccess.remove_absolute(ProjectSettings.globalize_path(path))
	ForestConfigRes.use(saved)
	_chk(r, "use() makes current() return that config", ForestConfigRes.current() == saved)
	ForestConfigRes.use(null)
	cap.lines.clear()
	ForestLogRes.debug("d")
	ForestLogRes.info("i")
	ForestLogRes.warn("w")
	ForestLogRes.error("e")
	_chk(r, "each level reaches the sink, in order (%s)" % str(cap.lines),
		cap.lines == [[&"debug", "d"], [&"info", "i"], [&"warn", "w"], [&"error", "e"]])
	var gone := Capture.new()
	ForestLogRes.sink = gone.take
	gone = null   # the sink's object is freed now; its Callable is invalid
	ForestLogRes.info("[forest_config test] after the sink's owner went: printed, no error")
	_chk(r, "a dead sink is invalid, and the log falls back to print", not ForestLogRes.sink.is_valid())
	# A line raised on a placement WORKER reaches the sink on the MAIN thread (a game logger need not be thread-safe).
	var tc := ThreadCapture.new()
	ForestLogRes.sink = tc.take
	var th := Thread.new()
	th.start(_warn_from_worker)
	th.wait_to_finish()
	await (Engine.get_main_loop() as SceneTree).process_frame
	_chk(r, "a worker's log line reaches the sink once, on the main thread (%s)" % str(tc.on_main),
		tc.on_main.size() == 1 and tc.on_main[0][1] == true)
	ForestLogRes.sink = keep

	# A host's ForestConfig subclass (another folder, or none) still finds the addon's starter.
	var sub := GDScript.new()
	sub.source_code = "extends \"res://addons/wuifwoud/forest_config.gd\"\n"
	sub.reload()
	var sc = sub.new()
	var base := ForestConfig.new()
	_chk(r, "a ForestConfig subclass finds the starter beside ForestConfig, not beside itself (%s)" % sc.starter_pack_path(),
		sc.starter_pack_path() == base.starter_pack_path() and sc.starter_flora_path() == base.starter_flora_path()
		and base.starter_pack_path() == "res://addons/wuifwoud/packs/starter/starter.tres")
	return r
