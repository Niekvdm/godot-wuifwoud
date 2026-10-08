# Copyright (c) 2026 Digitzone
# SPDX-License-Identifier: MIT
extends RefCounted
## ForestFarPalette: a species' crown colour from a premultiplied albedo (its true mean, sRGB
## decoded; none from a transparent one); a type's palette per band from its pools by style (the species with a bake,
## the heaviest eight, their weights renormalised and cumulative) and its canopy height (every species' height, baked
## or not, times the mean tree scale sliding with age); a band with no colour takes the mid band's; `far_color`
## overrides (a bad one named and ignored by ForestTypes); a type with no colour at all is FALLBACK, named once; the
## shader's palette texture.
##
## Run with a unit-suite runner: static run() returns {name, passed, failed, details}.

const PaletteRes := preload("res://addons/wuifwoud/forest_far_palette.gd")
const TypesRes := preload("res://addons/wuifwoud/forest_types.gd")
const COLOURS := {"A": Color(0.10, 0.30, 0.10), "B": Color(0.20, 0.20, 0.10), "D": Color(0.30, 0.30, 0.20),
	"E": Color(0.40, 0.20, 0.10)}
const HEIGHTS := {"A": 20.0, "B": 10.0, "C": 30.0, "D": 2.0, "E": 6.0, "Z": 5.0}


static func _chk(r: Dictionary, n: String, ok: bool) -> void:
	if ok:
		r.passed += 1
	else:
		r.failed += 1
		r.details.append("✗ " + n)


static func _near(a: Color, b: Color, tol: float) -> bool:
	return absf(a.r - b.r) <= tol and absf(a.g - b.g) <= tol and absf(a.b - b.b) <= tol


## A w × w premultiplied image: every other texel the colour `c` (sRGB) at alpha 0.5, the rest transparent.
static func _sheet(w: int, c: Color) -> Image:
	var img := Image.create_empty(w, w, false, Image.FORMAT_RGBA8)
	for y in w:
		for x in w:
			if (x + y) % 2 == 0:
				img.set_pixel(x, y, Color(c.r * 0.5, c.g * 0.5, c.b * 0.5, 0.5))
	return img


static func run() -> Dictionary:
	var r := {"name": "forest_far_palette", "passed": 0, "failed": 0, "details": []}
	var want := Color(0.2, 0.4, 0.1).srgb_to_linear()
	var small = PaletteRes.mean_colour(_sheet(4, Color(0.2, 0.4, 0.1)))
	var large = PaletteRes.mean_colour(_sheet(256, Color(0.2, 0.4, 0.1)))
	_chk(r, "a species' crown colour is the mean of its premultiplied albedo, decoded from sRGB, small or through the mips (%s %s)" % [str(small), str(large)],
		small != null and large != null and _near(small, want, 0.01) and _near(large, want, 0.01)
		and PaletteRes.mean_colour(Image.create_empty(8, 8, false, Image.FORMAT_RGBA8)) == null)
	var species := {"coast": [["A", 3.0], ["B", 1.0], ["C", 1.0]], "mid": [["A", 1.0]], "high": [["B", 1.0]],
		"bush": [["D", 1.0]], "orchard": [["E", 1.0]], "nobake": [["Z", 1.0]], "many": []}
	for i in 10:
		species["many"].append(["S%d" % i, float(i + 1)])
	var list := [
		{"id": 1, "name": "Wood", "style": "natural", "density_per_m2": 0.04},
		{"id": 2, "name": "Scrub", "style": "bushes", "density_per_m2": 0.02},
		{"id": 3, "name": "Orchard", "style": "grid", "pitch_m": 7.0},
		{"id": 4, "name": "Garden", "style": "mix", "density_per_m2": 0.01, "tree_share": 0.6},
		{"id": 5, "name": "Painted", "style": "natural", "density_per_m2": 0.04, "far_color": "#336633"},
		{"id": 6, "name": "Bare", "style": "grid", "pool": "nobake"},
		{"id": 7, "name": "Many", "style": "grid", "pool": "many"},
		{"id": 8, "name": "Odd", "style": "grid", "far_color": "green?"}]
	var ft = TypesRes.new()
	ft.load_list(list, species, {}, func(_s): return false, func(_s): return false)
	_chk(r, "ForestTypes reads a far_color; a bad one is named and ignored, the type loads (%s)" % str(ft.errors),
		ft.get_type(5).get("far_color") == Color.html("#336633") and not ft.get_type(8).has("far_color")
		and ft.get_type(8).size() > 0 and str(ft.errors).contains("far_color"))
	var colour_of := func(sp: String):
		if COLOURS.has(sp):
			return COLOURS[sp]
		if sp.begins_with("S"):
			return Color(0.1, 0.1 + float(sp.substr(1).to_int()) * 0.01, 0.1)
		return null
	var height_of := func(sp: String) -> float: return float(HEIGHTS.get(sp, 12.0))
	var p = PaletteRes.new()
	p.build(ft, colour_of, height_of)
	var w1: Dictionary = p.types[1]["bands"][0]
	_chk(r, "a natural type's coast band: the baked species by weight, cumulative (C has no bake), the mean their blend (%s)" % str(w1["weights"]),
		w1["colours"] == PackedColorArray([COLOURS["A"], COLOURS["B"]]) and w1["weights"] == PackedFloat32Array([0.75, 1.0])
		and _near(w1["mean"], COLOURS["A"] * 0.75 + COLOURS["B"] * 0.25, 0.001))
	_chk(r, "its canopy height counts every species, baked or not, times the mean scale, sliding with age (%.2f %.2f %.2f)" % [
		p.height(1, 0, 0.0), p.height(1, 0, -1.0), p.height(1, 0, 1.0)],
		is_equal_approx(p.height(1, 0, 0.0), 20.0 * 1.125) and is_equal_approx(p.height(1, 0, -1.0), 20.0 * 0.8)
		and is_equal_approx(p.height(1, 0, 1.0), 20.0 * 1.3) and is_equal_approx(p.height(1, 2, 0.0), 10.0 * 1.125))
	var w4: Dictionary = p.types[4]["bands"][1]
	_chk(r, "bushes take the bush pool, a grid its pool, a mix its trees and bushes by tree_share (%s)" % str(w4["weights"]),
		p.types[2]["bands"][1]["colours"] == PackedColorArray([COLOURS["D"]])
		and p.types[3]["bands"][1]["colours"] == PackedColorArray([COLOURS["E"]])
		and w4["colours"] == PackedColorArray([COLOURS["A"], COLOURS["D"]])
		and absf(w4["weights"][0] - 0.6) < 0.001 and is_equal_approx(PaletteRes.mean_scale("grid", 1.0), 1.125))
	var fc := Color.html("#336633").srgb_to_linear()
	_chk(r, "far_color overrides the palette in every band",
		p.types[5]["bands"].all(func(b): return b["colours"] == PackedColorArray([fc]) and b["weights"] == PackedFloat32Array([1.0])))
	var many: Dictionary = p.types[7]["bands"][1]
	_chk(r, "the heaviest eight species are kept, the last weight 1 (%d)" % (many["colours"] as PackedColorArray).size(),
		(many["colours"] as PackedColorArray).size() == 8 and many["weights"][7] == 1.0
		and _near(many["colours"][0], colour_of.call("S9"), 0.0001))
	var fb := PaletteRes.FALLBACK.srgb_to_linear()
	_chk(r, "a type with no baked species and no far_color is FALLBACK, named once (%s)" % str(p.warnings),
		p.types[6]["bands"][1]["colours"] == PackedColorArray([fb]) and p.warnings.size() == 1
		and str(p.warnings).contains("type 6"))
	var img: Image = p.texture_image()
	var c0 := img.get_pixel(0, 1 * 3 + 0)
	var cm := img.get_pixel(8, 1 * 3 + 0)
	_chk(r, "the palette texture: row type × 3 + band, a colour and its cumulative weight, then the mean and the tree spacing (%s %s)" % [str(c0), str(cm)],
		img.get_width() == 9 and img.get_height() == 768 and img.get_format() == Image.FORMAT_RGBAF
		and _near(c0, COLOURS["A"], 0.0001) and is_equal_approx(c0.a, 0.75) and is_equal_approx(cm.a, 1.0 / sqrt(0.04)))
	var tab: Dictionary = p.heights_table()
	_chk(r, "the heights table and the styles for the mesh builder",
		tab[1] == PackedFloat32Array([20.0, 20.0, 10.0]) and p.styles()[4] == "mix")
	return r
