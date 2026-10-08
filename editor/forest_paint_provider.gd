# Copyright (c) 2026 Digitzone
# SPDX-License-Identifier: MIT
@tool
extends RefCounted
## The Forest workspace in Terrain3D Extended: a tool provider that paints itself (API v3, level 2). Its tools paint
## the edited scene's forest maps through ForestBrush (Paint, Ctrl: no forest; Replace; Density; Age; Smooth; Revert,
## back to the import mapping) and Pick reads one texel. Every stroke is
## one undo step in that scene's history; the touched cells grow again every REGROW_EVERY_MS during a stroke and at its
## end. The plugin hands it the forest (`forest_of`) and the undo manager, and saves the maps with the scene. The ⋯
## menu's Import… asks the plugin for the Import dialog; while an import runs no stroke starts (it would land in a map
## the import copied); a stroke from before an import no longer undoes. Tree and Row place
## single trees and rows: their strokes, hover, cursor note and panel go to ForestPlaceTools (forest_place_tools.gd).

## A tool finished (the overlay's tool API).
signal tool_done(tool_id: String)
## The library changed (the profile's types were read again).
signal library_changed
## "Import…": the plugin opens the dialog.
signal import_requested

## The texel rules.
const ForestBrushRes := preload("res://addons/wuifwoud/forest_brush.gd")
## The import (Revert's texels).
const ForestImportRes := preload("res://addons/wuifwoud/forest_import.gd")
## The forest's log, through its sink.
const ForestLogRes := preload("res://addons/wuifwoud/forest_log.gd")
## The Place tools.
const PlaceRes := preload("res://addons/wuifwoud/editor/forest_place_tools.gd")
## The Revert brush's cursor note asks for the mapping and the reader at most this often.
const REVERT_ASK_MS := 1000
## A cursor note older than this (ms) is dropped.
const STALE_NOTE_MS := 4000
## The workspace's icons.
const ICON_DIR := "res://addons/wuifwoud/editor/icons"
## The tool providers' level this needs (groups, descriptions, the From chip, the eyedropper, the header row).
const NEEDS_LEVEL := 2
## The touched cells grow again at most this often during a stroke (ms).
const REGROW_EVERY_MS := 250
## The workspace's tools: id, name, icon, and what the overlay shows for them.
const TOOLS := [
	{"id": "forest.paint", "title": "Paint", "icon": "forest_paint", "group": "paint",
		"description": "Paints a forest type. Ctrl: no forest."},
	{"id": "forest.replace", "title": "Replace", "icon": "forest_replace", "group": "paint", "source_item": true,
		"description": "Turns the From type into the selected one."},
	{"id": "forest.density", "title": "Density", "icon": "forest_density", "group": "shape",
		"description": "Raises the density. Ctrl: lowers it."},
	{"id": "forest.age", "title": "Age", "icon": "forest_age", "group": "shape",
		"description": "Older forest. Ctrl: younger."},
	{"id": "forest.smooth", "title": "Smooth", "icon": "forest_smooth", "group": "shape",
		"description": "Evens out density and age."},
	{"id": "forest.revert", "title": "Revert", "icon": "forest_revert", "group": "shape",
		"description": "Back to what the import mapping says (the texels lose their painted mark)."},
	{"id": "forest.tree", "title": "Tree", "icon": "forest_tree", "group": "place", "uses_size": false,
		"uses_strength": false, "description": "Places a single tree; drag one to move it. Ctrl: deletes it.",
		"inverse": {"title": "Delete tree", "icon": "forest_delete", "description": "Deletes the tree clicked."}},
	{"id": "forest.row", "title": "Row", "icon": "forest_row", "group": "place", "uses_size": false,
		"uses_strength": false,
		"description": "Draws a row of trees; drag a vertex to move it, the line to add one, Shift to move the row. Ctrl: deletes.",
		"inverse": {"title": "Delete", "icon": "forest_delete", "description": "Deletes the vertex, or the row, clicked."}},
	{"id": "forest.pick", "title": "Pick", "icon": "forest_pick", "uses_size": false, "uses_strength": false,
		"hidden": true, "description": "Picks the type under the cursor."},
]

## () -> the edited scene's forest (a ForestSpawner node) or null. Set by the plugin.
var forest_of := Callable()
## () -> the running import's progress ({"phase", "done", "total"}), or {} when none runs. Set by the plugin.
var importing := Callable()
## () -> the edited scene's import mapping ({} : none). Set by the plugin.
var mapping_of := Callable()
## The source reader the Import dialog shares (ForestSourceReader): the Revert brush's shapes. Set by the plugin.
var reader: RefCounted = null
## The tool in use.
var active_tool := "forest.paint"
## The type Paint and Replace paint.
var selected := 0
## Replace's From type.
var replace_from := 0
## The last Pick's readout (the panel's header row)
var picked := ""
var _undo: Object = null
var _invert := false       # Ctrl at the last brush_data() call, for the decal
var _brush = ForestBrushRes.new()
var _stroke := {}
var _before := {}          # Vector2i -> Image: a region's map before the stroke's first change there
var _last_send_ms := 0
var _stale_until := 0      # ms: the "not undone" note shows until then
## The Place tools: Tree and Row.
var place = PlaceRes.new()
var _revert_ask_ms := -100000      # when the Revert brush's note last asked for the mapping
var _revert_why := ""
var _ui_ref: WeakRef = null      # the overlay's UI node (activate): is a Place tool still its active tool?


func _init() -> void:
	place.bind(self)


func _is_place(p_tool: String) -> bool:
	return p_tool == PlaceRes.TREE or p_tool == PlaceRes.ROW


## The tool providers' feature level (1 for an overlay from before LEVEL existed).
static func overlay_level(providers: Script) -> int:
	return int(providers.get_script_constant_map().get("LEVEL", 1)) if providers != null else 0


## A type's swatch colour: a fixed hue per id, the same in every session.
static func color_of(id: int) -> Color:
	return Color.from_hsv(fposmod(float(id) * 0.618034, 1.0), 0.55, 0.85)


## The editor's undo manager.
func set_undo(p_ur: Object) -> void:
	_undo = p_ur


func _forest() -> Node:
	var f = forest_of.call() if forest_of.is_valid() else null
	return f if f != null and is_instance_valid(f) else null


# ── the workspace ──

## The workspace (the overlay's tool API).
func workspace() -> Dictionary:
	return {"id": "forest", "title": "Forest", "icon": "ws_forest", "order": 6, "library": "types",
		"library_tool": "forest.paint", "pick_tool": "forest.pick", "icon_dir": ICON_DIR, "api": 3,
		"paints_itself": true}


## The tools (the overlay's tool API).
func tools() -> Array:
	return TOOLS.duplicate(true)


## Activate a tool (the overlay's tool API).
func activate(p_tool: String, p_ui: Node) -> void:
	active_tool = p_tool
	_ui_ref = weakref(p_ui) if p_ui != null else null
	_revert_ask_ms = -100000         # a tool change asks for the mapping again at once


## Ctrl, kept for the decal (this provider paints itself: the brush data is not used).
func brush_data(p_invert := false) -> Dictionary:
	_invert = p_invert
	return {}


## The brush decal's colour (the overlay's tool API).
func decal_color() -> Color:
	if active_tool == "forest.paint" and _invert:
		return Color(0.6, 0.6, 0.6)
	return color_of(selected) if selected > 0 else Color.WHITE


## Where the view ray lands (provider API v3, called on every mouse event): unchanged; the Place tools hear the hover.
func project_hit(p_from: Vector3, _p_dir: Vector3, p_hit: Vector3) -> Vector3:
	if _is_place(active_tool):
		place.hover_at(active_tool, p_from, p_hit)
	return p_hit


## The plugin's frame: the Place tools' overlay shows while a Place tool is the overlay's active tool.
func tick() -> void:
	place.tick(_is_place(active_tool) and _overlay_has_us())


## The overlay's active tool is still one of this provider's (Terrain3D Extended gives a provider no "workspace left"
## call: its UI node's overlay is asked, behind has_method; without one, the last activate stands).
func _overlay_has_us() -> bool:
	var ui = _ui_ref.get_ref() if _ui_ref != null else null
	if ui == null:
		return true
	var ov = ui.get("overlay")
	if ov == null or not ov.has_method("active_provider"):
		return true
	return ov.active_provider() == self


## The library: the profile's types (the overlay's tool API).
func library() -> Dictionary:
	var f := _forest()
	var items := []
	var footer := "no forest in this scene"
	if f != null:
		var ids: Array = Array(f._types.ids())
		ids.sort()
		for id in ids:
			var t: Dictionary = f._types.get_type(id)
			items.append({"id": id, "name": String(t["name"]), "picture": _swatch(color_of(id)), "card": _card.bind(t)})
		footer = "%d types · %s" % [items.size(), String(f.profile_path).get_file()]
	return {"id": "types", "key": "forest.types", "placeholder": "Search types", "tool": "forest.paint",
		"items": items, "footer": footer, "footer_action": "reload"}


## A type's hover card: its style, density, clump and understory, and its road edge wall.
static func _card(t: Dictionary) -> Control:
	var lines := PackedStringArray(["%s (%d) · %s" % [t["name"], t["id"], t["style"]],
		"%.4f a m² (one every %.1f m)" % [float(t["density"]), float(t["pitch"])]])
	if String(t["style"]) == "natural":
		lines.append("clump %.2f · understory %.2f" % [float(t["clump"]), float(t["understory"])])
	if float(t["edge_wall_m"]) > 0.0 and float(t["edge_wall_mult"]) > 1.0:
		lines.append("road edge wall %.0f m ×%.1f" % [float(t["edge_wall_m"]), float(t["edge_wall_mult"])])
	var l := Label.new()
	l.text = "\n".join(lines)
	return l


## The selected type.
func library_selected() -> int:
	return selected


## Select a type.
func library_select(p_id: int) -> void:
	selected = p_id


## Replace's From type.
func source_selected() -> int:
	return replace_from


## Select Replace's From type.
func source_select(p_id: int) -> void:
	replace_from = p_id


## Size and strength are the bar's; the paint tools have no options of their own. The Place tools' panel is theirs.
func build_settings(box: VBoxContainer, p_tool: String, kit: Object, accent: Color) -> void:
	if _is_place(p_tool):
		place.build_panel(box, p_tool, kit, accent)


## The last Pick's readout, under the panel's header.
func build_header(box: VBoxContainer, kit: Object, _accent: Color) -> void:
	if picked != "":
		box.add_child(kit.description(picked))


## The ⋯ menu's actions.
func workspace_actions() -> Array:
	return [{"id": "import", "title": "Import…", "tooltip": "This map's import mapping: edit it and run the import"},
		{"id": "restore", "title": "Restore deleted imports", "tooltip": "Bring back the single trees and rows deleted from the import"},
		{"id": "reload", "title": "Reload types", "tooltip": "Read the flora profile again and re-grow the forest"},
		{"id": "regrow", "title": "Re-grow all", "tooltip": "Grow the whole preview again from the maps"}]


## Run a ⋯ menu action.
func workspace_action(p_id: String) -> void:
	if p_id == "import":
		import_requested.emit()
		return
	if p_id == "restore":
		place.restore_removed()
		return
	var f := _forest()
	if f == null:
		return
	if p_id == "reload":
		f.reload_types()
		library_changed.emit()
	elif p_id == "regrow":
		f.regrow_all()


## Amber: what is wrong or busy (the API passes no cursor position), or, for the Place tools, what a click does there
## (they hear the cursor through project_hit).
func cursor_note() -> String:
	if _is_place(active_tool):
		return place.note(active_tool)
	var f := _forest()
	if f == null:
		return "no forest in this scene"
	var prog := _import_progress()
	if not prog.is_empty():
		return "importing %d/%d" % [int(prog.get("done", 0)), int(prog.get("total", 0))]
	if not f.maps.configured():
		return "the forest's maps are not ready"
	if Time.get_ticks_msec() < _stale_until:
		return "painted before the import: not undone"
	if not (f.maps.unreadable as Dictionary).is_empty():
		return "map unreadable: %s" % String(f.maps.unreadable.values()[0]).get_file()
	if active_tool == "forest.revert":
		# The mapping and the reader are asked at most once a second: each ask stats the mapping's
		# files, and this note is drawn every frame.
		var now := Time.get_ticks_msec()
		if now - _revert_ask_ms >= REVERT_ASK_MS:
			_revert_ask_ms = now
			var m := _mapping()
			_revert_why = "no mapping: Import… first" if m.is_empty() or reader == null else ""
			if _revert_why == "":
				reader.request(m)
		if _revert_why != "":
			return _revert_why
		if not reader.poll():
			return "reading the mapping…"
	return ""


func _import_progress() -> Dictionary:
	var p = importing.call() if importing.is_valid() else {}
	return p if p is Dictionary else {}


func _mapping() -> Dictionary:
	var m = mapping_of.call() if mapping_of.is_valid() else {}
	return m if m is Dictionary else {}


## The state an undo step restores (the overlay's tool API).
func capture(_tool: String) -> Dictionary:
	return {"type": selected, "from": replace_from, "age": place.age, "species": place.species,
		"tree_clear": place.tree_clear, "row_clear": place.row_clear, "spacing": place.spacing}


## Restore a state (the overlay's tool API).
func apply(_tool: String, state: Dictionary) -> void:
	selected = int(state.get("type", selected))
	replace_from = int(state.get("from", replace_from))
	place.age = float(state.get("age", place.age))
	place.species = str(state.get("species", place.species))
	place.tree_clear = float(state.get("tree_clear", place.tree_clear))
	place.row_clear = float(state.get("row_clear", place.row_clear))
	place.spacing = float(state.get("spacing", place.spacing))


# ── strokes (API v3) ──

## A stroke begins at `p_hit` with the brush (the overlay's tool API).
func stroke_begin(p_hit: Vector3, p_brush: Dictionary) -> void:
	if _is_place(active_tool):
		place.begin(active_tool, p_hit, p_brush)
		return
	var f := _forest()
	if f == null or not f.maps.editing or not f.maps.configured() or not _import_progress().is_empty():
		return                           # an import is running: no stroke lands in a map it copied
	if active_tool == "forest.pick":
		_pick(f, p_hit)
		tool_done.emit("forest.pick")
		return
	var maps = f.maps
	_brush.revert_of = Callable()
	if active_tool == "forest.revert":
		var m := _mapping()
		if m.is_empty() or reader == null:
			return
		reader.request(m)
		if not reader.poll():
			return
		var shapes: Array = reader.rules["shapes"]
		var rm: float = maps.region_m()
		# The mapping's texels at the edited map's own size (its w), whatever the mapping's texel size says.
		_brush.revert_of = func(loc: Vector2i, rect: Rect2i, w: int) -> PackedByteArray:
			return ForestImportRes.paint_rect(loc, rm, w, shapes, rect)
	_brush.image_of = maps.edit_image
	_brush.region_m = maps.region_m()
	_brush.begin()
	_before.clear()
	_brush.on_first_change = func(loc: Vector2i) -> void:
		_before[loc] = (maps.edit_image(loc) as Image).duplicate()
		maps.mark_dirty(loc)         # dirty now: a stroke whose release never comes still saves
	_stroke = {"brush": p_brush, "op": op_for(active_tool, bool(p_brush.get("invert", false))), "forest": f}
	_last_send_ms = Time.get_ticks_msec()
	_brush.dab(p_hit, p_brush, _stroke["op"])


## The stroke continues to `p_hit`.
func stroke_to(p_hit: Vector3) -> void:
	if _is_place(active_tool):
		place.drag(p_hit)
		return
	if _stroke.is_empty():
		return
	_brush.dab(p_hit, _stroke["brush"], _stroke["op"])
	_send(false)


## One undo action for the stroke: each touched region's rectangle, before and after (already applied).
func stroke_end() -> void:
	if _is_place(active_tool):
		place.end()
		return
	if _stroke.is_empty():
		return
	_send(true)
	var f: Node = _stroke["forest"]
	if is_instance_valid(f) and not _brush.touched.is_empty():
		# The card cells the stroke crossed grow again once, now (the sends regrew only the mesh chunks).
		for loc in _brush.touched:
			f.regrow(f.maps.world_rect(loc, _brush.touched[loc]), false, true)
		var steps := []
		for loc in _brush.touched:
			var rect: Rect2i = _brush.touched[loc]
			steps.append([loc, rect.position, (_before[loc] as Image).get_region(rect),
				(f.maps.edit_image(loc) as Image).get_region(rect)])
		if _undo != null:
			# The forest node is the context: the stroke is undone in its scene's history (per-scene Ctrl+Z, the tab
			# shows (*)), not the editor's global one.
			var gen: int = f.maps.generation
			_undo.create_action(String(_stroke["op"]["label"]), UndoRedo.MERGE_DISABLE, f)
			for s in steps:
				_undo.add_do_method(self, &"_blit", f, gen, s[0], s[1], s[3])
				_undo.add_undo_method(self, &"_blit", f, gen, s[0], s[1], s[2])
			_undo.commit_action(false)
	_before.clear()
	_stroke = {}


## The op a tool stands for, Ctrl (`p_invert`) inverting Paint, Density and Age; Replace and Smooth ignore it.
func op_for(p_tool: String, p_invert: bool) -> Dictionary:
	var o: int = ForestBrushRes.Op.SMOOTH
	match p_tool:
		"forest.paint":
			o = ForestBrushRes.Op.ERASE if p_invert else ForestBrushRes.Op.PAINT
		"forest.replace":
			o = ForestBrushRes.Op.REPLACE
		"forest.density":
			o = ForestBrushRes.Op.DENSITY_DOWN if p_invert else ForestBrushRes.Op.DENSITY_UP
		"forest.age":
			o = ForestBrushRes.Op.AGE_DOWN if p_invert else ForestBrushRes.Op.AGE_UP
		"forest.revert":
			o = ForestBrushRes.Op.REVERT
	var label := "Forest"
	for t in TOOLS:
		if t["id"] == p_tool:
			label = "Forest: " + String(t["title"])
	return {"op": o, "type": selected, "from": replace_from, "label": label}


## The rectangles changed since the last send go back into the held maps and their mesh chunks grow again: at most
## every REGROW_EVERY_MS during a stroke, and always at its end. The 1 km card cells wait for the stroke's
## end (stroke_end): resubmitted every send, a card cell would stay missing for the whole stroke.
func _send(p_force: bool) -> void:
	var now := Time.get_ticks_msec()
	if not p_force and now - _last_send_ms < REGROW_EVERY_MS:
		return
	_last_send_ms = now
	var f = _stroke.get("forest")
	if f == null or not is_instance_valid(f):
		return
	var fresh: Dictionary = _brush.take_fresh()
	for loc in fresh:
		f.maps.refresh(loc, fresh[loc])
		f.regrow(f.maps.world_rect(loc, fresh[loc]), true, false)


## Undo and redo: a region's rectangle put back (all four channels, marks included), then the same refresh and regrow.
## A stroke from before an import changes nothing: its rectangle would put the old import's texels back
## over the new; it says so. Nor does one while an import runs: the import copied the map with the stroke in it, and
## its swap would bring the stroke back over the undo (the cursor note says the import runs).
func _blit(f: Node, gen: int, loc: Vector2i, at: Vector2i, crop: Image) -> void:
	if not is_instance_valid(f):
		return
	if not _import_progress().is_empty():
		ForestLogRes.warn("[Wuifwoud] a Forest stroke is not undone or redone while an import runs: the import copied the map with it")
		return
	if int(f.maps.generation) != gen:
		if Time.get_ticks_msec() >= _stale_until:
			ForestLogRes.warn("[Wuifwoud] a Forest stroke from before the last import is not undone or redone: it would put the old import back")
		_stale_until = Time.get_ticks_msec() + STALE_NOTE_MS
		return
	var img: Image = f.maps.edit_image(loc)
	if img == null:
		return
	img.blit_rect(crop, Rect2i(Vector2i.ZERO, crop.get_size()), at)
	f.maps.mark_dirty(loc)
	var rect := Rect2i(at, crop.get_size())
	f.maps.refresh(loc, rect)
	f.regrow(f.maps.world_rect(loc, rect))


func _pick(f: Node, p_hit: Vector3) -> void:
	var px: PackedInt32Array = f.maps.pixel_at(p_hit.x, p_hit.z)
	if px.is_empty():
		picked = "Picked: no forest map here"
		return
	var nm := "no forest"
	if px[0] != 0:
		var t: Dictionary = f._types.get_type(px[0])
		nm = String(t.get("name", "type %d (not in the profile)" % px[0]))
		if not t.is_empty():
			selected = px[0]
	picked = "Picked: %s · density %d %% · age %+.2f · %s" % [nm, roundi(float(px[1]) * 100.0 / 255.0),
		clampf(float(px[2] - 128) / 127.0, -1.0, 1.0), "painted" if px[3] == 255 else "as imported"]


## A plain colour tile.
static func _swatch(c: Color) -> Texture2D:
	var img := Image.create_empty(8, 8, false, Image.FORMAT_RGB8)
	img.fill(c)
	return ImageTexture.create_from_image(img)
