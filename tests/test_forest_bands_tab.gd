# Copyright (c) 2026 Digitzone
# SPDX-License-Identifier: MIT
extends RefCounted
## The Bands tab: the profile's coast top, mid top, treeline and the share kept above it, beside a strip of the three
## bands as tall as they are; a band let go is written (the strip follows) and undone; one that would put the bands out
## of order is refused and said; the share is written 0-1; the note says the forest takes them as proportions.
##
## Run with a unit-suite runner: static run() returns {name, passed, failed, details}.

const Fix := preload("res://addons/wuifwoud/tests/fixtures/types_fixture.gd")
const ROOT := "user://wf_e2_bands"


static func _chk(r: Dictionary, n: String, ok: bool) -> void:
	if ok:
		r.passed += 1
	else:
		r.failed += 1
		r.details.append("✗ " + n)


static func _bands(path: String) -> Dictionary:
	var v = JSON.parse_string(FileAccess.get_file_as_string(path))
	return v.get("bands", {}) if v is Dictionary else {}


static func _slider(d: Node, nm: String) -> HSlider:
	var row: Node = d.find_child(nm, true, false)
	return row.get_node("Slider") as HSlider if row != null else null


static func _ratio(d: Node, band: String) -> float:
	var strip: Node = d.find_child("BandStrip", true, false)
	var c: Control = strip.get_node(band) as Control if strip != null else null
	return c.size_flags_stretch_ratio if c != null else -1.0


static func run() -> Dictionary:
	var r := {"name": "forest_bands_tab", "passed": 0, "failed": 0, "details": []}
	var fx := Fix.make(ROOT)
	var made: Array = Fix.dialog(fx)
	var d = made[0]
	var path: String = fx["profile"]
	d.set_tab("bands")
	_chk(r, "the Bands tab: the profile's bands; the strip's bands as tall as they are",
		d.find_child("TypeList", true, false) == null and _slider(d, "MidTop").value == 300.0
		and _slider(d, "Keep").value == 30.0 and _ratio(d, "High") == 500.0 and _ratio(d, "Mid") == 250.0
		and _ratio(d, "Coast") == 50.0)
	var note := d.find_child("BandsNote", true, false) as Label
	_chk(r, "the note: proportions of the island", note != null and note.text.contains("proportions"))
	var mid := _slider(d, "MidTop")
	mid.value = 350.0
	mid.drag_ended.emit(true)
	_chk(r, "a band let go is written; the strip follows", float(_bands(path).get("mid_top_m", 0.0)) == 350.0
		and _ratio(d, "Mid") == 300.0 and _ratio(d, "High") == 450.0)
	var coast := _slider(d, "CoastTop")
	coast.value = 400.0
	coast.drag_ended.emit(true)
	_chk(r, "a coast top above the mid top is refused and said (%s)" % d.error, d.error.contains("climb")
		and float(_bands(path).get("coast_top_m", 0.0)) == 50.0)
	var keep := _slider(d, "Keep")
	keep.value = 45.0
	keep.drag_ended.emit(true)
	_chk(r, "the share kept above the treeline is written 0-1", is_equal_approx(float(_bands(path).get("treeline_keep", 0.0)), 0.45))
	d.undo()
	_chk(r, "undo writes it back", is_equal_approx(float(_bands(path).get("treeline_keep", 0.0)), 0.3))
	d.set_tab("types")
	_chk(r, "back on Types: the list", d.find_child("TypeList", true, false) != null and d.find_child("BandStrip", true, false) == null)
	d.free()
	Fix.clean(ROOT)
	return r
