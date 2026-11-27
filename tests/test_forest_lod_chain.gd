# Copyright (c) 2026 Digitzone
# SPDX-License-Identifier: MIT
extends RefCounted
## An authored LOD chain whose level is not simpler than LOD0 on a surface: that level is left out of the surface (the
## engine takes an index LOD only shorter than the surface's own, and dropped it with an error, its vertices left in the
## buffer); a level equal to LOD0 there (a bark kept whole) likewise; a surface that does simplify keeps every level.
##
## Run with a unit-suite runner: static run() returns {name, passed, failed, details}.

const VA := preload("res://addons/wuifwoud/forest_assets.gd")
const TreeFix := preload("res://addons/wuifwoud/tests/fixtures/tree_fixture.gd")
const ROOT := "user://wf_lod_chain"


static func _chk(r: Dictionary, n: String, ok: bool) -> void:
	if ok:
		r.passed += 1
	else:
		r.failed += 1
		r.details.append("✗ " + n)


static func _verts(m: ArrayMesh) -> Array:
	var out := []
	for si in m.get_surface_count():
		out.append((m.surface_get_arrays(si)[Mesh.ARRAY_VERTEX] as PackedVector3Array).size())
	return out


static func run() -> Dictionary:
	var r := {"name": "forest_lod_chain", "passed": 0, "failed": 0, "details": []}
	TreeFix.rm_tree(ROOT)
	var lo := TreeFix.tree_mesh(3, "Bark", "Leaves")
	var hi := TreeFix.tree_mesh(8, "Bark", "Leaves")
	# Simplifying: LOD0 the 8-card tree, LOD1 the 3-card one. Not: LOD1 bigger than LOD0.
	TreeFix.scene(ROOT + "/m/good.tscn", [hi, lo], ["Tree_LOD0", "Tree_LOD1"])
	TreeFix.scene(ROOT + "/m/bad.tscn", [lo, hi], ["Tree_LOD0", "Tree_LOD1"])
	var good := VA.prepare_species_of(TreeFix.species("W_Good", ROOT + "/m/good.tscn"))
	var bad := VA.prepare_species_of(TreeFix.species("W_Bad", ROOT + "/m/bad.tscn"))
	var vlo := _verts(lo)
	var vhi := _verts(hi)
	var vgood := _verts(good["combined"])
	var vbad := _verts(bad["combined"])
	# Surface 0 is the bark, the same in both levels (equal is not simpler either); surface 1 the leaves, 8 cards to 3.
	_chk(r, "a simplifying surface keeps both levels (leaves: %d = %d + %d)" % [vgood[1], vhi[1], vlo[1]],
		vgood.size() == vhi.size() and vgood[1] == vhi[1] + vlo[1])
	_chk(r, "a level equal to LOD0 on a surface is left out of it (bark: %d = %d)" % [vgood[0], vhi[0]], vgood[0] == vhi[0])
	_chk(r, "a level bigger than LOD0 is left out of the surface, vertices and all (%s = %s)" % [vbad, vlo],
		vbad.size() == vlo.size() and vbad[0] == vlo[0] and vbad[1] == vlo[1])
	TreeFix.rm_tree(ROOT)
	return r
