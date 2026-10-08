// Copyright (c) 2026 Digitzone
// SPDX-License-Identifier: MIT
#ifndef WF_CORE_H
#define WF_CORE_H

#include "arena/wf_arena.h"
#include "wf_roads.h"
#include "wf_tables.h"

#include <godot_cpp/classes/ref.hpp>
#include <godot_cpp/classes/ref_counted.hpp>
#include <godot_cpp/variant/color.hpp>
#include <godot_cpp/variant/dictionary.hpp>
#include <godot_cpp/variant/packed_byte_array.hpp>
#include <godot_cpp/variant/packed_float32_array.hpp>
#include <godot_cpp/variant/packed_float64_array.hpp>
#include <godot_cpp/variant/packed_int32_array.hpp>
#include <godot_cpp/variant/string.hpp>
#include <godot_cpp/variant/transform3d.hpp>
#include <godot_cpp/variant/vector2.hpp>
#include <godot_cpp/variant/vector2i.hpp>

namespace godot {

// THE FOREST'S NATIVE CORE: stateless (every method const, nothing written after construction), so
// one instance serves every worker at once. The addon's GDScript reaches it only through ClassDB by name (an editor that
// was open when the library was first built does not know the class until it restarts, and a script naming it would not
// parse there), one call per job: the boundary costs a crossing, so a call carries a whole cell.
class WfCore : public RefCounted {
	GDCLASS(WfCore, RefCounted)

protected:
	static void _bind_methods();

public:
	// The library's name and kernel generation.
	String version() const;
	// The tables a job reads (WfTables.build's input); errors are the tables' own (error()).
	Ref<WfTables> make_tables(const Dictionary &p_d) const;
	// The road corridor a job reads (WfRoads.build's input).
	Ref<WfRoads> make_roads(const PackedFloat64Array &p_segs, double p_margin) const;
	// A forest map's block summary (maps/wf_map_summary.h).
	Dictionary summarise_map(const PackedByteArray &p_data, int64_t p_w, double p_ox, double p_oz, double p_tm,
			const PackedInt32Array &p_ids, const Vector2i &p_b0, const Vector2i &p_b1) const;
	// One ring cell's scatter (scatter/wf_scatter.h).
	Dictionary scatter_cell(const Dictionary &p_job) const;
	// The clearing noise at p (tests and tools: which points stand at a glade's edge).
	double noise_at(const Vector2 &p_p, int64_t p_seed) const;
	// One ring cell's place (place/wf_place.h).
	Dictionary place_cell(const Dictionary &p_job) const;
	// One instance as the place writes it (tests: the MultiMesh buffer's layout).
	PackedFloat32Array pack_instance(const Transform3D &p_xf, const Color &p_c) const;
	// The far forest's kernels (far/wf_far.h).
	Dictionary far_summarise(const PackedByteArray &p_data, int64_t p_w, int64_t p_out_w, const PackedInt32Array &p_ids) const;
	PackedFloat32Array far_sample_ground(const PackedByteArray &p_data, int64_t p_w, int64_t p_h, int64_t p_s,
			double p_step) const;
	Dictionary far_build_cell(const Dictionary &p_p) const;
	// An instance arena for ForestIndirect (arena/wf_arena.h): `stride` floats an instance, growing
	// (`fixed_cap` 0) or fixed at `fixed_cap` instances; null for a stride or capacity out of range.
	Ref<WfArena> make_arena(int64_t p_stride, int64_t p_fixed_cap) const;
	// The block walk ForestIndirect.plan_block hands a caller: [cx, cy, cz, radius + reach, rel, n] every
	// BLOCK_SPLIT instances of `buf`; empty when `buf` holds fewer than n * stride floats.
	PackedFloat32Array plan_walk(const PackedFloat32Array &p_buf, int64_t p_n, int64_t p_stride, double p_reach) const;
	// A trunk cell's crowns for one species (the spawner's crown registry): from its raw records (x, z,
	// ground, scale) and the species' crown height and radius, [x, z, ground + bottom * height * scale, ground + height *
	// scale, radius * scale] each, the GDScript's arithmetic in double; empty when the species has no crown (height <= 0).
	PackedFloat32Array crowns(const PackedFloat32Array &p_raw, double p_height, double p_radius, double p_bottom) const;
};

} // namespace godot

#endif // WF_CORE_H
