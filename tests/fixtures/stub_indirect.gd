# Copyright (c) 2026 Digitzone
# SPDX-License-Identifier: MIT
extends Node3D
## Test fixture: stands in for the forest's GPU node: counts clear_all() and update(), keeps the camera it was handed.

var cleared := 0
var updates := 0
var camera: Camera3D = null


func clear_all() -> void:
	cleared += 1


func update(_eye: Vector3) -> void:
	updates += 1


func free_block(_h: Dictionary) -> void:
	pass
