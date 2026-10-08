# Copyright (c) 2026 Digitzone
# SPDX-License-Identifier: MIT
extends SceneTree
## Builds species packs from the command line: every species that needs it (or every one, --all, or those named,
## --species <id>[,<id>…]) of the packs the project grows, or of one pack or pack set (--pack
## <res path>): prepared, its impostor baked, landed in the pack's built/. The same job as the editor's Forest → Build
## packs….
##
##   godot --path . --display-driver x11 --rendering-driver vulkan --resolution 256x256 --position -6000,-6000 \
##       --script res://addons/wuifwoud/tools/build_packs.gd -- [--pack <res://…/pack.tres>] [--species <id>] [--all]
##
## X11 OFF-SCREEN, NOT HEADLESS: --headless has no renderer, and a bake there writes blank atlases, so it refuses. A
## host whose server mode takes headless boots passes its opt-out after `--`. Exit code: the species that failed.

## A pack build.
const JobRes := preload("res://addons/wuifwoud/species/forest_pack_build.gd")

var _job = null
var _last := ""
## The frames this script forces: an off-screen window may never draw in the main loop, so the bake counts these.
var _drawn := 0


func _arg(n: String, d: String) -> String:
	var a := OS.get_cmdline_user_args()
	for i in a.size():
		if a[i] == n and i + 1 < a.size():
			return a[i + 1]
	return d


func _initialize() -> void:
	if DisplayServer.get_name() == "headless":
		printerr("[packs] RESULT FAIL the bake needs a renderer: run with --display-driver x11, not --headless")
		quit(1)
		return
	var packs: Array = []
	var one := _arg("--pack", "")
	if one != "":
		var p = load(one) if ResourceLoader.exists(one) else null
		if p is ForestPackSet:
			packs = Array(p.packs)
		elif p is ForestSpeciesPack:
			packs = [p]
		else:
			printerr("[packs] RESULT FAIL %s is not a species pack or a pack set" % one)
			quit(1)
			return
	else:
		packs = ForestConfig.current().resolved_packs()
	var sp := _arg("--species", "")
	_job = JobRes.new(packs, {"force": OS.get_cmdline_user_args().has("--all"),
		"only": sp.split(",", false) if sp != "" else PackedStringArray()})
	_job.frames = func() -> int: return _drawn
	# Its frames are forced and never shown: no vsync wait (a forced, presented frame waited a display refresh).
	DisplayServer.window_set_vsync_mode(DisplayServer.VSYNC_DISABLED)
	_job.start(get_root())
	print("[packs] %d pack(s): %s" % [packs.size(), ", ".join(PackedStringArray(packs.map(func(p): return String(p.name))))])


func _process(_dt: float) -> bool:
	if _job == null:
		return true
	RenderingServer.force_draw(false)
	_drawn += 1
	var done: bool = _job.poll()
	var pr: Dictionary = _job.progress()
	var line := "%s %s" % [pr["phase"], pr["species"]]
	if line != _last:
		_last = line
		print("[packs] %d/%d %s" % [int(pr["done"]), int(pr["total"]), line])
	if not done:
		return false
	var rep: Dictionary = _job.report
	for id in rep["warnings"]:
		print("[packs] warn %s: %s" % [id, "; ".join(PackedStringArray(rep["warnings"][id]))])
	for id in rep["failed"]:
		print("[packs] FAIL %s: %s" % [id, rep["failed"][id]])
	print("[packs] RESULT %s built %d, up to date %d, failed %d, removed %d, %.1f s" % [
		"PASS" if (rep["failed"] as Dictionary).is_empty() else "FAIL", (rep["built"] as Array).size(),
		(rep["skipped"] as Array).size(), (rep["failed"] as Dictionary).size(), (rep["removed"] as Array).size(),
		float(rep["ms"]) / 1000.0])
	quit((rep["failed"] as Dictionary).size())
	return true
