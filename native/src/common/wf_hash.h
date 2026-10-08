// Copyright (c) 2026 Digitzone
// SPDX-License-Identifier: MIT
#ifndef WF_HASH_H
#define WF_HASH_H

#include <cmath>
#include <cstdint>

// THE FOREST'S INTEGER HASHES. Every keep, drop and pick is decided from these, so two peers on any
// compiler and CPU decide the same: splitmix64's finaliser over a running state, and a decision takes the top 24 bits of
// its own salted draw, which a float holds exactly.
namespace wf {

inline uint64_t mix64(uint64_t p_z) {
	uint64_t z = p_z + 0x9E3779B97F4A7C15ull;
	z = (z ^ (z >> 30)) * 0xBF58476D1CE4E5B9ull;
	z = (z ^ (z >> 27)) * 0x94D049BB133111EBull;
	return z ^ (z >> 31);
}

// Streams never cross: a map point, a noise lattice, the canopy's lumps and the thinning key each hash under their own.
enum Domain : uint64_t {
	D_CELL = 0x5746000000000001ull,
	D_NOISE = 0x5746000000000002ull,
	D_LUMP = 0x5746000000000003ull,
	D_THIN = 0x5746000000000004ull,
};

// The seed of four integers under a domain.
inline uint64_t seed4(uint64_t p_domain, int64_t p_a, int64_t p_b, int64_t p_c, int64_t p_d) {
	uint64_t h = mix64(p_domain);
	h = mix64(h ^ (uint64_t)p_a);
	h = mix64(h ^ (uint64_t)p_b);
	h = mix64(h ^ (uint64_t)p_c);
	return mix64(h ^ (uint64_t)p_d);
}

// One decision of a seed, 24 bits: each decision has its own salt (Salt, below), never shared.
inline uint32_t bits24(uint64_t p_seed, uint64_t p_salt) {
	return (uint32_t)(mix64(p_seed ^ (p_salt * 0xD6E8FEB86659FD93ull)) >> 40);
}

// The same decision as [0, 1), exact in a float.
inline float u01(uint64_t p_seed, uint64_t p_salt) {
	return (float)bits24(p_seed, p_salt) * (1.0f / 16777216.0f);
}

enum Salt : uint64_t {
	S_JIT_X = 1,
	S_JIT_Z,
	S_DENSITY,
	S_QUALITY,
	S_DEAD,
	S_CLUMP,
	S_UNDER,
	S_UNDER_X,
	S_UNDER_Z,
	S_SLOPE,
	S_TREELINE,
	S_PICK,
	S_PICK_DEAD,
	S_EDGE,
	S_AGED,
	S_MIX,
	S_YAW,
	S_SCALE,
	S_LEAN,
	S_TINT_B,
	S_TINT_W,
};

// floor(v / step) as an integer: west and south of the origin a coordinate floors, never truncates toward zero.
inline int64_t cell_of(double p_v, double p_step) {
	return (int64_t)std::floor(p_v / p_step);
}

} // namespace wf

#endif // WF_HASH_H
