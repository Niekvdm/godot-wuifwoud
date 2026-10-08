# Copyright (c) 2026 Digitzone
# SPDX-License-Identifier: MIT
@tool
extends Button
## A species tile in the Species dialog: its picture (ForestPictures), its name along the bottom, a dot at the top right
## (green: it grows; hollow: switched off, the tile dimmed), a badge at the top left ("build", amber: not built or out
## of date; "mesh missing", red), a bush's corner fold at the bottom right, and the accent frame when selected. Dragging
## it carries {"kind": KIND, "id"}; a click is `pressed`, a double click `activated`, a right click `menu_requested`.

## A double click.
signal activated
## A right click, at the screen position `at`.
signal menu_requested(at: Vector2)

## The pictures.
const PicturesRes := preload("res://addons/wuifwoud/editor/common/forest_pictures.gd")
## The drag kind of a species.
const KIND := "wuifwoud_species"
## A tile's size.
const PX := 70
## The dot of a species that grows.
const ON := Color("8bc34a")
## The "build" badge.
const AMBER := Color("ffb74d")
## The "mesh missing" badge.
const ERROR := Color("ff8a80")
## A switched-off tile's opacity.
const OFF_ALPHA := 0.42

## The species' id.
var id := ""


## The tile for species `sp` (its pack built in `dir`) in `state` ("built" | "needs" | "unbuilt" | "missing"), drawn
## with `kit` (ForestKit).
func setup(kit, sp, dir: String, state: String, enabled: bool, selected: bool, accent: Color, px := PX) -> Button:
	id = String(sp.id)
	name = "Tile_" + id.validate_node_name()
	kit.tile(PicturesRes.of(sp, dir), caption(sp), accent, px, self)
	kit.set_tile_selected(self, selected)
	tooltip_text = "%s (%s)" % [caption(sp), id]
	var dot := Panel.new()
	dot.name = "Dot"
	dot.mouse_filter = Control.MOUSE_FILTER_IGNORE
	dot.position = Vector2(px - 12, 4)
	dot.size = Vector2(8, 8)
	var sb := StyleBoxFlat.new()
	sb.set_corner_radius_all(4)
	if enabled:
		sb.bg_color = ON
	else:
		sb.bg_color = Color(0, 0, 0, 0)
		sb.set_border_width_all(1)
		sb.border_color = Color(0.8, 0.8, 0.8)
	dot.add_theme_stylebox_override("panel", sb)
	add_child(dot)
	var badge := badge_of(state)
	if badge != "":
		var l := Label.new()
		l.name = "Badge"
		l.text = badge
		l.mouse_filter = Control.MOUSE_FILTER_IGNORE
		l.position = Vector2(3, 2)
		l.add_theme_font_size_override("font_size", 9)
		l.add_theme_color_override("font_color", ERROR if state == "missing" else AMBER)
		var bb := StyleBoxFlat.new()
		bb.bg_color = Color(0, 0, 0, 0.55)
		bb.set_corner_radius_all(3)
		bb.content_margin_left = 3.0
		bb.content_margin_right = 3.0
		l.add_theme_stylebox_override("normal", bb)
		add_child(l)
	if String(sp.kind) == "bush":
		var fold := Polygon2D.new()
		fold.name = "Fold"
		fold.polygon = PackedVector2Array([Vector2(px, px - 30), Vector2(px, px - 18), Vector2(px - 12, px - 18)])
		fold.color = Color(0.55, 0.85, 0.95)
		add_child(fold)
	modulate.a = 1.0 if enabled else OFF_ALPHA
	return self


## A species' name on its tile: its display name, else its id with "_" as spaces.
static func caption(sp) -> String:
	var d := String(sp.display_name)
	return d if d != "" else String(sp.id).replace("_", " ")


## The badge a state wears ("" for none).
static func badge_of(state: String) -> String:
	match state:
		"needs", "unbuilt":
			return "build"
		"missing":
			return "mesh missing"
	return ""


func _get_drag_data(_at: Vector2) -> Variant:
	var pv := Label.new()
	pv.text = tooltip_text
	set_drag_preview(pv)
	return {"kind": KIND, "id": id}


func _gui_input(ev: InputEvent) -> void:
	var mb := ev as InputEventMouseButton
	if mb == null or not mb.pressed:
		return
	if mb.button_index == MOUSE_BUTTON_LEFT and mb.double_click:
		activated.emit()
		accept_event()
	elif mb.button_index == MOUSE_BUTTON_RIGHT:
		menu_requested.emit(get_global_mouse_position())
		accept_event()
