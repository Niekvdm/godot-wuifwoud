# Copyright (c) 2026 Digitzone
# SPDX-License-Identifier: MIT
extends RefCounted
## ForestTypes: a profile's `types`: the four styles with their defaults, stable ids whatever
## the list order, pools resolved by name (the defaults follow today's pool names), the age subsets, and every error
## named while the good types still load.
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
	return r


static func _reversed(a: Array) -> Array:
	var out := a.duplicate(true)
	out.reverse()
	return out
