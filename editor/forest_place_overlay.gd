# Copyright (c) 2026 Digitzone
# SPDX-License-Identifier: MIT
@tool
extends MeshInstance3D
## The Place tools' lines in the 3D view: each row draped on the terrain with its vertices as small squares, each
## single tree's clearance ring, in the colour of who owns it (imported, edited, hand-made), the
## selected and hovered items brighter. An internal child of the forest without an owner (never saved), in world space
## (top_level), drawn without depth test LIFT_M above the ground.

## Drawn this far above the ground (m).
const LIFT_M := 0.3
## A row is draped at this step (m).
const STEP_M := 2.0
## A vertex square's size (m).
const SQUARE_M := 0.6
## A clearance ring's segments.
const RING_SEGMENTS := 24
## An imported item's colour.
const IMPORTED := Color(0.45, 0.75, 1.0)
## An edited imported item's colour.
const EDITED := Color(1.0, 0.75, 0.3)
## A hand-made item's colour.
const HAND := Color(0.55, 0.9, 0.45)
## The selected item's colour.
const SELECTED := Color(1.0, 1.0, 1.0)
## The hovered item's colour.
const HOVERED := Color(1.0, 1.0, 0.6)

## How many times it drew (tests)
var draws := 0


func _init() -> void:
	name = "WuifwoudPlaceOverlay"
	top_level = true
	mesh = ImmediateMesh.new()
	var m := StandardMaterial3D.new()
	m.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	m.no_depth_test = true
	m.vertex_color_use_as_albedo = true
	m.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
	material_override = m
	cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF


## Draws `items` (ForestTrees.items): `height` (x, z) -> the ground's height there (0 where unknown).
func draw(items: Dictionary, selected: int, hover: int, height: Callable) -> void:
	draws += 1
	var im := mesh as ImmediateMesh
	im.clear_surfaces()
	if items.is_empty():
		return
	im.surface_begin(Mesh.PRIMITIVE_LINES)
	for id in items:
		var it: Dictionary = items[id]
		var c := _colour(it, int(id) == selected, int(id) == hover)
		if it["kind"] == "row":
			var pts: PackedVector2Array = it["points"]
			for i in range(1, pts.size()):
				_line(im, pts[i - 1], pts[i], c, height)
			for q in pts:
				_square(im, q, c, height)
		else:
			_ring(im, it["at"], maxf(float(it["clear_m"]), 0.5), c, height)
	im.surface_end()


static func _colour(it: Dictionary, sel: bool, hov: bool) -> Color:
	if sel:
		return SELECTED
	if hov:
		return HOVERED
	if not it.has("source"):
		return HAND
	return EDITED if bool(it.get("edited", false)) else IMPORTED


static func _at(p: Vector2, height: Callable) -> Vector3:
	return Vector3(p.x, float(height.call(p.x, p.y)) + LIFT_M, p.y)


static func _seg(im: ImmediateMesh, a: Vector3, b: Vector3, c: Color) -> void:
	im.surface_set_color(c)
	im.surface_add_vertex(a)
	im.surface_set_color(c)
	im.surface_add_vertex(b)


## A ground-hugging line from a to b: a sample every STEP_M.
static func _line(im: ImmediateMesh, a: Vector2, b: Vector2, c: Color, height: Callable) -> void:
	var n := maxi(1, ceili(a.distance_to(b) / STEP_M))
	var prev := _at(a, height)
	for i in range(1, n + 1):
		var q := _at(a.lerp(b, float(i) / float(n)), height)
		_seg(im, prev, q, c)
		prev = q


static func _square(im: ImmediateMesh, p: Vector2, c: Color, height: Callable) -> void:
	var h := SQUARE_M * 0.5
	var corners := [p + Vector2(-h, -h), p + Vector2(h, -h), p + Vector2(h, h), p + Vector2(-h, h)]
	for i in 4:
		_seg(im, _at(corners[i], height), _at(corners[(i + 1) % 4], height), c)


static func _ring(im: ImmediateMesh, p: Vector2, r: float, c: Color, height: Callable) -> void:
	var prev := _at(p + Vector2(r, 0.0), height)
	for i in range(1, RING_SEGMENTS + 1):
		var a := TAU * float(i) / float(RING_SEGMENTS)
		var q := _at(p + Vector2(cos(a), sin(a)) * r, height)
		_seg(im, prev, q, c)
		prev = q
