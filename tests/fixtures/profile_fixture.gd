# Copyright (c) 2026 Digitzone
# SPDX-License-Identifier: MIT
extends RefCounted
## Tests: flora profiles. LEGACY is one in today's form (comments, the default pools and one other, a dead pool; Wood
## owns its coast mix, Ridge names the other pool for its high lane, and one type the forest refuses); EVERY_KEY uses
## every old pool key; FALLBACK is a fallback flora's pools. write() saves one as Godot writes JSON.

## The fallback flora's pools: a high pool the profiles lack, a conifer pool, a dead coast pool.
const FALLBACK := {"species": {"high": [["W_Tree", 1.0]], "conifer": [["W_Pine", 2.0]]}, "dead": {"coast": ["W_Snag"]}}
## A profile in today's form.
const LEGACY := {
	"_comment": "A test flora: a \"quoted\" word, a back\\slash and ünïcode.",
	"bands": {"coast_top_m": 50.0, "mid_top_m": 300.0, "treeline_m": 800.0, "treeline_keep": 0.3},
	"species": {"coast": [["W_Tree", 2.0], ["W_Gone", 1.0]], "mid": [["W_Tree", 3.0], ["W_New", 1.0]],
		"bush": [["W_Bush", 1.0]], "orchard": [["W_New", 1.0]], "spare": [["W_New", 2.0], ["W_Tree", 1.0]]},
	"dead": {"mid": ["W_Missing"]},
	"_comment_types": "kept where it is",
	"types": [
		{"id": 1, "name": "Wood", "style": "natural", "density_per_m2": 0.04, "clump": 0.5,
			"mixes": {"coast": [["W_Other", 1.0], ["W_Tree", 2.0]]}},
		{"id": 2, "name": "Scrub", "style": "bushes", "density_per_m2": 0.0028571428571},
		{"id": 3, "name": "Garden", "style": "mix", "density_per_m2": 0.007},
		{"id": 7, "name": "Orchard", "style": "grid", "pitch_m": 6.0},
		{"id": 4, "name": "Ridge \"north\"", "style": "natural", "density_per_m2": 0.02, "pools": {"high": "spare"}},
		{"name": "No id", "style": "natural"},
	],
}
## Every old key: each naming a pool not named for its lane (one of them only the fallback's), one naming its own
## default, one naming a pool nobody has.
const EVERY_KEY := {
	"species": {"coast": [["W_A", 1.0]], "mid": [["W_B", 1.0]], "high": [["W_C", 1.0]], "bush": [["W_D", 1.0]],
		"orchard": [["W_E", 1.0]], "p1": [["W_F", 2.0], ["W_G_Y", 1.0]], "p2": [["W_H", 1.0]], "p3": [["W_I_Y", 3.0]]},
	"dead": {"mid": ["W_S1"], "d1": ["W_S2", "W_S3"]},
	"types": [
		{"id": 1, "name": "N", "style": "natural", "density_per_m2": 0.02,
			"pools": {"coast": "p1", "mid": "mid", "high": "conifer"}, "dead": {"high": "d1"}, "bush_pool": "p2"},
		{"id": 2, "name": "G", "style": "grid", "pool": "p3"},
		{"id": 3, "name": "M", "style": "mix", "density_per_m2": 0.01, "tree_pool": "p1", "bush_pool": "p2"},
		{"id": 4, "name": "X", "style": "bushes", "density_per_m2": 0.01, "bush_pool": "nowhere"},
	],
}


## Profile `d` as Godot writes JSON (two-space indents; ids as 1.0).
static func text_of(d: Dictionary) -> String:
	return JSON.stringify(d, "  ", false)


## Profile `d` saved at `path` (its folder made).
static func write(path: String, d: Dictionary) -> void:
	DirAccess.make_dir_recursive_absolute(ProjectSettings.globalize_path(path.get_base_dir()))
	var f := FileAccess.open(path, FileAccess.WRITE)
	f.store_string(text_of(d))
	f.close()
