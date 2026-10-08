# Copyright (c) 2026 Digitzone
# SPDX-License-Identifier: MIT
extends "res://addons/wuifwoud/forest_feeder.gd"
## Test fixture: records what it saw when it readied and how often it fed.

var saw_forest := false
var pool_existed_at_ready := true
var feeds := 0


func _ready() -> void:
	saw_forest = forest != null
	pool_existed_at_ready = forest != null and forest.get_node_or_null(^"TreeCollision") != null


func _feed(_dt: float) -> void:
	feeds += 1
