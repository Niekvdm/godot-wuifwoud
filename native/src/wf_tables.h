// Copyright (c) 2026 Digitzone
// SPDX-License-Identifier: MIT
#ifndef WF_TABLES_H
#define WF_TABLES_H

#include <godot_cpp/classes/ref_counted.hpp>
#include <godot_cpp/variant/dictionary.hpp>
#include <godot_cpp/variant/packed_int32_array.hpp>
#include <godot_cpp/variant/packed_string_array.hpp>
#include <godot_cpp/variant/string.hpp>

#include <cstdint>
#include <string>
#include <unordered_map>
#include <vector>

namespace wf {

enum Style : uint8_t { STYLE_NATURAL = 0, STYLE_BUSHES = 1, STYLE_GRID = 2, STYLE_MIX = 3 };

// A species pool: indices into the tables' species with their running weights (a pick takes the first running weight
// at or past u * total).
struct Pool {
	std::vector<int32_t> sp;
	std::vector<double> run;
	double total = 0.0;
	bool empty() const { return sp.empty(); }
};

// One forest type as the kernels read it.
struct Type {
	int32_t id = 0;
	uint8_t style = STYLE_NATURAL;
	double pitch = 7.0;
	double clump = 0.0;
	double understory = 0.0;
	double wall_m = 0.0; // how far from a road a natural type's edge stands as a wall; 0: no wall
	double dead_frac = 0.0;
	double tree_share = 0.6;
	Pool bush, pool, tree, tree_young, tree_mature;
	Pool bands[3], young[3], mature[3], dead[3];
};

} // namespace wf

namespace godot {

// THE FOREST'S TABLES: the flora profile's types with their pools as species indices, and every
// species' catalog scalars. Made once on the main thread (WfCore.make_tables) and never changed after: a job holds the
// tables it was given, so tables made for a new profile never change a job in flight.
class WfTables : public RefCounted {
	GDCLASS(WfTables, RefCounted)

	std::vector<wf::Type> types_;
	int16_t by_id_[256];
	std::vector<String> names_;
	std::vector<uint8_t> bush_;
	std::vector<float> trunk_;
	std::unordered_map<std::string, int32_t> index_;
	String error_;

	void clear();

protected:
	static void _bind_methods();

public:
	WfTables();

	// From {"species": PackedStringArray, "bush": PackedByteArray, "trunk": PackedFloat32Array, "types": [{"id", "style"
	// (0 natural, 1 bushes, 2 grid, 3 mix), "pitch", "clump", "understory", "wall_m", "dead_frac", "tree_share",
	// "pools": {name: [PackedInt32Array, PackedFloat32Array]}}]}; pool names: bush, pool, tree, tree_young, tree_mature,
	// band_0..2, young_0..2, mature_0..2, dead_0..2 (coast, mid, high). False, with error(), on a malformed input: the
	// tables are then empty.
	bool build(const Dictionary &p_d);

	const wf::Type *type(int64_t p_id) const;
	const String &name_of(int32_t p_i) const { return names_[(size_t)p_i]; }
	bool bush(int32_t p_i) const { return bush_[(size_t)p_i] != 0; }
	float trunk(int32_t p_i) const { return trunk_[(size_t)p_i]; }
	int32_t count() const { return (int32_t)names_.size(); }
	int32_t find(const String &p_name) const;

	// Bound: tests and tools.
	String error() const { return error_; }
	PackedInt32Array type_ids() const;
	PackedStringArray species_names() const;
	int64_t species_index(const String &p_name) const { return find(p_name); }
	bool is_bush(int64_t p_i) const;
	double trunk_radius(int64_t p_i) const;
};

} // namespace godot

#endif // WF_TABLES_H
