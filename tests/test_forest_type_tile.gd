# Copyright (c) 2026 Digitzone
# SPDX-License-Identifier: MIT
extends RefCounted
## The type icons: ten glyphs, each white on the type's colour in a rounded tile, made once per icon, colour and size;
## the tile names its icon; a type's icon (its own, else by style: a natural type's conifer when most of its mid lane
## by weight is conifer crowns); a type's colour (its own, else today's for its id); ForestAssets.species_of.
##
## Run with a unit-suite runner: static run() returns {name, passed, failed, details}.

const TypeTileRes := preload("res://addons/wuifwoud/editor/common/forest_type_tile.gd")
const ProviderRes := preload("res://addons/wuifwoud/editor/forest_paint_provider.gd")
const VA := preload("res://addons/wuifwoud/forest_assets.gd")
const Fix := preload("res://addons/wuifwoud/tests/fixtures/species_fixture.gd")
const ROOT := "user://wf_e2_type_tile"


static func _chk(r: Dictionary, n: String, ok: bool) -> void:
	if ok:
		r.passed += 1
	else:
		r.failed += 1
		r.details.append("✗ " + n)


static func run() -> Dictionary:
	var r := {"name": "forest_type_tile", "passed": 0, "failed": 0, "details": []}
	var c := Color("3f7d4c")
	var bad := []
	for ic in TypeTileRes.ICONS:
		var img: Image = TypeTileRes.texture(ic, c, 32).get_image()
		var white := 0
		for y in 32:
			for x in 32:
				var px := img.get_pixel(x, y)
				if px.r > 0.9 and px.g > 0.9 and px.b > 0.9 and px.a > 0.9:
					white += 1
		if img.get_width() != 32 or img.get_pixel(0, 0).a > 0.01 or not img.get_pixel(16, 1).is_equal_approx(c) or white < 16:
			bad.append("%s (white %d)" % [ic, white])
	_chk(r, "ten glyphs, each white on the colour in a rounded tile (%s)" % str(bad),
		TypeTileRes.ICONS.size() == 10 and bad.is_empty())
	_chk(r, "a texture is made once per icon, colour and size",
		TypeTileRes.texture("palm", c, 32) == TypeTileRes.texture("palm", c, 32)
		and TypeTileRes.texture("palm", c, 32) != TypeTileRes.texture("palm", Color.RED, 32))
	var tile: TextureRect = TypeTileRes.tile("orchard", c, 30)
	_chk(r, "a tile names its icon and keeps its size", tile.name == "Icon" and tile.get_meta("icon") == "orchard"
		and tile.custom_minimum_size == Vector2(30, 30) and TypeTileRes.label_of("dead_wood") == "Dead wood")
	tile.free()
	# ── the icon a type wears ──
	var crowns := {"W_Pine": "conifer", "W_Oak": "broadleaf"}
	var crown_of := func(id: String) -> String: return String(crowns.get(id, ""))
	_chk(r, "by style: bushes, grid, mix",
		TypeTileRes.icon_of({"style": "bushes"}, [], crown_of) == "bush"
		and TypeTileRes.icon_of({"style": "grid"}, [], crown_of) == "orchard"
		and TypeTileRes.icon_of({"style": "mix"}, [], crown_of) == "mixed")
	_chk(r, "a natural type: broadleaf; conifer when most of its mid lane by weight is conifer crowns",
		TypeTileRes.icon_of({"style": "natural"}, [["W_Oak", 1.0]], crown_of) == "broadleaf"
		and TypeTileRes.icon_of({"style": "natural"}, [["W_Pine", 3.0], ["W_Oak", 2.0]], crown_of) == "conifer"
		and TypeTileRes.icon_of({"style": "natural"}, [["W_Pine", 1.0], ["W_Oak", 1.0]], crown_of) == "broadleaf")
	_chk(r, "its own icon wins; one that is no glyph does not",
		TypeTileRes.icon_of({"style": "grid", "icon": "palm"}, [], crown_of) == "palm"
		and TypeTileRes.icon_of({"style": "grid", "icon": "rocket"}, [], crown_of) == "orchard")
	# ── its colour ──
	_chk(r, "a type's colour: its own (a resolved Color or the file's #rrggbb), else today's for its id",
		TypeTileRes.colour_of({"id": 3, "colour": Color.RED}) == Color.RED
		and TypeTileRes.colour_of({"id": 3, "colour": "#3f7d4c"}) == c
		and TypeTileRes.colour_of({"id": 3}) == ProviderRes.color_of(3)
		and TypeTileRes.colour_for_id(3) == ProviderRes.color_of(3))
	# ── the forest's species by id, without a warning ──
	var fx := Fix.make(ROOT)
	VA.use_packs([fx["fixture"], fx["other"]], PackedStringArray(["W_Other"]))
	_chk(r, "species_of: a pack's species; null when switched off or in no pack",
		VA.species_of("W_Bush") != null and String(VA.species_of("W_Bush").kind) == "bush"
		and VA.species_of("W_Other") == null and VA.species_of("W_Gone") == null)
	VA.forget_packs()
	VA.reset()
	Fix.TreeFix.rm_tree(ROOT)
	return r
