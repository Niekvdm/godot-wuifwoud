# Copyright (c) 2026 Digitzone
# SPDX-License-Identifier: MIT
extends SceneTree
## Wuifwoud's forest import, headless: world-space GeoJSON + a mapping file -> the forest maps beside the
## terrain's region files, and the report.
##
##   godot --headless --script res://addons/wuifwoud/tools/import_forest.gd -- --mapping <file> [--discard-painted]
##
## It keeps every texel painted by hand; --discard-painted overwrites them.
## The single trees and rows go to trees.json beside the maps.
## A host whose server mode takes over headless boots passes its opt-out after `--` as well. Exit code 0 on success.

## The import.
const ForestImportRes := preload("res://addons/wuifwoud/forest_import.gd")


func _initialize() -> void:
	var args := OS.get_cmdline_user_args()
	var i := args.find("--mapping")
	if i < 0 or i + 1 >= args.size():
		printerr("[import_forest] usage: -- --mapping <file> [--discard-painted]")
		quit(2)
		return
	var rep: Dictionary = ForestImportRes.run_file(args[i + 1], args.has("--discard-painted"))
	for e in rep["errors"]:
		printerr("[import_forest] ERROR %s" % e)
	print("[import_forest] %d map(s) written (%d kept for their paint, %d resampled), %d deleted, %d with their terrain region gone, %.2f MB on disk, %d ms" % [
		(rep["written"] as Array).size(), (rep["kept_painted"] as Array).size(), (rep["resampled"] as Array).size(),
		(rep["deleted"] as Array).size(), (rep["deleted_no_region"] as Array).size(), float(rep["bytes"]) / 1048576.0,
		rep["ms"]])
	if not (rep["painted_overwritten"] as Array).is_empty():
		print("[import_forest] painted texels overwritten in %d map(s): %s" % [(rep["painted_overwritten"] as Array).size(),
			str(rep["painted_overwritten"])])
	var tys: Array = (rep["km2"] as Dictionary).keys()
	tys.sort()
	for ty in tys:
		print("[import_forest] type %d: %.3f km²" % [ty, rep["km2"][ty]])
	for k in rep["unmatched"]:
		print("[import_forest] %s: %.3f km², no rule" % [k, rep["unmatched"][k]])
	for g in rep["skipped"]:
		print("[import_forest] skipped %d %s geometr%s" % [rep["skipped"][g], g, "y" if rep["skipped"][g] == 1 else "ies"])
	var iw: Dictionary = rep.get("items_written", {})
	print("[import_forest] single trees and rows: %d rows and %d trees written, %d kept as edited, %d skipped as deleted, %d deleted, %d rows cut by a zone; trees file %s" % [
		int(iw.get("rows", 0)), int(iw.get("trees", 0)), int(rep.get("items_kept_edited", 0)),
		int(rep.get("items_skipped_removed", 0)), int(rep.get("items_deleted", 0)), int(rep.get("rows_cut", 0)),
		str(rep.get("trees_file", "unchanged"))])
	var ul: Dictionary = rep.get("unmatched_lines", {})
	for k in ul:
		print("[import_forest] %s: %.0f m of lines, no rule" % [k, float(ul[k])])
	var up: Dictionary = rep.get("unmatched_points", {})
	for k in up:
		print("[import_forest] %s: %d points, no rule" % [k, int(up[k])])
	var inv: Dictionary = rep.get("items_invalid", {})
	for g in inv:
		print("[import_forest] %d malformed %s geometr%s skipped" % [int(inv[g]), g, "y" if int(inv[g]) == 1 else "ies"])
	if int(rep.get("items_dup_keys", 0)) > 0:
		print("[import_forest] %d feature key(s) seen twice: suffixed ^2, ^3, …" % int(rep["items_dup_keys"]))
	print("[import_forest] %s" % ("PASS" if rep["ok"] else "FAIL"))
	quit(0 if rep["ok"] else 1)
