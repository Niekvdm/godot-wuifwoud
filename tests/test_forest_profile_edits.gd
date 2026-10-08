# Copyright (c) 2026 Digitzone
# SPDX-License-Identifier: MIT
extends RefCounted
## ForestProfile's edits: + New type (the next free id, every lane inherited; none when every id is taken), Duplicate
## (after the original, its own lanes copied), move, Delete; a type's settings within the forest's ranges, an icon and
## colours set and taken out; a style switch keeps what applies; a lane: add (what it inherited copied first, the lane's
## mean weight, 1 in an empty one, a dead row without a weight), the same species twice refused, a weight clamped,
## remove, a move between a weighted lane and a dead row, a move onto its own lane or a lane that has it, Copy from a
## type and from the default, Reset; the Defaults row edits the map's own pools; the bands; snapshot and restore; and the
## forest still loads the result.
##
## Run with a unit-suite runner: static run() returns {name, passed, failed, details}.

const ProfileRes := preload("res://addons/wuifwoud/forest_profile.gd")
const PF := preload("res://addons/wuifwoud/tests/fixtures/profile_fixture.gd")


static func _chk(r: Dictionary, n: String, ok: bool) -> void:
	if ok:
		r.passed += 1
	else:
		r.failed += 1
		r.details.append("✗ " + n)


static func run() -> Dictionary:
	var r := {"name": "forest_profile_edits", "passed": 0, "failed": 0, "details": []}
	var p = ProfileRes.new()
	p.open_text(PF.text_of(PF.LEGACY), PF.FALLBACK)
	# ── the type list ──
	var nid: int = p.add_type()
	_chk(r, "+ New type: the next free id, its name, natural, the new density, every lane inherited",
		nid == 5 and p.type_of(5)["name"] == "New type" and p.type_of(5)["style"] == "natural"
		and is_equal_approx(float(p.type_of(5)["density_per_m2"]), ProfileRes.NEW_DENSITY)
		and ProfileRes.lanes_for("natural").all(func(l): return p.lane_of(5, l)["from"] != "own"))
	var many := []
	for i in range(1, 256):
		many.append({"id": i, "name": "T%d" % i, "style": "bushes", "density_per_m2": 0.01})
	var full = ProfileRes.new()
	full.open_text(JSON.stringify({"types": many}))
	_chk(r, "every id taken: no new type, nothing added", full.add_type() == 0 and full.types().size() == 255)
	var dup: int = p.duplicate_type(1)
	(p.type_of(dup)["mixes"]["coast"] as Array).append(["W_New", 1.0])
	_chk(r, "Duplicate: a new id right after the original, \"Wood copy\", its own lanes copied (%s)" % str(p.type_ids()),
		dup == 6 and Array(p.type_ids()) == [1, 6, 2, 3, 7, 4, 5] and p.type_of(6)["name"] == "Wood copy"
		and p.lane_of(6, "coast")["from"] == "own" and (p.lane_of(1, "coast")["entries"] as Array).size() == 2)
	p.move_type(5, 0)
	_chk(r, "a type moved to the top, its id kept", Array(p.type_ids()) == [5, 1, 6, 2, 3, 7, 4])
	_chk(r, "Delete; a type that is not there is refused", p.delete_type(6) == ""
		and Array(p.type_ids()) == [5, 1, 2, 3, 7, 4] and p.delete_type(99) != "")
	# ── a type's settings ──
	_chk(r, "an empty name is refused", p.set_value(1, "name", "  ") != "" and p.type_of(1)["name"] == "Wood")
	_chk(r, "a density of 0 refused; clump clamped to 0-1, understory to 0-2",
		p.set_value(1, "density_per_m2", 0.0) != "" and p.set_value(1, "clump", 1.7) == ""
		and is_equal_approx(float(p.type_of(1)["clump"]), 1.0) and p.set_value(1, "understory", 5.0) == ""
		and is_equal_approx(float(p.type_of(1)["understory"]), 2.0))
	_chk(r, "a colour is #rrggbb; an icon set and taken out; a far colour taken out",
		p.set_value(1, "colour", "#zz0000") != "" and p.set_value(1, "colour", "#3f7d4c") == ""
		and p.type_of(1)["colour"] == "#3f7d4c" and p.set_value(1, "icon", "conifer") == ""
		and p.type_of(1)["icon"] == "conifer" and p.set_value(1, "icon", "") == "" and not p.type_of(1).has("icon")
		and p.set_value(1, "far_color", "#102030") == "" and p.set_value(1, "far_color", "") == ""
		and not p.type_of(1).has("far_color"))
	_chk(r, "a key that is not a type setting is refused", p.set_value(1, "bush_pool", "x") != ""
		and not p.type_of(1).has("bush_pool"))
	_chk(r, "Grid keeps the density; back to natural without one takes it from the pitch; an unknown style refused",
		p.set_style(1, "grid") == "" and is_equal_approx(float(p.type_of(1)["density_per_m2"]), 0.04)
		and p.set_style(7, "natural") == "" and is_equal_approx(float(p.type_of(7)["density_per_m2"]), 1.0 / 36.0)
		and p.set_style(1, "jungle") != "" and p.type_of(1)["style"] == "grid")
	p.set_style(1, "natural")
	p.set_style(7, "grid")
	# ── lanes ──
	_chk(r, "add to an inheriting lane: what it inherited copied first, the new one at the lane's mean weight",
		p.add_to_lane(1, "mid", "W_Bush") == "" and p.lane_of(1, "mid")["from"] == "own"
		and p.lane_of(1, "mid")["entries"] == [["W_Tree", 3.0], ["W_New", 1.0], ["W_Bush", 2.0]])
	_chk(r, "the same species twice is refused", p.add_to_lane(1, "mid", "W_Bush") != "")
	_chk(r, "an empty lane's first species weighs 1; a dead row's has no weight",
		p.set_lane(5, "bush", []) == "" and p.add_to_lane(5, "bush", "W_New") == ""
		and p.lane_of(5, "bush")["entries"] == [["W_New", 1.0]] and p.add_to_lane(1, "dead.high", "W_Snag") == ""
		and p.lane_of(1, "dead.high")["entries"] == ["W_Snag"])
	_chk(r, "a weight set and clamped to 0.1-10; a species not in the lane refused",
		p.set_weight(1, "mid", "W_Bush", 25.0) == "" and p.lane_of(1, "mid")["entries"][2] == ["W_Bush", 10.0]
		and p.set_weight(1, "mid", "W_Gone", 1.0) != "")
	_chk(r, "remove", p.remove_from_lane(1, "mid", "W_Bush") == ""
		and (p.lane_of(1, "mid")["entries"] as Array).size() == 2 and p.remove_from_lane(1, "mid", "W_Bush") != "")
	_chk(r, "a move: from a weighted lane to a dead row bare, from a dead row to a weighted lane at its mean",
		p.move_between(1, "mid", "dead.high", "W_New") == ""
		and p.lane_of(1, "dead.high")["entries"] == ["W_Snag", "W_New"] and p.lane_of(1, "mid")["entries"] == [["W_Tree", 3.0]]
		and p.move_between(1, "dead.high", "coast", "W_Snag") == ""
		and p.lane_of(1, "coast")["entries"] == [["W_Other", 1.0], ["W_Tree", 2.0], ["W_Snag", 1.5]])
	var before: Dictionary = p.snapshot()
	_chk(r, "a move onto its own lane changes nothing; onto a lane that has it is refused",
		p.move_between(1, "coast", "coast", "W_Tree") == "" and p.doc == before
		and p.move_between(1, "coast", "mid", "W_Tree") != "" and p.doc == before)
	_chk(r, "Copy from another type's lane; from the default (the lane owns a copy)",
		p.copy_lane(5, "coast", 1, "coast") == "" and p.lane_of(5, "coast")["entries"] == p.lane_of(1, "coast")["entries"]
		and p.copy_lane(5, "mid", 0, "mid") == "" and p.lane_of(5, "mid")["entries"] == PF.LEGACY["species"]["mid"]
		and p.lane_of(5, "mid")["from"] == "own")
	_chk(r, "Copy from a weighted lane into a dead row takes the names", p.copy_lane(5, "dead.mid", 1, "mid") == ""
		and p.lane_of(5, "dead.mid")["entries"] == ["W_Tree"])
	_chk(r, "Reset to default drops the own mix (and `mixes` once it is empty)",
		p.reset_lane(5, "coast") == "" and p.reset_lane(5, "mid") == "" and p.reset_lane(5, "dead.mid") == ""
		and p.reset_lane(5, "bush") == "" and not p.type_of(5).has("mixes") and p.lane_of(5, "coast")["from"] == "map")
	# ── the Defaults row ──
	_chk(r, "the Defaults row: adding to a lane the fallback supplies writes the map's own pool (a copy first)",
		p.add_to_lane(0, "high", "W_New") == "" and p.doc["species"]["high"] == [["W_Tree", 1.0], ["W_New", 1.0]]
		and p.lane_of(0, "high")["from"] == "map")
	_chk(r, "Reset on it drops the map's pool: the fallback's grows again", p.reset_lane(0, "high") == ""
		and not (p.doc["species"] as Dictionary).has("high") and p.lane_of(0, "high")["from"] == "fallback")
	# ── the bands ──
	_chk(r, "the bands: the profile's; one set; the order kept; the share 0-1; an unknown key refused",
		p.bands()["mid_top_m"] == 300.0 and p.set_band("mid_top_m", 350.0) == ""
		and p.doc["bands"]["mid_top_m"] == 350.0 and p.set_band("coast_top_m", 400.0) != ""
		and p.doc["bands"]["coast_top_m"] == 50.0 and p.set_band("treeline_keep", 1.5) != ""
		and p.set_band("nope", 1.0) != "")
	var nb = ProfileRes.new()
	nb.open_text("{}")
	_chk(r, "no bands: the forest's own; a band set starts the block", nb.bands() == ProfileRes.BAND_DEFAULTS
		and nb.set_band("treeline_m", 900.0) == "" and nb.doc["bands"] == {"treeline_m": 900.0})
	# ── snapshots, and the forest still loads it ──
	var s: Dictionary = p.snapshot()
	p.delete_type(1)
	p.restore(s)
	_chk(r, "snapshot and restore", p.type_of(1)["name"] == "Wood" and p.doc == s and not is_same(p.doc, s))
	var errs: PackedStringArray = p.load_errors()
	_chk(r, "after every edit the forest loads it, refusing only the type it refused before (%s)" % str(errs),
		errs.size() == 1 and errs[0].contains("No id"))
	_chk(r, "the helpers: the names in a lane, its mean weight",
		ProfileRes.names_in([["W_A", 2.0], "W_B"]) == PackedStringArray(["W_A", "W_B"])
		and is_equal_approx(ProfileRes.mean_weight([["W_A", 2.0], ["W_B", 4.0]]), 3.0)
		and is_equal_approx(ProfileRes.mean_weight([]), 1.0))
	return r
