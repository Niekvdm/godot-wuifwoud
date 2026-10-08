# Copyright (c) 2026 Digitzone
# SPDX-License-Identifier: MIT
@tool
extends RefCounted
## The Species dialog's left column: a search (id and name) and the filter chips, then a row per listed pack (its name,
## where it comes from, its counts, its switch, its ⋯) opening into its species' tiles. While the search or a filter
## narrows the tree, the rows with a match open by themselves and the rest hide.

## A species tile.
const TileRes := preload("res://addons/wuifwoud/editor/common/forest_species_tile.gd")
## The filter chips: label, filter.
const FILTERS := [["All", "all"], ["Trees", "trees"], ["Bushes", "bushes"], ["Needs building", "build"],
	["Disabled", "disabled"]]
## A pack's ⋯: Build this pack.
const MENU_BUILD := 1
## A pack's ⋯: Show in FileSystem.
const MENU_SHOW := 2


## The column for the dialog `d`.
static func build(d) -> Control:
	var v := VBoxContainer.new()
	v.name = "Tree"
	v.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	v.size_flags_stretch_ratio = 1.35
	var s: LineEdit = d.kit.search_field("Search species")
	s.name = "Search"
	s.text = d.search
	s.text_changed.connect(d.search_changed)
	v.add_child(s)
	var chips := HBoxContainer.new()
	chips.name = "Filters"
	var g := ButtonGroup.new()
	for pair in FILTERS:
		var b: Button = d.kit.toggle_chip(String(pair[0]), d.filter == String(pair[1]), d.accent)
		b.name = "Filter_" + String(pair[1])
		b.button_group = g
		b.pressed.connect(d.set_filter.bind(String(pair[1])))
		chips.add_child(b)
	v.add_child(chips)
	var sc := ScrollContainer.new()
	sc.name = "TreeScroll"
	sc.size_flags_vertical = Control.SIZE_EXPAND_FILL
	sc.horizontal_scroll_mode = ScrollContainer.SCROLL_MODE_DISABLED
	var list := VBoxContainer.new()
	list.name = "Packs"
	list.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	list.add_theme_constant_override("separation", 6)
	sc.add_child(list)
	var narrowing: bool = d.search.strip_edges() != "" or d.filter != "all"
	for pr in d.all_packs():
		var shown: Array = d.shown_species(pr["pack"])
		if narrowing and shown.is_empty():
			continue
		list.add_child(_pack_row(d, pr, shown, narrowing))
	if list.get_child_count() == 0:
		list.add_child(d.hint("Nothing matches." if narrowing else
			"No species pack in this project: list one in the Wuifwoud config, install a pack addon, or switch the starter pack on."))
	v.add_child(sc)
	return v


static func _pack_row(d, pr: Dictionary, shown: Array, narrowing: bool) -> Control:
	var pack = pr["pack"]
	var key: String = d.pack_key(pack)
	var box := PanelContainer.new()
	box.name = "Pack_" + String(d.pack_label(pack)).validate_node_name()
	box.add_theme_stylebox_override("panel", d.box(Color(1, 1, 1, 0.04)))
	var v := VBoxContainer.new()
	box.add_child(v)
	var h := HBoxContainer.new()
	h.name = "Head"
	h.add_theme_constant_override("separation", 8)
	var opened: bool = narrowing or d.is_open(key)
	var op := Button.new()
	op.name = "Open"
	op.flat = true
	op.text = ("▾ " if opened else "▸ ") + String(d.pack_label(pack))
	op.focus_mode = Control.FOCUS_NONE
	op.pressed.connect(d.toggle_open.bind(key))
	h.add_child(op)
	var where := Label.new()
	where.name = "Where"
	where.text = d.pack_where(pr["src"], pack)
	where.modulate = d.DIM
	where.clip_text = true
	where.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	h.add_child(where)
	var counts := Label.new()
	counts.name = "Counts"
	counts.text = d.counts_text(pack)
	counts.modulate = d.DIM
	h.add_child(counts)
	var sw := CheckButton.new()
	sw.name = "On"
	sw.button_pressed = bool(pr["enabled"])
	sw.focus_mode = Control.FOCUS_NONE
	sw.tooltip_text = "Grow this pack"
	sw.toggled.connect(func(t: bool) -> void: d.set_pack_enabled(pr["src"], pack, t))
	h.add_child(sw)
	var items := [{"id": MENU_BUILD, "text": "Build this pack", "disabled": d.busy() or String(pack.resource_path) == ""},
		{"id": MENU_SHOW, "text": "Show in FileSystem", "disabled": String(pack.resource_path) == ""}]
	var menu = d.kit.menu_chip("⋯", items, d.accent, func(id: int) -> void: pack_menu(d, pack, id))
	menu.name = "PackMenu"
	h.add_child(menu)
	v.add_child(h)
	if opened:
		var flow := HFlowContainer.new()
		flow.name = "Tiles"
		for row in shown:
			var id := String(row["id"])
			var t = TileRes.new().setup(d.kit, row["s"], pack.built_dir(), String(row["state"]), d.grows(id, pack),
				id == d.selected, d.accent)
			t.pressed.connect(d.select.bind(id))
			t.activated.connect(d.select.bind(id))
			flow.add_child(t)
		v.add_child(flow)
	return box


## A pack's ⋯ picked.
static func pack_menu(d, pack, id: int) -> void:
	if id == MENU_BUILD:
		d.build_pack(pack)
	elif id == MENU_SHOW and d.show_file.is_valid():
		d.show_file.call(String(pack.resource_path))
