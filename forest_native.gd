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
## WITHOUT THE LIBRARY the forest grows nothing, near or far, and says so once; the game runs. A LIBRARY OF
## ANOTHER VERSION (built before these scripts, or an editor still holding the old one) counts as none and says so once:
## rebuild it, then restart the editor; it would otherwise fail job by job on the methods it lacks.

## The forest's log, through its sink.
const ForestLogRes := preload("res://addons/wuifwoud/forest_log.gd")
## The native core's class name.
const CLASS := &"WfCore"
## The library these scripts are written against: what WfCore.version() says.
const VERSION := "wuifwoud_core 3"
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
	ForestLogRes.warn(("[Wuifwoud] the forest's native core (the wuifwoud_core library, class %s) is not built, so no "
		+ "forest grows, near or far. Build it from addons/wuifwoud/native (the addon's README says how), then restart "
		+ "the editor, or run a headless --import once.") % CLASS)
