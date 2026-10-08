# Copyright (c) 2026 Digitzone
# SPDX-License-Identifier: MIT
@tool
extends RefCounted
## What uses each species in a scene's forest: the lanes of its flora profile's types (each type's pools as ForestTypes
## resolved them), the import rules of its mapping that pin one, and its single trees and rows that pin one.


## The lanes of a resolved type (ForestTypes.get_type) by label, each its pool ([[id, weight], …] or [id, …]): a
## natural type's bands and its dead by band, a grid's trees, a mix's trees, and every type's bushes.
static func lanes_of(t: Dictionary) -> Dictionary:
	var out := {}
	match String(t.get("style", "")):
		"natural":
			for b in (t.get("bands", {}) as Dictionary):
				out[String(b)] = t["bands"][b]
			for b in (t.get("dead", {}) as Dictionary):
				out["dead (%s)" % b] = t["dead"][b]
		"grid":
			out["grid"] = t.get("pool", [])
		"mix":
			out["trees"] = t.get("tree", [])
	out["bushes"] = t.get("bush", [])
	return out


## {species id: PackedStringArray of what uses it}: "Wood (coast, mid)" (a type and its lanes, types by id),
## "import rule 2", "pinned by 3 single trees or rows". `types_by_id`: ForestTypes.by_id; `items`: ForestTrees.items;
## `rules`: the mapping's rules.
static func of(types_by_id: Dictionary, items: Dictionary, rules: Array) -> Dictionary:
	var per := {}          # id -> {type name: [lane, …]}, in type id order
	var ids := types_by_id.keys()
	ids.sort()
	for tid in ids:
		var t: Dictionary = types_by_id[tid]
		var nm := String(t.get("name", "type %d" % int(tid)))
		var lanes := lanes_of(t)
		for lane in lanes:
			var pool = lanes[lane]
			if typeof(pool) != TYPE_ARRAY:
				continue
			for e in pool:
				var sid := str(e[0]) if typeof(e) == TYPE_ARRAY else str(e)
				var by_type: Dictionary = per.get(sid, {})
				var ls: Array = by_type.get(nm, [])
				if not ls.has(lane):
					ls.append(lane)
				by_type[nm] = ls
				per[sid] = by_type
	var out := {}
	for sid in per:
		var acc := PackedStringArray()
		for nm in per[sid]:
			acc.append("%s (%s)" % [nm, ", ".join(PackedStringArray(per[sid][nm]))])
		out[sid] = acc
	for i in rules.size():
		var sp := str((rules[i] as Dictionary).get("species", ""))
		if sp != "":
			var acc2: PackedStringArray = out.get(sp, PackedStringArray())
			acc2.append("import rule %d" % (i + 1))
			out[sp] = acc2
	var pins := {}
	for k in items:
		var sp2 := str((items[k] as Dictionary).get("species", ""))
		if sp2 != "":
			pins[sp2] = int(pins.get(sp2, 0)) + 1
	for sp2 in pins:
		var acc3: PackedStringArray = out.get(sp2, PackedStringArray())
		acc3.append("pinned by %d single tree%s or rows" % [pins[sp2], "" if int(pins[sp2]) == 1 else "s"])
		out[sp2] = acc3
	return out
