# Copyright (c) 2026 Digitzone
# SPDX-License-Identifier: MIT
@tool
class_name ForestAssets
extends RefCounted
## Turns a species NAME into the things needed to draw it: a shadered mesh, an
## impostor card, the atlas rects and the crown shape measured off its geometry.
##
## PURE ASSET RESOLUTION: no scene, no terrain, no placement. A tool or a test can
## use it with a scatter of its own and still draw exactly what the game draws: one
## carrier, so a visual fix is written once.
##
## A single MultiMesh with a big custom AABB has neither frustum nor occlusion
## culling and pays for every instance behind the camera; that is not what the
## spawner does: it builds one MMI per species per chunk, each with its own
## visibility range, and does not build cells outside its streaming radius at all.
##
## Everything here is STATIC and CACHED BY SPECIES NAME, because an island of one
## species shares one shadered mesh, one impostor card and one wind feed.
# By PATH, like every reference in this carrier: it must compile in a bare `--script` boot.
## The forest's log, through its sink.
const ForestLog := preload("res://addons/wuifwoud/forest_log.gd")
## The project's forest config.
const ForestConfigRes := preload("res://addons/wuifwoud/forest_config.gd")
## A species of a pack.
const ForestSpeciesRes := preload("res://addons/wuifwoud/species/forest_species.gd")

## THE SPECIES COME FROM PACKS: the ForestSpeciesPacks ForestConfig resolves (the ones it lists, the pack addons it
## finds, the built-in starter), each species a ForestSpecies naming its own mesh and textures.
## Loaded on first use, on the main thread (ForestSpawner._ready asks before any placement job), so workers only read
## them. Two packs with one species id: the first resolved wins, said once. Tests and tools hand in their own
## (use_packs).
static var _packs: Array = []            # ForestSpeciesPack, in resolved order
static var _species: Dictionary = {}      # id -> ForestSpecies
static var _pack_of: Dictionary = {}      # id -> its ForestSpeciesPack
static var _packs_loaded := false
static var _disabled: Dictionary = {}     # id -> true: the config's disabled_species (or use_packs' `disabled`)
static var _unknown_warned := {}
## Placement workers ask about species too: the one shared write (the unknown-species warning set) is locked.
static var _unknown_lock := Mutex.new()
## A species no pack has: a broadleaf tree with this trunk radius (m), said once per species.
const DEFAULT_TRUNK_RADIUS := 0.26


static func _ensure_packs() -> void:
	if _packs_loaded:
		return
	var c := ForestConfigRes.current()
	_apply_packs(c.resolved_packs(), c.disabled_species)


## Tests and tools: grow from `packs` (ForestSpeciesPack) instead of the config's, `disabled` switched off. Drops every
## cache.
static func use_packs(packs: Array, disabled := PackedStringArray()) -> void:
	_apply_packs(packs, disabled)
	reset()


## Tests: forget the packs; the next read resolves the config's again.
static func forget_packs() -> void:
	_packs_loaded = false
	_packs = []
	_species = {}
	_pack_of = {}
	_disabled = {}


## The packs and the tables built from them. The FIRST load drops no cache (there is none yet).
static func _apply_packs(packs: Array, disabled := PackedStringArray()) -> void:
	_packs_loaded = true
	_packs = []
	_species = {}
	_pack_of = {}
	_unknown_warned.clear()
	_disabled = {}
	for id in disabled:
		_disabled[String(id)] = true
	for p in packs:
		if p == null:
			continue
		_packs.append(p)
		for sp in p.species:
			if sp == null or String(sp.id) == "" or _disabled.has(String(sp.id)):
				continue
			if _species.has(sp.id):
				ForestLog.warn("[Wuifwoud] species %s is in two packs: %s's grows, %s's does not"
					% [sp.id, _pack_label(_pack_of[sp.id]), _pack_label(p)])
				continue
			_species[sp.id] = sp
			_pack_of[sp.id] = p
	if _packs.is_empty():
		ForestLog.warn("[Wuifwoud] no species pack resolves: no species can be placed")


static func _pack_label(p) -> String:
	return String(p.name) if String(p.name) != "" else String(p.resource_path)


## Every species id the resolved packs hold, sorted.
static func species_ids() -> PackedStringArray:
	_ensure_packs()
	var out := PackedStringArray(_species.keys())
	out.sort()
	return out


## The species `mesh_name` (a ForestSpecies), or null with one warning per species no pack has.
static func _species_entry(mesh_name: String):
	_ensure_packs()
	if _species.has(mesh_name):
		return _species[mesh_name]
	if _disabled.has(mesh_name):
		return null
	_unknown_lock.lock()
	var first := not _unknown_warned.has(mesh_name)
	_unknown_warned[mesh_name] = true
	_unknown_lock.unlock()
	if first:
		ForestLog.warn("[Vegetation] %s is in no species pack: a broadleaf tree, trunk %.2f m"
			% [mesh_name, DEFAULT_TRUNK_RADIUS])
	return null


## Whether species `mesh_name` is switched off (the config's disabled_species): it is in no species table then.
static func is_disabled(mesh_name: String) -> bool:
	_ensure_packs()
	return _disabled.has(mesh_name)


## The species switched off, sorted.
static func disabled_ids() -> PackedStringArray:
	_ensure_packs()
	var out := PackedStringArray(_disabled.keys())
	out.sort()
	return out


## A pack has `mesh_name` (no warning: the forest asks before a single tree or a row pins one).
static func has_species(mesh_name: String) -> bool:
	_ensure_packs()
	return _species.has(mesh_name)


## A species' trunk collider radius (m); a species no pack has gets DEFAULT_TRUNK_RADIUS.
static func trunk_radius_for(mesh_name: String) -> float:
	var sp = _species_entry(mesh_name)
	return float(sp.trunk_radius) if sp != null else DEFAULT_TRUNK_RADIUS


## Whether a species is in the mature subset (old growth draws from it).
static func is_mature(mesh_name: String) -> bool:
	var sp = _species_entry(mesh_name)
	return sp != null and bool(sp.mature)


## Whether a species is in the young subset (young growth draws from it).
static func is_young(mesh_name: String) -> bool:
	var sp = _species_entry(mesh_name)
	return sp != null and bool(sp.young)


## Full path to a species' mesh; "" for one no pack has.
static func mesh_path(mesh_name: String) -> String:
	_ensure_packs()
	var sp = _species.get(mesh_name)
	return ForestSpeciesRes.resolve(String(sp.mesh)) if sp != null else ""
const _WIND_SHADER_PATH := "res://addons/wuifwoud/shaders/tree_wind.gdshader"
const _BILLBOARD_SHADER_PATH := "res://addons/wuifwoud/shaders/tree_billboard.gdshader"
## LOADED LAZILY, NOT PRELOADED, and the order is load-bearing. Both shaders declare
## `global uniform`s (wf_common.gdshaderinc), and a global that does not exist when
## the shader is PARSED is a compile error ("Create it in the Project Settings"),
## which renders every tree as the magenta error shader. The globals are declared in
## project.godot, but an external edit to project.godot is dropped the next time an
## open editor saves it, so `ensure_wind_globals` registers them at runtime first,
## and a `preload` would have parsed the shader before any code here could run.
static var _wind_shader: Shader = null
static var _billboard_shader: Shader = null

## The wind globals both tree shaders read, with their project defaults. Types and
## names mirror wf_common.gdshaderinc. Registered here if project.godot lacks them
## (see _wind_shader_res); fed every frame by ForestSpawner._advance_wind.
const WIND_GLOBALS := {
	"wuifwoud_wind_phase": [RenderingServer.GLOBAL_VAR_TYPE_FLOAT, 0.0],
	"wuifwoud_gust_phase": [RenderingServer.GLOBAL_VAR_TYPE_FLOAT, 0.0],
	"wuifwoud_wind_dir": [RenderingServer.GLOBAL_VAR_TYPE_VEC2, Vector2(1.0, 0.3)],
	"wuifwoud_wind_strength": [RenderingServer.GLOBAL_VAR_TYPE_FLOAT, 0.0],
	"wuifwoud_gust_depth": [RenderingServer.GLOBAL_VAR_TYPE_FLOAT, 0.0],
}


## Make sure every wind global exists before a tree shader is parsed. Idempotent;
## the project.godot declaration wins when present.
static func ensure_wind_globals() -> void:
	if _wind_globals_done:
		return
	# The engine says which globals exist only in the editor: anywhere else the list is an error (and empty, so a
	# second call would add them again, another error each). Outside the editor this process's own record decides.
	var listed: Array = Array(RenderingServer.global_shader_parameter_get_list()) if Engine.is_editor_hint() else []
	for name in WIND_GLOBALS:
		if ProjectSettings.has_setting("shader_globals/" + name) or listed.has(StringName(name)):
			continue
		var spec: Array = WIND_GLOBALS[name]
		RenderingServer.global_shader_parameter_add(StringName(name), spec[0], spec[1])
	_wind_globals_done = true


## Whether ensure_wind_globals has run in this process.
static var _wind_globals_done := false


static func _wind_shader_res() -> Shader:
	if _wind_shader == null:
		ensure_wind_globals()
		_wind_shader = load(_WIND_SHADER_PATH)
	return _wind_shader


static func _billboard_shader_res() -> Shader:
	if _billboard_shader == null:
		ensure_wind_globals()
		_billboard_shader = load(_BILLBOARD_SHADER_PATH)
	return _billboard_shader


## A bush, by its species' `kind`: one rule, used everywhere. A bush has no card, a short dissolve, and never casts.
static func is_bush_mesh(mesh_name: String) -> bool:
	var sp = _species_entry(mesh_name)
	return sp != null and String(sp.kind) == "bush"


static var _mat_cache: Dictionary = {}        # mesh name -> [shadered ArrayMesh per LOD level]
static var _lod_mesh_cache: Dictionary = {}   # mesh name -> [ArrayMesh per authored LOD level]
static var _height_cache: Dictionary = {}     # mesh name -> AABB height, metres
static var _radius_cache: Dictionary = {}     # mesh name -> bounding radius about the origin
static var _crown_cache: Dictionary = {}      # mesh name -> Vector2(height, crown radius), metres
static var _billboard_cache: Dictionary = {}  # mesh name -> {mesh, mat} | {}
## mesh name -> the far palette's crown colour (Color, or null: no bake): a GPU read of the impostor bake, ~15 ms
## each, so read once (ForestFarPalette.crown_colour; the forest reads them at load).
static var _crown_colour_cache: Dictionary = {}
## Every material built here, so ONE wind feed can drive the whole island: tens of
## materials, not thousands, because each species shares one.
static var _live_materials: Array = []
## Baked impostor rings are used when present. False falls every species back to the
## procedural silhouette, which is also what a species with no bake gets.
static var _rings_enabled := true


## Drop every cache. A tool that rebuilds between areas in one process needs it: a mesh
## cached against an earlier pack is a forest of the wrong species with no error.
static func reset() -> void:
	_mat_cache.clear()
	_lod_mesh_cache.clear()
	_height_cache.clear()
	_radius_cache.clear()
	_crown_cache.clear()
	_billboard_cache.clear()
	_crown_colour_cache.clear()
	_prep_cache.clear()
	_unbuilt_warned.clear()
	_live_materials.clear()
	_mesh_cache.clear()
	_lod_chain_cache.clear()
	_tex_cache.clear()
	_ring_cache.clear()
	_manifests.clear()


static func _load_tex(path: String) -> Texture2D:
	if path == "":
		return null
	if not _tex_cache.has(path):
		_tex_cache[path] = load(path) as Texture2D if ResourceLoader.exists(path) else null
	return _tex_cache[path]


## The PBR maps of a species' bark or foliage surfaces: {"normal": path, "mtao": path}, each only when
## the species names one.
static func _tex_set(mesh_name: String, foliage: bool) -> Dictionary:
	_ensure_packs()
	return _tex_set_of(_species.get(mesh_name), foliage)


static func _tex_set_of(sp, foliage: bool) -> Dictionary:
	var out := {}
	if sp == null:
		return out
	var n := ForestSpeciesRes.resolve(String(sp.foliage_normal if foliage else sp.bark_normal))
	var m := ForestSpeciesRes.resolve(String(sp.foliage_mtao if foliage else sp.bark_mtao))
	if n != "":
		out["normal"] = n
	if m != "":
		out["mtao"] = m
	return out


const _ALPHA_CUT := 0.5


## Foliage alpha cutoff for a species: its own (cutting a pack authored at 0.40 at 0.50 throws away needle the artist
## put there and thins every crown); 0.5 for one no pack has.
static func alpha_cut_for(mesh_name: String) -> float:
	var sp = _species_entry(mesh_name)
	return float(sp.alpha_cut) if sp != null else _ALPHA_CUT


## Textures by path, loaded once (misses included).
static var _tex_cache: Dictionary = {}


## The full-detail mesh in an imported vegetation scene, cached (misses included).
##
## NOT Furniture._scene_mesh, which takes the FIRST MeshInstance3D it reaches and
## breaks. That is right for a manhole FBX carrying one mesh and wrong for these.
## MEASURED on a palm:
##
##     Palm_LOD0            2285 verts
##     Palm_LOD1            1772
##     Palm_LOD2            1331
##     Palm_LOD3             527
##     Palm_MeshCollider       22   <- what a first-mesh pick returns
##
## A 19 m palm drawn as a 22-vertex COLLISION PROXY. Nothing errors and nothing
## logs; the forest just ships as splinters.
##
## Prefer the node the artist labelled LOD0, fall back to vertex count, and never
## take a collider. This is the FULL-DETAIL level only; the authored LOD1-3 beside it
## are taken by `_lod_chain` and rebuilt into the mesh's LOD chain (see the note
## above LOD_SWITCH_M).
static var _mesh_cache: Dictionary = {}


## The full-detail mesh of an imported vegetation scene and its authored chain, from ONE instance of it (cache-free
## and silent: the pack build calls it for packs the forest may not grow): {"lod0": the full-detail Mesh or
## null, "chain": [LOD0, LOD1, …] validated as _lod_chain says, "warnings"}. `names`: the species' leaf materials,
## when it names them. MAIN THREAD: every mesh read goes through the rendering server.
static func _scene_meshes(path: String, names: PackedStringArray) -> Dictionary:
	var warnings := PackedStringArray()
	var out := {"lod0": null, "chain": [], "warnings": warnings}
	if path == "" or not ResourceLoader.exists(path):
		return out
	var ps := load(path) as PackedScene
	if ps == null:
		return out
	var root: Node = ps.instantiate()
	var mis := root.find_children("*", "MeshInstance3D", true, false)
	var found: Mesh = null
	var best := -1
	var got_lod0 := false
	for mi in mis:
		var m: Mesh = (mi as MeshInstance3D).mesh
		if m == null:
			continue
		var nm := String(mi.name)
		if nm.findn("collider") >= 0 or nm.findn("collision") >= 0:
			continue
		if nm.ends_with("_LOD0"):
			found = m
			got_lod0 = true
			break
		var n := 0
		for si in m.get_surface_count():
			var v = m.surface_get_arrays(si)[Mesh.ARRAY_VERTEX]
			n += (v as PackedVector3Array).size() if v != null else 0
		if n > best:
			best = n
			found = m
	if not got_lod0 and found == null:
		warnings.append("%s has no usable mesh" % path.get_file())
	var by_level := {}
	for mi in mis:
		var nm := String(mi.name)
		var at := nm.rfindn("_LOD")
		var m: Mesh = (mi as MeshInstance3D).mesh
		if at < 0 or m == null or nm.findn("collider") >= 0:
			continue
		var lvl := nm.substr(at + 4)
		if lvl.is_valid_int():
			by_level[int(lvl)] = m
	root.free()
	var chain: Array = []
	var k := 0
	while by_level.has(k):
		var m = by_level[k]
		if not (m is ArrayMesh) or (k > 0 and not _lod_matches(chain[0], m, names)):
			break
		chain.append(m)
		k += 1
	out["lod0"] = found
	out["chain"] = chain
	out["warnings"] = warnings
	return out


## The full-detail mesh of an imported scene, cached per path (tools; the forest's own preparation reads the scene
## through _scene_meshes).
static func _mesh(path: String) -> Mesh:
	if not _mesh_cache.has(path):
		var sc := _scene_meshes(path, PackedStringArray())
		for w in sc["warnings"]:
			ForestLog.warn("[Vegetation] " + String(w))
		_mesh_cache[path] = sc["lod0"]
		_lod_chain_cache[path] = sc["chain"]
	return _mesh_cache[path]


## AUTHORED LOD CHAINS. Tree packs ship one: `<species>_LOD0..LOD3` nodes in the
## model (7115 -> 2906 -> 1703 -> 698 triangles on a detailed fir; 1856 -> 1248 -> 820
## -> 320 on a stylised palm). Decimating LOD0 instead cannot simplify a crown of alpha
## cards: it has no cards to remove, only triangles to collapse, so a generated chain
## tears leaves rather than thinning them, and `tree_lod_bias` would have to sit at
## 0.35 to get anything out of it. The artist's LOD1 is a crown with FEWER, LARGER cards
## (the silhouette kept, the interior dropped), which is the thing a distance LOD is for.
##
## ONE MESH WITH INDEX LODs, NOT ONE MULTIMESH PER LEVEL. One MultiMesh per authored
## level over the same instances, each level's shader keeping only the instances inside
## its own distance band, measures 44 % WORSE (forest cost 6.9 ms against 4.8 at a
## driver-eye station) because collapsing an instance in the vertex stage skips
## RASTERISATION, not vertex shading: every level pays the full vertex cost of every
## instance in the chunk, counted: 18.15M primitives against 3.28M, 3479 draws against
## 2467, 8480 MultiMeshInstances against 2100, and a 44-second first fill. A LOD chosen
## by the tree's distance rather than by its chunk's is bought instead by small render
## buckets (ForestSpawner.render_bucket_m), which cost draw calls only.
##
## Godot mesh LODs are index buffers over ONE vertex buffer, so the chain is rebuilt as
## a single surface: every level's vertices concatenated, LOD0's indices as the
## surface, each further level's indices (offset) as a LOD keyed by the distance it
## takes over at. The switch distances follow a typical tree pack's own intent, rounded
## conservative: its LOD group keeps LOD0 for a tree filling the WHOLE screen and puts a
## 20 m fir on LOD2 from ~19 m; this keeps LOD0 to 15 m.
##
## The key is in METRES PER PIXEL: Godot picks LOD i once `key_i * scale / distance`
## projects under the viewport's `mesh_lod_threshold` (1 px default), where distance is
## scaled by the camera's lod multiplier (view width at 1 m). So a key is "the edge
## length that is one pixel at d": d * (2 * tan(fov/2) * aspect) / width_px. Pinned
## to a 70 deg, 16:9, 1920-wide camera; a wider view or lower resolution switches
## sooner, exactly as every other LOD in the engine does. Measured in `lod_bias` terms
## on the MultiMesh, so that export remains a multiplier on these.
const LOD_SWITCH_M := [15.0, 40.0, 110.0]
const _LOD_KEY_PER_M := 2.0 * 0.7002 * (16.0 / 9.0) / 1920.0


## The MESH -> CARD hand-over band of a species: where the mesh starts dithering out
## and where it is gone. One function, read by push_lod_params for the shader and by
## _add_tree_mmi for the node range, so the two cannot disagree.
static func handover_band(cut_m: float, overlap_m: float) -> Dictionary:
	return {"out0": maxf(cut_m - overlap_m, 0.0), "out1": cut_m}


## Unscaled height of a species, metres: the LOD0 AABB. Cached; the mesh is loaded
## anyway by anything that draws it, so this is free after the first call.
static func species_height(mesh_name: String) -> float:
	if _height_cache.has(mesh_name):
		return _height_cache[mesh_name]
	var p := _prepared(mesh_name)
	var h: float = (p["aabb"] as AABB).size.y if p.has("aabb") else 0.0
	_height_cache[mesh_name] = h
	return h


## A species' crown for rotor strikes, unscaled metres: x = height (the LOD0 AABB), y =
## crown radius (the farthest AABB corner from the trunk axis, in the ground plane).
## Vector2.ZERO if the mesh does not load. MAIN THREAD, like species_height: it loads
## the mesh; the placement worker hands raw trunk records to the commit instead.
static func species_crown(mesh_name: String) -> Vector2:
	if _crown_cache.has(mesh_name):
		return _crown_cache[mesh_name]
	var c := Vector2.ZERO
	var p := _prepared(mesh_name)
	if p.has("aabb"):
		var ab: AABB = p["aabb"]
		var rad := 0.0
		for i in 8:
			var e := ab.get_endpoint(i)
			rad = maxf(rad, Vector2(e.x, e.z).length())
		c = Vector2(ab.size.y, rad)
	_crown_cache[mesh_name] = c
	return c


## Radius of a sphere at the INSTANCE ORIGIN that contains the whole species, metres,
## unscaled. Not `aabb.size.length() * 0.5`: the origin is the trunk base, not the
## AABB centre, so a 20 m fir would get a 10 m sphere and be culled while half of it
## was still on screen. This is the farthest AABB corner from the origin.
static func species_radius(mesh_name: String) -> float:
	if _radius_cache.has(mesh_name):
		return _radius_cache[mesh_name]
	var r := 0.0
	var p := _prepared(mesh_name)
	if p.has("aabb"):
		var ab: AABB = p["aabb"]
		for i in 8:
			r = maxf(r, ab.get_endpoint(i).length())
	_radius_cache[mesh_name] = r
	return r


## Radius of a sphere at the instance origin containing this species' IMPOSTOR CARD,
## metres, unscaled: the card is billboarded, so it sweeps a sphere rather than
## occupying a fixed quad. Its centre rides `card_pivot_h` above the origin and it
## spans `size` across, so the reach is the lift plus the quad's half-diagonal. Used
## to frustum-cull cards in the GPU pass; too small and cards pop out at the screen
## edge, so it is deliberately the outer bound rather than a fit.
static func card_radius(mesh_name: String) -> float:
	var bb := _billboard(mesh_name)
	if bb.is_empty():
		return 0.0
	var q := bb["mesh"] as QuadMesh
	if q == null:
		return species_radius(mesh_name)
	return q.size.length() * 0.5 + species_height(mesh_name) * 0.5


## The distance at which a plant of this species stands `px_min` pixels tall.
##
## THE SAME SCREEN METRIC THE LOD CHAIN USES, one level up: `_LOD_KEY_PER_M` is metres
## per pixel per metre of distance on the pinned camera (70 deg, 16:9, 1920), so
## `px = height / (d * _LOD_KEY_PER_M)` and the inverse is a cut distance. This exists
## because a FLAT cut distance is a statement about the world, not about the screen:
## one distance for every bush, from a 0.6 m grass tuft to a 4 m tree fern, draws the
## tuft at under two pixels for most of its range while the fern and the tuft share one
## number. INF when the species has no height (mesh missing), so a caller's own cap
## decides rather than this cutting everything to zero.
static func px_cull_distance(mesh_name: String, px_min: float, scale: float = 1.0) -> float:
	var h := species_height(mesh_name) * scale
	if h <= 0.0 or px_min <= 0.0:
		return INF
	return h / (px_min * _LOD_KEY_PER_M)


static var _lod_chain_cache: Dictionary = {}


## The authored chain [LOD0, LOD1, ...] of an imported vegetation scene, validated: every level has LOD0's surface
## count, the same bark/foliage classification per surface, triangles and an index buffer. Stops at the first level that
## does not match (a cross-billboard LOD4 with its own material would otherwise bind the leaf atlas to a quad). Empty
## when the scene names no `_LOD0`; [LOD0] alone means "no chain" to the caller. Cached per path (tools; the forest's
## own preparation reads the scene through _scene_meshes).
static func _lod_chain(path: String) -> Array:
	if not _lod_chain_cache.has(path):
		_mesh(path)
	return _lod_chain_cache[path]


static func _lod_matches(lod0: ArrayMesh, m: ArrayMesh, names := PackedStringArray()) -> bool:
	if m.get_surface_count() != lod0.get_surface_count():
		return false
	for si in lod0.get_surface_count():
		if m.surface_get_primitive_type(si) != Mesh.PRIMITIVE_TRIANGLES:
			return false
		if _is_foliage_surface(m, si, names) != _is_foliage_surface(lod0, si, names):
			return false
		var idx = m.surface_get_arrays(si)[Mesh.ARRAY_INDEX]
		if idx == null or (idx as PackedInt32Array).is_empty():
			return false
	return true


## One ArrayMesh from an authored chain: per surface, all levels' vertices in one
## buffer, LOD0 as the surface and LOD1.. as distance-keyed index LODs; card ids
## stamped over every level of a foliage surface (components never span levels, so one
## union-find over the concatenated indices does all of them).
static func _build_authored_chain(chain: Array, foliage_surfaces: Array) -> ArrayMesh:
	var lod0: ArrayMesh = chain[0]
	var out := ArrayMesh.new()
	var ATTRS := _CHAIN_ATTRS
	for si in lod0.get_surface_count():
		var base: Array = lod0.surface_get_arrays(si)
		# The attribute set is LOD0's. A level missing one is filled with the neutral
		# value; one carrying an extra array drops it: the surface has one format.
		var parts := {}
		for a in ATTRS:
			if base[a] != null:
				parts[a] = _empty_like(a)
		var verts := PackedVector3Array()
		var main_idx := PackedInt32Array()
		var all_idx := PackedInt32Array()
		var lods := {}
		var offset := 0
		var last_key := 0.0
		for k in chain.size():
			var arr: Array = (chain[k] as ArrayMesh).surface_get_arrays(si)
			var v: PackedVector3Array = arr[Mesh.ARRAY_VERTEX]
			var idx: PackedInt32Array = (arr[Mesh.ARRAY_INDEX] as PackedInt32Array).duplicate()
			if offset > 0:
				for i in idx.size():
					idx[i] += offset
			verts.append_array(v)
			for a in parts:
				_append_attr(parts[a], a, arr[a], v.size())
			if k == 0:
				main_idx = idx
			else:
				# Strictly increasing keys: levels past the switch table double the last.
				var key: float = LOD_SWITCH_M[k - 1] * _LOD_KEY_PER_M \
					if k - 1 < LOD_SWITCH_M.size() else last_key * 2.0
				lods[key] = idx
				last_key = key
			all_idx.append_array(idx)
			offset += v.size()
		var arrays := []
		arrays.resize(Mesh.ARRAY_MAX)
		arrays[Mesh.ARRAY_VERTEX] = verts
		arrays[Mesh.ARRAY_INDEX] = main_idx
		for a in parts:
			arrays[a] = parts[a]
		if si in foliage_surfaces:
			arrays[Mesh.ARRAY_COLOR] = _card_colors(verts.size(), all_idx, arrays[Mesh.ARRAY_COLOR])
		out.add_surface_from_arrays(Mesh.PRIMITIVE_TRIANGLES, arrays, [], lods)
		out.surface_set_name(si, lod0.surface_get_name(si))
		out.surface_set_material(si, lod0.surface_get_material(si))
	return out


## The attributes a rebuilt surface carries over, in LOD0's set. Shared by
## _build_authored_chain and _species_lod_meshes so the two cannot disagree about what
## a level's surface is allowed to contain.
const _CHAIN_ATTRS := [Mesh.ARRAY_NORMAL, Mesh.ARRAY_TANGENT, Mesh.ARRAY_COLOR,
	Mesh.ARRAY_TEX_UV, Mesh.ARRAY_TEX_UV2]


static func _empty_like(attr: int):
	match attr:
		Mesh.ARRAY_NORMAL: return PackedVector3Array()
		Mesh.ARRAY_TANGENT: return PackedFloat32Array()
		Mesh.ARRAY_COLOR: return PackedColorArray()
		_: return PackedVector2Array()


static func _append_attr(acc, attr: int, part, n: int) -> void:
	if part != null and (attr != Mesh.ARRAY_TANGENT or (part as PackedFloat32Array).size() == n * 4):
		acc.append_array(part)
		return
	match attr:
		Mesh.ARRAY_NORMAL:
			for i in n:
				(acc as PackedVector3Array).append(Vector3.UP)
		Mesh.ARRAY_TANGENT:
			for i in n:
				(acc as PackedFloat32Array).append_array(PackedFloat32Array([1.0, 0.0, 0.0, 1.0]))
		Mesh.ARRAY_COLOR:
			for i in n:
				(acc as PackedColorArray).append(Color(1, 1, 1, 1))
		_:
			for i in n:
				(acc as PackedVector2Array).append(Vector2.ZERO)


## A species' albedo sheet for its bark or foliage surfaces; null when it names none.
static func _atlas_for(mesh_name: String, foliage: bool) -> Texture2D:
	_ensure_packs()
	return _atlas_of(_species.get(mesh_name), foliage)


static func _atlas_of(sp, foliage: bool) -> Texture2D:
	if sp == null:
		return null
	return _load_tex(ForestSpeciesRes.resolve(String(sp.foliage_albedo if foliage else sp.bark_albedo)))


## Which surface is the crown. A model names its source material after the sheet it
## wants, so read that rather than guessing by index: a tree whose surfaces come
## back in a different order would otherwise get bark bound to its canopy, which is
## invisible in code and obvious only once it is on screen.
## Rebuild `src` with a per-CARD id in COLOR.r on each surface in `foliage_surfaces`.
##
## A card is a connected component of the surface's triangle graph (a leaf quad, a
## fan of cards, a frond), found by union-find over the index buffer. Every vertex of
## a component gets the same value, a deterministic hash of the component's lowest
## vertex index, so the shader can collapse a whole card in the vertex stage with all
## of its vertices agreeing, and so MP peers and repeat runs stamp identical ids.
## Non-foliage surfaces are copied unchanged. With an authored `chain` of two or more
## levels the mesh is rebuilt as that chain (see _build_authored_chain); otherwise the
## whole mesh goes through ImporterMesh so a generated LOD chain exists (importer
## defaults). Null when `src` cannot be rebuilt (no index buffer, non-triangle
## primitive).
static func stamp_card_ids(src: ArrayMesh, foliage_surfaces: Array, chain: Array = []) -> ArrayMesh:
	if chain.size() >= 2 and chain[0] == src:
		for si in src.get_surface_count():
			if si in foliage_surfaces and (src.surface_get_arrays(si)[Mesh.ARRAY_INDEX] as PackedInt32Array).is_empty():
				return null
		return _build_authored_chain(chain, foliage_surfaces)
	var im := ImporterMesh.new()
	for si in src.get_surface_count():
		if src.surface_get_primitive_type(si) != Mesh.PRIMITIVE_TRIANGLES:
			return null
		var arrays: Array = src.surface_get_arrays(si)
		if si in foliage_surfaces:
			var idx = arrays[Mesh.ARRAY_INDEX]
			var verts: PackedVector3Array = arrays[Mesh.ARRAY_VERTEX]
			if idx == null or (idx as PackedInt32Array).is_empty():
				return null
			# Only R is ours. Packs may author COLOR.a as the shiver mask the shader reads
			# (a fir pack ramps it over the needles); G and B stay too.
			arrays[Mesh.ARRAY_COLOR] = _card_colors(verts.size(), idx, arrays[Mesh.ARRAY_COLOR])
		im.add_surface(Mesh.PRIMITIVE_TRIANGLES, arrays, [], {}, src.surface_get_material(si),
			src.surface_get_name(si))
	# Importer defaults: normal merge 25 deg, split 60 deg. Same pass, same chain.
	im.generate_lods(25.0, 60.0, [])
	var out := im.get_mesh()
	for si in out.get_surface_count():
		out.surface_set_material(si, src.surface_get_material(si))
	return out


## Union-find over the index buffer; COLOR.r = hash of the component root. The other
## channels come from `existing` when the surface has colours (a mesh without them
## reads (1,1,1,1) in the shader, so that is what is written).
static func _card_colors(vertex_count: int, idx: PackedInt32Array, existing = null) -> PackedColorArray:
	var parent := PackedInt32Array()
	parent.resize(vertex_count)
	for i in vertex_count:
		parent[i] = i
	for t in range(0, idx.size() - 2, 3):
		var a := idx[t]
		var b := idx[t + 1]
		var c := idx[t + 2]
		_uf_union(parent, a, b)
		_uf_union(parent, a, c)
	var out := PackedColorArray()
	out.resize(vertex_count)
	var has_existing: bool = existing != null and (existing as PackedColorArray).size() == vertex_count
	for i in vertex_count:
		var root := _uf_find(parent, i)
		var c := (existing as PackedColorArray)[i] if has_existing else Color(1.0, 1.0, 1.0, 1.0)
		c.r = _card_hash(root)
		out[i] = c
	return out


## Deterministic integer mix -> [0, 1), spread evenly. The mesh stores COLOR at 8 bits,
## so the value lands on one of 256 levels; a multiplicative hash of roots that are
## all multiples of 4 clustered 0.002 apart and merged there. Platform-stable: every
## step is masked to 32 bits.
static func _card_hash(root: int) -> float:
	var x := (root * 0x9E3779B1) & 0xFFFFFFFF
	x ^= x >> 15
	x = (x * 0x85EBCA77) & 0xFFFFFFFF
	x ^= x >> 13
	x = (x * 0xC2B2AE3D) & 0xFFFFFFFF
	x ^= x >> 16
	return float(x & 0xFFFF) / 65536.0


static func _uf_find(parent: PackedInt32Array, i: int) -> int:
	var r := i
	while parent[r] != r:
		r = parent[r]
	while parent[i] != r:
		var nxt := parent[i]
		parent[i] = r
		i = nxt
	return r


static func _uf_union(parent: PackedInt32Array, a: int, b: int) -> void:
	var ra := _uf_find(parent, a)
	var rb := _uf_find(parent, b)
	if ra != rb:
		parent[maxi(ra, rb)] = mini(ra, rb)


static func _is_foliage_surface(mesh: ArrayMesh, si: int, names := PackedStringArray()) -> bool:
	var m := mesh.surface_get_material(si)
	# A species that names its leaf materials (ForestSpecies.foliage_materials) is taken at its word.
	if not names.is_empty():
		return m != null and names.has(String(m.resource_name))
	if m == null:
		return si > 0
	var n := String(m.resource_name).to_lower()
	# BARK WINS, and it is checked first because a name can contain both: the
	# fir packs carry names like `M_Bark_Fir_01` beside `M_leaves_Fir`, and a
	# substring test for "fir" or a missing "bark" rule binds the cutout leaf atlas
	# to a trunk: a tree with a transparent stem.
	if n.find("bark") >= 0 or n.find("trunk") >= 0 or n.find("wood") >= 0:
		return false
	# "leaves", not just "leaf": M_leaves_Fir does not contain "leaf".
	return n.find("vegetation") >= 0 or n.find("cutout") >= 0 \
		or n.find("leaf") >= 0 or n.find("leaves") >= 0 or n.find("needle") >= 0


## Crown centre, radius and how far the foliage normals fall short of spherical.
##
## MEASURED PER SPECIES, because the packs disagree and a fixed value would be wrong
## for half of them. Foliage-surface mean(N.radial), measured:
##
##   stylised oak +0.94   birch +0.91   bush +0.94   already spherified
##   stylised pine +0.01  palm  +0.04   tree +0.25   flat card normals
##
## `spherify` is the deficit (1 - measured), so a correctly authored broadleaf gets
## ~0 and is left alone while a pine gets ~1. Applying a blanket amount would flatten
## the trees that were already right. Cached with the material.
##
## The AABB is the FOLIAGE surface's, not the mesh's: a mesh AABB runs down the trunk
## to the ground, and a crown centred half way down its own trunk shades with the
## bright side underneath it.
static func _crown_shape(mesh: ArrayMesh, foliage: PackedInt32Array) -> Dictionary:
	var lo := Vector3(INF, INF, INF)
	var hi := Vector3(-INF, -INF, -INF)
	var radial := 0.0
	var up_sum := 0.0
	var n := 0
	var arrays: Array = []
	for si in mesh.get_surface_count():
		if not foliage.has(si):
			continue
		var arr := mesh.surface_get_arrays(si)
		var v = arr[Mesh.ARRAY_VERTEX]
		if v == null:
			continue
		var vs: PackedVector3Array = v
		for i in range(0, vs.size(), maxi(vs.size() / 600, 1)):
			lo = lo.min(vs[i])
			hi = hi.max(vs[i])
		arrays.append(arr)
	if arrays.is_empty() or lo.x == INF:
		return {"centre": Vector3.ZERO, "radius": 1.0, "spherify": 0.0}
	var centre := (lo + hi) * 0.5
	var radius: float = maxf((hi - lo).length() * 0.5, 0.05)
	for arr in arrays:
		var v = (arr as Array)[Mesh.ARRAY_VERTEX]
		var nn = (arr as Array)[Mesh.ARRAY_NORMAL]
		if v == null or nn == null:
			continue
		var vs: PackedVector3Array = v
		var ns: PackedVector3Array = nn
		for i in range(0, mini(vs.size(), ns.size()), maxi(vs.size() / 600, 1)):
			var r := vs[i] - centre
			if r.length() < 0.01:
				continue
			radial += ns[i].dot(r.normalized())
			up_sum += ns[i].y
			n += 1
	# AUTHORED-NESS, not radial-ness, and the difference is not academic.
	#
	# Scoring `1 - mean(N.radial)` assumes the only correct foliage normal is
	# spherical. It is not: detailed firs bias their needle normals UPWARD (measured
	# mean(N.y) +0.73 to +0.79 against a radial of only +0.03 to +0.48), which is the
	# standard conifer treatment and is authored on purpose. Scoring those on radial
	# alone gives spherify 0.5-0.97 and destroys exactly the shading the artist put there.
	#
	# What actually separates an authored normal from a flat card normal is whether
	# the normals agree about ANY direction. Flat cards face every way and average to
	# ~0 on both axes; measured mean(radial)/mean(N.y):
	#
	#   stylised oak   +0.94 / +0.21   stylised pine  +0.01 / +0.00
	#   detailed firs  +0.25 / +0.77   palm           +0.04 / +0.01
	#
	# so the deficit is against the STRONGER of the two agreements.
	var mean_radial := radial / maxf(float(n), 1.0)
	var mean_up := up_sum / maxf(float(n), 1.0)
	var authored: float = maxf(absf(mean_radial), absf(mean_up))
	return {"centre": centre, "radius": radius,
		"spherify": clampf(1.0 - authored, 0.0, 1.0)}


## THE PREPARATION: everything the forest derives from a species' mesh, materials aside.
## A pack's build saves it (ForestBuiltSpecies, built/<id>.res); the forest loads that, or prepares here when the pack is
## not built. Bump PREP_VERSION whenever what prepare_species_of returns changes: a species built at another version is
## prepared at start, and its pack says so once.
const PREP_VERSION := 1
static var _prep_cache: Dictionary = {}       # id -> the prepared species (built, or prepared at start); {}: none
static var _unbuilt_warned: Dictionary = {}   # built dir -> true: its pack was said to be unbuilt
## For tools and tests: preparations run so far (a built species runs none).
static var prepared_count := 0


## Species `sp` prepared: the combined mesh (LOD0 with its index LODs and stamped leaf cards: the per-chunk path), the
## per-level meshes (the GPU path's bands; [] without an authored chain), its leaf surfaces, whether its cards were
## stamped, the crown's shape and UV rect, the source LOD0's AABB, and what it warns about ({"warnings"} alone when its
## mesh is missing. NO MATERIAL on any surface, NO ForestAssets cache touched, nothing logged: the pack's build calls it
## for a pack the forest may not grow (a disabled starter) and logs its warnings in the build's report. MAIN THREAD.
##
## REBUILT THROUGH ImporterMesh, WITH ITS LOD CHAIN REGENERATED. A plain surface_get_arrays + add_surface_from_arrays
## rebuild drops the importer's LOD chain, and the LODs are load-bearing: `tree_lod_bias` buys 23 % of the forest's
## frame through them. ImporterMesh.generate_lods is the same meshoptimizer pass the importer ran, so the chain comes
## back, and the rebuild is what lets every foliage surface carry a per-card id (stamp_card_ids) for vertex-stage
## culling. The pack's own LOD0..3 when the scene names them, meshoptimizer's chain when not.
static func prepare_species_of(sp) -> Dictionary:
	prepared_count += 1
	var id := String(sp.id) if sp != null else ""
	var path := ForestSpeciesRes.resolve(String(sp.mesh)) if sp != null else ""
	var names: PackedStringArray = sp.foliage_materials if sp != null else PackedStringArray()
	var warnings := PackedStringArray()
	var scene := _scene_meshes(path, names)
	warnings.append_array(scene["warnings"])
	var src = scene["lod0"]
	if not (src is ArrayMesh):
		warnings.append("mesh missing: %s" % id)
		return {"warnings": warnings}
	var foliage := PackedInt32Array()
	for si in range((src as ArrayMesh).get_surface_count()):
		if _is_foliage_surface(src, si, names):
			foliage.append(si)
	var chain: Array = scene["chain"]
	var mesh: ArrayMesh = stamp_card_ids(src, Array(foliage), chain)
	if mesh == null:
		mesh = (src as ArrayMesh).duplicate() as ArrayMesh
	mesh.resource_name = id
	# Today's rule, kept for byte-identical materials: true whenever the species has a leaf surface (the duplicate
	# above is never `src` either).
	var stamped: bool = mesh != null and not foliage.is_empty() and mesh != src
	var crown := _crown_shape(mesh, foliage)
	var lv := _prepared_levels(id, mesh, chain, foliage)
	warnings.append_array(lv["warnings"])
	for si in mesh.get_surface_count():
		mesh.surface_set_material(si, null)
	return {"combined": mesh, "levels": lv["levels"], "foliage": foliage, "stamped": stamped,
		"crown_centre": crown["centre"], "crown_radius": crown["radius"], "spherify": crown["spherify"],
		"crown_uv": _crown_uv_of(src, foliage), "aabb": (src as ArrayMesh).get_aabb(), "warnings": warnings}


## Species `mesh_name` prepared, MAIN THREAD, cached: its pack's built species when built.json lists it at
## this PREP_VERSION; else prepared now, its warnings logged, and its pack said once to be unbuilt. {} for a species
## no pack has (said once) or whose mesh is missing (said).
static func _prepared(mesh_name: String) -> Dictionary:
	if _prep_cache.has(mesh_name):
		return _prep_cache[mesh_name]
	_ensure_packs()
	var p := {}
	var b = _built_species(mesh_name)
	if b != null:
		p = b.to_prepared()
	else:
		var sp = _species_entry(mesh_name)
		if sp != null:
			p = prepare_species_of(sp)
			for w in p.get("warnings", PackedStringArray()):
				ForestLog.warn("[Vegetation] " + String(w))
	if not p.has("combined"):
		p = {}
	_prep_cache[mesh_name] = p
	return p


## A species' built resource, or null: then its pack is said once to be unbuilt (no entry, another prep version,
## its file gone), or the file that would not load is named.
static func _built_species(mesh_name: String):
	var dir := built_dir_of(mesh_name)
	if dir == "":
		return null
	var e := built_entry(mesh_name)
	var path := dir.path_join(mesh_name + ".res")
	if e.is_empty() or int(e.get("prep_version", -1)) != PREP_VERSION or not ResourceLoader.exists(path):
		if not _unbuilt_warned.has(dir):
			_unbuilt_warned[dir] = true
			ForestLog.warn("[Wuifwoud] the species pack at %s is not built (or is out of date): its species are prepared when the forest starts. Build it: Forest → Build packs…, or res://addons/wuifwoud/tools/build_packs.gd"
				% dir.get_base_dir())
		return null
	var b = ResourceLoader.load(path, "", ResourceLoader.CACHE_MODE_REPLACE)
	if b == null or not b.has_method("to_prepared"):
		ForestLog.warn("[Wuifwoud] %s will not load: %s is prepared when the forest starts" % [path, mesh_name])
		return null
	return b


## A species' combined mesh, dressed: its preparation (built, or prepared now) with its materials made
## from its pack's textures. Cached per species, so a whole island of one species shares one mesh and one wind feed;
## [] when it has no mesh.
static func _species_materials(mesh_name: String) -> Array:
	if _mat_cache.has(mesh_name):
		return _mat_cache[mesh_name]
	var p := _prepared(mesh_name)
	if p.is_empty():
		_mat_cache[mesh_name] = []
		return []
	var mesh: ArrayMesh = p["combined"]
	_dress(_species.get(mesh_name), mesh, p, true)
	_mat_cache[mesh_name] = [mesh]
	return [mesh]


## Species `sp`'s materials on `mesh` (made at load, cheap): one wind ShaderMaterial a surface, bark or
## foliage by the preparation's classification, the crown's shape from it. `live`: the forest's, fed by its one wind
## feed (_live_materials); the pack build's bake dresses a mesh of its own with `live` off.
static func _dress(sp, mesh: ArrayMesh, p: Dictionary, live: bool) -> void:
	var name := String(sp.id) if sp != null else String(mesh.resource_name)
	var foliage_list: PackedInt32Array = p["foliage"]
	for si in range(mesh.get_surface_count()):
		var foliage := foliage_list.has(si)
		var tex := _atlas_of(sp, foliage)
		var sm := ShaderMaterial.new()
		sm.shader = _wind_shader_res()
		# Named after its species so the spawner's per-material pushes (push_lod_params)
		# can tell a bush material from a tree material without a second registry.
		sm.resource_name = name
		sm.set_shader_parameter("albedo_tex", tex)
		# PBR set when the species names one. Bound BEFORE the flags, and the flags are
		# only raised for maps that actually resolved: a missing file would
		# otherwise leave the sampler unbound, which reads as opaque white and lights
		# the tree as a chrome mirror rather than as a tree.
		var ts := _tex_set_of(sp, foliage)
		var nrm := _load_tex(String(ts.get("normal", "")))
		var mtao := _load_tex(String(ts.get("mtao", "")))
		if nrm != null:
			sm.set_shader_parameter("normal_tex", nrm)
		if mtao != null:
			sm.set_shader_parameter("mtao_tex", mtao)
		sm.set_shader_parameter("has_normal", nrm != null)
		sm.set_shader_parameter("has_mtao", mtao != null)
		sm.set_shader_parameter("albedo", Color.WHITE)
		sm.set_shader_parameter("roughness", 0.92)
		sm.set_shader_parameter("alpha_cut", (float(sp.alpha_cut) if sp != null else _ALPHA_CUT) if foliage else 0.0)
		sm.set_shader_parameter("backlight_col",
			Color(0.10, 0.14, 0.05) if foliage else Color(0, 0, 0))
		# Bark bends with the tree but must not flutter: a trembling trunk is the
		# other half of the "heat haze" look.
		sm.set_shader_parameter("foliage_mask", 1.0 if foliage else 0.0)
		# Only a stamped surface may be card-culled: an unstamped COLOR reads (1,1,1,1)
		# and every card would collapse the moment thinning came on.
		sm.set_shader_parameter("cards_stamped", bool(p["stamped"]) and foliage)
		sm.set_shader_parameter("crown_centre", p["crown_centre"])
		sm.set_shader_parameter("crown_radius", p["crown_radius"])
		sm.set_shader_parameter("spherify", p["spherify"] if foliage else 0.0)
		mesh.surface_set_material(si, sm)
		if live:
			_live_materials.append(sm)
		if tex == null:
			ForestLog.warn("[Vegetation] no atlas for %s surface %d: it will render black" % [name, si])


## One drawable Mesh per authored LOD LEVEL, sharing the species' materials.
##
## WHY THE CHAIN HAS TO COME APART AGAIN. The per-chunk path draws ONE mesh whose
## surfaces carry index LODs, and Godot picks the level from the MultiMesh's AABB,
## which is a 64 m chunk, so the chunk's distance is a fair stand-in for its trees'.
## The indirect path has no chunk: one MultiMesh per species covers the whole ring, its
## AABB says nothing about any instance in it, and every tree would draw at LOD0
## forever. There the level is chosen PER INSTANCE by binning distance in the cull
## compute, and a draw can only carry one mesh, so each bin needs its level as a mesh
## of its own. Same triangles, same materials, addressed differently.
##
## Card ids are re-stamped per level rather than shared across the chain: a component's
## id is a hash of its lowest vertex index, and the levels have their own index spaces.
## The consequence is that the card-cull set changes at a level switch, which is where
## the geometry changes anyway, so the pop has no new home.
##
## Returns `[combined]` for a species whose pack ships no authored `_LOD0..3`. That
## species then draws its LOD0 in every bin: a cost, not a defect, and logged once.
## Triangles in a mesh, summed over surfaces. Indexed or not: an unindexed surface
## still has three vertices per triangle.
static func _tri_count(m: ArrayMesh) -> int:
	if m == null:
		return 0
	var t := 0
	for si in m.get_surface_count():
		var a: Array = m.surface_get_arrays(si)
		var idx = a[Mesh.ARRAY_INDEX]
		if idx != null and (idx as PackedInt32Array).size() > 0:
			t += (idx as PackedInt32Array).size() / 3
		elif a[Mesh.ARRAY_VERTEX] != null:
			t += (a[Mesh.ARRAY_VERTEX] as PackedVector3Array).size() / 3
	return t


static func _species_lod_meshes(mesh_name: String) -> Array:
	if _lod_mesh_cache.has(mesh_name):
		return _lod_mesh_cache[mesh_name]
	var mats := _species_materials(mesh_name)
	if mats.is_empty():
		_lod_mesh_cache[mesh_name] = []
		return []
	var combined: ArrayMesh = mats[0]
	var levels: Array = _prepared(mesh_name).get("levels", [])
	if levels.is_empty():
		_lod_mesh_cache[mesh_name] = [combined]
		return [combined]
	for m in levels:
		for si in (m as ArrayMesh).get_surface_count():
			(m as ArrayMesh).surface_set_material(si, combined.surface_get_material(si))
	_lod_mesh_cache[mesh_name] = levels
	return levels


## The levels of an authored chain as meshes of their own (the preparation's; see the note above _tri_count), with no
## material: {"levels": [ArrayMesh per level] or [] (no chain, or none rebuilt), "warnings"}.
static func _prepared_levels(mesh_name: String, combined: ArrayMesh, chain: Array, foliage_surfaces: PackedInt32Array) -> Dictionary:
	var warnings := PackedStringArray()
	if chain.size() < 2:
		# THE TRIANGLE COUNT IS THE POINT OF THE WARNING, not the missing chain. Chain-less
		# species are typically small (a 192-triangle bush, a 265-triangle trunk, a
		# 1198-triangle fallen log) against chained trees of 5 000 to 16 000 triangles, and
		# a 192-triangle bush drawing LOD0 in the far bin is cheaper than a chained bush
		# drawing its LOD1. So print the number and let the reader decide, rather than
		# reporting every chain-less species as a problem of the same size.
		warnings.append("%s ships no authored LOD chain: indirect bins all draw LOD0 (%d tri)"
			% [mesh_name, _tri_count(combined)])
		return {"levels": [], "warnings": warnings}
	var out: Array = []
	for k in chain.size():
		var lvl: ArrayMesh = chain[k]
		if lvl.get_surface_count() != combined.get_surface_count():
			break   # _lod_chain validates this; a mismatch here means a stale cache
		var m := ArrayMesh.new()
		for si in lvl.get_surface_count():
			# NORMALISE THE ATTRIBUTE SET AGAINST LOD0, exactly as _build_authored_chain
			# does, and for the same reason: a level may ship an attribute LOD0 lacks or
			# lack one it has, and `add_surface_from_arrays` then answers "Invalid array
			# format for surface": a printed error, not a failed call, so the mesh comes
			# back with zero surfaces and reads as a species with no geometry (two fir species
			# vanished this way).
			var src_arrays: Array = lvl.surface_get_arrays(si)
			var base: Array = (chain[0] as ArrayMesh).surface_get_arrays(si)
			var verts: PackedVector3Array = src_arrays[Mesh.ARRAY_VERTEX]
			var arrays: Array = []
			arrays.resize(Mesh.ARRAY_MAX)
			arrays[Mesh.ARRAY_VERTEX] = verts
			arrays[Mesh.ARRAY_INDEX] = src_arrays[Mesh.ARRAY_INDEX]
			for a in _CHAIN_ATTRS:
				if base[a] == null:
					continue
				var acc = _empty_like(a)
				_append_attr(acc, a, src_arrays[a], verts.size())
				arrays[a] = acc
			if foliage_surfaces.has(si):
				var idx = arrays[Mesh.ARRAY_INDEX]
				if idx != null and not (idx as PackedInt32Array).is_empty():
					arrays[Mesh.ARRAY_COLOR] = _card_colors(
						verts.size(), idx, arrays[Mesh.ARRAY_COLOR])
			m.add_surface_from_arrays(Mesh.PRIMITIVE_TRIANGLES, arrays)
			m.surface_set_name(si, lvl.surface_get_name(si))
		# A LEVEL THAT DID NOT REBUILD TRUNCATES THE CHAIN, IT DOES NOT SHIP EMPTY.
		# `add_surface_from_arrays` refuses a surface whose arrays it cannot use and
		# says so in the log without failing the call, so the level comes out with
		# fewer surfaces than it went in with, and Godot sizes an indirect MultiMesh's
		# command buffer from the surface count, so a level with none yields an INVALID
		# RID and takes the whole species' uniform set down with it (two fir species lost
		# their LOD2 this way and vanished entirely).
		if m.get_surface_count() != lvl.get_surface_count():
			warnings.append("%s LOD%d rebuilt %d of %d surfaces: chain truncated to %d level(s)"
				% [mesh_name, k, m.get_surface_count(), lvl.get_surface_count(), k])
			break
		m.resource_name = "%s_L%d" % [mesh_name, k]
		out.append(m)
	return {"levels": out, "warnings": warnings}


## The atlas rect a species' crown occupies, as (u0, v0, u1, v1).
##
## WHY A RECT AND NOT A COLOUR. One flat foliage colour averaged from the atlas texels
## on the CPU needs Image.get_image() on a 4096-square atlas, a call expensive enough to
## stall a headless probe for minutes, and it would run at chunk-resolve time while the
## player is driving.
##
## Handing the shader the atlas and the crown's UV rect is cheaper AND better: no
## CPU image access at all (this is array min/max), the impostor gets real texture
## instead of a flat wash, and its colour matches the mesh BY CONSTRUCTION because
## it is literally the same texels rather than an average of them.
##
## Single-surface meshes (the palms) split by height, same rule as everywhere else
## here: bottom third bark, top third canopy.
static func _crown_uv_rect(mesh_name: String) -> Vector4:
	return _prepared(mesh_name).get("crown_uv", Vector4(0.0, 0.0, 1.0, 1.0))


## The crown's atlas rect on `mesh` (the source LOD0) from its leaf surfaces `foliage`, the preparation's.
static func _crown_uv_of(mesh: ArrayMesh, foliage: PackedInt32Array) -> Vector4:
	var ab := mesh.get_aabb()
	var single := mesh.get_surface_count() <= 1
	var lo := Vector2(1e9, 1e9)
	var hi := Vector2(-1e9, -1e9)
	for si in range(mesh.get_surface_count()):
		if not single and not foliage.has(si):
			continue
		var arr := mesh.surface_get_arrays(si)
		var uv = arr[Mesh.ARRAY_TEX_UV]
		var vt = arr[Mesh.ARRAY_VERTEX]
		if uv == null or vt == null:
			continue
		var uvs: PackedVector2Array = uv
		var vts: PackedVector3Array = vt
		for i in range(mini(uvs.size(), vts.size())):
			if single:
				var f: float = (vts[i].y - ab.position.y) / maxf(ab.size.y, 0.001)
				if f < 0.66:
					continue
			lo = lo.min(uvs[i])
			hi = hi.max(uvs[i])
	if hi.x <= lo.x or hi.y <= lo.y:
		return Vector4(0.0, 0.0, 1.0, 1.0)
	return Vector4(lo.x, lo.y, hi.x, hi.y)


## An impostor card for species `id` (`sp` its ForestSpecies or null, `p` its preparation, `ring` its baked view ring or
## {}, `profile` its silhouette family): {"mesh": QuadMesh, "mat": ShaderMaterial}. Neither cached nor registered for
## the wind and the hand-over pushes: _billboard does both for the forest's own cards; the Species dialog's view draws
## one of its own.
static func card_of(id: String, sp, p: Dictionary, ring: Dictionary, profile: int) -> Dictionary:
	var height: float = maxf((p["aabb"] as AABB).size.y, 1.0)
	# COLOURS COME FROM THE ATLAS, NOT THE MATERIAL. A classification by the "greenness"
	# of `albedo_color` only works while meshes carry authored material colours. Stylised
	# packs often import UNTEXTURED with white materials, so every surface scores the same
	# and every impostor comes out WHITE: a hillside of white lollipops past
	# tree_visibility_m that turn green the moment they cross into mesh range.
	var crown: Vector4 = p.get("crown_uv", Vector4(0.0, 0.0, 1.0, 1.0))
	var atlas := _atlas_of(sp, true)
	var q := QuadMesh.new()
	var sm := ShaderMaterial.new()
	sm.shader = _billboard_shader_res()
	sm.resource_name = id

	# BAKED VIEW RING, when the species' pack is built (its built/ holds the impostor sheets).
	# The card must span the SAME world square the bake framed, or the tree renders
	# scaled and off its own trunk; so the span comes out of the bake's manifest
	# rather than being re-derived here from the AABB. Two derivations of one number
	# is how an impostor ends up beside the mesh it replaces.
	if not ring.is_empty():
		var span: float = float(ring["span"])
		q.size = Vector2(span, span)
		# CENTRE OFFSET STAYS ZERO and the lift is a shader uniform: see
		# `card_pivot_h` in tree_billboard.gdshader. A baked offset rides the card's
		# own up, which now tips to face the camera, so from above the tree would
		# slide off its trunk.
		sm.set_shader_parameter("card_pivot_h", height * 0.5)
		sm.set_shader_parameter("impostor_albedo", ring["albedo"])
		sm.set_shader_parameter("impostor_normal", ring["normal"])
		sm.set_shader_parameter("impostor_gbuffer", true)
		sm.set_shader_parameter("impostor_grid", int(ring["grid"]))
		sm.set_shader_parameter("impostor_cols", int(ring["cols"]))
		sm.set_shader_parameter("impostor_rows", int(ring["rows"]))
		# CROWN DOME EXTENT, out of the SAME entry `span` came from: two derivations
		# of one framing is how the dome ends up sized to a different tree than the
		# card is. A pre-`w`/`h` manifest leaves it at (1, 1), i.e. the dome spans the
		# whole card: wrong, but only softly (a flatter sun side), where guessing would
		# be wrong sharply.
		var rw: float = float(ring["w"])
		var rh: float = float(ring["h"])
		sm.set_shader_parameter("crown_extent", Vector2(
			span / rw if rw > 0.001 else 1.0,
			span / rh if rh > 0.001 else 1.0))
	else:
		q.size = Vector2(height * 0.62, height)
		sm.set_shader_parameter("card_pivot_h", height * 0.5)   # base sits at the pivot
		sm.set_shader_parameter("impostor_grid", 0)
	sm.set_shader_parameter("albedo_tex", atlas)
	sm.set_shader_parameter("crown_uv", crown)
	# Kept as the fallback the shader uses when no atlas resolves, so a pack without
	# one still gets a plausible tree rather than a white card.
	sm.set_shader_parameter("foliage", Color(0.24, 0.29, 0.10))
	sm.set_shader_parameter("trunk", Color(0.36, 0.23, 0.12))
	# THE SAME transmission colour the mesh foliage gets above, and it has to be the
	# same literal: this is the term that decides what a backlit hillside looks like,
	# and the mesh trees and their cards are the same hillside either side of the
	# hand-over.
	sm.set_shader_parameter("backlight_col", Color(0.10, 0.14, 0.05))
	sm.set_shader_parameter("profile", profile)
	return {"mesh": q, "mat": sm}


## Impostor card + material for a species: a QuadMesh sized to the tree's real
## height (base at the pivot) and a billboard ShaderMaterial carrying the
## foliage/trunk colours + silhouette profile. Cached; shares the wind feed.
static func _billboard(mesh_name: String) -> Dictionary:
	if _billboard_cache.has(mesh_name):
		return _billboard_cache[mesh_name]
	var p := _prepared(mesh_name)
	if p.is_empty():
		_billboard_cache[mesh_name] = {}
		return {}
	_ensure_packs()
	var out := card_of(mesh_name, _species.get(mesh_name), p, _impostor_ring(mesh_name), _profile_of(mesh_name))
	_live_materials.append(out["mat"])
	_billboard_cache[mesh_name] = out
	return out


## What the Species dialog's view draws of species `sp` (its pack built in `dir`, whose built.json is `man`): its
## preparation (the built one when built.json lists it at this PREP_VERSION and its file loads, else prepared now:
## MAIN THREAD), its combined mesh and each authored level dressed with the species' own materials, its baked ring (the
## last bake's, current or not) and its card (none for a bush). {} when it has no mesh. Nothing is cached or
## registered: the dialog's edits must show, and the forest's caches must not hold them.
static func view_parts(sp, dir: String, man: Dictionary) -> Dictionary:
	if sp == null:
		return {}
	var id := String(sp.id)
	var p := {}
	var e: Dictionary = (man.get("species", {}) as Dictionary).get(id, {})
	var path := dir.path_join(id + ".res") if dir != "" else ""
	if not e.is_empty() and int(e.get("prep_version", -1)) == PREP_VERSION and path != "" and ResourceLoader.exists(path):
		var b = ResourceLoader.load(path, "", ResourceLoader.CACHE_MODE_REPLACE)
		if b != null and b.has_method("to_prepared"):
			p = b.to_prepared()
	var built := not p.is_empty()
	if not built:
		p = prepare_species_of(sp)
	if not p.has("combined"):
		return {}
	var combined := (p["combined"] as ArrayMesh).duplicate() as ArrayMesh
	_dress(sp, combined, p, false)
	var levels := []
	for m in p.get("levels", []):
		var lm := (m as ArrayMesh).duplicate() as ArrayMesh
		for si in lm.get_surface_count():
			lm.surface_set_material(si, combined.surface_get_material(si))
		levels.append(lm)
	if levels.is_empty():
		levels = [combined]
	var ring := ring_at(dir, id, man)
	var card := {} if String(sp.kind) == "bush" else card_of(id, sp, p, ring, crown_profile(String(sp.crown)))
	return {"prepared": p, "built": built, "combined": combined, "levels": levels, "ring": ring, "card": card,
		"warnings": p.get("warnings", PackedStringArray())}


## A pack's built.json, read once: {"bake": {grid, cols, rows, …}, "species": {id: {span, w, h, …}}};
## {} for a pack that is not built (or not a file).
static var _manifests: Dictionary = {}    # built dir -> Dictionary
static var _ring_cache: Dictionary = {}


static func _manifest(dir: String) -> Dictionary:
	if dir == "":
		return {}
	if not _manifests.has(dir):
		var p := dir.path_join("built.json")
		var j: Variant = JSON.parse_string(FileAccess.get_file_as_string(p)) if FileAccess.file_exists(p) else null
		_manifests[dir] = j if j is Dictionary else {}
	return _manifests[dir]


## The built folder of a species' pack; "" when its pack is not a file, or no pack has it.
static func built_dir_of(mesh_name: String) -> String:
	_ensure_packs()
	var p = _pack_of.get(mesh_name)
	return p.built_dir() if p != null else ""


## A species' entry in its pack's built.json; {} when it has none.
static func built_entry(mesh_name: String) -> Dictionary:
	return (_manifest(built_dir_of(mesh_name)).get("species", {}) as Dictionary).get(mesh_name, {})


## A species' far palette colour from its pack's build (read from the stored bake): [Color], or [null] when the
## build had none (a bake that rendered nothing); [] when built.json does not say, and the palette reads the bake
## back from the GPU.
static func built_crown_colour(mesh_name: String) -> Array:
	var e := built_entry(mesh_name)
	if not e.has("crown_colour"):
		return []
	var c = e["crown_colour"]
	if typeof(c) == TYPE_ARRAY and (c as Array).size() >= 3:
		return [Color(float(c[0]), float(c[1]), float(c[2]))]
	return [null]


## The baked view ring of species `id` in built folder `dir` (`man` its built.json), or {} when that folder holds none:
## the sheets as textures (loaded REPLACING a cached copy) and the bake's framing. Uncached: _impostor_ring caches it
## per species for the forest; the Species dialog's view reads a fresh build.
static func ring_at(dir: String, id: String, man: Dictionary) -> Dictionary:
	var bake: Dictionary = man.get("bake", {})
	var e: Dictionary = (man.get("species", {}) as Dictionary).get(id, {})
	var a := dir.path_join(id + "_albedo.res")
	var n := dir.path_join(id + "_normal.res")
	if dir == "" or not e.has("span") or int(bake.get("grid", 0)) <= 0 \
			or not ResourceLoader.exists(a) or not ResourceLoader.exists(n):
		return {}
	return {
		"albedo": _sheet(a),
		"normal": _sheet(n),
		"grid": int(bake["grid"]),
		"cols": int(bake.get("cols", bake["grid"])),
		"rows": int(bake.get("rows", bake["grid"])),
		# The card spans the SAME world square the bake framed (`span`), the tree's own extent inside it (`w`, `h`):
		# the card shader places its crown dome on the tree, not on the card.
		"span": float(e["span"]),
		"w": float(e.get("w", 0.0)),
		"h": float(e.get("h", 0.0)),
	}


## The baked view ring of a species (its pack's build bakes it), or {} if it has none: the procedural
## silhouette is the fallback, a downgrade rather than a black card. The G-buffer pair: premultiplied albedo with the
## crown occlusion baked in, the normal the mesh is lit with and its transmission weight. Loaded REPLACING a cached copy:
## a rebuild in an open editor writes over the files.
static func _impostor_ring(mesh_name: String) -> Dictionary:
	if not _rings_enabled:
		return {}
	if _ring_cache.has(mesh_name):
		return _ring_cache[mesh_name]
	var dir := built_dir_of(mesh_name)
	var out := ring_at(dir, mesh_name, _manifest(dir))
	_ring_cache[mesh_name] = out
	return out


## A baked sheet as a texture: the pack build saves an Image (the same bytes whoever built it), made a texture here; a
## texture saved as one is taken as it is.
static func _sheet(path: String) -> Texture2D:
	var res := ResourceLoader.load(path, "", ResourceLoader.CACHE_MODE_REPLACE)
	return ImageTexture.create_from_image(res) if res is Image else res as Texture2D


## The procedural card silhouette's family of crown `crown`: 0 broadleaf, 1 conifer, 2 palm.
static func crown_profile(crown: String) -> int:
	match crown:
		"conifer":
			return 1
		"palm":
			return 2
	return 0


## The procedural card silhouette's family of species `mesh_name`: 0 broadleaf, 1 conifer, 2 palm (its `crown`).
static func _profile_of(mesh_name: String) -> int:
	var sp = _species_entry(mesh_name)
	return crown_profile(String(sp.crown) if sp != null else "broadleaf")
