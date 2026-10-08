# Copyright (c) 2026 Digitzone
# SPDX-License-Identifier: MIT
@tool
extends RefCounted
## Add species: a new ForestSpecies from a mesh file. Its id from the file's base name (letters, digits, "_" and "-"
## kept, the rest "_"), made unique across the listed packs; its crown and kind guessed from the name; its textures read
## from the mesh's materials (albedo and normal; MTAO left empty: an imported ORM map packs other channels), bark and
## leaves by the forest's name rule. Saved by the dialog as <pack folder>/species/<id>.tres.

## The forest's assets (the mesh's surfaces).
const VA := preload("res://addons/wuifwoud/forest_assets.gd")
## Words that name a conifer.
const CONIFER := ["pine", "fir", "spruce", "cedar", "cypress", "larch", "conifer", "cryptomeria", "juniper"]
## Words that name a bush.
const BUSH := ["bush", "shrub", "fern"]


## An id from `base` (a file's base name), unique among `taken` (id -> true): "_2", "_3", … when it is taken.
static func id_for(base: String, taken: Dictionary) -> String:
	var clean := ""
	for ch in base.strip_edges():
		clean += ch if (ch.to_lower() != ch.to_upper() or ch.is_valid_int() or ch == "_" or ch == "-") else "_"
	if clean == "":
		clean = "species"
	var id := clean
	var n := 2
	while taken.has(id):
		id = "%s_%d" % [clean, n]
		n += 1
	return id


## "conifer", "palm" or "broadleaf", by the name.
static func crown_guess(name: String) -> String:
	var n := name.to_lower()
	for w in CONIFER:
		if n.contains(w):
			return "conifer"
	return "palm" if n.contains("palm") else "broadleaf"


## "bush" or "tree", by the name.
static func kind_guess(name: String) -> String:
	var n := name.to_lower()
	for w in BUSH:
		if n.contains(w):
			return "bush"
	return "tree"


## The texture files of mesh `path`'s materials: the first bark surface's and the first leaf surface's albedo and normal.
static func textures_of(path: String) -> Dictionary:
	var out := {"bark_albedo": "", "bark_normal": "", "foliage_albedo": "", "foliage_normal": ""}
	for s in VA.mesh_surfaces(path):
		var side := "foliage" if bool(s["foliage"]) else "bark"
		if String(out[side + "_albedo"]) == "" and String(s["albedo"]) != "":
			out[side + "_albedo"] = String(s["albedo"])
		if String(out[side + "_normal"]) == "" and String(s["normal"]) != "":
			out[side + "_normal"] = String(s["normal"])
	return out


## A new species for mesh `path`, its id unique among `taken`.
static func make(path: String, taken: Dictionary) -> ForestSpecies:
	var base := path.get_file().get_basename()
	var s := ForestSpecies.new()
	s.id = id_for(base, taken)
	s.display_name = String(s.id).replace("_", " ")
	s.crown = crown_guess(base)
	s.kind = kind_guess(base)
	s.mesh = path
	var tex := textures_of(path)
	for k in tex:
		s.set(k, String(tex[k]))
	return s


## Where a new species of `pack` is saved.
static func species_path(pack, id: String) -> String:
	return String(pack.resource_path).get_base_dir().path_join("species").path_join(id + ".tres")
