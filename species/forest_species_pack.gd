# Copyright (c) 2026 Digitzone
# SPDX-License-Identifier: MIT
@tool
class_name ForestSpeciesPack
extends Resource
## A pack of tree and bush species: its name, credits and species, in the order a library lists
## them. A project lists its packs in ForestConfig.packs, or installs them as a pack addon (a ForestPackSet at
## res://addons/<name>/wuifwoud_packs.tres). A BUILT pack keeps each species' prepared meshes, impostor atlases and
## built.json in built/ beside this file (Forest → Species…, or res://addons/wuifwoud/tools/build_packs.gd).

## The built folder's name, beside the pack's file.
const BUILT := "built"

## The pack's name.
@export var name := ""
## Who made it, and its licence.
@export_multiline var credits := ""
## Its species, in the order a library lists them.
@export var species: Array[ForestSpecies] = []


## The pack's built folder, beside its file; "" for a pack that is not its own file (made in code, or saved inside
## another resource); such a pack is never built.
func built_dir() -> String:
	if resource_path == "" or resource_path.contains("::"):
		return ""
	return resource_path.get_base_dir().path_join(BUILT)
