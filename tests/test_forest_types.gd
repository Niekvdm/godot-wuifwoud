# Copyright (c) 2026 Digitzone
# SPDX-License-Identifier: MIT
extends RefCounted
## ForestTypes: a profile's `types`: the four styles with their defaults, stable ids whatever
## the list order, pools resolved by name (the defaults follow today's pool names), the age subsets, and every error
## named while the good types still load; a type's own mixes (they win over pools; the dead rows too; switched-off
## species leave them), its icon and colour, and the profile's order.
##
## Run with a unit-suite runner: static run() returns {name, passed, failed, details}.

const TypesRes := preload("res://addons/wuifwoud/forest_types.gd")
const SPECIES := {
	"coast": [["Palm", 1.0]], "mid": [["Old", 2.0], ["Young", 1.0]], "high": [["Old", 1.0]],
	"bush": [["Fern", 1.0]], "orchard": [["Plum", 1.0]], "empty": [],
}
const DEAD := {"coast": ["Snag_A"], "mid": ["Snag_B"]}
const FOUR := [
	{"id": 1, "name": "Forest", "style": "natural", "density_per_m2": 0.038, "clump": 0.6, "understory": 0.4,
		"edge_wall_m": 34.0, "edge_wall_mult": 3.0},
	{"id": 2, "name": "Open bushland", "style": "bushes", "density_per_m2": 0.0028571428571},
	{"id": 3, "name": "Garden", "style": "mix", "density_per_m2": 0.0066666666667},
	{"id": 4, "name": "Orchard", "style": "grid", "pitch_m": 7.0},
]


static func _chk(r: Dictionary, n: String, ok: bool) -> void:
	if ok:
		r.passed += 1
	else:
		r.failed += 1
		r.details.append("✗ " + n)


static func _parse(list) -> RefCounted:
	var t = TypesRes.new()
	t.load_list(list, SPECIES, DEAD, func(n: String) -> bool: return n == "Young",
		func(n: String) -> bool: return n == "Old")
	return t


static func run() -> Dictionary:
	var r := {"name": "forest_types", "passed": 0, "failed": 0, "details": []}
	var t = _parse(FOUR)
	_chk(r, "four types load, no errors (%s)" % str(t.errors), Array(t.ids()) == [1, 2, 3, 4] and t.errors.is_empty())
	var f: Dictionary = t.get_type(1)
	_chk(r, "natural: its numbers, today's pools by band, dead by band",
		f["style"] == "natural" and is_equal_approx(f["density"], 0.038)
		and is_equal_approx(f["pitch"], 1.0 / sqrt(0.038)) and is_equal_approx(f["clump"], 0.6)
		and is_equal_approx(f["understory"], 0.4) and is_equal_approx(f["edge_wall_m"], 34.0)
		and is_equal_approx(f["edge_wall_mult"], 3.0) and is_equal_approx(f["dead_frac"], 0.03)
		and f["bands"]["mid"] == SPECIES["mid"] and f["bush"] == SPECIES["bush"]
		and f["dead"]["coast"] == ["Snag_A"] and (f["dead"]["high"] as Array).is_empty())
	_chk(r, "the age subsets per band", f["young"]["mid"] == [["Young", 1.0]] and f["mature"]["mid"] == [["Old", 2.0]]
		and (f["young"]["coast"] as Array).is_empty())
	var g: Dictionary = t.get_type(4)
	_chk(r, "grid: pitch 7 m, density 1/49, the orchard pool",
		is_equal_approx(g["pitch"], 7.0) and is_equal_approx(g["density"], 1.0 / 49.0) and g["pool"] == SPECIES["orchard"])
	var m: Dictionary = t.get_type(3)
	_chk(r, "mix: the mid pool, share 0.6, its age subsets; bushes: the bush pool",
		m["tree"] == SPECIES["mid"] and is_equal_approx(m["tree_share"], 0.6) and m["tree_young"] == [["Young", 1.0]]
		and t.get_type(2)["bush"] == SPECIES["bush"] and is_equal_approx(t.get_type(2)["understory"], 0.35))
	var rev = _parse(_reversed(FOUR))
	_chk(r, "ids are stable whatever the order", rev.by_id == t.by_id)
	var named = _parse([{"id": 9, "name": "Ridge", "style": "natural", "density_per_m2": 0.02,
		"pools": {"coast": "high"}, "bush_pool": "orchard"}])
	_chk(r, "pools by name override the defaults", named.get_type(9)["bands"]["coast"] == SPECIES["high"]
		and named.get_type(9)["bush"] == SPECIES["orchard"])
	var bad = _parse([
		FOUR[0],
		{"id": 1, "name": "Twin", "style": "bushes", "density_per_m2": 0.01},
		{"id": 0, "name": "Zero", "style": "bushes", "density_per_m2": 0.01},
		{"id": 256, "name": "Big", "style": "bushes", "density_per_m2": 0.01},
		{"id": 5.5, "name": "Half", "style": "bushes", "density_per_m2": 0.01},
		{"id": 6, "name": "Odd", "style": "jungle", "density_per_m2": 0.01},
		{"id": 7, "style": "bushes", "density_per_m2": 0.01},
		{"id": 8, "name": "Thin", "style": "bushes"},
		{"id": 10, "name": "Ghost", "style": "grid", "pool": "no_such_pool"},
		{"id": 11, "name": "Bare", "style": "bushes", "density_per_m2": 0.01, "bush_pool": "empty"},
		"not a type",
	])
	_chk(r, "each bad type named and dropped, the good ones kept (%d errors: %s)" % [bad.errors.size(), str(bad.errors)],
		Array(bad.ids()) == [1, 11] and bad.errors.size() == 9)
	var none = _parse("nope")
	_chk(r, "types that are not a list: one error, no types", none.by_id.is_empty() and none.errors.size() == 1)
	# ── a type's own mixes ──
	var own = _parse([{"id": 5, "name": "Own", "style": "natural", "density_per_m2": 0.02,
			"pools": {"mid": "high"}, "bush_pool": "orchard",
			"mixes": {"coast": [["Young", 4.0]], "mid": [["Old", 1.0], ["Young", 2.0]], "bush": [["Fern", 2.0]],
				"dead": {"high": ["Snag_C"]}}},
		{"id": 6, "name": "Own grid", "style": "grid", "mixes": {"grid": [["Old", 1.0]]}},
		{"id": 8, "name": "Own mix", "style": "mix", "density_per_m2": 0.01, "mixes": {"trees": [["Young", 1.0]]}}])
	var o: Dictionary = own.get_type(5)
	_chk(r, "an own mix wins over the pool its old key names; a lane without one keeps its pool (%s)" % str(own.errors),
		own.errors.is_empty() and o["bands"]["coast"] == [["Young", 4.0]]
		and o["bands"]["mid"] == [["Old", 1.0], ["Young", 2.0]] and o["bands"]["high"] == SPECIES["high"]
		and o["bush"] == [["Fern", 2.0]])
	_chk(r, "the age subsets come from the own mix; a dead row: its own, else the pool",
		o["young"]["mid"] == [["Young", 2.0]] and o["mature"]["mid"] == [["Old", 1.0]] and o["dead"]["high"] == ["Snag_C"]
		and o["dead"]["coast"] == ["Snag_A"])
	_chk(r, "a grid's own grid lane, a mix's own trees lane", own.get_type(6)["pool"] == [["Old", 1.0]]
		and own.get_type(8)["tree"] == [["Young", 1.0]] and own.get_type(8)["tree_young"] == [["Young", 1.0]])
	var off = TypesRes.new()
	off.load_list([{"id": 5, "name": "Own", "style": "natural", "density_per_m2": 0.02,
		"mixes": {"mid": [["Old", 1.0], ["Young", 2.0]], "dead": {"mid": ["Snag_B", "Snag_C"]}}}], SPECIES, DEAD,
		func(_n: String) -> bool: return false, func(_n: String) -> bool: return false,
		PackedStringArray(["Young", "Snag_B"]))
	_chk(r, "a switched-off species leaves an own mix too, the rest keep their weights (%s)" % str(off.get_type(5).get("bands")),
		off.get_type(5)["bands"]["mid"] == [["Old", 1.0]] and off.get_type(5)["dead"]["mid"] == ["Snag_C"])
	var badm = _parse([{"id": 5, "name": "A", "style": "bushes", "density_per_m2": 0.01, "mixes": "nope"},
		{"id": 6, "name": "B", "style": "bushes", "density_per_m2": 0.01, "mixes": {"bush": "nope"}},
		{"id": 7, "name": "C", "style": "natural", "density_per_m2": 0.01, "mixes": {"dead": []}}])
	_chk(r, "mixes not an object, an own lane not a list, dead rows not an object: each named and dropped (%s)" % str(badm.errors),
		badm.by_id.is_empty() and badm.errors.size() == 3)
	# ── icon, colour, the profile's order ──
	var dressed = _parse([
		{"id": 9, "name": "Ridge", "style": "bushes", "density_per_m2": 0.01, "icon": "conifer", "colour": "#3f7d4c"},
		{"id": 2, "name": "Scrub", "style": "bushes", "density_per_m2": 0.01, "colour": "green"}])
	_chk(r, "icon and colour read; a colour that is not #rrggbb named and ignored (%s)" % str(dressed.errors),
		dressed.get_type(9)["icon"] == "conifer" and dressed.get_type(9)["colour"] == Color.html("#3f7d4c")
		and not dressed.get_type(2).has("colour") and dressed.errors.size() == 1 and dressed.by_id.size() == 2)
	_chk(r, "order(): the profile's order; ids() sorted", Array(dressed.order()) == [9, 2] and Array(dressed.ids()) == [2, 9])
	return r


static func _reversed(a: Array) -> Array:
	var out := a.duplicate(true)
	out.reverse()
	return out
