# Copyright (c) 2026 Digitzone
# SPDX-License-Identifier: MIT
extends RefCounted
## Per-species cost sheet for the vegetation carrier: triangles per surface at LOD0,
## stamped card count, and the ALPHA OCCUPANCY of each foliage surface's atlas region
## (the share of the card area the rasteriser fills that the alpha test then keeps).
## A 1 m card with 30 % opaque texels costs the pre-pass and every shadow cascade
## 3.3x what it shows. The profile's species are weighted by their pool weight so the
## sheet reflects the stand, not the catalogue.
##
## Runs as a unit suite (static run()) through the host's suite runner. VEG_PROFILE picks the flora profile; unset,
## it is the config's fallback flora (ForestConfig.default_profile_path):
##
##   VEG_PROFILE=<a flora profile .json> <the host's suite runner> res://addons/wuifwoud/tools/wf_mesh_stats.gd

## The species' assets.
const ForestAssets := preload("res://addons/wuifwoud/forest_assets.gd")
## Decoded atlas per texture path: the toon packs share one 4096 sheet across ~30
## species, and decompressing it per surface is what stalls a headless run.
static var _img_cache: Dictionary = {}


static func _image_of(tex: Texture2D) -> Image:
	var key := tex.resource_path if tex.resource_path != "" else str(tex.get_instance_id())
	if not _img_cache.has(key):
		var img := tex.get_image()
		if img != null and img.is_compressed():
			img.decompress()
		_img_cache[key] = img
	return _img_cache[key]


## The cost sheet, as a unit suite: {name, passed, failed, details}.
static func run() -> Dictionary:
	var profile := OS.get_environment("VEG_PROFILE")
	if profile == "":
		profile = String((load("res://addons/wuifwoud/forest_config.gd") as GDScript).current().default_profile_path)
	var d = JSON.parse_string(FileAccess.get_file_as_string("res://" + profile.trim_prefix("res://")))
	var weights := {}
	for band in d.get("species", {}):
		for e in d["species"][band]:
			weights[str(e[0])] = maxf(float(weights.get(str(e[0]), 0.0)), float(e[1]))
	print("%-22s %5s %8s %8s %6s %7s %6s  %s" % ["species", "pool", "tris", "fol_tris", "cards", "occup", "aabb_h", "raster waste = fol_tris / occup"])
	var rows := []
	for name in weights:
		var meshes: Array = ForestAssets._species_materials(name)
		if meshes.is_empty():
			print("%-22s  (no mesh)" % name)
			continue
		var mesh: ArrayMesh = meshes[0]
		var tris := 0
		var fol_tris := 0
		var cards := {}
		var occ_sum := 0.0
		var occ_n := 0
		for si in mesh.get_surface_count():
			var arr := mesh.surface_get_arrays(si)
			var idx: PackedInt32Array = arr[Mesh.ARRAY_INDEX]
			var n := idx.size() / 3 if idx.size() > 0 else (arr[Mesh.ARRAY_VERTEX] as PackedVector3Array).size() / 3
			tris += n
			var sm := mesh.surface_get_material(si) as ShaderMaterial
			if sm == null or float(sm.get_shader_parameter("foliage_mask")) < 0.5:
				continue
			fol_tris += n
			var cols: PackedColorArray = arr[Mesh.ARRAY_COLOR] if arr[Mesh.ARRAY_COLOR] != null else PackedColorArray()
			for c in cols:
				cards[snappedf(c.r, 0.0001)] = true
			var tex := sm.get_shader_parameter("albedo_tex") as Texture2D
			var uvs: PackedVector2Array = arr[Mesh.ARRAY_TEX_UV]
			if tex != null and uvs.size() > 0:
				var img := _image_of(tex)
				if img != null:
					var cut := float(sm.get_shader_parameter("alpha_cut"))
					occ_sum += _occupancy(img, uvs, idx, cut)
					occ_n += 1
		var occ := occ_sum / maxf(occ_n, 1)
		var r := [name, weights[name], tris, fol_tris, cards.size(), occ, mesh.get_aabb().size.y,
			float(fol_tris) / maxf(occ, 0.01)]
		rows.append(r)
		print("%-22s %5.1f %8d %8d %6d %6.0f%% %6.1f  %8.0f" % [r[0], r[1], r[2], r[3], r[4], r[5] * 100.0, r[6], r[7]])
	# AUTHORED LOD CHAIN in the source scene, per species that has one. The carrier
	# takes `_LOD0` and lets meshoptimizer decimate it; this is what it leaves behind.
	print("--- authored LOD nodes in the source FBX (name: tris per surface) ---")
	for name in weights:
		var path := ForestAssets.mesh_path(name)
		if not ResourceLoader.exists(path):
			continue
		var ps = load(path)
		if not (ps is PackedScene):
			continue
		var root: Node = (ps as PackedScene).instantiate()
		var line := "%-22s" % name
		var any := false
		for mi in root.find_children("*", "MeshInstance3D", true, false):
			var nm := String(mi.name)
			if nm.findn("LOD") < 0:
				continue
			var m: Mesh = (mi as MeshInstance3D).mesh
			if m == null:
				continue
			var per := []
			for si in m.get_surface_count():
				var arr := m.surface_get_arrays(si)
				var idx: PackedInt32Array = arr[Mesh.ARRAY_INDEX]
				per.append(idx.size() / 3 if idx.size() > 0 else (arr[Mesh.ARRAY_VERTEX] as PackedVector3Array).size() / 3)
			line += "  %s:%s" % [nm.substr(nm.findn("LOD")), "+".join(per.map(func(x): return str(x)))]
			any = true
		root.free()
		if any:
			print(line)
	rows.sort_custom(func(a, b): return a[7] > b[7])
	print("--- sorted by raster waste ---")
	for r in rows:
		print("%-22s %5.1f %8d %8d %6d %6.0f%% %6.1f  %8.0f" % [r[0], r[1], r[2], r[3], r[4], r[5] * 100.0, r[6], r[7]])
	return {"name": "wf_mesh_stats", "passed": rows.size(), "failed": 0}


## Area-weighted alpha occupancy of the triangles' UV footprint: sample each triangle
## on a small grid in barycentric space and count texels over the cut.
static func _occupancy(img: Image, uvs: PackedVector2Array, idx: PackedInt32Array, cut: float) -> float:
	var w := img.get_width()
	var h := img.get_height()
	var kept := 0
	var total := 0
	var tri_n := idx.size() / 3 if idx.size() > 0 else uvs.size() / 3
	var step := maxi(1, tri_n / 400)   # at most ~400 triangles sampled per surface
	for t in range(0, tri_n, step):
		var a := uvs[idx[t * 3]] if idx.size() > 0 else uvs[t * 3]
		var b := uvs[idx[t * 3 + 1]] if idx.size() > 0 else uvs[t * 3 + 1]
		var c := uvs[idx[t * 3 + 2]] if idx.size() > 0 else uvs[t * 3 + 2]
		for i in 6:
			for j in 6 - i:
				var u := (float(i) + 0.33) / 6.0
				var v := (float(j) + 0.33) / 6.0
				var uv := a + (b - a) * u + (c - a) * v
				var px := int(posmod(int(uv.x * w), w))
				var py := int(posmod(int(uv.y * h), h))
				total += 1
				if img.get_pixel(px, py).a >= cut:
					kept += 1
	return float(kept) / maxf(total, 1)
