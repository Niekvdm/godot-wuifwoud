// Copyright (c) 2026 Digitzone
// SPDX-License-Identifier: MIT
#ifndef WF_SCATTER_H
#define WF_SCATTER_H

#include <godot_cpp/variant/dictionary.hpp>

namespace wf {

// One ring cell's scatter: the job ForestSpawner._scatter_job made in, the cell's
// points out. The job: "tables" (WfTables), "roads" (WfRoads or null), "rect" (Rect2), "view" ({Vector2i: {"w", "data"}},
// ForestMaps.view), "blocks" ({Vector2i: PackedInt32Array}, ForestMaps.blocks_in), "region_m", "bb", "params" {"seed",
// "quality", "wood", "item_margin"}, and from the items (ForestSpawner._pack_items): "item_pos", "item_seed",
// "item_type", "item_age", "item_species", "clear". The points: {"n", "pos": PackedFloat32Array (x, z) a point,
// "info": PackedInt32Array (type | role << 8 | map role << 12 | item << 16, pinned species or -1) a point, "seed":
// PackedInt64Array, "age": PackedFloat32Array, "items_n", "wood": PackedInt32Array (cell x, cell z, type) a cell,
// "error": ""}. Inconsistent inputs: no points, and why.
godot::Dictionary scatter_cell(const godot::Dictionary &p_job);

} // namespace wf

#endif // WF_SCATTER_H
