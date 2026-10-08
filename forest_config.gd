# Copyright (c) 2026 Digitzone
# SPDX-License-Identifier: MIT
@tool
class_name ForestConfig
extends Resource
## Wuifwoud's one integration point: the feeder nodes that run under every ForestSpawner, the species packs, the
## fallback flora, and the trunk colliders' physics setup. The project ships it at DEFAULT_PATH; the project setting
## SETTING overrides the path (read only: nothing here writes project.godot). Without one the forest runs with no
## feeders and the starter pack, and says so once.

## Where the project's config lives unless the project setting SETTING says otherwise.
const DEFAULT_PATH := "res://wuifwoud_config.tres"
## The project setting that overrides DEFAULT_PATH (Wuifwoud only reads it).
const SETTING := "wuifwoud/config_path"
## The file a pack addon holds at its folder's root: a ForestPackSet.
const SET_FILE := "wuifwoud_packs.tres"

@export_group("Feeders")

## Feeder scripts (ForestFeeder) added under every ForestSpawner in the game, one node per script.
@export var runtime_inputs: Array[Script] = []

## Feeders that also run in the editor. Empty until the forest has an editor preview.
@export var editor_inputs: Array[Script] = []

@export_group("Species packs")

## The species packs this project lists first; pack addons (a ForestPackSet at res://addons/<name>/wuifwoud_packs.tres)
## are found without it, and the starter pack comes last (resolved_sources). Species ids are unique across them: the
## first resolved wins.
@export var packs: Array[ForestSpeciesPack] = []

## Packs not to grow, by res:// path: one the config lists, a whole pack addon (its wuifwoud_packs.tres), one pack of a
## pack addon, or the starter pack.
@export var disabled_packs := PackedStringArray()

@export_group("Flora")

## The flora used where a map names no profile: a profile file whose species and dead pools are the fallback. Empty:
## the starter pack's flora, unless the starter is disabled (starter_flora_path).
@export_file("*.json") var default_profile_path := ""

@export_group("Import")

## Where each map's forest import mapping lives: <imports_dir>/<the map scene's file name>.json (the editor's Import
## dialog). Empty: the dialog says where to set it.
@export_dir var imports_dir := ""

@export_group("Trunk colliders")

## Trunk colliders are kept around the members of this group.
@export var collision_group: StringName = &"vehicles"

## The trunk colliders' physics layer.
@export_flags_3d_physics var trunk_layer: int = 1

## The trunk colliders' physics mask.
@export_flags_3d_physics var trunk_mask: int = 1

## Metadata set on the trunk colliders' body, for a game's own collision handling.
@export var trunk_meta: Dictionary = {}

static var _current: ForestConfig = null


## The project's config, loaded once.
static func current() -> ForestConfig:
	if _current == null:
		_current = load_from(String(ProjectSettings.get_setting(SETTING, DEFAULT_PATH)))
	return _current


## The config at `path`; missing, or not a ForestConfig: an empty one, with one warning.
static func load_from(path: String) -> ForestConfig:
	var c: ForestConfig = null
	if ResourceLoader.exists(path):
		c = load(path) as ForestConfig
	if c == null:
		ForestLog.warn("[Wuifwoud] no ForestConfig at %s: the forest runs with no feeders, on the starter pack" % path)
		c = ForestConfig.new()
	return c


## For tools and tests: use `c` from now on; null forgets it (the next current() loads again).
static func use(c: ForestConfig) -> void:
	_current = c


## The packs that grow, by where they come from, in order: the ones this config lists, each pack addon's set (sorted
## by folder) in the set's own order, then the starter: [{name, kind ("project" | "addon" | "wuifwoud"), path,
## packs}], less disabled_packs; a pack counts once, where it comes first; a source left with no pack is left out. A
## set or a pack that will not load is skipped and named.
func resolved_sources(addons_dir := "res://addons") -> Array:
	var out := []
	var seen := {}
	for p in packs:
		if p == null:
			ForestLog.warn("[Wuifwoud] the config has an empty pack slot: skipped")
			continue
		if not seen.has(_key(p)) and not disabled_packs.has(p.resource_path):
			seen[_key(p)] = true
			out.append({"name": _label(p), "kind": "project", "path": p.resource_path, "packs": [p]})
	for path in discovered_set_paths(addons_dir):
		if disabled_packs.has(path):
			continue
		var ps = load(path)
		if not (ps is ForestPackSet):
			ForestLog.warn("[Wuifwoud] %s is not a pack set (ForestPackSet): skipped" % path)
			continue
		var mine := []
		for p in ps.packs:
			if p == null:
				ForestLog.warn("[Wuifwoud] %s lists a pack that will not load: skipped" % path)
				continue
			if not seen.has(_key(p)) and not disabled_packs.has(p.resource_path):
				seen[_key(p)] = true
				mine.append(p)
		if not mine.is_empty():
			var nm := String(ps.name) if String(ps.name) != "" else path.get_base_dir().get_file()
			out.append({"name": nm, "kind": "addon", "path": path, "packs": mine})
	var starter := starter_pack_path()
	if starter != "" and not disabled_packs.has(starter) and ResourceLoader.exists(starter):
		var st = load(starter)
		if st is ForestSpeciesPack and not seen.has(_key(st)):
			out.append({"name": "Starter trees", "kind": "wuifwoud", "path": starter, "packs": [st]})
	return out


## Every pack that grows, in resolved order (resolved_sources, flattened).
func resolved_packs(addons_dir := "res://addons") -> Array:
	var out := []
	for src in resolved_sources(addons_dir):
		out.append_array(src["packs"])
	return out


## Every <addons_dir>/<folder>/wuifwoud_packs.tres, sorted (ResourceLoader.list_directory, so an exported game finds
## them too).
static func discovered_set_paths(addons_dir := "res://addons") -> PackedStringArray:
	var out := PackedStringArray()
	for d in ResourceLoader.list_directory(addons_dir):
		if d.ends_with("/"):
			var p := addons_dir.path_join(d.trim_suffix("/")).path_join(SET_FILE)
			if ResourceLoader.exists(p):
				out.append(p)
	out.sort()
	return out


## The built-in starter pack, beside ForestConfig's own script (whatever the addon's folder is called, and whatever
## folder a subclass lives in).
func starter_pack_path() -> String:
	return _addon_dir().path_join("packs/starter/starter.tres")


## The starter pack's flora: the fallback flora when the config names none and the starter is not disabled.
func starter_flora_path() -> String:
	return _addon_dir().path_join("packs/starter/starter_flora.json")


## The addon's folder: ForestConfig's own script's, never a subclass's.
static func _addon_dir() -> String:
	return (ForestConfig as Script).resource_path.get_base_dir()


## A pack's identity for counting it once: its file, or the object for a pack that is not a file.
static func _key(p) -> Variant:
	return p.resource_path if String(p.resource_path) != "" else p


static func _label(p) -> String:
	return String(p.name) if String(p.name) != "" else String(p.resource_path).get_file()
