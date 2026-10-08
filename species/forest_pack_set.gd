# Copyright (c) 2026 Digitzone
# SPDX-License-Identifier: MIT
@tool
class_name ForestPackSet
extends Resource
## A pack addon's index: the packs one addon ships, each its own ForestSpeciesPack file in its
## own folder (so each keeps its own built/). Wuifwoud finds it at res://addons/<name>/wuifwoud_packs.tres without the
## project listing it (ForestConfig.resolved_sources).

## The set's name; empty: its folder's.
@export var name := ""
## Its packs, in the order they are used.
@export var packs: Array[ForestSpeciesPack] = []
