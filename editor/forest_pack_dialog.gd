# Copyright (c) 2026 Digitzone
# SPDX-License-Identifier: MIT
@tool
extends Control
## Forest → Build packs…: centred and modal over the editor, every pack the project grows and
## each species' state (built; needs building, and why; not built; mesh missing), Build what's needed and Rebuild all;
## while a build runs, its progress and Cancel (at once, as the Import dialog's: the species already built stay); then
## its report. The plugin runs the build (`run`) and polls it; this dialog only watches, and may close and reopen while
## it runs. Built in code: with Terrain3D Extended's overlay components when installed (`kit`), plain controls when not
## (building a pack needs no terrain overlay).

## The dialog closed.
signal closed

## A pack build (its states).
const BuildRes := preload("res://addons/wuifwoud/species/forest_pack_build.gd")
## The dialog's size.
const SIZE := Vector2(900, 620)
## The backdrop over the editor.
const BACKDROP := Color(0.0, 0.0, 0.0, 0.45)
## Secondary text.
const DIM := Color(1.0, 1.0, 1.0, 0.55)
## Errors.
const ERROR := Color("ff8a80")
## Warnings.
const AMBER := Color("ffcc80")
## Built.
const GOOD := Color("aed581")
## The panel's opacity.
const PANEL_ALPHA := 0.94
## Terrain3D Extended's modal group: while the dialog is in it, the overlay hides and the terrain takes no 3D input.
const UX_MODAL_GROUP := &"terrain_3d_ux_modal"
## A species' state as the list says it.
const STATE_TEXT := {"built": "built", "needs": "needs building", "unbuilt": "not built", "missing": "mesh missing"}
## A state's colour.
const STATE_COLOUR := {"built": GOOD, "needs": AMBER, "unbuilt": AMBER, "missing": ERROR}
## A build phase as the progress line says it.
const VERB := {"prepare": "Preparing", "bake": "Baking", "store": "Storing", "land": "Built"}

## The overlay's components; null: plain controls.
var kit: Object = null
## The accent colour (the overlay's).
var accent := Color("7cb342")
## ForestSpeciesPack, as the project grows them.
var packs: Array = []
## (packs: Array, force: bool) -> String: "" when it started, else why not.
var run := Callable()
## () -> the running or last build, or null.
var job_of := Callable()
## The last build's, until the next one or the dialog closes.
var report := {}
## What went wrong starting a build ("": nothing).
var error := ""
## ForestPackBuild.states(packs), read on each rebuild.
var rows: Array = []
var _watch = null                  # the build shown here
var _panel: PanelContainer
var _content: VBoxContainer


## The packs and the plugin's callables; builds the view.
func setup(p: Dictionary) -> void:
	kit = p.get("kit")
	accent = p.get("accent", accent)
	packs = p.get("packs", [])
	run = p.get("run", Callable())
	job_of = p.get("job_of", Callable())
	var j = job_of.call() if job_of.is_valid() else null
	if j != null and j.is_running():
		_watch = j                       # reopened while a build runs: its progress
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
	_panel = kit.glass_panel() if kit != null else PanelContainer.new()
	var base = _panel.get_theme_stylebox("panel")
	if base is StyleBoxFlat:
		var sb := (base as StyleBoxFlat).duplicate() as StyleBoxFlat
		sb.bg_color.a = PANEL_ALPHA
		_panel.add_theme_stylebox_override("panel", sb)
	_panel.custom_minimum_size = SIZE
	center.add_child(_panel)
	_content = VBoxContainer.new()
	_content.add_theme_constant_override("separation", 8)
	_panel.add_child(_content)
	rebuild()


func _notification(what: int) -> void:
	if what == NOTIFICATION_ENTER_TREE:
		add_to_group(UX_MODAL_GROUP)
		# Top level: the whole window whatever the parent lays out, so the panel is centred and the backdrop takes
		# every click.
		top_level = true
		set_anchors_and_offsets_preset(PRESET_FULL_RECT)
	elif what == NOTIFICATION_RESIZED and _panel != null and is_inside_tree():
		_panel.custom_minimum_size = SIZE.min(get_viewport_rect().size - Vector2(40.0, 40.0))


## The build shown here, every frame: its progress while it runs, its report when it ends.
func _process(_dt: float) -> void:
	if _watch == null:
		return
	if _watch.is_running():
		_show_progress()
		return
	report = _watch.report
	_watch = null
	rebuild()


## The view from the packs' states (read again: a build changes them).
func rebuild() -> void:
	rows = BuildRes.states(packs)
	for c in _content.get_children():
		_content.remove_child(c)
		c.queue_free()
	_content.add_child(_header())
	if error != "":
		var e := _label(error, ERROR)
		e.name = "Error"
		_content.add_child(e)
	var body: Control
	if rows.is_empty():
		body = _label("No species pack grows in this project: list one in the Wuifwoud config, install a pack addon, or enable the starter pack.", DIM)
	else:
		body = _list()
	body.size_flags_vertical = SIZE_EXPAND_FILL
	_content.add_child(body)
	_content.add_child(_run_bar())
	if busy():
		_show_progress()


func _header() -> Control:
	var h := HBoxContainer.new()
	h.name = "Header"
	h.add_theme_constant_override("separation", 10)
	var title := Label.new()
	title.text = "BUILD PACKS"
	title.add_theme_color_override("font_color", accent)
	title.add_theme_font_size_override("font_size", 13)
	h.add_child(title)
	var what := _label("· %d pack(s), %d species" % [rows.size(), species_count()], DIM)
	what.size_flags_horizontal = SIZE_EXPAND_FILL
	h.add_child(what)
	h.add_child(_chip("Close", "✕", close, false))
	return h


func _list() -> Control:
	var sc := ScrollContainer.new()
	sc.name = "List"
	sc.horizontal_scroll_mode = ScrollContainer.SCROLL_MODE_DISABLED
	var v := VBoxContainer.new()
	v.size_flags_horizontal = SIZE_EXPAND_FILL
	sc.add_child(v)
	for row in rows:
		var where: String = row["dir"] if String(row["dir"]) != "" else "not saved as its own file: it cannot be built"
		var head := _label("%s · %s" % [row["name"], where], accent)
		head.name = "Pack_" + String(row["name"]).validate_node_name()
		v.add_child(head)
		for st in row["species"]:
			var h := HBoxContainer.new()
			h.name = "Species_" + String(st["id"]).validate_node_name()
			var idl := Label.new()
			idl.text = String(st["id"])
			idl.custom_minimum_size = Vector2(260, 0)
			h.add_child(idl)
			var t: String = STATE_TEXT[st["state"]]
			if String(st["why"]) != "" and String(st["why"]) != t:
				t += ": " + String(st["why"])
			var stl := _label(t, STATE_COLOUR[st["state"]])
			stl.name = "State"
			stl.autowrap_mode = TextServer.AUTOWRAP_OFF
			stl.clip_text = true
			stl.size_flags_horizontal = SIZE_EXPAND_FILL
			h.add_child(stl)
			v.add_child(h)
	return sc


func _run_bar() -> Control:
	var v := VBoxContainer.new()
	v.name = "RunBar"
	v.add_theme_constant_override("separation", 4)
	v.add_child(HSeparator.new())
	if busy():
		var h := HBoxContainer.new()
		h.add_theme_constant_override("separation", 10)
		var bar := ProgressBar.new()
		bar.name = "Progress"
		bar.show_percentage = false
		bar.custom_minimum_size = Vector2(0, 8)
		bar.size_flags_horizontal = SIZE_EXPAND_FILL
		bar.size_flags_vertical = SIZE_SHRINK_CENTER
		h.add_child(bar)
		var ph := Label.new()
		ph.name = "Phase"
		ph.text = phase_text()
		h.add_child(ph)
		h.add_child(_chip("Cancel", "Cancel", cancel_run, false))
		v.add_child(h)
		v.add_child(_label("The editor is free while it builds; closing this dialog does not stop it. Cancel keeps the species already built.", DIM))
		return v
	var n := needed_count()
	var h2 := HBoxContainer.new()
	h2.add_theme_constant_override("separation", 10)
	var info := _label("%d of %d species need building." % [n, species_count()] if n > 0 else "Every species that can be built is built.", DIM)
	info.name = "Needed"
	info.size_flags_horizontal = SIZE_EXPAND_FILL
	h2.add_child(info)
	h2.add_child(_chip("BuildNeeded", "Build what's needed", build_needed, n == 0 or not run.is_valid()))
	h2.add_child(_chip("RebuildAll", "Rebuild all", rebuild_all, buildable_count() == 0 or not run.is_valid()))
	v.add_child(h2)
	if not report.is_empty():
		v.add_child(_report())
	return v


func _report() -> Control:
	var v := VBoxContainer.new()
	v.name = "Report"
	var failed: Dictionary = report.get("failed", {})
	var sl := _label("%s%d built, %d up to date, %d failed, %d removed · %.1f s" % [
		"Cancelled: the species built before it stay. " if bool(report.get("cancelled", false)) else "",
		(report.get("built", []) as Array).size(), (report.get("skipped", []) as Array).size(), failed.size(),
		(report.get("removed", []) as Array).size(), float(report.get("ms", 0)) / 1000.0], DIM)
	sl.name = "Summary"
	v.add_child(sl)
	for id in failed:
		v.add_child(_label("%s: %s" % [id, failed[id]], ERROR))
	var warns: Dictionary = report.get("warnings", {})
	var ids := warns.keys()
	for id in ids.slice(0, 6):
		v.add_child(_label("%s: %s" % [id, "; ".join(PackedStringArray(warns[id]))], AMBER))
	if ids.size() > 6:
		v.add_child(_label("(+%d more with warnings)" % (ids.size() - 6), DIM))
	return v


## Species that need building and can be: not built, or out of date, in a pack that is its own file.
func needed_count() -> int:
	var n := 0
	for row in rows:
		if String(row["dir"]) == "":
			continue
		for st in row["species"]:
			if st["state"] in ["needs", "unbuilt"]:
				n += 1
	return n


## Species a Rebuild all would build: every one with a mesh in a pack that is its own file.
func buildable_count() -> int:
	var n := 0
	for row in rows:
		if String(row["dir"]) == "":
			continue
		for st in row["species"]:
			if st["state"] != "missing":
				n += 1
	return n


## How many species the packs hold.
func species_count() -> int:
	var n := 0
	for row in rows:
		n += (row["species"] as Array).size()
	return n


## Whether a build is running.
func busy() -> bool:
	return _watch != null and _watch.is_running()


## Build what's needed.
func build_needed() -> void:
	_launch(false)


## Rebuild every species.
func rebuild_all() -> void:
	_launch(true)


func _launch(force: bool) -> void:
	if busy() or not run.is_valid():
		return
	var why: String = run.call(packs, force)
	error = why
	if why == "":
		report = {}
		_watch = job_of.call() if job_of.is_valid() else null
	rebuild()


## Cancel the running build.
func cancel_run() -> void:
	if busy():
		_watch.cancel()


## The running build's phase, for the progress line.
func phase_text() -> String:
	if _watch == null:
		return ""
	var p: Dictionary = _watch.progress()
	var verb: String = VERB.get(String(p.get("phase", "")), "")
	if verb == "":
		return ""
	return "%s %s · %d of %d" % [verb, String(p.get("species", "")), int(p.get("done", 0)), int(p.get("total", 0))]


func _show_progress() -> void:
	var p: Dictionary = _watch.progress()
	var bar := _content.find_child("Progress", true, false) as ProgressBar
	if bar != null:
		bar.max_value = maxi(int(p.get("total", 0)), 1)
		bar.value = int(p.get("done", 0))
	var ph := _content.find_child("Phase", true, false) as Label
	if ph != null:
		ph.text = phase_text()


## Close the dialog (a running build carries on).
func close() -> void:
	closed.emit()
	queue_free()


func _input(ev: InputEvent) -> void:
	if ev is InputEventKey and ev.pressed and not ev.echo and (ev as InputEventKey).keycode == KEY_ESCAPE:
		close()
		var vp := get_viewport()
		if vp != null:
			vp.set_input_as_handled()


func _chip(nm: String, text: String, fn: Callable, off: bool) -> Button:
	var b: Button = kit.chip(text, false, accent) if kit != null else Button.new()
	b.name = nm
	if kit == null:
		b.text = text
	b.tooltip_text = text
	b.disabled = off
	b.focus_mode = FOCUS_NONE
	b.pressed.connect(fn)
	return b


func _label(text: String, c: Color) -> Label:
	var l := Label.new()
	l.text = text
	l.add_theme_color_override("font_color", c)
	l.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	return l


## The dialog's context for the editor: the overlay's components when installed, the packs the project grows.
static func context_for(p_kit: Object) -> Dictionary:
	return {"kit": p_kit, "packs": ForestConfig.current().resolved_packs()}
