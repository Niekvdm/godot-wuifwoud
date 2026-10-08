# Copyright (c) 2026 Digitzone
# SPDX-License-Identifier: MIT
@icon("res://addons/wuifwoud/forest_spawner_icon.svg")
@tool
class_name ForestSpawner
extends Node3D
## The forest, grown from its forest maps: per-region maps beside the terrain's region files say
## per texel which forest type grows there, how dense and how old; the flora profile's types say what each type is
## (natural forest, bushes, a planted grid, a mix), its species by ELEVATION band, density and stand numbers.
##
## Deterministic (seeded by grid cell, type and forest_seed): every MP peer grows the same forest from the same map
## files. Placement gates: road corridor (roads win), water line, slope (no trees on cliff faces). Instances land in
## CHUNKS, one MultiMesh per species per chunk, resolved LAZILY as the ring follows the camera (a 60 km² forest
## cannot snap on boot), with visibility ranges so distant chunks cost nothing. NO per-tree collision (a quarter
## million static bodies is not a thing): a trunk pool follows whatever moves.

# By PATH, not the global class name: a `class_name` is not in the registry until an
# editor-mode import has run, and this file must compile in a bare `--script` boot.
## The species' assets: packs, built species, meshes, materials, impostors.
const ForestAssets := preload("res://addons/wuifwoud/forest_assets.gd")
## The terrain adapter: heights, region files, the data directory.
const ForestTerrainRes := preload("res://addons/wuifwoud/forest_terrain.gd")
## The order the ring fills in: nearest first, ahead of the camera before behind it.
const ForestStreamOrderRes := preload("res://addons/wuifwoud/forest_stream_order.gd")
## The trunk colliders kept around whatever moves.
const TreeCollisionPoolRes := preload("res://addons/wuifwoud/forest_trunk_pool.gd")
## The GPU-driven path: the species' instance arenas and their cull.
const VegetationIndirectRes := preload("res://addons/wuifwoud/forest_indirect.gd")
## The forest's log, through its sink.
const ForestLog := preload("res://addons/wuifwoud/forest_log.gd")
## The project's forest config.
const ForestConfigRes := preload("res://addons/wuifwoud/forest_config.gd")
## The base of the feeders the config adds as children.
const ForestFeederRes := preload("res://addons/wuifwoud/forest_feeder.gd")
## The forest maps, one image per terrain region.
const ForestMapsRes := preload("res://addons/wuifwoud/forest_maps.gd")
## The flora profile's forest types.
const ForestTypesRes := preload("res://addons/wuifwoud/forest_types.gd")
## The editor preview's switch.
const ForestPreviewRes := preload("res://addons/wuifwoud/forest_preview.gd")
## The single trees and tree rows (trees.json).
const ForestTreesRes := preload("res://addons/wuifwoud/forest_trees.gd")
## The far forest past the cards.
const ForestFarRes := preload("res://addons/wuifwoud/forest_far.gd")
## The native core, reached by class name.
const ForestNativeRes := preload("res://addons/wuifwoud/forest_native.gd")
## The group rotor strikes and feeders find the forest by. Joined on entering the tree, so a feeder placed under
## the node in a scene (which enters right after) already sees it.
const GROUP := &"wuifwoud_forest"

@export_group("Forest")

# Per map: the fallback flora (ForestConfig.default_profile_path, else the starter's) is the project's default, not
# this map's, so a real map declares its own.
## The flora profile (a JSON file): the forest types the maps name, with their species by elevation band,
## density and stand numbers. Empty: the built-in elevation bands and the fallback flora's pools, and no types.
@export_file("*.json") var profile_path: String = ""

## Where this forest's maps are. Empty: `<the terrain's data_directory>/forest`.
@export_dir var maps_directory: String = ""

## Part of every map point's seed: another value re-rolls every tree. Every peer must use the same.
@export var forest_seed: int = 0

## Ground below this height grows nothing: the sea, and the wet margin above it.
@export_range(-100.0, 1000.0, 0.1, "or_less", "or_greater", "suffix:m") var sea_level: float = 0.6

# THE SUMMIT OF THIS CUT, in game metres. 0 = resolve it (`_resolve_world_summit`).
#
# AUTHORED, not observed, because with terrain streaming on it CANNOT be observed:
# `Terrain3DData.get_height_range()` answers for the regions that are RESIDENT, and
# at boot that is the handful around the spawn. Measured on a 1024-region map from its
# own start location: `get_region_locations()` reported 13 of the 1024 region files on
# disk and the range read 362..526 m against a true summit of 1499.3, a different
# figure on each run, so the bands were not even the same forest twice.
#
# Latching that scaled every band down by the same factor and put most of an island
# "above the treeline": 70% of those trees deleted by `treeline_keep`, the survivors
# re-rolled from the BUSH pool, and no impostor cards at all. It reads as trees that
# do not spawn and bushes where the pine ridge should be.
## The terrain's highest point: the profile's elevation bands scale to it. 0: read from the terrain, which a
## streaming terrain cannot answer (only its resident regions do), so set it there.
@export_range(0.0, 9000.0, 1.0, "or_greater", "suffix:m") var world_summit_m: float = 0.0

@export_group("Trees")

# How deep the MESH band goes before the impostor cards take over. THE SINGLE
# BIGGEST VEGETATION COST IN THE FRAME.
#
# Measured on a test terrain with dense fir stands:
#   mesh instance      3.2-3.8 ms per 1000 visible
#   impostor card      0.16    ms per 1000 (22x cheaper)
# and 61-75 % of the mesh figure is the shadow passes. A 600 m disc at 260 stems/ha
# costs 113 ms p50 with an unbounded mesh band and 18.3 ms with a 150 m band plus
# impostors behind it (6.2x, at the SAME tree count), with the far hillside still
# reading as closed forest because the cards carry it.
#
# The band is what a player is looking at when the frame collapses in a wood; the
# cards are what they are looking at when it does not. The impostor hand-off follows
# this value automatically: the shader's `near_cut` sits at
# `tree_visibility_m - _BILLBOARD_OVERLAP`.
#
# Rendered through a vegetation shot rig at two stations (a ridge looking across a
# wooded valley and a driver eye 1.7 m up) with the SAME 152 801 placed instances in
# every leg and the sun pinned and frozen, 900, 600, 420 and 300 m are
# indistinguishable: the cards carry the far field, and the band only decides how much
# of it is paid for in geometry. By area 350 m draws (350/900)^2 = 15 % of the mesh
# trees 900 m does.
#
# THE THREE KNOBS ARE NOT INTERCHANGEABLE, and moving them together makes the forest
# look thin. `mesh_ring_m` bounds where trees are PLACED, and the impostor shader's
# `near_cut` sits at `tree_visibility_m - _BILLBOARD_OVERLAP`, so cutting the ring
# while leaving the band long opens a hole: at vis 900 the cards start at 810 m, and a
# 420 m ring leaves nothing between the last mesh chunk and there. Cut the BAND (the
# cut moves `near_cut` with it and the cards close up behind it); `mesh_ring_m` and
# `chunk_size` are independent of it.
#
# A desktop A/B is only honest with nothing else on the GPU: an open editor on the same
# project is a big enough neighbour to invert the sign of the result.
#
# An in-game ablation sweep that hid one band at a time priced the OUTERMOST MESH BAND
# (the trees between the shadow ring at 200 m and a cut at 350) at 2.42 ms of a
# 14.62 ms GPU frame, 17 %. They are pure colour-pass cost: `casts` is
# `d0 < tree_shadow_ring_m`, so that band never enters a cascade. The forest as a whole
# was 7.39 ms, 51 % of the frame. 300 m, which the shot comparison above clears, takes
# the part of that band the pictures say costs nothing to give up: by area,
# (350²-300²)/(350²-200²) = 39 % of it, ~0.95 ms. The remaining ~1.4 ms is reachable
# at 200, where the mesh cut meets the shadow ring and every mesh tree casts, but 200
# is not shot-tested, and thinning a treeline is not a thing to do on arithmetic.
## How far mesh trees are drawn; the impostor cards take over past it. The biggest cost in the forest's frame.
@export_range(0.0, 5000.0, 1.0, "or_greater", "suffix:m") var tree_visibility_m: float = 300.0

# GeometryInstance3D.lod_bias on every mesh-tree MMI. Godot picks a mesh LOD per
# MultiMesh from its AABB distance against the viewport's 1 px mesh_lod_threshold,
# which keeps every tree in the camera's own chunk at LOD0; below 1 this selects the
# coarser LODs sooner. Tree-only, unlike the viewport threshold (which also coarsens
# cars and buildings).
#
# The species carry their packs' AUTHORED LOD1-3 with explicit switch distances
# (ForestAssets.LOD_SWITCH_M: 15 / 40 / 110 m), and this is a multiplier on those; a
# bias tuned for a generated chain (0.35, against meshoptimizer's) would put LOD1 at
# 5 m. 0.7 suits conifer-heavy stands: a detailed fir and a stylised tree cost about
# the same at LOD3 (~700 vs ~650 triangles) but not at LOD0 (7 115 vs 5 260, and up
# to 15 900), so the fir's penalty sits in the NEAR field, which pulling the switches
# in reaches, and only that reaches it: past 110 m every band is already on the
# coarsest authored level. 0.7 puts LOD1 at 10.5 m, LOD2 at 28, LOD3 at 77.
#
# NOT A LIVE KNOB on the indirect path: `forest_indirect.gd` multiplies the band
# boundaries by it inside `plan_bins` at species-build time, so changing it needs a species
# rebuild. Measure it by restarting and capturing, never by editing it in flight.
## Multiplies the species' authored LOD switch distances: below 1, the coarser levels come sooner. Takes
## effect when the species are built again (the GPU path plans its bands then).
@export_range(0.05, 4.0, 0.05, "or_greater") var tree_lod_bias: float = 0.7

# Tree shadow casting: the single biggest draw-call multiplier (every
# visible tree MMI renders again per shadow cascade). Turn off to tune.
## Whether trees cast shadows: a casting tree draws again in every shadow cascade.
@export var tree_shadows: bool = true

# Only chunks whose AABB comes within this of the camera cast shadows. A caster
# farther out than the cascade reach plus the longest shadow a tree throws cannot
# land in the rendered volume, so this changes nothing on screen until the ring is
# shorter than the sun's `directional_shadow_max_distance`, and the sun's cascades
# redraw every casting tree, so it is the cheapest shadow lever there is. Measured
# (driver eye, 128 m chunks, the sun at 1 km / 2 splits): -6 ms of 39. 0 = every
# chunk casts. Applied per chunk on commit and re-applied on every stream tick.
## Only trees within this distance of the camera cast shadows. 0: every tree casts.
@export_range(0.0, 5000.0, 1.0, "or_greater", "suffix:m") var tree_shadow_ring_m: float = 200.0

# Crown thinning with distance, see tree_wind.gdshader `lod`: inside
# `foliage_thin_start_m` nothing changes; from there the share of crown fragments a
# tree draws falls to `1 - foliage_thin_max` at the impostor hand-over
# (`tree_visibility_m`). 0 = off. Pushed to the live species materials.
# Measured on the worst forest view (driver eye into the dense stand, 38.8 ms with
# tree_lod_bias alone): 0.4 -13 %, 0.6 -18 % with the crowns intact, 0.8 -26 % and
# the mid-distance crowns read sparse. Culled in the VERTEX stage: a card that is
# not kept is never rasterised, which is the cost (tree_wind.gdshader `lod`).
## Past this distance a crown draws fewer of its leaf cards, down to 1 - foliage_thin_max at the hand-over to
## the impostor cards.
@export_range(0.0, 5000.0, 1.0, "or_greater", "suffix:m") var foliage_thin_start_m: float = 80.0

## The share of a crown's leaf fragments dropped at the hand-over to the cards (0..1). 0: no thinning.
@export_range(0.0, 1.0, 0.01) var foliage_thin_max: float = 0.6

# HOW MUCH OF THE HAND-OVER BAND ONE TREE USES, as a fraction of it.
#
# The band is the STAND's (90 m, `_BILLBOARD_OVERLAP`); at 1.0 every tree in it
# crossfades over the whole thing at once, so what the player sees is not a forest
# changing LOD but a screen door drawn across a hillside, for 3.6 s at 25 m/s, and
# nearer than `tree_visibility_m` whenever `_card_near_cut` is clamped to the streamed
# mesh frontier, where a tree is big enough for the pattern to be unmistakable.
#
# Below 1.0 each tree takes a sub-band of this width at a random offset inside the
# band (wf_common `wf_tree_band`, keyed on the instance origin, which the mesh tier
# and the card tier share, so both sides derive the SAME sub-band and the dither stays
# complementary). The stand still converts gradually, because the offsets spread
# across the full band; only this share of it is dithering at any moment.
#
# BUSHES ARE PUSHED 1.0 REGARDLESS (push_lod_params). A bush has no card to hand over
# to (it dissolves into nothing), so a narrow sub-band is a pop, not a fade.
## The share of the mesh-to-card hand-over band one tree's crossfade takes: lower staggers the hand-over
## across the stand. Bushes always use the whole band.
@export_range(0.05, 1.0, 0.01) var handover_frac: float = 0.3

## Trunk colliders around whatever moves (the config's collision group).
@export var tree_collision: bool = true

@export_group("Bushes")

## The farthest a bush is drawn; a small bush stops sooner (bush_px_min).
@export_range(0.0, 5000.0, 1.0, "or_greater", "suffix:m") var bush_visibility_m: float = 380.0

# SCREEN HEIGHT, IN PIXELS, BELOW WHICH A BUSH IS NOT DRAWN. The cut distance is
# derived per species from its mesh height (ForestAssets.px_cull_distance) and
# capped by `bush_visibility_m`; 0 falls back to that cap for every bush.
#
# WHY THIS IS NOT ONE NUMBER. One distance for every bush draws a 0.6 m grass tuft as
# far as a 4 m tree fern. At 380 m (thirty metres further than the trees above them)
# the tuft is 1.7 px tall on a pinned camera, and under ten pixels from 65 m on, so
# most of its range draws nothing anyone can see; and bushes can be most of an
# island's drawables (2 131 of 3 696 on one). Derived from height, the tuft stops at
# ~65 m and the fern still runs to the cap.
#
# Trees are NOT cut this way: a tree's cut is where its impostor card takes over
# (`tree_visibility_m`), and moving it per species would need the card's hand-over
# band to move with it.
## A bush shorter than this on screen is not drawn: its cut distance comes from its height, capped by
## bush_visibility_m. 0: every bush runs to the cap.
@export_range(0.0, 100.0, 0.5, "or_greater", "suffix:px") var bush_px_min: float = 10.0

@export_group("Impostor cards")

## How far the impostor cards carry the forest past the mesh trees (crossfaded from the meshes). 0: no cards.
@export_range(0.0, 20000.0, 1.0, "or_greater", "suffix:m") var billboard_far_m: float = 2600.0

# IMPOSTOR THINNING BY COUNT. Past `card_thin_start_m` the share of cards a cell
# draws falls linearly to `1 - card_thin_max` at `billboard_far_m`, by moving
# MultiMesh.visible_instance_count, so the dropped cards are never processed at all,
# where the LOD band's vertex-stage collapse still pays their vertex shading. Free
# because the native place packs the buffer in thinning order: any prefix is a
# uniform sample of the cell, and the same one every frame.
## Past this distance a cell draws fewer of its cards, down to 1 - card_thin_max at billboard_far_m.
@export_range(0.0, 20000.0, 1.0, "or_greater", "suffix:m") var card_thin_start_m: float = 1200.0

## The share of cards dropped at billboard_far_m (0..1; see card_thin_start_m).
@export_range(0.0, 1.0, 0.01) var card_thin_max: float = 0.55

# The cards that SURVIVE thinning grow by 1/sqrt(keep) and so cover the canopy the dropped
# ones did: fewer cards, the same forest. Off, thinning trades canopy for count. See
# `thin_compensate` in tree_billboard.gdshader.
## The cards that survive thinning grow to cover the canopy of the dropped ones: fewer cards, the same forest.
## Off: thinning trades canopy for count.
@export var card_thin_compensate: bool = true

# SCREEN HEIGHT, IN PIXELS, BELOW WHICH AN IMPOSTOR CARD IS NOT DRAWN: the cards' copy of
# `bush_px_min`. Thinning by distance drops a share of EVERY card; this drops the ones
# too small to show at all, which on a mixed-age stand are the saplings and young trees
# first: a 5 m sapling is ~4 px tall at 1 km on 1080p and a 25 m mature tree ~19 px, so
# the far field keeps its mass and loses only the specks. Measured in the card's own
# vertex stage from the tree's height, the projection and the viewport, so it holds at
# any resolution and FOV; it dissolves over the next half of the same number of pixels
# on the shared dither instead of popping. 0 = off.
## A card shorter than this on screen is not drawn: the far field keeps its mass and loses its specks. 0: off.
@export_range(0.0, 50.0, 0.5, "or_greater", "suffix:px") var card_px_min: float = 3.0

# Distance impostors use the BAKED VIEW RING from the species' pack (the pack build
# bakes it) when the species has one. Off, every species falls back to the
# procedural silhouette tree_billboard.gdshader draws for an unbaked one: about
# 24 MB of texture cheaper, and visibly a paper cut-out.
#
# Read once into a static at spawn because the card GEOMETRY depends on it, not
# just the shader: a ring card is the square the bake framed, a procedural card is
# 0.62h by h. Flipping the uniform alone leaves the silhouette stretched across the
# wrong quad, which makes an A/B dishonest: the fallback looks fatter than it ships.
## The cards use the species' baked view ring (the pack build bakes it). Off: a procedural silhouette, about
## 24 MB of texture cheaper and visibly flat. Read when the forest starts.
@export var impostor_rings: bool = true

# Far-mass extras ramp IN across this band past mesh range (per-instance
# appear distance in COLOR.a): density grows smoothly instead of cliffing
# at the LOD ring.
## The band past the mesh ring over which the cards' extra far trees fade in, so the density grows smoothly.
@export_range(0.0, 20000.0, 1.0, "or_greater", "suffix:m") var billboard_density_ramp_m: float = 1300.0

# Billboard cells are COARSE (they're unshadowed quads: fine culling buys
# nothing): one MMI per species per cell. The shader's near_cut discards
# instances inside the mesh LOD, so the coarse AABB can't double-draw.
## The card cells' size on the per-chunk path: one MultiMesh per species per cell.
@export_range(64.0, 8192.0, 1.0, "or_greater", "suffix:m") var billboard_chunk_m: float = 1024.0

@export_group("Far forest")

## The far forest: a canopy shell over the forested ground past the cards, built from the forest maps. A
## server that draws nothing turns it off.
@export var far_forest: bool = true

## The hand-over under the last cards: the shell ramps in over this distance before billboard_far_m.
@export_range(0.0, 5000.0, 1.0, "or_greater", "suffix:m") var far_fade_m: float = 600.0

## Terrain regions a far cell spans, each way: one mesh and one summary texture a cell.
@export_range(1, 16, 1, "or_greater") var far_cell_regions: int = 4

## The shell's quad size; it divides the region.
@export_range(1.0, 256.0, 1.0, "or_greater", "suffix:m") var far_grid_m: float = 16.0

## The far summary's texel size; it divides far_grid_m.
@export_range(1.0, 256.0, 1.0, "or_greater", "suffix:m") var far_texel_m: float = 8.0

@export_group("Roads")

## How far the map's trees keep past the road corridor the host sends.
@export_range(0.0, 50.0, 0.1, "or_greater", "suffix:m") var road_margin: float = 3.0

# A single tree or a row's tree keeps this far past the road corridor the host sends, not road_margin: a street
# tree stands at the verge (rows commonly stand 0-3 m past the corridor, where a 3 m margin would drop them all).
# At most road_margin: the corridor's cells are hashed with road_margin's reach.
## How far a single tree or a row's tree keeps past the road corridor: a street tree stands at the verge. At
## most road_margin.
@export_range(0.0, 50.0, 0.1, "or_greater", "suffix:m") var item_road_margin: float = 0.0

@export_group("Wind and vehicles")

## Wind sway, fed live by a wind feeder (set_wind).
@export var wind_enabled: bool = true

## Canopy-tip travel at full gust.
@export_range(0.0, 5.0, 0.01, "or_greater", "suffix:m") var wind_strength: float = 0.35

# How far a car's wake reaches, and how far it leans a plant at the centre. Sized
# for a body plus mirrors, not for a collision hull: this is air and contact
# brushing vegetation aside, so it should reach a little past the paint.
## How far a vehicle's wake reaches, from its centre (a feeder sends the vehicles, set_push_points).
@export_range(0.0, 50.0, 0.1, "or_greater", "suffix:m") var push_radius_m: float = 3.2

## How far a vehicle's wake leans a plant at its centre.
@export_range(0.0, 5.0, 0.01, "or_greater", "suffix:m") var push_strength_m: float = 0.45

@export_group("Ground clutter")

# GROUND-CLUTTER RING: ferns/bushes/deadfall recycled around the camera.
#
# The mesh ring builds the authored density outright, so this is not filler between
# kept trees. What it is for is the metre scale the tree grid cannot reach at all: the
# pitch is 1/sqrt(density), 9 m at a density of 0.012, so nothing smaller than a
# tree exists between trunks, and the corridor gate strips the verge besides.
## The ground-clutter ring: ferns, bushes and deadfall recycled around the camera, at a scale the tree grid
## cannot reach. Off by default: its look is not tuned yet.
@export var clutter_enabled: bool = false

## The clutter ring's radius around the camera.
@export_range(0.0, 500.0, 1.0, "or_greater", "suffix:m") var clutter_radius_m: float = 70.0

## Clutter plants per square metre inside the ring.
@export_range(0.0, 10.0, 0.01, "or_greater", "suffix:/m²") var clutter_density_per_m2: float = 0.10

# Clutter may stand this close to the pavement edge (bushes are
# drive-through: no collision), well inside the tree corridor margin.
## How close clutter may stand to the pavement edge: bushes are drive-through, with no collision.
@export_range(0.0, 50.0, 0.1, "or_greater", "suffix:m") var clutter_road_margin: float = 1.2

@export_group("Streaming")

# STREAMING RINGS: how far from the camera vegetation is BUILT, as opposed to
# how far it is DRAWN (`tree_visibility_m` / `billboard_far_m`).
#
# THIS IS WHAT MAKES `density_per_m2` MEAN ANYTHING. Scattering the whole island at
# boot and dividing `max_instances` across it makes `keep` 0.28 on a 50 km² map (the
# authored 120 trees/ha landing as 23), and raising the density cannot help, because
# `keep` is max_instances/expected and the density is in `expected`. Nine tenths of
# that budget would go on trees behind the player, costing memory and thousands of
# MultiMeshInstance3D nodes to cull while rendering nothing.
#
# Bounded by RADIUS instead, the same money buys the authored density outright:
# π·1000² of wood at 120 trees/ha plus understory is ~40 k instances against a
# 320 k cap. Cells are generated on demand and released behind you.
#
# NOT "BILLBOARDS THAT FOLLOW YOU". Placement is deterministic from the CELL
# COORDINATE (`hash(Vector3i(gx, gy, seed_base))`), so a tree is at the same spot with
# the same species, yaw and scale forever; leaving and returning rebuilds it
# identically, and MP peers agree with zero sync. What streams is whether it is
# INSTANTIATED, not where it is.
#
# 0 = unbounded (scatter the whole island). 480: the hand-over to the cards is per tree
# and the node range is `cut + half-diagonal` (395 m at 64 m chunks), so anything built
# past it is pure streaming cost: placement, MultiMesh upload, collision cells and node
# churn for trees the shader collapses the frame they exist. At 64 m chunks a 1000 m
# ring is ~770 resident chunks and 11 000 MMIs for a band that draws 160 of them (a
# first fill of 34 s against 14). 480 keeps a chunk and the release hysteresis
# (x1.18 = 566) past the node range, so a chunk is resident before its centre can come
# into range.
## How far from the camera the mesh trees are built, as opposed to drawn (tree_visibility_m). 0: the whole
## map at once.
@export_range(0.0, 20000.0, 1.0, "or_greater", "suffix:m") var mesh_ring_m: float = 480.0

# Impostor cells stream on their own, coarser ring: they have to reach past
# `billboard_far_m` or the treeline ends inside the draw distance.
#
# 0 (THE DEFAULT) = DERIVED: `billboard_far_m + _CARD_RING_PAD_M`, see card_ring_m(). A
# fixed ring cannot follow the quality tier, which moves `billboard_far_m` between 1800
# and 3000 m: a 2800 m ring builds cells the shader dissolves on arrival on the low tiers
# and stops short of the draw distance on the highest. A positive value is an explicit
# ring, for a probe.
## How far from the camera the card cells are built. 0: billboard_far_m and a margin, so it follows the
## quality tier.
@export_range(0.0, 40000.0, 1.0, "or_greater", "suffix:m") var billboard_ring_m: float = 0.0

# Mesh-LOD chunk. Bigger = fewer MultiMeshInstances, coarser culling, and the
# culling is what costs. Every chunk whose AABB touches a frustum (camera OR a shadow
# cascade) renders ALL of its instances, so a 384 m chunk with the camera inside it
# draws the trees behind the player and the trees 300 m up the valley in every pass.
#
# Measured at a driver-eye station in a dense forest (a vegetation shot rig, same trees,
# same frozen sun): 384 -> 128 m took the frame from 53.0 to 39.3 ms with identical
# placement, draws 906 -> 2474 (absorbed: the no-vegetation floor is the same 11.7 ms
# either way). The visibility cut is per tree in the shader and the node range is sized
# `cut + half-diagonal` (see _HALF_DIAG), so a chunk imposes no visibility floor.
#
# 128 -> 64, same station, same rig, 1080p: 27.4 -> 22.4 ms (-18 %), draws 1345 -> 2467,
# the floor unchanged at 11.8-12.2. Two things pay: the camera's own chunk draws every
# tree in it whatever the frustum says (behind the player included), and at 380 stems/ha
# that is ~265 trees per species chunk at 128 m against ~66 at 64; and Godot picks a MESH
# LOD per MultiMesh from its AABB distance, so every chunk the camera can stand near is
# LOD0, while a 64 m chunk lets its neighbours fall to LOD1/2 sooner. The same ladder at
# 64 m puts `lod_bias` 0.2 at -2.6 ms and the 2 px viewport threshold at -3.7, both
# reachable because the near chunks are small enough to have a distance.
# `_TRUNK_CELL` (64) must divide this, which rules out 96.
## The mesh trees' chunk: one MultiMesh per species per chunk on the per-chunk path. A multiple of 64 m.
@export_range(64.0, 1024.0, 64.0, "or_greater", "suffix:m") var chunk_size: float = 64.0

# RENDER BUCKET: split a chunk's instances into cells this wide, one
# MultiMeshInstance per species per cell. Godot culls and picks a mesh LOD PER
# MULTIMESH from its AABB distance, so the bucket (not the chunk) becomes the grain
# at which the forest can be rejected or coarsened.
#
# DEFAULT 0 (OFF), AND THE MEASUREMENT IS WHY. It does what it is meant to do on the
# GPU and loses on the CPU. Ridge station, shot rig, GPU column: 10.59 ms at 0 -> 10.10
# at 32 m -> 9.80 at 16. In a game at a driver-eye station (four runs, orders mixed):
#
#     bucket 0    10.86, 10.52 ms      bucket 64 (= chunk, control)  10.52 ms
#     bucket 32   14.08-14.49 ms
#
# So a bucket buys ~0.5 ms of GPU and costs ~3.6 ms of frame: at 32 m the ring holds
# 9088 MultiMeshInstances instead of 3699 (18767 at 16 m), and the cull + draw
# submission of those is main-thread work. THE FOREST IS CPU-BOUND THERE, which is
# also why the tighter LOD it buys cannot pay for itself. Worth re-testing on a
# GPU-bound machine or after the draw count comes down some other way; the knob
# stays for exactly that.
#
# A RENDER unit only: scatter, terrain reads, the worker job, collision and streaming
# all stay per chunk. Should divide `chunk_size`. 0 = one bucket per chunk.
# (The other variant, one MultiMesh per authored LOD level, measures 44 % WORSE: see
# the note above ForestAssets.LOD_SWITCH_M.)
## Splits a chunk's instances into cells this wide, one MultiMesh each, for finer culling and LOD. 0: one per
## chunk (finer measures slower where the frame is CPU-bound).
@export_range(0.0, 1024.0, 1.0, "or_greater", "suffix:m") var render_bucket_m: float = 0.0

## The instance budget: the scatter thins uniformly to stay under it.
@export_range(0, 10000000, 1000, "or_greater") var max_instances: int = 320000

# READ GROUND HEIGHTS FROM THE REGION FILES when Terrain3D has not streamed them.
#
# Off, the scatter can only place where the RENDERER has a region resident: measured
# on one island, 8 of 1024 regions, about 1536 m, against a 2800 m impostor ring. So
# the distance has no trees, and any cell reaching past residency is placed with NAN
# over the missing part and then marked done forever (it is never retried).
#
# On, ForestHeightPump loads the region file on a worker (~5 ms) for anything the
# terrain has not streamed. It is the SEAM for this behaviour: turn it off for the
# residency-bound forest, for an A/B or to save the cache's RAM.
#
# A disk region carries the base hillside and NOT the runtime deform composite, so a
# road carve is not reflected in far cells. A live region is always preferred, and
# these cells are all beyond streaming range where a metre of carve is far below a
# pixel; but it is why this is a fallback and not the primary path.
## Read ground heights from the terrain's region files where the terrain has not streamed them, so the far
## field grows. Off: the forest stops where the terrain is resident.
@export var pump_disk_fallback: bool = true

@export_group("Performance")

# Milliseconds per frame the chunk resolve may spend on the main thread. The
# budget is TIME, not a point count, so the same setting behaves on a laptop and a
# workstation: each spends what it can afford and the island fills in at whatever
# rate that buys. 2 ms of a 16.6 ms frame is ~12%, invisible while driving.
## Main-thread time a frame the chunk resolve may spend.
@export_range(0.1, 50.0, 0.1, "or_greater", "suffix:ms") var resolve_budget_ms: float = 2.0

# Milliseconds per frame the COMMIT may spend landing finished chunks (MultiMesh
# uploads + add_child) on the main thread. Separate from the resolve box because the
# two are different costs on different threads' results; see _collect_place.
## Main-thread time a frame the commit of finished chunks may spend.
@export_range(0.1, 50.0, 0.1, "or_greater", "suffix:ms") var commit_budget_ms: float = 2.5

# CATCH-UP commit box, used only while the mesh ring has fallen INSIDE the card
# hand-over band, i.e. only while there is a visible hole in front of the player.
#
# The base 2.5 ms ration is right for a settled forest and much too small for a
# moving one. Measured driving an island at 25 m/s across its twelve largest forest
# polygons, one second after arriving, mesh chunks resolved of ~208:
#
#     commit 2.5 ms   38 / 141 / 178 / 141 /  62 / 168   (0-14 k instances)
#     commit  12 ms  174 / 210 / 207 / 210 / 208 / 208   (7-23 k instances)
#
# At 2.5 the ring never closed while moving and the cards had nothing behind them;
# at 12 it closed at ten of the twelve stations. But 12 ms of a 16.6 ms frame is not
# a default, so the big box is spent ONLY when it buys something the player can see,
# and the frame goes back to the small ration the moment the ring is closed.
#
# A MULTIPLE of `commit_budget_ms`, not an absolute: the base ration is what the
# machine can afford, and a fixed millisecond figure would ignore it, including in
# the tests that set a tiny ration to pin that the commit stays partial and
# RESUMABLE, which the catch-up must remain. 3.2 x the 2.5 ms default is the 8 ms
# measured above. 1.0 or less disables catch-up.
## The commit's time a frame while the mesh ring lags inside the card hand-over (a visible hole), as a
## multiple of commit_budget_ms. 1 or less: no catch-up.
@export_range(0.0, 20.0, 0.1, "or_greater") var commit_budget_catchup_mult: float = 3.2

# GPU-DRIVEN MESH TREES: one indirect MultiMesh per species per distance band for the
# whole ring, compacted every frame by a compute shader, instead of one
# MultiMeshInstance3D per (chunk x species). See forest_indirect.gd.
#
# What it changes, all at once: ~3 700 drawables become ~150; the LOD level is chosen
# per TREE instead of per 64 m chunk; the shadow ring becomes a band boundary rather
# than a per-chunk flag re-applied on every stream tick; and committing a chunk stops
# costing an `add_child` per species (~8 ms each, 29.3 s of the island's first fill).
#
# Needs a RenderingDevice, so it is inert under --headless: every headless test still
# exercises the per-chunk path, which is kept and is the fallback.
## Draw the mesh trees on the GPU-driven path: one indirect MultiMesh per species and distance band. Off, or
## without a RenderingDevice (headless): the per-chunk path.
@export var indirect_mmi: bool = true

# The IMPOSTOR tier on the same path: one arena per card species instead of one
# MultiMeshInstance3D per 1024 m cell per species, with the distance thinning moved
# from `visible_instance_count` into the cull shader. Separate from `indirect_mmi`
# because the two tiers price differently and each has to be able to answer for
# itself; ignored when `indirect_mmi` is off.
#
# ON, BUT IT IS A CLOSE CALL AND THE NUMBERS ARE HERE SO IT CAN BE REVERSED. A flat
# scan of the arena in the cull loses the frame everywhere (0.03 ms for the mesh tier's
# 29 511 instances, 0.37 ms for 512 752 with cards in) against a per-cell path where
# Godot culls hierarchically. Two things make it pay: a LEVEL-1 cluster cull in the
# shader (0.37 -> 0.15 ms) and the impostor bands kept out of SDFGI, whose cascades
# would otherwise consider half a million billboards inside a 2.6 km AABB.
#
# Where it stands, one sitting, two passes each (mesh-only vs mesh+cards):
#
#     driver eye   14.62 / 14.37  vs  14.71 / 14.65 ms      draws 841 -> 773
#     flyover      11.43 / 11.35  vs  11.21 / 11.15         draws 699 -> 564
#     horizon       7.30 / 7.35   vs   7.27 / 7.27          draws 600 -> 468
#
# Neutral on total frame (66.42 vs 66.26 ms across the six), FEWER draws at every
# station, and 439 vegetation nodes fewer, for ~80 MB of VRAM. If the driver-eye
# 0.28 ms matters more than the altitude stations, turn this off; the mesh tier is
# unaffected.
## The impostor cards on the GPU-driven path too (with indirect_mmi).
@export var indirect_cards: bool = true

## The scale the cut is computed at. The scatter draws 0.8-1.45 (lerp), so this is the
## midpoint rather than the worst case: sizing the cut for the biggest bush in a
## species would give the whole species the tallest one's range.
const _BUSH_CUT_SCALE := 1.12
## Never cut a bush closer than this whatever the arithmetic says: a bush that
## vanishes inside the near field is a pop in the player's lap, and understory at the
## treeline is the only vegetation up there.
const _BUSH_CUT_MIN_M := 60.0
var _lod_pushed_count := -1
## How far past the draw distance the card ring reaches: one stream step (the ring is
## re-centred only every `_STREAM_MOVE_M`) plus margin. Cells are admitted by their NEAREST
## corner, so any cell with a card inside the draw distance is already in.
const _CARD_RING_PAD_M := 100.0

const _NAME_PREFIX := "Veg_"
const _SLOPE_MAX := 1.2         # rise/run ≈ 50°: steeper is cliff, no trees
# Elevation bands for wood species (subtropical island profile).
const _COAST_M := 120.0
const _MID_M := 420.0
# Above the treeline the forest gives out: scrub + heavy thinning (a volcano's
# cloud-scrubbed summit is low growth, not canopy).
const _TREELINE_M := 700.0
const _TREELINE_KEEP := 0.4
# Slope thinning band: full density below, fades to nothing at _SLOPE_MAX.
const _SLOPE_THIN := 0.8
# The stand structure's numbers (clearings, their soft edge, groves) are the native core's own (its wf_rules.h).
## MESH -> CARD HAND-OVER BAND before tree_visibility_m. Per tree, in the shaders
## (tree_wind `fade_start_m`..`fade_end_m` = impostor `near_cut`..`+near_fade`): across
## the band the share of trees still drawn as mesh falls to none and the cards take
## exactly those trees over, one id each: see wf_common.gdshaderinc.
const _BILLBOARD_OVERLAP := 90.0
## A bush has no card; it dissolves bush by bush over this band before its cut.
const _BUSH_DISSOLVE_M := 40.0
## Half the diagonal of a square cell: how far a cell's farthest instance can be
## from its AABB centre, which is what Godot measures `visibility_range_end` against.
## A node range of `cut + cell * _HALF_DIAG` therefore keeps a cell until its LAST
## instance has crossed the shader's cut, and frees it right after, so no band is ever
## too short to draw (a cut on the node itself culls a whole tier: 45 238 trees drawn
## as ZERO primitives under a passing test).
const _HALF_DIAG := 0.7072
## Node-range hysteresis so a chunk straddling its range does not flicker as the
## camera rocks on its springs. Small: the shader has already emptied the chunk.
const _RANGE_HYSTERESIS_M := 8.0

# Age-weighted species pools: [mesh, weight]. Mixing mature + young + sapling
# is the biggest realism tell: a real stand is not all one height. Dead/fallen
# are drawn separately (a type's dead_frac) so they stay rare. The pools come from the
# map's flora profile over the FALLBACK FLORA (ForestConfig.default_profile_path);
# mature/young subsets are the species' `mature` / `young` flags (its pack).

## The fallback flora (ForestConfig.default_profile_path: its `species` and `dead` pools), loaded once per path.
## Empty pools without one: then nothing is placed where a map names no profile.
static var _fallback := {}
static var _fallback_path := "<none>"


static func _fallback_pools() -> Dictionary:
	var cfg := ForestConfigRes.current()
	var p := cfg.default_profile_path
	# The starter pack's flora when the config names none and grows the starter.
	if p == "" and not cfg.disabled_packs.has(cfg.starter_pack_path()):
		p = cfg.starter_flora_path()
	if p != _fallback_path:
		_fallback_path = p
		var d = JSON.parse_string(FileAccess.get_file_as_string(p)) if p != "" and FileAccess.file_exists(p) else null
		_fallback = {
			"species": d.get("species", {}) if typeof(d) == TYPE_DICTIONARY else {},
			"dead": d.get("dead", {}) if typeof(d) == TYPE_DICTIONARY else {},
		}
	return _fallback


# Per-species surface ShaderMaterials, built lazily from the FBX flat colours.

# Live flora tables: the consts above are the DEFAULT; a profile overrides.
var _species: Dictionary = {}
var _dead: Dictionary = {}
var _coast_m: float = _COAST_M
var _mid_m: float = _MID_M
var _treeline_m: float = _TREELINE_M
var _treeline_keep: float = _TREELINE_KEEP
## The treeline the PROFILE was authored against, kept so the bands can be
## rescaled to this world's summit. See `_rescale_bands_to_world`.
var _profile_treeline_m: float = 0.0
var _bands_rescaled: bool = false
var _summit_warned: bool = false
## Radius inside which EVERY mesh chunk has resolved. INF once the ring has closed.
## The card hand-over is clamped to it: see `_card_near_cut`.
var _mesh_frontier_m: float = INF
var _card_cut_pushed: float = -1.0
## Trunk registry for the dynamic collision pool: 96 m cells ->
## PackedFloat32Array of [x, ground y, z, radius] quads (flat packed floats:
## 320k boxed Vector4 Variants cost ~8x the memory and thrash the cache).
## Standing trees only.
var _trunk_cells: Dictionary = {}
## Tree crowns for rotor strikes (canopies have no collision): per trunk cell, flat
## [x, z, y_bottom, y_top, radius], filled wherever a trunk is registered, erased with it.
var _crown_cells: Dictionary = {}
## Where a crown starts, as a share of the tree's height (an AABB does not say).
const CROWN_BOTTOM_FRAC := 0.35
## 64, not 96: it has to divide EVERY cell size (128 m mesh chunks, 1024 m impostor
## cells) exactly, so a trunk cell belongs to one chunk of either tier: releasing a
## chunk erases its trunk cells, and a cell shared with a neighbour would take the
## neighbour's trunks with it. It must also exceed the collision pool's 45 m query
## radius so a 3x3 neighbourhood covers the query.
const _TRUNK_CELL := 64.0
## Multiplier from the quality tier (apply_quality_params). 1.0 until a tier says otherwise.
## NOT a density: it never re-pitches the scatter grid; the native scatter drops a per-point
## share, so a lower tier's forest is a subset of a higher one, the same
## trees trunk-for-trunk (the MP contract this file is built on).
var _quality_density_scale: float = 1.0

var _chunks: Dictionary = {}    # Vector2i -> {pts: [{p: Vector2, kind, seed}], done: bool}
## Rasterisation jobs on the WorkerThreadPool, one per cell that entered a ring:
## [{key, cells, entry, rect, polys, bb, pts, wood, task}]. See _scatter_cell.
var _scatter_jobs: Array = []
## Placement jobs on the WorkerThreadPool, one per scattered chunk: heights from the
## pump's region copies, every gate, species, tint and the packed MultiMesh buffers.
## `_place_ready` holds finished jobs waiting for their rationed commit.
var _place_jobs: Array = []
var _place_ready: Array = []
var _place_jobs_run: int = 0
## Hard cap on MultiMeshInstances landed per tick, a backstop behind the TIME box
## (`commit_budget_ms`, see _collect_place). With one MultiMesh per species per LOD level
## a node-count ration would quarter the fill, so the time box rations and this only
## catches a runaway. A chunk stays `placing` until its last species is in.
const MMIS_PER_TICK := 512
## Region heightmap copies for the place jobs (ForestHeightPump). Null until a
## terrain with `get_regionp` is found; without one nothing is placed (said once).
var _pump: ForestHeightPump = null
## What the camera looks along (world XZ), for ForestStreamOrder. Captured in
## _stream_tick; zero until there is a camera, which degrades to nearest-first.
var _stream_look := Vector2.ZERO
## Injectable terrain (rigs, tests). When null, ForestTerrain finds the Terrain3D
## in the tree the way it always has.
var terrain_source: Node = null
## The forest maps, configured from the terrain once one is found (_ensure_maps); tests configure and
## adopt their own.
var maps: ForestMapsRes = ForestMapsRes.new()
## The single trees and tree rows: trees.json in the maps' folder, read when the maps are configured.
var trees: ForestTreesRes = ForestTreesRes.new()
var _far: ForestFarRes = null           # the far forest: the FarForest internal child, once made
## The native tables (WfTables) and the ForestTypes they were built from: a new profile builds them again
## (_tables_now). Untyped, as every native object here: the class is reached by name only (forest_native.gd).
var _tables = null
var _tables_types = null
## The native road corridor (WfRoads), built with the GDScript one by set_road_segments; null: no roads.
var _roads = null
var _native_warned := {}           # a native job's reason: said once
## THE FRAME'S BOX: the far landing, the commit and the card flush draw on ONE deadline, opened where the
## resolve pump starts that work (_box_open) and closed when it ends; 0 outside it (a direct _collect_place or
## _flush_billboards opens its own). The first commit and the first flush item of a box always land.
var _box_until_us := 0
var _box_commits := 0
var _box_flushes := 0
## The ring is refilling from nothing (boot, a jump past the mesh ring, a quality rebuild, a Re-grow) until every
## cell has resolved: only then may the commit take the catch-up box.
var _filling := true
## THE ARENAS' HEADROOM WHEN A FILL ENDS: 3x the fill's count, both tiers. A drive from farmland into a forest
## grows the card arenas up to 2.0x, and each growth rebuilds a species' whole GPU side in one driving frame
## (10-21 ms a card arena, 2-5 ms a mesh one); reserved once the fill's cards are drawn, the regrow lands inside
## the fill. A mesh arena also starts at ForestIndirect.MESH_MIN_CAP.
const ARENA_RESERVE_MULT := 3.0
var _reserve_due := false
## Cells the ring admitted while driving, waiting for their scatter job: [cells, key, cell_m, bb, entry].
var _admit_queue: Array = []
## The stream tick's share of a frame (ms): admissions past it wait for the next frame; the first always goes.
const _ADMIT_MS := 0.5
## The far forest waits at most this long (ms) for the first ring fill (near_busy).
const FAR_HOLD_MS := 10000
var _far_hold_until := -1               # ms: set when the far forest first asks
## For tools and tests: run the editor's branch outside the editor (Engine.is_editor_hint() is false in a test run).
## Read once, in _ready.
var force_editor := false
var _editor := false        # decided once in _ready
var _preview_off := false   # the editor's Forest menu turned the preview off: every cell released
var _seen_generation := 0      # the maps' generation the ring last grew from (an import moves it)
var _seen_trees_generation := 0   # the trees' generation the ring last grew from (an import moves it)
var _species_warned := {}         # a pinned species no pack has: said once
var _type_warned := {}            # an item's type the profile lacks: said once
var _items_planted := 0           # item trees the scatter handed the mesh ring (debug_churn)
## The profile's forest types. Frozen after _load_profile: scatter and placement workers read it.
var _types: ForestTypesRes = ForestTypesRes.new()
## Some ring cell waits for its maps: _feed_maps has work.
var _map_waiting := false
var _maps_warned := false
## Coarse impostor cells, same shape as `_chunks` but tier "bb": {pts, done, cursor}.
var _bb_cells: Dictionary = {}
## Where the ring is centred. Starts at the ORIGIN, not at infinity: the editor
## button and a dedicated server both run without a camera, and a ring centred on
## 1e18 builds nothing at all while looking exactly like a broken spawner.
var _stream_at := Vector2.ZERO
var _stream_dirty := true
## First fill has completed: used only to log the initial ring once instead of
## every time the last chunk of a steady-state pass lands.
var _settled := false
## FIRST-FILL ACCOUNTING, reported once on "ring filled" so a boot's loading time can
## be attributed rather than felt: worker seconds in scatter and in placement (summed
## over the pool, not wall clock), main-thread milliseconds in the commit,
## and how many ticks the commit ration held a finished chunk back.
var _fill_t0_us := 0
var _fill_scatter_us := 0
var _fill_place_us := 0
var _fill_commit_us := 0
var _fill_species_us := 0     # of which: MultiMesh build + add_child per species level
var _fill_flush_us := 0       # of which: impostor cell flushes (_flush_billboards)
var _fill_commit_ticks := 0
var _fill_starved_ticks := 0
var _budget_warned := false
## THE PER-FRAME INSTRUMENT: microseconds of this node's main-thread work per phase, accumulated
## while a frame runs; frame_timings() hands out the last WHOLE frame's. Two clock reads around a phase, each charged
## exclusive of the phases nested in it (a release inside the stream tick is `frees`, not `stream`); nothing is logged.
const FRAME_PHASES: Array[StringName] = [&"stream", &"frees", &"scatter", &"feed", &"far", &"place", &"commit",
	&"trunks", &"crowns", &"flush", &"resolve", &"upload", &"process"]
var _ft_frame := -1
var _ft_cur := {}
var _ft_last := {}
var _ft_stack: Array = []    # [phase, start µs, µs charged to nested phases] while a phase runs
## The GPU-driven mesh-tree path, or null when it is unavailable (headless) or off.
## Every `_indirect != null` branch in this file is "are the mesh trees GPU-driven".
var _indirect: Node3D = null
## Re-evaluate the ring only after the camera has moved this far: one chunk, since
## chunks are 64 m: a chunk entering or leaving the ring is exactly what a crossing
## means, and the ring is not re-sorted inside one.
const _STREAM_MOVE_M := 64.0
## Cells are released at ring x this, never at the ring itself: a car parked on the
## boundary would otherwise build and free the same chunk every time it rolls a
## metre, which is the classic streaming thrash.
const _RING_HYSTERESIS := 1.18
var _bb_accum: Dictionary = {}  # coarse Vector2i -> {species: {xforms: [], colors: []}}
var _bb_nodes: Dictionary = {}  # "cell/species" -> MultiMeshInstance3D
## "cell/species" -> arena handle, the GPU-driven path's answer to `_bb_nodes`.
var _bb_blocks: Dictionary = {}
var _bb_touched: Dictionary = {}  # coarse cells with NEW instances this pass
var _bb_left: Dictionary = {}     # coarse cell -> species still to flush (a cell part-flushed when the box ran out)
var _timer: Timer = null
var _wood_cells: Dictionary = {}   # Vector2i (16 m) -> true; forest-ground membership
var _clutter_nodes: Dictionary = {}  # species -> MultiMeshInstance3D (recycled)
var _clutter_at := Vector2(1e18, 1e18)
var _clutter_poll := 0.0
var _road_rects: Array = []     # [{a: Vector2, b: Vector2, hw: float}] corridor capsules
var _road_grid: Dictionary = {} # Vector2i (64 m cell) -> Array of indices into _road_rects
var _road_blocker_built := false
var _spawned := 0

func _enter_tree() -> void:
	add_to_group(GROUP)   # rotor strikes ask for crowns_near(); feeders find their forest by it (the editor's too)


## The project's feeders (ForestConfig.runtime_inputs) as children, one per script, unless a child already runs it
## (a scene may hold its own). Added without an owner, so a scene save never stores them. A child's _ready runs
## inside add_child, so a one-off input (paths, the quality tier, the log sink) lands before anything after this call
## reads it. In the editor: ForestConfig.editor_inputs instead, @tool scripts only.
func _attach_inputs() -> void:
	var have := {}
	for c in get_children():
		if c.get_script() != null:
			have[c.get_script()] = true
	for s in (ForestConfigRes.current().editor_inputs if _editor else ForestConfigRes.current().runtime_inputs):
		if s == null or have.has(s):
			continue
		if not _is_feeder_script(s):
			ForestLog.warn("[Wuifwoud] %s is not a ForestFeeder: skipped" % s.resource_path)
			continue
		if _editor and not s.is_tool():
			ForestLog.warn("[Wuifwoud] %s is not @tool, so it cannot run in the editor: skipped" % s.resource_path)
			continue
		var n: Node = s.new()
		n.name = s.resource_path.get_file().get_basename().to_pascal_case()
		add_child(n)
		have[s] = true


static func _is_feeder_script(s: Script) -> bool:
	var b: Script = s
	while b != null:
		if b == ForestFeederRes:
			return true
		b = b.get_base_script()
	return false


func _ready() -> void:
	# ONE flag decides every editor branch: no fix can sit behind a scattered is_editor_hint() gate that
	# the editor never reaches.
	_editor = force_editor or Engine.is_editor_hint()
	_free_stored_preview()
	_attach_inputs()
	ForestAssets._ensure_packs()     # main thread, before any placement worker asks about a species
	ForestNativeRes.core()           # the native core, probed here on the main thread before any job
	ForestAssets._rings_enabled = impostor_rings
	maps.editing = _editor
	if _editor:
		# The scene the maps are saved with, asked when needed: Save As and a first save move it.
		var me := weakref(self)
		maps.scene_of = func() -> String:
			var n = me.get_ref()
			if n == null:
				return ""
			var root: Node = n.get_tree().edited_scene_root if n.is_inside_tree() else null
			if root == null:
				root = n.owner if n.owner != null else n
			return root.scene_file_path
		trees.scene_of = maps.scene_of
	_plan_scatter()
	_ensure_indirect()
	if _indirect != null:
		_warm_species()
	push_lod_params()
	# Dynamic tree collision: a fixed shape pool teleports onto trunks near
	# vehicles (deterministic scatter -> MP peers agree with zero sync). The game's only: the editor has no vehicles.
	if tree_collision and not _editor:
		var pool: Node3D = TreeCollisionPoolRes.new()
		pool.name = "TreeCollision"
		pool.source = self
		var cfg := ForestConfigRes.current()
		pool.collision_group = cfg.collision_group
		pool.trunk_layer = cfg.trunk_layer
		pool.trunk_mask = cfg.trunk_mask
		pool.trunk_meta = cfg.trunk_meta
		add_child(pool)

## Nodes the removed "Spawn in scene" button stored in a scene (named _NAME_PREFIX…, owned by the scene) are freed,
## with one warning: the forest grows its own and stores none.
func _free_stored_preview() -> void:
	var n := 0
	for c in get_children():
		if String(c.name).begins_with(_NAME_PREFIX) and c.owner != null:
			c.queue_free()
			n += 1
	if n > 0:
		ForestLog.warn("[Wuifwoud] %s held %d stored preview node(s) from the old Spawn in scene button: removed (save the scene to drop them)" % [name, n])


## The camera the ring follows: in the editor Terrain3D's (it follows the editor's 3D view), else the viewport's.
func _camera() -> Camera3D:
	if not is_inside_tree():
		return null
	if _editor:
		var t := terrain_source if terrain_source != null else ForestTerrainRes.find_cached(self)
		if t != null and t.has_method("get_camera"):
			var c = t.call("get_camera")
			if c is Camera3D:
				return c
	return get_viewport().get_camera_3d()


## The editor's frame: an import's catch-up (the maps' or the trees' generation moved, every cell grows again),
## the preview switch, the ring (no Timer here), the GPU cull's camera. No wind, push or washes. With the preview off
## the maps are still configured from the terrain: painting needs them.
func _editor_tick() -> void:
	if maps.generation != _seen_generation or trees.generation != _seen_trees_generation:
		_seen_generation = maps.generation
		_seen_trees_generation = trees.generation
		regrow_all()
	var off := not ForestPreviewRes.visible
	if off != _preview_off:
		_preview_off = off
		if _far != null:
			_far.visible = not off
		if off:
			_release_all()
			if _indirect != null:
				_indirect.clear_all()   # its arena would keep drawing the last cull's trees, frozen in place
		else:
			_stream_dirty = true
	if _preview_off:
		var t := terrain_source if terrain_source != null else ForestTerrainRes.find_cached(self)
		if t != null:
			_ensure_maps(t)
		return
	_resolve_pending()
	if _indirect != null:
		var cam := _camera()
		if cam != null:
			_indirect.camera = cam      # the cull's frustum: the edited scene's viewport camera is not the editor's
			_ft_begin(&"upload")
			_indirect.update(VegetationIndirectRes.eye_of(cam))
			_ft_end()


## Every ring cell released, both tiers (the preview switched off, the editor's teardown, Re-grow all).
func _release_all() -> void:
	for tier in [_chunks, _bb_cells]:
		var bb := is_same(tier, _bb_cells)
		for k in tier.keys():
			_release_cell(k, tier, bb)
	_map_waiting = false


## The ring cells over `rect` (world metres) grow again from the maps as they are now: the mesh chunks, the
## impostor cells, or both. A stroke in progress regrows only the mesh chunks: a 1 km impostor cell resubmitted every
## send would stay missing for the whole stroke (each earlier job still runs, then is dropped). A job already running
## for a regrown cell is dropped when it lands: its entry is no longer the cell's (entry identity, _collect_scatter /
## _collect_place).
## The far forest regrows the far cells the rectangle reaches.
func regrow(rect: Rect2, mesh := true, cards := true) -> void:
	if _far != null:
		_far.touch(rect)
	for tier in [_chunks, _bb_cells]:
		var bb := is_same(tier, _bb_cells)
		if (bb and not cards) or (not bb and not mesh):
			continue
		var cell_m: float = billboard_chunk_m if bb else chunk_size
		for k in tier.keys():
			if Rect2(float(k.x) * cell_m, float(k.y) * cell_m, cell_m, cell_m).intersects(rect):
				_release_cell(k, tier, bb)
				_scatter_cell(k, tier, cell_m, bb)
	_settled = false


## Every cell released; the ring admits them again from the maps as they are now (the Forest menu's Re-grow), and the far
## forest rebuilds every far cell.
func regrow_all() -> void:
	_release_all()
	_stream_dirty = true
	_settled = false
	_filling = true
	if _far != null:
		_far.rebuild_all(false)


## The flora profile read again (the Forest workspace's Reload types): the types, the maps' summary ids and every
## held map's summary, then every cell grows again. The jobs in flight finish first: their workers read `_types`, which
## is swapped here, and a map summary built with the old ids must not land after the re-summary.
func reload_types() -> void:
	_drain_scatter_jobs()
	_drain_place_jobs()
	maps.drain()
	_load_profile()
	maps.type_ids = _types.ids()
	maps.resummarise()
	if _far != null:
		_far.rebuild_all(true)
	regrow_all()


## The species packs resolved again and the forest grown again from them (the editor's build landing and Re-grow):
## a pack or a species added since the forest started grows, a rebuilt one loads afresh. The jobs in flight finish
## first: placement workers ask about species.
func reload_species() -> void:
	_drain_scatter_jobs()
	_drain_place_jobs()
	ForestAssets.forget_packs()
	ForestAssets.reset()
	reload_types()


## The editor takes a scene out of the tree when its tab is left and puts it back: the preview is taken
## down here and built again by _ready on the way back in, so nothing the forest made outlives its GPU resources. The
## maps stay, with any unsaved paint.
func _editor_teardown() -> void:
	_release_all()
	if _indirect != null:
		_indirect.queue_free()
		_indirect = null
	_bb_blocks.clear()
	_bb_accum.clear()
	_bb_nodes.clear()
	_bb_left.clear()
	_admit_queue.clear()
	_filling = true
	_trunk_cells.clear()
	_crown_cells.clear()
	_wood_cells.clear()
	_spawned = 0
	_settled = false
	_stream_dirty = true
	_pump = null
	_free_far()
	request_ready()

## Apply the per-map flora profile over the built-in tables (partial files are
## fine: anything absent keeps its default).
func _load_profile() -> void:
	_load_profile_pools()
	_name_species()


## Every species the pools can place, the types' own mixes included, looked up once here on the MAIN thread:
## placement workers ask about species too, and a species no pack has is named in a warning on its first lookup, which
## must not be a worker's.
func _name_species() -> void:
	for pools in [_species, _dead]:
		for band in pools:
			var pool = pools[band]
			if typeof(pool) != TYPE_ARRAY:
				continue
			for e in pool:
				ForestAssets._species_entry(str(e[0]) if typeof(e) == TYPE_ARRAY else str(e))
	for id in _types.ids():
		for pool in _type_pools(_types.get_type(id)).values():
			for e in pool:
				ForestAssets._species_entry(_entry_name(e))


func _load_profile_pools() -> void:
	_species = _fallback_pools()["species"]
	_dead = _fallback_pools()["dead"]
	_drop_disabled()
	_coast_m = _COAST_M
	_mid_m = _MID_M
	_treeline_m = _TREELINE_M
	_treeline_keep = _TREELINE_KEEP
	_types = ForestTypesRes.new()
	if profile_path == "" or not FileAccess.file_exists(profile_path):
		return
	var data = JSON.parse_string(FileAccess.get_file_as_string(profile_path))
	if typeof(data) != TYPE_DICTIONARY:
		ForestLog.warn("[Vegetation] bad flora profile: %s" % profile_path)
		return
	var bands: Dictionary = data.get("bands", {})
	_coast_m = float(bands.get("coast_top_m", _coast_m))
	_mid_m = float(bands.get("mid_top_m", _mid_m))
	_treeline_m = float(bands.get("treeline_m", _treeline_m))
	_treeline_keep = float(bands.get("treeline_keep", _treeline_keep))
	# The bands are PROPORTIONS of this island, not metres of this cut.
	_profile_treeline_m = _treeline_m
	_bands_rescaled = false
	var sp: Dictionary = data.get("species", {})
	if not sp.is_empty():
		_species = (_fallback_pools()["species"] as Dictionary).duplicate(true)
		for band in sp:
			_species[band] = sp[band]   # whole-pool replace: a partial merge would
										# keep the default's wrong-biome species
	var dd: Dictionary = data.get("dead", {})
	if not dd.is_empty():
		_dead = (_fallback_pools()["dead"] as Dictionary).duplicate(true)
		for band in dd:
			_dead[band] = dd[band]
	_drop_disabled()
	# The stand numbers live in the forest types: a leftover block is said, not silently read.
	if data.has("forest"):
		ForestLog.warn("[Vegetation] %s still has a `forest` block: its numbers belong in `types` now. Remove the key."
			% profile_path.get_file())
	# FOREST TYPES: what the forest maps name. A profile with them grows the forest from its maps. The
	# age subsets ask the species packs HERE, on the main thread, never on a worker.
	if data.has("types"):
		_types.load_list(data["types"], _species, _dead,
			func(n: String) -> bool: return ForestAssets.is_young(n),
			func(n: String) -> bool: return ForestAssets.is_mature(n), ForestAssets.disabled_ids())
		for e in _types.errors:
			ForestLog.error("[Wuifwoud] %s: %s" % [profile_path.get_file(), e])
	else:
		ForestLog.warn("[Vegetation] %s has no forest types, so nothing grows" % profile_path.get_file())
	ForestLog.debug("[Vegetation] flora profile: %s (bands %.0f/%.0f, treeline %.0f; %d forest type(s))" % [
		profile_path.get_file(), _coast_m, _mid_m, _treeline_m, _types.by_id.size()])


## The species switched off (ForestConfig.disabled_species) leave every pool: the rest of a pool share its weight.
func _drop_disabled() -> void:
	var off := ForestAssets.disabled_ids()
	_species = ForestTypesRes.drop_species(_species, off)
	_dead = ForestTypesRes.drop_species(_dead, off)


## The native tables for the profile as it is now: built on the main thread when a job first needs them after
## the profile (re)loaded (`_types` is a new object then), and frozen: a job holds the tables it was given.
func _tables_now():
	if _tables == null or not is_same(_tables_types, _types):
		_build_tables()
	return _tables


## Every species the map can place: the packs' (a single tree or a row may pin any of them) and every forest
## type's pools', sorted, each once; the names the native tables are built from.
func _placeable_species() -> PackedStringArray:
	var seen := {}
	for sp in ForestAssets.species_ids():
		seen[str(sp)] = true
	for id in _types.ids():
		for pool in _type_pools(_types.get_type(id)).values():
			for e in pool:
				seen[_entry_name(e)] = true
	var names := PackedStringArray(seen.keys())
	names.sort()
	return names


## THE SPECIES BUILT AT LOAD: every species the map can place (its materials and LOD meshes, a tree's impostor
## card) is built when the forest starts, before the first fill, on the GPU path. A species' first build is 1-62 ms
## of main-thread work (the mesh, its card stamps, the LOD chain, the textures) that a commit would otherwise pay
## the first time the ring meets the species: while driving. Headless (the per-chunk path, every test) nothing is
## built up front. The caches are static: a second call is free. The far forest's palette colours too: read here,
## its start costs nothing while driving.
func _warm_species() -> void:
	var cards := billboard_far_m > tree_visibility_m
	for n in _placeable_species():
		ForestAssets._species_lod_meshes(n)
		if cards and not ForestAssets.is_bush_mesh(n):
			ForestAssets._billboard(n)
	if far_forest:
		_ensure_far()
		_far._warm_colours(true)


## When a fill ends: once every cell has resolved and the fill's card flush has drained, the card and
## the mesh arenas reserve ARENA_RESERVE_MULT times their count, so the regrow lands inside the fill and never in a
## driving frame: the next update takes all their rebuilds at once. Once a fill.
## Every tick it also sets the arenas' pacing: while driving one GPU rebuild a frame, none limited while filling.
func _reserve_after_fill() -> void:
	if _indirect != null:
		_indirect.realloc_limit = 0 if _filling else 1
	if _filling:
		_reserve_due = true
		return
	if not _reserve_due or not _bb_touched.is_empty():
		return
	_reserve_due = false
	if _indirect != null:
		_indirect.reserve_tier(VegetationIndirectRes.TIER_CARD, ARENA_RESERVE_MULT)
		_indirect.reserve_tier(VegetationIndirectRes.TIER_MESH, ARENA_RESERVE_MULT)
		_indirect.realloc_free_once = true


## The native tables: every species the map can place (_placeable_species), with its pack's scalars (a
## bush; the trunk radius); each type with its numbers and its pools as index lists. MAIN THREAD. Null without the
## native core.
func _build_tables() -> void:
	_tables_types = _types
	_tables = null
	var core = ForestNativeRes.core()
	if core == null:
		return
	var names := _placeable_species()
	var index := {}
	var bush := PackedByteArray()
	var trunk := PackedFloat32Array()
	for i in names.size():
		index[names[i]] = i
		bush.append(1 if ForestAssets.is_bush_mesh(names[i]) else 0)
		trunk.append(ForestAssets.trunk_radius_for(names[i]))
	var types := []
	for id in _types.ids():
		var t: Dictionary = _types.get_type(id)
		var pools := {}
		var named := _type_pools(t)
		for key in named:
			var ids := PackedInt32Array()
			var ws := PackedFloat32Array()
			for e in named[key]:
				ids.append(int(index[_entry_name(e)]))
				ws.append(float(e[1]) if typeof(e) == TYPE_ARRAY and (e as Array).size() > 1 else 1.0)
			pools[key] = [ids, ws]
		types.append({"id": id, "style": ForestTypesRes.STYLES.find(str(t["style"])), "pitch": float(t["pitch"]),
			"clump": float(t["clump"]), "understory": float(t["understory"]),
			"wall_m": float(t["edge_wall_m"]) if float(t["edge_wall_mult"]) > 1.0 else 0.0,
			"dead_frac": float(t["dead_frac"]),
			"tree_share": float(t.get("tree_share", ForestTypesRes.DEFAULT_TREE_SHARE)), "pools": pools})
	_tables = core.make_tables({"species": names, "bush": bush, "trunk": trunk, "types": types})
	if str(_tables.error()) != "":
		ForestLog.error("[Wuifwoud] the forest's native tables: %s; nothing grows" % _tables.error())


## A type's pools under the native tables' names: bush; a natural type's band_, young_, mature_ and dead_
## 0-2 (coast, mid, high); a grid's pool; a mix's tree, tree_young and tree_mature.
static func _type_pools(t: Dictionary) -> Dictionary:
	var out := {"bush": t["bush"]}
	match str(t["style"]):
		"natural":
			for b in ForestTypesRes.BANDS.size():
				var band: String = ForestTypesRes.BANDS[b]
				out["band_%d" % b] = t["bands"][band]
				out["young_%d" % b] = t["young"][band]
				out["mature_%d" % b] = t["mature"][band]
				out["dead_%d" % b] = t["dead"][band]
		"grid":
			out["pool"] = t["pool"]
		"mix":
			out["tree"] = t["tree"]
			out["tree_young"] = t["tree_young"]
			out["tree_mature"] = t["tree_mature"]
	return out


## A pool entry's species: [name, weight] or a bare name (a dead pool's).
static func _entry_name(e) -> String:
	return str(e[0]) if typeof(e) == TYPE_ARRAY else str(e)


## Rescale the flora bands to THIS world's summit. Runs once, when a terrain is
## first available.
##
## A profile describes an ISLAND; a world is one CUT of it, and z_scale is a
## tuning knob. A profile authored against a 1:2 cut (bands at 140/470/700 m), taken
## literally on the 1:1 cut of the same island (summit 1499 m), puts 38.7% OF THE LAND
## ABOVE THE TREELINE, thinned to `treeline_keep`, and squeezes the coast band from
## 30.2% of land to 15.6%. Every tree is in the wrong elevation band, the island still
## renders, and nothing errors: the failure is silent and reads as "trees in odd places".
## A threshold in metres over terrain whose vertical scale is a tuning knob drifts every
## time that knob moves; the profile's PROPORTIONS are what transfer.
##
## THE SUMMIT IS AUTHORED, NOT OBSERVED: see `world_summit_m` and
## `_resolve_world_summit`. With streaming on, get_height_range() covers only the
## resident regions: booted at a map's own start location the data knows 13 regions of
## 1024 and answers 362..526 m, and `calc_height_range(true)` only recomputes over the
## same 13; with none resident it answers 0..0. A partial range is not DEGENERATE, so a
## guard on it passes and the bands latch against whichever hill was loaded.
func _rescale_bands_to_world(terrain) -> void:
	if _bands_rescaled or _profile_treeline_m <= 0.0:
		return
	var summit := _resolve_world_summit(terrain)
	# NOT latched on a summit nothing could answer for. The flag stays down and the
	# bands keep the profile's literal metres (wrong on a re-cut island, but the
	# SAME wrong on every peer and every run, which a streamed read is not).
	if not is_finite(summit) or summit <= 1.0:
		return
	_bands_rescaled = true
	var s := summit / _profile_treeline_m
	if is_equal_approx(s, 1.0):
		return
	var c0 := _coast_m
	var m0 := _mid_m
	var t0 := _treeline_m
	_coast_m *= s
	_mid_m *= s
	_treeline_m = summit
	ForestLog.info("[Vegetation] flora bands x%.2f for this cut: %.0f/%.0f/%.0f -> %.0f/%.0f/%.0f (summit %.0f m)"
			% [s, c0, m0, t0, _coast_m, _mid_m, _treeline_m, summit])


## The summit to take the flora bands' proportions against, or 0 when nothing can
## answer for it yet.
##
## The AUTHORED export first. Then the terrain, but ONLY when streaming is off,
## which is the one case where its range covers the whole map instead of whatever is
## resident; the rigs and small maps that rely on that keep working.
##
## There is deliberately NO third tier reading a terrain importer's own metadata, which
## may carry the composed range: such output folders are often `.gdignore`d and in no
## export preset, so it would resolve in a dev tree and silently not in a build, the
## same defect in a new place.
func _resolve_world_summit(terrain) -> float:
	if world_summit_m > 1.0:
		return world_summit_m
	if terrain == null or not ("data" in terrain) or terrain.data == null:
		return 0.0
	if not terrain.data.has_method("get_height_range"):
		return 0.0
	# NOT `bool(...)`: there is no bool constructor in GDScript, and the resulting
	# runtime error aborts THIS function and returns to the caller with the rescale
	# silently not done: the same class of silent failure this guards against.
	var streaming = terrain.get("streaming_enabled")
	if streaming != null and streaming:
		# Asking anyway is the defect this function exists to stop.
		if not _summit_warned:
			_summit_warned = true
			ForestLog.warn(("[Vegetation] terrain streaming is on and world_summit_m is not set, "
				+ "so the flora bands cannot be rescaled for this cut and keep %s's literal "
				+ "%.0f/%.0f/%.0f m. Set world_summit_m on this spawner to the cut's summit "
				+ "in game metres.") % [profile_path.get_file(), _coast_m, _mid_m,
				_treeline_m])
		return 0.0
	var hr: Vector2 = terrain.data.get_height_range()
	return hr.y


# ── Scatter (pure planning, no terrain needed) ───────────────────────────────

func _plan_scatter() -> void:
	_load_profile()
	if _types.by_id.is_empty():
		return
	# The maps: ring cells ask for them as they enter.
	if not _editor:
		_start_timer()   # the editor drives the ring from _process

## The streaming pump's clock.
func _start_timer() -> void:
	_timer = Timer.new()
	# EVERY FRAME, NOT FOUR TIMES A SECOND. Paired with the time-boxed budget in
	# _resolve_pending, this is what took whole-island resolve from minutes to
	# seconds.
	_timer.wait_time = 0.016
	_timer.timeout.connect(_resolve_pending)
	add_child(_timer)
	_timer.start()


# ── Lazy terrain resolve: one chunk at a time as regions stream in ──────────

## Bring the ring in line with where the camera is: scatter cells that have entered
## it, release cells that have left.
##
## Cheap when nothing has changed: one distance compare. The set is only recomputed
## after `_STREAM_MOVE_M` of travel, because the answer cannot change meaningfully
## inside that.
func _stream_tick() -> void:
	if _types.by_id.is_empty():
		return
	var cam := _camera()
	# NO CAMERA IS NOT NO POSITION. A dedicated server, a boot frame before the
	# player spawns, or the editor button all land here; falling back to the last
	# known focus keeps whatever is already built rather than releasing the world.
	var at := _stream_at
	if cam != null:
		at = Vector2(cam.global_position.x, cam.global_position.z)
		var fwd := -cam.global_transform.basis.z
		_stream_look = Vector2(fwd.x, fwd.z)
	elif not _stream_dirty:
		return
	if not _stream_dirty and at.distance_to(_stream_at) < _STREAM_MOVE_M:
		return
	# A jump past the mesh ring (the first camera, a teleport, a respawn) refills the ring from nothing: a fill.
	if at.distance_to(_stream_at) > mesh_ring_m:
		_filling = true
	_stream_at = at
	_stream_dirty = false
	_stream_ring(at, _chunks, chunk_size, mesh_ring_m, false)
	_update_shadow_ring(at)
	_update_card_density(at)
	if billboard_far_m > tree_visibility_m:
		_stream_ring(at, _bb_cells, billboard_chunk_m, card_ring_m(), true)


## One ring: add cells inside `radius`, drop cells past `radius * _RING_HYSTERESIS`.
##
## `radius <= 0` means unbounded: every cell over a region with a map, the whole island,
## because a small map does not need a ring and a rig sometimes wants the lot.
func _stream_ring(at: Vector2, cells: Dictionary, cell_m: float, radius: float,
		bb_tier: bool) -> void:
	var drop_r := radius * _RING_HYSTERESIS
	if radius > 0.0:
		for k in cells.keys():
			var c := Vector2((float(k.x) + 0.5) * cell_m, (float(k.y) + 0.5) * cell_m)
			# Against the cell's NEAREST corner, not its centre: a 1024 m impostor
			# cell judged by its centre is dropped while 700 m of it is still inside
			# the ring, and the treeline visibly retreats from the player.
			if _cell_near_dist(at, c, cell_m) > drop_r:
				_release_cell(k, cells, bb_tier)
		# Backstop only: the ring is sized to fit inside it with room to spare, so
		# reaching this means the map is denser than the budget was told. Measured
		# worst case on a 50 km² island at 380 stems/ha: 227 k of 320 k, patrolling
		# its two massifs. It stops FILLING rather than thinning, which shows up as a
		# ring that does not close, so it says so once instead of looking like a
		# streaming bug.
		if _spawned > max_instances:
			if not _budget_warned:
				_budget_warned = true
				ForestLog.warn("[Vegetation] ring hit max_instances (%d): it will stop short "
					% max_instances + "of %.0f m. Lower forest.density_per_m2 or raise the cap."
					% mesh_ring_m)
			return
	var r_cells := int(ceil(radius / cell_m)) + 1 if radius > 0.0 else 0
	var here := Vector2i(int(floor(at.x / cell_m)), int(floor(at.y / cell_m)))
	if radius <= 0.0:
		for k in _cells_with_maps(cell_m):
			if not cells.has(k):
				_scatter_cell(k, cells, cell_m, bb_tier)
		return
	# Admit in VIEW PRIORITY, not scanline order. The scatter jobs run in the order
	# they are submitted and the place jobs follow the same order, so which cell goes
	# first here is which forest the player sees arrive first: the one under them,
	# then the one ahead, then the one behind.
	var entering: Array[Vector2i] = []
	var centres := PackedVector2Array()
	for dx in range(-r_cells, r_cells + 1):
		for dy in range(-r_cells, r_cells + 1):
			var k := Vector2i(here.x + dx, here.y + dy)
			if cells.has(k):
				continue
			var c := Vector2((float(k.x) + 0.5) * cell_m, (float(k.y) + 0.5) * cell_m)
			if _cell_near_dist(at, c, cell_m) > radius:
				continue
			entering.append(k)
			centres.append(c)
	for i in ForestStreamOrderRes.order_indices(centres, at, _stream_look):
		_admit(entering[i], cells, cell_m, bb_tier)


## A cell entering the ring: scattered at once while the ring fills; while driving, registered open now (so the
## resolve, the frontier and the shot rig count it) and its scatter job submitted by
## _admit_pending under the stream tick's share of the frame.
func _admit(k: Vector2i, cells: Dictionary, cell_m: float, bb_tier: bool) -> void:
	if _filling:
		_scatter_cell(k, cells, cell_m, bb_tier)
		return
	var entry := {"pts": [], "done": false, "nodes": [], "admitting": true}
	cells[k] = entry
	_admit_queue.append([cells, k, cell_m, bb_tier, entry])


## The admitted cells' scatter jobs in the order the ring admitted them (view priority), until the stream tick's share
## is spent, the first always. A cell released meanwhile is skipped (identity, as for a job).
func _admit_pending() -> void:
	var deadline := Time.get_ticks_usec() + int(_ADMIT_MS * 1000.0)
	var first := true
	while not _admit_queue.is_empty() and (first or Time.get_ticks_usec() < deadline):
		var q: Array = _admit_queue.pop_front()
		var cells: Dictionary = q[0]
		var k: Vector2i = q[1]
		if not cells.has(k) or not is_same(cells[k], q[4]):
			continue
		first = false
		_scatter_cell(k, cells, float(q[2]), bool(q[3]))


## Distance from `at` to the nearest point of the cell centred on `c`.
static func _cell_near_dist(at: Vector2, c: Vector2, cell_m: float) -> float:
	var h := cell_m * 0.5
	var d := Vector2(maxf(absf(at.x - c.x) - h, 0.0), maxf(absf(at.y - c.y) - h, 0.0))
	return d.length()


## Scatter one cell that entered the ring, from the maps, ON A WORKER.
##
## The cell is registered EVEN WHEN EMPTY (`pts` of size 0, done immediately), so a
## cell of open sea is not re-rasterised on every tick for the rest of the session.
##
## OFF THE MAIN THREAD because a ring step is a stall otherwise. Every 64 m of travel
## `_stream_ring` admits a row of cells at once (mesh chunks and 1024 m impostor cells),
## and rasterising them synchronously measured 497 ms in ONE frame driving at 25 m/s,
## 304 ms of it in the road distance across 29 400 candidates. The scatter is pure math
## over data frozen for the job (the native core's), so it goes to the
## WorkerThreadPool and `_collect_scatter` lands the result. While it is in flight the
## entry carries `scattering`, its `pts` are empty and `done` is false: every reader
## of `done` (the resolve, the shot rig's `_open_cells`) keeps its meaning.
func _scatter_cell(k: Vector2i, cells: Dictionary, cell_m: float, bb_tier: bool) -> void:
	if _fill_t0_us == 0:
		_fill_t0_us = Time.get_ticks_usec()
	var rect := Rect2(float(k.x) * cell_m, float(k.y) * cell_m, cell_m, cell_m)
	_scatter_map_cell(k, cells, rect, bb_tier)


func _run_scatter_job(job: Dictionary) -> void:
	var t0 := Time.get_ticks_usec()
	_run_scatter_job_body(job)
	job["us"] = Time.get_ticks_usec() - t0


## WORKER. The native scatter: the items' trees planted and packed here, then one call for the cell.
func _run_scatter_job_body(job: Dictionary) -> void:
	var items: Array = job.get("items", [])
	if not items.is_empty():
		_pack_items(job, items)
	var res: Dictionary = job["core"].scatter_cell(job)
	job["pts"] = res
	job["items_n"] = int(res.get("items_n", 0))
	job["wood"] = res.get("wood", PackedInt32Array())
	job["error"] = str(res.get("error", ""))


## WORKER. A scatter job's single trees and rows for the native scatter: the trees whose base lies
## in the cell, where ForestTrees.planted puts them (the editor's own spots), and every item's clearance as segments
## (ax, az, bx, bz, metres; a single tree's a point).
static func _pack_items(job: Dictionary, items: Array) -> void:
	var pos := PackedFloat32Array()
	var seeds := PackedInt64Array()
	var types := PackedInt32Array()
	var ages := PackedFloat32Array()
	var species := PackedStringArray()
	for t in ForestTreesRes.trees_in(items, job["rect"], int(job["params"]["seed"])):
		var it: Dictionary = t["item"]
		var p: Vector2 = t["p"]
		pos.append(p.x)
		pos.append(p.y)
		seeds.append(int(t["seed"]))
		types.append(int(it["type"]))
		ages.append(float(it["age"]))
		species.append(str(it.get("species", "")))
	var clear := PackedFloat32Array()
	for it in items:
		var r := float(it["clear_m"])
		if r <= 0.0:
			continue
		if it["kind"] == "tree":
			var a: Vector2 = it["at"]
			clear.append_array(PackedFloat32Array([a.x, a.y, a.x, a.y, r]))
			continue
		var pts: PackedVector2Array = it["points"]
		for i in range(1, pts.size()):
			clear.append_array(PackedFloat32Array([pts[i - 1].x, pts[i - 1].y, pts[i].x, pts[i].y, r]))
	job["item_pos"] = pos
	job["item_seed"] = seeds
	job["item_type"] = types
	job["item_age"] = ages
	job["item_species"] = species
	job["clear"] = clear


## A cell's points: a native scatter's packed points ({"n", …}), or the [] a cell starts with. Tools read it too.
static func point_count(pts) -> int:
	if pts is Dictionary:
		return int((pts as Dictionary).get("n", 0))
	return (pts as Array).size() if pts is Array else 0


## Land finished scatter jobs: the cell takes its points, the wood-membership grid
## merges, and a cell released while its job was in flight drops the result rather
## than coming back from the dead. `block` waits for every job: the editor preview
## and shutdown use it; the streaming pump never does.
func _collect_scatter(block: bool = false) -> void:
	var i := 0
	while i < _scatter_jobs.size():
		var job: Dictionary = _scatter_jobs[i]
		var id: int = job["task"]
		if not block and not WorkerThreadPool.is_task_completed(id):
			i += 1
			continue
		WorkerThreadPool.wait_for_task_completion(id)
		_scatter_jobs.remove_at(i)
		_fill_scatter_us += int(job.get("us", 0))
		if str(job.get("error", "")) != "":
			_native_warn("scatter " + str(job["error"]), "[Wuifwoud] a forest cell grew nothing: %s" % job["error"])
		var cells: Dictionary = job["cells"]
		var k: Vector2i = job["key"]
		# Identity, not equality: `_release_cell` + a re-entry makes a NEW entry for
		# the same key, and the late result belongs to the old one.
		if not cells.has(k) or not is_same(cells[k], job["entry"]):
			continue
		var entry: Dictionary = cells[k]
		var pts = job["pts"]
		entry["pts"] = pts
		entry["done"] = point_count(pts) == 0
		entry.erase("scattering")
		if not bool(job["bb"]):
			_items_planted += int(job.get("items_n", 0))
		_merge_wood(job["wood"])
		if point_count(pts) > 0:
			_settled = false


## A scatter job's wood-membership cells, (cell x, cell z, type) triples, into the grid the clutter ring reads. A cell
## already there keeps its type.
func _merge_wood(w: PackedInt32Array) -> void:
	for i in range(0, w.size() - 2, 3):
		var c := Vector2i(w[i], w[i + 1])
		if not _wood_cells.has(c):
			_wood_cells[c] = w[i + 2]


## Said once per reason: a native job that refused its inputs lands empty.
func _native_warn(key: String, msg: String) -> void:
	if _native_warned.has(key):
		return
	_native_warned[key] = true
	ForestLog.warn(msg)


## Outstanding jobs hold this node's bound method and read the road
## blocker, so they must finish before either goes away.
func _drain_scatter_jobs() -> void:
	for job in _scatter_jobs:
		WorkerThreadPool.wait_for_task_completion(job["task"])
	_scatter_jobs.clear()


func _exit_tree() -> void:
	_drain_scatter_jobs()
	_drain_place_jobs()
	maps.drain()
	if _far != null:
		_far.drain()
	if _pump != null:
		_pump.drain()
	if _editor:
		_editor_teardown()


# ── The forest from its maps ──────────────────────────────────────────────────

## Map mode's half of _scatter_cell: a cell whose maps are all held (or that has none) is
## scattered on a worker, or registered empty at once when neither a map type nor a single tree or row reaches it; any
## other WAITS (`mapwait`), never registered empty, until _feed_maps has its maps in.
func _scatter_map_cell(k: Vector2i, cells: Dictionary, rect: Rect2, bb_tier: bool) -> void:
	# Without the native core no forest grows: the cell is registered empty, and that is said once.
	if not ForestNativeRes.available():
		ForestNativeRes.warn_missing()
		cells[k] = {"pts": [], "done": true, "nodes": []}
		return
	if maps.configured():
		var locs := _map_locs(rect)
		if locs.all(func(l): return maps.is_held(l)):
			_scatter_or_empty(k, cells, rect, bb_tier, locs)
			return
	cells[k] = {"pts": [], "done": false, "nodes": [], "mapwait": true}
	_map_waiting = true


## A cell whose maps are all held (or that has none): registered empty at once when neither a map type (the block
## summary) nor an item reaches it (a worker would find nothing), else scattered on a worker.
func _scatter_or_empty(k: Vector2i, cells: Dictionary, rect: Rect2, bb_tier: bool, locs: Array) -> void:
	var items := _items_for(rect)
	if items.is_empty() and (locs.is_empty() or maps.blocks_in(locs, rect).is_empty()):
		cells[k] = {"pts": [], "done": true, "nodes": []}
		return
	_submit_map_scatter(k, cells, rect, bb_tier, locs, items)


func _submit_map_scatter(k: Vector2i, cells: Dictionary, rect: Rect2, bb_tier: bool, locs: Array,
		items: Array = []) -> void:
	var entry := {"pts": [], "done": false, "nodes": [], "scattering": true}
	cells[k] = entry
	var job := _scatter_job(rect, bb_tier, locs, items)
	job["key"] = k
	job["cells"] = cells
	job["entry"] = entry
	job["task"] = WorkerThreadPool.add_task(_run_scatter_job.bind(job), false, "wf_scatter")
	_scatter_jobs.append(job)


## A scatter job for `rect`, read HERE on the main thread: the held maps' bytes (copy on write),
## their block summary, copies of the items reaching it, and the native core, tables, road corridor and numbers it keeps
## for its whole run. Tests and tools run one with _run_scatter_job_body.
## EVERY KEY THE WORKER WRITES IS MADE HERE, and the task id's too: the main thread reads the job ("task") every tick
## while the worker runs, and a Dictionary that grows on one thread while another reads it is a data race (Godot's
## threading rule); writing an existing key never resizes it.
func _scatter_job(rect: Rect2, bb_tier: bool, locs: Array, items: Array) -> Dictionary:
	return {"rect": rect, "view": maps.view(locs), "blocks": maps.blocks_in(locs, rect), "region_m": maps.region_m(),
		"bb": bb_tier, "pts": [], "wood": PackedInt32Array(), "items": items, "core": ForestNativeRes.core(),
		"tables": _tables_now(), "roads": _roads,
		"params": {"seed": forest_seed, "quality": _quality_density_scale, "wood": clutter_enabled,
			"item_margin": item_road_margin},
		"task": -1, "us": 0, "items_n": 0, "error": "", "item_pos": PackedFloat32Array(), "item_seed": PackedInt64Array(),
		"item_type": PackedInt32Array(), "item_age": PackedFloat32Array(), "item_species": PackedStringArray(),
		"clear": PackedFloat32Array()}


## The regions under `rect` that have a map.
func _map_locs(rect: Rect2) -> Array:
	var out := []
	var l0 := maps.location_of(rect.position.x, rect.position.y)
	var l1 := maps.location_of(rect.end.x - 0.001, rect.end.y - 0.001)
	for lz in range(l0.y, l1.y + 1):
		for lx in range(l0.x, l1.x + 1):
			if maps.has_map(Vector2i(lx, lz)):
				out.append(Vector2i(lx, lz))
	return out


## Every cell of size `cell_m` over a region with a map, or reached by a single tree or a row (the unbounded mode).
func _cells_with_maps(cell_m: float) -> Array:
	if not maps.configured():
		return []
	var out := {}
	var rm := maps.region_m()
	for loc in maps.locations():
		var c0 := Vector2i(floori(float(loc.x) * rm / cell_m), floori(float(loc.y) * rm / cell_m))
		var c1 := Vector2i(floori((float(loc.x + 1) * rm - 0.001) / cell_m),
			floori((float(loc.y + 1) * rm - 0.001) / cell_m))
		for cx in range(c0.x, c1.x + 1):
			for cy in range(c0.y, c1.y + 1):
				out[Vector2i(cx, cy)] = true
	for e in trees.extents():
		var er: Rect2 = e
		for cx in range(floori(er.position.x / cell_m), floori(er.end.x / cell_m) + 1):
			for cy in range(floori(er.position.y / cell_m), floori(er.end.y / cell_m) + 1):
				out[Vector2i(cx, cy)] = true
	return out.keys()


## Map mode: point the maps at the terrain's regions once a terrain is found. Tests configure their own.
func _ensure_maps(terrain: Node) -> void:
	if _types.by_id.is_empty() or maps.configured():
		return
	var rs_v = terrain.get("region_size")
	var rs := int(rs_v) if rs_v != null else 0
	if rs <= 0:
		return
	var vs_v = terrain.get("vertex_spacing")
	var dir := maps_directory
	if dir == "":
		var dd_v = terrain.get("data_directory")
		dir = String(dd_v).path_join(ForestMapsRes.FOLDER) if dd_v != null and String(dd_v) != "" else ""
	maps.configure(rs, float(vs_v) if vs_v != null else 1.0, dir)
	trees.configure(dir.path_join(ForestTreesRes.FILE) if dir != "" else "")
	for e in trees.errors:
		ForestLog.warn("[Wuifwoud] %s" % e)
	maps.type_ids = _types.ids()
	var data = terrain.get("data")
	if data != null and data.has_method("has_region"):
		maps.region_exists = func(l: Vector2i) -> bool: return bool(data.call("has_region", l))
	if maps.file_count() == 0 and not _maps_warned:
		_maps_warned = true
		ForestLog.warn(("[Vegetation] no forest maps in %s, so nothing grows. The forest import writes them "
			+ "(res://addons/wuifwoud/tools/import_forest.gd)") % (dir if dir != "" else
			"<maps_directory is empty and the terrain has no data_directory>"))
	_stream_dirty = true   # cells admitted before the maps were known are fed; the unbounded mode re-lists


## Map mode, every tick: land finished map reads; keep the maps the waiting cells need, nearest
## first and within the maps' budget (the FIRST waiting cell always gets all of its, so a cell needing more maps than
## the budget still scatters); ask for the missing ones; scatter every waiting cell whose maps are all in.
func _feed_maps() -> void:
	if not maps.configured():
		return
	maps.collect()
	if not _map_waiting:
		return
	var plans: Array = []      # [cells, key, rect, bb, locs]
	var needed := {}
	var cap := maps.budget_regions()
	var full := false
	for tier in [_chunks, _bb_cells]:
		var cell_m: float = chunk_size if tier == _chunks else billboard_chunk_m
		for ck in _resolve_order(tier, cell_m):
			if not bool((tier[ck] as Dictionary).get("mapwait", false)):
				continue
			var rect := Rect2(float(ck.x) * cell_m, float(ck.y) * cell_m, cell_m, cell_m)
			var locs := _map_locs(rect)
			var add := 0
			for l in locs:
				if not needed.has(l):
					add += 1
			if not plans.is_empty() and needed.size() + add > cap:
				full = true
				break
			for l in locs:
				needed[l] = true
			plans.append([tier, ck, rect, tier == _bb_cells, locs])
		if full:
			break
	if plans.is_empty():
		_map_waiting = false
		return
	maps.keep_only(needed)
	for l in needed:
		maps.request(l)
	for pl in plans:
		var locs: Array = pl[4]
		if locs.all(func(l): return maps.is_held(l)):
			_scatter_or_empty(pl[1], pl[0], pl[2], pl[3], locs)


func _log_maps_stats() -> void:
	if maps.configured():
		ForestLog.debug("[Vegetation] forest maps: %s" % str(maps.debug_stats()))


## The items reaching `rect`, as copies a scatter worker may read: a pinned species no pack has is
## dropped from the copy, so the type picks; a type the profile lacks grows nothing (the native place);
## each is named once, here, on the main thread.
func _items_for(rect: Rect2) -> Array:
	var out: Array = trees.near(rect)
	for it in out:
		var ty := int(it.get("type", 0))
		if _types.get_type(ty).is_empty() and not _type_warned.has(ty):
			_type_warned[ty] = true
			ForestLog.warn("[Wuifwoud] a single tree or row names type %d, which the profile lacks: it grows nothing" % ty)
		var sp := str(it.get("species", ""))
		if sp != "" and not ForestAssets.has_species(sp):
			if not _species_warned.has(sp):
				_species_warned[sp] = true
				if ForestAssets.is_disabled(sp):
					ForestLog.warn("[Wuifwoud] a single tree or row pins species %s, which is switched off: its type picks instead" % sp)
				else:
					ForestLog.warn("[Wuifwoud] a single tree or row pins species %s, which no species pack has: its type picks instead" % sp)
			it["species"] = ""
	return out


## Every species the profile's pools and its types' own mixes name, sorted (the Place tools' species picker).
func species_names() -> PackedStringArray:
	var seen := {}
	for band in _species:
		var pool = _species[band]
		if typeof(pool) != TYPE_ARRAY:
			continue
		for e in pool:
			seen[str(e[0]) if typeof(e) == TYPE_ARRAY else str(e)] = true
	for id in _types.ids():
		for pool in _type_pools(_types.get_type(id)).values():
			for e in pool:
				seen[_entry_name(e)] = true
	var out := PackedStringArray(seen.keys())
	out.sort()
	return out


## Why a single tree or a row's tree at `p` would not grow there, for the Place tools' cursor note:
## "on a road", "under water", "too steep", or "" (it grows, or the ground is not known yet). The main thread.
func item_gate(p: Vector2) -> String:
	if _road_blocked_within(p, item_road_margin):
		return "on a road"
	var t := terrain_source if terrain_source != null else ForestTerrainRes.find_cached(self)
	var data = t.get("data") if t != null else null
	if data == null or not data.has_method("get_height"):
		return ""
	var h: float = data.get_height(Vector3(p.x, 0.0, p.y))
	if is_nan(h):
		return ""
	if h < sea_level:
		return "under water"
	var vs_v = t.get("vertex_spacing")
	var s := float(vs_v) if vs_v != null else 1.0
	var hx: float = data.get_height(Vector3(p.x + s, 0.0, p.y))
	var hz: float = data.get_height(Vector3(p.x, 0.0, p.y + s))
	if not is_nan(hx) and not is_nan(hz) and Vector2(h - hx, h - hz).length() / s > _SLOPE_MAX:
		return "too steep"
	return ""


## The last whole frame's main-thread work, µs per phase (FRAME_PHASES) and its "total": stream (the
## ring's diff, its cells' scatter jobs submitted), frees (cells released), scatter and place (finished jobs collected),
## feed (the maps' and the height pump's landings), far (the far forest's tick and landing), commit (installs), trunks,
## crowns, flush (the card cells), resolve (place jobs submitted), upload (the GPU path's frame message), process
## (wind, push, clutter). A frame with no forest work reads zeros. The drive bench reads it every frame.
func frame_timings() -> Dictionary:
	_ft_roll()
	var out := {}
	var total := 0
	for p in FRAME_PHASES:
		var us := int(_ft_last.get(p, 0))
		out[p] = us
		total += us
	out[&"total"] = total
	return out


func _ft_roll() -> void:
	var f := Engine.get_process_frames()
	if f == _ft_frame:
		return
	_ft_last = _ft_cur if _ft_frame == f - 1 else {}
	_ft_cur = {}
	_ft_frame = f
	_ft_stack.clear()    # a phase an aborted function left open never charges the next frame


func _ft_begin(phase: StringName) -> void:
	_ft_roll()
	_ft_stack.append([phase, Time.get_ticks_usec(), 0])


func _ft_end() -> void:
	if _ft_stack.is_empty():
		return
	var e: Array = _ft_stack.pop_back()
	var dt: int = Time.get_ticks_usec() - int(e[1])
	_ft_cur[e[0]] = int(_ft_cur.get(e[0], 0)) + dt - int(e[2])
	if not _ft_stack.is_empty():
		var parent: Array = _ft_stack[_ft_stack.size() - 1]
		parent[2] = int(parent[2]) + dt


## Free a cell's MultiMeshes and forget its trunks.
##
## The trunk registry has to be pruned with the cell or it grows without bound over
## a long session, and worse, `trunks_near` would hand the collision pool a trunk
## that no longer has a tree on it. `_TRUNK_CELL` (64 m) divides both cell sizes
## exactly, so a trunk cell belongs to exactly one cell of either tier.
func _release_cell(k: Vector2i, cells: Dictionary, bb_tier: bool) -> void:
	_ft_begin(&"frees")
	var cell: Dictionary = cells[k]
	for n in cell.get("nodes", []):
		if not is_instance_valid(n):
			continue
		var mmi := n as MultiMeshInstance3D
		if not bb_tier and mmi.multimesh != null:
			_spawned -= mmi.multimesh.instance_count
		mmi.queue_free()
	if _indirect != null:
		for h in cell.get("iblocks", []):
			_spawned -= int((h as Dictionary).get("n", 0))
			_indirect.free_block(h)
		cell["iblocks"] = []
	if bb_tier:
		for key in cell.get("bb_keys", []):
			_bb_nodes.erase(key)
			if _indirect != null and _bb_blocks.has(key):
				_indirect.free_block(_bb_blocks[key])
				_bb_blocks.erase(key)
		_bb_accum.erase(k)
		_bb_left.erase(k)
	else:
		var cm: float = chunk_size
		var t0 := Vector2i(int(floor(float(k.x) * cm / _TRUNK_CELL)),
			int(floor(float(k.y) * cm / _TRUNK_CELL)))
		var span := int(ceil(cm / _TRUNK_CELL))
		for tx in range(t0.x, t0.x + span):
			for ty in range(t0.y, t0.y + span):
				_trunk_cells.erase(Vector2i(tx, ty))
				_crown_cells.erase(Vector2i(tx, ty))
		# Wood membership prunes with the chunk for the same reason the trunks do
		# (16 m divides the chunk exactly). Only read while clutter is on: the native
		# scatter marks it only then.
		if clutter_enabled:
			var w0 := Vector2i(int(floor(float(k.x) * cm / _WOOD_CELL)),
				int(floor(float(k.y) * cm / _WOOD_CELL)))
			var wspan := int(ceil(cm / _WOOD_CELL))
			for wx in range(w0.x, w0.x + wspan):
				for wy in range(w0.y, w0.y + wspan):
					_wood_cells.erase(Vector2i(wx, wy))
	cells.erase(k)
	_ft_end()


func _resolve_pending() -> void:
	if _preview_off:
		return
	_ft_begin(&"stream")
	_stream_tick()
	_admit_pending()
	_ft_end()
	_ft_begin(&"scatter")
	_collect_scatter()
	_ft_end()
	var terrain := terrain_source if terrain_source != null else ForestTerrainRes.find_cached(self)
	if terrain == null:
		return
	_ft_begin(&"feed")
	_rescale_bands_to_world(terrain)
	_ensure_maps(terrain)
	_feed_maps()
	_ensure_pump(terrain)
	if _pump != null:
		_pump.collect()
	_ft_end()
	_box_open()
	_ft_begin(&"far")
	_far_tick(terrain)
	_ft_end()
	_ft_begin(&"place")
	_collect_place()
	_ft_end()
	_ft_begin(&"resolve")
	var open := 0
	var deadline := Time.get_ticks_usec() + int(resolve_budget_ms * 1000.0)
	# The submission shares the frame's box: what the far landing and the commit left of it.
	if _box_until_us > 0:
		deadline = mini(deadline, _box_until_us)
	var submitted := 0
	# MESH FIRST, THEN IMPOSTORS, and the order is load-bearing on arrival: the mesh
	# ring is what the player is standing in, and a shared nearest-first sort over
	# both tiers would interleave 2.8 km impostor cells into the 1 km of forest
	# around the camera and fill the near view last.
	for tier in [_chunks, _bb_cells]:
		var cell_m: float = chunk_size if tier == _chunks else billboard_chunk_m
		for ck in _resolve_order(tier, cell_m):
			if Time.get_ticks_usec() > deadline and submitted > 0:
				# Count what is left so the settle test below stays honest.
				for rest in tier:
					if not bool((tier[rest] as Dictionary)["done"]):
						open += 1
				break
			var chunk: Dictionary = tier[ck]
			if bool(chunk["done"]):
				continue
			open += 1
			# Still being rasterised or placed on a worker: open, nothing to do here.
			if bool(chunk.get("scattering", false)) or bool(chunk.get("placing", false)) \
					or bool(chunk.get("mapwait", false)) or bool(chunk.get("admitting", false)):
				continue
			# Ask the pump for the region copies the chunk sits on and hand the whole chunk
			# to the pool once they are in. Nothing per point happens on this thread. A
			# terrain that hands out no copies (no get_regionp) places nothing.
			if _pump == null:
				_native_warn("no pump", "[Wuifwoud] the terrain hands out no region copies (get_regionp), so the forest places nothing")
				continue
			if _regions_ready(ck, cell_m):
				_submit_place(ck, chunk, tier, cell_m, tier == _bb_cells)
				submitted += 1
	if open == 0:
		_filling = false
	# The cards' hand-over follows what the mesh ring has actually built, so it has to
	# be recomputed after this tick's placements landed and before the flush pushes
	# the material.
	_update_mesh_frontier()
	# ONE billboard flush per frame, under the commit box: it covers the worker
	# commits that ran in _collect_place above. A flush per landed job would copy, in a frame
	# that landed five jobs, five coarse cells' arenas on the main thread with no deadline in
	# sight: see the note in _commit_place and add_block's own.
	if not _bb_touched.is_empty():
		_flush_billboards()
	_reserve_after_fill()
	# THE TIMER NEVER STOPS: it is the STREAMING PUMP, and stopping it would strand the ring
	# wherever the player happened to be when the last chunk landed. Idle cost is one distance
	# compare against `_stream_at`: `_stream_tick` returns before doing anything else until
	# the camera has moved `_STREAM_MOVE_M`.
	# FIRST-FILL ONLY. The ring reaches steady state constantly while driving; this
	# reports the initial fill so a boot can be judged, and then goes quiet rather
	# than logging a line every time a chunk lands.
	if open == 0 and not _settled and _spawned > 0:
		_settled = true
		ForestLog.debug(("[Vegetation] ring filled: %d instances, %d MMIs, %.0f%% of max_instances "
			+ "(%d mesh chunks, %d impostor cells) in %.1f s; workers: scatter %.1f s, "
			+ "place %.1f s; main: commit %.0f ms over %d ticks (species %.0f ms, impostor "
			+ "flushes %.0f ms; %d ticks held back by the %.1f ms commit box)") % [
			_spawned, get_child_count(),
			100.0 * float(_spawned) / maxf(float(max_instances), 1.0),
			_chunks.size(), _bb_cells.size(),
			float(Time.get_ticks_usec() - _fill_t0_us) / 1e6 if _fill_t0_us > 0 else 0.0,
			_fill_scatter_us / 1e6, _fill_place_us / 1e6, _fill_commit_us / 1e3,
			_fill_commit_ticks, _fill_species_us / 1e3, _fill_flush_us / 1e3,
			_fill_starved_ticks, commit_budget_ms])
		_log_drawable_split()
		_log_bush_cuts()
		_log_pump_stats()
		_log_maps_stats()
	_box_until_us = 0
	_ft_end()


## The far forest: made once, ticked from the resolve pump; freed when switched off.
func _far_tick(terrain: Node) -> void:
	if not far_forest:
		_free_far()
		return
	_ensure_far()
	_far.box_until_us = _box_until_us
	_far.tick(terrain)


func _ensure_far() -> void:
	if _far != null:
		return
	_far = ForestFarRes.new()
	_far.name = "FarForest"
	_far.forest = self
	_far.top_level = true
	var band := _far_band()
	_far.set_band(band.x, band.y)
	add_child(_far, false, Node.INTERNAL_MODE_BACK)


func _free_far() -> void:
	if _far == null:
		return
	_far.drain()
	remove_child(_far)
	_far.queue_free()
	_far = null


## The forest's rules by place, for the far forest's mesh: the sea line, the elevation bands, the treeline,
## the slope's thinning band and cut.
func far_rules() -> Dictionary:
	return {"sea": sea_level, "coast": _coast_m, "mid": _mid_m, "treeline": _treeline_m, "slope_thin": _SLOPE_THIN,
		"slope_max": _SLOPE_MAX}


## Where the cards end and the far forest's handover under them: the shell's band covers the cards' own
## dissolve (a band shorter than theirs leaves a ring where the cards thin with no shell under them; at the 3000 m
## tier theirs is 660 m, far_fade_m 600); cards that never end (billboard_far_m 0) leave no room for a far forest.
func _far_band() -> Vector2:
	if billboard_far_m <= 0.0:
		return Vector2(1.0e9, far_fade_m)
	return Vector2(billboard_far_m, maxf(far_fade_m, _card_far_fade()))


## The cards' far dissolve, metres before billboard_far_m: 22 % of it, at least 120 m (their material's far_fade).
func _card_far_fade() -> float:
	return maxf(billboard_far_m * 0.22, 120.0)


## The near forest comes first: the far forest starts none of its own work while this has a scatter or place job or a map
## read in flight, nor before the ring around the player has filled once (at most FAR_HOLD_MS, as a ring with nothing
## to grow, a boat at sea, never reports filled). Both share the engine's low-priority worker lane and this thread
## (measured windowed, ABBA: the first fill 2.5 s with the far forest off, 3.0 s starting at once, 2.9 s yielding only
## to work in flight).
func near_busy() -> bool:
	# Its cards not all drawn yet is the near forest still filling: the far forest's start and its new
	# builds would otherwise take the frame's box from the card flush, one item a frame (0.45 s of the first fill).
	if not _scatter_jobs.is_empty() or not _place_jobs.is_empty() or not maps._loading.is_empty() \
			or not maps._summing.is_empty() or not _bb_touched.is_empty():
		return true
	if _far_hold_until < 0:
		_far_hold_until = Time.get_ticks_msec() + FAR_HOLD_MS
	return not _settled and Time.get_ticks_msec() < _far_hold_until

## WHERE THE GROUND HEIGHTS CAME FROM. The far field is only unbound from terrain
## residency because ForestHeightPump can fall back to the region FILES, and that
## fallback costs a ~5 ms load per region on a worker, so the two numbers that decide
## whether it is too heavy are how many disk loads a fill needed and how many of them
## were RELOADS (the same region fetched twice, i.e. the LRU thrashing against
## PUMP_REGIONS). `absent` is regions with no file at all, which is normal at the map
## edge and is what keeps an off-map cell from blocking forever.
func _log_pump_stats() -> void:
	if _pump == null:
		return
	var st: Dictionary = _pump.stats
	ForestLog.debug("[Vegetation] region heights: %d live, %d from disk, %d off-map, %d reloads "
		% [st.get("live", 0), st.get("disk", 0), st.get("absent", 0), st.get("reload", 0)]
		+ "(cache holds %d)" % PUMP_REGIONS)


## WHAT EACH BUSH SPECIES ACTUALLY CUT AT. `bush_px_min` derives the distance from the
## species' mesh height, so the numbers that ship are not in any file; printing them
## is the only way the authoring decision can be checked against the plant.
func _log_bush_cuts() -> void:
	if bush_px_min <= 0.0:
		return
	var line := ""
	var seen := {}
	for sm in ForestAssets._live_materials:
		if not is_instance_valid(sm):
			continue
		var nm := String(sm.resource_name)
		if not ForestAssets.is_bush_mesh(nm) or seen.has(nm):
			continue
		seen[nm] = true
		line += "%s %.1fm@%.0fm, " % [nm, ForestAssets.species_height(nm), _species_cut_m(nm)]
	if line != "":
		ForestLog.debug("[Vegetation] bush cuts (%.0f px floor, cap %.0f m): %s"
			% [bush_px_min, bush_visibility_m, line.trim_suffix(", ")])


## WHERE THE DRAWABLES ARE, by tier and by species. The forest is CPU-bound in
## per-drawable cull and submit, so the count is the thing to attack, and "one
## MultiMesh per species per chunk" means the
## SPECIES POOL is a performance number, not only an art one. A band with eight bush
## species costs eight drawables in every chunk it touches, whether or not eight kinds
## of bush are distinguishable at 40 m.
func _log_drawable_split() -> void:
	var by_kind := {"mesh_tree": 0, "mesh_bush": 0, "card": 0}
	var per_species := {}
	for c in get_children():
		if not (c is MultiMeshInstance3D):
			continue
		var nm := String(c.name)
		var sp := nm.substr(nm.rfind("_") + 1)
		# Species names carry underscores; take everything after the cell/bucket block.
		var parts := nm.split("_")
		if parts.size() > 5:
			sp = "_".join(Array(parts).slice(5))
		per_species[sp] = int(per_species.get(sp, 0)) + 1
		if nm.contains("BB_"):
			by_kind["card"] += 1
		elif ForestAssets.is_bush_mesh(sp):
			by_kind["mesh_bush"] += 1
		else:
			by_kind["mesh_tree"] += 1
	var top := per_species.keys()
	top.sort_custom(func(a, b): return per_species[a] > per_species[b])
	var line := ""
	for i in mini(6, top.size()):
		line += "%s %d, " % [top[i], per_species[top[i]]]
	var gpu := ""
	if _indirect != null:
		gpu = "; INDIRECT %d bands / %d instances" % [
			_indirect.drawable_count(), _indirect.instance_count()]
	ForestLog.debug("[Vegetation] drawables: %d mesh-tree, %d mesh-BUSH, %d card%s; top: %s"
		% [by_kind["mesh_tree"], by_kind["mesh_bush"], by_kind["card"], gpu,
			line.trim_suffix(", ")])


## Unresolved chunks, NEAREST THE CAMERA FIRST.
##
## This is the change that matters to a player, separately from throughput. The
## resolve in dictionary order (effectively arbitrary) could land the trees around
## you first or last, and on a 5000-hectare island "last" is most of a minute of
## standing in a clearing that should be forest. Sorted by distance, the view you are
## actually in fills immediately and the far slopes catch up behind you, which also
## happens to be the order the billboards are least likely to be noticed arriving in.
##
## Recomputed per tick because the camera moves; it is a sort of the OPEN chunks
## only, which shrinks as the island resolves.
func _resolve_order(cells: Dictionary, cell_m: float) -> Array:
	var open: Array = []
	for ck in cells:
		if not bool((cells[ck] as Dictionary)["done"]):
			open.append(ck)
	if open.size() < 2:
		return open
	var cam := get_viewport().get_camera_3d() if is_inside_tree() else null
	var here := _stream_at
	if cam != null:
		here = Vector2(cam.global_position.x, cam.global_position.z)
	var half := cell_m * 0.5
	var centres := PackedVector2Array()
	centres.resize(open.size())
	for i in open.size():
		var k: Vector2i = open[i]
		centres[i] = Vector2(float(k.x) * cell_m + half, float(k.y) * cell_m + half)
	# ForestStreamOrder: nearest first, ahead of the camera before behind it: the same
	# rule the grass ring drains by, so both fill in the same order.
	var ordered: Array = []
	ordered.resize(open.size())
	var order := ForestStreamOrderRes.order_indices(centres, here, _stream_look)
	for i in open.size():
		ordered[i] = open[order[i]]
	return ordered


# ── Placement on workers ─────────────────────────────────────────────────────
#
# A chunk's points are placed by a WorkerThreadPool job reading heights from the
# pump's REGION COPIES (ForestHeightCache: the copy is what makes this legal; see
# that file), and the job hands back packed MultiMesh buffers. The main thread's
# share of a chunk is: ask for the copies, submit, and one `buffer =` per species on
# commit. On the main thread the per-point work (10-20 k `get_height` Variant calls and
# every gate) would not fit a 2 ms box, and a commit would issue thousands of
# set_instance_* calls in one frame.

## Copies of the most recent regions the place jobs needed, ~4 MB each at 1024²
## (1 MB at 512²). The mesh ring spans at most a 3x3 of them; impostor cells reach
## further.
##
## 32, with the pump's disk fallback: a 1024 m impostor cell fetches the up-to-2x2
## regions it straddles, and several cells are in flight at once. 16 makes those evict
## each other: `ForestHeightPump.stats.reload` is the number to watch, and it is
## logged at first fill.
const PUMP_REGIONS := 32
## Memory the region cache may hold. The cap has to be in BYTES, not regions: a
## region is 1 MB at 512² and spacing 2, and 4 MB at 1024² and spacing 1, so one slot
## count cannot mean the same thing on both maps.
const PUMP_BUDGET_MB := 256.0


## How many region copies to keep, from the ring that actually needs them.
##
## MEASURED THRASH: at a fixed 32 slots, a 60 s flight at 120 m/s logged 694 disk
## loads of which 641 were RELOADS (92 %), which is the signature of a working set
## larger than the cache (the hit rate collapses to near zero rather than degrading).
## 32 was sized for the MESH ring, which spans a 3x3 of regions; the impostor ring is
## 2800 m and spans about 7x7.
##
## A miss is not just a reload, either: `_submit_place` snapshots the cache for the
## worker, so a region evicted between `_regions_ready` and the snapshot makes every
## height lookup over it walk the slow path and return NAN: the point is then dropped
## AND the cell is marked done.
static func _pump_slots(region_size: int, span: float, ring_m: float) -> int:
	if region_size <= 0 or span <= 0.001:
		return 16
	var across := int(ceil(2.0 * ring_m / span)) + 2
	var need := across * across
	var mb_each := float(region_size) * float(region_size) * 4.0 / 1048576.0
	var cap := int(PUMP_BUDGET_MB / maxf(mb_each, 0.001))
	return clampi(mini(need, cap), 9, maxi(need, 9))


func _ensure_pump(terrain: Node) -> void:
	if _pump != null:
		return
	var td = terrain.get("data")
	var rs_v = terrain.get("region_size")
	var rs: int = int(rs_v) if rs_v != null else 0
	if td == null or rs <= 0 or not td.has_method("get_regionp"):
		return
	var vs_v = terrain.get("vertex_spacing")
	_pump = ForestHeightPump.new()
	# THE DATA DIRECTORY IS WHAT UNBINDS THE FAR FIELD from terrain residency. Without
	# it the pump can only copy regions Terrain3D has STREAMED (8 of 1024 on one
	# island, about 1536 m, against a 2800 m impostor ring), so the distance has no
	# trees and the cells that reach past it are marked done with nothing in them.
	# See ForestHeightPump's header.
	# With pump_disk_fallback off the pump still reads the directory, to know which regions exist, and loads none.
	var dd_v = terrain.get("data_directory")
	var dd := String(dd_v) if dd_v != null else ""
	var vs := float(vs_v) if vs_v != null else 1.0
	var span := float(rs) * vs
	var ring := _max_card_ring_m()
	var slots := _pump_slots(rs, span, ring)
	var need := int(ceil(2.0 * ring / maxf(span, 0.001))) + 2
	need *= need
	_pump.configure(td, rs, vs, slots, dd, pump_disk_fallback, dd_v != null)
	if slots < need:
		# SAY IT rather than thrash silently: below the ring's footprint the hit rate
		# collapses and every place job pays for it. `stats.reload` at first fill is
		# the confirmation.
		ForestLog.warn(("[Vegetation] region cache %d slots (%.0f MB budget) is under the "
			+ "%.0f m ring's %d-region footprint at %.0f m regions; expect reloads. "
			+ "Raise PUMP_BUDGET_MB or lower billboard_far_m.")
			% [slots, PUMP_BUDGET_MB, ring, need, span])
	if dd.is_empty() and pump_disk_fallback:
		ForestLog.warn("[Vegetation] terrain has no data_directory: the forest's far field "
			+ "stays bound to streamed regions")


## Are the region copies under this cell in? Asks the pump for any that are not.
## The CENTRE region is required; a neighbour still in flight is waited for; one the
## terrain has not streamed is not: its points read NAN and are skipped.
func _regions_ready(ck: Vector2i, cell_m: float) -> bool:
	var cache := _pump.cache
	var span := float(cache.region_size) * cache.vertex_spacing
	var x0 := float(ck.x) * cell_m
	var z0 := float(ck.y) * cell_m
	var l0 := cache.region_location(x0, z0)
	var l1 := cache.region_location(x0 + cell_m - 0.001, z0 + cell_m - 0.001)
	var lc := cache.region_location(x0 + cell_m * 0.5, z0 + cell_m * 0.5)
	var ready := true
	for lx in range(l0.x, l1.x + 1):
		for lz in range(l0.y, l1.y + 1):
			var loc := Vector2i(lx, lz)
			if cache.has_region(loc):
				continue
			var probe := Vector3((float(lx) + 0.5) * span, 0.0, (float(lz) + 0.5) * span)
			_pump.ensure(probe)
			# The centre region is waited for unless it is off the map: a card cell over a small terrain's corner has
			# its centre where no region is, and would never place its cards nor let the fill end.
			if (loc == lc and not _pump.absent(probe)) or _pump.pending(probe):
				ready = false
	return ready


func _submit_place(ck: Vector2i, chunk: Dictionary, cells: Dictionary, cell_m: float, bb_tier: bool) -> void:
	chunk["placing"] = true
	var x0 := float(ck.x) * cell_m
	var z0 := float(ck.y) * cell_m
	var job := _place_job(chunk["pts"], _pump.cache.regions_rect(x0, z0, x0 + cell_m - 0.001, z0 + cell_m - 0.001),
		_pump.cache.region_size, _pump.cache.vertex_spacing)
	job["key"] = ck
	job["cells"] = cells
	job["entry"] = chunk
	job["bb"] = bb_tier
	job["task"] = WorkerThreadPool.add_task(_run_place_job.bind(job), false, "wf_place")
	_place_jobs.append(job)


## A native place job, read HERE on the main thread: the cell's points, the region copies under it
## ([location, heights, …]: shared, not copied; nothing writes them), the native core and tables, and the rules by place
## as they are now. The kernel plans the arena blocks itself (each slot's "clusters"), so the commit
## installs them without a walk. Tests and tools hand in their own regions and run it with _run_place_job_body. Every
## key the worker writes, and the task id's, is made here (see _scatter_job: a Dictionary must not grow while another
## thread reads it).
func _place_job(pts: Dictionary, regions: Array, region_size: int, vertex_spacing: float) -> Dictionary:
	return {"pts": pts, "regions": regions, "region_size": region_size, "vertex_spacing": vertex_spacing,
		"core": ForestNativeRes.core(), "tables": _tables_now(),
		"params": {"seed": forest_seed, "sea": sea_level, "coast": _coast_m, "mid": _mid_m, "treeline": _treeline_m,
			"treeline_keep": _treeline_keep, "cards": billboard_far_m > tree_visibility_m,
			"bucket_m": render_bucket_m if render_bucket_m > 0.0 else chunk_size, "bb_cell_m": billboard_chunk_m,
			"trunk_cell_m": _TRUNK_CELL},
		"spatial": _indirect != null and indirect_cards,
		"species": {}, "bbs": {}, "trunks": {}, "crowns": {}, "task": -1, "us": 0, "error": ""}


## WORKER. Reads only the job: its points, its region copies, the frozen tables.
func _run_place_job(job: Dictionary) -> void:
	var t0 := Time.get_ticks_usec()
	_run_place_job_body(job)
	job["us"] = Time.get_ticks_usec() - t0


## WORKER. The native place: one call for the cell. Its slots carry their arena clusters.
func _run_place_job_body(job: Dictionary) -> void:
	var res: Dictionary = job["core"].place_cell(job)
	job["error"] = str(res.get("error", ""))
	job["species"] = res.get("species", {})
	job["bbs"] = res.get("bbs", {})
	job["trunks"] = res.get("trunks", {})
	job["crowns"] = res.get("crowns", {})


## Floats an instance in a place job's MultiMesh buffers (the engine's TRANSFORM_3D layout plus one colour): the basis's
## rows, each followed by the origin's coordinate, then the colour. Pinned by test_vegetation_streaming.
const INSTANCE_STRIDE := 16


## Land finished place jobs and commit up to `max_mmis` MultiMeshInstances from
## them, oldest job first, a job spanning ticks when it has more species than the
## ration. `block` waits for every job in flight (editor preview, shutdown, tests):
## it still rations, because a blocking wait is about completeness, not about
## landing a dozen chunks in one frame.
func _collect_place(block: bool = false, max_mmis: int = MMIS_PER_TICK) -> void:
	var i := 0
	while i < _place_jobs.size():
		var job: Dictionary = _place_jobs[i]
		var id: int = job["task"]
		if not block and not WorkerThreadPool.is_task_completed(id):
			i += 1
			continue
		WorkerThreadPool.wait_for_task_completion(id)
		_place_jobs.remove_at(i)
		_place_jobs_run += 1
		_fill_place_us += int(job.get("us", 0))
		if str(job.get("error", "")) != "":
			_native_warn("place " + str(job["error"]), "[Wuifwoud] a forest cell placed nothing: %s" % job["error"])
		_place_ready.append(job)
	_commit_ready(max_mmis)


## The finished jobs' installs under the frame's box, oldest job first, a job spanning frames when its
## species outlast the box: the deadline is checked between species slots, and a slot is one native copy, so
## no slot outweighs the box. The box's first commit always lands (a fast drive never starves the forest). `max_mmis`
## stays as the hard cap the editor preview lifts (1 << 20). A direct call (the editor preview, tests) opens its own box.
func _commit_ready(max_mmis: int) -> void:
	var own := _box_until_us == 0
	if own:
		_box_open()
	var t0 := Time.get_ticks_usec()
	var budget := max_mmis
	var landed := 0
	_ft_begin(&"commit")
	while not _place_ready.is_empty() and budget > 0 \
			and (_box_commits == 0 or Time.get_ticks_usec() < _box_until_us):
		var job: Dictionary = _place_ready[0]
		var cells: Dictionary = job["cells"]
		var k: Vector2i = job["key"]
		# Released while in flight: drop it (identity, not key equality: see
		# _collect_scatter). A dropped job costs no budget.
		if not cells.has(k) or not is_same(cells[k], job["entry"]):
			_place_ready.pop_front()
			continue
		var before := budget
		budget = _commit_place(job, budget, _box_until_us, _box_commits == 0)
		_box_commits += 1
		landed += before - budget
		if job.get("committed", false):
			_place_ready.pop_front()
	_ft_end()
	if landed > 0:
		_fill_commit_us += Time.get_ticks_usec() - t0
		_fill_commit_ticks += 1
	if not _place_ready.is_empty():
		_fill_starved_ticks += 1
	# A completed collect leaves no unflushed impostor cells it could flush: anything that drives _collect_place
	# directly (the editor preview, tests) still sees its cards when it returns (the box allowing). In the pump's frame
	# (its box open) the flush runs once at the frame's end, after the resolve, on what the box has left: flushed here
	# too, it took the whole box and the resolve ran past it (the drive bench's last frames over 4 ms).
	if own and landed > 0 and not _bb_touched.is_empty():
		_flush_billboards()
	if own:
		_box_until_us = 0


## Open the frame's box: the commit box's milliseconds from now, nothing landed under it yet.
func _box_open() -> void:
	_box_until_us = Time.get_ticks_usec() + int(_commit_box_ms() * 1000.0)
	_box_commits = 0
	_box_flushes = 0


## Commit a job's results under a budget of MMIs; returns what is left. The first
## call lands the trunk registry and the impostor cells (one flush, counted as one)
## and queues the species; each further species is one MultiMeshInstance. The chunk
## is `done` (and stops being `placing`) only when the last species is in, so a
## reader of `done` never sees a half-landed chunk.
func _commit_place(job: Dictionary, budget: int, deadline_us: int = 0, first: bool = false) -> int:
	var chunk: Dictionary = job["entry"]
	var ck: Vector2i = job["key"]
	if not job.has("queue"):
		_ft_begin(&"trunks")
		var trunks: Dictionary = job["trunks"]
		for tc in trunks:
			var cell: PackedFloat32Array = _trunk_cells.get(tc, PackedFloat32Array())
			cell.append_array(trunks[tc])
			_trunk_cells[tc] = cell
		_ft_end()
		_ft_begin(&"crowns")
		_land_crowns(job.get("crowns", {}))
		_ft_end()
		var bbs: Dictionary = job["bbs"]
		if not bbs.is_empty():
			for bcb in bbs:
				_bb_touched[bcb] = true
				_bb_left.erase(bcb)          # touched again: every species of it flushes again
				var cellm: Dictionary = _bb_accum.get_or_add(bcb, {})
				for mesh_name in bbs[bcb]:
					cellm[mesh_name] = bbs[bcb][mesh_name]
			# The FLUSH is not here. It was, and one flush per landed job meant a
			# frame that landed several jobs copied several coarse cells' arenas
			# back to back with no deadline in sight. Cells merge into _bb_touched
			# and ONE flush per frame runs from _resolve_pending, inside the box.
			budget -= 1
		job["queue"] = (job["species"] as Dictionary).keys()
	var queue: Array = job["queue"]
	var species: Dictionary = job["species"]
	# `first`: the box's first commit; its first slot lands whatever the clock says.
	while not queue.is_empty() and budget > 0 \
			and (deadline_us == 0 or first or Time.get_ticks_usec() < deadline_us):
		first = false
		var skey: String = str(queue.pop_front())
		var slot: Dictionary = species[skey]
		var n: int = int(slot["n"])
		if n <= 0:
			continue
		budget -= _commit_slot(ck, str(slot["mesh"]), slot["bucket"], slot, chunk)
		_spawned += n
	# Species materials are created lazily by the first chunk that needs them, so a
	# push at _ready reaches none of them: push again whenever the live set grew.
	if ForestAssets._live_materials.size() != _lod_pushed_count:
		push_lod_params()
	if queue.is_empty():
		chunk["done"] = true
		chunk["pts"] = []
		chunk.erase("placing")
		job["committed"] = true
	return budget


## Outstanding jobs hold this node's bound method; drain before it goes away.
func _drain_place_jobs() -> void:
	for job in _place_jobs:
		WorkerThreadPool.wait_for_task_completion(job["task"])
	_place_jobs.clear()
	_place_ready.clear()


## THE DRAW DISTANCE OF ONE SPECIES.
##
## Trees: `tree_visibility_m`, because a tree's cut is where its impostor CARD takes
## over and the card's `near_cut` is pushed from the same number (_flush_billboards).
## Move one per species and the other has to move with it.
##
## Bushes have no card (they dissolve into nothing), so nothing downstream is pinned
## to their cut and it can be what it should always have been: the distance at which
## the plant stops being worth pixels. See `bush_px_min`.
func _species_cut_m(mesh_name: String) -> float:
	if not ForestAssets.is_bush_mesh(mesh_name):
		return tree_visibility_m
	if bush_px_min <= 0.0:
		return bush_visibility_m
	var d := ForestAssets.px_cull_distance(mesh_name, bush_px_min, _BUSH_CUT_SCALE)
	return clampf(d, minf(_BUSH_CUT_MIN_M, bush_visibility_m), bush_visibility_m)


## ── Quality tier ─────────────────────────────────────────────────────────────
## A feeder applies the tier (the game's quality feeder): apply_quality_params before the first ring,
## and on a change apply_quality_params + rebuild_for_quality.

## The pure half: a params dictionary in, the exports out. No autoload, no tree.
func apply_quality_params(p: Dictionary) -> void:
	if p.is_empty():
		return
	tree_visibility_m = float(p["visibility"])
	tree_lod_bias = float(p["lod_bias"])
	tree_shadow_ring_m = float(p["shadow_ring"])
	billboard_far_m = float(p["billboard_far"])
	_quality_density_scale = float(p["density_scale"])
	if _far != null:
		var band := _far_band()
		_far.set_band(band.x, band.y)


## Drop everything streamed and let the ring refill at the new tier.
##
## THROUGH `_release_cell`, NOT `_indirect.clear_all()`. The spawner holds block HANDLES
## into the indirect arenas; releasing the cells hands each one back with `free_block`,
## whereas clearing the arenas underneath them leaves the handles dangling and the next
## commit writes at a stale offset into an arena that is back at minimum capacity. That is
## not hypothetical: it crashes with "add_block: Out of bounds set index 32768" and leaves a
## world with no trees in it. Only once every cell is gone is the arena safe to drop, and it
## has to be dropped, because the BANDS are planned from `lod_bias` and the cut at species
## build time and nothing re-plans them in place.
func rebuild_for_quality() -> void:
	for k in _chunks.keys():
		_release_cell(k, _chunks, false)
	for k in _bb_cells.keys():
		_release_cell(k, _bb_cells, true)
	if _indirect != null:
		_indirect.clear_all()
		_indirect.lod_bias = tree_lod_bias
		_indirect.shadow_ring_m = tree_shadow_ring_m
		_indirect.shadows_enabled = tree_shadows
	# Far enough that the streamer cannot mistake this for "nothing moved".
	_stream_at = Vector2(1e18, 1e18)
	_stream_dirty = true
	_settled = false
	_filling = true
	ForestLog.debug("[Vegetation] tree tier applied: vis %.0f bias %.2f ring %.0f density x%.2f"
		% [tree_visibility_m, tree_lod_bias, tree_shadow_ring_m, _quality_density_scale])


## Build the GPU-driven path, or say plainly why it is not there. Called before the
## first chunk commits, because `_commit_slot` branches on it.
func _ensure_indirect() -> void:
	if not indirect_mmi or _indirect != null:
		return
	var ind: Node3D = VegetationIndirectRes.new()
	ind.name = "VegIndirect"
	ind.lod_bias = tree_lod_bias
	ind.shadow_ring_m = tree_shadow_ring_m
	ind.shadows_enabled = tree_shadows
	ind.cut_of = _species_cut_m
	ind.card_near_m = maxf(tree_visibility_m - _BILLBOARD_OVERLAP, 0.0)
	ind.card_far_m = billboard_far_m
	ind.card_thin_start_m = card_thin_start_m
	ind.card_thin_max = card_thin_max
	ind.card_thin_compensate = card_thin_compensate
	ind.editor = _editor
	add_child(ind)
	if not ind.available():
		# No RenderingDevice (headless), or the cull shader would not load. The
		# per-chunk path is still there and still correct; say so rather than falling
		# through to an empty forest.
		ForestLog.info("[Vegetation] indirect MultiMesh unavailable: per-chunk path")
		ind.queue_free()
		return
	_indirect = ind


## Hand the distance-thinning knobs to every live species material. Called at ready
## and by anything that changes them live (the rig's measure legs).
func push_lod_params() -> void:
	_lod_pushed_count = ForestAssets._live_materials.size()
	for sm in ForestAssets._live_materials:
		if not is_instance_valid(sm):
			continue
		sm.set_shader_parameter("thin_start_m", foliage_thin_start_m)
		sm.set_shader_parameter("thin_end_m", tree_visibility_m)
		sm.set_shader_parameter("thin_max", clampf(foliage_thin_max, 0.0, 1.0))
		# THIS SPECIES' HAND-OVER BAND (tree_wind `lod_out0`/`lod_out1`): where the
		# mesh dithers out and where it is gone. The impostor's `near_cut`/`near_fade`
		# are pushed to the SAME two numbers in _flush_billboards, which is what makes
		# the crossfade complementary: one pattern, one curve, every pixel covered
		# exactly once. Bushes have no card and fade into nothing over a short band.
		var bush := ForestAssets.is_bush_mesh(String(sm.resource_name))
		var cut := _species_cut_m(String(sm.resource_name))
		# The dissolve cannot be longer than the range it lives in: a 60 m bush with a
		# 40 m band would be half-transparent from 20 m out.
		var overlap: float = minf(_BUSH_DISSOLVE_M, cut * 0.35) if bush else _BILLBOARD_OVERLAP
		var band := ForestAssets.handover_band(cut, overlap)
		sm.set_shader_parameter("lod_out0", band["out0"])
		sm.set_shader_parameter("lod_out1", band["out1"])
		# A bush has no card behind it, so it must keep the whole band: see
		# `handover_frac`. A tree hands over to its card and takes a sub-band.
		sm.set_shader_parameter("handover_frac", 1.0 if bush else handover_frac)


## How far card cells are BUILT: `billboard_ring_m` when set, else the tier's draw distance
## plus one stream step.
func card_ring_m() -> float:
	if billboard_ring_m > 0.0:
		return billboard_ring_m
	return billboard_far_m + _CARD_RING_PAD_M


## The largest `billboard_far_m` a quality feeder may switch this forest to (a quality feeder sets it from the
## game's tier table before the first ring). 0 = only the current value.
var quality_far_ceiling_m := 0.0


## The largest card ring any quality tier can ask for. The region pump is sized ONCE, and a
## tier change rebuilds the rings but not the pump, so it is sized for the widest tier.
func _max_card_ring_m() -> float:
	if billboard_ring_m > 0.0:
		return billboard_ring_m
	return maxf(billboard_far_m, quality_far_ceiling_m) + _CARD_RING_PAD_M


## Where the cards hand over to mesh trees.
##
## NOT a fixed `tree_visibility_m - _BILLBOARD_OVERLAP`. That number assumes the mesh
## ring behind the band is BUILT, and while driving it is not: the mesh ring is 208
## chunks of 64 m and the card ring 36 cells of 1024 m, so the cards are always in
## first. Measured driving an island at 25 m/s, a second after arriving, 29-83 of ~208
## mesh chunks were still unresolved with the terrain 100% sampleable and the region
## pump holding every region: cards handing over at a fixed distance hand over to
## trees that do not exist yet ("billboards fade out into no trees").
##
## So the hand-over moves IN to the resolved frontier and back out as the ring closes.
## Once it has closed this is exactly `tree_visibility_m - _BILLBOARD_OVERLAP`.
func _card_near_cut() -> float:
	return minf(maxf(tree_visibility_m - _BILLBOARD_OVERLAP, 0.0), _mesh_frontier_m)


## The commit ration for this frame. The big one only while the mesh ring is behind
## the hand-over band: past it every tree the player can see is already built and
## there is nothing to hurry for.
func _commit_box_ms() -> float:
	if commit_budget_catchup_mult <= 1.0 or _mesh_frontier_m >= tree_visibility_m:
		return commit_budget_ms
	# A FILL'S, NEVER A DRIVE'S: the box is shared by the far landing, the commit and the flush, and the
	# forest's frame budget holds while driving; with installs one native copy each, the base box keeps a drive's ring
	# closed (the drive bench's frontier says so).
	if not _filling:
		return commit_budget_ms
	return commit_budget_ms * commit_budget_catchup_mult


## Distance to the nearest UNRESOLVED mesh chunk: how far the mesh forest actually
## reaches right now. Cheap: a few hundred cells, once per resolve tick.
func _update_mesh_frontier() -> void:
	var f := INF
	for k in _chunks:
		var chunk: Dictionary = _chunks[k]
		if bool(chunk.get("done", false)):
			continue
		var c := Vector2((float(k.x) + 0.5) * chunk_size, (float(k.y) + 0.5) * chunk_size)
		f = minf(f, _cell_near_dist(_stream_at, c, chunk_size))
	_mesh_frontier_m = f
	var cut := _card_near_cut()
	# Hysteresis: the frontier jitters by a chunk as cells land, and re-pushing a
	# shader uniform on every species every frame for 2 m of movement is not free.
	if _card_cut_pushed >= 0.0 and absf(cut - _card_cut_pushed) < 8.0:
		return
	_card_cut_pushed = cut
	for name in ForestAssets._billboard_cache:
		var bb: Dictionary = ForestAssets._billboard_cache[name]
		var mat := bb.get("mat") as ShaderMaterial
		if mat != null:
			mat.set_shader_parameter("near_cut", cut)


## Thin the IMPOSTOR field with distance, by instance COUNT rather than by collapsing
## instances in a shader.
##
## Why the cards and not the mesh trees: the cards hold most of the island's instances
## (a 2.8 km impostor ring against a 480 m mesh ring), each is a few pixels at the far
## end, and the far forest's canopy reads between them anyway. Thinning the MESH
## band would be visible: it is a few hundred metres deep and the trees in it are the
## ones being looked at.
##
## Because the native place packs the buffer in thinning order, the prefix that
## survives is a uniform sample of the cell and the SAME trees every frame. Set on the
## stream tick, i.e. every `_STREAM_MOVE_M` of travel, which is far coarser than the
## curve: a card does not need its count updated per metre.
func _update_card_density(at: Vector2) -> void:
	# Under the GPU path this is per CARD, in the cull shader, from the card's own
	# distance: see wf_cull.glsl `thin_key`. Nothing per cell is left to set, and the
	# arena has no per-cell MultiMesh to set it on.
	if (_indirect != null and indirect_cards) or card_thin_max <= 0.0:
		return
	for key in _bb_nodes:
		var mmi = _bb_nodes[key]
		if not is_instance_valid(mmi):
			continue
		var mm: MultiMesh = (mmi as MultiMeshInstance3D).multimesh
		if mm == null or mm.instance_count <= 0:
			continue
		# THE CELL COORD COMES FROM THE KEY, NOT FROM THE NODE. Every one of these
		# nodes sits at the spawner's origin (the instances carry world positions in
		# the MultiMesh buffer), so `global_position` is (0,0,0) for all of them and
		# every cell would be handed the distance from the camera to the world origin.
		# Uniform thinning of the whole island, including the cell under your feet.
		var parts: PackedStringArray = String(key).split("/")[0].split("_")
		if parts.size() < 2:
			continue
		var c := Vector2((float(parts[0].to_int()) + 0.5) * billboard_chunk_m,
			(float(parts[1].to_int()) + 0.5) * billboard_chunk_m)
		var d := _cell_near_dist(at, c, billboard_chunk_m)
		var t := clampf((d - card_thin_start_m)
			/ maxf(billboard_far_m - card_thin_start_m, 1.0), 0.0, 1.0)
		var keep := 1.0 - card_thin_max * t
		# Never zero: a cell that draws nothing is a hole in the treeline, and the
		# node's own visibility range is what should end the cell, not this.
		mm.visible_instance_count = maxi(int(float(mm.instance_count) * keep), 1)
		# The share this CELL actually draws, for the survivors' growth: the shader's
		# own distance formula would read each card's distance, not the cell's.
		(mmi as MultiMeshInstance3D).set_instance_shader_parameter("card_keep",
			float(mm.visible_instance_count) / float(mm.instance_count))


## Does a mesh chunk cast shadows from where the camera stands? See tree_shadow_ring_m.
func _chunk_casts(ck: Vector2i, at: Vector2) -> bool:
	if not tree_shadows:
		return false
	if tree_shadow_ring_m <= 0.0:
		return true
	var centre := Vector2((float(ck.x) + 0.5) * chunk_size, (float(ck.y) + 0.5) * chunk_size)
	return _cell_near_dist(at, centre, chunk_size) <= tree_shadow_ring_m


## Re-apply the casting ring to every landed mesh chunk. Runs on the stream tick
## (every 64 m of travel), a flag write per MMI: cheap against the pass it saves.
func _update_shadow_ring(at: Vector2) -> void:
	# Under the GPU path the shadow ring IS a band boundary (VegetationIndirect
	# .plan_bins), so casting follows the camera per instance and there is nothing here
	# to re-apply.
	if _indirect != null:
		return
	for ck in _chunks:
		var chunk: Dictionary = _chunks[ck]
		var nodes: Array = chunk.get("nodes", [])
		if nodes.is_empty():
			continue
		var casts := _chunk_casts(ck, at)
		for n in nodes:
			if not is_instance_valid(n):
				continue
			var mmi := n as MultiMeshInstance3D
			# Bushes never cast (see _add_tree_mmi); they are never switched on.
			if ForestAssets.is_bush_mesh(String(mmi.get_meta(&"species", ""))):
				continue
			mmi.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_ON if casts 				else GeometryInstance3D.SHADOW_CASTING_SETTING_OFF


## One species' MultiMeshInstance for a mesh chunk: ranges, fade, shadows, parent.
func _add_tree_mmi(ck: Vector2i, mesh_name: String, mm: MultiMesh, chunk: Dictionary,
		bucket: Vector2i = Vector2i.ZERO) -> void:
	var mmi := MultiMeshInstance3D.new()
	mmi.name = "%s%d_%d_b%d_%d_%s" % [_NAME_PREFIX, ck.x, ck.y, bucket.x, bucket.y, mesh_name]
	mmi.set_meta(&"species", mesh_name)
	mmi.multimesh = mm
	var is_bush := ForestAssets.is_bush_mesh(mesh_name)
	# THE NODE RANGE IS A GATE, NOT THE FADE. The shader dithers each tree out over
	# [out0, out1] (ForestAssets.handover_band, pushed by push_lod_params), measured
	# from the INSTANCE; the node range is measured to the AABB CENTRE, so it is that
	# band widened by the BUCKET's half-diagonal (the bucket is what this node holds,
	# and it is `render_bucket_m` across, not `chunk_size`).
	#
	# NEVER FADE_SELF. An instance inside its fade band (end ± margin) is FORCED INTO THE
	# TRANSPARENT PASS whatever its material (render_forward_clustered.cpp `force_alpha`),
	# and tree_wind's `ALPHA = tex.a` overwrites the fade value anyway: a 260-440 m band
	# paid 28.6 ms of back-to-front alpha overdraw on a 66 ms frame and never faded.
	var cut_m: float = _species_cut_m(mesh_name)
	var cell: float = render_bucket_m if render_bucket_m > 0.0 else chunk_size
	mmi.visibility_range_end = cut_m + cell * _HALF_DIAG
	mmi.visibility_range_end_margin = _RANGE_HYSTERESIS_M
	mmi.visibility_range_fade_mode = GeometryInstance3D.VISIBILITY_RANGE_FADE_DISABLED
	mmi.lod_bias = tree_lod_bias
	mmi.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_ON \
		if (not is_bush and _chunk_casts(ck, _stream_at)) else GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	add_child(mmi)
	(chunk["nodes"] as Array).append(mmi)


## One MultiMeshInstance for one species in one RENDER BUCKET. Returns 1 when it
## landed, 0 when the species has no mesh.
func _commit_slot(ck: Vector2i, mesh_name: String, bucket: Vector2i,
		packed: Dictionary, chunk: Dictionary) -> int:
	var mats := ForestAssets._species_materials(mesh_name)
	if mats.is_empty():
		return 0
	var n: int = int(packed["n"])
	var t0 := Time.get_ticks_usec()
	# GPU-DRIVEN PATH: the instances go into the species' island-wide arena and there is
	# no node at all. Still costs one unit of the commit budget, because packing and
	# copying them is the same work; what disappears is the MultiMesh and the
	# `add_child`, about 8 ms per species.
	if _indirect != null:
		# The place kernel's clusters.
		var h: Dictionary = _indirect.add_block(mesh_name, packed["buf"], n, VegetationIndirectRes.TIER_MESH,
			{"clusters": packed.get("clusters", PackedFloat32Array())})
		if h.is_empty():
			return 0
		(chunk.get_or_add("iblocks", []) as Array).append(h)
		_fill_species_us += Time.get_ticks_usec() - t0
		return 1
	var mm := MultiMesh.new()
	mm.transform_format = MultiMesh.TRANSFORM_3D
	mm.use_custom_data = true
	mm.mesh = mats[0]   # shared shadered mesh (colours in the surface mats)
	# NO CUSTOM AABB, AND IT WAS MEASURED RATHER THAN ASSUMED. Setting one on the
	# resource and the node skips two O(instances) bound scans
	# (`_multimesh_re_create_aabb` at `multimesh_set_buffer`, `multimesh_get_aabb` at
	# `instance_set_scenario`; Godot issue #79573). Alternating A/B in ONE session,
	# two boots each at a driver-eye station in a dense forest: 86-87 fps without,
	# 86-88 with: INDISTINGUISHABLE, and the commit cost did not move either.
	#
	# Why it cannot matter HERE: this ring holds 29 511 instances in 3 699
	# MultiMeshes, about EIGHT instances each, so the scan Godot runs is over eight
	# transforms. The scan is only a cost when a MultiMesh is large, and ours are
	# tiny, which is itself the thing worth fixing (see chunk_size). A hand-written
	# bound also cannot be as tight as the exact union Godot builds, so it would have
	# to buy something to be worth the looser culling. It does not.
	mm.instance_count = n
	mm.buffer = packed["buf"]
	_add_tree_mmi(ck, mesh_name, mm, chunk, bucket)
	_fill_species_us += Time.get_ticks_usec() - t0
	return 1


## (Re)build the billboard MMI ONLY for coarse cells touched this pass:
## flushing every cell every pass re-uploads the whole accumulated set
## once a second and hitches the editor to a standstill (O(N²) total).
func _flush_billboards() -> void:
	_ft_begin(&"flush")
	var t0 := Time.get_ticks_usec()
	var own := _box_until_us == 0
	if own:
		_box_open()
	_flush_billboards_body(_box_until_us)
	if own:
		_box_until_us = 0
	_fill_flush_us += Time.get_ticks_usec() - t0
	_ft_end()


## The impostor material's per-frame band, pushed once per species. Extracted because
## the GPU-driven path has no node to hang it off and would otherwise leave the card
## shader on its uniform defaults: an 810 m `near_cut` against a 260 m hand-over,
## i.e. a 550 m ring with no trees in it at all.
func _bb_material(bb: Dictionary) -> void:
	var mat := bb["mat"] as ShaderMaterial
	if mat == null:
		return
	# near_cut + near_fade == the mesh shader's fade_start_m..fade_end_m
	# (push_lod_params): the same band, so the per-tree hand-over is exact.
	mat.set_shader_parameter("near_cut", _card_near_cut())
	mat.set_shader_parameter("near_fade", _BILLBOARD_OVERLAP)
	# The SAME fraction the mesh shader gets, over the SAME band: that is what makes
	# the two sub-bands identical per tree, and the dither complementary.
	mat.set_shader_parameter("handover_frac", handover_frac)
	mat.set_shader_parameter("density_ramp_m", billboard_density_ramp_m)
	# Dissolve out before the range ends, so the field thins into the haze instead of
	# stopping on a line.
	mat.set_shader_parameter("far_cut", billboard_far_m)
	mat.set_shader_parameter("far_fade", _card_far_fade())
	mat.set_shader_parameter("px_min", card_px_min)
	mat.set_shader_parameter("thin_start_m", card_thin_start_m)
	mat.set_shader_parameter("thin_max", clampf(card_thin_max, 0.0, 0.9))
	mat.set_shader_parameter("thin_compensate", card_thin_compensate)


## The touched impostor cells' cards into the arenas (or their per-cell MultiMeshes), ONE CELL'S SPECIES AT A TIME under
## the frame's box: a 1 km cell holds ~10 000 cards a species, each species one native copy, so
## the deadline is checked between them. A cell stays touched until its last species is in (the shot rig's "cards
## flushed" reads _bb_touched); touched again while part-flushed, it starts over (_commit_place). The box's first item
## always lands, or a drive that keeps touching cells faster than the box drains them never flushes anything.
func _flush_billboards_body(deadline_us: int) -> void:
	for bc in _bb_touched.keys():
		# Released while touched: _release_cell freed the handles and erased the accumulator, and a cell no longer in
		# its tier must not gain a fresh arena block nobody will free.
		if not _bb_cells.has(bc) or not _bb_accum.has(bc):
			if not _bb_cells.has(bc):
				_bb_accum.erase(bc)
			_bb_touched.erase(bc)
			_bb_left.erase(bc)
			continue
		if not _bb_left.has(bc):
			_bb_left[bc] = (_bb_accum[bc] as Dictionary).keys()
		var left: Array = _bb_left[bc]
		while not left.is_empty():
			if _box_flushes > 0 and Time.get_ticks_usec() > deadline_us:
				return
			_box_flushes += 1
			_flush_card_slot(bc, str(left.pop_front()))
		_bb_touched.erase(bc)
		_bb_left.erase(bc)


## One card cell's species (the flush's item): into the species' arena on the GPU path, the cell's previous
## block freed first, else the cell's MultiMeshInstance3D for it.
func _flush_card_slot(bc: Vector2i, mesh_name: String) -> void:
	if not (_bb_accum.get(bc, {}) as Dictionary).has(mesh_name):
		return
	var bb := ForestAssets._billboard(mesh_name)
	if bb.is_empty():
		return
	var slot: Dictionary = _bb_accum[bc][mesh_name]
	var key := "%d_%d/%s" % [bc.x, bc.y, mesh_name]
	var mmi: MultiMeshInstance3D = _bb_nodes.get(key)
	if _indirect != null and indirect_cards:
		# GPU-DRIVEN IMPOSTORS: no node, no per-cell MultiMesh. The cell's cards
		# go into the species' island-wide arena and the cull shader picks the
		# ones in the band, in the frustum and past the thinning test, which is
		# why the material's own `near_cut`/`far_cut` are still pushed below and
		# `_update_card_density` has nothing left to do.
		#
		# A cell is FLUSHED REPEATEDLY as more of it resolves, and the slot is
		# the whole cell each time, so the previous block has to go back to the
		# free list or the arena grows by the cell on every pass.
		_bb_material(bb)
		var old_h: Dictionary = _bb_blocks.get(key, {})
		if not old_h.is_empty():
			_indirect.free_block(old_h)
		# The place kernel's clusters.
		var h: Dictionary = _indirect.add_block(mesh_name, slot["buf"],
			int(slot["n"]), VegetationIndirectRes.TIER_CARD,
			{"clusters": slot.get("clusters", PackedFloat32Array())})
		if h.is_empty():
			return
		_bb_blocks[key] = h
		var owner_i: Dictionary = _bb_cells.get(bc, {})
		if not owner_i.is_empty() and old_h.is_empty():
			(owner_i.get_or_add("bb_keys", []) as Array).append(key)
		return
	if mmi == null or not is_instance_valid(mmi):
		mmi = MultiMeshInstance3D.new()
		mmi.name = "%sBB_%d_%d_%s" % [_NAME_PREFIX, bc.x, bc.y, mesh_name]
		mmi.material_override = bb["mat"]
		# Centre + half-diagonal, as for the mesh chunks: the shader has
		# dissolved every card by `far_cut` = billboard_far_m, so past this the
		# cell is empty quads. The margin is hysteresis, not a fade.
		mmi.visibility_range_end = billboard_far_m + billboard_chunk_m * _HALF_DIAG
		mmi.visibility_range_end_margin = _RANGE_HYSTERESIS_M
		# A cell fully inside the mesh ring draws nothing: every card in it
		# is discarded by the shader's `near_cut`. Culling the whole MMI at
		# the node level is free and skips rasterising them at all.
		mmi.visibility_range_begin = maxf(tree_visibility_m - _BILLBOARD_OVERLAP
			- billboard_chunk_m, 0.0)
		# NEVER FADE_SELF: see _add_tree_mmi. It puts every cell in the far band
		# into the transparent pass, alpha-blended on top of the shader's own
		# per-tree dissolve (`far_cut`/`far_fade`).
		mmi.visibility_range_fade_mode = GeometryInstance3D.VISIBILITY_RANGE_FADE_DISABLED
		mmi.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
		add_child(mmi)
		_bb_nodes[key] = mmi
		# Hand the node to the cell that owns it so releasing the cell frees
		# it. Without this the impostor field is immortal: cells leave the
		# ring, stop being resolved, and their cards stay on screen forever.
		var owner_cell: Dictionary = _bb_cells.get(bc, {})
		if not owner_cell.is_empty():
			(owner_cell.get_or_add("nodes", []) as Array).append(mmi)
			(owner_cell.get_or_add("bb_keys", []) as Array).append(key)
	_bb_material(bb)
	# ONE buffer upload per species per cell: a place job hands the slot over
	# already packed ({buf, n}).
	var packed: Dictionary = slot
	var n: int = int(packed["n"])
	var mm := MultiMesh.new()
	mm.transform_format = MultiMesh.TRANSFORM_3D
	mm.use_colors = true
	mm.mesh = bb["mesh"]
	mm.instance_count = n
	if n > 0:
		mm.buffer = packed["buf"]
	mmi.multimesh = mm

# ── Species assets live in ForestAssets ─────────────────────────────────
# Mesh, material and impostor resolution live in forest_assets.gd. This file keeps
# what is about PLACEMENT (maps, gates, chunks, streaming); that file keeps what is
# about a SPECIES.

## Weighted pick from [[mesh, weight], …]. "" on an EMPTY pool (a profile band of
## []): callers drop the point, where indexing pool[-1] would error instead.
static func _weighted(pool: Array, sd: int) -> String:
	if pool.is_empty():
		return ""
	var total := 0.0
	for e in pool:
		total += float(e[1])
	var r: float = _rand01(sd * 31 + 7) * total
	for e in pool:
		r -= float(e[1])
		if r <= 0.0:
			return str(e[0])
	return str(pool[pool.size() - 1][0])

# ── Live wind feed: a CLOCK the forest reads, not a rate it rebuilds ─────────
#
# THE SHADERS ANIMATE ON A PHASE THAT IS INTEGRATED HERE, NEVER ON `TIME * rate`.
# A phase rebuilt from an absolute clock (`TIME * wind_speed` for the sway, `TIME *
# gust_speed` for the front, both rates re-pushed from the gusted wind) jumps whenever
# its rate changes: at TIME = 600 s a 1 % change of rate moves the sway by 6 radians,
# so every gust change snaps the whole forest to a new pose and the trees look like they
# are "catching up" with the weather. The direction has the same flaw one level down:
# `along = dot(p, dir)` jumps 20 m for a 0.02 rad veer on a tree a kilometre from the
# origin.
#
# So: targets are READ at 10 Hz (the weather is smooth, that is plenty), and every
# frame the phases advance by rate*dt, the direction rotates a little way toward
# its target, and the amplitudes ease: five GLOBAL shader parameters, one
# RenderingServer call each, for every species and for the impostor field behind
# them. Per-material pushes stay at 10 Hz for the only thing that is per material:
# the vehicle push points.

## Both wrap periods MIRROR wf_common.gdshaderinc, which pins them to the harmonics
## the shaders use. Change them together or the wrap becomes a once-an-hour jump.
const WIND_PHASE_WRAP := 200.0 * PI
## The gust front's wrap period, in metres (see WIND_PHASE_WRAP).
const GUST_WRAP_M := 26000.0
## Seconds for the direction / amplitude to cover ~63 % of a step in their target.
## The fed wind (a gusted vector) is already continuous; this only has to hide
## the 10 Hz sampling, so it is short enough not to lag a real veer.
const _WIND_EASE_S := 0.6

var _wind_poll := 0.0
## Integrated state: see above. Phases in the shaders' own units.
var _wind_phase := 0.0          # sway clock, radians
var _gust_phase := 0.0          # gust-front travel, metres downwind
var _wind_dir := Vector2(1.0, 0.3).normalized()
var _wind_amp := 0.0            # metres of tip travel
var _gust_depth := 0.0
var _wind_rate := 0.75          # sway tempo, phase units per second
var _front_speed := 2.0         # gust-front speed, m/s
## Targets from the last weather read, eased toward by _advance_wind.
var _wind_rate_t := 0.75
var _front_speed_t := 2.0
var _wind_dir_t := Vector2(1.0, 0.3).normalized()
var _wind_amp_t := 0.0
var _gust_depth_t := 0.0

## What the feeders last sent. Applied as it arrives: the wind and the push points at
## the moment they arrive (set_wind derives the targets; push points go out in that frame's _process), the washes
## every frame (_push_washes). Nothing fed: calm, no push, no wash.
var _fed_wind_dir := Vector2(1.0, 0.3)
var _fed_wind_speed := 0.0
var _fed_push := PackedVector4Array([Vector4.ZERO, Vector4.ZERO, Vector4.ZERO, Vector4.ZERO])
var _fed_washes := PackedVector4Array()
var _push_dirty := false
## The tree shaders carry two wash slots (forest_wash.gdshaderinc MAX_WASH).
const MAX_WASHES := 2


## The wind at the forest: a direction in the ground plane and a speed in m/s (a wind feeder sends the game's
## gusted wind). A direction shorter than 0.01 keeps the last one; a negative or NaN speed reads as calm, so the
## shader globals never get a NaN.
func set_wind(dir: Vector2, speed: float) -> void:
	if dir.is_finite() and dir.length() >= 0.01:
		_fed_wind_dir = dir
	_fed_wind_speed = speed if is_finite(speed) and speed > 0.0 else 0.0
	_apply_wind_targets()   # on arrival: a second 10 Hz clock out of step with the feeder's would only add lag


## Up to PUSH_SLOTS (x, z, radius m, strength m) brushes the undergrowth leans away from, nearest first; radius 0 is
## an unused slot. Extra slots are dropped, missing ones are empty.
func set_push_points(slots: PackedVector4Array) -> void:
	var out := PackedVector4Array()
	out.resize(PUSH_SLOTS)
	for i in mini(slots.size(), PUSH_SLOTS):
		out[i] = slots[i]
	_fed_push = out
	_push_dirty = true   # sent to the materials in this frame's _process (feeders run before the forest)


## The washing rotors near the camera, (x, z, footprint radius, intensity) each, sent to every tree material as
## `wash` / `wash_count`. At most MAX_WASHES are kept.
func set_washes(washes: PackedVector4Array) -> void:
	_fed_washes = washes if washes.size() <= MAX_WASHES else washes.slice(0, MAX_WASHES)

func _process(dt: float) -> void:
	if _editor:
		_editor_tick()
		return
	# The GPU cull needs one thing per frame and it is the camera. Everything else it
	# owns already; a frame with no chunk churn sends nothing but this.
	if _indirect != null:
		var cam := _camera()
		if cam != null:
			_ft_begin(&"upload")
			_indirect.update(VegetationIndirectRes.eye_of(cam))
			_ft_end()
	_ft_begin(&"process")
	_animate(dt)
	_ft_end()


## The forest's per-frame feel: the clutter ring, the wind clock, the vehicles' push points and rotor wash.
func _animate(dt: float) -> void:
	_clutter_tick(dt)
	if not wind_enabled or ForestAssets._live_materials.is_empty():
		return
	_wind_poll -= dt
	if _wind_poll <= 0.0:
		_wind_poll = 0.1
		_apply_wind_targets()   # also when nothing is fed: calm air, and a live wind_strength
	if _push_dirty:
		_push_dirty = false
		# VEHICLE PUSH POINTS: the nearest few cars, so undergrowth leans away as they
		# pass. The one thing still pushed per material: tens of calls at a feeder's 10 Hz.
		for sm in ForestAssets._live_materials:
			if is_instance_valid(sm):
				sm.set_shader_parameter("wind_push", _fed_push)
	_advance_wind(dt)
	_push_washes()


## Washing rotors onto every tree and bush material (tree_wind.gdshader reads them through forest_wash.gdshaderinc,
## the same outwash the grass reads). Per FRAME, not at 10 Hz: the column moves with the ship, and 10 Hz steps in
## where it stands read as the canopy twitching. Sends nothing while no rotor washes; only the one frame that clears
## the last one.
var _washes_sent := -1

func _push_washes() -> void:
	if _fed_washes.is_empty() and _washes_sent == 0:
		return
	_washes_sent = _fed_washes.size()
	for sm in ForestAssets._live_materials:
		if is_instance_valid(sm):
			sm.set_shader_parameter("wash", _fed_washes)
			sm.set_shader_parameter("wash_count", _fed_washes.size())


## The sway targets from the last wind fed: on each set_wind, and at 10 Hz so the calm default and a live
## wind_strength apply with no feeder. The feeder samples the GUSTED wind, because a gust envelope is the signal
## rather than a slowly drifting average: a canopy driven by a mean moves but cannot move DIFFERENTLY, which is what
## "does not respond to the weather" looks like.
func _apply_wind_targets() -> void:
	var t := wind_targets(_fed_wind_dir, _fed_wind_speed, wind_strength)
	_wind_dir_t = t["dir"]
	_wind_amp_t = t["amp"]
	_wind_rate_t = t["rate"]
	_front_speed_t = t["front"]
	_gust_depth_t = t["depth"]


## The sway targets for a wind (dir in the ground plane, speed m/s). Pure, so the numbers can be pinned
## (test_forest_wind).
static func wind_targets(dir: Vector2, speed: float, strength: float) -> Dictionary:
	return {
		"dir": dir.normalized(),
		# Metres of tip travel. Calm air is not still air (a canopy always breathes),
		# so the floor is a gentle idle rather than zero, and 12 m/s reaches full throw.
		"amp": strength * clampf(0.25 + speed / 12.0, 0.25, 1.7),
		# Stronger wind churns faster as well as further; without this a gale sways at
		# exactly the pace of a calm and reads as slow motion.
		"rate": clampf(0.75 + speed / 18.0, 0.75, 1.9),
		# Gust fronts travel at roughly the wind speed, so the wave sweeps the island at
		# the pace of the air moving over it. Floored so a calm still drifts rather than
		# freezing a crest in place, which looks like a bug rather than stillness.
		"front": maxf(speed, 2.0),
		# Stronger wind gusts DEEPER as well as harder: a gale's lulls are still windy,
		# a breeze's are near-still, so depth falls as speed rises.
		"depth": clampf(0.65 - speed / 40.0, 0.25, 0.65),
	}


## One frame of the wind clock: integrate, ease, publish. Pure state -> globals.
func _advance_wind(dt: float) -> void:
	var k := 1.0 - exp(-dt / _WIND_EASE_S)
	# The RATES ease too, so a gust changes the sway's tempo smoothly rather than the
	# tempo stepping ten times a second. Neither can jump the phase either way (the
	# phase is the integral), but a stepped tempo is visible in the motion.
	_wind_rate = lerpf(_wind_rate, _wind_rate_t, k)
	_front_speed = lerpf(_front_speed, _front_speed_t, k)
	_wind_phase = fposmod(_wind_phase + _wind_rate * dt, WIND_PHASE_WRAP)
	_gust_phase = fposmod(_gust_phase + _front_speed * dt, GUST_WRAP_M)
	# Rotate, never lerp, a direction: a lerp through the origin on a 180-degree veer
	# collapses the vector and the whole forest spins through every direction.
	_wind_dir = _wind_dir.rotated(_wind_dir.angle_to(_wind_dir_t) * k).normalized()
	_wind_amp = lerpf(_wind_amp, _wind_amp_t, k)
	_gust_depth = lerpf(_gust_depth, _gust_depth_t, k)
	RenderingServer.global_shader_parameter_set(&"wuifwoud_wind_phase", _wind_phase)
	RenderingServer.global_shader_parameter_set(&"wuifwoud_gust_phase", _gust_phase)
	RenderingServer.global_shader_parameter_set(&"wuifwoud_wind_dir", _wind_dir)
	RenderingServer.global_shader_parameter_set(&"wuifwoud_wind_strength", _wind_amp)
	RenderingServer.global_shader_parameter_set(&"wuifwoud_gust_depth", _gust_depth)

## Up to PUSH_SLOTS vehicles as (world x, world z, radius m, strength m), nearest to the camera first (a feeder
## sends them, set_push_points). Unused slots carry radius 0, which the shader skips.
const PUSH_SLOTS := 4

# ── Ground-clutter ring (camera-following near-field density) ────────────────
# The classic open-world racer "clutter" system: the island-wide MultiMesh
# budget bounds what can exist EVERYWHERE, but the player only ever inspects
# ~70 m, so that ring gets its own dense, recycled layer. Deterministic per
# 3 m cell (same spot regrows the same fern), positions re-scattered only when
# the camera has moved; species from the profile's bush pool (a fern carpet, moss,
# deadfall) by elevation band. Visual-only and client-local: no MP sync, no
# collision (bush trunk radius is 0).

const _WOOD_CELL := 16.0
const _CLUT_CELL := 3.0
const _CLUT_MOVE_M := 7.0     # re-scatter when the camera strays this far
const _CLUT_POLL_S := 0.3

func _clutter_tick(dt: float) -> void:
	if not clutter_enabled or _wood_cells.is_empty():
		return
	_clutter_poll -= dt
	if _clutter_poll > 0.0:
		return
	_clutter_poll = _CLUT_POLL_S
	var cam := get_viewport().get_camera_3d()
	if cam == null:
		return
	var at := Vector2(cam.global_position.x, cam.global_position.z)
	if at.distance_to(_clutter_at) < _CLUT_MOVE_M:
		return
	var terrain := ForestTerrainRes.find_cached(self)
	if terrain == null:
		return
	_clutter_at = at
	_refresh_clutter(at, terrain)

func _refresh_clutter(at: Vector2, terrain) -> void:
	var per_cell := clutter_density_per_m2 * _CLUT_CELL * _CLUT_CELL
	var r_cells := int(ceil(clutter_radius_m / _CLUT_CELL))
	var c0 := Vector2i(int(floor(at.x / _CLUT_CELL)), int(floor(at.y / _CLUT_CELL)))
	var by_species: Dictionary = {}   # mesh_name -> {xforms, colors}
	for cy in range(c0.y - r_cells, c0.y + r_cells + 1):
		for cx in range(c0.x - r_cells, c0.x + r_cells + 1):
			var sd: int = hash(Vector3i(cx, cy, 90017))
			var centre := Vector2((float(cx) + 0.5) * _CLUT_CELL, (float(cy) + 0.5) * _CLUT_CELL)
			var d := centre.distance_to(at)
			if d > clutter_radius_m:
				continue
			# Density falls off toward the ring edge: the boundary never
			# reads as a wall of ferns appearing.
			var prob: float = per_cell * (1.0 - pow(d / clutter_radius_m, 2.0))
			if _rand01(sd) > prob:
				continue
			var wv = _wood_cells.get(Vector2i(int(floor(centre.x / _WOOD_CELL)),
					int(floor(centre.y / _WOOD_CELL))))
			if wv == null:
				continue
			var p := centre + Vector2(_rand01(sd * 3 + 1) - 0.5,
				_rand01(sd * 7 + 2) - 0.5) * _CLUT_CELL
			if _road_blocked_within(p, clutter_road_margin):
				continue
			var h: float = ForestTerrainRes.height_at(terrain, Vector3(p.x, 0, p.y))
			if is_nan(h):
				continue
			# Forest ground's clutter is its type's bushes.
			var mesh_name := _weighted(_types.get_type(int(wv)).get("bush", []), sd * 11 + 5)
			if mesh_name == "":
				continue
			var scl := 0.55 + _rand01(sd * 13 + 3) * 0.75
			var basis := Basis(Vector3.UP, _rand01(sd * 17 + 4) * TAU).scaled(Vector3.ONE * scl)
			var tint := 0.88 + _rand01(sd * 19 + 6) * 0.24
			if not by_species.has(mesh_name):
				by_species[mesh_name] = {"xforms": [], "colors": []}
			(by_species[mesh_name]["xforms"] as Array).append(
				Transform3D(basis, Vector3(p.x, h, p.y)))
			(by_species[mesh_name]["colors"] as Array).append(
				Color(tint, tint * (0.96 + _rand01(sd * 23 + 7) * 0.08), tint, 1.0))
	# Recycle one MMI per species; species absent this refresh go to 0 instances.
	for mesh_name in _clutter_nodes:
		if not by_species.has(mesh_name):
			(_clutter_nodes[mesh_name] as MultiMeshInstance3D).multimesh.instance_count = 0
	for mesh_name in by_species:
		var xforms: Array = by_species[mesh_name]["xforms"]
		var colors: Array = by_species[mesh_name]["colors"]
		var mmi: MultiMeshInstance3D = _clutter_nodes.get(mesh_name)
		if mmi == null or not is_instance_valid(mmi):
			var mats := ForestAssets._species_materials(str(mesh_name))
			if mats.is_empty():
				continue
			var mm := MultiMesh.new()
			mm.transform_format = MultiMesh.TRANSFORM_3D
			mm.use_custom_data = true
			mm.mesh = mats[0]
			mmi = MultiMeshInstance3D.new()
			mmi.name = "Clutter_%s" % mesh_name
			mmi.multimesh = mm
			mmi.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
			add_child(mmi)
			_clutter_nodes[mesh_name] = mmi
		var mm2: MultiMesh = mmi.multimesh
		mm2.instance_count = 0   # resize resets instance data
		mm2.instance_count = xforms.size()
		for i in range(xforms.size()):
			mm2.set_instance_transform(i, xforms[i])
			mm2.set_instance_custom_data(i, colors[i])

## Corridor test with a CUSTOM margin: rects store hw already inflated by
## road_margin, so subtract the difference: clutter stands nearer the
## pavement than trees may.
func _road_blocked_within(p: Vector2, margin: float) -> bool:
	var key := Vector2i(int(floor(p.x / _ROAD_CELL)), int(floor(p.y / _ROAD_CELL)))
	if not _road_grid.has(key):
		return false
	var shrink := road_margin - margin
	for idx in _road_grid[key]:
		var r: Dictionary = _road_rects[idx]
		var a: Vector2 = r["a"]
		var b: Vector2 = r["b"]
		var ab := b - a
		var t: float = clampf((p - a).dot(ab) / maxf(ab.length_squared(), 0.0001), 0.0, 1.0)
		if p.distance_to(a + ab * t) < float(r["hw"]) - shrink:
			return true
	return false

# ── Road corridor gate (roads win) ───────────────────────────────────────────

const _ROAD_CELL := 64.0
## Floats per road segment in set_road_segments: ax, az, bx, bz, half width.
const ROAD_STRIDE := 5

## The road corridor trees keep out of: ROAD_STRIDE floats a segment, (ax, az, bx, bz, half width m)
## in world XZ; `road_margin` is added here. An empty array is a map without roads. Until this is called nothing is
## gated: a road source that appears late gates the cells built after it, and those built before it re-scatter when
## they re-enter the ring. Scatter jobs read the corridor, so the ones in flight land first. 64-bit, because the
## half width always was: a 32-bit one moves the edge of the corridor by a rounding, and a tree with it. A malformed
## array (not a multiple of ROAD_STRIDE) is refused with an error and changes nothing.
func set_road_segments(segs: PackedFloat64Array) -> void:
	if segs.size() % ROAD_STRIDE != 0:
		ForestLog.error("[Vegetation] set_road_segments: %d floats is not a multiple of %d; ignored"
			% [segs.size(), ROAD_STRIDE])
		return
	if not _scatter_jobs.is_empty():
		_collect_scatter(true)
	_road_rects.clear()
	_road_grid.clear()
	for s in range(0, segs.size(), ROAD_STRIDE):
		var a := Vector2(segs[s], segs[s + 1])
		var b := Vector2(segs[s + 2], segs[s + 3])
		var hw: float = segs[s + 4]
		var idx := _road_rects.size()
		_road_rects.append({"a": a, "b": b, "hw": hw + road_margin})
		# SPATIAL HASH: an island graph carries tens of thousands of
		# segments: a linear scan per scatter candidate is the boot-time
		# killer. Register the segment in every 64 m cell its inflated
		# bbox touches; queries look at one cell.
		var pad := hw + road_margin
		var lo := (a.min(b) - Vector2(pad, pad)) / _ROAD_CELL
		var hi := (a.max(b) + Vector2(pad, pad)) / _ROAD_CELL
		for cy in range(int(floor(lo.y)), int(floor(hi.y)) + 1):
			for cx in range(int(floor(lo.x)), int(floor(hi.x)) + 1):
				var key := Vector2i(cx, cy)
				if not _road_grid.has(key):
					_road_grid[key] = []   # Array, not packed: see row_edges
				(_road_grid[key] as Array).append(idx)
	_road_blocker_built = true
	# The native corridor: the same segments and margin, frozen; a scatter job holds the one it was given.
	var core = ForestNativeRes.core()
	_roads = core.make_roads(segs, road_margin) if core != null else null

## A standing tree's crown, flat [x, z, y_bottom, y_top, radius] (world metres), or
## empty when the species has no mesh to measure. MAIN THREAD (species_crown loads).
static func _crown_entry(mesh_name: String, x: float, z: float, ground: float,
		scale: float) -> PackedFloat32Array:
	var c: Vector2 = ForestAssets.species_crown(mesh_name)
	if c.x <= 0.0:
		return PackedFloat32Array()
	return PackedFloat32Array([x, z, ground + CROWN_BOTTOM_FRAC * c.x * scale,
		ground + c.x * scale, c.y * scale])


## Land a placement job's raw trunk records as crowns, MAIN THREAD, at commit: one native call a species and trunk
## cell, _crown_entry's arithmetic byte for byte (test_wf_core), where a GDScript call a tree would be the commit's
## largest cost after the installs. `raw`: trunk cell -> species -> PackedFloat32Array [x, z, ground, scale]*.
func _land_crowns(raw: Dictionary) -> void:
	var core = ForestNativeRes.core()
	if core == null:
		return
	for tc in raw:
		var cc: PackedFloat32Array = _crown_cells.get(tc, PackedFloat32Array())
		var per: Dictionary = raw[tc]
		for mesh_name in per:
			var c: Vector2 = ForestAssets.species_crown(String(mesh_name))
			cc.append_array(core.crowns(per[mesh_name], c.x, c.y, CROWN_BOTTOM_FRAC))
		_crown_cells[tc] = cc


## Crowns within r of p (2D): flat [x, z, y_bottom, y_top, radius] quintuples, from the
## 3x3 trunk-cell neighbourhood (the rotor strike probe's query).
func crowns_near(p: Vector2, r: float) -> PackedFloat32Array:
	var out := PackedFloat32Array()
	var c := Vector2i(int(floor(p.x / _TRUNK_CELL)), int(floor(p.y / _TRUNK_CELL)))
	var r2 := r * r
	for cy in range(c.y - 1, c.y + 2):
		for cx in range(c.x - 1, c.x + 2):
			var cell: PackedFloat32Array = _crown_cells.get(Vector2i(cx, cy), PackedFloat32Array())
			for i in range(0, cell.size() - 4, 5):
				var dx := cell[i] - p.x
				var dz := cell[i + 1] - p.y
				if dx * dx + dz * dz <= r2:
					out.append_array(cell.slice(i, i + 5))
	return out


## Trunks within r of p (2D): the collision pool's query. Scans the 3x3
## trunk-cell neighbourhood (64 m cells vs a ~45 m radius). Returns flat
## [x, ground y, z, radius] quads.
func trunks_near(p: Vector2, r: float) -> PackedFloat32Array:
	var out := PackedFloat32Array()
	var c := Vector2i(int(floor(p.x / _TRUNK_CELL)), int(floor(p.y / _TRUNK_CELL)))
	var r2 := r * r
	for cy in range(c.y - 1, c.y + 2):
		for cx in range(c.x - 1, c.x + 2):
			var key := Vector2i(cx, cy)
			if not _trunk_cells.has(key):
				continue
			var cell: PackedFloat32Array = _trunk_cells[key]
			for i in range(0, cell.size(), 4):
				var dx := cell[i] - p.x
				var dz := cell[i + 2] - p.y
				if dx * dx + dz * dz <= r2:
					out.append(cell[i])
					out.append(cell[i + 1])
					out.append(cell[i + 2])
					out.append(cell[i + 3])
	return out

# ── Small pure helpers ───────────────────────────────────────────────────────

## Deterministic 0..1 from an int (same on every peer: the forest is shared
## world state without a single RPC).
static func _rand01(s: int) -> float:
	var x := s
	x = (x ^ (x >> 16)) * 0x45d9f3b
	x = (x ^ (x >> 16)) * 0x45d9f3b
	x = x ^ (x >> 16)
	return float(x & 0xFFFFFF) / float(0x1000000)

## ── Diagnostics ────────────────────────────────────────────────────────────────
## What the streaming machinery holds RIGHT NOW, for a host's memory probe.
## Read-only and cheap enough to call every couple of seconds. The attribution
## this enables: RSS climbing while `pump_reload` climbs is pump churn; RSS
## climbing while `indirect.total_cpu_mb` climbs is the arenas refusing to give
## blocks back; RSS climbing with BOTH flat points somewhere else entirely.
func debug_churn() -> Dictionary:
	var out := {
		"bb_cells": _bb_cells.size(),
		"chunks": _chunks.size(),
		"scatter_jobs": _scatter_jobs.size(),
		"place_jobs": _place_jobs.size(),
		"place_ready": _place_ready.size(),
	}
	if _pump != null:
		out["pump_live"] = int(_pump.stats.get("live", -1))
		out["pump_disk"] = int(_pump.stats.get("disk", -1))
		out["pump_reload"] = int(_pump.stats.get("reload", -1))
		out["pump_cache_regions"] = _pump.cache._maps.size()
		out["pump_inflight"] = _pump._wanted.size()
	if _indirect != null and _indirect.has_method("arena_stats"):
		out["indirect"] = _indirect.arena_stats()
	if maps.configured():
		out["maps"] = maps.debug_stats()
	out["items"] = {"items": trees.items.size(), "planted": _items_planted}
	if _far != null:
		out["far"] = _far.info()
	return out
