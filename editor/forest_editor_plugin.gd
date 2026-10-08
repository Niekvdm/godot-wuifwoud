# Copyright (c) 2026 Digitzone
# SPDX-License-Identifier: MIT
@tool
extends EditorPlugin
## Wuifwoud in the editor: the Forest menu (the preview switch, kept in the project's editor metadata and never in a
## scene; Re-grow; Build packs…), the Forest workspace in Terrain3D Extended when it is installed (1.2 or newer), the
## painted forest maps and the single trees and rows (trees.json) saved with the scene, and the Import dialog, opened
## from the workspace's ⋯, whose import runs on a worker this plugin polls every frame; when it lands, every forest map
## and trees file of that folder in the editor catches up (the unsaved edits were handed to the import). The forest node
## is @tool on its own: without this plugin it still previews, and nothing paints, places or imports. The edited
## scene's forest is found by ForestFinder. Build packs… opens the pack dialog, and the build it starts is polled here
## every frame; when it lands the packs are resolved again and the scene's forest regrows.

## The project's editor metadata section the plugin keeps its settings in.
const SECTION := "wuifwoud"
## The preview switch's key in that section.
const KEY_VISIBLE := "preview_visible"
## Terrain3D Extended's tool providers (the Forest workspace's host).
const PROVIDERS := "res://addons/terrain_3d_extended/src/tool_providers.gd"
## Terrain3D Extended's overlay components (the dialogs' look).
const UX_COMPONENTS := "res://addons/terrain_3d_extended/src/ux_components.gd"
## The forest node.
const ForestSpawnerRes := preload("res://addons/wuifwoud/forest_spawner.gd")
## The forest maps.
const ForestMapsRes := preload("res://addons/wuifwoud/forest_maps.gd")
## The editor preview's switch.
const ForestPreviewRes := preload("res://addons/wuifwoud/forest_preview.gd")
## The Forest workspace.
const ProviderRes := preload("res://addons/wuifwoud/editor/forest_paint_provider.gd")
## The Forest menu.
const MenuRes := preload("res://addons/wuifwoud/editor/forest_preview_menu.gd")
## The Import dialog.
const DialogRes := preload("res://addons/wuifwoud/editor/forest_import_dialog.gd")
## An import run.
const JobRes := preload("res://addons/wuifwoud/forest_import_job.gd")
## The sources' reader, shared by the dialog and the Revert brush.
const ReaderRes := preload("res://addons/wuifwoud/forest_source_reader.gd")
## An import mapping.
const MappingRes := preload("res://addons/wuifwoud/forest_mapping.gd")
## The single trees and rows.
const ForestTreesRes := preload("res://addons/wuifwoud/forest_trees.gd")
## The edited scene's forest, kept per scene.
const FinderRes := preload("res://addons/wuifwoud/editor/forest_finder.gd")
## A pack build.
const BuildRes := preload("res://addons/wuifwoud/species/forest_pack_build.gd")
## The Build packs dialog.
const BuildDialogRes := preload("res://addons/wuifwoud/editor/forest_pack_dialog.gd")
## The species' assets (their caches).
const ForestAssetsRes := preload("res://addons/wuifwoud/forest_assets.gd")

var _menu: MenuButton = null
var _paint = null
var _finder = FinderRes.new()   # the edited scene's forest
var _dialog: Control = null
var _job = null                 # the running or last import (ForestImportJob)
var _build = null               # the running or last pack build (ForestPackBuild)
var _build_dialog: Control = null
var _reader = ReaderRes.new()   # shared by the Import dialog and the Revert brush
var _picker: EditorFileDialog = null
var _doc := {"key": "", "doc": {}}   # the edited scene's mapping for the Revert brush; key "": read it again


func _get_plugin_name() -> String:
	return "Wuifwoud"


func _enter_tree() -> void:
	var es := EditorInterface.get_editor_settings()
	ForestPreviewRes.visible = bool(es.get_project_metadata(SECTION, KEY_VISIBLE, true))
	_menu = MenuRes.new()
	_menu.changed.connect(_on_menu_changed)
	_menu.regrow_requested.connect(_regrow)
	_menu.build_requested.connect(_open_build)
	add_control_to_container(CONTAINER_SPATIAL_EDITOR_MENU, _menu)
	_register_paint.call_deferred()


func _exit_tree() -> void:
	if _job != null and _job.is_running():
		_job.cancel()
		while not _job.poll():
			OS.delay_msec(5)
	if _build != null and _build.is_running():
		if _build.finished.is_connected(_on_built):
			_build.finished.disconnect(_on_built)   # no landing (a rescan, a regrow) while the plugin unloads
		_build.cancel()
		while not _build.poll():     # a running store is image work: it ends on its own
			OS.delay_msec(5)
	if _build_dialog != null and is_instance_valid(_build_dialog):
		_build_dialog.queue_free()
	_build_dialog = null
	_reader.wait()                  # its worker reads files and calls into scripts this plugin unloads
	if _dialog != null and is_instance_valid(_dialog):
		_dialog.queue_free()
	_dialog = null
	if _picker != null and is_instance_valid(_picker):
		_picker.queue_free()
	_picker = null
	if _paint != null and ResourceLoader.exists(PROVIDERS):
		load(PROVIDERS).unregister(_paint)
	_paint = null
	if _menu != null:
		remove_control_from_container(CONTAINER_SPATIAL_EDITOR_MENU, _menu)
		_menu.queue_free()
		_menu = null


## The import's worker, landed on the main thread (the swap, the catch-up), and the Place tools' overlay: every frame.
func _process(_dt: float) -> void:
	if _job != null and _job.is_running():
		_job.poll()
	if _build != null and _build.is_running():
		_build.poll()
		# The bake counts drawn frames: keep the editor drawing while a build runs (it may idle in low-processor mode).
		EditorInterface.get_base_control().queue_redraw()
	if _paint != null:
		_paint.tick()


func _on_menu_changed() -> void:
	EditorInterface.get_editor_settings().set_project_metadata(SECTION, KEY_VISIBLE, ForestPreviewRes.visible)


## Forest → Re-grow, and a build's landing: the packs resolved again (a pack or species added since), then the forest
## grown again from them.
func _regrow() -> void:
	var f := _forest()
	if f != null:
		f.reload_species()
	else:
		ForestAssetsRes.forget_packs()
		ForestAssetsRes.reset()


## The Forest workspace lives in the Terrain3D Extended overlay (1.2 or newer); without it there is none.
func _register_paint() -> void:
	if not ResourceLoader.exists(PROVIDERS):
		return
	var level := ProviderRes.overlay_level(load(PROVIDERS))
	if level < ProviderRes.NEEDS_LEVEL:
		push_error("Wuifwoud needs Terrain3D Extended 1.2 or newer for its Forest tools (tool providers level %d, found %d): the Forest workspace is off." % [ProviderRes.NEEDS_LEVEL, level])
		return
	_paint = ProviderRes.new()
	_paint.set_undo(get_undo_redo())
	_paint.forest_of = _forest
	_paint.reader = _reader
	_paint.importing = func() -> Dictionary: return _job.progress() if _job != null and _job.is_running() else {}
	_paint.mapping_of = _mapping_doc
	_paint.import_requested.connect(_open_import)
	load(PROVIDERS).register(_paint)


## The Import dialog for the edited scene, over the editor (Godot 4.8 hides the main screen): one at a time.
func _open_import() -> void:
	if _dialog != null and is_instance_valid(_dialog):
		return
	if not ResourceLoader.exists(UX_COMPONENTS):
		push_error("Wuifwoud's Import dialog is built with Terrain3D Extended's components (%s), which are missing." % UX_COMPONENTS)
		return
	var ctx := DialogRes.context_for(_forest(), load(UX_COMPONENTS))
	ctx["reader"] = _reader
	ctx["run"] = _run_import
	ctx["job_of"] = func(): return _job
	ctx["pick_file"] = _pick_file
	_dialog = DialogRes.new()
	_dialog.setup(ctx)
	_dialog.mapping_written.connect(func() -> void: _doc["key"] = "")
	_dialog.closed.connect(func() -> void: _dialog = null)
	EditorInterface.get_base_control().add_child(_dialog)


## Run (the dialog's): the unsaved paint of that maps folder handed over, the import started on a worker. "" when it
## started, else why not.
func _run_import(doc: Dictionary, discard: bool) -> String:
	if _job != null and _job.is_running():
		return "an import is running"
	_job = JobRes.new(doc, {"discard_painted": discard, "edits": JobRes.edits_for(doc),
		"trees": JobRes.trees_edits_for(doc)})
	_job.finished.connect(_on_imported)
	_job.start()
	return ""


## The import landed (the swap done): every live forest map and trees set of its folder catches up; each forest regrows
## on its own next frame (their generation moved); the Place tools' panel follows.
func _on_imported(report: Dictionary) -> void:
	ForestMapsRes.imported(report)
	ForestTreesRes.imported(report)
	if _paint != null:
		_paint.place.refresh()


## An editor file dialog over the editor: a file, or a folder when `dir`; `on_pick` gets the path.
func _pick_file(title: String, filters: PackedStringArray, dir: bool, on_pick: Callable) -> void:
	if _picker != null and is_instance_valid(_picker):
		_picker.queue_free()
	_picker = EditorFileDialog.new()
	_picker.title = title
	_picker.access = EditorFileDialog.ACCESS_RESOURCES
	_picker.file_mode = EditorFileDialog.FILE_MODE_OPEN_DIR if dir else EditorFileDialog.FILE_MODE_OPEN_FILE
	_picker.filters = filters
	_picker.file_selected.connect(func(p: String) -> void: on_pick.call(p))
	_picker.dir_selected.connect(func(p: String) -> void: on_pick.call(p))
	EditorInterface.get_base_control().add_child(_picker)
	_picker.popup_centered_ratio(0.6)


## The edited scene's mapping document ({}: none), for the Revert brush: read from its file again after the dialog wrote
## it or when the file changed on disk (its modified time and size).
func _mapping_doc() -> Dictionary:
	var p := DialogRes.mapping_path(_forest())
	if p == "" or not FileAccess.file_exists(p):
		return {}
	var fa := FileAccess.open(p, FileAccess.READ)
	var k := "%s|%d|%d" % [p, FileAccess.get_modified_time(p), fa.get_length() if fa != null else -1]
	if k != String(_doc["key"]):
		var m = MappingRes.new()
		_doc = {"key": k, "doc": m.doc if m.load_file(p) == OK else {}}
	return _doc["doc"]


## The scene save also writes the painted forest maps and the single trees and rows: every set with unsaved changes, a
## background scene tab's included.
func _save_external_data() -> void:
	for m in ForestMapsRes.unsaved_maps():
		m.save_dirty()
	for t in ForestTreesRes.unsaved():
		var e: Error = t.save()
		if e != OK:
			push_error("Wuifwoud: the single trees and rows were not saved to %s (%s)" % [t.path, error_string(e)])


## The prompt closing a scene (its maps and trees) or quitting ("": any).
func _get_unsaved_status(p_for_scene: String) -> String:
	if ForestMapsRes.unsaved_for(p_for_scene).is_empty() and ForestTreesRes.unsaved_for(p_for_scene).is_empty():
		return ""
	return "Save the forest maps and trees?"


## The edited scene's forest (null: the open scene has none), kept per scene by the finder.
func _forest() -> Node:
	return _finder.find(EditorInterface.get_edited_scene_root())


## Forest → Build packs…: the dialog over the editor, one at a time; it lists the packs the project grows.
func _open_build() -> void:
	if _build_dialog != null and is_instance_valid(_build_dialog):
		return
	var ctx := BuildDialogRes.context_for(load(UX_COMPONENTS) if ResourceLoader.exists(UX_COMPONENTS) else null)
	ctx["run"] = _run_build
	ctx["job_of"] = func(): return _build
	_build_dialog = BuildDialogRes.new()
	_build_dialog.setup(ctx)
	_build_dialog.closed.connect(func() -> void: _build_dialog = null)
	EditorInterface.get_base_control().add_child(_build_dialog)


## The dialog's Build: a pack build started, its bake under the editor's base control. "" when it started.
func _run_build(packs: Array, force: bool) -> String:
	if _build != null and _build.is_running():
		return "a build is running"
	_build = BuildRes.new(packs, {"force": force})
	_build.finished.connect(_on_built)
	_build.start(EditorInterface.get_base_control())
	return ""


## A build ended: the forest's caches dropped (its built species and sheets are new), the file system rescanned, the
## edited scene's forest regrown. A build that landed nothing (an early cancel) changes nothing.
func _on_built(report: Dictionary) -> void:
	if not BuildRes.landed_anything(report):
		return
	EditorInterface.get_resource_filesystem().scan()
	_regrow()
