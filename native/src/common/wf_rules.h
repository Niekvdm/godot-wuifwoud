// Copyright (c) 2026 Digitzone
// SPDX-License-Identifier: MIT
#ifndef WF_RULES_H
#define WF_RULES_H

#include "common/wf_hash.h"

#include <cmath>
#include <cstdint>

// The forest's rules by number: the roles a scatter point carries into the place, and the
// constants both kernels read. The addon's test fixture (tests/fixtures/wf_points.gd) mirrors the roles and UNDER_TAG.
namespace wf {

enum Role : uint8_t { R_TREE = 0, R_DEAD = 1, R_WALL = 2, R_UNDER = 3, R_BB = 4, R_SCRUB = 5, R_EDGE = 6 };

constexpr double BLOCK_M = 64.0; // the maps' block summary (ForestMaps.BLOCK_M)
constexpr double WOOD_CELL = 16.0; // the wood-membership grid the clutter ring reads
constexpr double CLEARING_SCALE = 0.011; // the clearing noise's frequency (about 90 m)
constexpr double CLEARING_FLOOR = 0.28; // under it: a clearing, no canopy
constexpr double CLEARING_EDGE = 0.12; // the glade's soft edge above the floor: young growth and bushes
constexpr double GROVE_SCALE = 0.033; // the grove (clump) noise's frequency (about 30 m)
constexpr double SLOPE_THIN = 0.8; // rise/run where a slope starts thinning the forest
constexpr double SLOPE_MAX = 1.2; // and past which nothing grows: a cliff
// An understory bush's seed is its tree's XOR this, so a test can find the tree a bush came with.
constexpr uint64_t UNDER_TAG = 0x0F0F0F0F0F0F0F0Full;

enum NoiseLayer : int64_t { N_CLEARING = 0, N_GROVE = 1 };

// Smooth value noise in 0..1 over world XZ: a lattice of hashed values blended by smoothstep. Hashes and + - * floor only
// (no transcendental, no engine noise), so a threshold on it decides the same on every peer.
inline double value_noise(double p_x, double p_z, double p_scale, int64_t p_seed, int64_t p_layer) {
	const double cx = p_x * p_scale;
	const double cz = p_z * p_scale;
	const double fx0 = std::floor(cx);
	const double fz0 = std::floor(cz);
	const int64_t gx = (int64_t)fx0;
	const int64_t gz = (int64_t)fz0;
	double fx = cx - fx0;
	double fz = cz - fz0;
	fx = fx * fx * (3.0 - 2.0 * fx);
	fz = fz * fz * (3.0 - 2.0 * fz);
	const double k = 1.0 / 16777216.0;
	const double n00 = (double)bits24(seed4(D_NOISE, gx, gz, p_seed, p_layer), 0) * k;
	const double n10 = (double)bits24(seed4(D_NOISE, gx + 1, gz, p_seed, p_layer), 0) * k;
	const double n01 = (double)bits24(seed4(D_NOISE, gx, gz + 1, p_seed, p_layer), 0) * k;
	const double n11 = (double)bits24(seed4(D_NOISE, gx + 1, gz + 1, p_seed, p_layer), 0) * k;
	const double a = n00 + (n10 - n00) * fx;
	const double b = n01 + (n11 - n01) * fx;
	return a + (b - a) * fz;
}

inline double clamp01(double p_v) {
	return p_v < 0.0 ? 0.0 : (p_v > 1.0 ? 1.0 : p_v);
}

inline double lerp(double p_a, double p_b, double p_t) {
	return p_a + (p_b - p_a) * p_t;
}

} // namespace wf

#endif // WF_RULES_H
