// Copyright (c) 2026 Digitzone
// SPDX-License-Identifier: MIT
#include "wf_tables.h"

#include <godot_cpp/core/class_db.hpp>
#include <godot_cpp/variant/array.hpp>
#include <godot_cpp/variant/char_string.hpp>
#include <godot_cpp/variant/packed_byte_array.hpp>
#include <godot_cpp/variant/packed_float32_array.hpp>

using namespace godot;

namespace {

std::string key_of(const String &p_s) {
	const CharString u = p_s.utf8();
	return std::string(u.get_data(), (size_t)u.length());
}

// A pool from [indices, weights]. True for a pool the type does not have (nil); false when the two differ in length or
// an index is not a species.
bool read_pool(const Variant &p_v, int32_t p_species, wf::Pool &r_out) {
	r_out = wf::Pool();
	if (p_v.get_type() == Variant::NIL) {
		return true;
	}
	if (p_v.get_type() != Variant::ARRAY) {
		return false;
	}
	const Array a = p_v;
	if (a.size() != 2) {
		return false;
	}
	const PackedInt32Array idx = a[0];
	const PackedFloat32Array w = a[1];
	if (idx.size() != w.size()) {
		return false;
	}
	double run = 0.0;
	for (int64_t i = 0; i < idx.size(); i++) {
		const int32_t s = idx[i];
		if (s < 0 || s >= p_species) {
			return false;
		}
		run += (double)w[i];
		r_out.sp.push_back(s);
		r_out.run.push_back(run);
	}
	r_out.total = run;
	return true;
}

String band_key(const char *p_prefix, int p_band) {
	return String(p_prefix) + String::num_int64(p_band);
}

} // namespace

WfTables::WfTables() {
	for (int i = 0; i < 256; i++) {
		by_id_[i] = -1;
	}
}

void WfTables::_bind_methods() {
	ClassDB::bind_method(D_METHOD("error"), &WfTables::error);
	ClassDB::bind_method(D_METHOD("type_ids"), &WfTables::type_ids);
	ClassDB::bind_method(D_METHOD("species_names"), &WfTables::species_names);
	ClassDB::bind_method(D_METHOD("species_index", "name"), &WfTables::species_index);
	ClassDB::bind_method(D_METHOD("is_bush", "index"), &WfTables::is_bush);
	ClassDB::bind_method(D_METHOD("trunk_radius", "index"), &WfTables::trunk_radius);
}

void WfTables::clear() {
	types_.clear();
	names_.clear();
	bush_.clear();
	trunk_.clear();
	index_.clear();
	for (int i = 0; i < 256; i++) {
		by_id_[i] = -1;
	}
}

bool WfTables::build(const Dictionary &p_d) {
	clear();
	error_ = String();
	const PackedStringArray names = p_d.get("species", PackedStringArray());
	const PackedByteArray bush = p_d.get("bush", PackedByteArray());
	const PackedFloat32Array trunk = p_d.get("trunk", PackedFloat32Array());
	if (bush.size() != names.size() || trunk.size() != names.size()) {
		error_ = "the species, their bush flags and their trunk radii differ in length";
		return false;
	}
	const int32_t n = (int32_t)names.size();
	for (int32_t i = 0; i < n; i++) {
		names_.push_back(names[i]);
		bush_.push_back(bush[i] != 0 ? 1 : 0);
		trunk_.push_back(trunk[i]);
		index_[key_of(names[i])] = i;
	}
	const Array types = p_d.get("types", Array());
	for (int64_t k = 0; k < types.size(); k++) {
		const Dictionary td = types[k];
		wf::Type t;
		t.id = (int32_t)(int64_t)td.get("id", 0);
		const int64_t style = td.get("style", -1);
		t.pitch = td.get("pitch", 0.0);
		t.clump = td.get("clump", 0.0);
		t.understory = td.get("understory", 0.0);
		t.wall_m = td.get("wall_m", 0.0);
		t.dead_frac = td.get("dead_frac", 0.0);
		t.tree_share = td.get("tree_share", 0.6);
		String why;
		if (t.id < 1 || t.id > 255) {
			why = "an id outside 1-255";
		} else if (by_id_[t.id] >= 0) {
			why = "an id used twice";
		} else if (style < 0 || style > 3) {
			why = "a style that is not 0-3";
		} else if (!(t.pitch > 0.0)) {
			why = "a pitch that is not above 0";
		}
		t.style = (uint8_t)style;
		const Dictionary pools = td.get("pools", Dictionary());
		bool ok = why.is_empty() && read_pool(pools.get("bush", Variant()), n, t.bush) &&
				read_pool(pools.get("pool", Variant()), n, t.pool) && read_pool(pools.get("tree", Variant()), n, t.tree) &&
				read_pool(pools.get("tree_young", Variant()), n, t.tree_young) &&
				read_pool(pools.get("tree_mature", Variant()), n, t.tree_mature);
		for (int b = 0; b < 3 && ok; b++) {
			ok = read_pool(pools.get(band_key("band_", b), Variant()), n, t.bands[b]) &&
					read_pool(pools.get(band_key("young_", b), Variant()), n, t.young[b]) &&
					read_pool(pools.get(band_key("mature_", b), Variant()), n, t.mature[b]) &&
					read_pool(pools.get(band_key("dead_", b), Variant()), n, t.dead[b]);
		}
		if (!ok) {
			if (why.is_empty()) {
				why = "a pool whose species and weights differ in length or name no species";
			}
			clear();
			error_ = String("type ") + String::num_int64(t.id) + ": " + why;
			return false;
		}
		by_id_[t.id] = (int16_t)types_.size();
		types_.push_back(t);
	}
	return true;
}

const wf::Type *WfTables::type(int64_t p_id) const {
	if (p_id < 0 || p_id > 255) {
		return nullptr;
	}
	const int16_t i = by_id_[p_id];
	return i < 0 ? nullptr : &types_[(size_t)i];
}

int32_t WfTables::find(const String &p_name) const {
	const auto it = index_.find(key_of(p_name));
	return it == index_.end() ? -1 : it->second;
}

PackedInt32Array WfTables::type_ids() const {
	PackedInt32Array out;
	for (const wf::Type &t : types_) {
		out.push_back(t.id);
	}
	return out;
}

PackedStringArray WfTables::species_names() const {
	PackedStringArray out;
	for (const String &s : names_) {
		out.push_back(s);
	}
	return out;
}

bool WfTables::is_bush(int64_t p_i) const {
	return p_i >= 0 && p_i < (int64_t)bush_.size() && bush_[(size_t)p_i] != 0;
}

double WfTables::trunk_radius(int64_t p_i) const {
	return p_i >= 0 && p_i < (int64_t)trunk_.size() ? (double)trunk_[(size_t)p_i] : 0.0;
}
