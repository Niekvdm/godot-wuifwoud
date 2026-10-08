# Wuifwoud

A streamed forest for [Terrain3D](https://github.com/TokisanGames/Terrain3D) in Godot 4.

<!-- A hero picture goes here: the forest in the editor. -->

- Forests grown from **forest maps**: one small image per terrain region holding the forest type, density and age.
- **Forest types** in a flora profile: natural stands, planted grids, bushes and mixes, with species by elevation band.
- **Mesh trees** with their LOD chains near the camera, **impostor cards** past them, a **canopy far field** to the
  horizon.
- **Single trees and tree rows**, placed by hand or imported.
- An **import** from GeoJSON, an **Import dialog** and **paint tools** in the editor (with Terrain3D Extended).
- **Species packs** built offline, and a CC0 **starter pack** of nine species that grows out of the box.
- Trunk colliders around moving bodies, wind, gusts and vehicle push.
- The same forest on every peer of a multiplayer game, with nothing synced.

## Requirements

- Godot 4.8 (tested on 4.8.dev6).
- Terrain3D 1.1 (tested on 1.1.0-dev, upstream main at 188873b).
- The Forward+ renderer. Without a RenderingDevice (headless) the forest draws one MultiMesh per chunk and species.
- The native library `wuifwoud_core`, included for Linux x86_64 (glibc 2.31 or newer). For Windows and macOS, build it
  (see "Building the native library").
- Optional: [Terrain3D Extended](https://github.com/Niekvdm/godot-terrain3d-extended) 1.2 or newer, for painting,
  placing trees and the Import dialog.

## Install

1. Put this repository at `addons/wuifwoud`, as a copy or a submodule:
   `git submodule add https://github.com/Niekvdm/godot-wuifwoud.git addons/wuifwoud`.
2. Install Terrain3D first.
3. Enable **Wuifwoud** in Project Settings → Plugins, then restart the editor once to load the native library.

## Quick start

1. Add a `ForestSpawner` node to a scene that has a Terrain3D node.
2. Set its `profile_path` to a flora profile. `res://addons/wuifwoud/packs/starter/starter_flora.json` works out of the
   box (types 1 Mixed forest, 2 Conifer forest, 3 Bushland).
3. Give the terrain forest maps: run the import (below), or paint them in the Forest workspace.

The forest reads its maps from `<the terrain's data_directory>/forest/`, or from the node's `maps_directory`.

## Configuration

A `ForestConfig` resource at `res://wuifwoud_config.tres` (or at the path in the project setting
`wuifwoud/config_path`) holds the project-wide settings. Without one, the forest uses the starter pack and its flora.

| Field | Meaning |
|---|---|
| `runtime_inputs` | Feeder scripts (`ForestFeeder`) added under every forest node in the game |
| `editor_inputs` | Feeders that also run in the editor (`@tool` scripts) |
| `packs` | The species packs this project lists |
| `disabled_packs` | Packs not to grow, by `res://` path: a listed pack, a pack addon, one of its packs, or the starter |
| `default_profile_path` | The fallback flora: its `species` and `dead` pools fill what a profile lacks (empty: the starter's flora) |
| `imports_dir` | Where the Import dialog keeps each scene's mapping |
| `collision_group` | Trunk colliders follow the members of this group (default `vehicles`) |
| `trunk_layer`, `trunk_mask` | The trunk colliders' physics layer and mask |
| `trunk_meta` | Metadata set on the trunk colliders' body |

The `ForestSpawner` node's settings are grouped in the inspector (Forest, Trees, Bushes, Impostor cards, Far forest,
Roads, Wind and vehicles, Ground clutter, Streaming, Performance); each tooltip gives the unit and what 0 means.

## Forest maps

One RGBA8 image per Terrain3D region, named like the region's file (`terrain3d_00-01.res`):

| Channel | Meaning | Neutral |
|---|---|---|
| R | forest type: 0 nothing grows, 1-255 a type of the profile | 0 |
| G | density: 255 the type's full density, 128 about half | 255 |
| B | age: 0 young regrowth, 128 as authored, 255 old growth | 128 |
| A | 255 painted by hand, 0 imported; ignored when growing | 0 |

A map is `region_size / t` texels square, with `t` (vertices per texel) 1, 2, 4 or 8. A region without a map grows
nothing.

## Forest types

A flora profile's `types` list defines each map type:

```json
"types": [
  {"id": 1, "name": "Forest", "style": "natural", "density_per_m2": 0.038, "clump": 0.6, "understory": 0.4,
   "edge_wall_m": 34.0, "edge_wall_mult": 3.0},
  {"id": 2, "name": "Scrub", "style": "bushes", "density_per_m2": 0.016},
  {"id": 3, "name": "Garden", "style": "mix", "density_per_m2": 0.0067},
  {"id": 4, "name": "Orchard", "style": "grid", "pitch_m": 7.0}
]
```

| Style | Grows |
|---|---|
| `natural` | Species by elevation band (the profile's `bands`), dead trees, clearings, groves, a mature wall along roads, understory bushes, the treeline |
| `bushes` | The bush pool |
| `grid` | A planted grid |
| `mix` | `tree_share` (0.6) trees from `tree_pool`, the rest bushes |

| Field | Styles | Default |
|---|---|---|
| `id` (1-255, unique), `name`, `style` | all | required |
| `density_per_m2` | natural, bushes, mix | required |
| `pitch_m` | grid | 7.0 |
| `clump` (0-1), `understory` (0-2), `edge_wall_m`, `edge_wall_mult` (≥1), `dead_frac` | natural | 0, 0.35, 0, 1, 0.03 |
| `pools` (`{coast, mid, high}` → pool names), `dead` (band → dead pool names) | natural | the band names |
| `bush_pool` | all | `"bush"` |
| `pool` | grid | `"orchard"` |
| `tree_pool`, `tree_share` | mix | `"mid"`, 0.6 |
| `far_color` (`"#rrggbb"`) | all | from the species' bakes |

Pools are looked up by name in the profile's `species` and `dead`, then in the fallback flora's.

## The import

A mapping file turns world-space GeoJSON into forest maps. Polygons paint types; points and lines become single trees
and rows.

```json
{"schema": "wuifwoud_import/1",
 "source": "res://my_map/landuse.geojson",
 "data_directory": "res://my_map/terrain",
 "texel_vertices": 1,
 "exclusions": ["res://my_map/bare_ground.json"],
 "rules": [
   {"match": {"landuse": ["forest", "wood"]}, "type": 1},
   {"match": {"natural": "scrub"}, "type": 2, "density": 0.7, "age": -0.5},
   {"match": {"natural": "bare_rock"}, "type": 0}]}
```

```
godot --headless --script res://addons/wuifwoud/tools/import_forest.gd -- --mapping <file> [--discard-painted]
```

- A rule matches when every key of its `match` matches (one value or a list); the first matching rule wins.
- `density` (0-1) and `age` (−1…1) set G and B; type 0 means nothing grows.
- Exclusion zones (schema `vegetation_exclusions/1`) clear everything under them.
- An import rewrites every map but keeps texels painted by hand; `--discard-painted` overwrites them. The maps change
  all at once at the end; Cancel or an error leaves them as they were.
- The report lists the area per type and every unmatched property value.

## In the editor

With the plugin enabled, the forest grows around the editor camera.

- **The Forest menu** (3D view toolbar): *Show forest*, *Re-grow*, *Build packs…*.
- **The Forest workspace** (Terrain3D Extended's rail):

  | Tool | Does |
  |---|---|
  | Paint | Paints the selected type. Ctrl: no forest. |
  | Replace | Turns the From type into the selected one. |
  | Density | Raises density. Ctrl: lowers it. |
  | Age | Older forest. Ctrl: younger. |
  | Smooth | Evens out density and age. |
  | Revert | Back to what the import mapping says. |
  | Pick | Selects the type under the cursor and shows its density and age. |
  | Tree | Click places a single tree, drag moves it, Ctrl deletes it. |
  | Row | Drag draws a row; drag a vertex to move it, the line to add one; Shift moves the row; Ctrl deletes. |

- **Saving:** painted maps and `trees.json` are saved with the scene (Ctrl+S); each stroke or gesture is one undo step.
- **Import…** (the workspace's ⋯ menu) opens the Import dialog for the open scene. Its mapping lives at
  `<ForestConfig.imports_dir>/<scene name>.json`:
  - **Rules:** drag property values onto rules; order the rules; set each rule's type, density, age, and for points
    and lines its spacing, clearance and species.
  - **Source:** the GeoJSON files, the terrain folder, the texel size and the exclusion files.
  - **Run** imports on a worker thread, with progress and Cancel; the forest regrows when it finishes.

Painted maps are files beside the terrain's region files: keep them under version control or back them up.

## Single trees and rows

`trees.json`, beside the forest maps, holds single trees and tree rows, one item per line:

| Field | Meaning |
|---|---|
| `id` | the item's id, never reused |
| `kind` | `tree` (`at`: `[x, z]`) or `row` (`points`: two or more `[x, z]`) |
| `type`, `age` | a forest type and an age, as the maps' R and B |
| `species` | a fixed species (empty: the type picks) |
| `spacing_m` | a row's distance between trees (default 8 m) |
| `clear_m` | map trees within this distance are not grown (default 3 m a tree, 2.5 m a row) |
| `source`, `edited` | an imported item's key, and whether it was changed by hand |

`removed` lists the imported items deleted by hand. A re-import keeps hand edits, deletions and hand-made items.
Items keep `item_road_margin` (default 0 m) from the road corridor, so street trees stand at the verge.

## The far forest

Past the impostor cards (`billboard_far_m`) the forest continues as a canopy shell built from the forest maps, one mesh
per far cell, coloured from the species' impostor bakes.

| Setting | Default | Meaning |
|---|---|---|
| `far_forest` | true | the far forest on or off |
| `far_fade_m` | 600 | the hand-over band under the last cards |
| `far_cell_regions` | 4 | regions per far cell, each way |
| `far_grid_m` | 16 | the shell's quad size (divides the region) |
| `far_texel_m` | 8 | the summary's texel size (divides `far_grid_m`) |

## Species packs

Trees and bushes come from species packs, edited in the inspector:

- **`ForestSpecies`:** one species: `id`, `kind` (`tree` or `bush`), `crown` (`broadleaf`, `conifer` or `palm`),
  `trunk_radius` (0: no collider), `mature` / `young`, `alpha_cut`, and its files by path: `mesh` (a scene whose
  `<name>_LOD0..3` nodes are its LOD chain), `foliage_materials`, and the bark and foliage `albedo` / `normal` / `mtao`
  textures.
- **`ForestSpeciesPack`:** a `name`, `credits` and its `species`.
- **`ForestPackSet`:** the packs a pack addon ships.

Packs are found in this order: the ones `ForestConfig.packs` lists; every `res://addons/<name>/wuifwoud_packs.tres` (a
`ForestPackSet`); the starter pack. `ForestConfig.disabled_packs` removes any of them. Species ids are unique: the first
pack wins.

### Building packs

A pack's build writes each species' meshes and impostor sheets into `built/` beside the pack, with `built.json`. The
forest loads built species; an unbuilt one is prepared when the forest starts, without an impostor.

- **Forest → Build packs…** lists each species' state (built, not built, needs building, mesh missing) and builds what
  is needed, or everything.
- **Command line** (windowed, not headless: the bake needs a renderer):

  ```
  godot --path . --display-driver x11 --rendering-driver vulkan --resolution 256x256 --position -6000,-6000 \
      --script res://addons/wuifwoud/tools/build_packs.gd -- [--pack <res://…/pack.tres>] [--species <id>,…] [--all]
  ```

  The exit code is the number of species that failed.

If your meshes may not be redistributed, keep the pack's `built/` out of version control and build it after cloning.

### The starter pack

`packs/starter/` holds nine CC0 species from Quaternius' [Stylized Nature MegaKit](https://quaternius.com), already
built: two broadleaf trees, a young tree, two pines, a dead tree, a bush, a fern and a plant (ids `WW_*`). Its flora,
`packs/starter/starter_flora.json`, defines three forest types and is the fallback flora when the config names none.
Disable it with `ForestConfig.disabled_packs` once you have your own species.

## Feeding the forest

Feeders are nodes extending `ForestFeeder`, added under the forest from `ForestConfig.runtime_inputs`. Override
`_ready` for one-off inputs and `_feed(dt)` for per-frame ones, and call the forest:

| Call | Does |
|---|---|
| `set_wind(dir: Vector2, speed: float)` | Sets the wind (m/s) |
| `apply_quality_params(p)`, `rebuild_for_quality()` | Applies a quality tier: `visibility`, `lod_bias`, `shadow_ring`, `billboard_far`, `density_scale` |
| `set_road_segments(segs: PackedFloat64Array)` | The road corridor: 5 floats per segment, `(ax, az, bx, bz, half width)` |
| `set_push_points(slots: PackedVector4Array)` | Up to 4 vehicles `(x, z, radius, strength)` that push the undergrowth aside |
| `set_washes(washes: PackedVector4Array)` | Up to 2 rotor downwashes `(x, z, radius, intensity)` |
| `ForestLog.sink` | Receives the forest's log lines: `Callable(level, message)` |

Other code finds the forest in the group `wuifwoud_forest`; `crowns_near(p, r)` and `trunks_near(p, r)` return the tree
crowns and trunks around a point, and `frame_timings()` the last frame's main-thread time per phase.

## Tools and tests

- `tools/import_forest.gd`: the command-line import.
- `tools/build_packs.gd`: the command-line pack build.
- `tools/wf_mesh_stats.gd`: a per-species cost sheet (`VEG_PROFILE` picks the flora profile).
- `VEG_OCCLUSION=1` turns on Hi-Z occlusion culling; `VEG_CULL_TIMING=1` times the cull pass.
- Members documented "For tools and tests" are for tools and tests only.

Run the unit suites in a project with the addon and Terrain3D installed:

```
godot --headless --path <project> --script res://addons/wuifwoud/tests/run_all.gd
```

The exit code is the number of failing suites.

## Building the native library

Requirements: `scons`, a C++17 compiler, and godot-cpp for your engine version at `native/godot-cpp`.

1. `godot --headless --dump-extension-api` writes `extension_api.json`.
2. In `native/`: `scons target=template_debug custom_api_file=<extension_api.json>`, then `target=template_release`.
3. Copy `native/bin/libwuifwoud_core.*` into `bin/` and restart the editor.

`wuifwoud_core.gdextension` already names the Linux, Windows and macOS libraries. On Linux,
`native/build_linux_portable.sh <extension_api.json>` builds in an Ubuntu 20.04 container (podman or docker), so the
library runs on glibc 2.31 and newer.

## License

MIT, see [LICENSE](LICENSE). The starter pack (`packs/starter/`) is CC0 1.0, see
[packs/starter/LICENSE](packs/starter/LICENSE).
