# Copyright (c) 2026 Digitzone
# SPDX-License-Identifier: MIT
@tool
extends RefCounted
## Finds the edited scene's forest for the Wuifwoud plugin: kept per edited scene, and a scene without one is walked
## at most once every MISS_MS (the Place tools ask on every mouse move, and walking a whole map scene each
## time would be slow. A forest added to a scene is found within MISS_MS.

## The forest node.
const ForestSpawnerRes := preload("res://addons/wuifwoud/forest_spawner.gd")
## A scene without a forest is walked again at most this often (ms).
const MISS_MS := 1000

## How many times a scene was walked (tests)
var walks := 0
var _root: Node = null
var _found: Node = null
var _miss_until := 0


## The forest under `root` (the root itself, or the first ForestSpawner below it), or null. `now_ms`: tests' clock.
func find(root: Node, now_ms: int = -1) -> Node:
	if root == null:
		return null
	var now := now_ms if now_ms >= 0 else Time.get_ticks_msec()
	if root == _root:
		if _found != null and is_instance_valid(_found) and (root == _found or root.is_ancestor_of(_found)):
			return _found
		if _found == null and now < _miss_until:
			return null
	_root = root
	walks += 1
	_found = root if root.get_script() == ForestSpawnerRes else null
	if _found == null:
		for n in root.find_children("*", "Node3D", true, false):
			if n.get_script() == ForestSpawnerRes:
				_found = n
				break
	_miss_until = now + MISS_MS if _found == null else 0
	return _found
