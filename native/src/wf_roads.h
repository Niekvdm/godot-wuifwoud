// Copyright (c) 2026 Digitzone
// SPDX-License-Identifier: MIT
#ifndef WF_ROADS_H
#define WF_ROADS_H

#include <godot_cpp/classes/ref_counted.hpp>
#include <godot_cpp/variant/packed_float64_array.hpp>
#include <godot_cpp/variant/string.hpp>
#include <godot_cpp/variant/vector2.hpp>

#include <cstdint>
#include <unordered_map>
#include <vector>

namespace godot {

// THE ROAD CORRIDOR: the segments the host's road feeder sends, (ax, az, bx, bz, half
// width) in world XZ, each registered in every 64 m cell its box grown by its half width and `margin` touches. Made once
// on the main thread (WfCore.make_roads) and never changed after: a scatter job holds the corridor it was given.
class WfRoads : public RefCounted {
	GDCLASS(WfRoads, RefCounted)

	std::vector<double> seg_;
	double margin_ = 0.0;
	std::unordered_map<uint64_t, std::vector<int32_t>> grid_;
	String error_;

protected:
	static void _bind_methods();

public:
	static constexpr double CELL = 64.0;
	static constexpr int64_t STRIDE = 5;

	static uint64_t key(int64_t p_cx, int64_t p_cz) {
		return ((uint64_t)(uint32_t)(int32_t)p_cx << 32) | (uint64_t)(uint32_t)(int32_t)p_cz;
	}

	// False, with error(), when the array is not a multiple of STRIDE: the corridor is then empty.
	bool build(const PackedFloat64Array &p_segs, double p_margin);
	const std::vector<int32_t> *cell(int64_t p_cx, int64_t p_cz) const;
	// From (x, z) to segment i's centre line.
	double seg_dist(int32_t p_i, double p_x, double p_z) const;
	double half_width(int32_t p_i) const { return seg_[(size_t)p_i * STRIDE + 4]; }
	double margin() const { return margin_; }

	// Bound: tests and tools.
	String error() const { return error_; }
	int64_t size() const { return (int64_t)(seg_.size() / STRIDE); }
	double get_margin() const { return margin_; }
	// Within half width + p_margin of a road registered in p's cell.
	bool is_blocked(const Vector2 &p_p, double p_margin) const;
	// To the nearest corridor edge (half width + the build's margin) among the roads of the 3 x 3 cells around p; INF none.
	double edge_distance(const Vector2 &p_p) const;
};

} // namespace godot

#endif // WF_ROADS_H
