# Copyright (c) 2026 Digitzone
# SPDX-License-Identifier: MIT
extends RefCounted
## The Types dialog in the editor: Forest → Types… (after Species…) asks the plugin for it; the workspace's ⋯ has Types…
## first and no Reload types; the library lists the forest's types in the profile's order, each in its own colour, and its
## footer opens the Types dialog; the brush wears the selected type's colour; color_of stays today's colour for an id.
##
## Run with a unit-suite runner: static run() returns {name, passed, failed, details}.

const MenuRes := preload("res://addons/wuifwoud/editor/forest_preview_menu.gd")
const ProviderRes := preload("res://addons/wuifwoud/editor/forest_paint_provider.gd")
const TypeTileRes := preload("res://addons/wuifwoud/editor/common/forest_type_tile.gd")
const Veg := preload("res://addons/wuifwoud/forest_spawner.gd")
const VA := preload("res://addons/wuifwoud/forest_assets.gd")
const ForestConfigRes := preload("res://addons/wuifwoud/forest_config.gd")
const PROFILE_PATH := "user://wf_e2_wiring_profile.json"
const PROFILE := {"species": {"bush": [["W_B", 1.0]]}, "types": [
	{"id": 4, "name": "Heath", "style": "bushes", "density_per_m2": 0.01, "colour": "#aa3300"},
	{"id": 2, "name": "Scrub", "style": "bushes", "density_per_m2": 0.01}]}


static func _chk(r: Dictionary, n: String, ok: bool) -> void:
	if ok:
		r.passed += 1
	else:
		r.failed += 1
		r.details.append("✗ " + n)


## Two colours alike within 8-bit rounding.
static func _near(a: Color, b: Color) -> bool:
	return absf(a.r - b.r) < 0.01 and absf(a.g - b.g) < 0.01 and absf(a.b - b.b) < 0.01


static func run() -> Dictionary:
	var r := {"name": "forest_types_wiring", "passed": 0, "failed": 0, "details": []}
	var m = MenuRes.new()
	var asked := [0]
	m.types_requested.connect(func() -> void: asked[0] += 1)
	m._on_id(MenuRes.ID_TYPES)
	var pop: PopupMenu = m.get_popup()
	var texts := []
	for i in pop.item_count:
		texts.append(pop.get_item_text(i))
	_chk(r, "Forest → Types… asks for the dialog, right after Species… (%s)" % str(texts),
		asked[0] == 1 and texts.find("Types…") == texts.find("Species…") + 1)
	m.free()
	var p = ProviderRes.new()
	var opened := [0]
	p.types_requested.connect(func() -> void: opened[0] += 1)
	var acts: Array = p.workspace_actions().map(func(a): return a["id"])
	p.workspace_action("types")
	_chk(r, "the workspace's ⋯: Types… first, Reload types gone (%s)" % str(acts),
		acts == ["types", "species", "import", "restore", "regrow"] and opened[0] == 1)
	ForestConfigRes.use(ForestConfigRes.new())
	VA.use_packs([])
	var f := FileAccess.open(PROFILE_PATH, FileAccess.WRITE)
	f.store_string(JSON.stringify(PROFILE))
	f.close()
	var vp = Veg.new()
	vp.profile_path = PROFILE_PATH
	vp._load_profile()
	p.forest_of = func(): return vp
	var lib: Dictionary = p.library()
	var items: Array = lib["items"]
	var names: Array = items.map(func(i): return i["name"])
	var c0: Color = (items[0]["picture"] as Texture2D).get_image().get_pixel(0, 0)
	var c1: Color = (items[1]["picture"] as Texture2D).get_image().get_pixel(0, 0)
	_chk(r, "the library: the profile's order, each type's colour, the footer opens the Types dialog (%s)" % str(names),
		names == ["Heath", "Scrub"] and _near(c0, Color("aa3300")) and _near(c1, ProviderRes.color_of(2))
		and lib["footer_action"] == "types")
	p.library_select(4)
	p.activate("forest.paint", null)
	_chk(r, "the brush wears the selected type's colour", _near(p.decal_color(), Color("aa3300")))
	_chk(r, "color_of is today's colour for an id; colour_of a type's own", ProviderRes.color_of(2) == TypeTileRes.colour_for_id(2)
		and ProviderRes.colour_of(vp._types.get_type(4)) == Color.html("#aa3300"))
	vp.free()
	ForestConfigRes.use(null)
	VA.forget_packs()
	VA.reset()
	DirAccess.remove_absolute(ProjectSettings.globalize_path(PROFILE_PATH))
	return r
