// Copyright (c) 2026 Digitzone
// SPDX-License-Identifier: MIT
#include "wf_roads.h"

#include <godot_cpp/core/class_db.hpp>

#include <algorithm>
#include <cmath>
#include <limits>

using namespace godot;

void WfRoads::_bind_methods() {
	ClassDB::bind_method(D_METHOD("error"), &WfRoads::error);
	ClassDB::bind_method(D_METHOD("size"), &WfRoads::size);
	ClassDB::bind_method(D_METHOD("get_margin"), &WfRoads::get_margin);
	ClassDB::bind_method(D_METHOD("is_blocked", "p", "margin"), &WfRoads::is_blocked);
	ClassDB::bind_method(D_METHOD("edge_distance", "p"), &WfRoads::edge_distance);
}

bool WfRoads::build(const PackedFloat64Array &p_segs, double p_margin) {
	seg_.clear();
	grid_.clear();
	margin_ = p_margin;
	error_ = String();
	const int64_t n = p_segs.size();
	if (n % STRIDE != 0) {
		error_ = String("the road segments are ") + String::num_int64(n) + " floats, not a multiple of 5";
		return false;
	}
	seg_.resize((size_t)n);
	for (int64_t i = 0; i < n; i++) {
		seg_[(size_t)i] = p_segs[i];
	}
	for (int64_t i = 0; i < n / STRIDE; i++) {
		const double *q = seg_.data() + i * STRIDE;
		const double pad = q[4] + p_margin;
		const int64_t cx0 = (int64_t)std::floor((std::min(q[0], q[2]) - pad) / CELL);
		const int64_t cx1 = (int64_t)std::floor((std::max(q[0], q[2]) + pad) / CELL);
		const int64_t cz0 = (int64_t)std::floor((std::min(q[1], q[3]) - pad) / CELL);
		const int64_t cz1 = (int64_t)std::floor((std::max(q[1], q[3]) + pad) / CELL);
		for (int64_t cz = cz0; cz <= cz1; cz++) {
			for (int64_t cx = cx0; cx <= cx1; cx++) {
				grid_[key(cx, cz)].push_back((int32_t)i);
			}
		}
	}
	return true;
}

const std::vector<int32_t> *WfRoads::cell(int64_t p_cx, int64_t p_cz) const {
	const auto it = grid_.find(key(p_cx, p_cz));
	return it == grid_.end() ? nullptr : &it->second;
}

double WfRoads::seg_dist(int32_t p_i, double p_x, double p_z) const {
	const double *q = seg_.data() + (size_t)p_i * STRIDE;
	const double abx = q[2] - q[0];
	const double abz = q[3] - q[1];
	const double l2 = std::max(abx * abx + abz * abz, 0.0001);
	const double t = std::clamp(((p_x - q[0]) * abx + (p_z - q[1]) * abz) / l2, 0.0, 1.0);
	const double dx = p_x - (q[0] + abx * t);
	const double dz = p_z - (q[1] + abz * t);
	return std::sqrt(dx * dx + dz * dz);
}

bool WfRoads::is_blocked(const Vector2 &p_p, double p_margin) const {
	const double x = p_p.x;
	const double z = p_p.y;
	const std::vector<int32_t> *c = cell((int64_t)std::floor(x / CELL), (int64_t)std::floor(z / CELL));
	if (c == nullptr) {
		return false;
	}
	for (const int32_t s : *c) {
		if (seg_dist(s, x, z) < half_width(s) + p_margin) {
			return true;
		}
	}
	return false;
}

double WfRoads::edge_distance(const Vector2 &p_p) const {
	const double x = p_p.x;
	const double z = p_p.y;
	const int64_t cx = (int64_t)std::floor(x / CELL);
	const int64_t cz = (int64_t)std::floor(z / CELL);
	double best = std::numeric_limits<double>::infinity();
	for (int64_t j = cz - 1; j <= cz + 1; j++) {
		for (int64_t i = cx - 1; i <= cx + 1; i++) {
			const std::vector<int32_t> *c = cell(i, j);
			if (c == nullptr) {
				continue;
			}
			for (const int32_t s : *c) {
				best = std::min(best, seg_dist(s, x, z) - (half_width(s) + margin_));
			}
		}
	}
	return best;
}
