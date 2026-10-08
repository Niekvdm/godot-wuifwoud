# Copyright (c) 2026 Digitzone
# SPDX-License-Identifier: MIT
@tool
extends RefCounted
## The Types dialog's left column: the Defaults row (the map's default lanes), then a row per type in the profile's
## order (≡ to drag it onto another row's place, its icon, its name, its style and density, its id; right-click:
## Duplicate, Delete), and + New type.

## Where a dragged type row lands.
const DropRes := preload("res://addons/wuifwoud/editor/common/forest_drop_target.gd")
## The ≡ handle.
const HandleRes := preload("res://addons/wuifwoud/editor/forest_value_tile.gd")
## The type icons.
const TypeTileRes := preload("res://addons/wuifwoud/editor/common/forest_type_tile.gd")
## A row's fill.
const ROW := Color(1.0, 1.0, 1.0, 0.04)
## No border.
const NONE := Color(0, 0, 0, 0)
## The Defaults row's icon colour.
const DEFAULTS_COLOUR := Color(0.42, 0.45, 0.48)


## The column for the dialog `d`.
static func build(d) -> Control:
	var v := VBoxContainer.new()
	v.name = "TypeList"
	v.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	v.size_flags_stretch_ratio = 0.8
	var sc := ScrollContainer.new()
	sc.name = "ListScroll"
	sc.size_flags_vertical = Control.SIZE_EXPAND_FILL
	sc.horizontal_scroll_mode = ScrollContainer.SCROLL_MODE_DISABLED
	var list := VBoxContainer.new()
	list.name = "Types"
	list.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	list.add_theme_constant_override("separation", 5)
	sc.add_child(list)
	list.add_child(_defaults_row(d))
	var ids: PackedInt32Array = d.profile.type_ids()
	for id in ids:
		list.add_child(_row(d, id))
	if ids.is_empty():
		list.add_child(d.hint("No types yet: + New type adds one."))
	v.add_child(sc)
	var add: Button = d.kit.chip("+ New type", false, d.accent)
	add.name = "NewType"
	add.disabled = not d.editable()
	add.pressed.connect(d.new_type)
	v.add_child(add)
	return v


static func _defaults_row(d) -> Control:
	var sel: bool = d.selected == 0
	var row: PanelContainer = DropRes.new().setup([], Callable(),
		d.box(Color(d.accent, 0.14) if sel else ROW, d.accent if sel else NONE), null)
	row.name = "Defaults"
	row.pressed.connect(d.select.bind(0))
	var h := HBoxContainer.new()
	h.mouse_filter = Control.MOUSE_FILTER_IGNORE
	h.add_theme_constant_override("separation", 8)
	h.add_child(TypeTileRes.tile("mixed", DEFAULTS_COLOUR, 30))
	var nm := Label.new()
	nm.name = "Name"
	nm.text = "Defaults (every type)"
	h.add_child(nm)
	row.add_child(h)
	return row


static func _row(d, id: int) -> Control:
	var t: Dictionary = d.profile.type_of(id)
	var sel: bool = d.selected == id
	var row: PanelContainer = DropRes.new().setup([d.TYPE_KIND],
		func(_kind: String, src: String) -> void: d.move_type(int(src), id),
		d.box(Color(d.accent, 0.14) if sel else ROW, d.accent if sel else NONE), d.box(Color(d.accent, 0.2), d.accent))
	row.name = "Type_%d" % id
	row.pressed.connect(d.select.bind(id))
	row.menu_requested.connect(func(at: Vector2) -> void: d.open_type_menu(id, at))
	var h := HBoxContainer.new()
	h.mouse_filter = Control.MOUSE_FILTER_IGNORE
	h.add_theme_constant_override("separation", 8)
	var handle: Button = HandleRes.new().setup(d.TYPE_KIND, str(id), "≡")
	handle.name = "Handle"
	handle.custom_minimum_size = Vector2(22, 22)
	handle.disabled = not d.editable()
	handle.tooltip_text = "Drag onto another type to move this one there (the library's order; ids never change)"
	h.add_child(handle)
	h.add_child(TypeTileRes.tile(d.icon_for(id), d.colour_for(id), 30))
	var col := VBoxContainer.new()
	col.mouse_filter = Control.MOUSE_FILTER_IGNORE
	col.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	col.add_theme_constant_override("separation", 0)
	var nm := Label.new()
	nm.name = "Name"
	nm.text = str(t.get("name", "type %d" % id))
	nm.clip_text = true
	col.add_child(nm)
	var info := Label.new()
	info.name = "Info"
	info.text = d.type_info(id)
	info.modulate = d.DIM
	info.add_theme_font_size_override("font_size", 11)
	col.add_child(info)
	h.add_child(col)
	var idl := Label.new()
	idl.name = "Id"
	idl.text = str(id)
	idl.modulate = d.DIM
	h.add_child(idl)
	row.add_child(h)
	return row
