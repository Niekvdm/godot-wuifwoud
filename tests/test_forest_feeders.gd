# Copyright (c) 2026 Digitzone
# SPDX-License-Identifier: MIT
extends RefCounted
## The feeders: the forest adds one child per ForestConfig.runtime_inputs script, without an
## owner, BEFORE the rest of its _ready (the trunk pool is added at the end of _ready, so a feeder that saw no pool
## ran first); a feeder already under the node replaces the config's copy; a script that is not a ForestFeeder is
## skipped with one warning, and a null entry silently; feeders feed every frame.
##
## Run with a unit-suite runner: static run() returns {name, passed, failed, details}.

const ForestConfigRes := preload("res://addons/wuifwoud/forest_config.gd")
const ForestLogRes := preload("res://addons/wuifwoud/forest_log.gd")
const Veg := preload("res://addons/wuifwoud/forest_spawner.gd")
const ProbeFeeder := preload("res://addons/wuifwoud/tests/fixtures/probe_feeder.gd")
const NotAFeeder := preload("res://addons/wuifwoud/tests/fixtures/not_a_feeder.gd")


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
	var r := {"name": "forest_feeders", "passed": 0, "failed": 0, "details": []}
	var tree := Engine.get_main_loop() as SceneTree
	var cfg = ForestConfigRes.new()
	var inputs: Array[Script] = [ProbeFeeder, NotAFeeder, null]
	cfg.runtime_inputs = inputs
	ForestConfigRes.use(cfg)
	var keep: Callable = ForestLogRes.sink
	var cap := Capture.new()
	ForestLogRes.sink = cap.take
	var vs: Node3D = Veg.new()
	vs.indirect_mmi = false
	tree.root.add_child(vs)
	await tree.process_frame   # the batch's root enters the tree on its first frame: _ready runs there
	var feeders := vs.get_children().filter(func(c): return c.get_script() == ProbeFeeder)
	_chk(r, "one feeder per config script (%d)" % feeders.size(), feeders.size() == 1)
	var f = feeders[0] if feeders.size() == 1 else null
	_chk(r, "the feeder found its forest", f != null and f.saw_forest)
	_chk(r, "the feeder readied before the rest of the forest's _ready (no trunk pool yet)",
		f != null and not f.pool_existed_at_ready)
	_chk(r, "the feeder has no owner (a scene save never stores it)", f != null and f.owner == null)
	_chk(r, "the forest is in its group", vs.is_in_group(&"wuifwoud_forest"))
	var warns := cap.lines.filter(func(l): return l[0] == &"warn" and String(l[1]).contains("not a ForestFeeder"))
	_chk(r, "a script that is not a feeder is skipped with one warning (%d)" % warns.size(), warns.size() == 1)
	await tree.process_frame
	await tree.process_frame
	_chk(r, "the feeder feeds every frame (%d)" % (f.feeds if f != null else -1), f != null and f.feeds >= 2)
	vs.queue_free()
	var vs2: Node3D = Veg.new()
	vs2.indirect_mmi = false
	var mine = ProbeFeeder.new()
	mine.name = "Mine"
	vs2.add_child(mine)
	tree.root.add_child(vs2)
	await tree.process_frame
	var n2 := vs2.get_children().filter(func(c): return c.get_script() == ProbeFeeder).size()
	_chk(r, "a feeder placed under the node beforehand is not doubled (%d)" % n2, n2 == 1)
	vs2.queue_free()
	await tree.process_frame
	ForestConfigRes.use(null)
	ForestLogRes.sink = keep
	return r
