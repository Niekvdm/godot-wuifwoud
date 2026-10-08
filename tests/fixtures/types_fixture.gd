# Copyright (c) 2026 Digitzone
# SPDX-License-Identifier: MIT
extends RefCounted
## Tests: the Types dialog's world in `root`: the species fixture's packs grown by the forest (W_Other switched off),
## the profile fixture's LEGACY profile at <root>/flora.json and a one-type default flora at <root>/default_flora.json;
## and the dialog on them with a stand-in for the plugin.

const SpeciesFix := preload("res://addons/wuifwoud/tests/fixtures/species_fixture.gd")
const PF := preload("res://addons/wuifwoud/tests/fixtures/profile_fixture.gd")
const DialogRes := preload("res://addons/wuifwoud/editor/types/forest_types_dialog.gd")
const KitRes := preload("res://addons/wuifwoud/editor/common/forest_kit.gd")
const VA := preload("res://addons/wuifwoud/forest_assets.gd")
## The default flora Create a profile… copies.
const DEFAULT_FLORA := {"_comment": "the default flora", "species": {"mid": [["W_Tree", 1.0]]},
	"types": [{"id": 1, "name": "Woodland", "style": "natural", "density_per_m2": 0.02}]}


## The plugin's side.
class Plugin extends RefCounted:
	var set_to: Array = []
	var saves: Array = []
	var rules: Array = []

	func set_profile(p: String) -> void:
		set_to.append(p)

	func pick_save(title: String, filters: PackedStringArray, start: String, on_pick: Callable) -> void:
		saves.append([title, filters, start, on_pick])

	func rules_of() -> Array:
		return rules


## The world in `root`: {"root", "profile", "flora", "fixture", "other"}.
static func make(root: String) -> Dictionary:
	var fx := SpeciesFix.make(root)
	VA.use_packs([fx["fixture"], fx["other"]], PackedStringArray(["W_Other"]))
	PF.write(root + "/flora.json", PF.LEGACY)
	PF.write(root + "/default_flora.json", DEFAULT_FLORA)
	return {"root": root, "profile": root + "/flora.json", "flora": root + "/default_flora.json",
		"fixture": fx["fixture"], "other": fx["other"]}


## The dialog on world `fx` (`extra` overrides the context), plain controls: [dialog, plugin].
static func dialog(fx: Dictionary, extra := {}) -> Array:
	var pl := Plugin.new()
	var ctx := {"kit": KitRes.new(null), "has_forest": true, "scene": "fixture", "scene_dir": String(fx["root"]),
		"profile_path": String(fx["profile"]), "fallback": PF.FALLBACK, "default_flora": String(fx["flora"]),
		"set_profile": pl.set_profile, "pick_save": pl.pick_save, "rules_of": pl.rules_of}
	ctx.merge(extra, true)
	var d = DialogRes.new()
	d.setup(ctx)
	return [d, pl]


## The forest's packs forgotten, the world removed.
static func clean(root: String) -> void:
	VA.forget_packs()
	VA.reset()
	SpeciesFix.TreeFix.rm_tree(root)
