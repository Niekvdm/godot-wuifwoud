# Copyright (c) 2026 Digitzone
# SPDX-License-Identifier: MIT
@tool
extends RefCounted
## A forest import mapping as the Import dialog edits it: the whole document (every key kept, `_comment` and keys it
## does not know included), the rule operations the dialog's drops and fields make, undo
## snapshots, and a stable file: the known keys in schema order, then the rest; one rule a line; `type` and
## `texel_vertices` whole numbers; a rule's density 1 and age 0 left out (the defaults). The source is one file or a
## list of them; a rule's spacing_m, clear_m and species serve points and lines. A file whose shape is
## wrong is refused with `problem` saying why.

## The import (its schema and its rule matching).
const ForestImportRes := preload("res://addons/wuifwoud/forest_import.gd")
## The file's key order: the known keys first, the rest after.
const ORDER := ["schema", "_comment", "source", "data_directory", "texel_vertices", "exclusions", "rules"]

## The document, every key kept.
var doc := {}
## Why load_file refused a parseable file.
var problem := ""


## A new mapping: the schema, the terrain's folder, one texel a vertex; no source, no exclusions, no rules yet.
func start(data_directory: String) -> void:
	doc = {"schema": ForestImportRes.SCHEMA, "source": "", "data_directory": data_directory, "texel_vertices": 1,
		"exclusions": [], "rules": []}


## Reads a mapping file: OK, or why not (the document is then empty). A parseable file whose shape is wrong is refused
## (ERR_INVALID_DATA, `problem` says why): half-read, the dialog would build what it could and write a default over the
## rest.
func load_file(path: String) -> Error:
	doc = {}
	problem = ""
	if not FileAccess.file_exists(path):
		return ERR_FILE_NOT_FOUND
	var d = JSON.parse_string(FileAccess.get_file_as_string(path))
	if typeof(d) != TYPE_DICTIONARY:
		return ERR_PARSE_ERROR
	problem = problem_of(d)
	if problem != "":
		return ERR_INVALID_DATA
	doc = d
	_normalise()
	return OK


## Why a parsed mapping's shape is wrong ("" when it is right): a key the dialog builds from holds the wrong kind.
static func problem_of(d: Dictionary) -> String:
	if d.has("rules") and typeof(d["rules"]) != TYPE_ARRAY:
		return "'rules' is not a list"
	if d.has("exclusions") and typeof(d["exclusions"]) != TYPE_ARRAY:
		return "'exclusions' is not a list"
	var s = d.get("source", "")
	if typeof(s) == TYPE_ARRAY:
		if not (s as Array).all(func(x): return typeof(x) == TYPE_STRING):
			return "'source' lists something that is not a path"
	elif typeof(s) != TYPE_STRING:
		return "'source' is not a path or a list of paths"
	var rules: Array = d.get("rules", [])
	for i in rules.size():
		var rl = rules[i]
		if typeof(rl) != TYPE_DICTIONARY:
			return "rule %d is not an object" % i
		if (rl as Dictionary).has("match") and typeof(rl["match"]) != TYPE_DICTIONARY:
			return "rule %d's match is not an object" % i
	return ""


## Write the mapping in its stable form.
func save_file(path: String) -> Error:
	DirAccess.make_dir_recursive_absolute(path.get_base_dir())
	var f := FileAccess.open(path, FileAccess.WRITE)
	if f == null:
		return FileAccess.get_open_error()
	f.store_string(text())
	f.close()
	return OK


## The file's text: the known keys in ORDER, then the others as they came; "rules" one a line.
func text() -> String:
	var keys := []
	for k in ORDER:
		if doc.has(k):
			keys.append(k)
	for k in doc:
		if not keys.has(k):
			keys.append(k)
	var lines := PackedStringArray()
	for k in keys:
		if k == "rules":
			var rl := PackedStringArray()
			for rule in doc["rules"]:
				rl.append("  " + JSON.stringify(rule, "", false))
			lines.append(" \"rules\": [" + (("\n" + ",\n".join(rl) + "\n ]") if not rl.is_empty() else "]"))
		else:
			lines.append(" %s: %s" % [JSON.stringify(k), JSON.stringify(doc[k], "", false)])
	return "{\n" + ",\n".join(lines) + "\n}\n"


## A copy of the document, for undo.
func snapshot() -> Dictionary:
	return doc.duplicate(true)


## Put a snapshot back.
func restore(s: Dictionary) -> void:
	doc = s.duplicate(true)


## The rules, in priority order.
func rules() -> Array:
	return doc["rules"]


## The source files.
func sources() -> Array:
	return ForestImportRes.sources_of(doc)


## `list` as the source: one file written as a path, more as a list, none as "".
func set_sources(list: Array) -> void:
	var clean := list.map(func(x): return str(x)).filter(func(x): return x != "")
	doc["source"] = "" if clean.is_empty() else (clean[0] if clean.size() == 1 else clean)


## Add a source file.
func add_source(p: String) -> void:
	var s := sources()
	if not s.has(p):
		s.append(p)
	set_sources(s)


## Remove the source at `i`.
func remove_source(i: int) -> void:
	var s := sources()
	if i >= 0 and i < s.size():
		s.remove_at(i)
	set_sources(s)


## A new rule painting `type` that matches nothing yet, last (the lowest priority): its index.
func add_rule(type: int) -> int:
	rules().append({"match": {}, "type": type})
	return rules().size() - 1


## Delete the rule at `i`.
func delete_rule(i: int) -> void:
	if i >= 0 and i < rules().size():
		rules().remove_at(i)


## The rule at `from` moves to index `to` (clamped).
func move_rule(from: int, to: int) -> void:
	if from < 0 or from >= rules().size():
		return
	var rl = rules().pop_at(from)
	rules().insert(clampi(to, 0, rules().size()), rl)


## Rule i's "type" (a whole number), "density" (0-1; 1 is left out) or "age" (-1..1; 0 is left out); for points and
## lines "spacing_m" (1 or more, 0.5 steps; 8 is left out), "clear_m" (0.1 steps; below 0 is left out: the kind's
## default), "species" ("" is left out: by type).
func set_field(i: int, field: String, value) -> void:
	var rl: Dictionary = rules()[i]
	match field:
		"type":
			rl["type"] = int(value)
		"density":
			var dn := snappedf(clampf(float(value), 0.0, 1.0), 0.01)
			if is_equal_approx(dn, 1.0):
				rl.erase("density")
			else:
				rl["density"] = dn
		"age":
			var ag := snappedf(clampf(float(value), -1.0, 1.0), 0.01)
			if is_equal_approx(ag, 0.0):
				rl.erase("age")
			else:
				rl["age"] = ag
		"spacing_m":
			var sp := snappedf(maxf(float(value), 1.0), 0.5)
			if is_equal_approx(sp, 8.0):
				rl.erase("spacing_m")
			else:
				rl["spacing_m"] = sp
		"clear_m":
			if float(value) < 0.0:
				rl.erase("clear_m")
			else:
				rl["clear_m"] = snappedf(float(value), 0.1)
		"species":
			if str(value) == "":
				rl.erase("species")
			else:
				rl["species"] = str(value)


## Rule i's values on `key`, as text ([] when it has no such key).
func values_of(i: int, key: String) -> Array:
	var want = (rules()[i]["match"] as Dictionary).get(key)
	if want == null:
		return []
	if typeof(want) == TYPE_ARRAY:
		return (want as Array).map(func(w): return str(w))
	return [str(want)]


## `value` joins rule i's match on `key` and leaves every other rule whose match is `key` alone.
func add_value(i: int, key: String, value: String) -> void:
	for j in rules().size():
		if j != i and _only_key(j, key):
			remove_value(j, key, value)
	var have := values_of(i, key)
	if not have.has(value):
		have.append(value)
	_set_values(i, key, have)


## Take `value` of `key` out of the rule at `i`'s match.
func remove_value(i: int, key: String, value: String) -> void:
	if not (rules()[i]["match"] as Dictionary).has(key):
		return
	var have := values_of(i, key)
	have.erase(value)
	_set_values(i, key, have)


## `value` leaves every rule's match on `key` (a value dropped back on the Values column).
func take_out(key: String, value: String) -> void:
	for j in rules().size():
		remove_value(j, key, value)


## A new rule painting `type`, last, matching key = value (which leaves the rules matching on `key` alone).
func new_rule_from(key: String, value: String, type: int) -> int:
	var i := add_rule(type)
	add_value(i, key, value)
	return i


## The rule a feature whose only property is key = value falls under (ForestImport.match_rule), or -1. A rule with no
## match (the import refuses it) never matches.
func rule_of_value(key: String, value: String) -> int:
	var safe := []
	for rl in rules():
		var good: bool = typeof(rl) == TYPE_DICTIONARY and typeof(rl.get("match")) == TYPE_DICTIONARY \
			and not (rl["match"] as Dictionary).is_empty()
		safe.append(rl if good else {"match": {"\u0001never": "\u0001"}})
	return ForestImportRes.match_rule(safe, {key: value})


## What is wrong with the mapping, one line each (empty: nothing).
func validate() -> PackedStringArray:
	return ForestImportRes.validate(doc)


func _only_key(j: int, key: String) -> bool:
	var mt: Dictionary = rules()[j]["match"]
	return mt.size() == 1 and mt.has(key)


func _set_values(i: int, key: String, have: Array) -> void:
	var mt: Dictionary = rules()[i]["match"]
	if have.is_empty():
		mt.erase(key)
	else:
		mt[key] = have[0] if have.size() == 1 else have


## Whole numbers whole, the lists present, every rule with a match.
func _normalise() -> void:
	if typeof(doc.get("texel_vertices")) == TYPE_FLOAT and float(int(doc["texel_vertices"])) == float(doc["texel_vertices"]):
		doc["texel_vertices"] = int(doc["texel_vertices"])
	if typeof(doc.get("rules")) != TYPE_ARRAY:
		doc["rules"] = []
	if typeof(doc.get("exclusions")) != TYPE_ARRAY:
		doc["exclusions"] = []
	for rl in doc["rules"]:
		if typeof(rl) != TYPE_DICTIONARY:
			continue
		if typeof(rl.get("type")) == TYPE_FLOAT and float(int(rl["type"])) == float(rl["type"]):
			rl["type"] = int(rl["type"])
		if typeof(rl.get("match")) != TYPE_DICTIONARY:
			rl["match"] = {}
