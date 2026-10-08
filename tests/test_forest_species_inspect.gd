# Copyright (c) 2026 Digitzone
# SPDX-License-Identifier: MIT
extends RefCounted
## Inspect: ⤢ folds the pack tree and widens the view, its four modes; the distance row in Compare walks the camera out to
## the hand-over the plugin gives (or the default), its readout says the distance, the hand-over and the elevation; ⤡ and
## Esc go back; a tile's double click selects and inspects it.
##
## Run with a unit-suite runner: static run() returns {name, passed, failed, details}.

const Fix := preload("res://addons/wuifwoud/tests/fixtures/species_fixture.gd")
const ROOT := "user://wf_e1_inspect"


static func _chk(r: Dictionary, n: String, ok: bool) -> void:
	if ok:
		r.passed += 1
	else:
		r.failed += 1
		r.details.append("✗ " + n)


static func run() -> Dictionary:
	var r := {"name": "forest_species_inspect", "passed": 0, "failed": 0, "details": []}
	var fx := Fix.make(ROOT)
	var made: Array = Fix.dialog(fx, false, {"handover_of": func(_id: String) -> Dictionary: return {"out0": 210.0, "out1": 300.0}})
	var d = made[0]
	d.select("W_Tree")
	(d.find_child("Inspect", true, false) as Button).pressed.emit()
	var modes: Node = d.find_child("Modes", true, false)
	_chk(r, "⤢: the tree folds, four modes", d.inspecting and d.find_child("Tree", true, false) == null
		and modes != null and modes.get_child_count() == 4)
	(modes.get_node("Seg2") as Button).pressed.emit()
	var dist := d.find_child("Distance", true, false) as VBoxContainer
	_chk(r, "Compare: the distance row", d.view.mode == "compare" and dist != null)
	var s := dist.get_node("Slider") as HSlider
	_chk(r, "it reaches past the hand-over", s.max_value >= 300.0)
	s.value = 250.0
	s.value_changed.emit(250.0)          # Range defers value_changed (Godot 4.8): the editor's comes a frame later
	var ro := d.find_child("Readout", true, false) as Label
	_chk(r, "the camera walks out; the readout says it (%s)" % ro.text,
		is_equal_approx(d.view.distance(), 250.0) and ro.text.contains("250 m") and ro.text.contains("hand-over 300 m")
		and ro.text.contains("elev 18°"))
	d.rebuild()
	d.rebuild()
	_chk(r, "the kept view does not pile up readouts across rebuilds (%d)" % d.view.camera_moved.get_connections().size(),
		d.view.camera_moved.get_connections().size() <= 1)
	(d.find_child("Inspect", true, false) as Button).pressed.emit()
	_chk(r, "⤡ goes back", not d.inspecting and d.find_child("Tree", true, false) != null)
	d.inspect_species("W_New")
	var closed := [false]
	d.closed.connect(func() -> void: closed[0] = true)
	var esc := InputEventKey.new()
	esc.keycode = KEY_ESCAPE
	esc.pressed = true
	var was_open: bool = d.inspecting and d.selected == "W_New"
	d._input(esc)
	_chk(r, "a double click inspects; Esc leaves Inspect, not the dialog", was_open and not d.inspecting and not closed[0])
	d.free()
	Fix.TreeFix.rm_tree(ROOT)
	return r
