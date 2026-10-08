# Changelog

## Unreleased

- The Species dialog (Forest → Species…, the workspace's ⋯, the inspector): every pack and species as pictures,
  search and filters, species and packs switched on and off, a species' settings, Add species from a mesh, Remove from
  pack, building per species, per pack or all; a live 3D view and Inspect (the model against its impostor card, the
  bake's sheets). It replaces Build packs….
- Species pictures: the pack build renders one a species (`built/<id>_picture.res`); a pack built before needs
  building once.
- `ForestConfig.disabled_species`: a species switched off leaves every mix (the rest share its weight); a single tree
  pinned to it grows its type's pick.

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
