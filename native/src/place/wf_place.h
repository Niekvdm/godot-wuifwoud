// Copyright (c) 2026 Digitzone
// SPDX-License-Identifier: MIT
#ifndef WF_PLACE_H
#define WF_PLACE_H

#include <godot_cpp/variant/basis.hpp>
#include <godot_cpp/variant/dictionary.hpp>

namespace wf {

// One instance into a MultiMesh buffer at `p_dst` (16 floats): the engine's TRANSFORM_3D layout with one four-float
// attribute: the basis's rows, each followed by the origin's coordinate, then the colour.
void put_instance(float *p_dst, const godot::Basis &p_b, float p_ox, float p_oy, float p_oz, float p_r, float p_g,
		float p_bl, float p_a);

// One ring cell's place: its points (a scatter's result) on the ground of the region copies
// handed in, every gate, species, scale, yaw, lean and tint, packed. The job: "tables", "pts", "regions" ([Vector2i,
// PackedFloat32Array, ...]: region copies, region_size squared floats each), "region_size", "vertex_spacing", "spatial"
// (cards in Z-order for the GPU arena, else thinning order), "params" {"seed", "sea", "coast", "mid", "treeline",
// "treeline_keep", "cards", "bucket_m", "bb_cell_m", "trunk_cell_m"}. Out: {"species": {"bx,bz/name": {"buf", "n",
// "clusters", "mesh", "bucket"}}, "bbs": {Vector2i: {name: {"buf", "n", "clusters"}}}, "trunks": {Vector2i:
// PackedFloat32Array (x, ground, z, radius) a trunk}, "crowns": {Vector2i: {name: PackedFloat32Array (x, z, ground, scale)
// a tree}}, "error": ""}. A slot's "clusters" are its buffer's level-1 clusters for the GPU arena, [cx, cy, cz, radius,
// rel, n] every BLOCK_SPLIT instances, the radius without the species' reach (arena/wf_arena.h).
godot::Dictionary place_cell(const godot::Dictionary &p_job);

} // namespace wf

#endif // WF_PLACE_H
