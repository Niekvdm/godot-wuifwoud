# Copyright (c) 2026 Digitzone
# SPDX-License-Identifier: MIT
@tool
extends Button
## A compact species picker (the Tree and Row panel, the Import dialog's rule inspector): the species picked, its
## picture and name, or By type (the forest type picks); a click opens a popover under it, a grid of picture tiles with
## a search (Enter picks the first it shows) and By type first. A tile clicked closes the popover and is `picked` (its id, "" for By type) once that
## click's input is done, so an owner that rebuilds on a pick never takes the popover out of the tree under the mouse.
## A species that grows nowhere (switched off, or in no pack) or whose mesh is missing is red and says why; one picked
## already stays offered.

## A species picked ("": By type).
signal picked(id: String)

## The building blocks.
const KitRes := preload("res://addons/wuifwoud/editor/common/forest_kit.gd")
## The species pictures.
const PicturesRes := preload("res://addons/wuifwoud/editor/common/forest_pictures.gd")
## A species tile.
const SpeciesTileRes := preload("res://addons/wuifwoud/editor/common/forest_species_tile.gd")
## The type icons (By type's tile).
const TypeTileRes := preload("res://addons/wuifwoud/editor/common/forest_type_tile.gd")
## The forest's species.
const VA := preload("res://addons/wuifwoud/forest_assets.gd")
## A species (its mesh path, resolved).
const SpeciesRes := preload("res://addons/wuifwoud/species/forest_species.gd")
## What By type is called.
const BY_TYPE := "By type"
## By type's tile: the mixed glyph on grey (the type picks).
const BY_TYPE_COLOUR := Color(0.42, 0.45, 0.43)
## A species that grows nowhere.
const ERROR := Color("ff8a80")
## The picture on the face (px).
const FACE_PX := 18
## A tile in the popover (px).
const TILE_PX := 56
## Tiles a row.
const COLUMNS := 6
## The popover's size: a long list scrolls inside it.
const POP_SIZE := Vector2i(400, 380)

## The species picked ("": By type).
var current := ""
## The species it offers (choices()).
var offered := PackedStringArray()
## The popover's search.
var search := ""
## ForestKit.
var kit = null
## The accent.
var accent := Color.WHITE
## Before its node names: "New" names it NewSpecies, its tiles NewSpecies_<id>.
var prefix := ""
var _pop: PopupPanel = null
var _search: LineEdit = null
var _grid: GridContainer = null


## The picker with `p_kit` (a ForestKit, or the overlay's component script, or null: plain controls), species
## `p_current` ("": By type), the species it offers (choices()), the accent and `p_prefix` before its node names;
## returns itself.
func setup(p_kit, p_current: String, p_offered: PackedStringArray, p_accent: Color, p_prefix := "") -> Button:
	kit = p_kit if p_kit is KitRes else KitRes.new(p_kit)
	current = p_current
	offered = p_offered
	accent = p_accent
	prefix = p_prefix
	kit.chip("", false, accent, self)
	name = prefix + "Species"
	alignment = HORIZONTAL_ALIGNMENT_LEFT
	clip_text = true
	text_overrun_behavior = TextServer.OVERRUN_TRIM_ELLIPSIS
	add_theme_constant_override("icon_max_width", FACE_PX)
	pressed.connect(open)
	_face()
	return self


## The species a picker offers: `names` (the forest's: its profile's pools and its types' mixes) and every species the
## packs grow, each once, sorted by name.
static func choices(names: PackedStringArray) -> PackedStringArray:
	var seen := {}
	for id in names:
		seen[String(id)] = true
	for id in VA.species_ids():
		seen[String(id)] = true
	var out: Array = seen.keys()
	out.sort_custom(func(a, b) -> bool:
		var ca := caption_of(String(a)).to_lower()
		var cb := caption_of(String(b)).to_lower()
		return ca < cb if ca != cb else String(a) < String(b))
	return PackedStringArray(out)


## Species `id`'s name in the picker: its display name, else its id with "_" as spaces; "By type" for "".
static func caption_of(id: String) -> String:
	if id == "":
		return BY_TYPE
	var sp = VA.species_of(id)
	return SpeciesTileRes.caption(sp) if sp != null else id.replace("_", " ")


## Species `id`'s picture (By type's tile for "").
static func picture_of(id: String) -> Texture2D:
	return TypeTileRes.texture("mixed", BY_TYPE_COLOUR, 64) if id == "" else PicturesRes.of_id(id)


## What is wrong with species `id` ("" when nothing, and for By type): switched off or in no species pack (its type
## picks), or its mesh is missing.
static func why(id: String) -> String:
	if id == "":
		return ""
	var sp = VA.species_of(id)
	if sp == null:
		return ("switched off" if VA.is_disabled(id) else "in no species pack") + ": its type picks"
	return "" if mesh_found(sp) else "its mesh is missing"


## Whether species `sp`'s mesh resolves to a file.
static func mesh_found(sp) -> bool:
	var m := SpeciesRes.resolve(String(sp.mesh))
	return m != "" and ResourceLoader.exists(m)


## The species the popover shows: those offered (the one picked first when it is not), narrowed by the search (id or
## name).
func shown_ids() -> PackedStringArray:
	var ids := PackedStringArray(offered)
	if current != "" and not ids.has(current):
		ids.insert(0, current)
	var out := PackedStringArray()
	for id in ids:
		if _matches(String(id)):
			out.append(id)
	return out


## The popover under the face, filled afresh with the search emptied; shown when the picker is in a tree (a test drives
## it without one), its search field taking the keys.
func open() -> void:
	if _pop == null or not is_instance_valid(_pop):
		_build_pop()
	search = ""
	_search.text = ""
	_fill()
	if not is_inside_tree() or _pop.visible:
		return
	var at := get_screen_transform() * Vector2(0.0, size.y)
	_pop.popup(Rect2i(Vector2i(at.round()), POP_SIZE))
	_search.grab_focus.call_deferred()


## Species `id` ("": By type) picked: the face shows it, the popover closes, then `picked` (its owner may rebuild).
func choose(id: String) -> void:
	current = id
	_face()
	if _pop != null and is_instance_valid(_pop):
		_pop.hide()
	picked.emit(id)


## The search narrowed: the tiles it leaves out are hidden, none rebuilt (the field keeps its focus and caret).
func set_search(t: String) -> void:
	search = t
	if _grid == null:
		return
	for c in _grid.get_children():
		if c.has_meta("species"):
			(c as Control).visible = _matches(String(c.get_meta("species")))


func _matches(id: String) -> bool:
	var q := search.strip_edges().to_lower()
	return q == "" or id.to_lower().contains(q) or caption_of(id).to_lower().contains(q)


## Enter in the search: the first species it shows is picked (nothing for an empty search).
func _on_submit(t: String) -> void:
	set_search(t)
	if search.strip_edges() == "":
		return
	var ids := shown_ids()
	if not ids.is_empty():
		_on_tile(String(ids[0]))


## The face: the species' picture and name, a ▾; red with why when it grows nowhere.
func _face() -> void:
	var w := why(current)
	icon = picture_of(current)
	text = caption_of(current) + " ▾"
	tooltip_text = ("Species: %s" % caption_of(current)) + ((" (%s)" % w) if w != "" else "")
	if w != "":
		add_theme_color_override("font_color", ERROR)
	else:
		remove_theme_color_override("font_color")


func _build_pop() -> void:
	_pop = PopupPanel.new()
	_pop.name = prefix + "SpeciesPop"
	# Its size as a minimum, not only popup()'s rect: popup() clamps the rect to the usable screen, which a display
	# without screens (headless) reports as zero, and the popover would shrink to its search field.
	_pop.min_size = POP_SIZE
	add_child(_pop)
	var v := VBoxContainer.new()
	v.add_theme_constant_override("separation", 6)
	_pop.add_child(v)
	_search = kit.search_field("Search species")
	_search.name = prefix + "SpeciesSearch"
	_search.text_changed.connect(set_search)
	_search.text_submitted.connect(_on_submit)
	v.add_child(_search)
	var sc := ScrollContainer.new()
	sc.name = prefix + "SpeciesScroll"
	sc.size_flags_vertical = Control.SIZE_EXPAND_FILL
	sc.horizontal_scroll_mode = ScrollContainer.SCROLL_MODE_DISABLED
	v.add_child(sc)
	_grid = GridContainer.new()
	_grid.name = prefix + "SpeciesGrid"
	_grid.columns = COLUMNS
	sc.add_child(_grid)


## By type first, then a tile a species shown.
func _fill() -> void:
	for c in _grid.get_children():
		_grid.remove_child(c)
		c.queue_free()
	var by: Button = kit.tile(picture_of(""), BY_TYPE, accent, TILE_PX)
	by.name = prefix + "SpeciesBy"
	by.tooltip_text = "By type: the forest type picks the species"
	kit.set_tile_selected(by, current == "")
	by.pressed.connect(_on_tile.bind(""))
	_grid.add_child(by)
	for id in shown_ids():
		_grid.add_child(_tile(String(id)))


## A species' tile: its picture tile, a missing mesh's badge; one that grows nowhere framed red; each saying why.
func _tile(id: String) -> Button:
	var sp = VA.species_of(id)
	var t: Button
	if sp != null:
		var state := "built" if mesh_found(sp) else "missing"
		t = SpeciesTileRes.new().setup(kit, sp, VA.built_dir_of(id), state, true, id == current, accent, TILE_PX)
		t.draggable = false
		if state == "missing":
			t.tooltip_text = "%s (%s): %s" % [caption_of(id), id, why(id)]
	else:
		t = kit.tile(PicturesRes.glyph("broadleaf"), caption_of(id), ERROR, TILE_PX)
		kit.set_tile_selected(t, true)
		t.tooltip_text = "%s (%s): %s" % [caption_of(id), id, why(id)]
	t.name = prefix + "Species_" + id.validate_node_name()
	t.set_meta("species", id)
	t.pressed.connect(_on_tile.bind(id))
	return t


## A tile clicked: the popover closes now; the pick lands once this input is done, so an owner that rebuilds on it
## never takes the popover out of the tree inside its own input.
func _on_tile(id: String) -> void:
	if _pop != null and is_instance_valid(_pop):
		_pop.hide()
	choose.call_deferred(id)
