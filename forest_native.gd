# Copyright (c) 2026 Digitzone
# SPDX-License-Identifier: MIT
@tool
extends RefCounted
## The forest's native core: the map summary, the scatter, the place, the far forest's build and the GPU path's
## instance arenas (WfArena, made by the core) run in a GDExtension library, wuifwoud_core (native/ in this addon,
## wuifwoud_core.gdextension), one call a job.
##
## REACHED ONLY THROUGH ClassDB, BY NAME. An editor that was open when the library was first built does not know its
## classes until it restarts, and a script that names one as an identifier does not parse there: every forest script
## that reached it would break. So no script names a native class: the core is made here with ClassDB.instantiate and
## held untyped, its methods called on the instance; its tables, road corridor and arenas come from its own methods.
##
## WITHOUT THE LIBRARY the forest grows nothing, near or far, and says so once (not built, or built but not loaded);
## the game runs. A LIBRARY OF
## ANOTHER VERSION (built before these scripts, or an editor still holding the old one) counts as none and says so once:
## rebuild it, then restart the editor; it would otherwise fail job by job on the methods it lacks.

## The forest's log, through its sink.
const ForestLogRes := preload("res://addons/wuifwoud/forest_log.gd")
## The native core's class name.
const CLASS := &"WfCore"
## The library these scripts are written against: what WfCore.version() says.
const VERSION := "wuifwoud_core 3"
## The extension file naming the library a platform loads.
const GDEXTENSION := "res://addons/wuifwoud/wuifwoud_core.gdextension"
## Tests: behave as if the library were not built.
static var force_absent := false
## Tests: the version asked for (anything else counts as stale); reprobe() after changing it.
static var expect_version := VERSION
static var _core = null
## The version the last probe asked for, "" before one. Not a boolean flag: an editor that hot-reloads this script
## may keep its statics, and a new one starts at "" either way, so the first call after the reload probes again and
## finds the older library the editor still holds.
static var _probed_for := ""
static var _warned := false
static var _found := ""    # the version a stale library said; "" when the library is current or not there at all


## The core (stateless, every method const, safe on any worker), or null when the library is not built or is of
## another version. Probed once, on the main thread: the forest asks before any job, and each job carries the core it
## was given.
static func core():
	if force_absent:
		return null
	if _probed_for != expect_version:
		_probed_for = expect_version
		_core = null
		_found = ""
		if ClassDB.class_exists(CLASS):
			var c = ClassDB.instantiate(CLASS)
			var v := str(c.version()) if c != null and c.has_method("version") else "?"
			if v == expect_version:
				_core = c
			else:
				_found = v
	return _core


## Whether the native core is there, of this version.
static func available() -> bool:
	return core() != null


## Tests: forget the probe and the warning, so the next core() looks again.
static func reprobe() -> void:
	_probed_for = ""
	_warned = false


## Said once: no forest grows without the library (or with one of another version), and what to do.
static func warn_missing() -> void:
	if _warned:
		return
	_warned = true
	core()
	if _found != "":
		ForestLogRes.warn(("[Wuifwoud] the forest's native core is out of date (the library says '%s', these scripts "
			+ "need '%s'), so no forest grows, near or far. Rebuild it from addons/wuifwoud/native (the addon's README "
			+ "says how), then restart the editor.") % [_found, expect_version])
		return
	var lib := library_path()
	ForestLogRes.warn(missing_text(not force_absent and lib != "" and FileAccess.file_exists(lib)))


## The library file this platform loads: the extension's entry whose feature tags (OS, build, CPU) all hold here; ""
## when it names none.
static func library_path() -> String:
	var cf := ConfigFile.new()
	if cf.load(GDEXTENSION) != OK or not cf.has_section("libraries"):
		return ""
	for key in cf.get_section_keys("libraries"):
		var all := true
		for tag in String(key).split("."):
			if not OS.has_feature(tag):
				all = false
				break
		if all:
			return str(cf.get_value("libraries", key))
	return ""


## What the warning says when the core is missing: `file_there`, its library is on disk but did not load; else it is
## not built. Both say where it comes from.
static func missing_text(file_there: bool) -> String:
	if file_there:
		return ("[Wuifwoud] the forest's native core (%s) is there but did not load, so no forest grows, near or far. "
			+ "An editor that was open when it was built loads it after a restart; otherwise the error loading it, above "
			+ "in the Output, says why (built for a newer system, or for another Godot): rebuild it from "
			+ "addons/wuifwoud/native (the addon's README says how).") % library_path().get_file()
	return ("[Wuifwoud] the forest's native core (the wuifwoud_core library, class %s) is not built, so no forest grows, "
		+ "near or far. Build it from addons/wuifwoud/native (the addon's README says how), then restart the editor, or "
		+ "run a headless --import once.") % CLASS
