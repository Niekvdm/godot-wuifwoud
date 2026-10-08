# Copyright (c) 2026 Digitzone
# SPDX-License-Identifier: MIT
extends RefCounted
## Test fixture: stands in for a terrain's data: get_height(p) from a callable (x, z) -> height; NaN without one.

var height := Callable()


func get_height(p: Vector3) -> float:
	return float(height.call(p.x, p.z)) if height.is_valid() else NAN
