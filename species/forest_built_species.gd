# Copyright (c) 2026 Digitzone
# SPDX-License-Identifier: MIT
@tool
extends Resource
## A species prepared by its pack's build: what ForestAssets.prepare_species_of returned, saved as built/<id>.res: the
## combined mesh (LOD0 with its index LODs, its leaf cards stamped), the per-level meshes
## of the GPU path, its leaf surfaces, the crown, the source LOD0's AABB, and what its preparation warned about. No
## material: the forest makes them at load from the pack's textures.

## The species id.
@export var id := ""
## The preparation version it was built at.
@export var prep_version := 0
## LOD0 with its index LODs and stamped leaf cards (the per-chunk path).
@export var combined: ArrayMesh
## One mesh per authored LOD level (the GPU path).
@export var levels: Array[ArrayMesh] = []
## Its leaf surfaces' indices.
@export var foliage := PackedInt32Array()
## Whether its leaf cards are stamped.
@export var stamped := false
## The crown's centre (mesh space).
@export var crown_centre := Vector3.ZERO
## The crown's radius.
@export var crown_radius := 1.0
## How far the leaf normals fall short of spherical (the shader's spherify).
@export var spherify := 0.0
## The crown's rect in the atlas (u0, v0, u1, v1).
@export var crown_uv := Vector4(0.0, 0.0, 1.0, 1.0)
## The source LOD0's AABB.
@export var aabb := AABB()
## What its preparation warned about.
@export var warnings := PackedStringArray()


## This resource from a preparation (prepare_species_of's Dictionary) of species `p_id` at prep `version`.
func fill(p_id: String, p: Dictionary, version: int) -> void:
	id = p_id
	prep_version = version
	combined = p["combined"]
	var lv: Array[ArrayMesh] = []
	for m in p["levels"]:
		lv.append(m)
	levels = lv
	foliage = p["foliage"]
	stamped = p["stamped"]
	crown_centre = p["crown_centre"]
	crown_radius = p["crown_radius"]
	spherify = p["spherify"]
	crown_uv = p["crown_uv"]
	aabb = p["aabb"]
	warnings = PackedStringArray(p.get("warnings", PackedStringArray()))
	# Its resource ids fixed: the same species is the same bytes whoever built it (the saver would give each mesh a
	# random id, and keeps a path's ids only within one process).
	resource_scene_unique_id = "built"
	if combined != null:
		combined.resource_scene_unique_id = "combined"
	for i in levels.size():
		if levels[i] != null:
			levels[i].resource_scene_unique_id = "level_%d" % i


## The preparation it holds, in prepare_species_of's shape (its own meshes: the forest dresses them).
func to_prepared() -> Dictionary:
	return {"combined": combined, "levels": Array(levels), "foliage": foliage, "stamped": stamped,
		"crown_centre": crown_centre, "crown_radius": crown_radius, "spherify": spherify, "crown_uv": crown_uv,
		"aabb": aabb, "warnings": warnings}
