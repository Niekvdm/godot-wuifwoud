# Copyright (c) 2026 Digitzone
# SPDX-License-Identifier: MIT
@tool
extends RefCounted
## The Types dialog's Bands tab: the profile's elevation bands (the coast's top, the mid's top, the treeline, in metres)
## and the share kept above the treeline, beside a strip of the three bands as tall as they are. The forest takes them as
## proportions of its island: a cut of the terrain at another height scale keeps its bands.

## The rows: [node name, label, key, low, high, step, suffix, shown ×].
const ROWS := [["CoastTop", "Coast top", "coast_top_m", 0.0, 3000.0, 1.0, "m", 1.0],
	["MidTop", "Mid top", "mid_top_m", 0.0, 3000.0, 1.0, "m", 1.0],
	["Treeline", "Treeline", "treeline_m", 0.0, 4000.0, 1.0, "m", 1.0],
	["Keep", "Kept above the treeline", "treeline_keep", 0.0, 100.0, 1.0, "%", 100.0]]
## The bands' colours in the strip: coast, mid, high.
const COLOURS := [Color("6aa05a"), Color("3f7a4c"), Color("2f5d3a")]


## The tab for the dialog `d`.
static func build(d) -> Control:
	var h := HBoxContainer.new()
	h.name = "Bands"
	h.size_flags_vertical = Control.SIZE_EXPAND_FILL
	h.add_theme_constant_override("separation", 24)
	var b: Dictionary = d.profile.bands()
	var col := VBoxContainer.new()
	col.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	col.add_theme_constant_override("separation", 10)
	for row in ROWS:
		col.add_child(_row(d, row, b))
	var note: Label = d.hint("The forest takes the bands as proportions of its island: where the terrain is a cut at another height scale, they move with its summit, so the cut keeps its bands.")
	note.name = "BandsNote"
	col.add_child(note)
	h.add_child(col)
	h.add_child(_strip(b))
	return h


static func _row(d, row: Array, b: Dictionary) -> Control:
	var key := String(row[2])
	var scale := float(row[7])
	var r: VBoxContainer = d.kit.slider_row(String(row[1]), float(row[3]), float(row[4]), float(row[5]),
		float(b[key]) * scale, String(row[6]), d.accent)
	r.name = String(row[0])
	var s := r.get_node("Slider") as HSlider
	s.scrollable = false
	s.editable = d.editable()
	s.drag_ended.connect(func(moved: bool) -> void:
		if moved:
			d.set_band(key, s.value / scale))
	return r


## The strip: the three bands, high on top, each as tall as its height.
static func _strip(b: Dictionary) -> Control:
	var v := VBoxContainer.new()
	v.name = "BandStrip"
	v.custom_minimum_size = Vector2(90, 320)
	v.add_theme_constant_override("separation", 0)
	var parts := [["High", float(b["treeline_m"]) - float(b["mid_top_m"]), 2],
		["Mid", float(b["mid_top_m"]) - float(b["coast_top_m"]), 1], ["Coast", float(b["coast_top_m"]), 0]]
	for p in parts:
		var c := ColorRect.new()
		c.name = String(p[0])
		c.color = COLOURS[int(p[2])]
		c.size_flags_vertical = Control.SIZE_EXPAND_FILL
		c.size_flags_stretch_ratio = maxf(float(p[1]), 1.0)
		var l := Label.new()
		l.text = String(p[0])
		l.set_anchors_and_offsets_preset(Control.PRESET_CENTER)
		c.add_child(l)
		v.add_child(c)
	return v
