# Copyright (c) 2026 Digitzone
# SPDX-License-Identifier: MIT
extends RefCounted
## Wuifwoud names nothing of the game it runs in (Waailand's promise as a test): no res:// path outside
## the addon (the project's config file, a bare "res://" prefix and Terrain3D Extended's tool providers and UI kit, an
## optional integration behind ResourceLoader.exists, excepted), no /root/ node, no `Log.` autoload, no game class, no group
## read by a literal name. Every line listed is a dependency a public user of the addon would not have. Comments count:
## a public file that points at a game file is stale the day it ships. Every script outside tests/ and tools/ is @tool
## (the forest runs in the editor). The native core's source (native/: C++, its SConstruct, the .gdextension) is held
## to the same rule; its build products and the godot-cpp checkout its build links in are not the addon's text.
##
## Run with a unit-suite runner: static run() returns {name, passed, failed, details}.

const ROOT := "res://addons/wuifwoud/"
const SELF := "res://addons/wuifwoud/tests/test_wuifwoud_self_contained.gd"
const EXTS := ["gd", "gdshader", "gdshaderinc", "glsl", "tres", "tscn", "cfg", "gdextension", "cpp", "h"]
## Not the addon's text: the native build's products and the godot-cpp checkout it links in.
const SKIP_DIRS := ["godot-cpp", "bin"]
const ALLOWED_RES := ["res://addons/wuifwoud/", "res://wuifwoud_config.tres",
	"res://addons/terrain_3d_extended/src/tool_providers.gd", "res://addons/terrain_3d_extended/src/ux_components.gd"]
## The addons folder itself, exactly: where pack addons are found (res://addons/<name>/wuifwoud_packs.tres).
const ALLOWED_EXACT := ["res://addons", "res://addons/"]
## The host's names come from the host itself, not from a list that ages: every script class outside the addon
## (the project's class cache) and every autoload.
const OWN_GROUP := "wuifwoud_forest"


static func _host_names() -> PackedStringArray:
	var out := PackedStringArray()
	for c in ProjectSettings.get_global_class_list():
		if not String(c["path"]).begins_with(ROOT):
			out.append(String(c["class"]))
	for pr in ProjectSettings.get_property_list():
		var n := String(pr["name"])
		if n.begins_with("autoload/"):
			out.append(n.trim_prefix("autoload/"))
	return out


static func _chk(r: Dictionary, n: String, ok: bool) -> void:
	if ok:
		r.passed += 1
	else:
		r.failed += 1
		r.details.append("✗ " + n)


static func _files(dir: String, out: Array) -> void:
	for d in DirAccess.get_directories_at(dir):
		if not d.begins_with(".") and not (d in SKIP_DIRS):
			_files(dir + d + "/", out)
	for f in DirAccess.get_files_at(dir):
		if (f.get_extension() in EXTS or f == "SConstruct") and dir + f != SELF:
			out.append(dir + f)


static func run() -> Dictionary:
	var r := {"name": "wuifwoud_self_contained", "passed": 0, "failed": 0, "details": []}
	var files: Array = []
	_files(ROOT, files)
	_chk(r, "the addon has files to check (%d)" % files.size(), files.size() > 20)
	# Every script the forest runs is @tool: in the editor a script without it that the forest
	# instantiates is a placeholder whose methods never run, which no headless test can see (scripting is on there).
	var untool: Array = []
	for path in files:
		var rel := String(path).trim_prefix(ROOT)
		if rel.get_extension() != "gd" or rel.begins_with("tests/") or rel.begins_with("tools/"):
			continue
		var head := FileAccess.get_file_as_string(path).substr(0, 300)
		if not (head.begins_with("@tool") or head.contains("\n@tool")):
			untool.append(rel)
	_chk(r, "every script outside tests/ and tools/ is @tool (%s)" % str(untool), untool.is_empty())
	var res_re := RegEx.create_from_string("res://[A-Za-z0-9_./-]*")
	var log_re := RegEx.create_from_string("(^|[^A-Za-z0-9_.])Log\\.")
	var host := _host_names()
	# The class list is read when it holds the addon's own classes; a small host may have few names of its own, or none.
	var own := ProjectSettings.get_global_class_list().any(func(c): return String(c["class"]) == "ForestSpawner")
	_chk(r, "the class list is read: it holds the addon's own (the host's names: %d)" % host.size(), own)
	var cls_re: RegEx = RegEx.create_from_string("\\b(" + "|".join(host) + ")\\b") if not host.is_empty() else null
	var bare_re := RegEx.create_from_string("(?<![\\w./:])(src|data|tools|assets|road_cells|resources|test|terrain)/[\\w./-]+")
	var grp_re := RegEx.create_from_string("(get_nodes_in_group|is_in_group|add_to_group|call_group|get_first_node_in_group)\\(\\s*&?\"([^\"]+)\"")
	var bad := {"res:// path": [], "/root/ node": [], "Log autoload": [], "host class or autoload": [],
		"literal group": [], "bare host path": []}
	for path in files:
		var lines := FileAccess.get_file_as_string(path).split("\n")
		for i in lines.size():
			var l: String = lines[i]
			var at := "%s:%d" % [String(path).trim_prefix(ROOT), i + 1]
			for m in res_re.search_all(l):
				var p := m.get_string()
				if p != "res://" and not ALLOWED_EXACT.has(p) and not ALLOWED_RES.any(func(a): return p.begins_with(a)):
					bad["res:// path"].append("%s %s" % [at, p])
			if l.contains("/root/"):
				bad["/root/ node"].append(at)
			if log_re.search(l) != null:
				bad["Log autoload"].append(at)
			var cm := cls_re.search(l) if cls_re != null else null
			if cm != null:
				bad["host class or autoload"].append("%s %s" % [at, cm.get_string()])
			for gm in grp_re.search_all(l):
				if gm.get_string(2) != OWN_GROUP:
					bad["literal group"].append("%s %s" % [at, gm.get_string(2)])
			for bm in bare_re.search_all(l):
				bad["bare host path"].append("%s %s" % [at, bm.get_string()])
	for k in bad:
		var list: Array = bad[k]
		_chk(r, "no %s (%d: %s)" % [k, list.size(), ", ".join(list.slice(0, 12))], list.is_empty())
	return r
