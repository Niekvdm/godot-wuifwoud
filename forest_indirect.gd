# Copyright (c) 2026 Digitzone
# SPDX-License-Identifier: MIT
@tool
class_name ForestIndirect
extends Node3D
## GPU-driven vegetation: one instance arena per SPECIES, sorted into distance bands by
## a compute shader every frame and drawn with INDIRECT MultiMeshes.
##
## THE PROBLEM IT SOLVES. The per-chunk path makes one MultiMeshInstance3D per (64 m
## chunk x species). On a 50 km² island that is 3 699 drawables for 29 511 plants (about
## eight instances per drawable), and 2 131 of them are bushes. Godot then pays a cull,
## an LOD pick and a submit per drawable for groups of eight, and building one costs
## ~8 ms of `add_child` while the ring streams (52.7 s of first fill, 29.3 s of it on
## the main thread). Here the ring is one arena per species; the draw count is
## species x bands, and the arena is written once and never re-nodes.
##
## WHAT INDIRECT BUYS. The instance count of a draw lives in a GPU buffer
## (`RenderingServer.multimesh_get_command_buffer_rd_rid`), so the compute shader that
## compacts instances into a band can also decide how many that band draws: no
## readback, no CPU sync, nothing per-frame on the main thread but a camera position.
## `use_indirect` is only reachable through `multimesh_allocate_data`, not through the
## MultiMesh resource, so these are raw RenderingServer instances rather than nodes,
## which is also why the `add_child` cost disappears.
##
## PER-INSTANCE LOD, NOT PER-CHUNK. A band carries one mesh, so the band boundaries are
## the pack's authored LOD switch distances (ForestAssets.LOD_SWITCH_M) and each
## band draws that level's mesh (ForestAssets._species_lod_meshes). A tree 14 m away
## draws LOD0 and one 16 m away draws LOD1, instead of a whole 64 m chunk taking the
## level its centre earns. The band list is split once more at the shadow ring so near
## bands cast and far bands do not: the per-chunk shadow ring, at instance precision.
##
## THIS IS NOT A REBUTTAL OF "DRAWABLE COUNT IS NOT THE LEVER". That measurement stands:
## cutting 36 % of the drawables by dropping bush species changed nothing, so drawable
## count ALONE does not price the frame. What this changes as well is the LOD
## granularity, the fill cost and the shadow ring, and it must be judged on the frame it
## produces, not on the draw count it reports.
##
## FALLBACK. Everything here needs a RenderingDevice. Headless has none, so `available()`
## is false there and the spawner keeps its per-chunk path, which is also the path
## every headless test exercises.
##
## THE ARENA'S DATA PLANE IS NATIVE: each species' instance buffer, free
## list, block table and dirty ranges live in a WfArena from the forest's native core (made by
## WfCore.make_arena, reached by name through forest_native.gd and held untyped), so an install
## is one memcpy, a release one strided memset, and a frame's uploads leave as bytes. Without the
## core `available()` is false. Meshes, bands, the render-thread buffers, the frame message and
## the Hi-Z builder stay here.

## The species' assets: meshes, materials, LOD levels.
const ForestAssets := preload("res://addons/wuifwoud/forest_assets.gd")
## The forest's log, through its sink.
const ForestLog := preload("res://addons/wuifwoud/forest_log.gd")
## The native core, reached by class name (its WfArena holds every arena's data).
const ForestNativeRes := preload("res://addons/wuifwoud/forest_native.gd")
## The cull compute shader.
const CULL_SHADER := "res://addons/wuifwoud/shaders/wf_cull.glsl"

## Must match MAX_BINS in wf_cull.glsl: the shader has one output binding per band.
const MAX_BINS := 6
## The two things this path draws. A species name is NOT unique across them (every
## mesh tree with a bake has an impostor card of the same name), so the arena is keyed
## by (tier, name) and the tier decides mesh, bands, shadows and buffer format.
const TIER_MESH := 0
## The impostor tier (see TIER_MESH).
const TIER_CARD := 1
## A MESH-TIER ARENA STARTS AT THIS MANY INSTANCES: growing one rebuilds every LOD band's MultiMesh in one frame
## (2-5 ms, measured), and no mesh arena grew past 8192 on a drive from farmland into a forest. About 0.45 KB of
## GPU memory an instance (the source buffer and one MultiMesh a band).
const MESH_MIN_CAP := 8192
## Floats per instance: Godot's TRANSFORM_3D is 12, plus one four-float attribute (custom data on a mesh tier, the
## colour on a card).
const STRIDE := 16
## Instances past a band's capacity are DROPPED, not wrapped. Capacity is the arena's,
## so the drop can only happen if every instance of a species falls in one band, which
## is exactly the case the arena is sized for: the guard is against corruption, not a
## budget.
const _AABB_MOVE_M := 12.0
## How far past a band's outer edge its AABB reaches: the deepest instance's own mesh
## extends beyond its origin, and the box is re-fitted only every `_AABB_MOVE_M`.
const _AABB_PAD_M := 70.0
## Push-constant size: two vec4 of band boundaries, one vec4 of species scalars, two
## uvec4 of counts. Vulkan only guarantees 128 bytes, which is why the camera and the
## six frustum planes live in a shared buffer instead.
const PUSH_BYTES := 80
## Bytes of the shared Globals buffer: camera (vec4) + six frustum planes (vec4 each).
## cam, thin_cam, 6 frustum planes, the previous frame's view-projection (4) and the Hi-Z
## parameters: 13 vec4. Must match the Globals block in wf_cull.glsl exactly.
const GLOBALS_BYTES := 13 * 16
## How far the camera must move before the THINNING camera follows it. Thinning is a
## hard cut with no fade, so re-evaluating it against an exact camera every frame makes
## every card on the threshold flicker whenever the camera moves, worst while climbing,
## because altitude moves every card's distance at once. Stepping it restores what the
## per-cell path did by accident: re-thin rarely, in one discrete jump.
const THIN_MOVE_M := 40.0
## One LEVEL-1 block: a bounding sphere (vec4) plus the arena slice it owns (vec4).
## Must match `struct Block` in wf_cull.glsl.
const BLOCK_FLOATS := 8
## Bytes of one block.
const BLOCK_BYTES := BLOCK_FLOATS * 4
## Blocks the table is sized for to begin with; it doubles from there. The shader walks
## any count in batches, so this is an allocation step, not a limit.
const MIN_BLOCKS := 256
## Dirty ranges uploaded per frame. Each is one `buffer_update` of a few kilobytes;
## the rest wait for the next frame rather than stalling this one.
const UPLOADS_PER_FRAME := 96
## A committed block is SPLIT into clusters of at most this many instances.
##
## A block is whatever one commit handed over: a 64 m mesh chunk (tens of instances,
## already tight) or a 1024 m impostor cell (ten thousand cards, bounding sphere ~750 m,
## which rejects nothing near the camera and would make level 1 worth almost nothing). The
## card buffers arrive in Z-ORDER (the native place's), so a contiguous
## run of them is a contiguous patch of ground and splitting on a fixed stride gives
## clusters a few tens of metres across for free: no spatial structure to build, no
## second pass over the data.
const BLOCK_SPLIT := 256

## Set by the spawner before the first block lands: the multiplier on the authored LOD switch distances.
var lod_bias: float = 1.0
## Bands nearer than this cast shadows (the spawner's tree_shadow_ring_m).
var shadow_ring_m: float = 200.0
## Shadows off silences every species (the spawner's tree_shadows).
var shadows_enabled: bool = true
## mesh name -> cut distance in metres. The spawner owns the policy (species size, tree
## vs bush); this only needs the answer.
var cut_of: Callable = Callable()
## The impostor band, and its distance thinning. Set by the spawner from
## `tree_visibility_m - _BILLBOARD_OVERLAP`, `billboard_far_m`, `card_thin_start_m` and
## `card_thin_max`; the shader thins per card rather than per 1024 m cell.
var card_near_m: float = 260.0
## Where the impostor band ends.
var card_far_m: float = 2600.0
## Where the card thinning starts.
var card_thin_start_m: float = 1200.0
## The share of cards dropped at card_far_m.
var card_thin_max: float = 0.55
## Survivors of the thinning grow (tree_billboard.gdshader `thin_compensate`), so the cull
## sphere has to hold the largest card the shader can draw, or a grown card at the edge of
## the screen is culled while its quad still reaches into view.
var card_thin_compensate: bool = false

var _ok := false
var _init_done := false
## Species whose arena refused a block: said once each.
var _refused := {}
## THE PACING: at most this many arenas (re)build their GPU side in one update (a new species, a regrow, a
## reservation); the rest wait in the deltas for the next frames. 0: no limit. The forest sets 1 while driving (the
## ring can meet a dozen species in one step, each a mesh arena of MESH_MIN_CAP: 22 ms in one frame, measured) and 0
## while it fills.
var realloc_limit := 0
## The next update takes every rebuild at once, then clears (the forest's fill-end reserve: its rebuilds land inside the
## fill).
var realloc_free_once := false
var _sp: Dictionary = {}          # mesh name -> arena (main thread WRITES; workers
								  # READ frozen fields under _sp_mx: see plan_block)
## Guards the STRUCTURE of `_sp` only (insert/lookup/clear): species creation and
## clear_all run on the main thread while place jobs plan blocks on workers. Never
## held around the O(n) work: that touches job-private buffers and frozen fields.
var _sp_mx := Mutex.new()
var _gpu: Dictionary = {}         # mesh name -> GPU mirror (RENDER thread only)
var _shader := RID()
var _pipeline := RID()
## OCCLUSION CULLING SEAM, default OFF. The pyramid is a frame stale by construction, so
## the failure mode is holes in the world when the camera turns, not something to have on
## by default before it has been looked at in motion. `VEG_OCCLUSION=1` in the environment,
## or set this from a probe.
var occlusion_cull := OS.get_environment("VEG_OCCLUSION") == "1"
## The editor's forest: never installs the Hi-Z builder; it appends to the scene's WorldEnvironment
## compositor, which a scene save would store.
var editor := false
## The camera the cull's frustum comes from; null: the viewport's. The editor's forest hands it Terrain3D's editor camera
## (the edited scene's viewport camera is the scene's own, or none, and no frustum culls nothing).
var camera: Camera3D = null
## PRELOADED, NOT BY class_name. A newly added `class_name` only resolves once the editor has
## rewritten its global class cache, and until then every script referencing it fails to parse
## ("Identifier ForestHizPyramid not declared in the current scope") in the editor while running
## fine from the command line. A preload has no such dependency.
const HizPyramidRef := preload("res://addons/wuifwoud/forest_hiz_pyramid.gd")
var _hiz_set := RID()
var _hiz_tex_seen := RID()
## Binding 0 of set 1 must ALWAYS resolve to something valid: Godot rejects a uniform set
## containing an invalid RID outright, which would take the whole cull down rather than just
## disabling the test. A 1x1 texture of 0.0 reads as the far plane, so every comparison says
## "not occluded" and the shader's own `hiz.w = 0` gate never even reaches it.
var _hiz_dummy := RID()
var _hiz_dummy_sampler := RID()
## Camera + frustum planes, one buffer for every species, rewritten once a frame.
var _globals := RID()
var _scenario := RID()
var _cam := Vector3.ZERO
var _aabb_at := Vector3(1e18, 1e18, 1e18)
var _thin_at := Vector3(1e18, 1e18, 1e18)
## For tools and tests: timestamp the cull pass. OFF because it is an instrument, not a feature: the labels
## show up in the engine profiler, and with more than one field on this path two
## instances captured under the SAME names would have the profiler's intervals span
## each other's work and `cull_gpu_us` read whichever pair it found first. Names are per
## instance, and nothing is captured unless this is set.
var debug_cull_timing := OS.get_environment("VEG_CULL_TIMING") == "1"
var _ts_a := "wf_cull_a"
var _ts_b := "wf_cull_b"
var _deltas: Dictionary = {}      # mesh name -> pending delta for the next frame
var _live := false
## For tools and tests: GPU microseconds the cull pass took, last frame it was measured
## (debug_cull_timing). Read by the vegetation rig; the viewport's own `gpu` figure does NOT include this pass, which is
## how moving the impostor tier into the arena managed to lower the reported GPU time
## and raise the frame at the same time.
var cull_gpu_us := 0.0
var _ts_frame := 0


func _ready() -> void:
	# RenderingServer.get_rendering_device() is null under --headless (dummy renderer):
	# that is the whole availability test, and it is why the spawner keeps its per-chunk
	# path for tests.
	# The arena is native: without the core the GPU path is not there, and a caller takes its fallback.
	_ok = RenderingServer.get_rendering_device() != null and ResourceLoader.exists(CULL_SHADER) \
		and ForestNativeRes.available()
	if not _ok:
		return
	_scenario = get_world_3d().scenario
	_ts_a = "cull_a_" + name
	_ts_b = "cull_b_" + name
	var f = load(CULL_SHADER)
	if f == null or not (f is RDShaderFile):
		ForestLog.warn("[VegIndirect] %s did not load as an RDShaderFile" % CULL_SHADER)
		_ok = false
		return
	# Compile on the render thread with the buffers it will later own. `_live` is the
	# flag `update()` reads; a frame or two of `false` at boot costs nothing.
	RenderingServer.call_on_render_thread(_rt_init.bind(f))


## Whether the GPU-driven path runs: a RenderingDevice and the native core (false headless).
func available() -> bool:
	return _ok


## ── Band planning ────────────────────────────────────────────────────────────
## PURE, AND SEPARATE FROM THE GPU, so it can be tested headless where none of the rest
## of this file can run. `switches` are the authored LOD switch distances already
## scaled by `lod_bias`; `levels` is how many meshes the species actually has.
##
## The result is contiguous and gapless from 0 to `cut_m`: a gap is a ring of missing
## trees, and one at a LOD boundary would be invisible in code and obvious on screen.
static func plan_bins(cut_m: float, switches: Array, shadow_ring_m: float,
		levels: int, max_bins: int = MAX_BINS) -> Array:
	if cut_m <= 0.0 or levels <= 0:
		return []
	var bounds: Array[float] = [0.0]
	for s in switches:
		var v := float(s)
		if v > 0.0 and v < cut_m:
			bounds.append(v)
	if shadow_ring_m > 0.0 and shadow_ring_m < cut_m:
		bounds.append(shadow_ring_m)
	bounds.append(cut_m)
	bounds.sort()
	# Dedup at half a metre: two boundaries closer than that are one boundary, and an
	# empty band would still cost a draw call and an output buffer.
	var uniq: Array[float] = []
	for b in bounds:
		if uniq.is_empty() or b - uniq[uniq.size() - 1] > 0.5:
			uniq.append(b)
	# Too many bands: drop boundaries from the FAR end inward. The near ones are the
	# LOD switches that matter (15/40/110 m carry most of the triangle saving) and the
	# far ones only refine shadow casting nobody sees.
	while uniq.size() - 1 > max_bins:
		uniq.remove_at(uniq.size() - 2)
	var out: Array = []
	for i in uniq.size() - 1:
		var d0: float = uniq[i]
		var lod := 0
		for s in switches:
			if d0 >= float(s) - 0.5:
				lod += 1
		out.append({
			"d0": d0,
			"d1": uniq[i + 1],
			"lod": mini(lod, levels - 1),
			"casts": d0 < shadow_ring_m or shadow_ring_m <= 0.0,
		})
	return out


func _cut_for(mesh_name: String) -> float:
	if cut_of.is_valid():
		return float(cut_of.call(mesh_name))
	return 350.0


## The arena for a species, created on first use. Band layout, meshes and surface count
## are fixed here: a species' geometry does not change at runtime. MAIN THREAD ONLY:
## creation mutates assets and bins; workers reach a species through plan_block's
## mutexed lookup and read only fields frozen here.
func _species(mesh_name: String, tier: int) -> Dictionary:
	var key := "%d/%s" % [tier, mesh_name]
	_sp_mx.lock()
	var hit: Dictionary = _sp.get(key, {})
	_sp_mx.unlock()
	if not hit.is_empty():
		return hit
	if tier == TIER_CARD:
		var sc := _card_species(key, mesh_name)
		_sp_mx.lock()
		_sp[key] = sc
		_sp_mx.unlock()
		return sc
	var meshes: Array = ForestAssets._species_lod_meshes(mesh_name)
	var switches: Array = []
	for s in ForestAssets.LOD_SWITCH_M:
		switches.append(float(s) * maxf(lod_bias, 0.01))
	var bins := plan_bins(_cut_for(mesh_name), switches, shadow_ring_m, maxi(meshes.size(), 1))
	# Bushes never cast: the same rule as the per-chunk path (_add_tree_mmi), and for the
	# same reason: an understory tuft's shadow is alpha-card FILL in four cascades for a
	# smudge nobody sees. `tree_shadows` off silences every species.
	if not shadows_enabled or ForestAssets.is_bush_mesh(mesh_name):
		for b in bins:
			(b as Dictionary)["casts"] = false
	var surfaces := 1
	if not meshes.is_empty() and meshes[0] != null:
		surfaces = maxi((meshes[0] as Mesh).get_surface_count(), 1)
	var cast_mask := 0
	for i in bins.size():
		if bool((bins[i] as Dictionary)["casts"]):
			cast_mask |= 1 << i
	var sp := {
		"key": key,
		"name": mesh_name,
		"tier": TIER_MESH,
		"stride": STRIDE,
		"custom": true,
		"radius": ForestAssets.species_radius(mesh_name),
		"cast_mask": cast_mask,
		"colors": false,
		"gi": true,
		"material": RID(),
		"thin_start": 0.0,
		"thin_max": 0.0,
		"bins": bins,
		"meshes": meshes,
		"surfaces": surfaces,
	}
	sp.merge(_arena_state(STRIDE))
	if sp.has("arena"):
		sp["arena"].reserve(MESH_MIN_CAP)
	_sp_mx.lock()
	_sp[key] = sp
	_sp_mx.unlock()
	return sp


## The impostor tier's arena. ONE BAND, because a card has one mesh and no LOD chain:
## the band is simply the impostor's range, and its inner edge replaces the per-cell
## `visibility_range_begin` with a per-card test. Cards never cast, carry their colour
## in COLOR rather than custom data (the shader reads `COLOR.rgb`/`COLOR.a`), and take
## their material as an instance override because the QuadMesh has none.
func _card_species(key: String, mesh_name: String) -> Dictionary:
	var bb: Dictionary = ForestAssets._billboard(mesh_name)
	var meshes: Array = []
	var mat := RID()
	if not bb.is_empty():
		meshes = [bb["mesh"]]
		mat = (bb["mat"] as Material).get_rid()
	var far: float = maxf(card_far_m, card_near_m + 1.0)
	var sc := {
		"key": key,
		"name": mesh_name,
		"tier": TIER_CARD,
		"stride": STRIDE,
		"custom": false,
		"radius": ForestAssets.card_radius(mesh_name) * (1.0 / sqrt(clampf(
			1.0 - card_thin_max, 0.1, 1.0)) if card_thin_compensate else 1.0),
		"cast_mask": 0,
		"colors": true,
		"gi": false,
		"material": mat,
		"thin_start": card_thin_start_m,
		"thin_max": clampf(card_thin_max, 0.0, 1.0),
		"bins": [{"d0": maxf(card_near_m, 0.0), "d1": far, "lod": 0, "casts": false}],
		"meshes": meshes,
		"surfaces": 1,
	}
	sc.merge(_arena_state(STRIDE))
	return sc


## A new species' arena: a native WfArena (the core's make_arena, growing), held untyped; none without the core (the
## node is then not available()).
func _arena_state(stride: int) -> Dictionary:
	var core = ForestNativeRes.core()
	var arena = core.make_arena(stride, 0) if core != null else null
	return {"arena": arena} if arena != null else {}


## ── Arena ────────────────────────────────────────────────────────────────────
## The WORKER-SIDE half of add_block: the O(n) geometry passes over the block's own
## packed buffer, which the place job already holds. Returns the cluster table the
## main-thread install will write, so the commit costs an offset allocation and a
## handful of bookkeeping writes instead of two per-instance interpreted walks.
##
## READS ONLY FROZEN STATE: the species' stride and radius, fixed at build. The
## `_sp` lookup is mutexed (species creation and clear_all are main-thread); past
## the lookup everything touches job-private data, so the lock is never held around
## the walk. {} when the species is not built YET: the first block of a species
## plans nothing and the install computes the walk itself; the fallback lives in
## add_block for exactly that case. A species cleared by a quality rebuild mid-job
## reads as absent too, and the spawner drops that job's result by identity anyway.
func plan_block(mesh_name: String, tier: int, buf: PackedFloat32Array, n: int) -> Dictionary:
	var key := "%d/%s" % [tier, mesh_name]
	_sp_mx.lock()
	var sp: Dictionary = _sp.get(key, {})
	_sp_mx.unlock()
	if sp.is_empty():
		return {}
	var stride := int(sp.get("stride", STRIDE))
	var reach := float(sp["radius"]) * 1.5
	return {
		"key": key,
		"stride": stride,
		"clusters": _plan_walk(buf, n, stride, reach),
	}


## Clusters of at most BLOCK_SPLIT instances, each as [cx, cy, cz, radius, rel, n]
## where `rel` is the cluster's offset RELATIVE TO THE BLOCK; the install adds the
## block's arena offset. The native core's walk (WfCore.plan_walk, the one the arena and
## the place kernel use); static and buffer-local, so a worker may run it.
## The sphere must contain the GEOMETRY, not the origins: `reach` carries the
## species' radius past each origin. Empty without the core.
static func _plan_walk(buf: PackedFloat32Array, n: int, stride: int, reach: float) -> Array:
	var out: Array = []
	var core = ForestNativeRes.core()
	if core == null:
		return out
	var w: PackedFloat32Array = core.plan_walk(buf, n, stride, reach)
	for i in range(0, w.size(), 6):
		out.append([w[i], w[i + 1], w[i + 2], w[i + 3], int(w[i + 4]), int(w[i + 5])])
	return out


## Take `n` instances of `mesh_name`, already packed in Godot's MultiMesh layout, and
## return a handle to free them by. First fit over the free list, then the high-water
## mark; capacity doubles when neither serves.
##
## `plan` is what plan_block computed on the worker for this same buffer: when it is
## valid (same species, same stride) the cluster walk is skipped here. Without one
## (the first block of a species, the main-thread fallback paths, any direct caller)
## the walk runs in place.
func add_block(mesh_name: String, buf: PackedFloat32Array, n: int,
		tier: int = TIER_MESH, plan: Dictionary = {}) -> Dictionary:
	if not _ok or n <= 0:
		return {}
	var sp := _species(mesh_name, tier)
	if (sp["meshes"] as Array).is_empty() or (sp["bins"] as Array).is_empty():
		return {}
	if not sp.has("arena"):
		return {}
	# The place kernel's clusters come without the species' reach, which the install adds; plan_block's
	# carry it already. Neither: the arena walks the buffer itself.
	var reach := float(sp["radius"]) * 1.5
	var clusters := PackedFloat32Array()
	var pc = plan.get("clusters", null)
	if pc is PackedFloat32Array:
		clusters = pc
	elif pc is Array and str(plan.get("key", "")) == str(sp["key"]) and int(plan.get("stride", -1)) == int(sp["stride"]):
		for cl in pc:
			clusters.append_array(PackedFloat32Array([cl[0], cl[1], cl[2], cl[3], cl[4], cl[5]]))
		reach = 0.0
	var h: Dictionary = sp["arena"].add(buf, n, clusters, reach)
	if h.is_empty():
		# Past the arena's limits, or a buffer shorter than n instances: the commit skips the slot.
		if not _refused.has(sp["key"]):
			_refused[sp["key"]] = true
			ForestLog.warn("[VegIndirect] %s: the arena refused a block of %d instances (%d floats)" % [
				sp["key"], n, buf.size()])
		return {}
	_deltas[sp["key"]] = true
	# The handle names its arena: one from before a clear_all frees nothing in the arena made after it.
	return {"sp": sp["key"], "off": int(h["off"]), "n": n, "arena": sp["arena"]}


## Release a block: zero it so the shader's liveness test (a zero basis column) rejects
## it, and give the slots back. Adjacent free blocks are NOT coalesced: the ring
## churns a chunk at a time, so a first-fit list of a few hundred entries never grows
## into anything a scan notices.
func free_block(h: Dictionary) -> void:
	if not _ok or h.is_empty() or not _sp.has(h.get("sp", "")):
		return
	var sp: Dictionary = _sp[h["sp"]]
	if not sp.has("arena"):
		return
	# A handle from before a clear_all names an arena that is gone: its offsets mean nothing in the one made since (the
	# spawner's rebuild_for_quality note: "add_block: Out of bounds set index 32768").
	if not is_same(h.get("arena"), sp["arena"]):
		return
	if sp["arena"].release(int(h["off"]), int(h["n"])):
		_deltas[sp["key"]] = true


## Every arena dropped, on both threads (a quality rebuild, after every cell was released).
func clear_all() -> void:
	_sp_mx.lock()
	_sp.clear()
	_sp_mx.unlock()
	_deltas.clear()
	if _ok:
		RenderingServer.call_on_render_thread(_rt_clear)


## The live instances across every arena.
func instance_count() -> int:
	var t := 0
	for k in _sp:
		var sp: Dictionary = _sp[k]
		t += int(sp["arena"].stats()["n"]) if sp.has("arena") else 0
	return t


## Drawables this path costs: one RenderingServer instance per species per band.
func drawable_count() -> int:
	var t := 0
	for k in _sp:
		t += (( _sp[k] as Dictionary)["bins"] as Array).size()
	return t


## ── Per frame ────────────────────────────────────────────────────────────────
## Snapshot whatever changed and hand it to the render thread with the camera. Nothing
## here touches a RenderingDevice: the arena bytes are COPIED into the message, because
## the render thread reads them while the main thread is free to keep committing chunks
## into the same arrays.
func update(cam: Vector3) -> void:
	if not _ok or not _live:
		return
	_cam = cam
	if occlusion_cull:
		_ensure_hiz_builder()
	var msg: Array = []
	var carry: Dictionary = {}
	var limit := 0 if realloc_free_once else realloc_limit
	realloc_free_once = false
	var reallocs := 0
	for name in _deltas:
		var sp: Dictionary = _sp[name]
		if limit > 0 and reallocs >= limit and _realloc_pending(sp):
			carry[name] = true   # its GPU side is rebuilt in a later frame (the pacing)
			continue
		var a := _take(sp)
		if bool(a["realloc"]):
			reallocs += 1
		var d := {
			"name": name,
			"n": int(a["n"]),
			"cap": int(a["cap"]),
			"surfaces": int(sp["surfaces"]),
			"radius": float(sp["radius"]),
			"cast_mask": int(sp["cast_mask"]),
			"colors": bool(sp["colors"]),
			"custom": bool(sp.get("custom", true)),
			"stride": int(sp.get("stride", STRIDE)),
			"gi": bool(sp["gi"]),
			"nblocks": int(a["nblocks"]),
			"material": sp["material"],
			"thin_start": float(sp["thin_start"]),
			"thin_max": float(sp["thin_max"]),
			"realloc": bool(a["realloc"]),
		}
		if bool(a["realloc"]):
			var meshes: Array = []
			for m in sp["meshes"]:
				meshes.append((m as Mesh).get_rid())
			d["meshes"] = meshes
			d["bins"] = sp["bins"]
			d["scenario"] = _scenario
		# A realloc replaces the block buffer too, so the whole table goes with it;
		# otherwise only the rows that moved.
		if not (a["rows"] as Array).is_empty():
			d["bups"] = a["rows"]
		d["bcap"] = int(a["bcap"])
		if not (a["ranges"] as Array).is_empty():
			d["ups"] = a["ranges"]
		if bool(a["more"]):
			carry[name] = true   # work left: this species must be visited again
		msg.append(d)
	_deltas.clear()
	for k in carry:
		_deltas[k] = true
	var refit := _cam.distance_to(_aabb_at) > _AABB_MOVE_M
	if refit:
		_aabb_at = _cam
	RenderingServer.call_on_render_thread(_rt_frame.bind(msg, _globals_bytes(), refit))


## A tier's arenas pre-sized at `mult` times their LIVE instances (both tiers when a fill ends, so the ring a drive
## brings in never forces a regrow; a regrow rebuilds the species' whole GPU side in one frame). Not the high-water:
## released holes stay in it, and reserving it compounds at every fill (a teleport doubled the card arenas,
## 122 → 224 MB, and the frames after it slowed). Each one that grows sends its realloc on the next update.
func reserve_tier(tier: int, mult: float) -> void:
	if not _ok:
		return
	for key in _sp:
		var sp: Dictionary = _sp[key]
		if int(sp["tier"]) != tier or not sp.has("arena"):
			continue
		var n := int(sp["arena"].stats()["live_n"])
		if n > 0 and sp["arena"].reserve(ceili(float(n) * mult)):
			_deltas[sp["key"]] = true


## The species' next uploads rebuild its GPU side (a new species, a regrow, a reservation).
func _realloc_pending(sp: Dictionary) -> bool:
	return sp.has("arena") and bool(sp["arena"].stats()["realloc"])


## One species' uploads for this frame, as bytes: its arena's take_uploads ({"ranges", "rows", "realloc", "n",
## "cap", "nblocks", "bcap", "more"}), at most UPLOADS_PER_FRAME ranges, the rest left for the next.
func _take(sp: Dictionary) -> Dictionary:
	if sp.has("arena"):
		return sp["arena"].take_uploads(UPLOADS_PER_FRAME)
	# A species made before a hot reload, in an editor still running the older library: nothing to send.
	return {"ranges": [], "rows": [], "realloc": false, "n": 0, "cap": 0, "nblocks": 0, "bcap": 0, "more": false}


## The 112 bytes the cull shader reads as `Globals`: camera, then six frustum planes
## with normals pointing INWARD.
##
## THE SIGN IS MEASURED, NOT ASSUMED. Godot's `Camera3D.get_frustum()` does not
## promise a normal direction anywhere the engine documents, and a flipped plane set
## culls everything that is on screen and keeps everything that is not, which looks
## exactly like a broken compute shader. A point known to be inside (just past the near
## plane, on the view axis) decides each plane's sign every frame, so the shader can
## have one rule and no convention to get wrong.
func _globals_bytes() -> PackedByteArray:
	var f := PackedFloat32Array()
	f.resize(GLOBALS_BYTES / 4)
	f[0] = _cam.x
	f[1] = _cam.y
	f[2] = _cam.z
	f[3] = 0.0
	if _cam.distance_to(_thin_at) > THIN_MOVE_M:
		_thin_at = _cam
	f[4] = _thin_at.x
	f[5] = _thin_at.y
	f[6] = _thin_at.z
	f[7] = 0.0
	# Hi-Z block. Written before the early return so a frame with no camera still leaves
	# the test disabled rather than reading whatever was in the buffer last frame.
	var hz = HizPyramidRef.shared()
	var on: bool = occlusion_cull and hz != null and hz.is_ready() and hz.built_frame >= 0
	if on:
		var vp: Projection = hz.view_projection
		for r in 4:
			# Projection indexes by COLUMN (vp[c][r]), and the shader rebuilds
			# mat4(col0, col1, col2, col3), which is also column-major. Writing rows here
			# would transpose the matrix and project everything through a mirror.
			f[32 + r * 4 + 0] = vp[r][0]
			f[32 + r * 4 + 1] = vp[r][1]
			f[32 + r * 4 + 2] = vp[r][2]
			f[32 + r * 4 + 3] = vp[r][3]
		f[48] = float(hz.size().x)
		f[49] = float(hz.size().y)
		f[50] = float(hz.mip_count())
		f[51] = 1.0
	else:
		f[51] = 0.0
	var cam := camera if camera != null and is_instance_valid(camera) else (
		get_viewport().get_camera_3d() if is_inside_tree() else null)
	if cam == null:
		return f.to_byte_array()
	var rows := frustum_rows(cam)
	for i in rows.size():
		f[8 + i] = rows[i]
	return f.to_byte_array()


## WHERE THE CULL MEASURES FROM: the camera as the renderer DRAWS it this frame.
##
## A game may interpolate physics. A camera moved in _physics_process is then drawn (and its
## get_frustum() built) from an interpolated transform up to a tick BEHIND
## global_transform (0.8 m at a 50 m/s climb). The draw shaders measure every tree's
## distance from MAIN_CAM_INV_VIEW_MATRIX, the drawn camera, so the bands and the
## hand-over must too, or the two sides of a crossfade disagree about where a tree is.
static func eye_of(cam: Camera3D) -> Vector3:
	return cam.get_camera_transform().origin


## The six frustum planes as the cull shader reads them: 24 floats, (normal, w) per plane,
## every normal pointing INWARD, so the shader's one rule is `dot(n, p) + w >= -r`.
##
## THE INSIDE POINT COMES FROM THE SAME TRANSFORM AS THE PLANES. A point taken 1.2 m ahead of
## global_position while the planes come from get_frustum() (the drawn camera, a tick behind)
## falls outside the drawn frustum's top or bottom plane when climbing faster than ~40 m/s;
## the plane is then flipped, and every tree and card on screen fails it: the whole forest
## vanishes on each frame drawn between two ticks, which reads as the forest flickering
## whenever the camera changes elevation fast. test_vegetation_view pins it.
static func frustum_rows(cam: Camera3D) -> PackedFloat32Array:
	var f := PackedFloat32Array()
	f.resize(24)
	var view := cam.get_camera_transform()
	var inside := view.origin - view.basis.z * (cam.near * 2.0 + 1.0)
	var planes := cam.get_frustum()
	for i in 6:
		var pl := Plane(0.0, 1.0, 0.0, -1e9)   # a plane nothing fails, if there are <6
		if i < planes.size():
			pl = planes[i]
			if pl.distance_to(inside) < 0.0:
				pl = Plane(-pl.normal, -pl.d)
		f[i * 4 + 0] = pl.normal.x
		f[i * 4 + 1] = pl.normal.y
		f[i * 4 + 2] = pl.normal.z
		# Godot's Plane is `dot(n, p) = d`; the shader tests `dot(n, p) + w >= -r`.
		f[i * 4 + 3] = -pl.d
	return f


func _exit_tree() -> void:
	if _ok:
		RenderingServer.call_on_render_thread(_rt_shutdown)


## ── Render thread ────────────────────────────────────────────────────────────
## EVERYTHING BELOW RUNS ON THE RENDER THREAD. RenderingDevice is not safe to touch
## from anywhere else when the renderer runs threaded, and `multimesh_get_*_rd_rid`
## returns RIDs that only mean anything there.
func _rt_init(f: RDShaderFile) -> void:
	var rd := RenderingServer.get_rendering_device()
	if rd == null:
		_ok = false
		return
	var spirv := f.get_spirv()
	if spirv == null:
		_ok = false
		return
	var err := spirv.compile_error_compute
	if err != "":
		ForestLog.error("[VegIndirect] cull shader failed to compile: %s" % err)
		_ok = false
		return
	_shader = rd.shader_create_from_spirv(spirv)
	if not _shader.is_valid():
		_ok = false
		return
	_pipeline = rd.compute_pipeline_create(_shader)
	if not _pipeline.is_valid():
		_ok = false
		return
	_globals = rd.storage_buffer_create(GLOBALS_BYTES)
	_init_done = true
	_live = true
	ForestLog.info("[VegIndirect] GPU cull ready (indirect MultiMesh, %d bands max)"
		% MAX_BINS)


func _rt_frame(msg: Array, globals: PackedByteArray, refit: bool) -> void:
	var rd := RenderingServer.get_rendering_device()
	if rd == null or not _init_done:
		return
	var cam := Vector3(globals.decode_float(0), globals.decode_float(4),
		globals.decode_float(8))
	rd.buffer_update(_globals, 0, globals.size(), globals)
	var made := false
	for d in msg:
		var before := _gpu.size()
		var g: Dictionary = _rt_species(rd, d)
		if g.is_empty():
			continue
		made = made or _gpu.size() != before or bool(d.get("realloc", false))
		g["n"] = int(d["n"])
		g["nblocks"] = int(d.get("nblocks", g.get("nblocks", 0)))
		for bu in d.get("bups", []):
			var bb: PackedByteArray = (bu as Array)[1]
			if bb.size() > 0:
				rd.buffer_update(g["blocks"], int((bu as Array)[0]), bb.size(), bb)
		# Buffer updates must not straddle a compute list, so every upload lands first.
		for u in d.get("ups", []):
			var b: PackedByteArray = (u as Array)[1]
			if b.size() > 0:
				rd.buffer_update(g["src"], int((u as Array)[0]), b.size(), b)
	if _gpu.is_empty():
		return
	# A species created this frame has no box yet: an unset custom AABB is empty, and
	# an empty AABB culls the instance away silently.
	if refit or made:
		_rt_refit(cam)
	# TIMESTAMP THE PASS. A capture is resolved a FRAME LATER: reading it in the frame
	# that took it returns nothing (a flat 0.00 ms). So the read comes first and reports
	# the previous frame.
	if debug_cull_timing:
		_read_cull_time(rd)
		rd.capture_timestamp(_ts_a)
	# The HiZ uniform set resolves BEFORE the list opens: when the pyramid's texture
	# changes (first ready frame, window resize) _rt_hiz_set frees and re-creates
	# the set; freeing/creating resources during compute-list construction is
	# forbidden, and a failed cascade would leave the list open so every later buffer op
	# errors ("Updating buffers is forbidden during creation of a compute list").
	var hiz: RID = _rt_hiz_set(rd)
	var cl := rd.compute_list_begin()
	for name in _gpu:
		var g: Dictionary = _gpu[name]
		if int(g["n"]) <= 0 or not (g["uset"] as RID).is_valid():
			continue
		rd.compute_list_bind_compute_pipeline(cl, _pipeline)
		rd.compute_list_bind_uniform_set(cl, g["uset"], 0)
		rd.compute_list_bind_uniform_set(cl, hiz, 1)
		rd.compute_list_set_push_constant(cl, _rt_push(g), PUSH_BYTES)
		# ONE WORKGROUP. The shader strides over the arena and syncs its band counters
		# in shared memory; see wf_cull.glsl for why that is the shape.
		rd.compute_list_dispatch(cl, 1, 1, 1)
	rd.compute_list_end()
	if debug_cull_timing:
		rd.capture_timestamp(_ts_b)


## Pick the two labels back out of whatever the frame captured. Godot resets the list
## each frame and other systems capture into it too, so the pass is found by NAME.
func _read_cull_time(rd: RenderingDevice) -> void:
	var a := -1.0
	var b := -1.0
	for i in rd.get_captured_timestamps_count():
		var nm := rd.get_captured_timestamp_name(i)
		if nm == _ts_a:
			a = float(rd.get_captured_timestamp_gpu_time(i))
		elif nm == _ts_b:
			b = float(rd.get_captured_timestamp_gpu_time(i))
	if a >= 0.0 and b > a:
		cull_gpu_us = (b - a) / 1000.0
	elif _ts_frame < 3:
		_ts_frame += 1
		ForestLog.debug("[VegIndirect] timestamps: %d captured, wf_cull_a=%.0f b=%.0f"
			% [rd.get_captured_timestamps_count(), a, b])


func _rt_push(g: Dictionary) -> PackedByteArray:
	var f := PackedFloat32Array()
	f.resize(12)
	var bins: Array = g["bins"]
	# Boundaries 0..bins: band i spans [edge(i), edge(i+1)), so there is one more
	# boundary than there are bands.
	for i in 8:
		var v := 0.0
		if i < bins.size():
			v = float((bins[i] as Dictionary)["d0"])
		elif i == bins.size() and not bins.is_empty():
			v = float((bins[bins.size() - 1] as Dictionary)["d1"])
		f[i] = v
	f[8] = float(g["radius"])
	f[9] = maxf(shadow_ring_m, 0.0)
	f[10] = float(g["thin_start"])
	f[11] = float(g["thin_max"])
	var u := PackedInt32Array()
	u.resize(8)
	u[0] = int(g["n"])
	u[1] = bins.size()
	u[2] = int(g["cap"])
	u[3] = int(g["surfaces"])
	u[4] = int(g["cast_mask"])
	u[5] = int(g.get("nblocks", 0))
	u[6] = int(g.get("stride", STRIDE)) / 4
	var out := f.to_byte_array()
	out.append_array(u.to_byte_array())
	return out


## Create or re-create a species' GPU side. A realloc frees everything and builds again
## rather than resizing in place: the uniform set names the buffers by RID, so a resized
## buffer is a new buffer and the set has to be rebuilt anyway.
func _rt_species(rd: RenderingDevice, d: Dictionary) -> Dictionary:
	var name: String = d["name"]
	if _gpu.has(name) and not bool(d.get("realloc", false)):
		return _gpu[name]
	if _gpu.has(name):
		_rt_free_species(rd, _gpu[name])
		_gpu.erase(name)
	var cap := int(d["cap"])
	var bins: Array = d.get("bins", [])
	var meshes: Array = d.get("meshes", [])
	if cap <= 0 or bins.is_empty() or meshes.is_empty():
		return {}
	var g := {
		"cap": cap,
		"n": int(d["n"]),
		"bins": bins,
		"surfaces": int(d["surfaces"]),
		"radius": float(d.get("radius", 8.0)),
		"cast_mask": int(d.get("cast_mask", 0)),
		"thin_start": float(d.get("thin_start", 0.0)),
		"thin_max": float(d.get("thin_max", 0.0)),
		"mm": [],
		"inst": [],
		"src": RID(),
		"uset": RID(),
	}
	var stride := int(d.get("stride", STRIDE))
	g["stride"] = stride
	g["src"] = rd.storage_buffer_create(cap * stride * 4)
	g["blocks"] = rd.storage_buffer_create(
		maxi(int(d.get("bcap", MIN_BLOCKS)), MIN_BLOCKS) * BLOCK_BYTES)
	g["nblocks"] = int(d.get("nblocks", 0))
	var dst: Array = []
	var cmd: Array = []
	for i in bins.size():
		var bin: Dictionary = bins[i]
		var mm := RenderingServer.multimesh_create()
		# use_indirect is the last argument and only exists here: the MultiMesh
		# RESOURCE has no such property, which is why these are raw RIDs.
		# COLOUR OR CUSTOM DATA, NEVER BOTH: the layout is the same 16 floats either
		# way and the flag decides which the shader reads. Mesh trees carry their tint
		# in INSTANCE_CUSTOM; impostor cards read COLOR.rgb and COLOR.a.
		var use_colors: bool = bool(d.get("colors", false))
		var use_custom: bool = bool(d.get("custom", not use_colors))
		RenderingServer.multimesh_allocate_data(mm, cap,
			RenderingServer.MULTIMESH_TRANSFORM_3D, use_colors, use_custom, true)
		var lvl := mini(int(bin["lod"]), meshes.size() - 1)
		RenderingServer.multimesh_set_mesh(mm, meshes[lvl])
		var inst := RenderingServer.instance_create2(mm, d["scenario"])
		RenderingServer.instance_geometry_set_cast_shadows_setting(inst,
			RenderingServer.SHADOW_CASTING_SETTING_ON if bool(bin["casts"])
			else RenderingServer.SHADOW_CASTING_SETTING_OFF)
		# The impostor QuadMesh carries no surface material; the per-chunk path puts the
		# card shader on the node as a material_override, so this does the same.
		var mat: RID = d.get("material", RID())
		if mat.is_valid():
			RenderingServer.instance_geometry_set_material_override(inst, mat)
		# IMPOSTORS ARE NOT GI GEOMETRY. A band's AABB is a box around the camera as wide
		# as the band reaches, and the impostor band reaches 2.6 km, so it would land in
		# every SDFGI cascade and ask the probe to consider half a million billboards
		# for a contribution the mesh trees in the same place already make. The
		# per-chunk path gets this for free: a 1024 m cell that a cascade does not touch
		# is simply not in it.
		if not bool(d.get("gi", true)):
			RenderingServer.instance_geometry_set_flag(inst,
				RenderingServer.INSTANCE_FLAG_USE_BAKED_LIGHT, false)
		(g["mm"] as Array).append(mm)
		(g["inst"] as Array).append(inst)
		var db: RID = RenderingServer.multimesh_get_buffer_rd_rid(mm)
		var cb: RID = RenderingServer.multimesh_get_command_buffer_rd_rid(mm)
		# GODOT SIZES THE COMMAND BUFFER FROM THE MESH'S SURFACE COUNT, so a mesh with
		# no surfaces yields a zero-byte buffer and an INVALID RID, and a uniform set
		# built on one is rejected wholesale ("must provide one ID"), which takes the
		# whole species down rather than the one band. Refuse the species here, where
		# the reason can be named.
		if not db.is_valid() or not cb.is_valid():
			ForestLog.warn("[VegIndirect] %s band %d/%d has no GPU buffers (mesh level %d of %d, rid_ok=%s, data_ok=%s): species skipped"
				% [name, i, bins.size(), lvl, meshes.size(),
					(meshes[lvl] as RID).is_valid(), db.is_valid()])
			for x in g["inst"]:
				RenderingServer.free_rid(x)
			for x in g["mm"]:
				RenderingServer.free_rid(x)
			rd.free_rid(g["src"])
			return {}
		dst.append(db)
		cmd.append(cb)
	# The shader declares MAX_BINS outputs whatever a species uses, so unused bindings
	# are filled with band 0's buffers. The dispatch guards on the band count, so they
	# are never written: a binding may alias, a write may not.
	while dst.size() < MAX_BINS:
		dst.append(dst[0])
		cmd.append(cmd[0])
	var uniforms: Array[RDUniform] = []
	uniforms.append(_rt_uniform(0, g["src"]))
	for i in MAX_BINS:
		uniforms.append(_rt_uniform(1 + i, dst[i]))
	for i in MAX_BINS:
		uniforms.append(_rt_uniform(7 + i, cmd[i]))
	uniforms.append(_rt_uniform(13, _globals))
	uniforms.append(_rt_uniform(14, g["blocks"]))
	g["uset"] = rd.uniform_set_create(uniforms, _shader, 0)
	_gpu[name] = g
	return g


## ── Hi-Z occlusion ───────────────────────────────────────────────────────────

## Put the depth-pyramid builder on the compositor the viewport actually renders with, once,
## and only when the seam is on: this reaches into a resource other systems own (a speed post effect
## keeps its motion blur there and mutates it during play), so it APPENDS to whatever is
## already present and never swaps the Compositor object.
var _hiz_builder: CompositorEffect = null

func _ensure_hiz_builder() -> void:
	if editor or _hiz_builder != null or not is_inside_tree():
		return
	var w := get_viewport().find_world_3d()
	var env: Environment = w.environment if w != null else null
	if env == null:
		return
	var host: WorldEnvironment = null
	var stack: Array = [get_tree().root]
	while not stack.is_empty():
		var n: Node = stack.pop_back()
		if n is WorldEnvironment and (n as WorldEnvironment).environment == env:
			host = n as WorldEnvironment
			break
		for c in n.get_children():
			stack.append(c)
	if host == null:
		return
	if host.compositor == null:
		host.compositor = Compositor.new()
	_hiz_builder = HizBuilder.new()
	var fx: Array[CompositorEffect] = host.compositor.compositor_effects.duplicate()
	fx.append(_hiz_builder)
	host.compositor.compositor_effects = fx
	ForestLog.debug("[VegIndirect] Hi-Z occlusion builder installed on %s" % host.name)

## Set 1 holds the depth pyramid and nothing else, so it can be rebuilt when the pyramid is
## (viewport resize) without touching the per-species sets, which are cached and expensive.
func _rt_hiz_set(rd: RenderingDevice) -> RID:
	var hz = HizPyramidRef.shared()
	var tex: RID = hz.texture() if (occlusion_cull and hz.is_ready()) else RID()
	var smp: RID = hz.sampler() if (occlusion_cull and hz.is_ready()) else RID()
	if not tex.is_valid():
		_rt_ensure_hiz_dummy(rd)
		tex = _hiz_dummy
		smp = _hiz_dummy_sampler
	if _hiz_set.is_valid() and tex == _hiz_tex_seen:
		return _hiz_set
	if _hiz_set.is_valid():
		rd.free_rid(_hiz_set)
		_hiz_set = RID()
	var u := RDUniform.new()
	u.uniform_type = RenderingDevice.UNIFORM_TYPE_SAMPLER_WITH_TEXTURE
	u.binding = 0
	u.add_id(smp)
	u.add_id(tex)
	_hiz_set = rd.uniform_set_create([u], _shader, 1)
	_hiz_tex_seen = tex
	return _hiz_set


func _rt_ensure_hiz_dummy(rd: RenderingDevice) -> void:
	if _hiz_dummy.is_valid():
		return
	var f := RDTextureFormat.new()
	f.format = RenderingDevice.DATA_FORMAT_R32_SFLOAT
	f.width = 1
	f.height = 1
	f.depth = 1
	f.array_layers = 1
	f.mipmaps = 1
	f.texture_type = RenderingDevice.TEXTURE_TYPE_2D
	# STORAGE as well as SAMPLING. Godot validates a uniform against what the SHADER
	# declares, and it rejects this one with "Image (binding: 0, index 0) needs the
	# TEXTURE_USAGE_STORAGE_BIT" every frame, for every species, which costs more in
	# error spam than the cull costs in work: 14 ms becomes 256.
	f.usage_bits = RenderingDevice.TEXTURE_USAGE_SAMPLING_BIT \
		| RenderingDevice.TEXTURE_USAGE_STORAGE_BIT \
		| RenderingDevice.TEXTURE_USAGE_CAN_UPDATE_BIT
	# 0.0 is the FAR plane in reverse-Z, so every comparison against it says "not behind
	# anything": the safe reading for a placeholder.
	var zero := PackedFloat32Array([0.0]).to_byte_array()
	_hiz_dummy = rd.texture_create(f, RDTextureView.new(), [zero])
	var ss := RDSamplerState.new()
	ss.min_filter = RenderingDevice.SAMPLER_FILTER_NEAREST
	ss.mag_filter = RenderingDevice.SAMPLER_FILTER_NEAREST
	ss.mip_filter = RenderingDevice.SAMPLER_FILTER_NEAREST
	ss.repeat_u = RenderingDevice.SAMPLER_REPEAT_MODE_CLAMP_TO_EDGE
	ss.repeat_v = RenderingDevice.SAMPLER_REPEAT_MODE_CLAMP_TO_EDGE
	_hiz_dummy_sampler = rd.sampler_create(ss)


## Fills the shared pyramid from the frame's depth. POST_OPAQUE because that is the first
## point at which opaque geometry (terrain and trees, the things that do the occluding) is
## in the depth buffer.
class HizBuilder extends CompositorEffect:
	var frames := 0
	func _init() -> void:
		effect_callback_type = CompositorEffect.EFFECT_CALLBACK_TYPE_POST_OPAQUE
		access_resolved_depth = true
		needs_motion_vectors = false
	func _render_callback(_kind: int, data: RenderData) -> void:
		var rd := RenderingServer.get_rendering_device()
		if rd == null or data == null:
			return
		var bufs := data.get_render_scene_buffers() as RenderSceneBuffersRD
		var sd := data.get_render_scene_data()
		if bufs == null or sd == null:
			return
		var depth := bufs.get_depth_texture()
		if not depth.is_valid():
			return
		frames += 1
		# The FULL view-projection, not the projection alone: the cull projects world-space
		# instance positions, so the camera has to be in the matrix.
		var vp: Projection = sd.get_cam_projection() * Projection(sd.get_cam_transform().affine_inverse())
		HizPyramidRef.shared().build(rd, depth, bufs.get_internal_size(), vp, frames)


static func _rt_uniform(binding: int, rid: RID) -> RDUniform:
	var u := RDUniform.new()
	u.uniform_type = RenderingDevice.UNIFORM_TYPE_STORAGE_BUFFER
	u.binding = binding
	u.add_id(rid)
	return u


## Re-fit every band's bounding box around the camera.
##
## THE BOX IS NOT DECORATION. A band only ever holds instances within `d1` of the
## camera, and if its AABB claims the whole island instead, Godot puts it in every
## shadow cascade and every cull test passes vacuously: the near band would be
## rendered into all four cascades. Fitted, band 0 (0-15 m) touches cascade 0 only.
## Padded by the deepest mesh's own extent plus the refit hysteresis.
func _rt_refit(cam: Vector3) -> void:
	for name in _gpu:
		var g: Dictionary = _gpu[name]
		var bins: Array = g["bins"]
		# NO VERTICAL-SLAB VISIBILITY TEST. Hiding a band whose outer edge cannot reach the
		# species' Y slab from the camera's height saves ~240 empty draws at a horizon view
		# and ~500 from a flyover, but it is the ONLY altitude-asymmetric decision here: the
		# slab's floor is the ground, so `dy` grows only by climbing, and the slab (`ymin`,
		# `ymax`) is a monotonically-growing accumulator on the main thread, mirrored to the
		# render thread only when that species gets a delta. While climbing (the one time new
		# cells stream in continuously) the slab arrives in jumps, `dy` jumps with it, and
		# bands flip: impostors flicker while gaining altitude, clean horizontally and
		# descending. A correct version would take the slab from the LIVE BLOCK TABLE (which
		# carries per-block bounds and shrinks when cells unload) instead of an accumulator
		# that only grows; not worth carrying for 240 draws until that is built and verified
		# in motion.
		for i in bins.size():
			var r: float = float((bins[i] as Dictionary)["d1"]) + _AABB_PAD_M + _AABB_MOVE_M
			RenderingServer.multimesh_set_custom_aabb((g["mm"] as Array)[i],
				AABB(cam - Vector3(r, r, r), Vector3(r, r, r) * 2.0))


func _rt_free_species(rd: RenderingDevice, g: Dictionary) -> void:
	if (g["uset"] as RID).is_valid():
		rd.free_rid(g["uset"])
	for inst in g["inst"]:
		RenderingServer.free_rid(inst)
	for mm in g["mm"]:
		RenderingServer.free_rid(mm)
	# The multimesh owns its output and command buffers; freeing it frees them, so only
	# the arena is ours to release.
	if (g["src"] as RID).is_valid():
		rd.free_rid(g["src"])
	if (g.get("blocks", RID()) as RID).is_valid():
		rd.free_rid(g["blocks"])


func _rt_clear() -> void:
	var rd := RenderingServer.get_rendering_device()
	if rd == null:
		return
	for name in _gpu:
		_rt_free_species(rd, _gpu[name])
	_gpu.clear()


func _rt_shutdown() -> void:
	_live = false
	_rt_clear()
	var rd := RenderingServer.get_rendering_device()
	if rd == null:
		return
	if _pipeline.is_valid():
		rd.free_rid(_pipeline)
		_pipeline = RID()
	if _shader.is_valid():
		rd.free_rid(_shader)
		_shader = RID()
	if _hiz_set.is_valid():
		rd.free_rid(_hiz_set)
		_hiz_set = RID()
	_hiz_tex_seen = RID()
	if _hiz_dummy.is_valid():
		rd.free_rid(_hiz_dummy)
		_hiz_dummy = RID()
	if _hiz_dummy_sampler.is_valid():
		rd.free_rid(_hiz_dummy_sampler)
		_hiz_dummy_sampler = RID()
	if _globals.is_valid():
		rd.free_rid(_globals)
		_globals = RID()


## ── Diagnostics ────────────────────────────────────────────────────────────────
## Live CPU footprint of every arena, for a host's memory probe.
## `cpu_mb` is the allocated PackedFloat32Array; `blocks`/`free` are block-table
## occupancy. A `blocks` count that only ever climbs while `free` stays empty is
## a leak in the block lifecycle, not growth by demand; that distinction is
## exactly what this exists to measure.
func arena_stats() -> Dictionary:
	var out := {}
	var total_mb := 0.0
	for key in _sp:
		var sp: Dictionary = _sp[key]
		if not sp.has("arena"):
			continue
		var s: Dictionary = sp["arena"].stats()
		var mb := float(s["floats"]) * 4.0 / 1048576.0
		total_mb += mb
		out[str(key)] = {
			"cpu_mb": snapped(mb, 0.1),
			"n": int(s["n"]),
			"blocks": int(s["bcap"]),
			"free": int(s["free_rows"]),
		}
	out["total_cpu_mb"] = snapped(total_mb, 0.1)
	return out
