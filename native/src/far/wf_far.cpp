// Copyright (c) 2026 Digitzone
// SPDX-License-Identifier: MIT
#include "far/wf_far.h"

#include "common/wf_hash.h"
#include "common/wf_rules.h"
#include "wf_tables.h"

#include <godot_cpp/classes/mesh.hpp>
#include <godot_cpp/variant/array.hpp>
#include <godot_cpp/variant/packed_vector3_array.hpp>
#include <godot_cpp/variant/string.hpp>
#include <godot_cpp/variant/vector2.hpp>
#include <godot_cpp/variant/vector2i.hpp>
#include <godot_cpp/variant/vector3.hpp>

#include <algorithm>
#include <array>
#include <cmath>
#include <cstring>
#include <limits>
#include <unordered_map>
#include <vector>

using namespace godot;
using namespace wf;

namespace {

constexpr double SKIRT_M = 5.0; // a wall's foot under the sea line (or the ground, where lower)
constexpr double RELIEF = 0.3; // the canopy's lumps: +/- this share of its height
constexpr double LUMP_M = 32.0; // and their lattice
constexpr double MEAN_SCALE = 1.125; // the mean tree scale at age 0: the middle of 0.8-1.45
constexpr uint8_t NO_STYLE = 255;

struct Rules {
	double sea = 0.6;
	double coast = 120.0;
	double mid = 420.0;
	double treeline = 700.0;
	double slope_thin = 0.8;
	double slope_max = 1.2;
};

// The mean tree scale at `age` (ForestFarPalette.mean_scale): 1.125 at 0, sliding toward young or old growth's ranges for
// a natural or mix type.
double mean_scale(uint8_t p_style, double p_age) {
	if (p_age == 0.0 || !(p_style == STYLE_NATURAL || p_style == STYLE_MIX)) {
		return MEAN_SCALE;
	}
	const double k = std::fabs(std::clamp(p_age, -1.0, 1.0));
	const double lo = lerp(0.8, p_age < 0.0 ? 0.6 : 1.1, k);
	const double hi = lerp(1.45, p_age < 0.0 ? 1.0 : 1.5, k);
	return (lo + hi) * 0.5;
}

// The canopy's lump pattern at world (x, z), -1..1: smoothed value noise on a LUMP_M lattice, world-space, so two cells
// agree where they meet.
double lump(double p_x, double p_z, int64_t p_seed) {
	const double gx = p_x / LUMP_M;
	const double gz = p_z / LUMP_M;
	const double fx0 = std::floor(gx);
	const double fz0 = std::floor(gz);
	const int64_t ix = (int64_t)fx0;
	const int64_t iz = (int64_t)fz0;
	double fx = gx - fx0;
	double fz = gz - fz0;
	fx = fx * fx * (3.0 - 2.0 * fx);
	fz = fz * fz * (3.0 - 2.0 * fz);
	auto h = [&](int64_t p_i, int64_t p_k) {
		return (double)(bits24(seed4(D_LUMP, p_i, p_k, p_seed, 0), 0) >> 8) / 65535.0;
	};
	const double a = lerp(h(ix, iz), h(ix + 1, iz), fx);
	const double b = lerp(h(ix, iz + 1), h(ix + 1, iz + 1), fx);
	return lerp(a, b, fz) * 2.0 - 1.0;
}

uint64_t loc_key(int64_t p_x, int64_t p_z) {
	return ((uint64_t)(uint32_t)(int32_t)p_x << 32) | (uint64_t)(uint32_t)(int32_t)p_z;
}

uint8_t style_of(const String &p_s) {
	if (p_s == "natural") {
		return STYLE_NATURAL;
	}
	if (p_s == "bushes") {
		return STYLE_BUSHES;
	}
	if (p_s == "grid") {
		return STYLE_GRID;
	}
	if (p_s == "mix") {
		return STYLE_MIX;
	}
	return NO_STYLE;
}

// One cell's inputs, assembled: its far texels and ground with a one-quad margin, read out of its window's regions.
struct Cell {
	int64_t n = 0; // quads a side
	int64_t k = 0; // far texels a quad side
	int64_t qw = 0; // quads a side with the margin
	int64_t tw = 0; // far texels a side with the margin
	int64_t vw = 0; // vertices a side with the margin
	double g = 16.0;
	double ox = 0.0;
	double oz = 0.0;
	std::vector<uint8_t> texels;
	std::vector<float> ground;
	std::unordered_map<int64_t, std::array<float, 3>> heights;
	std::unordered_map<int64_t, uint8_t> styles;
	Rules rules;
	int64_t seed = 0;
	std::vector<uint8_t> qcov;
	std::vector<uint8_t> qtype;
	std::vector<uint8_t> qage;
};

bool assemble(const Dictionary &p_p, Cell &c, String &r_error) {
	const double g = p_p.get("grid_m", 0.0);
	const double tm = p_p.get("texel_m", 0.0);
	const double rm = p_p.get("rm", 0.0);
	const double cell_m = p_p.get("cell_m", 0.0);
	const int64_t out_w = p_p.get("out_w", 0);
	const int64_t s = p_p.get("s", 0);
	if (!(g > 0.0) || !(tm > 0.0) || !(rm > 0.0) || !(cell_m > 0.0) || out_w <= 0 || s <= 0) {
		r_error = "a far cell with no size, grid, texel or region";
		return false;
	}
	const Vector2 o = p_p.get("origin", Vector2());
	c.g = g;
	c.ox = o.x;
	c.oz = o.y;
	c.n = (int64_t)std::llround(cell_m / g);
	c.k = (int64_t)std::llround(g / tm);
	c.qw = c.n + 2;
	c.tw = c.qw * c.k;
	c.vw = c.n + 3;
	std::unordered_map<uint64_t, PackedByteArray> sums;
	const Dictionary sd = p_p.get("sums", Dictionary());
	const Array sk = sd.keys();
	for (int64_t i = 0; i < sk.size(); i++) {
		const Vector2i loc = sk[i];
		const PackedByteArray b = sd[sk[i]];
		if (b.size() == out_w * out_w * 4) {
			sums[loc_key(loc.x, loc.y)] = b;
		}
	}
	std::unordered_map<uint64_t, PackedFloat32Array> grounds;
	const Dictionary gd = p_p.get("grounds", Dictionary());
	const Array gk = gd.keys();
	for (int64_t i = 0; i < gk.size(); i++) {
		const Vector2i loc = gk[i];
		const PackedFloat32Array a = gd[gk[i]];
		if (a.size() == s * s) {
			grounds[loc_key(loc.x, loc.y)] = a;
		}
	}
	c.texels.assign((size_t)(c.tw * c.tw * 4), 0);
	for (int64_t v = 0; v < c.tw; v++) {
		const double z = c.oz - g + ((double)v + 0.5) * tm;
		const int64_t lz = cell_of(z, rm);
		const int64_t tz = (int64_t)((z - (double)lz * rm) / tm);
		for (int64_t u = 0; u < c.tw; u++) {
			const double x = c.ox - g + ((double)u + 0.5) * tm;
			const int64_t lx = cell_of(x, rm);
			const int64_t tx = (int64_t)((x - (double)lx * rm) / tm);
			const auto it = sums.find(loc_key(lx, lz));
			if (it == sums.end() || tx < 0 || tz < 0 || tx >= out_w || tz >= out_w) {
				continue;
			}
			std::memcpy(&c.texels[(size_t)((v * c.tw + u) * 4)], it->second.ptr() + (tz * out_w + tx) * 4, 4);
		}
	}
	c.ground.assign((size_t)(c.vw * c.vw), std::numeric_limits<float>::quiet_NaN());
	for (int64_t j = 0; j < c.vw; j++) {
		const double z = c.oz + (double)(j - 1) * g;
		const int64_t lz = cell_of(z, rm);
		const int64_t sz = (int64_t)std::llround((z - (double)lz * rm) / g);
		for (int64_t i = 0; i < c.vw; i++) {
			const double x = c.ox + (double)(i - 1) * g;
			const int64_t lx = cell_of(x, rm);
			const int64_t sx = (int64_t)std::llround((x - (double)lx * rm) / g);
			const auto it = grounds.find(loc_key(lx, lz));
			if (it == grounds.end() || sx < 0 || sz < 0 || sx >= s || sz >= s) {
				continue;
			}
			c.ground[(size_t)(j * c.vw + i)] = it->second[sz * s + sx];
		}
	}
	const Dictionary hd = p_p.get("heights", Dictionary());
	const Array hk = hd.keys();
	for (int64_t i = 0; i < hk.size(); i++) {
		const PackedFloat32Array a = hd[hk[i]];
		if (a.size() >= 3) {
			c.heights[(int64_t)hk[i]] = { a[0], a[1], a[2] };
		}
	}
	const Dictionary st = p_p.get("styles", Dictionary());
	const Array stk = st.keys();
	for (int64_t i = 0; i < stk.size(); i++) {
		c.styles[(int64_t)stk[i]] = style_of(st[stk[i]]);
	}
	const Dictionary r = p_p.get("rules", Dictionary());
	c.rules.sea = r.get("sea", 0.6);
	c.rules.coast = r.get("coast", 120.0);
	c.rules.mid = r.get("mid", 420.0);
	c.rules.treeline = r.get("treeline", 700.0);
	c.rules.slope_thin = r.get("slope_thin", 0.8);
	c.rules.slope_max = r.get("slope_max", 1.2);
	c.seed = p_p.get("seed", 0);
	return true;
}

// Each quad's densest far texel: its cover, type and age (quad index = world quad + 1).
void quads_of(Cell &c) {
	c.qcov.assign((size_t)(c.qw * c.qw), 0);
	c.qtype.assign((size_t)(c.qw * c.qw), 0);
	c.qage.assign((size_t)(c.qw * c.qw), 128);
	for (int64_t qj = 0; qj < c.qw; qj++) {
		for (int64_t qi = 0; qi < c.qw; qi++) {
			uint8_t best = 0;
			uint8_t t = 0;
			uint8_t a = 128;
			for (int64_t v = 0; v < c.k; v++) {
				const uint8_t *row = c.texels.data() + ((qj * c.k + v) * c.tw + qi * c.k) * 4;
				for (int64_t u = 0; u < c.k; u++) {
					if (row[u * 4 + 1] > best) {
						best = row[u * 4 + 1];
						t = row[u * 4];
						a = row[u * 4 + 2];
					}
				}
			}
			c.qcov[(size_t)(qj * c.qw + qi)] = best;
			c.qtype[(size_t)(qj * c.qw + qi)] = t;
			c.qage[(size_t)(qj * c.qw + qi)] = a;
		}
	}
}

bool near_cover(const Cell &c, int64_t p_qi, int64_t p_qj) {
	for (int64_t j = std::max<int64_t>(p_qj - 1, 0); j < std::min<int64_t>(p_qj + 2, c.qw); j++) {
		for (int64_t i = std::max<int64_t>(p_qi - 1, 0); i < std::min<int64_t>(p_qi + 2, c.qw); i++) {
			if (c.qcov[(size_t)(j * c.qw + i)] > 0) {
				return true;
			}
		}
	}
	return false;
}

// The densest covered quad of the size x size block from (qi0, qj0), as its index; -1 when none (ties: the first, row by row).
int64_t densest(const Cell &c, int64_t p_qi0, int64_t p_qj0, int64_t p_size) {
	int64_t best = -1;
	uint8_t bc = 0;
	for (int64_t j = std::max<int64_t>(p_qj0, 0); j < std::min<int64_t>(p_qj0 + p_size, c.qw); j++) {
		for (int64_t i = std::max<int64_t>(p_qi0, 0); i < std::min<int64_t>(p_qi0 + p_size, c.qw); i++) {
			const uint8_t cv = c.qcov[(size_t)(j * c.qw + i)];
			if (cv > bc) {
				bc = cv;
				best = j * c.qw + i;
			}
		}
	}
	return best;
}

double ground_at(const Cell &c, int64_t p_i, int64_t p_j) {
	if (p_i < 0 || p_j < 0 || p_i >= c.vw || p_j >= c.vw) {
		return NAN;
	}
	return c.ground[(size_t)(p_j * c.vw + p_i)];
}

// The slope along one axis from the heights before (a) and after (b) a vertex at h: central where both are known,
// one-sided where one is, 0 where neither.
double slope_d(double p_a, double p_h, double p_b, double p_g) {
	if (!std::isnan(p_a) && !std::isnan(p_b)) {
		return (p_b - p_a) / (2.0 * p_g);
	}
	if (!std::isnan(p_b)) {
		return (p_b - p_h) / p_g;
	}
	if (!std::isnan(p_a)) {
		return (p_h - p_a) / p_g;
	}
	return 0.0;
}

// The forest's rules by place at a vertex: 0 under the sea line, above a natural type's treeline (its cards draw none
// there) or on a cliff; thinned linearly over the slope band; else 1.
double rule_at(const Cell &c, int64_t p_vi, int64_t p_vj, double p_h, uint8_t p_style) {
	if (p_h < c.rules.sea) {
		return 0.0;
	}
	if (p_style == STYLE_NATURAL && p_h > c.rules.treeline) {
		return 0.0;
	}
	const double dx = slope_d(ground_at(c, p_vi - 1, p_vj), p_h, ground_at(c, p_vi + 1, p_vj), c.g);
	const double dz = slope_d(ground_at(c, p_vi, p_vj - 1), p_h, ground_at(c, p_vi, p_vj + 1), c.g);
	const double slope = std::sqrt(dx * dx + dz * dz);
	if (slope > c.rules.slope_max) {
		return 0.0;
	}
	if (slope > c.rules.slope_thin) {
		return 1.0 - (slope - c.rules.slope_thin) / (c.rules.slope_max - c.rules.slope_thin);
	}
	return 1.0;
}

// The vertex at vertex index (vi, vj); false where its ground is unknown. Canopy when a covered quad touches it (its type
// and age the densest one's), else a wall's foot (the type of the densest covered quad within one more quad).
bool vertex(const Cell &c, int64_t p_vi, int64_t p_vj, Vector3 &r_pos, float *r_custom) {
	const double h = c.ground[(size_t)(p_vj * c.vw + p_vi)];
	if (std::isnan(h)) {
		return false;
	}
	int64_t src = densest(c, p_vi - 1, p_vj - 1, 2);
	const bool canopy = src >= 0;
	if (!canopy) {
		src = densest(c, p_vi - 2, p_vj - 2, 4);
	}
	const int64_t t = src >= 0 ? (int64_t)c.qtype[(size_t)src] : 0;
	const double age = src >= 0 ? std::clamp(((double)c.qage[(size_t)src] - 128.0) / 127.0, -1.0, 1.0) : 0.0;
	const double x = c.ox + (double)(p_vi - 1) * c.g;
	const double z = c.oz + (double)(p_vj - 1) * c.g;
	const auto si = c.styles.find(t);
	const uint8_t style = si == c.styles.end() ? NO_STYLE : si->second;
	const double rule = rule_at(c, p_vi, p_vj, h, style);
	double y = std::min(h, c.rules.sea) - SKIRT_M;
	if (canopy) {
		const auto hi = c.heights.find(t);
		const std::array<float, 3> hs = hi == c.heights.end() ? std::array<float, 3>{ 0.0f, 0.0f, 0.0f } : hi->second;
		const int band = h < c.rules.coast ? 0 : (h < c.rules.mid ? 1 : 2);
		y = h + (double)hs[(size_t)band] * mean_scale(style, age) * (1.0 + RELIEF * lump(x, z, c.seed));
	}
	r_pos = Vector3((real_t)x, (real_t)y, (real_t)z);
	r_custom[0] = (float)rule;
	r_custom[1] = canopy ? 0.0f : 1.0f;
	r_custom[2] = (float)h;
	r_custom[3] = (float)t;
	return true;
}

Dictionary build_mesh(Cell &c, Array &r_arrays) {
	quads_of(c);
	std::vector<int32_t> index((size_t)(c.vw * c.vw), -1);
	std::vector<Vector3> verts;
	std::vector<float> custom;
	std::vector<int32_t> tris;
	int64_t quads = 0;
	for (int64_t qj = 1; qj <= c.n; qj++) {
		for (int64_t qi = 1; qi <= c.n; qi++) {
			if (!near_cover(c, qi, qj)) {
				continue;
			}
			// Vertex index = world vertex + 1: quad qi spans vertices qi and qi + 1.
			const int64_t cv[4][2] = { { qi, qj }, { qi + 1, qj }, { qi + 1, qj + 1 }, { qi, qj + 1 } };
			int32_t ids[4];
			bool hole = false;
			for (int q = 0; q < 4; q++) {
				const size_t at = (size_t)(cv[q][1] * c.vw + cv[q][0]);
				if (index[at] == -1) {
					Vector3 p;
					float cu[4];
					if (vertex(c, cv[q][0], cv[q][1], p, cu)) {
						index[at] = (int32_t)verts.size();
						verts.push_back(p);
						custom.insert(custom.end(), cu, cu + 4);
					} else {
						index[at] = -2;
					}
				}
				ids[q] = index[at];
				hole = hole || ids[q] == -2;
			}
			if (hole) {
				continue;
			}
			// Front faces up (the project's winding rule: (v2 - v0) x (v1 - v0) . up > 0).
			tris.insert(tris.end(), { ids[0], ids[1], ids[2], ids[0], ids[2], ids[3] });
			quads++;
		}
	}
	Dictionary out;
	out["quads"] = quads;
	if (quads == 0) {
		r_arrays = Array();
		return out;
	}
	// A canopy vertex is lit as canopy: a wall vertex beside it (down under the sea line) counts as its own height.
	auto y_of = [&](int64_t p_vi, int64_t p_vj, float p_own, bool p_canopy_only) -> float {
		if (p_vi < 0 || p_vj < 0 || p_vi >= c.vw || p_vj >= c.vw) {
			return p_own;
		}
		const int32_t id = index[(size_t)(p_vj * c.vw + p_vi)];
		if (id < 0 || (p_canopy_only && custom[(size_t)id * 4 + 1] != 0.0f)) {
			return p_own;
		}
		return verts[(size_t)id].y;
	};
	PackedVector3Array pv;
	pv.resize((int64_t)verts.size());
	PackedVector3Array pn;
	pn.resize((int64_t)verts.size());
	for (int64_t vj = 0; vj < c.vw; vj++) {
		for (int64_t vi = 0; vi < c.vw; vi++) {
			const int32_t id = index[(size_t)(vj * c.vw + vi)];
			if (id < 0) {
				continue;
			}
			const float y = verts[(size_t)id].y;
			const bool lit = custom[(size_t)id * 4 + 1] == 0.0f;
			const float yl = y_of(vi - 1, vj, y, lit);
			const float yr = y_of(vi + 1, vj, y, lit);
			const float yd = y_of(vi, vj - 1, y, lit);
			const float yu = y_of(vi, vj + 1, y, lit);
			pn.set(id, Vector3(yl - yr, (real_t)(2.0 * c.g), yd - yu).normalized());
			pv.set(id, verts[(size_t)id]);
		}
	}
	PackedFloat32Array pc;
	pc.resize((int64_t)custom.size());
	std::copy(custom.begin(), custom.end(), pc.ptrw());
	PackedInt32Array pi;
	pi.resize((int64_t)tris.size());
	std::copy(tris.begin(), tris.end(), pi.ptrw());
	r_arrays = Array();
	r_arrays.resize(Mesh::ARRAY_MAX);
	r_arrays[Mesh::ARRAY_VERTEX] = pv;
	r_arrays[Mesh::ARRAY_NORMAL] = pn;
	r_arrays[Mesh::ARRAY_CUSTOM0] = pc;
	r_arrays[Mesh::ARRAY_INDEX] = pi;
	return out;
}

} // namespace

Dictionary wf::far_summarise(const PackedByteArray &p_data, int64_t p_w, int64_t p_out_w, const PackedInt32Array &p_ids) {
	Dictionary res;
	PackedByteArray out;
	bool any = false;
	if (p_w <= 0 || p_out_w <= 0 || p_data.size() != p_w * p_w * 4) {
		res["texels"] = out;
		res["any"] = false;
		return res;
	}
	bool known[256] = {};
	for (int64_t i = 0; i < p_ids.size(); i++) {
		const int32_t id = p_ids[i];
		if (id > 0 && id < 256) {
			known[id] = true;
		}
	}
	out.resize(p_out_w * p_out_w * 4);
	uint8_t *o = out.ptrw();
	const uint8_t *px = p_data.ptr();
	const double step = (double)p_w / (double)p_out_w;
	for (int64_t j = 0; j < p_out_w; j++) {
		const int64_t y0 = (int64_t)((double)j * step);
		const int64_t y1 = std::min(std::max((int64_t)((double)(j + 1) * step), y0 + 1), p_w);
		for (int64_t i = 0; i < p_out_w; i++) {
			const int64_t x0 = (int64_t)((double)i * step);
			const int64_t x1 = std::min(std::max((int64_t)((double)(i + 1) * step), x0 + 1), p_w);
			uint64_t sg = 0;
			uint64_t sb = 0;
			uint64_t cnt = 0;
			for (int64_t y = y0; y < y1; y++) {
				for (int64_t x = x0; x < x1; x++) {
					const uint8_t *p = px + (y * p_w + x) * 4;
					if (known[p[0]]) {
						sg += p[1];
					}
					sb += p[2];
					cnt++;
				}
			}
			const uint8_t cover = (uint8_t)((sg * 2 + cnt) / (2 * cnt));
			const uint8_t age = (uint8_t)((sb * 2 + cnt) / (2 * cnt));
			uint8_t t = 0;
			if (cover > 0) {
				const int64_t cx = std::min((int64_t)(((double)i + 0.5) * step), p_w - 1);
				const int64_t cy = std::min((int64_t)(((double)j + 0.5) * step), p_w - 1);
				const uint8_t centre = px[(cy * p_w + cx) * 4];
				if (known[centre]) {
					t = centre;
				} else {
					for (int64_t y = y0; y < y1 && t == 0; y++) {
						for (int64_t x = x0; x < x1; x++) {
							const uint8_t v = px[(y * p_w + x) * 4];
							if (known[v]) {
								t = v;
								break;
							}
						}
					}
				}
			}
			uint8_t *d = o + (j * p_out_w + i) * 4;
			d[0] = t;
			d[1] = t != 0 ? cover : 0;
			d[2] = age;
			d[3] = 0;
			any = any || d[1] > 0;
		}
	}
	res["texels"] = out;
	res["any"] = any;
	return res;
}

PackedFloat32Array wf::far_sample_ground(const PackedByteArray &p_data, int64_t p_w, int64_t p_h, int64_t p_s, double p_step) {
	PackedFloat32Array out;
	if (p_w <= 0 || p_h <= 0 || p_s <= 0 || p_data.size() != p_w * p_h * 4) {
		return out;
	}
	out.resize(p_s * p_s);
	float *o = out.ptrw();
	const uint8_t *px = p_data.ptr();
	for (int64_t j = 0; j < p_s; j++) {
		const int64_t y = std::min((int64_t)std::llround((double)j * p_step), p_h - 1);
		for (int64_t i = 0; i < p_s; i++) {
			const int64_t x = std::min((int64_t)std::llround((double)i * p_step), p_w - 1);
			std::memcpy(o + j * p_s + i, px + (y * p_w + x) * 4, sizeof(float));
		}
	}
	return out;
}

Dictionary wf::far_build_cell(const Dictionary &p_p) {
	Dictionary res;
	Cell c;
	String why;
	if (!assemble(p_p, c, why)) {
		res["arrays"] = Array();
		res["quads"] = 0;
		res["texels"] = PackedByteArray();
		res["tw"] = 0;
		res["error"] = why;
		return res;
	}
	Array arrays;
	const Dictionary m = build_mesh(c, arrays);
	// The cell's own far texels, the margin cut off: the shader's summary texture.
	const int64_t tw = c.n * c.k;
	PackedByteArray inner;
	inner.resize(tw * tw * 4);
	uint8_t *w = inner.ptrw();
	for (int64_t v = 0; v < tw; v++) {
		std::memcpy(w + v * tw * 4, c.texels.data() + ((v + c.k) * c.tw + c.k) * 4, (size_t)(tw * 4));
	}
	res["arrays"] = arrays;
	res["quads"] = m["quads"];
	res["texels"] = inner;
	res["tw"] = tw;
	res["error"] = String();
	return res;
}
