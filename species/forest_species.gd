# Copyright (c) 2026 Digitzone
# SPDX-License-Identifier: MIT
@tool
class_name ForestSpecies
extends Resource
## One species of a Wuifwoud pack: what the forest needs to grow it, its id (the name the flora
## profiles, the forest types and trees.json use), kind, crown, trunk, age flags and alpha cut, its mesh and its bark and
## foliage textures. Files are PATHS, not resource dependencies: a pack whose meshes are missing (a project that keeps
## licensed meshes out of version control) still loads, and each such species is said once and not drawn.

## A species no pack names a radius for gets this trunk (m).
const DEFAULT_TRUNK_RADIUS := 0.26
## The alpha cut a species names none for.
const DEFAULT_ALPHA_CUT := 0.5

## Unique across the packs a project grows (the first resolved pack wins a clash).
@export var id := ""
## The name a library shows.
@export var display_name := ""
## A bush has no impostor card, a short dissolve, and casts no shadow.
@export_enum("tree", "bush") var kind := "tree"
## The family of the procedural card silhouette.
@export_enum("broadleaf", "conifer", "palm") var crown := "broadleaf"
## The trunk collider's radius; 0: none.
@export_range(0.0, 3.0, 0.01, "suffix:m") var trunk_radius := DEFAULT_TRUNK_RADIUS
## The age subsets: a forest map's old growth takes the mature species of a pool, young growth the young ones.
@export var mature := false
## Young growth takes it (see mature).
@export var young := false
## The foliage's alpha cutoff.
@export_range(0.0, 1.0, 0.01) var alpha_cut := DEFAULT_ALPHA_CUT
## An imported scene: its `<name>_LOD0..3` nodes are the authored LOD chain (else its largest mesh, and a generated
## chain); a node named like a collider is never taken.
@export_file("*.gltf", "*.glb", "*.fbx", "*.FBX", "*.blend", "*.tscn", "*.scn") var mesh := ""
## The material names of its leaf surfaces; empty: the name rule (bark, trunk, wood are bark; leaf, leaves, needle,
## vegetation, cutout are foliage; a surface with no material is foliage past the first).
@export var foliage_materials := PackedStringArray()

## The bark's colour.
@export_group("Bark")
@export_file("*.png", "*.jpg", "*.jpeg", "*.tga", "*.webp", "*.exr", "*.dds", "*.ktx") var bark_albedo := ""
## The bark's normal map.
@export_file("*.png", "*.jpg", "*.jpeg", "*.tga", "*.webp", "*.exr", "*.dds", "*.ktx") var bark_normal := ""
## Metallic, AO and gloss packed: the forest's mtao map.
@export_file("*.png", "*.jpg", "*.jpeg", "*.tga", "*.webp", "*.exr", "*.dds", "*.ktx") var bark_mtao := ""

## The leaves' colour.
@export_group("Foliage")
@export_file("*.png", "*.jpg", "*.jpeg", "*.tga", "*.webp", "*.exr", "*.dds", "*.ktx") var foliage_albedo := ""
## The leaves' normal map.
@export_file("*.png", "*.jpg", "*.jpeg", "*.tga", "*.webp", "*.exr", "*.dds", "*.ktx") var foliage_normal := ""
## Metallic, AO and gloss packed: the forest's mtao map.
@export_file("*.png", "*.jpg", "*.jpeg", "*.tga", "*.webp", "*.exr", "*.dds", "*.ktx") var foliage_mtao := ""


## A path as stored (res://, or the uid:// the inspector writes) as a res:// path; "" for a uid nothing has.
static func resolve(path: String) -> String:
	if not path.begins_with("uid://"):
		return path
	var uid := ResourceUID.text_to_id(path)
	return ResourceUID.get_id_path(uid) if uid != ResourceUID.INVALID_ID and ResourceUID.has_id(uid) else ""


## The files the pack's build hashes: the mesh (and a glTF's buffer files) and every texture, resolved; the empty ones
## left out.
func files() -> PackedStringArray:
	var out := PackedStringArray()
	for p in [mesh, bark_albedo, bark_normal, bark_mtao, foliage_albedo, foliage_normal, foliage_mtao]:
		var f := resolve(String(p))
		if f != "":
			out.append(f)
			if f.get_extension().to_lower() == "gltf":
				out.append_array(gltf_buffers(f))
	return out


## A .gltf's external buffer files, beside it; none for an embedded (data:) buffer or a file that does not read.
static func gltf_buffers(path: String) -> PackedStringArray:
	var out := PackedStringArray()
	var j: Variant = JSON.parse_string(FileAccess.get_file_as_string(path)) if FileAccess.file_exists(path) else null
	if not (j is Dictionary):
		return out
	for b in (j as Dictionary).get("buffers", []):
		var uri := String(b.get("uri", "")) if b is Dictionary else ""
		if uri != "" and not uri.begins_with("data:"):
			out.append(path.get_base_dir().path_join(uri.uri_decode()))
	return out


## What else a build's output depends on, as built.json keeps it: "settings", an MD5 of the fields the preparation and
## the bake read (its leaf materials, its alpha cut), and "imports", each file's import settings: an MD5 of the [params]
## of its .import ("" without one), not of its remap, which moves with the platform and the engine.
func build_inputs() -> Dictionary:
	var imports := {}
	for f in files():
		var params := import_params(f)
		imports[f] = params.md5_text() if params != "" else ""
	return {
		"settings": JSON.stringify({"foliage_materials": Array(foliage_materials), "alpha_cut": alpha_cut}, "", true).md5_text(),
		"imports": imports,
	}


## The [params] section of `path`'s .import ("" without one).
static func import_params(path: String) -> String:
	var imp := path + ".import"
	if not FileAccess.file_exists(imp):
		return ""
	var text := FileAccess.get_file_as_string(imp)
	var at := text.find("\n[params]")
	return text.substr(at).strip_edges() if at >= 0 else ""
