# Copyright (c) 2026 Digitzone
# SPDX-License-Identifier: MIT
@tool
extends Control
## The Import dialog: centred and modal over the editor, it edits the open scene's import mapping in two tabs, Rules
## (the source's values, the rules in priority order, the selected rule) and Source (the files and the texel size),
## and runs the import off the main thread from its Run bar. Every change is one undo step: the
## mapping is snapshotted, changed, written and the view rebuilt from it; the maps change only on Run. Built in code with
## Terrain3D Extended's overlay components (`kit`); the Wuifwoud plugin opens it (context_for), tests drive it headless.

## The dialog closed.
signal closed
## After each write: the plugin's copy of the mapping (the Revert brush's) follows.
signal mapping_written

## An import mapping.
const MappingRes := preload("res://addons/wuifwoud/forest_mapping.gd")
## The project's forest config.
const ForestConfigRes := preload("res://addons/wuifwoud/forest_config.gd")
## The forest maps.
const ForestMapsRes := preload("res://addons/wuifwoud/forest_maps.gd")
## The terrain adapter.
const ForestTerrainRes := preload("res://addons/wuifwoud/forest_terrain.gd")
## The Forest workspace (its type colours).
const ProviderRes := preload("res://addons/wuifwoud/editor/forest_paint_provider.gd")
## The Rules tab.
const RulesTabRes := preload("res://addons/wuifwoud/editor/forest_import_rules_tab.gd")
## The Source tab.
const SourceTabRes := preload("res://addons/wuifwoud/editor/forest_import_source_tab.gd")
## The Run bar.
const RunBarRes := preload("res://addons/wuifwoud/editor/forest_import_run_bar.gd")
## Undo steps kept at most.
const UNDO_MAX := 100
## The dialog's size.
const SIZE := Vector2(1100, 680)
## The backdrop over the editor.
const BACKDROP := Color(0.0, 0.0, 0.0, 0.45)
## Secondary text.
const DIM := Color(1.0, 1.0, 1.0, 0.55)
## Errors.
const ERROR := Color("ff8a80")
## Warnings and questions.
const AMBER := Color("ffcc80")
## Inactive text.
const GREY := Color(0.62, 0.62, 0.62)
## The panel's opacity.
const PANEL_ALPHA := 0.94
## Terrain3D Extended's modal group (its tool providers' MODAL_GROUP): while the dialog is in it, the overlay hides and
## the terrain takes no 3D input, so a click on the dialog never paints underneath.
const UX_MODAL_GROUP := &"terrain_3d_ux_modal"
## What a change attempted while an import runs says.
const READ_ONLY := "Read-only while the import runs: that change was not made."

## ForestMapping; null: no mapping file yet.
var mapping = null
## The overlay's components.
var kit: Object
## The accent colour (the overlay's).
var accent := Color("7cb342")
## The open scene's name; "": no forest in it.
var scene := ""
## False: never saved, so its mapping has no name yet.
var saved_scene := true
## The scene's mapping file; "": the config names no imports_dir.
var path := ""
## The mapping file exists but could not be read.
var load_error := ""
## The scene's terrain folder: a new mapping starts from it.
var terrain_dir := ""
## Where the scene's forest reads its maps.
var maps_dir := ""
## [{"id", "name", "colour"}]: the profile's types.
var types: Array = []
## The profile's species (the inspector's picker)
var species: Array = []
## ForestSourceReader, shared with the Revert brush.
var reader: RefCounted = null
## (doc: Dictionary, discard: bool) -> String: "" when started, else why not.
var run := Callable()
## () -> the running or last import job, or null.
var job_of := Callable()
## (title, filters: PackedStringArray, dir: bool, on_pick: Callable(path)) -> void.
var pick_file := Callable()
## "rules" | "source".
var tab := "rules"
## The Values column's property key ("": the one the rules use most)
var key := ""
## "all" | "unmatched".
var value_filter := "all"
## The selected rule.
var selected := -1
## Overwrite painted texels.
var discard := false
## The overwrite question is up.
var asking := false
## The last run's report, until the next run or the dialog closes.
var report := {}
## What went wrong in the last write or run ("": nothing).
var error := ""
var _undo: Array = []
var _redo: Array = []
var _watch = null                 # the import job shown here
var _panel: PanelContainer
var _content: VBoxContainer
var _rebuilding := false
var _was_ready := false


## The dialog's context (context_for's) and the plugin's callables; builds the view.
func setup(p: Dictionary) -> void:
	mapping = p.get("mapping")
	kit = p["kit"]
	accent = p.get("accent", accent)
	scene = String(p.get("scene", ""))
	saved_scene = bool(p.get("saved", true))
	path = String(p.get("path", ""))
	load_error = String(p.get("load_error", ""))
	terrain_dir = String(p.get("terrain_dir", ""))
	maps_dir = String(p.get("maps_dir", ""))
	types = p.get("types", [])
	species = p.get("species", [])
	reader = p.get("reader")
	run = p.get("run", Callable())
	job_of = p.get("job_of", Callable())
	pick_file = p.get("pick_file", Callable())
	var j = job_of.call() if job_of.is_valid() else null
	if j != null and j.is_running():
		_watch = j                       # reopened while an import runs: its progress
	_ask_reader()
	set_anchors_and_offsets_preset(PRESET_FULL_RECT)
	mouse_filter = MOUSE_FILTER_STOP
	var back := ColorRect.new()
	back.color = BACKDROP
	back.mouse_filter = MOUSE_FILTER_IGNORE
	back.set_anchors_and_offsets_preset(PRESET_FULL_RECT)
	add_child(back)
	var center := CenterContainer.new()
	center.mouse_filter = MOUSE_FILTER_IGNORE
	center.set_anchors_and_offsets_preset(PRESET_FULL_RECT)
	add_child(center)
	_panel = kit.glass_panel()
	var sb := (_panel.get_theme_stylebox("panel") as StyleBoxFlat).duplicate() as StyleBoxFlat
	sb.bg_color.a = PANEL_ALPHA
	_panel.add_theme_stylebox_override("panel", sb)
	_panel.custom_minimum_size = SIZE
	center.add_child(_panel)
	_content = VBoxContainer.new()
	_content.add_theme_constant_override("separation", 8)
	_panel.add_child(_content)
	rebuild()
	_was_ready = read_ready()


func _notification(what: int) -> void:
	if what == NOTIFICATION_ENTER_TREE:
		add_to_group(UX_MODAL_GROUP)
		# Top level: the whole window whatever the parent lays out, so the panel is centred and the backdrop takes
		# every click.
		top_level = true
		set_anchors_and_offsets_preset(PRESET_FULL_RECT)
	elif what == NOTIFICATION_RESIZED and _panel != null and is_inside_tree():
		_panel.custom_minimum_size = SIZE.min(get_viewport_rect().size - Vector2(40.0, 40.0))


## The source reader and the import, landed every frame on the main thread (the plugin polls the job itself).
func _process(_dt: float) -> void:
	if reader != null:
		reader.poll()
	var ready := read_ready()
	if ready != _was_ready:
		_was_ready = ready
		rebuild()
	if _watch == null:
		return
	if _watch.is_running():
		_show_progress()
		return
	report = _watch.report
	_watch = null
	if error == READ_ONLY:
		error = ""
	rebuild()


## Rebuilds the view from the mapping (each change rebuilds it). Scroll positions are kept.
func rebuild() -> void:
	_rebuilding = true
	var scrolls := {}
	for sc in _content.find_children("*", "ScrollContainer", true, false):
		scrolls[String(sc.name)] = (sc as ScrollContainer).scroll_vertical
	for c in _content.get_children():
		_content.remove_child(c)
		c.queue_free()
	_content.add_child(_header())
	if error != "":
		var e := red(error)
		e.name = "Error"
		_content.add_child(e)
	var body: Control
	if scene == "":
		body = _message("This scene has no forest node.")
	elif not saved_scene:
		body = _message("Save the scene first: its import mapping is named after it.")
	elif path == "":
		body = _message("The Wuifwoud config names no imports_dir: set it to give each map its import mapping (<imports_dir>/<scene name>.json).")
	elif load_error != "":
		body = _message("%s could not be read (%s): fix or remove it in a text editor." % [path, load_error])
	elif mapping == null:
		body = _start_view()
	else:
		body = SourceTabRes.build(self) if tab == "source" else RulesTabRes.build(self)
		if busy():
			body = _shielded(body)
	body.size_flags_vertical = SIZE_EXPAND_FILL
	_content.add_child(body)
	if mapping != null:
		_content.add_child(RunBarRes.build(self))
	for sc in _content.find_children("*", "ScrollContainer", true, false):
		if scrolls.has(String(sc.name)):
			(sc as ScrollContainer).set_deferred("scroll_vertical", scrolls[String(sc.name)])
	_rebuilding = false
	if busy():
		_show_progress()


## While an import runs the tabs are read-only: a shield over them takes every click and says so.
func _shielded(body: Control) -> Control:
	var stack := Control.new()
	stack.name = "ReadOnlyStack"
	stack.add_child(body)
	body.set_anchors_and_offsets_preset(PRESET_FULL_RECT)
	var shield := ColorRect.new()
	shield.name = "ReadOnly"
	shield.color = Color(0.0, 0.0, 0.0, 0.25)
	shield.mouse_filter = MOUSE_FILTER_STOP
	shield.tooltip_text = "Read-only while the import runs"
	shield.set_anchors_and_offsets_preset(PRESET_FULL_RECT)
	stack.add_child(shield)
	return stack


func _header() -> Control:
	var h := HBoxContainer.new()
	h.name = "Header"
	h.add_theme_constant_override("separation", 10)
	var title := Label.new()
	title.text = "FOREST IMPORT"
	title.add_theme_color_override("font_color", accent)
	title.add_theme_font_size_override("font_size", 13)
	h.add_child(title)
	var where := Label.new()
	where.text = ("· %s · %s" % [scene, path]) if scene != "" else ""
	where.modulate = DIM
	where.clip_text = true
	where.size_flags_horizontal = SIZE_EXPAND_FILL
	h.add_child(where)
	if mapping != null:
		var group := ButtonGroup.new()
		for pair in [["Rules", "rules"], ["Source", "source"]]:
			var b: Button = kit.toggle_chip(pair[0], tab == pair[1], accent)
			b.name = "Tab" + String(pair[0])
			b.button_group = group
			b.pressed.connect(_show_tab.bind(String(pair[1])))
			h.add_child(b)
		h.add_child(_button("Undo", "↶", undo, _undo.is_empty() or busy()))
		h.add_child(_button("Redo", "↷", redo, _redo.is_empty() or busy()))
	h.add_child(_button("Close", "✕", close, false))
	return h


func _show_tab(id: String) -> void:
	tab = id
	rebuild()


func _button(nm: String, text: String, fn: Callable, off: bool) -> Button:
	var b := Button.new()
	b.name = nm
	b.text = text
	b.tooltip_text = nm
	b.disabled = off
	b.focus_mode = FOCUS_NONE
	b.pressed.connect(fn)
	return b


func _message(text: String) -> Label:
	var l := Label.new()
	l.text = text
	l.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	l.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	l.vertical_alignment = VERTICAL_ALIGNMENT_CENTER
	return l


func _start_view() -> Control:
	var v := VBoxContainer.new()
	v.alignment = BoxContainer.ALIGNMENT_CENTER
	v.add_child(_message("%s has no import mapping yet (%s). Start one: it reads the terrain in %s; choose the source next." % [
		scene, path, terrain_dir if terrain_dir != "" else "the folder you set"]))
	var b := Button.new()
	b.name = "Start"
	b.text = "Start a mapping"
	b.size_flags_horizontal = SIZE_SHRINK_CENTER
	b.pressed.connect(start_mapping)
	v.add_child(b)
	return v


## A new mapping for the scene, from its terrain folder.
func start_mapping() -> void:
	mapping = MappingRes.new()
	mapping.start(terrain_dir)
	tab = "source"
	_commit()


# --- every change one undo step ---

## One undo step: `fn` changes the mapping; it is written and the view rebuilt. Ignored while rebuilding (a field losing
## focus as the view is torn down); refused, and said, while an import runs (read-only).
func change(fn: Callable) -> void:
	if _rebuilding or mapping == null:
		return
	if busy():
		error = READ_ONLY
		rebuild()
		return
	_undo.append(mapping.snapshot())
	if _undo.size() > UNDO_MAX:
		_undo.pop_front()
	_redo.clear()
	fn.call()
	_commit()


## Undo the last change.
func undo() -> void:
	if _undo.is_empty() or busy():
		return
	_redo.append(mapping.snapshot())
	mapping.restore(_undo.pop_back())
	_commit()


## Redo the last undone change.
func redo() -> void:
	if _redo.is_empty() or busy():
		return
	_undo.append(mapping.snapshot())
	mapping.restore(_redo.pop_back())
	_commit()


func _commit() -> void:
	var err: int = mapping.save_file(path)
	error = "" if err == OK else "Could not write %s: %s" % [path, error_string(err)]
	selected = clampi(selected, -1, mapping.rules().size() - 1)
	_ask_reader()
	if err == OK:
		mapping_written.emit()
	rebuild()


func _ask_reader() -> void:
	if reader != null and mapping != null:
		reader.request(mapping.doc)


## Close the dialog.
func close() -> void:
	closed.emit()
	queue_free()


func _input(ev: InputEvent) -> void:
	if not (ev is InputEventKey) or not ev.pressed or ev.echo:
		return
	var k := ev as InputEventKey
	var vp := get_viewport()
	var typing := vp != null and vp.gui_get_focus_owner() is LineEdit
	if k.keycode == KEY_ESCAPE:
		if asking:
			cancel_question()
		else:
			close()
	elif mapping != null and not typing and k.ctrl_pressed and k.keycode == KEY_Z:
		if k.shift_pressed:
			redo()
		else:
			undo()
	elif mapping != null and not typing and k.ctrl_pressed and k.keycode == KEY_Y:
		redo()
	else:
		return
	if vp != null:
		vp.set_input_as_handled()


# --- the run ---

## The import shown here is running.
func busy() -> bool:
	return _watch != null and _watch.is_running()


## Why Run cannot start (empty: it can): the mapping's checks, the files' read errors, an import of another scene.
func run_errors() -> PackedStringArray:
	var out := PackedStringArray()
	if mapping == null:
		return out
	out.append_array(mapping.validate())
	if read_ready():
		for e in reader.files.get("errors", []):
			out.append(String(e))
	var j = job_of.call() if job_of.is_valid() else null
	if j != null and j.is_running() and j != _watch:
		out.append("an import of another scene is running")
	return out


## Run the import (asks first when it would overwrite paint).
func start_run() -> void:
	if discard:
		asking = true
		rebuild()
		return
	_launch(false)


## Overwrite painted texels: yes.
func confirm_overwrite() -> void:
	asking = false
	_launch(true)


## Overwrite painted texels: no.
func cancel_question() -> void:
	asking = false
	rebuild()


## Overwrite painted texels on the next run, or not.
func set_discard(on: bool) -> void:
	discard = on
	rebuild()


func _launch(p_discard: bool) -> void:
	if mapping == null or busy() or not run.is_valid():
		return
	var why: String = run.call(mapping.doc.duplicate(true), p_discard)
	error = why
	if why == "":
		report = {}
		_watch = job_of.call() if job_of.is_valid() else null
	rebuild()


## Cancel the running import.
func cancel_run() -> void:
	if busy():
		_watch.cancel()


## The running import's phase, for the Run bar.
func phase_text() -> String:
	if _watch == null:
		return ""
	var p: Dictionary = _watch.progress()
	match String(p.get("phase", "")):
		"read":
			return "Reading the source"
		"regions":
			return "Region %d of %d" % [int(p.get("done", 0)), int(p.get("total", 0))]
		"trees":
			return "Single trees and rows"
		"swap":
			return "Swapping"
	return ""


func _show_progress() -> void:
	var p: Dictionary = _watch.progress()
	var bar := _content.find_child("Progress", true, false) as ProgressBar
	if bar != null:
		bar.max_value = maxi(int(p.get("total", 0)), 1)
		bar.value = int(p.get("done", 0))
	var ph := _content.find_child("Phase", true, false) as Label
	if ph != null:
		ph.text = phase_text()


# --- what the tabs ask ---

## Select rule `i` (-1: none).
func select(i: int) -> void:
	selected = i
	rebuild()


## A file (or, `dir`, a folder) from the plugin's picker; `on_pick` gets its path.
func pick(title: String, filters: PackedStringArray, dir: bool, on_pick: Callable) -> void:
	if pick_file.is_valid():
		pick_file.call(title, filters, dir, on_pick)


## The reader holds this mapping's files and rules.
func read_ready() -> bool:
	return reader != null and mapping != null and reader.is_ready()


## A type's name ("No forest" for 0).
func type_name(id: int) -> String:
	if id == 0:
		return "No forest"
	for t in types:
		if int(t["id"]) == id:
			return String(t["name"])
	return "type %d: not in the profile" % id


## A type's colour.
func type_colour(id: int) -> Color:
	if id == 0:
		return GREY
	for t in types:
		if int(t["id"]) == id:
			return t["colour"]
	return ERROR


## Whether the profile has type `id`.
func has_type(id: int) -> bool:
	return id == 0 or types.any(func(t): return int(t["id"]) == id)


## The type a new rule paints: the profile's first.
func default_type() -> int:
	return int(types[0]["id"]) if not types.is_empty() else 1


## "kind: wood, forest; class: landuse", or "matches nothing yet".
func match_text(i: int) -> String:
	var parts := PackedStringArray()
	for k in (mapping.rules()[i]["match"] as Dictionary):
		parts.append("%s: %s" % [k, ", ".join(PackedStringArray(mapping.values_of(i, String(k))))])
	return "; ".join(parts) if not parts.is_empty() else "matches nothing yet"


## What rule i takes (≈: by first match, exclusions not subtracted): its area, the metres of rows and the trees of its
## lines and points; … while it is read.
func rule_area(i: int) -> String:
	if not read_ready():
		return "…"
	var parts := PackedStringArray()
	var m2: Array = reader.rules.get("rule_m2", [])
	var lm: Array = reader.rules.get("rule_m", [])
	var pn: Array = reader.rules.get("rule_n", [])
	if i < m2.size() and float(m2[i]) > 0.0:
		parts.append("≈ %.3f km²" % (float(m2[i]) / 1e6))
	if i < lm.size() and float(lm[i]) > 0.0:
		parts.append("%s of rows" % length_text(float(lm[i])))
	if i < pn.size() and int(pn[i]) > 0:
		parts.append("%d trees" % int(pn[i]))
	return " · ".join(parts) if not parts.is_empty() else "≈ 0.000 km²"


## What no rule matches, for the No rule row.
func unmatched_text() -> String:
	if not read_ready():
		return "…"
	var k := current_key()
	var free := values_of_key(k).filter(func(x): return mapping.rule_of_value(k, String(x)) < 0).size()
	return "grows nothing · %d value%s of %s · ≈ %.3f km² of features no rule matches" % [free, "" if free == 1 else "s",
		k, float(reader.rules.get("unmatched_m2", 0.0)) / 1e6]


## The Values column's key: the one picked, else the key the rules match on most, else the source's first.
func current_key() -> String:
	var keys := ordered_keys()
	if key != "" and keys.has(key):
		return key
	var uses := {}
	for rl in mapping.rules():
		for k in (rl.get("match", {}) as Dictionary):
			uses[String(k)] = int(uses.get(String(k), 0)) + 1
	var best := ""
	for k in keys:
		if uses.has(k) and (best == "" or int(uses[k]) > int(uses[best])):
			best = k
	return best if best != "" else (String(keys[0]) if not keys.is_empty() else "")


## The source's property keys: the useful first (fewest distinct values first), a key whose every feature has its own
## value (an id, a name) last.
func ordered_keys() -> Array:
	if not read_ready():
		return []
	var counts: Dictionary = reader.files["scan"]["counts"]
	var keys := counts.keys()
	keys.sort_custom(func(a, b) -> bool:
		var ua := unique_key(String(a))
		var ub := unique_key(String(b))
		if ua != ub:
			return ub
		var na: int = (counts[a] as Dictionary).size()
		var nb: int = (counts[b] as Dictionary).size()
		return na < nb if na != nb else String(a) < String(b))
	return keys


## Every feature has its own value of `k` (an id or a name): no use for rules.
func unique_key(k: String) -> bool:
	var c: Dictionary = (reader.files["scan"]["counts"] as Dictionary).get(k, {})
	return c.size() > 1 and c.values().all(func(n): return int(n) == 1)


## "0.25 km²", or "500 m²" below a hundredth of a km².
func area_text(m2: float) -> String:
	return ("%.2f km²" % (m2 / 1e6)) if m2 >= 1e4 else ("%d m²" % roundi(m2))


## The values of `k` across polygons, lines and points, largest first: by area, then metres of lines, then points.
func values_of_key(k: String) -> Array:
	var scan: Dictionary = reader.files["scan"]
	var areas: Dictionary = (scan.get("areas", {}) as Dictionary).get(k, {})
	var lens: Dictionary = (scan.get("lengths", {}) as Dictionary).get(k, {})
	var pts: Dictionary = (scan.get("points", {}) as Dictionary).get(k, {})
	var all := {}
	for src in [areas, lens, pts]:
		for x in src:
			all[x] = true
	var out := all.keys()
	out.sort_custom(func(a, b) -> bool:
		var aa := float(areas.get(a, 0.0))
		var ab := float(areas.get(b, 0.0))
		if aa != ab:
			return aa > ab
		var la := float(lens.get(a, 0.0))
		var lb := float(lens.get(b, 0.0))
		if la != lb:
			return la > lb
		var pa := int(pts.get(a, 0))
		var pb := int(pts.get(b, 0))
		return pa > pb if pa != pb else String(a) < String(b))
	return out


## What a value covers: its area, its metres of lines, its points ("500 m² · 2.60 km · 3 points").
func measure_text(k: String, val: String) -> String:
	var scan: Dictionary = reader.files["scan"]
	var a := float(((scan.get("areas", {}) as Dictionary).get(k, {}) as Dictionary).get(val, 0.0))
	var l := float(((scan.get("lengths", {}) as Dictionary).get(k, {}) as Dictionary).get(val, 0.0))
	var n := int(((scan.get("points", {}) as Dictionary).get(k, {}) as Dictionary).get(val, 0))
	var parts := PackedStringArray()
	if a > 0.0:
		parts.append(area_text(a))
	if l > 0.0:
		parts.append(length_text(l))
	if n > 0:
		parts.append("%d point%s" % [n, "" if n == 1 else "s"])
	return " · ".join(parts) if not parts.is_empty() else area_text(0.0)


## "2.60 km", or "120 m" below a kilometre.
func length_text(m: float) -> String:
	return ("%.2f km" % (m / 1000.0)) if m >= 1000.0 else ("%d m" % roundi(m))


## Show the values of property key `k`.
func pick_key(k: String) -> void:
	key = k
	rebuild()


## Show all values, or the unmatched ones.
func set_filter(f: String) -> void:
	value_filter = f
	rebuild()


## The folder the scene's forest reads its maps from.
func maps_folder() -> String:
	return str(mapping.doc.get("data_directory", "")).path_join(ForestMapsRes.FOLDER)


## A secondary label.
func hint(text: String) -> Label:
	var l := Label.new()
	l.text = text
	l.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	l.modulate = DIM
	l.add_theme_font_size_override("font_size", 11)
	return l


## A one-line dim note (in a row: a word-wrapping label there gets no width and wraps each letter).
func note(text: String) -> Label:
	var l := Label.new()
	l.text = text
	l.modulate = DIM
	l.add_theme_font_size_override("font_size", 10)
	l.size_flags_vertical = SIZE_SHRINK_CENTER
	return l


## An error label.
func red(text: String) -> Label:
	var l := hint(text)
	l.modulate = Color.WHITE
	l.add_theme_color_override("font_color", ERROR)
	return l


## A warning label.
func amber(text: String) -> Label:
	var l := hint(text)
	l.modulate = Color.WHITE
	l.add_theme_color_override("font_color", AMBER)
	return l


## A small square of colour.
func dot(c: Color) -> Control:
	var p := Panel.new()
	p.mouse_filter = MOUSE_FILTER_IGNORE
	p.custom_minimum_size = Vector2(9, 9)
	p.size_flags_vertical = SIZE_SHRINK_CENTER
	var sb := StyleBoxFlat.new()
	sb.bg_color = c
	sb.set_corner_radius_all(5)
	p.add_theme_stylebox_override("panel", sb)
	return p


## A square texture of colour, for a menu item.
func swatch(c: Color) -> Texture2D:
	var img := Image.create_empty(10, 10, false, Image.FORMAT_RGB8)
	img.fill(c)
	return ImageTexture.create_from_image(img)


## A flat style box.
static func box(bg: Color, border := Color(0, 0, 0, 0)) -> StyleBoxFlat:
	var sb := StyleBoxFlat.new()
	sb.bg_color = bg
	sb.set_corner_radius_all(8)
	if border.a > 0.0:
		sb.set_border_width_all(1)
		sb.border_color = border
	sb.content_margin_left = 8.0
	sb.content_margin_right = 8.0
	sb.content_margin_top = 6.0
	sb.content_margin_bottom = 6.0
	return sb


## The edited scene's mapping file: <imports_dir>/<the scene's file name>.json ("" when the config names no imports_dir
## or the scene was never saved).
static func mapping_path(forest: Node) -> String:
	if forest == null:
		return ""
	var root: Node = forest.owner if forest.owner != null else forest
	var dir := ForestConfigRes.current().imports_dir
	var sp := root.scene_file_path
	return dir.path_join(sp.get_file().get_basename() + ".json") if dir != "" and sp != "" else ""


## What the plugin opens the dialog with for the edited scene's forest (null: the scene has none): its mapping file (read
## when it exists; a file that cannot be read is named, never replaced), its terrain folder, where its maps are and the
## profile's types. The plugin adds reader, run, job_of and pick_file.
static func context_for(forest: Node, p_kit: Object) -> Dictionary:
	var ctx := {"kit": p_kit, "mapping": null, "scene": "", "saved": true, "path": "", "load_error": "",
		"terrain_dir": "", "maps_dir": "", "types": [], "species": []}
	if forest == null:
		return ctx
	var root: Node = forest.owner if forest.owner != null else forest
	var sp := root.scene_file_path
	ctx["scene"] = sp.get_file().get_basename() if sp != "" else String(root.name)
	ctx["saved"] = sp != ""
	ctx["path"] = mapping_path(forest)
	var t: Node = forest.terrain_source if forest.terrain_source != null else ForestTerrainRes.find_cached(forest)
	var dd = t.get("data_directory") if t != null else null
	ctx["terrain_dir"] = String(dd) if dd != null else ""
	ctx["maps_dir"] = String(forest.maps.directory)
	var ids: Array = Array(forest._types.ids())
	ids.sort()
	for id in ids:
		ctx["types"].append({"id": id, "name": String(forest._types.get_type(id).get("name", "type %d" % id)),
			"colour": ProviderRes.color_of(id)})
	ctx["species"] = Array(forest.species_names())
	if ctx["path"] != "" and FileAccess.file_exists(ctx["path"]):
		var m = MappingRes.new()
		var e: Error = m.load_file(ctx["path"])
		if e == OK:
			ctx["mapping"] = m
		else:
			ctx["load_error"] = m.problem if String(m.problem) != "" else error_string(e)
	return ctx
