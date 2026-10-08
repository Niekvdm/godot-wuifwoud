# Copyright (c) 2026 Digitzone
# SPDX-License-Identifier: MIT
@tool
extends "res://addons/wuifwoud/forest_feeder.gd"
## Test fixture: a feeder that may run in the editor (@tool).

var readies := 0


func _ready() -> void:
	readies += 1
