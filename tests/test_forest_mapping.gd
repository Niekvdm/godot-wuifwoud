# Copyright (c) 2026 Digitzone
# SPDX-License-Identifier: MIT
extends RefCounted
## ForestMapping: a round trip keeps every key (`_comment` and unknown ones), the rules'
## order and one rule a line; whole numbers stay whole, default density and age are left out; a value moves between
## rules matching its key alone, a rule on more keys keeps it; the last value of a key takes the key with it; rules
## move, go and change; take_out; snapshot and restore; the rule a value falls under (a rule with no match never
## matches); a new mapping names what it lacks; a missing or broken file is an error. The source list (one path,
## a list, none); a rule's item fields and their defaults; a parseable but malformed mapping refused, with
## why.
##
## Run with a unit-suite runner: static run() returns {name, passed, failed, details}.

const MappingRes := preload("res://addons/wuifwoud/forest_mapping.gd")
const PATH := "user://wf_b2b_mapping/isle.json"
const DOC := {"schema": "wuifwoud_import/1", "_comment": "kept as written", "source": "user://src.geojson",
	"data_directory": "user://terrain", "texel_vertices": 1, "exclusions": [], "x_extra": {"a": 1},
	"rules": [{"match": {"kind": ["wood", "forest"]}, "type": 1},
		{"match": {"kind": "park"}, "type": 3, "density": 0.7},
		{"match": {"kind": "garden", "class": "landuse"}, "type": 2}]}


static func _chk(r: Dictionary, n: String, ok: bool) -> void:
	if ok:
		r.passed += 1
	else:
		r.failed += 1
		r.details.append("✗ " + n)


static func _loaded():
	DirAccess.make_dir_recursive_absolute(PATH.get_base_dir())
	var f := FileAccess.open(PATH, FileAccess.WRITE)
	f.store_string(JSON.stringify(DOC, "", false))         # in its own key order, as a person writes it
	f.close()
	var m = MappingRes.new()
	m.load_file(PATH)
	return m


static func run() -> Dictionary:
	var r := {"name": "forest_mapping", "passed": 0, "failed": 0, "details": []}
	var m = _loaded()
	var e: Error = m.save_file(PATH)
	var text := FileAccess.get_file_as_string(PATH)
	var back = MappingRes.new()
	back.load_file(PATH)
	var rule_lines := Array(text.split("\n")).filter(func(l): return String(l).begins_with("  {\"match\""))
	_chk(r, "a round trip keeps every key, the rules' order, one rule a line; schema first, the unknown key last (%s)" % error_string(e),
		e == OK and back.doc == m.doc and back.doc["_comment"] == "kept as written" and back.doc.has("x_extra")
		and rule_lines.size() == 3 and text.find("\"schema\"") < text.find("\"_comment\"")
		and text.find("\"rules\"") < text.find("\"x_extra\""))
	_chk(r, "whole numbers stay whole (type, texel_vertices)",
		typeof(m.doc["texel_vertices"]) == TYPE_INT and typeof(m.rules()[0]["type"]) == TYPE_INT
		and text.contains("\"type\":1") and not text.contains("\"type\":1.0"))

	# ── values ──
	m.add_value(1, "kind", "wood")                                  # into park's rule, out of wood's (kind alone)
	_chk(r, "a value moves into a rule and out of every rule matching its key alone (%s)" % str(m.rules()[0]["match"]),
		m.values_of(1, "kind") == ["park", "wood"] and m.values_of(0, "kind") == ["forest"])
	m.add_value(1, "kind", "garden")
	_chk(r, "a rule matching on more keys keeps its value", m.values_of(2, "kind") == ["garden"]
		and m.values_of(1, "kind") == ["park", "wood", "garden"])
	m.remove_value(0, "kind", "forest")
	_chk(r, "the last value of a key takes the key with it; one value is written bare (%s)" % str(m.rules()[0]["match"]),
		(m.rules()[0]["match"] as Dictionary).is_empty() and typeof(m.rules()[1]["match"]["kind"]) == TYPE_ARRAY)
	var nr: int = m.new_rule_from("kind", "orchard", 4)
	_chk(r, "a new rule from a value: last, its type, the value alone (%d)" % nr,
		nr == 3 and m.rules()[3] == {"match": {"kind": "orchard"}, "type": 4})
	var m3 = _loaded()
	m3.take_out("kind", "garden")
	_chk(r, "take_out: a value leaves every rule's match on its key, a rule on more keys too (%s)" % str(m3.rules()[2]["match"]),
		m3.values_of(2, "kind").is_empty() and m3.rules()[2]["match"] == {"class": "landuse"}
		and m3.values_of(0, "kind") == ["wood", "forest"])

	# ── rules ──
	var snap: Dictionary = m.snapshot()
	m.set_field(1, "density", 1.0)
	m.set_field(1, "age", 0.3)
	m.set_field(1, "type", 5.0)
	var fields: Dictionary = m.rules()[1].duplicate()
	m.set_field(1, "age", 0.0)
	m.move_rule(3, 0)
	var moved: int = int(m.rules()[0]["type"])
	m.delete_rule(1)
	_chk(r, "fields: density 1 and age 0 left out, type whole; a rule moves and goes (%s; %d; %d)" % [str(fields), moved,
		m.rules().size()], not fields.has("density") and is_equal_approx(float(fields["age"]), 0.3)
		and typeof(fields["type"]) == TYPE_INT and int(fields["type"]) == 5 and moved == 4 and m.rules().size() == 3)
	m.restore(snap)
	_chk(r, "restore puts a snapshot back", m.doc == snap and m.rules().size() == 4)

	# ── the rule a value falls under ──
	_chk(r, "rule_of_value: the first rule a feature with only that property matches; an empty match matches nothing (%s)" % str(
		[m.rule_of_value("kind", "wood"), m.rule_of_value("kind", "nothing"), m.rule_of_value("kind", "garden")]),
		m.rule_of_value("kind", "wood") == 1 and m.rule_of_value("kind", "nothing") == -1
		and m.rule_of_value("kind", "garden") == 1 and m.rule_of_value("class", "landuse") == -1)

	# ── the source list; the item fields; a malformed mapping refused ──
	var sm = MappingRes.new()
	sm.start("user://terrain")
	sm.add_source("a.geojson")
	var one_src = sm.doc["source"]
	sm.add_source("b.geojson")
	var two_src = sm.doc["source"]
	sm.remove_source(0)
	var back_src = sm.doc["source"]
	sm.remove_source(0)
	_chk(r, "the source list: one file written as a path, more as a list, none as \"\" (%s)" % str([one_src, two_src, back_src, sm.doc["source"]]),
		one_src == "a.geojson" and two_src == ["a.geojson", "b.geojson"] and back_src == "b.geojson"
		and sm.doc["source"] == "" and sm.sources().is_empty())
	var fm = _loaded()
	fm.set_field(0, "spacing_m", 6.0)
	fm.set_field(0, "clear_m", 2.0)
	fm.set_field(0, "species", "W_Old")
	var set1: Dictionary = (fm.rules()[0] as Dictionary).duplicate()
	fm.set_field(0, "spacing_m", 8.0)
	fm.set_field(0, "clear_m", -1.0)
	fm.set_field(0, "species", "")
	var rule0: Dictionary = fm.rules()[0]
	_chk(r, "a rule's item fields: spacing, clearance, species; their defaults (8 m, the kind's clearance, by type) left out (%s)" % str(set1),
		is_equal_approx(float(set1.get("spacing_m", 0.0)), 6.0) and is_equal_approx(float(set1.get("clear_m", 0.0)), 2.0)
		and set1.get("species", "") == "W_Old" and not rule0.has("spacing_m") and not rule0.has("clear_m")
		and not rule0.has("species"))
	var probs := []
	for bad in [{"rules": {}}, {"rules": ["x"]}, {"source": 5}, {"rules": [{"match": "kind", "type": 1}]},
			{"exclusions": "z.json"}]:
		var bd := DOC.duplicate(true)
		bd.merge(bad, true)
		var bf := FileAccess.open(PATH, FileAccess.WRITE)
		bf.store_string(JSON.stringify(bd))
		bf.close()
		var bm = MappingRes.new()
		var be: Error = bm.load_file(PATH)
		probs.append([be, bm.problem, bm.doc.is_empty()])
	_chk(r, "a parseable but malformed mapping is refused with why, never half-read (%s)" % str(probs),
		probs.all(func(x): return (x[0] == ERR_INVALID_DATA and String(x[1]) != "" and x[2])))

	# ── a new mapping, a missing file, a broken one ──
	var fresh = MappingRes.new()
	fresh.start("user://terrain")
	var errs: PackedStringArray = fresh.validate()
	var broken := FileAccess.open(PATH, FileAccess.WRITE)
	broken.store_string("{ not json")
	broken.close()
	_chk(r, "a new mapping names what it lacks; a missing file and a broken one are errors (%s)" % str(errs),
		str(errs).contains("source") and str(errs).contains("rules") and fresh.doc["data_directory"] == "user://terrain"
		and MappingRes.new().load_file(PATH.get_base_dir().path_join("none.json")) == ERR_FILE_NOT_FOUND
		and MappingRes.new().load_file(PATH) == ERR_PARSE_ERROR)
	DirAccess.remove_absolute(ProjectSettings.globalize_path(PATH))
	DirAccess.remove_absolute(ProjectSettings.globalize_path(PATH.get_base_dir()))
	return r
