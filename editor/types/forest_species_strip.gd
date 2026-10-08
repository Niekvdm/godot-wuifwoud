# Copyright (c) 2026 Digitzone
# SPDX-License-Identifier: MIT
@tool
extends RefCounted
## The Types dialog's species strip, under the lanes: every species the forest grows as a picture tile, a search (id and
## name) and the chips All · Trees · Bushes. Drag a tile onto a lane to add it there, or click it to add it to the lane
## in focus.

## A species tile.
const SpeciesTileRes := preload("res://addons/wuifwoud/editor/common/forest_species_tile.gd")
## The forest's species.
const VA := preload("res://addons/wuifwoud/forest_assets.gd")
## The drag kind of a species (the tile's).
const KIND := "wuifwoud_species"
## The filter chips: label, filter.
const FILTERS := [["All", "all"], ["Trees", "trees"], ["Bushes", "bushes"]]
## A tile's size.
const PX := 46


## The strip for the dialog `d`.
static func build(d) -> Control:
	var v := VBoxContainer.new()
	v.name = "Strip"
	var head := HBoxContainer.new()
	head.add_theme_constant_override("separation", 6)
	var s: LineEdit = d.kit.search_field("Search species")
	s.name = "StripSearch"
	s.text = d.strip_search
	s.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	s.text_changed.connect(d.strip_search_changed)
	head.add_child(s)
	var g := ButtonGroup.new()
	for pair in FILTERS:
		var b: Button = d.kit.toggle_chip(String(pair[0]), d.strip_filter == String(pair[1]), d.accent)
		b.name = "StripFilter_" + String(pair[1])
		b.button_group = g
		b.pressed.connect(d.set_strip_filter.bind(String(pair[1])))
		head.add_child(b)
	v.add_child(head)
	var sc := ScrollContainer.new()
	sc.name = "StripScroll"
	sc.custom_minimum_size = Vector2(0, PX + 16)
	sc.vertical_scroll_mode = ScrollContainer.SCROLL_MODE_DISABLED
	var row := HBoxContainer.new()
	row.name = "StripTiles"
	row.add_theme_constant_override("separation", 4)
	var ids: PackedStringArray = d.strip_ids()
	for id in ids:
		var t = SpeciesTileRes.new().setup(d.kit, VA.species_of(id), VA.built_dir_of(id), "built", true, false, d.accent, PX)
		t.pressed.connect(d.strip_click.bind(String(id)))
		row.add_child(t)
	sc.add_child(row)
	v.add_child(sc)
	if ids.is_empty():
		v.add_child(d.hint("No species matches." if d.strip_search != "" or d.strip_filter != "all"
			else "No species grows: switch a species pack on in Forest → Species…."))
	v.add_child(d.hint("Drag a species onto a lane, or click it to add it to %s." % d.focus_title()))
	return v
