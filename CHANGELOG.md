# Changelog

## Unreleased

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
