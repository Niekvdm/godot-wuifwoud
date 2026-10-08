// Copyright (c) 2026 Digitzone
// SPDX-License-Identifier: MIT
#include "wf_core.h"

#include "common/wf_rules.h"
#include "far/wf_far.h"
#include "maps/wf_map_summary.h"
#include "place/wf_place.h"
#include "scatter/wf_scatter.h"

#include <godot_cpp/core/class_db.hpp>

#include <algorithm>
#include <vector>

using namespace godot;

void WfCore::_bind_methods() {
	ClassDB::bind_method(D_METHOD("version"), &WfCore::version);
	ClassDB::bind_method(D_METHOD("make_tables", "d"), &WfCore::make_tables);
	ClassDB::bind_method(D_METHOD("make_roads", "segs", "margin"), &WfCore::make_roads);
	ClassDB::bind_method(D_METHOD("summarise_map", "data", "w", "ox", "oz", "tm", "ids", "b0", "b1"), &WfCore::summarise_map);
	ClassDB::bind_method(D_METHOD("scatter_cell", "job"), &WfCore::scatter_cell);
	ClassDB::bind_method(D_METHOD("noise_at", "p", "seed"), &WfCore::noise_at);
	ClassDB::bind_method(D_METHOD("place_cell", "job"), &WfCore::place_cell);
	ClassDB::bind_method(D_METHOD("pack_instance", "xf", "color"), &WfCore::pack_instance);
	ClassDB::bind_method(D_METHOD("far_summarise", "data", "w", "out_w", "ids"), &WfCore::far_summarise);
	ClassDB::bind_method(D_METHOD("far_sample_ground", "data", "w", "h", "s", "step"), &WfCore::far_sample_ground);
	ClassDB::bind_method(D_METHOD("far_build_cell", "p"), &WfCore::far_build_cell);
	ClassDB::bind_method(D_METHOD("make_arena", "stride", "fixed_cap"), &WfCore::make_arena);
	ClassDB::bind_method(D_METHOD("plan_walk", "buf", "n", "stride", "reach"), &WfCore::plan_walk);
	ClassDB::bind_method(D_METHOD("crowns", "raw", "height", "radius", "bottom"), &WfCore::crowns);
}

String WfCore::version() const {
	return String("wuifwoud_core 3");
}

Ref<WfTables> WfCore::make_tables(const Dictionary &p_d) const {
	Ref<WfTables> t;
	t.instantiate();
	t->build(p_d);
	return t;
}

Ref<WfRoads> WfCore::make_roads(const PackedFloat64Array &p_segs, double p_margin) const {
	Ref<WfRoads> r;
	r.instantiate();
	r->build(p_segs, p_margin);
	return r;
}

Dictionary WfCore::summarise_map(const PackedByteArray &p_data, int64_t p_w, double p_ox, double p_oz, double p_tm,
		const PackedInt32Array &p_ids, const Vector2i &p_b0, const Vector2i &p_b1) const {
	return wf::summarise_map(p_data, p_w, p_ox, p_oz, p_tm, p_ids, p_b0, p_b1);
}

Dictionary WfCore::scatter_cell(const Dictionary &p_job) const {
	return wf::scatter_cell(p_job);
}

double WfCore::noise_at(const Vector2 &p_p, int64_t p_seed) const {
	return wf::value_noise(p_p.x, p_p.y, wf::CLEARING_SCALE, p_seed, wf::N_CLEARING);
}

Dictionary WfCore::place_cell(const Dictionary &p_job) const {
	return wf::place_cell(p_job);
}

PackedFloat32Array WfCore::pack_instance(const Transform3D &p_xf, const Color &p_c) const {
	PackedFloat32Array out;
	out.resize(16);
	wf::put_instance(out.ptrw(), p_xf.basis, p_xf.origin.x, p_xf.origin.y, p_xf.origin.z, p_c.r, p_c.g, p_c.b, p_c.a);
	return out;
}

Dictionary WfCore::far_summarise(const PackedByteArray &p_data, int64_t p_w, int64_t p_out_w,
		const PackedInt32Array &p_ids) const {
	return wf::far_summarise(p_data, p_w, p_out_w, p_ids);
}

PackedFloat32Array WfCore::far_sample_ground(const PackedByteArray &p_data, int64_t p_w, int64_t p_h, int64_t p_s,
		double p_step) const {
	return wf::far_sample_ground(p_data, p_w, p_h, p_s, p_step);
}

Dictionary WfCore::far_build_cell(const Dictionary &p_p) const {
	return wf::far_build_cell(p_p);
}

Ref<WfArena> WfCore::make_arena(int64_t p_stride, int64_t p_fixed_cap) const {
	Ref<WfArena> a;
	a.instantiate();
	if (!a->setup(p_stride, p_fixed_cap)) {
		return Ref<WfArena>();
	}
	return a;
}

PackedFloat32Array WfCore::plan_walk(const PackedFloat32Array &p_buf, int64_t p_n, int64_t p_stride,
		double p_reach) const {
	PackedFloat32Array out;
	if (p_n <= 0 || p_stride < 12 || p_buf.size() < p_n * p_stride) {
		return out;
	}
	std::vector<float> walked;
	wf::walk_clusters(p_buf.ptr(), p_n, p_stride, p_reach, walked);
	out.resize((int64_t)walked.size());
	std::copy(walked.begin(), walked.end(), out.ptrw());
	return out;
}

PackedFloat32Array WfCore::crowns(const PackedFloat32Array &p_raw, double p_height, double p_radius,
		double p_bottom) const {
	PackedFloat32Array out;
	if (!(p_height > 0.0)) {
		return out;
	}
	const int64_t n = p_raw.size() / 4;
	out.resize(n * 5);
	const float *t = p_raw.ptr();
	float *w = out.ptrw();
	for (int64_t i = 0; i < n; i++) {
		const double ground = t[i * 4 + 2];
		const double scale = t[i * 4 + 3];
		w[i * 5 + 0] = t[i * 4 + 0];
		w[i * 5 + 1] = t[i * 4 + 1];
		w[i * 5 + 2] = (float)(ground + p_bottom * p_height * scale);
		w[i * 5 + 3] = (float)(ground + p_height * scale);
		w[i * 5 + 4] = (float)(p_radius * scale);
	}
	return out;
}
