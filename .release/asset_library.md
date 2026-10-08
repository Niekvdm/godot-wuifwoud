# Asset Library entry: Wuifwoud

Paste these into the Godot Asset Library's submission form (https://godotengine.org/asset-library/asset/submit).

| Field | Value |
|---|---|
| Asset name | Wuifwoud |
| Category | 3D Tools |
| Godot version | 4.8 |
| Version | 1.0.0 |
| License | MIT |
| Repository host | Custom |
| Repository URL | https://github.com/Niekvdm/godot-wuifwoud |
| Issues URL | https://github.com/Niekvdm/godot-wuifwoud/issues |
| Download URL | https://github.com/Niekvdm/godot-wuifwoud/releases/download/v1.0.0/godot-wuifwoud-1.0.0.zip |
| Icon URL | https://raw.githubusercontent.com/Niekvdm/godot-wuifwoud/v1.0.0/.release/icon.png |

## Description

A streamed forest for Terrain3D: woods grown from forest maps you import and paint, mesh trees with their authored LOD
chains near the camera, baked impostor cards past them and a canopy far field to the horizon, single trees and tree
rows, trunk colliders around whatever moves, and wind. The forest grows in a ring around the camera on worker threads,
by a native library, and every tree is decided from integer hashes, so every peer of a multiplayer game grows the same
forest. Species come in packs built offline; a CC0 starter pack is included. Paint it with Terrain3D Extended.

Requires Terrain3D and the Forward+ renderer. The native library ships for Linux x86_64 in 1.0.0; Windows and macOS
follow.

## Before submitting

- The platforms: the Asset Library serves every platform, and 1.0.0's native library is Linux x86_64 only. The listing
  waits for the Windows and macOS builds in `bin/`.
- The URLs work once the v1.0.0 release carries the zip (`.release/make_zip.sh`).
- The addon is tested on Godot 4.8.dev6 and Terrain3D 1.1.0-dev. The Asset Library lists assets against released Godot
  versions, so the listing also waits for Godot 4.8 and Terrain3D 1.1, or for a test on the released versions a listing
  would name.
