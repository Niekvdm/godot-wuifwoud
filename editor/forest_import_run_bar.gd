# Copyright (c) 2026 Digitzone
# SPDX-License-Identifier: MIT
@tool
extends RefCounted
## The Import dialog's Run bar: what Run needs; Run and Overwrite painted texels, which asks
## first; while the import runs its progress and Cancel; then its report.


## The bar for the dialog `d`.
static func build(d) -> Control:
	var v := VBoxContainer.new()
	v.name = "RunBar"
	v.add_theme_constant_override("separation", 4)
	v.add_child(HSeparator.new())
	if d.busy():
		var h := HBoxContainer.new()
		h.add_theme_constant_override("separation", 10)
		var bar := ProgressBar.new()
		bar.name = "Progress"
		bar.show_percentage = false
		bar.custom_minimum_size = Vector2(0, 8)
		bar.size_flags_horizontal = Control.SIZE_EXPAND_FILL
		bar.size_flags_vertical = Control.SIZE_SHRINK_CENTER
		h.add_child(bar)
		var ph := Label.new()
		ph.name = "Phase"
		ph.text = d.phase_text()
		h.add_child(ph)
		var c: Button = d.kit.chip("Cancel", false, d.accent)
		c.name = "Cancel"
		c.pressed.connect(d.cancel_run)
		h.add_child(c)
		v.add_child(h)
		v.add_child(d.hint("Read-only while the import runs. The editor is free; closing this dialog does not stop it."))
		return v
	var errs: PackedStringArray = d.run_errors()
	if not errs.is_empty():
		var more := (" (+%d more)" % (errs.size() - 4)) if errs.size() > 4 else ""
		var el: Label = d.red("Run needs: " + "; ".join(errs.slice(0, 4)) + more)
		el.name = "RunErrors"
		v.add_child(el)
	if d.asking:
		var q: PanelContainer = d.kit.banner("Every texel painted by hand in %s takes the import: that painted forest is lost." % d.maps_folder(),
			"Overwrite", d.accent)
		q.name = "Question"
		(q.find_child("Action", true, false) as Button).pressed.connect(d.confirm_overwrite)
		var no: Button = d.kit.chip("Keep the paint", false, d.accent)
		no.name = "KeepPaint"
		no.size_flags_horizontal = Control.SIZE_SHRINK_BEGIN
		no.pressed.connect(d.cancel_question)
		q.get_child(0).add_child(no)
		v.add_child(q)
		return v
	var h2 := HBoxContainer.new()
	h2.add_theme_constant_override("separation", 10)
	var ow: HBoxContainer = d.kit.toggle_row("Overwrite painted texels", d.discard, d.accent)
	ow.name = "Overwrite"
	ow.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	(ow.get_node("Toggle") as CheckBox).toggled.connect(d.set_discard)
	h2.add_child(ow)
	var run: Button = d.kit.chip("Run import", false, d.accent)
	run.name = "Run"
	run.disabled = not errs.is_empty()
	run.pressed.connect(d.start_run)
	h2.add_child(run)
	v.add_child(h2)
	if not (d.report as Dictionary).is_empty():
		v.add_child(_report(d))
	return v


static func _report(d) -> Control:
	var rep: Dictionary = d.report
	var v := VBoxContainer.new()
	v.name = "Report"
	if bool(rep.get("cancelled", false)):
		v.add_child(d.hint("Cancelled: the maps are as they were."))
		return v
	for e in rep.get("errors", []):
		v.add_child(d.red(String(e)))
	var written: Array = rep.get("written", [])
	if not bool(rep.get("ok", false)) and written.is_empty():
		v.add_child(d.hint("Nothing was swapped: the maps are as they were."))
		return v
	var sl := Label.new()
	sl.name = "Summary"
	sl.text = "%d maps written (%d kept for their paint, %d resampled), %d deleted, %d with their terrain region gone · %.2f MB · %.1f s" % [
		written.size(), (rep.get("kept_painted", []) as Array).size(), (rep.get("resampled", []) as Array).size(),
		(rep.get("deleted", []) as Array).size(), (rep.get("deleted_no_region", []) as Array).size(),
		float(rep.get("bytes", 0)) / 1048576.0, float(rep.get("ms", 0)) / 1000.0]
	sl.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	v.add_child(sl)
	var po: Array = rep.get("painted_overwritten", [])
	if not po.is_empty():
		v.add_child(d.amber("Painted texels overwritten in %d maps." % po.size()))
	var km := PackedStringArray()
	var km2: Dictionary = rep.get("km2", {})
	for ty in km2:
		km.append("%s %.3f km²" % [d.type_name(int(ty)), float(km2[ty])])
	if not km.is_empty():
		v.add_child(d.hint("By type: " + " · ".join(km)))
	var um: Dictionary = rep.get("unmatched", {})
	if not um.is_empty():
		var ks := um.keys()
		ks.sort_custom(func(a, b) -> bool: return float(um[a]) > float(um[b]))
		var parts := PackedStringArray()
		for k in ks.slice(0, 6):
			parts.append("%s %.3f km²" % [k, float(um[k])])
		var more := (" (+%d more)" % (ks.size() - 6)) if ks.size() > 6 else ""
		v.add_child(d.hint("No rule matched: " + " · ".join(parts) + more))
	var iw: Dictionary = rep.get("items_written", {})
	if not iw.is_empty():
		var il := Label.new()
		il.name = "Items"
		il.text = "Single trees and rows: %d rows and %d trees written, %d kept as edited, %d skipped as deleted, %d deleted, %d rows cut by a zone · trees file %s" % [
			int(iw.get("rows", 0)), int(iw.get("trees", 0)), int(rep.get("items_kept_edited", 0)),
			int(rep.get("items_skipped_removed", 0)), int(rep.get("items_deleted", 0)), int(rep.get("rows_cut", 0)),
			str(rep.get("trees_file", "unchanged"))]
		il.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
		v.add_child(il)
	var ul: Dictionary = rep.get("unmatched_lines", {})
	var upn: Dictionary = rep.get("unmatched_points", {})
	if not ul.is_empty() or not upn.is_empty():
		var lp := PackedStringArray()
		var lk := ul.keys()
		lk.sort_custom(func(a, b) -> bool: return float(ul[a]) > float(ul[b]))
		for k in lk.slice(0, 6):
			lp.append("%s %s" % [k, d.length_text(float(ul[k]))])
		for k in upn.keys().slice(0, 6):
			lp.append("%s %d points" % [k, int(upn[k])])
		v.add_child(d.hint("No rule matched (lines and points): " + " · ".join(lp)))
	var sk: Dictionary = rep.get("skipped", {})
	if not sk.is_empty():
		var gs := PackedStringArray()
		for g in sk:
			gs.append("%d %s" % [int(sk[g]), g])
		v.add_child(d.hint("Skipped (neither polygons, points nor lines): " + ", ".join(gs)))
	v.add_child(d.hint("An import is not an undo step: to go back, undo the mapping here and run again."))
	return v
