// Copyright (c) 2026 Digitzone
// SPDX-License-Identifier: MIT
#include "scatter/wf_scatter.h"

#include "common/wf_hash.h"
#include "common/wf_rules.h"
#include "wf_roads.h"
#include "wf_tables.h"

#include <godot_cpp/classes/ref.hpp>
#include <godot_cpp/variant/array.hpp>
#include <godot_cpp/variant/packed_byte_array.hpp>
#include <godot_cpp/variant/packed_float32_array.hpp>
#include <godot_cpp/variant/packed_int32_array.hpp>
#include <godot_cpp/variant/packed_int64_array.hpp>
#include <godot_cpp/variant/packed_string_array.hpp>
#include <godot_cpp/variant/rect2.hpp>
#include <godot_cpp/variant/vector2i.hpp>

#include <algorithm>
#include <cmath>
#include <limits>
#include <unordered_map>
#include <vector>

using namespace godot;
using namespace wf;

namespace {

// The held maps a job was given: the texel under a world point.
struct View {
	struct Map {
		int64_t lx = 0;
		int64_t lz = 0;
		int64_t w = 0;
		const uint8_t *px = nullptr;
	};
	std::vector<Map> maps;
	std::vector<PackedByteArray> keep; // the bytes, held for the call
	double rm = 0.0;
	String error;

	void read(const Dictionary &p_view, double p_region_m) {
		rm = p_region_m;
		const Array keys = p_view.keys();
		for (int64_t i = 0; i < keys.size(); i++) {
			const Vector2i loc = keys[i];
			const Dictionary m = p_view[keys[i]];
			const int64_t w = m.get("w", 0);
			const PackedByteArray data = m.get("data", PackedByteArray());
			if (w <= 0 || data.size() != w * w * 4) {
				error = String("the map of region (") + String::num_int64(loc.x) + ", " + String::num_int64(loc.y) +
						") is not " + String::num_int64(w) + " x " + String::num_int64(w) + " RGBA8 texels";
				maps.clear();
				keep.clear();
				return;
			}
			keep.push_back(data);
			maps.push_back({ loc.x, loc.y, w, nullptr });
		}
		for (size_t i = 0; i < maps.size(); i++) {
			maps[i].px = keep[i].ptr();
		}
	}

	// R | G << 8 | B << 16 at world (x, z), or -1 where no map is held.
	int32_t texel(double p_x, double p_z) const {
		const int64_t lx = cell_of(p_x, rm);
		const int64_t lz = cell_of(p_z, rm);
		for (const Map &m : maps) {
			if (m.lx != lx || m.lz != lz) {
				continue;
			}
			const double tm = rm / (double)m.w;
			const int64_t tx = std::clamp<int64_t>(cell_of(p_x - (double)lx * rm, tm), 0, m.w - 1);
			const int64_t tz = std::clamp<int64_t>(cell_of(p_z - (double)lz * rm, tm), 0, m.w - 1);
			const uint8_t *p = m.px + (tz * m.w + tx) * 4;
			return (int32_t)p[0] | ((int32_t)p[1] << 8) | ((int32_t)p[2] << 16);
		}
		return -1;
	}
};

// The road corridor around a cell, its 64 m cells looked up once: a point's test is an array index.
struct Corridor {
	const WfRoads *roads = nullptr;
	int64_t cx0 = 0;
	int64_t cz0 = 0;
	int64_t nx = 0;
	int64_t nz = 0;
	std::vector<const std::vector<int32_t> *> cells;

	void init(const WfRoads *p_roads, double p_x0, double p_z0, double p_x1, double p_z1) {
		roads = p_roads;
		if (roads == nullptr) {
			return;
		}
		cx0 = cell_of(p_x0, WfRoads::CELL) - 2;
		cz0 = cell_of(p_z0, WfRoads::CELL) - 2;
		nx = cell_of(p_x1, WfRoads::CELL) + 3 - cx0;
		nz = cell_of(p_z1, WfRoads::CELL) + 3 - cz0;
		cells.resize((size_t)(nx * nz));
		for (int64_t j = 0; j < nz; j++) {
			for (int64_t i = 0; i < nx; i++) {
				cells[(size_t)(j * nx + i)] = roads->cell(cx0 + i, cz0 + j);
			}
		}
	}

	const std::vector<int32_t> *at(int64_t p_cx, int64_t p_cz) const {
		const int64_t i = p_cx - cx0;
		const int64_t j = p_cz - cz0;
		if (i >= 0 && j >= 0 && i < nx && j < nz) {
			return cells[(size_t)(j * nx + i)];
		}
		return roads->cell(p_cx, p_cz);
	}

	// Within a road's half width + `margin` (the corridor's own margin for a map tree, an item's for an item).
	bool blocked(double p_x, double p_z, double p_margin) const {
		if (roads == nullptr) {
			return false;
		}
		const std::vector<int32_t> *c = at(cell_of(p_x, WfRoads::CELL), cell_of(p_z, WfRoads::CELL));
		if (c == nullptr) {
			return false;
		}
		for (const int32_t s : *c) {
			if (roads->seg_dist(s, p_x, p_z) < roads->half_width(s) + p_margin) {
				return true;
			}
		}
		return false;
	}

	// To the nearest corridor edge among the roads of the 3 x 3 cells around (x, z); INF none.
	double edge_dist(double p_x, double p_z) const {
		double best = std::numeric_limits<double>::infinity();
		if (roads == nullptr) {
			return best;
		}
		const int64_t cx = cell_of(p_x, WfRoads::CELL);
		const int64_t cz = cell_of(p_z, WfRoads::CELL);
		for (int64_t j = cz - 1; j <= cz + 1; j++) {
			for (int64_t i = cx - 1; i <= cx + 1; i++) {
				const std::vector<int32_t> *c = at(i, j);
				if (c == nullptr) {
					continue;
				}
				for (const int32_t s : *c) {
					best = std::min(best, roads->seg_dist(s, p_x, p_z) - (roads->half_width(s) + roads->margin()));
				}
			}
		}
		return best;
	}
};

// The single trees' and rows' clearances: within clear_m of a tree's point or a row's line.
struct Clearance {
	std::vector<double> s; // ax, az, bx, bz, r^2

	void read(const PackedFloat32Array &p_c) {
		for (int64_t i = 0; i + 4 < p_c.size(); i += 5) {
			const double r = p_c[i + 4];
			if (!(r > 0.0)) {
				continue;
			}
			s.insert(s.end(), { (double)p_c[i], (double)p_c[i + 1], (double)p_c[i + 2], (double)p_c[i + 3], r * r });
		}
	}

	bool hit(double p_x, double p_z) const {
		for (size_t i = 0; i < s.size(); i += 5) {
			const double abx = s[i + 2] - s[i];
			const double abz = s[i + 3] - s[i + 1];
			const double l2 = abx * abx + abz * abz;
			const double t = l2 <= 0.0 ? 0.0 : std::clamp(((p_x - s[i]) * abx + (p_z - s[i + 1]) * abz) / l2, 0.0, 1.0);
			const double dx = p_x - (s[i] + abx * t);
			const double dz = p_z - (s[i + 1] + abz * t);
			if (dx * dx + dz * dz < s[i + 4]) {
				return true;
			}
		}
		return false;
	}
};

struct Points {
	std::vector<float> pos;
	std::vector<int32_t> info;
	std::vector<int64_t> seed;
	std::vector<float> age;

	void add(double p_x, double p_z, int32_t p_type, uint64_t p_seed, uint8_t p_role, uint8_t p_mrole, float p_age,
			int32_t p_species, bool p_item) {
		pos.push_back((float)p_x);
		pos.push_back((float)p_z);
		info.push_back(p_type | ((int32_t)p_role << 8) | ((int32_t)p_mrole << 12) | ((p_item ? 1 : 0) << 16));
		info.push_back(p_species);
		seed.push_back((int64_t)p_seed);
		age.push_back(p_age);
	}
	int64_t size() const { return (int64_t)seed.size(); }
};

struct Ctx {
	const WfTables *tables = nullptr;
	View view;
	Corridor roads;
	Clearance clear;
	Points out;
	bool bb = false;
	bool wood_on = false;
	float quality = 1.0f;
	int64_t forest_seed = 0;
	std::unordered_map<uint64_t, int32_t> wood;
	std::vector<uint64_t> wood_order;
};

uint64_t wood_key(int64_t p_cx, int64_t p_cz) {
	return ((uint64_t)(uint32_t)(int32_t)p_cx << 32) | (uint64_t)(uint32_t)(int32_t)p_cz;
}

// One type's grid over [x0, x1) x [z0, z1): the stand rules for its style, membership from the map.
void scatter_type(Ctx &c, const Type &t, double p_x0, double p_z0, double p_x1, double p_z1) {
	const bool grid = t.style == STYLE_GRID;
	const bool natural = t.style == STYLE_NATURAL;
	const double pitch = t.pitch;
	const double road_m = c.roads.roads != nullptr ? c.roads.roads->margin() : 0.0;
	const int64_t gz0 = (int64_t)std::ceil(p_z0 / pitch - 0.5);
	const int64_t gz1 = (int64_t)std::ceil(p_z1 / pitch - 0.5) - 1;
	const int64_t gx0 = (int64_t)std::ceil(p_x0 / pitch - 0.5);
	const int64_t gx1 = (int64_t)std::ceil(p_x1 / pitch - 0.5) - 1;
	for (int64_t gz = gz0; gz <= gz1; gz++) {
		const double z = ((double)gz + 0.5) * pitch;
		for (int64_t gx = gx0; gx <= gx1; gx++) {
			const double x = ((double)gx + 0.5) * pitch;
			// MEMBERSHIP: the texel under the unjittered centre names this type, so a texel's edge is where it ends.
			const int32_t tex = c.view.texel(x, z);
			if (tex < 0 || (tex & 0xFF) != t.id) {
				continue;
			}
			const uint64_t sd = seed4(D_CELL, gx, gz, t.id, c.forest_seed);
			double px = x;
			double pz = z;
			if (!grid) {
				px += ((double)u01(sd, S_JIT_X) - 0.5) * pitch * 0.9;
				pz += ((double)u01(sd, S_JIT_Z) - 0.5) * pitch * 0.9;
			}
			if (natural && c.wood_on) {
				const uint64_t wk = wood_key(cell_of(px, WOOD_CELL), cell_of(pz, WOOD_CELL));
				if (c.wood.find(wk) == c.wood.end()) {
					c.wood_order.push_back(wk);
				}
				c.wood[wk] = t.id;
			}
			if (c.clear.hit(px, pz) || c.roads.blocked(px, pz, road_m)) {
				continue;
			}
			if (natural && value_noise(px, pz, CLEARING_SCALE, c.forest_seed, N_CLEARING) < CLEARING_FLOOR) {
				continue;
			}
			// DENSITY (G): a share of the grid kept by a draw of its own, so a thinner stand is a subset of a fuller one.
			const uint32_t g = ((uint32_t)tex >> 8) & 0xFF;
			if (g < 255 && (uint64_t)bits24(sd, S_DENSITY) * 255u >= ((uint64_t)g << 24)) {
				continue;
			}
			if (natural && c.quality < 1.0f && u01(sd, S_QUALITY) > c.quality) {
				continue;
			}
			double m = 1.0;
			if (natural && t.clump > 0.01) {
				const double g2 = clamp01((value_noise(px, pz, GROVE_SCALE, c.forest_seed, N_GROVE) - 0.30) / 0.45);
				m = lerp(1.0, g2 * 2.2, t.clump) / std::max(lerp(1.0, 1.1, t.clump), 0.01);
			}
			uint8_t role = (natural && (double)u01(sd, S_DEAD) < t.dead_frac) ? R_DEAD : R_TREE;
			if (natural && t.wall_m > 0.5 && role == R_TREE && c.roads.edge_dist(px, pz) < t.wall_m) {
				role = R_WALL;
			} else if (!grid && m < 0.999 && (double)u01(sd, S_CLUMP) > m) {
				continue;
			}
			const float age = (float)std::clamp((double)(((uint32_t)tex >> 16) & 0xFF) - 128.0, -127.0, 127.0) / 127.0f;
			if (c.bb) {
				if (role != R_DEAD) {
					c.out.add(px, pz, t.id, sd, R_BB, role, age, -1, false);
				}
				continue;
			}
			c.out.add(px, pz, t.id, sd, role, role, age, -1, false);
			if (natural && (double)u01(sd, S_UNDER) < t.understory) {
				const double bx = px + ((double)u01(sd, S_UNDER_X) - 0.5) * pitch * 0.6;
				const double bz = pz + ((double)u01(sd, S_UNDER_Z) - 0.5) * pitch * 0.6;
				const int32_t bt = c.view.texel(bx, bz);
				if (bt >= 0 && (bt & 0xFF) == t.id && !c.roads.blocked(bx, bz, road_m) && !c.clear.hit(bx, bz)) {
					c.out.add(bx, bz, t.id, sd ^ UNDER_TAG, R_UNDER, R_UNDER, 0.0f, -1, false);
				}
			}
		}
	}
}

template <typename T, typename P>
P packed(const std::vector<T> &p_v) {
	P out;
	out.resize((int64_t)p_v.size());
	if (!p_v.empty()) {
		std::copy(p_v.begin(), p_v.end(), out.ptrw());
	}
	return out;
}

Dictionary result(const Points &p_out, int64_t p_items, const PackedInt32Array &p_wood, const String &p_error) {
	Dictionary r;
	r["n"] = p_out.size();
	r["pos"] = packed<float, PackedFloat32Array>(p_out.pos);
	r["info"] = packed<int32_t, PackedInt32Array>(p_out.info);
	r["seed"] = packed<int64_t, PackedInt64Array>(p_out.seed);
	r["age"] = packed<float, PackedFloat32Array>(p_out.age);
	r["items_n"] = p_items;
	r["wood"] = p_wood;
	r["error"] = p_error;
	return r;
}

} // namespace

Dictionary wf::scatter_cell(const Dictionary &p_job) {
	const Points none;
	const Ref<WfTables> tables = p_job.get("tables", Variant());
	if (tables.is_null()) {
		return result(none, 0, PackedInt32Array(), "no tables");
	}
	if (!tables->error().is_empty()) {
		return result(none, 0, PackedInt32Array(), String("the tables: ") + tables->error());
	}
	const double region_m = p_job.get("region_m", 0.0);
	if (!(region_m > 0.0)) {
		return result(none, 0, PackedInt32Array(), "no region size");
	}
	Ctx c;
	c.tables = tables.ptr();
	c.view.read(p_job.get("view", Dictionary()), region_m);
	if (!c.view.error.is_empty()) {
		return result(none, 0, PackedInt32Array(), c.view.error);
	}
	const Rect2 rect = p_job.get("rect", Rect2());
	const double x0 = rect.position.x;
	const double z0 = rect.position.y;
	const double x1 = x0 + rect.size.x;
	const double z1 = z0 + rect.size.y;
	const Ref<WfRoads> roads = p_job.get("roads", Variant());
	c.roads.init(roads.ptr(), x0, z0, x1, z1);
	c.clear.read(p_job.get("clear", PackedFloat32Array()));
	const Dictionary params = p_job.get("params", Dictionary());
	c.bb = p_job.get("bb", false);
	c.wood_on = params.get("wood", false);
	c.quality = (float)(double)params.get("quality", 1.0);
	c.forest_seed = params.get("seed", 0);
	const double item_margin = params.get("item_margin", 0.0);

	// Block by block (ForestMaps.BLOCK_M), each type only where the summary has it.
	const Dictionary blocks = p_job.get("blocks", Dictionary());
	const int64_t b0x = cell_of(x0, BLOCK_M);
	const int64_t b0z = cell_of(z0, BLOCK_M);
	const int64_t b1x = cell_of(x1 - 0.001, BLOCK_M);
	const int64_t b1z = cell_of(z1 - 0.001, BLOCK_M);
	for (int64_t bz = b0z; bz <= b1z; bz++) {
		for (int64_t bx = b0x; bx <= b1x; bx++) {
			const Variant v = blocks.get(Vector2i((int32_t)bx, (int32_t)bz), Variant());
			if (v.get_type() != Variant::PACKED_INT32_ARRAY) {
				continue;
			}
			const PackedInt32Array ids = v;
			const double bx0 = std::max((double)bx * BLOCK_M, x0);
			const double bz0 = std::max((double)bz * BLOCK_M, z0);
			const double bx1 = std::min((double)(bx + 1) * BLOCK_M, x1);
			const double bz1 = std::min((double)(bz + 1) * BLOCK_M, z1);
			for (int64_t k = 0; k < ids.size(); k++) {
				const Type *t = c.tables->type(ids[k]);
				if (t != nullptr) {
					scatter_type(c, *t, bx0, bz0, bx1, bz1);
				}
			}
		}
	}

	// The single trees and rows planted in this cell: roads win, by the item's own margin.
	const PackedFloat32Array ipos = p_job.get("item_pos", PackedFloat32Array());
	const PackedInt64Array iseed = p_job.get("item_seed", PackedInt64Array());
	const PackedInt32Array itype = p_job.get("item_type", PackedInt32Array());
	const PackedFloat32Array iage = p_job.get("item_age", PackedFloat32Array());
	const PackedStringArray isp = p_job.get("item_species", PackedStringArray());
	const int64_t ni = iseed.size();
	if (ipos.size() != ni * 2 || itype.size() != ni || iage.size() != ni || isp.size() != ni) {
		return result(none, 0, PackedInt32Array(), "the items' arrays differ in length");
	}
	int64_t items_n = 0;
	for (int64_t i = 0; i < ni; i++) {
		const double x = ipos[2 * i];
		const double z = ipos[2 * i + 1];
		if (c.roads.blocked(x, z, item_margin)) {
			continue;
		}
		const int32_t sp = isp[i].is_empty() ? -1 : c.tables->find(isp[i]);
		c.out.add(x, z, itype[i], (uint64_t)iseed[i], c.bb ? R_BB : R_TREE, R_TREE, iage[i], sp, true);
		items_n++;
	}

	PackedInt32Array wood;
	for (const uint64_t k : c.wood_order) {
		wood.push_back((int32_t)(uint32_t)(k >> 32));
		wood.push_back((int32_t)(uint32_t)(k & 0xFFFFFFFFull));
		wood.push_back(c.wood[k]);
	}
	return result(c.out, items_n, wood, String());
}
