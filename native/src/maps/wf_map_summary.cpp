// Copyright (c) 2026 Digitzone
// SPDX-License-Identifier: MIT
#include "maps/wf_map_summary.h"

#include "common/wf_rules.h"

#include <godot_cpp/variant/string.hpp>
#include <godot_cpp/variant/variant.hpp>

#include <algorithm>
#include <cmath>

using namespace godot;

Dictionary wf::summarise_map(const PackedByteArray &p_data, int64_t p_w, double p_ox, double p_oz, double p_tm,
		const PackedInt32Array &p_ids, const Vector2i &p_b0, const Vector2i &p_b1) {
	Dictionary out;
	Dictionary blocks;
	PackedInt32Array unknown;
	if (p_w <= 0 || p_data.size() != p_w * p_w * 4 || !(p_tm > 0.0)) {
		out["blocks"] = blocks;
		out["unknown"] = unknown;
		out["error"] = String("the map's bytes are not ") + String::num_int64(p_w) + " x " + String::num_int64(p_w) +
				" RGBA8 texels";
		return out;
	}
	const uint8_t *px = p_data.ptr();
	bool want[256] = {};
	for (int64_t i = 0; i < p_ids.size(); i++) {
		const int32_t id = p_ids[i];
		if (id > 0 && id < 256) {
			want[id] = true;
		}
	}
	int64_t named[256] = {};
	for (int64_t i = 0; i < p_w * p_w; i++) {
		named[px[i * 4]]++;
	}
	for (int v = 1; v < 256; v++) {
		if (named[v] > 0 && !want[v]) {
			unknown.push_back(v);
		}
	}
	for (int64_t bz = p_b0.y; bz <= p_b1.y; bz++) {
		const int64_t j0 = std::max<int64_t>(0, (int64_t)std::ceil(((double)bz * BLOCK_M - p_oz) / p_tm - 0.5));
		const int64_t j1 = std::min<int64_t>(p_w - 1, (int64_t)std::ceil(((double)(bz + 1) * BLOCK_M - p_oz) / p_tm - 0.5) - 1);
		for (int64_t bx = p_b0.x; bx <= p_b1.x; bx++) {
			const int64_t i0 = std::max<int64_t>(0, (int64_t)std::ceil(((double)bx * BLOCK_M - p_ox) / p_tm - 0.5));
			const int64_t i1 = std::min<int64_t>(p_w - 1, (int64_t)std::ceil(((double)(bx + 1) * BLOCK_M - p_ox) / p_tm - 0.5) - 1);
			if (j1 < j0 || i1 < i0) {
				continue;
			}
			bool seen[256] = {};
			for (int64_t j = j0; j <= j1; j++) {
				const uint8_t *row = px + (j * p_w) * 4;
				for (int64_t i = i0; i <= i1; i++) {
					seen[row[i * 4]] = true;
				}
			}
			PackedInt32Array present;
			for (int64_t k = 0; k < p_ids.size(); k++) {
				const int32_t id = p_ids[k];
				if (id > 0 && id < 256 && seen[id]) {
					present.push_back(id);
				}
			}
			if (!present.is_empty()) {
				blocks[Vector2i((int32_t)bx, (int32_t)bz)] = present;
			}
		}
	}
	out["blocks"] = blocks;
	out["unknown"] = unknown;
	out["error"] = String();
	return out;
}
