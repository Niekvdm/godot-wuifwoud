# Wuifwoud

A streamed forest for [Terrain3D](https://github.com/TokisanGames/Terrain3D), for Godot 4: woods grown from forest maps
you import and paint, mesh trees with their authored LOD chains near the camera, baked impostor cards past them and a
canopy far field to the horizon, single trees and tree rows, trunk colliders around whatever moves, and wind.

<!-- A hero picture goes here: the forest in the editor. -->

Forest maps, one small image per terrain region, say where each forest type grows, how dense and how old. A flora
profile says what each type is: a natural stand, a planted grid, bushes or a mix, with its species by elevation band.
The forest is grown in a ring around the camera on the engine's worker threads, by a native library, and every tree is
decided from integer hashes, so every peer of a multiplayer game grows the same forest from the same maps with nothing
synced. Species come in packs, built offline into meshes and impostor sheets; a CC0 starter pack ships with the addon,
so a project grows real trees before it has any of its own.

## Requirements

- Godot 4.8 (tested on 4.8.dev6).
- Terrain3D 1.1 (tested on 1.1.0-dev, the upstream main branch at 188873b; a Terrain3D build with streaming also works).
- The Forward+ renderer for the GPU-driven path (a compute shader culls and bins every tree each frame). Without a
  RenderingDevice, for example headless, the forest falls back to one MultiMesh per chunk and species.
- The addon's native library, `wuifwoud_core`: 1.0.0 ships it for Linux x86_64 (glibc 2.31 or newer: any distribution
  from 2020 on); Windows and macOS follow (see "Building the native library"). Without it no forest grows, and the
  forest says so once.
- Optional: [Terrain3D Extended](https://github.com/Niekvdm/godot-terrain3d-extended) 1.2 or newer, the editing overlay,
  for painting the maps, placing single trees and rows, and the Import dialog.

## Install

1. Put the addon at `addons/wuifwoud`: as a copy of this repository, or as a git submodule:
   `git submodule add https://github.com/Niekvdm/godot-wuifwoud.git addons/wuifwoud`. (The Asset Library entry
   follows with the other platforms' libraries.)
2. Terrain3D must be installed and working first.
3. Enable **Wuifwoud** in Project Settings, Plugins, and restart the editor once so it registers the native library.

## Setup

1. Give the project a `ForestConfig` resource at `res://wuifwoud_config.tres` (the project setting
   `wuifwoud/config_path` overrides that path; Wuifwoud only reads it).
2. Write a flora profile with forest `types` (below) and a mapping file, and run the import: it writes the forest maps
   beside the terrain's region files.
3. Add a `ForestSpawner` node to your scene and set its `profile_path`. It finds the terrain and its maps
   (`<the terrain's data_directory>/forest/`, or `maps_directory`).
4. To paint: enable the plugin with Terrain3D Extended 1.2 or newer installed (below, "In the editor").

| `ForestConfig` field | Meaning |
|---|---|
| `runtime_inputs` | Feeder scripts (`ForestFeeder`) added under every forest node in the game, one node per script |
| `editor_inputs` | Feeders that also run in the editor: `@tool` scripts only (a road feeder there gives the preview its road gaps) |
| `packs` | The species packs this project lists (below, "Species packs") |
| `disabled_packs` | Packs not to grow, by `res://` path: a listed pack, a pack addon, one of its packs, or the starter |
| `default_profile_path` | The fallback flora: a profile file whose `species` and `dead` pools fill the ones a profile lacks (empty: the starter pack's flora, unless the starter is disabled) |
| `imports_dir` | Where each map's import mapping lives, for the editor's Import dialog |
| `collision_group` | Trunk colliders are kept around the members of this group (default `vehicles`) |
| `trunk_layer`, `trunk_mask` | The trunk colliders' physics layer and mask (default 1 and 1) |
| `trunk_meta` | Metadata set on the trunk colliders' body, for your own collision handling |

Without a config the forest runs with no feeders, with the starter pack's species and its flora as the fallback flora,
and warns once. A profile without `types`, or a terrain without maps, grows nothing and says so once.

**The forest node** (`ForestSpawner`) shows its settings in the inspector in groups: Forest (the profile, the maps, the
seed, the sea line), Trees, Bushes, Impostor cards, Far forest, Roads, Wind and vehicles, Ground clutter, Streaming and
Performance. Each setting's tooltip says what it does, its unit and what 0 means.

## Forest maps

One RGBA8 image per Terrain3D region, saved as `<maps folder>/<the region's own file name>` (`terrain3d_00-01.res`):

| Channel | Meaning | Neutral |
|---|---|---|
| R | forest type: 0 = nothing grows, 1-255 = a type of the profile | 0 |
| G | density share: 255 grows all of the type's density, 128 about half (always a subset of the fuller stand) | 255 |
| B | age: 0 young regrowth (young species, smaller trees) … 128 the type as authored … 255 old growth | 128 |
| A | painted by hand (255) or as imported (0); ignored when the forest grows | 0 |

A map is `region_size / t` texels square, `t` (vertices a texel) one of 1, 2, 4 or 8, read from each map itself (the
import writes one `t` per run, but a forest may mix them). A map of any other size is an error and its region grows
nothing; the other maps are not affected. A region without a map grows nothing. Maps are read on demand as the ring
follows the camera, within a byte budget (`ForestMaps.budget_mb`, 64 MB), and released after. Every peer of a
multiplayer game that has the same maps grows the same forest: placement is seeded from the grid cell, the type and the
node's `forest_seed`.

## Forest types

A flora profile's `types` list says what each map type id is:

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
| `grid` | A planted grid, no jitter |
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

Pools are taken by name from the profile's `species` and `dead` (and the fallback flora's). A type naming a pool
nobody has is an error and is dropped; the other types still load.

## The import

World-space GeoJSON polygons (`"coord_space": "world"`) and a mapping file become the forest maps. Points and lines
become single trees and rows (below), through the same rules; `source` may list several files.

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

- A rule matches when every key of its `match` matches a feature property (a value, or a list of values); the first
  matching rule wins, so rule order is the priority where features overlap. Type 0 writes "nothing grows".
- `density` (0-1) and `age` (−1…1) go into G and B.
- Exclusion zones (schema `vegetation_exclusions/1`) write "nothing grows" over everything.
- An import replaces the maps folder: every region with a region file and some forest gets a map; a map of a region
  that now has none is deleted. The report lists the area per type and every unmatched property value with its area.
- **It keeps every texel painted by hand** (A = 255): those texels stay, every other texel takes the import; a painted
  map where nothing grows any more is kept; a map whose terrain region is gone is deleted. A texel size change
  resamples the paint (no painted texel is lost). `--discard-painted` overwrites painted texels. An import runs region
  by region into a hidden staging folder beside the maps (`forest/.importing`) and swaps them in at the end, so the
  maps are all old or all new; Cancel or an error leaves them as they were. The report lists what was written, kept
  for its paint, resampled and deleted. A map file that cannot be read stops the import: it might hold paint.
- Every map is written with a fixed resource id, so the same map is the same bytes whoever wrote it.

## In the editor

The forest node is `@tool`: in the editor it grows the game's own forest around the editor camera (Terrain3D's camera),
from the same maps, with the same ring and workers; nothing it makes is stored in the scene. With the plugin enabled:

- **The Forest menu** (the 3D view's toolbar): *Show forest* turns the preview off and on (kept in the project's editor
  metadata, never in a scene); *Re-grow* grows it again from the maps; *Build packs…* builds the species packs (below,
  "Species packs").
- **The Forest workspace** (Terrain3D Extended's rail; size and strength from its bar):

  | Tool | Does |
  |---|---|
  | Paint | Paints the selected type where the brush weight is 0.5 or more; empty ground starts at full density and neutral age, forest keeps its own. Ctrl: no forest. |
  | Replace | Turns the From type (the bar's From chip) into the selected one. |
  | Density | Raises the density (G) of forest under the brush. Ctrl: lowers it. |
  | Age | Older forest (B). Ctrl: younger. |
  | Smooth | Evens out density and age under the brush. |
  | Revert | Back to what the import mapping says, unmarked (see "Importing in the editor"). |
  | Pick | The eyedropper beside the bar's chip: selects the type under the cursor; the panel says its density, age and whether it was painted. |

  The library is the profile's types (*Reload types* in the panel's ⋯ reads the profile again). Every texel a stroke
  changes is marked A = 255. The trees under a stroke grow again about four times a second while you paint.
- **Undo and saving:** one undo step a stroke, in the scene's own history. The painted maps are saved with the scene
  (Ctrl+S); closing a scene or the editor with unsaved maps asks first.
- **Painted maps are files like the terrain's region files.** If your project does not track those in version control,
  back the maps folder up: a fresh clone loses the paint.

## Importing in the editor

With the plugin and Terrain3D Extended 1.2 or newer, the Forest workspace's ⋯ → **Import…** opens the Import dialog
for the open scene:

- **The scene's mapping** is `<ForestConfig.imports_dir>/<scene name>.json` (set `imports_dir` in your
  `ForestConfig`). Without one the dialog offers *Start a mapping* (from the scene's terrain folder); a mapping file
  that cannot be read is named and never overwritten; a scene never saved has no mapping name yet.
- **Rules tab:** the source's values for one property (its keys as chips: an id-like key, where every feature has its
  own value, comes last and dim), each with its area, length of lines or count of points and its rule's colour (the 200
  largest; the rest are counted), *All* / *Unmatched*. Drag a value onto a rule, onto *a new rule*, or back to take it
  out. The rules are in priority order (the first rule a feature matches paints it), and a row's ≡ drags it onto
  another row. The selected rule: its type (the profile's types and *No forest*), its match (every key must match; ✕
  takes a value out), Density and Age, for points and lines Spacing, Clearance and the species, Delete. *No rule* says
  what no rule matches.
- **Source tab:** the source files (each world-space GeoJSON, added and removed in a list), the terrain folder (and a
  note when the scene's forest reads its maps from another folder), the texel size and what a texel costs, the exclusion
  files.
- **Every change is one undo step** in the dialog (Ctrl+Z / Ctrl+Shift+Z) and is written to the mapping at once; the
  maps change only on **Run**.
- **Run** runs the import on a worker: the editor stays free, the dialog shows the progress and Cancel, and the Forest
  tools pause meanwhile (the dialog is read-only until it ends). The scene's unsaved paint and single trees and rows are
  merged in and written by it; afterwards every forest reading that folder regrows. *Overwrite painted texels* asks
  first.
- **Revert** (a Forest tool) brushes texels back to what the mapping says now, unmarked.
- **An import is not an undo step:** to go back, undo the mapping in the dialog and run again. A paint stroke from
  before an import does not undo afterwards (it would put the old import back); the cursor note says so.

## Single trees and rows

Beside the forest maps, `trees.json` in the same folder holds **items**: single trees (a point) and tree rows (a
line). It is JSON, one item a line, in stable bytes (keys in a fixed order, 0.01 m rounding, defaults left out), so a
version-control diff shows exactly the items that changed. No file: no items.

| Field | Meaning |
|---|---|
| `id` | given once, never reused; a tree's seed is (id, its index along the row, type, `forest_seed`) |
| `kind` | `tree` (`at`: `[x, z]`) or `row` (`points`: two or more `[x, z]`) |
| `type`, `age` | a forest type and an age, as the maps' R and B |
| `species` | pins the species (empty: the type picks) |
| `spacing_m` | a row's distance between trees (8 m): a tree at both ends and evenly between, each nudged a little |
| `clear_m` | map trees within this distance of the tree, or of the row's line, are not grown (3 m a tree, 2.5 m a row) |
| `source`, `edited` | the import's key for an imported item; `edited` once the author changed it |

`removed` lists the keys of imported items the author deleted.

A malformed item (a hand edit, a merge) is dropped and named, and the rest grow. A file that did not read whole is
left as it is until it is fixed by hand: the editor neither edits nor saves it, and the import stops (*Overwrite painted
texels* replaces it).

**How they grow.** Through the forest's own pipeline: species by the type's style and band, scale by age, LOD,
impostor cards, trunk collision, wind. The sea line, the road gap and the cliff cut apply; clearings, density, the
quality tier, the treeline and the slope thinning do not. Every peer reading the same file grows the same trees. The
road gap an item keeps is the road corridor itself (`item_road_margin`, 0 m), not the map trees' `road_margin` beyond
it, so a street tree stands at the verge.

**The import** makes a point a single tree and a line a row, with the matching rule's `type`, `age`, `spacing_m`,
`clear_m` and `species`. A re-import keeps every item the author edited, keeps deleted ones deleted, never touches
hand-made ones, and writes the file only when it changes; a row is cut at the exclusion zones' edges.
`--discard-painted` (*Overwrite painted texels*) drops the edits and the deletions, never a hand-made item.

**In the editor** the Forest workspace's **Tree** and **Row** tools place them: a click places a tree, a drag on one
moves it, Ctrl deletes it; a drag draws a row, dragging a vertex moves it, dragging the line adds one, Shift moves the
whole row, Ctrl deletes a vertex or the row. The panel edits the selected item (Revert to import for an edited
imported one); ⋯ → Restore deleted imports brings deleted imports back. Each gesture is one undo step; the file is
saved with the scene.

## The far forest

Past the impostor cards (`billboard_far_m`) the forest goes on as a **canopy shell**: one mesh and one summary texture
per far cell (`far_cell_regions` regions each way), raised to canopy height over forested ground, built from the same
forest maps. Each map is summarised once at 8 m a texel (type, cover, age); the shell is a 16 m grid over the cover,
its edges walls down to 5 m under the sea line: deep enough to meet a coarser far-field terrain that a game may draw
past its streamed regions, and inside the hill wherever the true ground is drawn. Crowns are drawn per fragment
(cellular noise at the type's tree spacing), coloured from the cards' own impostor bakes (each species' mean crown
colour, by the type's pools and band) and lit like them. The sea line, the treeline and the cliff cut apply as they do
to the cards. Over the last `far_fade_m` (600 m) before the cards end, the shell dithers in as they dither out, on the
cards' own (3D) distance.

| Export | Default | Meaning |
|---|---|---|
| `far_forest` | true | the far forest on (a host turns it off where nothing draws, a dedicated server) |
| `far_fade_m` | 600 | the hand-over under the last cards |
| `far_cell_regions` | 4 | regions a far cell spans, each way |
| `far_grid_m` | 16 | the shell's quad size (divides the region) |
| `far_texel_m` | 8 | the summary's texel size (divides `far_grid_m`) |

A type may set `far_color` (`"#rrggbb"`) to override its far palette; a type none of whose species has a bake is drawn
dark green, said once. In the editor the shell follows painting (the touched cells rebuild at most every 250 ms) and
rebuilds after an import or Reload types. Files are read through the threaded loader and dropped, so the far build keeps
no region copies. It starts after the ring around the player has filled (the two share the engine's low-priority
workers), and builds the 12 cells of a 50 km² island in about a second. For diagnostics the shader's `debug_mode`
uniform draws the canopy flat magenta and the walls flat red (1: as cut; 2: the whole mesh uncut); it is 0 in play.

## Species packs

The trees and bushes come from **species packs**, three resources edited in the inspector:

- **`ForestSpecies`:** one species. `id` (the name the profiles, the forest types and `trees.json` use), `kind`
  (`tree`, or `bush`: no card, a short dissolve, no shadow), `crown` (`broadleaf`, `conifer` or `palm`: the card's
  silhouette family), `trunk_radius` (the trunk collider; 0: none), `mature` / `young` (the subsets a map's age, a
  roadside wall and a glade edge draw from), `alpha_cut`, and its files **by path**: `mesh` (an imported scene; its
  `<name>_LOD0..3` nodes are the authored LOD chain, else its largest mesh and a generated chain), `foliage_materials`
  (the leaf surfaces' material names; empty: the name rule, where bark, trunk and wood are bark and leaf, leaves,
  needle, vegetation and cutout are foliage), and the bark and foliage `albedo` / `normal` / `mtao` textures. Paths,
  not resource dependencies: a pack whose meshes are missing still loads, and each such species is named once and not
  drawn.
- **`ForestSpeciesPack`:** a `name`, `credits` and its `species`, in order.
- **`ForestPackSet`:** a pack addon's index: the packs one addon ships, each its own pack file in its own folder.

**Where packs come from**, in this order (`ForestConfig.resolved_sources()`):

1. the packs `ForestConfig.packs` lists;
2. **pack addons**: every `res://addons/<name>/wuifwoud_packs.tres` (a `ForestPackSet`), found without being listed,
   sorted by folder;
3. the built-in **starter pack** (`packs/starter/starter.tres`).

`ForestConfig.disabled_packs` takes out, by `res://` path, a pack the config lists, a whole pack addon (its
`wuifwoud_packs.tres`), one pack of a pack addon, or the starter. Species ids are unique across the packs that grow: the
first resolved pack wins a clash, and the forest says so once. A species no pack has is placed as a broadleaf tree with
a 0.26 m trunk, and named in one warning.

### Building packs

A species is **prepared** before it is drawn: its mesh read, its LOD meshes made, its impostor baked (a sheet of views
of the tree, albedo and normal, that the cards and the far forest draw). A pack's build does that once, offline, and
keeps the result in **`built/`** beside the pack's file: each species' meshes (`<id>.res`), its impostor sheets
(`<id>_albedo.res`, `<id>_normal.res`: BC7 images) and `built.json` (what each was built from and by which pack, the
bake's framing, the crown colour). The same species is the same bytes whoever builds it, so a committed `built/` only
changes when what it was built from does. The forest then **loads** a built species instead of preparing it. A species
not built (or out of date) is prepared when the forest starts: the same result, slower, and without a baked impostor;
the forest says so once a pack.

- **Forest → Build packs…** (the 3D view's toolbar, with the plugin enabled) lists each pack's species and its state:
  *built*, *not built*, *needs building* (and why: another preparation version, a built file gone, a source file new,
  gone or changed (a source's size and time first, then its bytes; a glTF's buffer files count), its leaf materials or
  alpha cut changed, or a file's import settings), *mesh missing*. **Build what's needed** builds those; **Rebuild
  all** builds every species again. The build shows its progress and **Cancel**: what already landed stays. The
  editor keeps drawing while it bakes; when it ends the forest resolves its packs again and regrows (so does
  *Re-grow*: a pack or species added since the forest started grows without restarting the editor).
- **From the command line**, the same job:

  ```
  godot --path . --display-driver x11 --rendering-driver vulkan --resolution 256x256 --position -6000,-6000 \
      --script res://addons/wuifwoud/tools/build_packs.gd -- [--pack <res://…/pack.tres>] [--species <id>,…] [--all]
  ```

  Windowed (off-screen), **never headless**: a headless Godot has no renderer and would bake blank sheets, so the script
  refuses. Its exit code is the number of species that failed.
- A build writes each species into a hidden staging folder and lands it whole, and writes `built.json` whole or not at
  all; built species of a pack that no longer lists them are removed. Two packs in one folder share its `built/`;
  neither's build removes the other's species.
- **A project whose meshes are licensed** (a store asset that may not be redistributed) keeps its pack's `built/` out
  of version control, like the meshes themselves, and builds it once after a fresh clone.

### The starter pack

`packs/starter/` ships with the addon: nine species from Quaternius' [Stylized Nature
MegaKit](https://quaternius.com) (CC0 1.0; `packs/starter/LICENSE`): two broadleaf trees, a young tree, two pines, a
dead tree, a bush, a fern and a plant, ids `WW_*`. It is **built** (its `built/` is committed), so a project grows real
trees with real impostors without building anything. Its flora, `packs/starter/starter_flora.json`, is a full profile
with three forest types (*Mixed forest*, *Conifer forest*, *Bushland*): a scene may name it as its `profile_path`, and
its `species` and `dead` pools are the **fallback flora** when `ForestConfig.default_profile_path` is empty and the
starter is not disabled. A project with its own species disables the starter (`disabled_packs`), so none of them is
prepared or drawn. It is 35 MB on disk: the kit's meshes and textures (its bark textures halved to 1024²) and the built
sheets.

## Feeding the forest

Your game tells the forest about its world through feeders: nodes extending `ForestFeeder` that the forest adds as
children before it plans its first ring. Override `_ready` for one-off inputs and `_feed(dt)` for per-frame ones,
and call the forest's input API:

| Input | What it does |
|---|---|
| `set_wind(dir: Vector2, speed: float)` | The wind in the ground plane, m/s. The sway targets follow it the moment it arrives. A degenerate direction keeps the last one; a negative or NaN speed reads as calm. |
| `apply_quality_params(p)`, `rebuild_for_quality()` | A quality tier: `visibility`, `lod_bias`, `shadow_ring`, `billboard_far`, `density_scale`. Apply before the first ring; after a change, apply and rebuild. `quality_far_ceiling_m` sizes the terrain height cache for the widest tier you may switch to. |
| `set_road_segments(segs: PackedFloat64Array)` | The road corridor trees keep out of: `ROAD_STRIDE` (5) floats per segment, `(ax, az, bx, bz, half width)`. The node's `road_margin` is added for the maps' trees, `item_road_margin` for single trees and rows. An empty array means a map without roads. |
| `set_push_points(slots: PackedVector4Array)` | Up to `PUSH_SLOTS` (4) brushes `(x, z, radius, strength)` the undergrowth leans away from. |
| `set_washes(washes: PackedVector4Array)` | Rotor downwash at the trees, `(x, z, footprint radius, intensity)`, at most 2. |
| `profile_path`, `maps_directory`, `forest_seed` | The flora profile; where the maps are (empty: beside the terrain's region files); the seed every tree's placement mixes in. A feeder may fill the profile a scene leaves empty. |
| `ForestLog.sink` | Where the forest's log lines go: `Callable(level, message)`. By default they print. A line raised on a worker thread reaches the sink on the main thread. |

With nothing fed, the forest still builds and draws: calm wind, the node's own quality values, no road gaps.

Other code finds the forest through the group `wuifwoud_forest`. `crowns_near(p, r)` returns the tree crowns
around a point; `trunks_near(p, r)` returns the trunks. `frame_timings()` hands out the last frame's main-thread
microseconds, phase by phase.

## How it works

- **The native core.** The forest's worker-side work runs in its own GDExtension library, `wuifwoud_core` (source in
  `native/`, the library in `bin/`, declared by `wuifwoud_core.gdextension`): the maps' block summary, a ring cell's
  scatter and the placement of its trees, the far forest's summaries, ground samples and cell meshes, one call a job,
  on the engine's worker pool. The ring, the cells, the commit and the editor stay GDScript. The scripts reach the
  library only by name, through `ClassDB` (`forest_native.gd`): an editor that was open when the library was first
  built does not know its classes until it restarts, and a script that named one would not parse there. A library of
  another version than the scripts expect counts as none, and says so once. Without it the forest grows nothing, near
  or far, and says so once; the maps still read, paint and save.
- **The GPU path.** Each species' instance arena (the instance buffer, its free list, the level-1 block table and what
  waits to be uploaded) is a native `WfArena`: installing a block is one copy, releasing one strided clear, and a
  frame's uploads leave as bytes; the place kernel plans each block's clusters on its worker. A compute shader culls
  every tree each frame and sorts it into its distance band, one indirect MultiMesh per species and band.
- **The main thread while driving.** The forest's main-thread work in a frame (the far landing, the commit and the card
  flush) shares one box (`commit_budget_ms`, the catch-up multiple only while the ring fills from nothing), checked
  between a card cell's species.
- **Nothing is built while driving that could be built before.** On the GPU path every species the map can place (its
  materials, its LOD meshes, a tree's card and the far palette's crown colour) is built when the forest starts, before
  the first fill. A mesh arena starts at 8192 instances (`ForestIndirect.MESH_MIN_CAP`), and when a fill ends (its
  cards drawn) every arena reserves three times its live instances (`ARENA_RESERVE_MULT`), so a drive into a forest
  never regrows one (a regrow rebuilds the species' GPU side in one frame, its buffers and every LOD band's
  MultiMesh). While driving at most one arena's GPU side is built a frame (`realloc_limit`), and the far forest waits
  for the near ring's cards. The fill's end lifts that limit once, so the frame after it rebuilds every arena the
  reserve grew: one long frame (about 70 ms measured) after each load, teleport, respawn, quality change and Re-grow.
  The cost is GPU memory: about 240 MB more at its peak than the arenas grown on demand.
- **The same forest everywhere.** Every keep, drop and pick is decided from integer hashes of the grid cell, the type,
  the point and `forest_seed` (splitmix64); the clearings' and groves' noise is built from those hashes too, and the
  library is compiled without fused multiply-add. Every peer grows the same forest from the same maps, on any compiler
  and CPU; two runs give the same forest byte for byte.

## For tools and tests

The members whose doc comments begin "For tools and tests" (`ForestSpawner.force_editor`,
`ForestAssets.prepared_count`, `ForestIndirect.debug_cull_timing` and `cull_gpu_us`, `ForestConfig.use()`) exist for
tools, tests and debugging; a game has no use for them. `tools/` holds the command-line import (`import_forest.gd`),
the pack build (`build_packs.gd`) and a per-species cost sheet (`wf_mesh_stats.gd`: triangles, cards and the leaf
atlas's alpha occupancy, run as a suite; `VEG_PROFILE` picks the flora profile). Two environment switches:
`VEG_OCCLUSION=1` turns on the GPU path's Hi-Z occlusion cull (off by default), and `VEG_CULL_TIMING=1` timestamps the
cull pass.

## Running the tests

The addon's unit suites run in any project that has the addon, its native library and Terrain3D installed:

```
godot --headless --path <project> --script res://addons/wuifwoud/tests/run_all.gd
```

It prints a line per suite and exits with the number of failing suites. A project whose autoloads need a flag to stay
out of the way passes it after `--`.

## Building the native library

1.0.0 ships `bin/libwuifwoud_core.linux.template_{debug,release}.x86_64.so`; the Windows and macOS builds follow. To
build it yourself, on Linux, Windows or macOS:

1. Install `scons` and a C++17 compiler, and put godot-cpp at the engine's version in `native/godot-cpp` (a checkout or
   a link).
2. Write the engine's API description: `godot --headless --dump-extension-api` (it writes `extension_api.json`).
3. In `native/`: `scons target=template_debug custom_api_file=<extension_api.json>`, and again with
   `target=template_release`.
4. Copy `native/bin/libwuifwoud_core.*` into `bin/`, by rename when an editor is open (it has the old one mapped).
   `wuifwoud_core.gdextension` already names the library for each platform, as scons names it (`.so` on Linux,
   `.windows.….x86_64.dll`, `.macos.….universal.dylib`). Then restart the editor (or run `godot --headless --import`
   once) so the project registers the extension.

A Linux library loads only where the glibc is at least as new as the one it was built on.
`native/build_linux_portable.sh <extension_api.json>` builds it in an Ubuntu 20.04 container (podman or docker), as
1.0.0's was, so it loads on glibc 2.31 and newer; `.release/make_zip.sh` refuses a library that needs a newer glibc.

## What it promises

- **Nothing of a host game.** No file names a host project's path, autoload, class or group. The suite
  `tests/test_wuifwoud_self_contained.gd` pins it, comments included.
- **The same forest on every machine.** Placement is seeded from the maps and the node's `forest_seed` alone, so peers
  in a multiplayer game agree with nothing synced.

## License

MIT, Copyright (c) 2026 Digitzone. See [LICENSE](LICENSE). The starter pack (`packs/starter/`) is Quaternius' Stylized
Nature MegaKit, CC0 1.0: see [packs/starter/LICENSE](packs/starter/LICENSE).
