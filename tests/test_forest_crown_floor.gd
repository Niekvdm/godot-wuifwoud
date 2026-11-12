# Copyright (c) 2026 Digitzone
# SPDX-License-Identifier: MIT
extends RefCounted
## A leaf surface's own stem (ForestAssets.crown_floor_of): a toon palm is ONE surface, trunk and fronds; the shaders
## leave its trunk below crown_floor as bark (no spherify, no crown occlusion, no backlight), or the trunk takes a
## normal spherified outward from a crown above it, pointing down, and renders black lit from the wrong side. A palm
## (a thin stem, a wide crown on top) has a floor at the crown's start; a round crown, a broadleaf's narrowing cap and
## a short stub have none; a leaning stem is still a stem; a surface that is not foliage is not measured; a built
## species from before the field measures it when it loads.
##
## Run with a unit-suite runner: static run() returns {name, passed, failed, details}.

const Assets := preload("res://addons/wuifwoud/forest_assets.gd")


static func _box(st: SurfaceTool, c: Vector3, h: Vector3) -> void:
	var p := [Vector3(-1, -1, -1), Vector3(1, -1, -1), Vector3(1, 1, -1), Vector3(-1, 1, -1),
		Vector3(-1, -1, 1), Vector3(1, -1, 1), Vector3(1, 1, 1), Vector3(-1, 1, 1)]
	for q in [[0, 1, 2], [0, 2, 3], [4, 6, 5], [4, 7, 6], [0, 4, 5], [0, 5, 1], [3, 2, 6], [3, 6, 7], [0, 3, 7], [0, 7, 4],
			[1, 5, 6], [1, 6, 2]]:
		for i in q:
			st.add_vertex(c + (p[i] as Vector3) * h)


## One surface of boxes: [centre, half size] each.
static func _mesh(parts: Array) -> ArrayMesh:
	var st := SurfaceTool.new()
	st.begin(Mesh.PRIMITIVE_TRIANGLES)
	for b in parts:
		_box(st, b[0], b[1])
	return st.commit()


static func run() -> Dictionary:
	var passed := 0
	var failed := 0
	var details: Array = []
	var leaf := PackedInt32Array([0])
	# a palm: a 0.4 m stem 0..10 m, fronds 9 m wide 10..14 m
	var palm := _mesh([[Vector3(0, 5, 0), Vector3(0.2, 5, 0.2)], [Vector3(0, 12, 0), Vector3(4.5, 2, 4.5)]])
	var f := Assets.crown_floor_of(palm, leaf)
	if f > 8.0 and f <= 10.5:
		passed += 1
	else:
		failed += 1
		details.append("a palm's floor %.2f, not at its crown's start (8..10.5)" % f)
	# a round crown (a broadleaf's leaf surface): widest in the middle, its cap narrowing: no stem
	var crown := _mesh([[Vector3(0, 1, 0), Vector3(1.5, 1, 1.5)], [Vector3(0, 4, 0), Vector3(4, 2, 4)],
		[Vector3(0, 7, 0), Vector3(1.5, 1, 1.5)]])
	if Assets.crown_floor_of(crown, leaf) == Assets.NO_STEM:
		passed += 1
	else:
		failed += 1
		details.append("a round crown has a stem at %.2f" % Assets.crown_floor_of(crown, leaf))
	# a leaning stem (each slice still thin) under its crown: a stem
	var lean := _mesh([[Vector3(0, 1.5, 0), Vector3(0.2, 1.5, 0.2)], [Vector3(0.6, 4.5, 0), Vector3(0.2, 1.5, 0.2)],
		[Vector3(1.2, 7.5, 0), Vector3(0.2, 1.5, 0.2)], [Vector3(1.5, 11, 0), Vector3(4, 2, 4)]])
	if Assets.crown_floor_of(lean, leaf) > 6.0:
		passed += 1
	else:
		failed += 1
		details.append("a leaning stem not found (%.2f)" % Assets.crown_floor_of(lean, leaf))
	# a stub under 15 % of the height: no stem
	var stub := _mesh([[Vector3(0, 0.5, 0), Vector3(0.2, 0.5, 0.2)], [Vector3(0, 6, 0), Vector3(4, 5, 4)]])
	if Assets.crown_floor_of(stub, leaf) == Assets.NO_STEM:
		passed += 1
	else:
		failed += 1
		details.append("a short stub is a stem (%.2f)" % Assets.crown_floor_of(stub, leaf))
	# no leaf surface: not measured
	if Assets.crown_floor_of(palm, PackedInt32Array()) == Assets.NO_STEM:
		passed += 1
	else:
		failed += 1
		details.append("a mesh with no leaf surface measured a stem")
	# a built species from before the field: NAN, measured when the species loads
	var b: Resource = load("res://addons/wuifwoud/species/forest_built_species.gd").new()
	if is_nan(float(b.get("crown_floor"))):
		passed += 1
	else:
		failed += 1
		details.append("a built species' crown_floor defaults to %s, not NAN (unmeasured)" % b.get("crown_floor"))
	return {"name": "forest_crown_floor", "passed": passed, "failed": failed, "details": details}
