# Copyright (c) 2026 Digitzone
# SPDX-License-Identifier: MIT
extends RefCounted
## The forest's per-frame instrument: frame_timings() hands out the last WHOLE frame's
## main-thread work per phase, each phase charged exclusive of the phases nested in it, the total their sum; a frame with
## no work reads zeros, and a phase an aborted function left open never charges the next frame.
##
## Run with a unit-suite runner: static run() returns {name, passed, failed, details}.

const Veg := preload("res://addons/wuifwoud/forest_spawner.gd")


static func _chk(r: Dictionary, n: String, ok: bool) -> void:
	if ok:
		r.passed += 1
	else:
		r.failed += 1
		r.details.append("✗ " + n)


static func _near(us: int, want: int) -> bool:
	return us >= want and us < want + 1500


static func run() -> Dictionary:
	var r := {"name": "forest_frame_timings", "passed": 0, "failed": 0, "details": []}
	var tree := Engine.get_main_loop() as SceneTree
	var vs = Veg.new()
	var fresh: Dictionary = vs.frame_timings()
	_chk(r, "every phase and the total, zeros before any work (%s)" % str(fresh.keys()),
		fresh.size() == Veg.FRAME_PHASES.size() + 1 and fresh.has(&"total")
		and Veg.FRAME_PHASES.all(func(p): return int(fresh.get(p, -1)) == 0) and int(fresh[&"total"]) == 0)
	await tree.process_frame
	vs._ft_begin(&"stream")
	OS.delay_usec(3000)
	vs._ft_begin(&"frees")
	OS.delay_usec(2000)
	vs._ft_end()
	vs._ft_end()
	vs._ft_begin(&"commit")
	OS.delay_usec(1000)
	vs._ft_end()
	var during: Dictionary = vs.frame_timings()
	await tree.process_frame
	var t: Dictionary = vs.frame_timings()
	var again: Dictionary = vs.frame_timings()
	_chk(r, "the frame is not over: the last whole frame's (none) (%d)" % int(during[&"total"]), int(during[&"total"]) == 0)
	_chk(r, "a nested phase charged to itself, not to the one around it; the total their sum (stream %d, frees %d, commit %d, total %d)" % [
		int(t[&"stream"]), int(t[&"frees"]), int(t[&"commit"]), int(t[&"total"])],
		_near(int(t[&"stream"]), 3000) and _near(int(t[&"frees"]), 2000) and _near(int(t[&"commit"]), 1000)
		and int(t[&"total"]) == int(t[&"stream"]) + int(t[&"frees"]) + int(t[&"commit"]) and again == t)
	vs._ft_begin(&"flush")                      # never ended: a function that aborted mid-phase
	OS.delay_usec(500)
	await tree.process_frame
	vs._ft_begin(&"far")
	vs._ft_end()
	await tree.process_frame
	var after: Dictionary = vs.frame_timings()
	await tree.process_frame
	var idle: Dictionary = vs.frame_timings()
	_chk(r, "a phase left open never charges the next frame; a frame with no work reads zeros (%d, %d)" % [
		int(after[&"flush"]), int(idle[&"total"])],
		int(after[&"flush"]) == 0 and int(after[&"total"]) < 500 and int(idle[&"total"]) == 0)
	vs.free()
	return r
