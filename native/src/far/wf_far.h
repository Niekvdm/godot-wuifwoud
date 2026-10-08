// Copyright (c) 2026 Digitzone
// SPDX-License-Identifier: MIT
#ifndef WF_FAR_H
#define WF_FAR_H

#include <godot_cpp/variant/dictionary.hpp>
#include <godot_cpp/variant/packed_byte_array.hpp>
#include <godot_cpp/variant/packed_float32_array.hpp>
#include <godot_cpp/variant/packed_int32_array.hpp>

#include <cstdint>

namespace wf {

// A forest map's far summary: out_w texels square, RGBA8: R the type at the far texel's
// centre (else the first of `ids` in it, row by row), G the cover (the mean over its map texels of their density where
// the type is one of `ids`, else 0: share times density, exactly), B the mean age, A 0. `data`: the map's RGBA8 bytes, w
// square. {"texels": PackedByteArray (empty for a map whose bytes are not w * w * 4), "any": some texel has cover}.
godot::Dictionary far_summarise(const godot::PackedByteArray &p_data, int64_t p_w, int64_t p_out_w,
		const godot::PackedInt32Array &p_ids);

// A region's ground at the shell's grid: s * s heights, row-major from its corner, from its height map's FORMAT_RF
// bytes (w x h), the sample (i, j) at texel (round(i * step), round(j * step)) clamped to the map. Empty for bytes that
// are not w * h floats.
godot::PackedFloat32Array far_sample_ground(const godot::PackedByteArray &p_data, int64_t p_w, int64_t p_h, int64_t p_s,
		double p_step);

// One far cell's shell, from its window of region summaries and grounds (ForestFar._submit_build's
// `p`: "origin", "cell_m", "rm", "grid_m", "texel_m", "out_w", "s", "sums" {Vector2i: PackedByteArray}, "grounds"
// {Vector2i: PackedFloat32Array}, "heights" {type: PackedFloat32Array [coast, mid, high]}, "styles" {type: String},
// "rules" {"sea", "coast", "mid", "treeline", "slope_thin", "slope_max"}, "seed"). {"arrays": the mesh's surface arrays
// (empty with no quad), "quads", "texels": the cell's own far texels (RGBA8, the margin cut off), "tw": their width,
// "error": ""}.
godot::Dictionary far_build_cell(const godot::Dictionary &p_p);

} // namespace wf

#endif // WF_FAR_H
