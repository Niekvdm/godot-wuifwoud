# Copyright (c) 2026 Digitzone
# SPDX-License-Identifier: MIT
@tool
extends RefCounted
## The Forest workspace's texel rules, pure: one dab of a brush on the forest maps it covers.
## A texel is under the brush when its CENTRE is; its weight is strength · pressure · pow(the brush image's red at the
## texel, gamma) (a disc of weight 1 without an image). The bar's rotation and spin are not used. Every texel whose R,
## G or B a dab changes gets A = 255, the painted mark (a re-import keeps those texels); a texel the dab leaves as it
## was keeps its A.
##
## Revert gives each texel at weight 0.5 or more what the import mapping says there, unmarked (A = 0):
## the texels come through `revert_of`, asked once a region for the rectangle the dab covers.
##
## The maps come through `image_of` (location -> the region's editable RGBA8 Image, or null where the terrain has no
## region), so this reads no files and knows no editor.

enum Op {PAINT, ERASE, REPLACE, DENSITY_UP, DENSITY_DOWN, AGE_UP, AGE_DOWN, SMOOTH, REVERT}

## A dab at full weight moves density or age by this much: a quarter of the range.
const STEP := 64

## (Vector2i) -> Image or null.
var image_of := Callable()
## A region's side in metres.
var region_m := 0.0
## (Vector2i) before a region's first change in a stroke: the undo's "before".
var on_first_change := Callable()
## Vector2i -> Rect2i: what this stroke changed.
var touched := {}
## (Vector2i, Rect2i, w) -> PackedByteArray: the mapping's texels there (Revert)
var revert_of := Callable()
var _fresh := {}                  # Vector2i -> Rect2i: changed since the last take_fresh()


## A new stroke.
func begin() -> void:
	touched.clear()
	_fresh.clear()


## The rectangles changed since the last call (a regrow sends only those), forgotten here.
func take_fresh() -> Dictionary:
	var out := _fresh
	_fresh = {}
	return out


## One dab at `center` (world). brush: {size m, strength 0..1, pressure, image (Image or null), gamma}; op: {"op": Op,
## "type": the selected type id, "from": Replace's From type}.
func dab(center: Vector3, brush: Dictionary, op: Dictionary) -> void:
	var size := float(brush.get("size", 1.0))
	var radius := size * 0.5
	var strength := float(brush.get("strength", 1.0)) * clampf(float(brush.get("pressure", 1.0)), 0.0, 1.0)
	var shape := brush.get("image") as Image
	var gamma := float(brush.get("gamma", 1.0))
	if radius <= 0.0 or strength <= 0.0 or region_m <= 0.0 or not image_of.is_valid():
		return
	var l0 := Vector2i(floori((center.x - radius) / region_m), floori((center.z - radius) / region_m))
	var l1 := Vector2i(floori((center.x + radius) / region_m), floori((center.z + radius) / region_m))
	var samples: Array = []   # [loc, img, i, j, weight, r, g, b]
	for lz in range(l0.y, l1.y + 1):
		for lx in range(l0.x, l1.x + 1):
			var loc := Vector2i(lx, lz)
			var img = image_of.call(loc)
			if img != null:
				_gather(samples, loc, img, center, radius, size, strength, shape, gamma)
	var o := int(op.get("op", Op.PAINT))
	if o == Op.REVERT:
		_revert(samples)
		return
	var mean_g := 0.0
	var mean_b := 0.0
	if o == Op.SMOOTH:
		var sw := 0.0
		for s in samples:
			if int(s[5]) != 0:
				sw += float(s[4])
				mean_g += float(s[4]) * float(s[6])
				mean_b += float(s[4]) * float(s[7])
		if sw <= 0.0:
			return
		mean_g /= sw
		mean_b /= sw
	for s in samples:
		var rgb := _apply(o, op, float(s[4]), int(s[5]), int(s[6]), int(s[7]), mean_g, mean_b)
		if rgb[0] == int(s[5]) and rgb[1] == int(s[6]) and rgb[2] == int(s[7]):
			continue
		var loc: Vector2i = s[0]
		var px := Vector2i(int(s[2]), int(s[3]))
		if not touched.has(loc) and on_first_change.is_valid():
			on_first_change.call(loc)
		(s[1] as Image).set_pixelv(px, Color8(rgb[0], rgb[1], rgb[2], 255))
		_mark(loc, px)


## Revert: every texel at weight 0.5 or more takes the mapping's texel, A = 0, asked once a region for
## the rectangle those texels span. A texel already so is left alone.
func _revert(samples: Array) -> void:
	if not revert_of.is_valid():
		return
	var rects := {}
	for s in samples:
		if float(s[4]) < 0.5:
			continue
		var one := Rect2i(int(s[2]), int(s[3]), 1, 1)
		rects[s[0]] = (rects[s[0]] as Rect2i).merge(one) if rects.has(s[0]) else one
	var src := {}
	for loc in rects:
		var img: Image = image_of.call(loc)
		src[loc] = revert_of.call(loc, rects[loc], img.get_width())
	for s in samples:
		var loc: Vector2i = s[0]
		if float(s[4]) < 0.5 or not src.has(loc):
			continue
		var rect: Rect2i = rects[loc]
		var bytes: PackedByteArray = src[loc]
		if bytes.size() != rect.size.x * rect.size.y * 4:
			continue
		var px := Vector2i(int(s[2]), int(s[3]))
		var k := ((px.y - rect.position.y) * rect.size.x + (px.x - rect.position.x)) * 4
		var img := s[1] as Image
		var c := img.get_pixelv(px)
		if c.r8 == bytes[k] and c.g8 == bytes[k + 1] and c.b8 == bytes[k + 2] and c.a8 == 0:
			continue
		if not touched.has(loc) and on_first_change.is_valid():
			on_first_change.call(loc)
		img.set_pixelv(px, Color8(bytes[k], bytes[k + 1], bytes[k + 2], 0))
		_mark(loc, px)


## A texel this stroke changed: the touched and fresh rectangles grow over it.
func _mark(loc: Vector2i, px: Vector2i) -> void:
	var one := Rect2i(px, Vector2i.ONE)
	touched[loc] = (touched[loc] as Rect2i).merge(one) if touched.has(loc) else one
	_fresh[loc] = (_fresh[loc] as Rect2i).merge(one) if _fresh.has(loc) else one


## The texels of one region's map under the brush, with their weights and current R, G, B.
func _gather(samples: Array, loc: Vector2i, img: Image, center: Vector3, radius: float, size: float, strength: float,
		shape: Image, gamma: float) -> void:
	var w := img.get_width()
	var tm := region_m / float(w)
	var ox := float(loc.x) * region_m
	var oz := float(loc.y) * region_m
	var i0 := maxi(0, ceili((center.x - radius - ox) / tm - 0.5))
	var i1 := mini(w - 1, floori((center.x + radius - ox) / tm - 0.5))
	var j0 := maxi(0, ceili((center.z - radius - oz) / tm - 0.5))
	var j1 := mini(w - 1, floori((center.z + radius - oz) / tm - 0.5))
	for j in range(j0, j1 + 1):
		var z := oz + (float(j) + 0.5) * tm
		for i in range(i0, i1 + 1):
			var x := ox + (float(i) + 0.5) * tm
			var a := _alpha(x - center.x, z - center.z, radius, size, shape, gamma)
			if a <= 0.0:
				continue
			var c := img.get_pixel(i, j)
			samples.append([loc, img, i, j, strength * a, c.r8, c.g8, c.b8])


## The brush at an offset from its centre: the image's red raised to gamma over the brush's square, or a disc of 1.
static func _alpha(dx: float, dz: float, radius: float, size: float, shape: Image, gamma: float) -> float:
	if shape == null:
		return 1.0 if dx * dx + dz * dz <= radius * radius else 0.0
	var u := dx / size + 0.5
	var v := dz / size + 0.5
	if u < 0.0 or u >= 1.0 or v < 0.0 or v >= 1.0:
		return 0.0
	var iw := shape.get_width()
	var ih := shape.get_height()
	var c := shape.get_pixel(clampi(floori(u * float(iw)), 0, iw - 1), clampi(floori(v * float(ih)), 0, ih - 1))
	return pow(c.r, gamma)


## A texel's new R, G, B under op `o` at weight `w`.
static func _apply(o: int, op: Dictionary, w: float, r: int, g: int, b: int, mg: float, mb: float) -> Array:
	match o:
		Op.PAINT:
			var t := int(op.get("type", 0))
			if w >= 0.5 and t != 0:
				return [t, g, b] if r != 0 else [t, 255, 128]
		Op.ERASE:
			if w >= 0.5:
				return [0, g, b]
		Op.REPLACE:
			var from := int(op.get("from", 0))
			var to := int(op.get("type", 0))
			if w >= 0.5 and r == from and from != 0 and to != 0 and from != to:
				return [to, g, b]
		Op.DENSITY_UP, Op.DENSITY_DOWN:
			if r != 0:
				var dg := roundi(w * STEP) * (1 if o == Op.DENSITY_UP else -1)
				return [r, clampi(g + dg, 0, 255), b]
		Op.AGE_UP, Op.AGE_DOWN:
			if r != 0:
				var db := roundi(w * STEP) * (1 if o == Op.AGE_UP else -1)
				return [r, g, clampi(b + db, 0, 255)]
		Op.SMOOTH:
			if r != 0:
				return [r, roundi(lerpf(float(g), mg, w)), roundi(lerpf(float(b), mb, w))]
	return [r, g, b]
