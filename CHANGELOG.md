# Changelog

## Unreleased

- Mesh trees keep their colour with distance, so a tree no longer brightens when it hands over to its card. A leaf
  texture's clear texels hold whatever colour was left there (the starter's broadleaf sheet: half the leaves'
  brightness over three quarters of it) and mips average colour without weighting it by alpha, so a crown sank toward
  that colour as it sampled coarser mips: CommonTree_3's green fell from 0.106 at 20 m to 0.046 at 160 m while its card
  held 0.104. The pack build now writes each foliage sheet once, filled (`ForestLeafSheet`: every clear texel takes the
  colour of the leaves around it; alpha and covered texels untouched), as `built/leaf_<hash>.res`, shared by the
  species that use it; the mesh trees and the bake sample it. Measured on the starter pack, card against mesh from 80 m
  to 160 m: CommonTree_3 1.40-2.16x as bright before, 0.91-0.95x after; CommonTree_5 1.44-2.14x before, 0.91-0.99x;
  pines 0.90-1.03x. A species built before reads "needs" (its leaves have no filled sheet yet) and draws its source
  sheet until it is built again.
- Fix: impostor cards are lit from the sun's side whatever their tree's yaw. The card turned its baked normal to the
  world with `MODEL_MATRIX` in `fragment()`, which there is the MultiMesh node's transform (the per-instance one only
  reaches the vertex stage): every card was lit as if unrotated, so a tree turned 180 deg had its sunlit side facing
  away (measured: yaw 135-225 brighter on the shadow side, in every build back to before the trimmed cards). The tree's
  basis now comes from `vertex()`.
- The pack build notices two more changes that need a species built again (and its impostor baked again):
  - a file moved to another role (the same texture as the foliage's instead of the bark's, say): built.json now records
    which file plays which part (`roles`); an entry built before keeps its build until its next one records them;
  - a changed import script: a file's import settings now take in the source of the import script they name and of
    the scripts that one extends by path, so a post-import that reshapes a mesh no longer leaves an old build (and an
    old impostor) in place. A file without an import script hashes as before.
- Distance stability (a new inspector group): the forest reads its viewport's anti-aliasing every frame (`use_taa`,
  `scaling_3d_mode`, `msaa_3d`) and adapts, with nothing to feed.
  - Under a temporal filter (TAA, FSR2, MetalFX temporal) the crossfade dithers move every frame (`temporal_dither`;
    the global `wuifwoud_dither_frame`, registered at runtime with the wind globals): the filter averages them into a
    fade where a still pattern stayed a softened screen door on a still camera. Without one they hold still.
  - Without a temporal filter a tree hands over to its card at its own distance (`handover_frac_native`, 0.02 of the
    band) instead of dithering over a 27 m sub-band that nothing averages. `handover_frac` (0.3) applies under one.
  - Each tree's mesh LOD switch distances move by up to ±12 % by its own position (`lod_jitter`, in the cull): no LOD
    rings travelling with the camera. Only the inner switches move; a tree still ends at its hand-over.
  - Leaf coverage is kept through the mips (`leaf_mip_alpha`, Golus' scale, as the cards already did), and a thinned
    crown's kept leaves give back what the thinning dropped (`thin_coverage`), so the crown meets a card about as
    covered as it is.
  - Under MSAA, leaf and card edges become per-sample coverage (`msaa_alpha_to_coverage`): both tree shaders carry an
    `#ifdef WF_A2C` variant (alpha to coverage, the alpha pass), made from the same source and swapped in while MSAA is
    on; `a2c_depth_write` (WF_A2C_DEPTH) also writes depth per covered sample. Bark stays opaque. Off by default: at
    MSAA 2x on a forest road it took 2 % off the forest's crawl for up to 1.9 ms of GPU (4.5 ms with the depth write).
  - While no temporal filter runs (with a narrow `handover_frac_native`) the far forest's dithered choices are made
    coherent: it comes in under the last cards crown cell by crown cell instead of in a 600 m band of still dither, its
    crown layer marches with one step offset for every pixel (a ridge's treetops no longer dot the sky through the
    canopy), and the layer gives way to the clumps at a size instead of pixel by pixel.
- The far forest costs less for the same picture: its triangles nearer than its hand-over (every pixel dropped there
  anyway) are put on the eye and not rasterised (`far_near_collapse`), and the crown layer's search tests only the
  neighbour crowns that can reach a pixel (`far_layer_prune`). `forest_far.gd`'s `SHADER` constant is replaced by
  `shader()`, loaded once the forest's globals exist.
- Fix: the impostor cards no longer take the mesh trees' thinning numbers. `push_lod_params` pushed `thin_start_m`
  and `thin_max` onto every live material, cards included (they share the list and the names), so after a mesh
  species arrived every card grew as if thinned from 80 m (about 8 % larger at 600 m).

- The height pump's disk fallback no longer keeps every region file it reads. It loaded each with
  `ResourceLoader.load()` inside a WorkerThreadPool task, and in Godot 4.8 such a load is never freed: measured
  headless, ~11-13 MB a 1024² region for the rest of the run (with `CACHE_MODE_REPLACE` one copy a region, up to the
  whole map: ~1.8 GB for an island of 140 regions; with `IGNORE` one a load). The pump now requests the threaded loader
  on the main thread (`collect()` polls it, 8 loads in flight and the rest queued, all reading `pending`), takes a
  region once it reads loaded, never earlier (a blocking get before the pool has started a load keeps it too), and hands
  its height bytes to a worker for the conversion as before; the worker drops the region. `CACHE_MODE_REUSE` instead of
  `REPLACE`: a region the cache holds is not read again, and is never overwritten from its file. A pump let go with
  loads in flight still takes them. The main thread pays ~5 µs a load in flight a frame and ~20 µs to land one
  (measured: 64 regions, 100 µs a frame on average while they load).
- Trimmed impostor cards: a built card is a strip of eight bands, each pulled in by the vertex shader to what the three
  views it blends reach there, instead of the bake's whole square rasterised and mostly discarded. The pack build
  measures the reach per view and per mip set on the stored albedo (`built/<id>_trim.res`,
  `ForestImpostorBaker.trim_of`), conservatively: every texel the card's cut can keep stays inside. On the starter
  pack's trees the strip covers 28-62 % of the square where the card is largest, 58-80 % farther out, against the
  11-25 % the trees cover; a card under ~11 px draws its plain square.
- Impostor cards sample each blended view where it saw the pixel: the view ray is met with each frame's own plane and
  stepped by a baked depth sheet (the bake's third channel, `built/<id>_depth.res`, BC5, read a few mips blurred so
  thin branches step together). From above and at steep angles the card no longer turns with the camera or sits off
  the tree (the overhead frames' roll was ignored); side on it matches the model as before. The trim widens by each
  frame's possible shift and folds to the square where that would save little. Varyings packed (the card shader had
  reached 33 of 32).
- A species whose impostor was baked before the trim and the depth sheet reads "needs" (its impostor has no trim or
  depth sheet yet) and draws the plain square with no parallax until it is built again. The starter pack is rebuilt.
- The Species dialog's card casts no shadow, as in the forest: it laid a straight-edged shadow across itself.
- Trunk collider shares: `ForestSpawner.set_trunk_share(share)` ranks the collision group's members
  (`ForestTrunkPool.member_share`, a Callable returning `ForestTrunkPool.Share`). A PRIMARY member (every member when
  unset, as before) keeps the trunks within `radius_m`; a SECONDARY member gets the trunks within `secondary_radius_m`
  (20 m) and only the colliders no primary trunk wants, a primary trunk taking one back when none is free; a NONE
  member gets nothing and no longer wakes the move gate. With many AI cars in the group the pool had handed most of
  its colliders to them, nearest first, and a player's own trunks went without.
- `trunks_near` scans only the trunk cells its disc touches (about six of nine for a 45 m query, three for 20 m); a
  radius past 64 m no longer misses trunks.
- The far forest reads as forest, not a shell: where a crown spans a pixel or more across the screen, each pixel's view
  ray is traced into a layer of crowns hanging from the shell (jittered crowns, cones to domes by `crown_point`,
  heights varied, kept by the cover): a ray meeting one is shaded by that crown (its flank, its colour, darker lower
  down), one reaching the layer's floor sees the understorey (or the ground where the cover is open), one skimming the
  tips is cut, so ridges and skylines show treetops. Past that a second, coarser crown lattice (`clump_k`) carries the
  colour and the dome; the elevation bands are picked per clump over `band_blend_m` (no ring); a wall darkens toward
  the ground with a ragged top. The palette's mean is kept (`pom_gain`). Tunables on `forest_far.gdshader`.
- `ForestSpawner.arena_reserve_mult` (3.0) and `mesh_arena_min` (8192): the GPU arenas' headroom after a fill and
  a mesh arena's starting capacity, per forest. The defaults are unchanged; a map with few instances a species lowers
  them for GPU memory (an island: 2.0 and 2048 hold ~90 MB less), a growth then landing in a driving frame.
- A leaf surface's own stem is bark: a mesh that is one surface (a toon palm or tree: trunk and leaves on a material the
  name rule calls foliage) had its trunk spherified outward from a crown centred above it, the normal pointing down,
  and the trunk rendered black, lit from the wrong side. The preparation measures the stem (`crown_floor`:
  `ForestAssets.crown_floor_of`, the run of thin height slices under the crown); `tree_wind` and the impostor bake give
  the vertices below it no spherify, no crown occlusion and no backlight. The crown and the leaves are unchanged. A pack
  built before measures it when a species loads (no rebuild needed; its impostor cards keep the old trunk until one).
- The Species dialog (Forest → Species…, the workspace's ⋯, the inspector): every pack and species as pictures,
  search and filters, species and packs switched on and off, a species' settings, Add species from a mesh, Remove from
  pack, building per species, per pack or all; a live 3D view and Inspect (the model against its impostor card, the
  bake's sheets). It replaces Build packs….
- Species pictures: the pack build renders one a species (`built/<id>_picture.res`); a pack built before needs
  building once.
- `ForestConfig.disabled_species`: a species switched off leaves every mix (the rest share its weight); a single tree
  pinned to it grows its type's pick.
- The Types dialog (Forest → Types…, the workspace's ⋯ and the library's footer): a map's forest types and their
  species mixes, a lane inheriting the map's default mix, the bands. It replaces Reload types.
- Type icons and colours: ten glyphs on the type's colour; a type's `icon` and `colour` in the flora profile.
- A type's own `mixes` in the flora profile; the Types dialog's first write turns a type's old pool keys (`pools`,
  `bush_pool`, `pool`, `tree_pool`, `dead`) into them, growing the same forest.
- The workspace library lists the types in the profile's order.
- Pictures and type icons on the existing surfaces: the workspace library's tiles and hover cards (the icon, the
  numbers, each lane's heaviest species as pictures), Pick's readout, the Tree and Row panel's type chips, the Import
  dialog's rule rows and type chips.
- One species picker (a picture grid with a search and By type) in place of the species chips of the Tree and Row
  panel and the Import dialog; it offers every species the packs grow.
- The Tree and Row panel and the Import dialog list the types in the profile's order.
- Right-click menus open at the mouse when the editor's windows float.
- The native core's warning tells a library that did not load from one that is not built; `wuifwoud_core.gdextension`
  asks for Godot 4.8.
- A grid type needs no bush pool. A compressed or mipmapped forest map is read whole; a map's format warning is said
  once.
- The species picker: Enter picks the first match; a search hides tiles rather than rebuilding them, as the Types
  dialog's strip search now leaves the dialog as it is.
- A Revert asked while the import's source is being read lands by itself once it is.
- The Import dialog names the profile a missing type is not in; its report's area by type carries the type icons; its
  progress ends at N of N.
- The far forest says why the native core could not build a cell. A forest with single trees but no maps says only they
  grow.
- `ForestConfig.addon_dir()`, `ForestSpawner.forest_types()` and `ForestSpawner.handover_of()` are public for editor code.

## 1.0.0 (2026-10-08)

The first release.

- Forest maps: one image per Terrain3D region (forest type, density, age), written by a headless or in-editor import
  from GeoJSON and painted in the editor with Terrain3D Extended; painted texels survive a re-import.
- Forest types in a flora profile: natural stands, grids, mixes; species pools by band; clearings, groves, a treeline,
  a sea line, slope thinning, road gaps.
- Single trees and tree rows in `trees.json`, placed and edited in the editor.
- Mesh trees with their authored LOD chains near the camera, impostor cards past them, a canopy far field to the horizon.
- The worker-side work native (`wuifwoud_core`); the main thread kept to a small budget a frame while driving.
- Species packs: `ForestSpecies`, `ForestSpeciesPack`, `ForestPackSet`; pack addons found without being listed; built
  offline (Forest → Build packs…, or `tools/build_packs.gd`); a CC0 starter pack of nine species.
- Trunk colliders around whatever moves; wind, gusts and rotor downwash; a log sink; the same forest on every peer.

### Known limitations
- The native library ships for Linux x86_64 only (glibc 2.31 or newer); Windows and macOS follow. Without it no forest
  grows (said once).
- Tested on Godot 4.8.dev6 and Terrain3D 1.1.0-dev (upstream main at 188873b).
- The pack build's bake needs a renderer: it runs in the editor or windowed, never headless.
