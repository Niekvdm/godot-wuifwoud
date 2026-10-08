// Copyright (c) 2026 Digitzone
// SPDX-License-Identifier: MIT
#include "place/wf_place.h"

#include "arena/wf_arena.h"
#include "common/wf_hash.h"
#include "common/wf_rules.h"
#include "wf_tables.h"

#include <godot_cpp/classes/ref.hpp>
#include <godot_cpp/variant/array.hpp>
#include <godot_cpp/variant/packed_float32_array.hpp>
#include <godot_cpp/variant/packed_int32_array.hpp>
#include <godot_cpp/variant/packed_int64_array.hpp>
#include <godot_cpp/variant/vector2i.hpp>
#include <godot_cpp/variant/vector3.hpp>

#include <algorithm>
#include <cmath>
#include <cstring>
#include <unordered_map>
#include <vector>

using namespace godot;
using namespace wf;

namespace {

constexpr double TAU = 6.28318530717958647692;

// The ground under a cell: the region copies a job was handed, sampled as ForestHeightCache samples them (bilinear over
// the vertex spacing; a tap with weight in a missing region is NaN).
struct Ground {
	struct Reg {
		int64_t lx = 0;
		int64_t lz = 0;
		const float *h = nullptr;
	};
	std::vector<Reg> regs;
	std::vector<PackedFloat32Array> keep;
	int64_t rs = 0;
	double vs = 1.0;
	int64_t memo = -1;
	String error;

	void read(const Array &p_regions, int64_t p_rs, double p_vs) {
		rs = p_rs;
		vs = p_vs;
		if (rs <= 0 || !(vs > 0.0) || p_regions.size() % 2 != 0) {
			error = "the height regions are not [location, heights] pairs over a region size and spacing";
			return;
		}
		for (int64_t i = 0; i < p_regions.size(); i += 2) {
			const Vector2i loc = p_regions[i];
			const PackedFloat32Array h = p_regions[i + 1];
			if (h.size() != rs * rs) {
				error = String("the heights of region (") + String::num_int64(loc.x) + ", " + String::num_int64(loc.y) +
						") are not " + String::num_int64(rs) + " squared";
				regs.clear();
				keep.clear();
				return;
			}
			keep.push_back(h);
			regs.push_back({ loc.x, loc.y, nullptr });
		}
		for (size_t i = 0; i < regs.size(); i++) {
			regs[i].h = keep[i].ptr();
		}
		if (regs.empty()) {
			error = "no height regions";
		}
	}

	static int64_t fdiv(int64_t p_a, int64_t p_b) {
		return p_a >= 0 ? p_a / p_b : -((-p_a + p_b - 1) / p_b);
	}

	float vertex(int64_t p_vx, int64_t p_vz) {
		const int64_t lx = fdiv(p_vx, rs);
		const int64_t lz = fdiv(p_vz, rs);
		if (memo < 0 || regs[(size_t)memo].lx != lx || regs[(size_t)memo].lz != lz) {
			memo = -1;
			for (size_t i = 0; i < regs.size(); i++) {
				if (regs[i].lx == lx && regs[i].lz == lz) {
					memo = (int64_t)i;
					break;
				}
			}
			if (memo < 0) {
				return NAN;
			}
		}
		return regs[(size_t)memo].h[(p_vz - lz * rs) * rs + (p_vx - lx * rs)];
	}

	double height(double p_x, double p_z) {
		const double px = p_x / vs;
		const double pz = p_z / vs;
		const double fx0 = std::floor(px);
		const double fz0 = std::floor(pz);
		const int64_t x0 = (int64_t)fx0;
		const int64_t z0 = (int64_t)fz0;
		const double fx = px - fx0;
		const double fz = pz - fz0;
		const double w[4] = { (1.0 - fx) * (1.0 - fz), fx * (1.0 - fz), (1.0 - fx) * fz, fx * fz };
		const int64_t tx[4] = { x0, x0 + 1, x0, x0 + 1 };
		const int64_t tz[4] = { z0, z0, z0 + 1, z0 + 1 };
		double acc = 0.0;
		for (int i = 0; i < 4; i++) {
			if (!(w[i] > 0.0)) {
				continue;
			}
			const float h = vertex(tx[i], tz[i]);
			if (std::isnan(h)) {
				return NAN;
			}
			acc += (double)h * w[i];
		}
		return acc;
	}

	// |grad| at (x, z) the way Terrain3DData.get_normal measures it: one vertex spacing along x and z. -1 when a tap is
	// outside the copies (no slope gate, as before).
	double slope(double p_x, double p_z, double p_h) {
		const double hx = height(p_x + vs, p_z);
		const double hz = height(p_x, p_z + vs);
		if (std::isnan(p_h) || std::isnan(hx) || std::isnan(hz)) {
			return -1.0;
		}
		return std::sqrt((p_h - hx) * (p_h - hx) + (p_h - hz) * (p_h - hz)) / vs;
	}
};

int32_t pick(const Pool &p_pool, uint64_t p_seed, uint64_t p_salt) {
	if (p_pool.empty()) {
		return -1;
	}
	const double r = (double)u01(p_seed, p_salt) * p_pool.total;
	for (size_t i = 0; i < p_pool.sp.size(); i++) {
		if (p_pool.run[i] >= r) {
			return p_pool.sp[i];
		}
	}
	return p_pool.sp.back();
}

// The pool an aged tree draws from: with probability |age| the young (age < 0) or mature subset.
const Pool &aged(const Pool &p_pool, const Pool &p_young, const Pool &p_mature, float p_age, uint64_t p_seed) {
	if (p_age == 0.0f || u01(p_seed, S_AGED) >= std::fabs(p_age)) {
		return p_pool;
	}
	const Pool &sub = p_age < 0.0f ? p_young : p_mature;
	return sub.empty() ? p_pool : sub;
}

// A point's species: by its type's style, the elevation band, its role and its age; -1 for none.
int32_t pick_typed(const Type &t, double p_h, double p_coast, double p_mid, uint64_t p_seed, uint8_t p_role, float p_age) {
	switch (t.style) {
		case STYLE_NATURAL: {
			const int b = p_h < p_coast ? 0 : (p_h < p_mid ? 1 : 2);
			if (p_role == R_DEAD) {
				return pick(t.dead[b], p_seed, S_PICK_DEAD);
			}
			if (p_role == R_SCRUB || p_role == R_UNDER) {
				return pick(t.bush, p_seed, S_PICK);
			}
			if (p_role == R_WALL && !t.mature[b].empty()) {
				return pick(t.mature[b], p_seed, S_PICK);
			}
			if (p_role == R_EDGE) {
				if (u01(p_seed, S_EDGE) < 0.45f) {
					return pick(t.bush, p_seed, S_PICK);
				}
				if (!t.young[b].empty()) {
					return pick(t.young[b], p_seed, S_PICK);
				}
			}
			if (p_role == R_TREE) {
				return pick(aged(t.bands[b], t.young[b], t.mature[b], p_age, p_seed), p_seed, S_PICK);
			}
			return pick(t.bands[b], p_seed, S_PICK);
		}
		case STYLE_BUSHES:
			return pick(t.bush, p_seed, S_PICK);
		case STYLE_GRID:
			return pick(t.pool, p_seed, S_PICK);
		case STYLE_MIX:
			if ((double)u01(p_seed, S_MIX) < t.tree_share) {
				return pick(p_role == R_TREE ? aged(t.tree, t.tree_young, t.tree_mature, p_age, p_seed) : t.tree, p_seed, S_PICK);
			}
			return pick(t.bush, p_seed, S_PICK);
		default:
			return -1;
	}
}

// A tree's scale from r (0..1): 0.8-1.45, sliding by |age| toward the young range (0.6-1.0) or old growth's (1.1-1.5) for
// a tree of a natural or mix type.
double tree_scale(const Type &t, uint8_t p_mrole, float p_age, double p_r) {
	if (p_age == 0.0f || p_mrole != R_TREE || !(t.style == STYLE_NATURAL || t.style == STYLE_MIX)) {
		return lerp(0.8, 1.45, p_r);
	}
	const double k = std::fabs((double)p_age);
	return lerp(lerp(0.8, p_age < 0.0f ? 0.6 : 1.1, k), lerp(1.45, p_age < 0.0f ? 1.0 : 1.5, k), p_r);
}

uint64_t key2(int64_t p_x, int64_t p_z) {
	return ((uint64_t)(uint32_t)(int32_t)p_x << 32) | (uint64_t)(uint32_t)(int32_t)p_z;
}

// Spread 16 bits so every other bit is free, for interleaving.
uint64_t part1by1(uint64_t p_v) {
	uint64_t n = p_v & 0x0000FFFFull;
	n = (n | (n << 8)) & 0x00FF00FFull;
	n = (n | (n << 4)) & 0x0F0F0F0Full;
	n = (n | (n << 2)) & 0x33333333ull;
	n = (n | (n << 1)) & 0x55555555ull;
	return n;
}

// The buffer order. THINNING ORDER: a hash of the position quantised to 0.25 m, so any prefix is a uniform sample of the
// slot (the per-chunk path's density knob is visible_instance_count). Z-ORDER (`spatial`) at 4 m: the GPU arena's level-1
// cull wants each run of instances a small patch of ground.
uint64_t order_key(float p_x, float p_z, bool p_spatial) {
	if (p_spatial) {
		const uint64_t qx = (uint64_t)std::clamp<int64_t>((int64_t)std::floor((double)p_x / 4.0) + 32768, 0, 65535);
		const uint64_t qz = (uint64_t)std::clamp<int64_t>((int64_t)std::floor((double)p_z / 4.0) + 32768, 0, 65535);
		return part1by1(qx) | (part1by1(qz) << 1);
	}
	return bits24(seed4(D_THIN, (int64_t)std::floor((double)p_x * 4.0), (int64_t)std::floor((double)p_z * 4.0), 0, 0), 0);
}

PackedFloat32Array pack(const std::vector<float> &p_inst, bool p_spatial) {
	const size_t n = p_inst.size() / 16;
	std::vector<uint64_t> key(n);
	std::vector<uint32_t> idx(n);
	for (size_t i = 0; i < n; i++) {
		key[i] = order_key(p_inst[i * 16 + 3], p_inst[i * 16 + 11], p_spatial);
		idx[i] = (uint32_t)i;
	}
	std::stable_sort(idx.begin(), idx.end(), [&](uint32_t a, uint32_t b) { return key[a] < key[b]; });
	PackedFloat32Array buf;
	buf.resize((int64_t)(n * 16));
	float *w = buf.ptrw();
	for (size_t k = 0; k < n; k++) {
		std::memcpy(w + k * 16, p_inst.data() + (size_t)idx[k] * 16, 16 * sizeof(float));
	}
	return buf;
}

// A packed slot's level-1 clusters for the GPU arena: the walk ForestIndirect's install would otherwise do,
// done here on the worker over the slot's own order, radius WITHOUT the species' reach (ForestIndirect adds it: the
// species' radius is the catalog's, which the kernel does not hold).
PackedFloat32Array clusters_of(const PackedFloat32Array &p_buf, int64_t p_n) {
	std::vector<float> walked;
	wf::walk_clusters(p_buf.ptr(), p_n, 16, 0.0, walked);
	PackedFloat32Array out;
	out.resize((int64_t)walked.size());
	std::copy(walked.begin(), walked.end(), out.ptrw());
	return out;
}

struct Slot {
	int64_t bx = 0;
	int64_t bz = 0;
	int32_t sp = 0;
	std::vector<float> inst;
};

struct CardCell {
	int64_t cx = 0;
	int64_t cz = 0;
	std::vector<Slot> slots;
	std::unordered_map<int32_t, size_t> by_sp;
};

struct TrunkCell {
	int64_t cx = 0;
	int64_t cz = 0;
	std::vector<float> trunks;
	std::vector<std::pair<int32_t, std::vector<float>>> crowns;
	std::unordered_map<int32_t, size_t> by_sp;
};

Dictionary failed(const String &p_why) {
	Dictionary r;
	r["species"] = Dictionary();
	r["bbs"] = Dictionary();
	r["trunks"] = Dictionary();
	r["crowns"] = Dictionary();
	r["error"] = p_why;
	return r;
}

} // namespace

void wf::put_instance(float *p_dst, const Basis &p_b, float p_ox, float p_oy, float p_oz, float p_r, float p_g, float p_bl,
		float p_a) {
	p_dst[0] = p_b.rows[0].x;
	p_dst[1] = p_b.rows[0].y;
	p_dst[2] = p_b.rows[0].z;
	p_dst[3] = p_ox;
	p_dst[4] = p_b.rows[1].x;
	p_dst[5] = p_b.rows[1].y;
	p_dst[6] = p_b.rows[1].z;
	p_dst[7] = p_oy;
	p_dst[8] = p_b.rows[2].x;
	p_dst[9] = p_b.rows[2].y;
	p_dst[10] = p_b.rows[2].z;
	p_dst[11] = p_oz;
	p_dst[12] = p_r;
	p_dst[13] = p_g;
	p_dst[14] = p_bl;
	p_dst[15] = p_a;
}

Dictionary wf::place_cell(const Dictionary &p_job) {
	const Ref<WfTables> tables = p_job.get("tables", Variant());
	if (tables.is_null()) {
		return failed("no tables");
	}
	if (!tables->error().is_empty()) {
		return failed(String("the tables: ") + tables->error());
	}
	const Dictionary pts = p_job.get("pts", Dictionary());
	const int64_t n = pts.get("n", 0);
	const PackedFloat32Array pos = pts.get("pos", PackedFloat32Array());
	const PackedInt32Array info = pts.get("info", PackedInt32Array());
	const PackedInt64Array seeds = pts.get("seed", PackedInt64Array());
	const PackedFloat32Array ages = pts.get("age", PackedFloat32Array());
	if (n < 0 || pos.size() != n * 2 || info.size() != n * 2 || seeds.size() != n || ages.size() != n) {
		return failed("the points' arrays differ in length");
	}
	Ground ground;
	ground.read(p_job.get("regions", Array()), p_job.get("region_size", 0), p_job.get("vertex_spacing", 1.0));
	if (!ground.error.is_empty()) {
		return failed(ground.error);
	}
	const Dictionary params = p_job.get("params", Dictionary());
	const int64_t forest_seed = params.get("seed", 0);
	const double sea = params.get("sea", 0.6);
	const double coast = params.get("coast", 120.0);
	const double mid = params.get("mid", 420.0);
	const double treeline = params.get("treeline", 700.0);
	const double keep = params.get("treeline_keep", 0.4);
	const bool cards = params.get("cards", true);
	const double bucket_m = params.get("bucket_m", 64.0);
	const double bb_cell_m = params.get("bb_cell_m", 1024.0);
	const double trunk_cell_m = params.get("trunk_cell_m", 64.0);
	const bool spatial = p_job.get("spatial", false);
	if (!(bucket_m > 0.0) || !(bb_cell_m > 0.0) || !(trunk_cell_m > 0.0)) {
		return failed("a bucket, card cell or trunk cell of no size");
	}

	std::vector<Slot> slots;
	std::unordered_map<uint64_t, std::unordered_map<int32_t, size_t>> slot_of;
	std::vector<CardCell> card_cells;
	std::unordered_map<uint64_t, size_t> card_of;
	std::vector<TrunkCell> trunk_cells;
	std::unordered_map<uint64_t, size_t> trunk_of;
	float inst[16];

	for (int64_t i = 0; i < n; i++) {
		const double x = pos[2 * i];
		const double z = pos[2 * i + 1];
		const double h = ground.height(x, z);
		if (std::isnan(h) || h < sea) {
			continue;
		}
		const int32_t f = info[2 * i];
		const uint64_t sd = (uint64_t)seeds[i];
		const bool item = ((f >> 16) & 1) != 0;
		// SLOPE: a cliff carries rock, not forest, and the band below the cut THINS (a hillside does not end at a line).
		const double slope = ground.slope(x, z, h);
		if (slope >= 0.0) {
			if (slope > SLOPE_MAX) {
				continue;
			}
			if (!item && slope > SLOPE_THIN && (double)u01(sd, S_SLOPE) < (slope - SLOPE_THIN) / (SLOPE_MAX - SLOPE_THIN)) {
				continue;
			}
		}
		const Type *t = tables->type(f & 0xFF);
		if (t == nullptr) {
			continue;
		}
		uint8_t role = (uint8_t)((f >> 8) & 0xF);
		if (t->style == STYLE_NATURAL && role != R_UNDER && !item) {
			if (h > treeline) {
				if (role == R_BB || (double)u01(sd, S_TREELINE) > keep) {
					continue; // no far canopy above the treeline; the trees thin to treeline_keep
				}
				role = R_SCRUB;
			} else if (role == R_TREE && value_noise(x, z, CLEARING_SCALE, forest_seed, N_CLEARING) < CLEARING_FLOOR + CLEARING_EDGE) {
				role = R_EDGE; // the glade's soft edge regrows as young trees and bushes
			}
		}
		const uint8_t mrole = role == R_BB ? (uint8_t)((f >> 12) & 0xF) : role;
		const float age = ages[i];
		int32_t sp = item ? info[2 * i + 1] : -1;
		if (sp < 0 || sp >= tables->count()) {
			sp = pick_typed(*t, h, coast, mid, sd, mrole, age);
		}
		if (sp < 0) {
			continue;
		}
		const double yaw = (double)u01(sd, S_YAW) * TAU;
		const double r_scale = (double)u01(sd, S_SCALE);
		const double scl = mrole == R_WALL ? lerp(1.1, 1.5, r_scale) : tree_scale(*t, mrole, age, r_scale);
		const double tb = lerp(0.82, 1.12, (double)u01(sd, S_TINT_B));
		const double warm = ((double)u01(sd, S_TINT_W) - 0.5) * 0.14;
		const float cr = (float)std::clamp(tb + warm, 0.0, 1.3);
		const float cb = (float)std::clamp(tb - warm, 0.0, 1.3);
		const float oy = (float)(h - 0.05);
		if (role == R_BB) {
			// A card: a LOD of the mesh tree, with its yaw (the bake is looked up in the instance's frame), upright, no lean.
			if (tables->bush(sp) || !cards) {
				continue;
			}
			const Basis b = Basis(Vector3(0, 1, 0), (real_t)yaw).scaled(Vector3((real_t)scl, (real_t)scl, (real_t)scl));
			put_instance(inst, b, (float)x, oy, (float)z, cr, (float)tb, cb, 1.0f);
			const int64_t cx = cell_of(x, bb_cell_m);
			const int64_t cz = cell_of(z, bb_cell_m);
			const uint64_t ck = key2(cx, cz);
			auto it = card_of.find(ck);
			if (it == card_of.end()) {
				it = card_of.emplace(ck, card_cells.size()).first;
				CardCell cell;
				cell.cx = cx;
				cell.cz = cz;
				card_cells.push_back(cell);
			}
			CardCell &cell = card_cells[it->second];
			auto st = cell.by_sp.find(sp);
			if (st == cell.by_sp.end()) {
				st = cell.by_sp.emplace(sp, cell.slots.size()).first;
				Slot s;
				s.sp = sp;
				cell.slots.push_back(s);
			}
			cell.slots[st->second].inst.insert(cell.slots[st->second].inst.end(), inst, inst + 16);
			continue;
		}
		const double lean = ((double)u01(sd, S_LEAN) - 0.5) * 0.12;
		const Basis b = Basis(Vector3(0, 1, 0), (real_t)yaw)
								.rotated(Vector3(1, 0, 0), (real_t)lean)
								.scaled(Vector3((real_t)scl, (real_t)scl, (real_t)scl));
		put_instance(inst, b, (float)x, oy, (float)z, cr, (float)tb, cb, 1.0f);
		// RENDER BUCKET: Godot culls and picks a mesh LOD per MultiMesh, so a species is split by bucket_m.
		const int64_t bx = cell_of(x, bucket_m);
		const int64_t bz = cell_of(z, bucket_m);
		std::unordered_map<int32_t, size_t> &by_sp = slot_of[key2(bx, bz)];
		auto st = by_sp.find(sp);
		if (st == by_sp.end()) {
			st = by_sp.emplace(sp, slots.size()).first;
			Slot s;
			s.bx = bx;
			s.bz = bz;
			s.sp = sp;
			slots.push_back(s);
		}
		slots[st->second].inst.insert(slots[st->second].inst.end(), inst, inst + 16);
		const double trunk = (double)tables->trunk(sp) * scl;
		if (trunk > 0.0) {
			const int64_t tcx = cell_of(x, trunk_cell_m);
			const int64_t tcz = cell_of(z, trunk_cell_m);
			const uint64_t tk = key2(tcx, tcz);
			auto tt = trunk_of.find(tk);
			if (tt == trunk_of.end()) {
				tt = trunk_of.emplace(tk, trunk_cells.size()).first;
				TrunkCell tc;
				tc.cx = tcx;
				tc.cz = tcz;
				trunk_cells.push_back(tc);
			}
			TrunkCell &tc = trunk_cells[tt->second];
			tc.trunks.insert(tc.trunks.end(), { (float)x, (float)h, (float)z, (float)trunk });
			auto cs = tc.by_sp.find(sp);
			if (cs == tc.by_sp.end()) {
				cs = tc.by_sp.emplace(sp, tc.crowns.size()).first;
				tc.crowns.push_back({ sp, std::vector<float>() });
			}
			// RAW crowns: a crown's size comes from the species mesh, which a worker may not load (the commit sizes it).
			tc.crowns[cs->second].second.insert(tc.crowns[cs->second].second.end(), { (float)x, (float)z, (float)h, (float)scl });
		}
	}

	Dictionary species;
	for (const Slot &s : slots) {
		Dictionary d;
		const PackedFloat32Array buf = pack(s.inst, false);
		d["buf"] = buf;
		d["n"] = (int64_t)(s.inst.size() / 16);
		d["clusters"] = clusters_of(buf, (int64_t)(s.inst.size() / 16));
		d["mesh"] = tables->name_of(s.sp);
		d["bucket"] = Vector2i((int32_t)s.bx, (int32_t)s.bz);
		species[String::num_int64(s.bx) + "," + String::num_int64(s.bz) + "/" + tables->name_of(s.sp)] = d;
	}
	Dictionary bbs;
	for (const CardCell &cell : card_cells) {
		Dictionary per;
		for (const Slot &s : cell.slots) {
			Dictionary d;
			const PackedFloat32Array buf = pack(s.inst, spatial);
			d["buf"] = buf;
			d["n"] = (int64_t)(s.inst.size() / 16);
			d["clusters"] = clusters_of(buf, (int64_t)(s.inst.size() / 16));
			per[tables->name_of(s.sp)] = d;
		}
		bbs[Vector2i((int32_t)cell.cx, (int32_t)cell.cz)] = per;
	}
	Dictionary trunks;
	Dictionary crowns;
	for (const TrunkCell &tc : trunk_cells) {
		PackedFloat32Array a;
		a.resize((int64_t)tc.trunks.size());
		std::copy(tc.trunks.begin(), tc.trunks.end(), a.ptrw());
		trunks[Vector2i((int32_t)tc.cx, (int32_t)tc.cz)] = a;
		Dictionary per;
		for (const auto &c : tc.crowns) {
			PackedFloat32Array raw;
			raw.resize((int64_t)c.second.size());
			std::copy(c.second.begin(), c.second.end(), raw.ptrw());
			per[tables->name_of(c.first)] = raw;
		}
		crowns[Vector2i((int32_t)tc.cx, (int32_t)tc.cz)] = per;
	}
	Dictionary r;
	r["species"] = species;
	r["bbs"] = bbs;
	r["trunks"] = trunks;
	r["crowns"] = crowns;
	r["error"] = String();
	return r;
}
