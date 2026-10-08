# Copyright (c) 2026 Digitzone
# SPDX-License-Identifier: MIT
extends Node
## Test fixture: stands in for a terrain whose camera follows the editor's 3D view (get_camera()); and, when
## region_size is set, the terrain the forest's maps are configured from.

var cam: Camera3D = null
var region_size := 0          # 0: the forest configures no maps from it
var vertex_spacing := 1.0
var data_directory := ""
var data: Object = null       # a terrain's data (get_height): the fake heights fixture, or none


func get_camera() -> Camera3D:
	return cam
