# Copyright (c) 2026 Digitzone
# SPDX-License-Identifier: MIT
extends RefCounted
## ForestProfile, reading and writing: a legacy profile reads, its ids whole numbers; a lane resolves to the type's own
## mix, the map's default pool or the fallback flora's, and says which; the conversion makes every old reference to a
## pool not named for its lane the type's own mix and the forest stays the same (LEGACY, a fixture with every old key,
## the starter flora's conifer pools), written and read back too; the file keeps its key order, its `_comment` keys,
## quotes, backslashes and non-ASCII, a type the forest refuses, and its numbers; a file that does not parse or has the
## wrong shape is refused with why; a read-only profile and one changed on disk are never written.
##
## Run with a unit-suite runner: static run() returns {name, passed, failed, details}.

const ProfileRes := preload("res://addons/wuifwoud/forest_profile.gd")
const PF := preload("res://addons/wuifwoud/tests/fixtures/profile_fixture.gd")
const TreeFix := preload("res://addons/wuifwoud/tests/fixtures/tree_fixture.gd")
const Veg := preload("res://addons/wuifwoud/forest_spawner.gd")
const ROOT := "user://wf_e2_profile"
const STARTER_FLORA := "res://addons/wuifwoud/packs/starter/starter_flora.json"


static func _chk(r: Dictionary, n: String, ok: bool) -> void:
	if ok:
		r.passed += 1
	else:
		r.failed += 1
		r.details.append("✗ " + n)


## The forest a profile's text grows before and after the conversion: the same types, the same lists in the same order,
## the same errors.
static func _same_text(text: String, fb: Dictionary) -> bool:
	var young := func(n: String) -> bool: return n.ends_with("_Y")
	var mature := func(n: String) -> bool: return not n.ends_with("_Y")
	var a = ProfileRes.new()
	var b = ProfileRes.new()
	if a.open_text(text, fb, false) != OK or b.open_text(text, fb, true) != OK:
		return false
	var ra: ForestTypes = a.resolve(young, mature)
	var rb: ForestTypes = b.resolve(young, mature)
	return not ra.by_id.is_empty() and ra.by_id == rb.by_id and ra.errors == rb.errors


## Every old key converted but the one naming its default and the one naming a pool nobody has; the pools they named
## gone, the default ones kept.
static func _converted_keys() -> bool:
	var p = ProfileRes.new()
	p.open_text(PF.text_of(PF.EVERY_KEY), PF.FALLBACK)
	var n: Dictionary = p.type_of(1)
	return (n.get("pools") == {"mid": "mid"} and not n.has("dead") and not n.has("bush_pool")
		and not p.type_of(2).has("pool") and not p.type_of(3).has("tree_pool") and not p.type_of(3).has("bush_pool")
		and p.type_of(4)["bush_pool"] == "nowhere"
		and (p.doc["species"] as Dictionary).keys() == ["coast", "mid", "high", "bush", "orchard"]
		and (p.doc["dead"] as Dictionary).keys() == ["mid"])


## Written and read back: the same forest, nothing left to convert.
static func _round_trip_same(p, path: String) -> bool:
	var before: ForestTypes = p.resolve()
	if p.write() != OK:
		return false
	var q = ProfileRes.new()
	if q.open(path, p.fallback) != OK:
		return false
	return q.resolve().by_id == before.by_id and q.converted.is_empty()


## A document as it reads back from JSON (ids as floats), for comparing with a parsed file.
static func _as_read(d: Dictionary) -> Variant:
	return JSON.parse_string(JSON.stringify(d, "", false, true))


static func run() -> Dictionary:
	var r := {"name": "forest_profile", "passed": 0, "failed": 0, "details": []}
	TreeFix.rm_tree(ROOT)
	var path := ROOT + "/flora.json"
	PF.write(path, PF.LEGACY)
	var p = ProfileRes.new()
	var e: Error = p.open(path, PF.FALLBACK)
	_chk(r, "a legacy profile reads; its ids are whole numbers; a type the forest refuses is kept (%s)" % error_string(e),
		e == OK and Array(p.type_ids()) == [1, 2, 3, 7, 4] and typeof(p.type_of(7)["id"]) == TYPE_INT
		and p.types().size() == 6)
	# ── lanes ──
	var own: Dictionary = p.lane_of(1, "coast")
	var mid: Dictionary = p.lane_of(1, "mid")
	var high: Dictionary = p.lane_of(1, "high")
	_chk(r, "a lane: the type's own mix, the map's default, the fallback flora's, each said (%s, %s, %s)" % [own["from"],
		mid["from"], high["from"]],
		own["from"] == "own" and own["entries"] == [["W_Other", 1.0], ["W_Tree", 2.0]] and own["pool"] == ""
		and mid["from"] == "map" and mid["pool"] == "mid" and mid["entries"] == PF.LEGACY["species"]["mid"]
		and high["from"] == "fallback" and high["entries"] == [["W_Tree", 1.0]])
	_chk(r, "the dead rows and the other styles' lanes default by name",
		p.lane_of(1, "dead.mid")["entries"] == ["W_Missing"] and p.lane_of(1, "dead.coast")["from"] == "fallback"
		and p.lane_of(1, "dead.high")["from"] == "none" and p.lane_of(7, "grid")["pool"] == "orchard"
		and p.lane_of(3, "trees")["pool"] == "mid" and p.lane_of(2, "bush")["entries"] == [["W_Bush", 1.0]])
	_chk(r, "the Defaults row: the profile's own pools, the fallback's where it has none",
		p.lane_of(0, "coast")["from"] == "map" and p.lane_of(0, "high")["from"] == "fallback"
		and p.lane_of(0, "grid")["pool"] == "orchard")
	var copy: Dictionary = p.lane_of(1, "mid")
	(copy["entries"] as Array).append(["W_X", 1.0])
	_chk(r, "a lane's entries are a copy", (p.lane_of(1, "mid")["entries"] as Array).size() == 2)
	_chk(r, "the lanes by style, the dead rows after their bands",
		ProfileRes.lanes_for("natural") == ["coast", "mid", "high", "bush"] and ProfileRes.lanes_for("mix") == ["trees", "bush"]
		and ProfileRes.lanes_for("grid") == ["grid"] and ProfileRes.with_dead(["mid", "bush"]) == ["mid", "dead.mid", "bush"])
	# ── the conversion ──
	var ridge: Dictionary = p.type_of(4)
	_chk(r, "Ridge's old reference is its own high mix now, the reference and the pool gone, said (%s)" % str(p.converted),
		p.lane_of(4, "high")["from"] == "own" and p.lane_of(4, "high")["entries"] == PF.LEGACY["species"]["spare"]
		and not ridge.has("pools") and not (p.doc["species"] as Dictionary).has("spare") and p.converted.size() == 2
		and p.converted[0].contains("Ridge") and p.converted[1].contains("spare"))
	_chk(r, "the conversion grows the same forest: LEGACY", _same_text(PF.text_of(PF.LEGACY), PF.FALLBACK))
	_chk(r, "every old key: the same forest", _same_text(PF.text_of(PF.EVERY_KEY), PF.FALLBACK))
	_chk(r, "every old key converted but a default's and a missing pool's; the pools they named gone", _converted_keys())
	var sf = ProfileRes.new()
	sf.open(STARTER_FLORA, {})
	_chk(r, "the starter flora: Conifer forest owns its coast, mid and high mixes, pool conifer gone (%s)" % str(sf.converted),
		sf.lane_of(2, "mid")["from"] == "own" and sf.lane_of(2, "coast")["entries"] == sf.lane_of(2, "high")["entries"]
		and not (sf.doc["species"] as Dictionary).has("conifer") and not sf.type_of(2).has("pools"))
	_chk(r, "and grows the same forest", _same_text(FileAccess.get_file_as_string(STARTER_FLORA), {}))
	# ── the file ──
	_chk(r, "written and read back: the same forest, nothing left to convert", _round_trip_same(p, path))
	var txt: String = p.text()
	var back = JSON.parse_string(txt)
	_chk(r, "the text reads back to the same document", back is Dictionary and back == _as_read(p.doc))
	_chk(r, "its key order kept, the _comment keys where they were",
		(back as Dictionary).keys() == ["_comment", "bands", "species", "dead", "_comment_types", "types"]
		and back["_comment"] == PF.LEGACY["_comment"] and back["_comment_types"] == "kept where it is")
	_chk(r, "ids whole, other whole numbers with a decimal, a pool entry on one line, two-space indents, full precision",
		txt.contains("\"id\": 1,") and txt.contains("[\"W_Tree\", 2.0]") and txt.contains("\n  \"bands\": {")
		and txt.contains("\"pitch_m\": 6.0") and txt.contains("0.0028571428571"))
	_chk(r, "quotes, a backslash and non-ASCII survive; a type the forest refuses is written as it was",
		back["types"][4]["name"] == "Ridge \"north\"" and String(back["_comment"]).contains("back\\slash")
		and String(back["_comment"]).contains("ünïcode") and back["types"][5] == {"name": "No id", "style": "natural"})
	# ── refused ──
	var broken := ROOT + "/broken.json"
	var bf := FileAccess.open(broken, FileAccess.WRITE)
	bf.store_string("{\n  \"types\": [\n    {\"id\": 1 \"name\": \"x\"}\n  ]\n}\n")
	bf.close()
	var pb = ProfileRes.new()
	var eb: Error = pb.open(broken, {})
	_chk(r, "a file that does not parse is refused, the parser's line said (%s)" % pb.problem,
		eb == ERR_PARSE_ERROR and pb.problem.contains("line") and pb.doc.is_empty())
	var pw = ProfileRes.new()
	_chk(r, "a wrong shape is refused with why", pw.open_text("{\"types\": {}}") == ERR_INVALID_DATA
		and pw.problem.contains("types"))
	_chk(r, "the starter flora is read-only and never written", ProfileRes.is_read_only(STARTER_FLORA)
		and sf.write() == ERR_FILE_NO_PERMISSION and not ProfileRes.is_read_only(path))
	var on_disk := FileAccess.get_file_as_string(path)
	var hand := FileAccess.open(path, FileAccess.WRITE)
	hand.store_string(on_disk.replace("Scrub", "Heath"))
	hand.close()
	p.type_of(2)["name"] = "Scrubland"
	var ew: Error = p.write()
	_chk(r, "a file changed on disk since it was read is not written over (%s)" % p.problem,
		ew == ERR_FILE_CANT_WRITE and p.problem.contains("changed on disk")
		and FileAccess.get_file_as_string(path).contains("Heath"))
	_chk(r, "the bands' defaults are the forest's", ProfileRes.BAND_DEFAULTS == {"coast_top_m": Veg._COAST_M,
		"mid_top_m": Veg._MID_M, "treeline_m": Veg._TREELINE_M, "treeline_keep": Veg._TREELINE_KEEP})
	TreeFix.rm_tree(ROOT)
	return r
