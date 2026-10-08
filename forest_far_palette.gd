# Copyright (c) 2026 Digitzone
# SPDX-License-Identifier: MIT
@tool
extends RefCounted
## The far forest's colours and canopy heights, per forest type and band (coast, mid, high): a
## band's palette is the type's pool for it (the crown colours of its species that have an impostor bake, the heaviest
## MAX_COLOURS, their weights renormalised) and its canopy height the weighted mean of its species' heights. A band
## with no colour takes the mid band's (or the first that has one); a type's `far_color` overrides its palette; a type
## left with no colour is drawn FALLBACK, named in `warnings`. Built on the main thread (it reads textures and meshes);
## read-only after, so workers may read it.

## The bands a type's pools are named by.
const BANDS := ["coast", "mid", "high"]
## The colours a band's palette keeps at most (its heaviest species).
const MAX_COLOURS := 8
## The colour of a type none of whose species has a bake.
const FALLBACK := Color("#2f4a2a")
## The mean tree scale at age 0: the middle of 0.8-1.45 (the forest's tree scale).
const MEAN_SCALE := 1.125

## id -> {"name", "style", "pitch", "bands": [{"colours": PackedColorArray (linear), "weights": PackedFloat32Array
## (cumulative, the last 1), "mean": Color, "h": float (the species' mean height, m)} for coast, mid, high]}
var types := {}
## The types drawn FALLBACK, named once each.
var warnings: PackedStringArray = []


## `ftypes` a ForestTypes; `colour_of` species -> Color (linear) or null when it has no bake; `height_of` species ->
## metres (0 when unknown).
func build(ftypes, colour_of: Callable, height_of: Callable) -> void:
	types.clear()
	warnings.clear()
	var seen := {}
	for id in ftypes.ids():
		var t: Dictionary = ftypes.get_type(id)
		var bands := []
		for band in BANDS:
			bands.append(_band(pool_of(t, band), seen, colour_of, height_of))
		_fill_empty(bands)
		if t.has("far_color"):
			var fc: Color = (t["far_color"] as Color).srgb_to_linear()
			for b in bands:
				_one_colour(b, fc)
		elif (bands[1]["colours"] as PackedColorArray).is_empty():
			warnings.append("type %d ('%s') has no species with an impostor bake and no far_color: drawn %s" % [
				id, str(t["name"]), FALLBACK.to_html(false)])
			for b in bands:
				_one_colour(b, FALLBACK.srgb_to_linear())
		types[int(id)] = {"name": str(t["name"]), "style": str(t["style"]), "pitch": float(t["pitch"]), "bands": bands}


## A type's canopy height (m) in band 0-2 at `age` (-1..1): its species' mean height times the mean tree scale there.
func height(id: int, band: int, age: float) -> float:
	var t: Dictionary = types.get(id, {})
	if t.is_empty():
		return 0.0
	return float(t["bands"][band]["h"]) * mean_scale(str(t["style"]), age)


## id -> PackedFloat32Array [coast, mid, high]: the species' mean heights (unscaled), for the mesh builder.
func heights_table() -> Dictionary:
	var out := {}
	for id in types:
		var b: Array = types[id]["bands"]
		out[id] = PackedFloat32Array([b[0]["h"], b[1]["h"], b[2]["h"]])
	return out


## id -> style, for the mesh builder.
func styles() -> Dictionary:
	var out := {}
	for id in types:
		out[id] = types[id]["style"]
	return out


## The shader's palette: RGBAF, 9 × 768, row id × 3 + band; columns 0-7 a colour (linear RGB) and its cumulative
## weight (A; 0 past the last), column 8 the band's mean colour and the type's tree spacing (A, metres).
func texture_image() -> Image:
	var img := Image.create_empty(MAX_COLOURS + 1, 256 * 3, false, Image.FORMAT_RGBAF)
	for id in types:
		var t: Dictionary = types[id]
		for b in 3:
			var bd: Dictionary = t["bands"][b]
			var row := int(id) * 3 + b
			var cs: PackedColorArray = bd["colours"]
			var ws: PackedFloat32Array = bd["weights"]
			for k in cs.size():
				img.set_pixel(k, row, Color(cs[k].r, cs[k].g, cs[k].b, ws[k]))
			var m: Color = bd["mean"]
			img.set_pixel(MAX_COLOURS, row, Color(m.r, m.g, m.b, float(t["pitch"])))
	return img


## The pool a type draws from in a band, as [[species, weight], …]: natural the band's pool, bushes the bush pool, a grid
## its pool, a mix its tree pool and bush pool shared by tree_share.
static func pool_of(t: Dictionary, band: String) -> Array:
	match str(t.get("style", "")):
		"natural":
			return (t["bands"] as Dictionary).get(band, [])
		"bushes":
			return t.get("bush", [])
		"grid":
			return t.get("pool", [])
		"mix":
			var share := float(t.get("tree_share", 0.6))
			return _scaled(t.get("tree", []), share) + _scaled(t.get("bush", []), 1.0 - share)
	return []


## The mean tree scale at `age` (the forest's tree scale): MEAN_SCALE at age 0, sliding to 0.8 (young) or
## 1.3 (old growth) for a natural or mix type; MEAN_SCALE for the others.
static func mean_scale(style: String, age: float) -> float:
	if age == 0.0 or not (style in ["natural", "mix"]):
		return MEAN_SCALE
	var k := absf(clampf(age, -1.0, 1.0))
	var lo := lerpf(0.8, 0.6 if age < 0.0 else 1.1, k)
	var hi := lerpf(1.45, 1.0 if age < 0.0 else 1.5, k)
	return (lo + hi) * 0.5


## A species' mean crown colour (linear) from its impostor bake, the G-buffer albedo (premultiplied sRGB bytes); null
## when it has no bake. MAIN THREAD (it reads the texture).
static func crown_colour(mesh_name: String):
	# Read once per species: from its pack's build when built.json has it, else a GPU read-back
	# of the bake: ForestAssets keeps it with the species' other caches.
	if ForestAssets._crown_colour_cache.has(mesh_name):
		return ForestAssets._crown_colour_cache[mesh_name]
	var built: Array = ForestAssets.built_crown_colour(mesh_name)
	var c = built[0] if not built.is_empty() else _read_crown_colour(mesh_name)
	ForestAssets._crown_colour_cache[mesh_name] = c
	return c


static func _read_crown_colour(mesh_name: String):
	var ring: Dictionary = ForestAssets._impostor_ring(mesh_name)
	if ring.is_empty():
		return null
	var tex: Texture2D = ring.get("albedo")
	if tex == null:
		return null
	var src := tex.get_image()
	if src == null or src.is_empty():
		return null
	var img := src.duplicate() as Image
	if img.is_compressed() and img.decompress() != OK:
		return null
	img.convert(Image.FORMAT_RGBA8)
	return mean_colour(img)


## The mean colour of a premultiplied RGBA8 image: RGB / A summed over a mip no wider than 32 (the whole image's box
## mean, kept to 8-bit steps per texel rather than per image), decoded from sRGB; null when it has no alpha.
static func mean_colour(img: Image):
	var c := img.duplicate() as Image
	c.clear_mipmaps()
	var level := 0
	if c.get_width() > 32 or c.get_height() > 32:
		c.generate_mipmaps()
		while maxi(c.get_width() >> level, c.get_height() >> level) > 32 and level < c.get_mipmap_count():
			level += 1
	var lw := maxi(c.get_width() >> level, 1)
	var lh := maxi(c.get_height() >> level, 1)
	var o := c.get_mipmap_offset(level) if level > 0 else 0
	var d := c.get_data()
	var s := Vector4.ZERO
	for i in lw * lh:
		var at := o + i * 4
		s += Vector4(d[at], d[at + 1], d[at + 2], d[at + 3])
	if s.w <= 0.0:
		return null
	return Color(s.x / s.w, s.y / s.w, s.z / s.w).srgb_to_linear()


static func _band(pool: Array, seen: Dictionary, colour_of: Callable, height_of: Callable) -> Dictionary:
	var hsum := 0.0
	var hw := 0.0
	var entries := []
	for e in pool:
		var sp := _name(e)
		var w := _weight(e)
		if w <= 0.0:
			continue
		var h := float(height_of.call(sp))
		if h > 0.0:
			hsum += h * w
			hw += w
		if not seen.has(sp):
			seen[sp] = colour_of.call(sp)
		if seen[sp] != null:
			entries.append([w, sp, seen[sp]])
	entries.sort_custom(func(a, b): return a[0] > b[0] or (a[0] == b[0] and str(a[1]) < str(b[1])))
	entries = entries.slice(0, MAX_COLOURS)
	var tot := 0.0
	for e in entries:
		tot += float(e[0])
	var cs := PackedColorArray()
	var ws := PackedFloat32Array()
	var mean := Color(0.0, 0.0, 0.0)
	var acc := 0.0
	for e in entries:
		var share := float(e[0]) / tot
		acc += share
		var c: Color = e[2]
		cs.append(c)
		ws.append(acc)
		mean = Color(mean.r + c.r * share, mean.g + c.g * share, mean.b + c.b * share)
	if not ws.is_empty():
		ws[ws.size() - 1] = 1.0
	return {"colours": cs, "weights": ws, "mean": mean, "h": hsum / hw if hw > 0.0 else 0.0}


## A band with no colour takes the mid band's (or the first band that has one); none when no band has one.
static func _fill_empty(bands: Array) -> void:
	var src := -1
	for i in [1, 0, 2]:
		if not (bands[i]["colours"] as PackedColorArray).is_empty():
			src = i
			break
	if src < 0:
		return
	for b in bands:
		if (b["colours"] as PackedColorArray).is_empty():
			b["colours"] = bands[src]["colours"]
			b["weights"] = bands[src]["weights"]
			b["mean"] = bands[src]["mean"]


static func _one_colour(b: Dictionary, c: Color) -> void:
	b["colours"] = PackedColorArray([c])
	b["weights"] = PackedFloat32Array([1.0])
	b["mean"] = c


static func _scaled(pool: Array, share: float) -> Array:
	var tot := 0.0
	for e in pool:
		tot += _weight(e)
	var out := []
	for e in pool:
		out.append([_name(e), _weight(e) / tot * share if tot > 0.0 else 0.0])
	return out


static func _name(e) -> String:
	return str(e[0]) if typeof(e) == TYPE_ARRAY else str(e)


static func _weight(e) -> float:
	return float(e[1]) if typeof(e) == TYPE_ARRAY and (e as Array).size() > 1 else 1.0
