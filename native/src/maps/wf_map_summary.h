// Copyright (c) 2026 Digitzone
// SPDX-License-Identifier: MIT
#ifndef WF_MAP_SUMMARY_H
#define WF_MAP_SUMMARY_H

#include <godot_cpp/variant/dictionary.hpp>
#include <godot_cpp/variant/packed_byte_array.hpp>
#include <godot_cpp/variant/packed_int32_array.hpp>
#include <godot_cpp/variant/vector2i.hpp>

#include <cstdint>

namespace wf {

// A forest map's block summary: which of `ids` each BLOCK_M block from b0 to b1
// (inclusive) holds, a texel counting in the block its centre lies in (half-open, as the scatter's grid splits), in the
// order of `ids`; and every type id the map names that `ids` lacks. `data`: the map's RGBA8 bytes, w texels square;
// its corner at (ox, oz), tm metres a texel. {"blocks": {Vector2i: PackedInt32Array} (a block with none left out),
// "unknown": PackedInt32Array, "error": ""}; a map whose bytes are not w * w * 4: no blocks, and why.
godot::Dictionary summarise_map(const godot::PackedByteArray &p_data, int64_t p_w, double p_ox, double p_oz, double p_tm,
		const godot::PackedInt32Array &p_ids, const godot::Vector2i &p_b0, const godot::Vector2i &p_b1);

} // namespace wf

#endif // WF_MAP_SUMMARY_H
