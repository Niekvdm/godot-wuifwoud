# Copyright (c) 2026 Digitzone
# SPDX-License-Identifier: MIT
@tool
class_name ForestFeeder
extends Node
## A node that feeds its parent ForestSpawner. Override _ready for one-off inputs (data paths, the quality tier,
## the log sink): a feeder the forest adds readies inside the forest's own _ready, before the first ring is
## planned. Override _feed(dt) for per-frame inputs (wind, push points, washes); never _process. It runs just before
## the forest (FEED_PRIORITY). A project lists feeder scripts in ForestConfig.runtime_inputs; a feeder already
## placed under the forest in a scene replaces the config's copy of its script.

## Feeders run before the forest in a frame, so its inputs are fresh when it reads them.
const FEED_PRIORITY := -1

## The ForestSpawner this feeds: its parent, found when it enters the tree.
var forest: Node3D = null
var _warned := false


func _notification(what: int) -> void:
	if what == NOTIFICATION_ENTER_TREE:
		var p := get_parent() as Node3D
		if p != null and p.is_in_group(&"wuifwoud_forest"):
			forest = p
		elif forest == null and not _warned:
			_warned = true
			ForestLog.warn("[Wuifwoud] ForestFeeder %s: its parent is not a forest, so it feeds nothing" % name)
		process_priority = FEED_PRIORITY


func _process(dt: float) -> void:
	if forest != null and is_instance_valid(forest):
		_feed(dt)


## Override: this frame's inputs, through the forest's input API.
func _feed(_dt: float) -> void:
	pass
