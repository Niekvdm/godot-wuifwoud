# Copyright (c) 2026 Digitzone
# SPDX-License-Identifier: MIT
extends RefCounted
## Without a ForestConfig (the public addon's first boot): exactly one warning, no error, no feeders,
## and nothing to place; the node still readies.
##
## Run with a unit-suite runner: static run() returns {name, passed, failed, details}.


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
	var r := {"name": "forest_no_config", "passed": 0, "failed": 0, "details": []}
	var tree := Engine.get_main_loop() as SceneTree
	var keep: Callable = ForestLog.sink
	var cap := Capture.new()
	ForestLog.sink = cap.take
	ForestConfig.use(ForestConfig.load_from("res://addons/wuifwoud/tests/fake/no_such_config.tres"))
	ForestAssets.forget_packs()
	var vs := ForestSpawner.new()
	vs.indirect_mmi = false
	tree.root.add_child(vs)
	await tree.process_frame
	var warns := cap.lines.filter(func(l): return l[0] == &"warn")
	var errs := cap.lines.filter(func(l): return l[0] == &"error")
	# The stand-in config grows the starter pack; until the addon ships one, nothing resolves, and that
	# is said once too.
	var starter_in := ResourceLoader.exists(ForestConfig.new().starter_pack_path())
	_chk(r, "the missing config's warning%s (%s)" % ["" if starter_in else ", and no species pack's", str(warns)],
		warns.size() == (1 if starter_in else 2) and String(warns[0][1]).contains("no ForestConfig"))
	_chk(r, "no errors (%s)" % str(errs), errs.is_empty())
	_chk(r, "no feeders", vs.get_children().filter(func(c): return c is ForestFeeder).is_empty())
	_chk(r, "the node readied", vs.is_node_ready())
	_chk(r, "nothing to place: no profile, no forest types", vs._types.ids().is_empty())
	vs.queue_free()
	await tree.process_frame
	ForestConfig.use(null)
	ForestAssets.forget_packs()
	ForestLog.sink = keep
	return r
